[CmdletBinding()]
param(
    [string]$Match,
    [ValidateRange(1, 100)]
    [int]$Repeat = 1,
    [switch]$FailFast,
    [switch]$List,
    [string]$Lua = 'lua',
    [string]$Luac = 'luac'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-Executable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (Test-Path -LiteralPath $Name -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($Name)
    }

    $resolved = @(Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
    if ($resolved.Count -eq 0) {
        throw "Required executable was not found: $Name"
    }
    return $resolved[0].Source
}

function Assert-DescendantPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Candidate,
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $resolvedCandidate = [System.IO.Path]::GetFullPath($Candidate)
    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $prefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedCandidate.StartsWith(
        $prefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Path escaped the project boundary: $resolvedCandidate"
    }
    return $resolvedCandidate
}

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$requiredMarkers = @(
    (Join-Path $projectRoot 'AGENTS.md'),
    (Join-Path $projectRoot 'toolchain.lock'),
    (Join-Path $projectRoot 'maps\EntryMap\script\wzx\tests\manifest.lua')
)
foreach ($marker in $requiredMarkers) {
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        throw "Project boundary marker is missing: $marker"
    }
}

$wzxRoot = Assert-DescendantPath `
    -Candidate (Join-Path $projectRoot 'maps\EntryMap\script\wzx') `
    -Root $projectRoot
$runner = Assert-DescendantPath `
    -Candidate (Join-Path $wzxRoot 'tests\runner.lua') `
    -Root $projectRoot
$testRoot = Assert-DescendantPath `
    -Candidate (Join-Path $wzxRoot 'tests') `
    -Root $projectRoot
$manifestPath = Assert-DescendantPath `
    -Candidate (Join-Path $testRoot 'manifest.lua') `
    -Root $projectRoot
$declaredTests = @{}
$manifestSource = Get-Content -LiteralPath $manifestPath -Raw
$manifestMatches = [regex]::Matches(
    $manifestSource,
    '(?m)^[ \t]*[''"]wzx\.tests\.(test_[a-z0-9_]+)[''"][ \t]*,?[ \t]*(?:--[^\r\n]*)?$'
)
foreach ($manifestEntryMatch in $manifestMatches) {
    $declaredTestName = $manifestEntryMatch.Groups[1].Value
    if ($declaredTests.ContainsKey($declaredTestName)) {
        throw "Duplicate test module in explicit manifest: $declaredTestName"
    }
    $declaredTests[$declaredTestName] = $true
}
$diskTests = @(
    Get-ChildItem -LiteralPath $testRoot -File -Filter 'test_*.lua' |
        Sort-Object -Property BaseName
)
$unlistedTests = @(
    $diskTests | Where-Object { -not $declaredTests.ContainsKey($_.BaseName) }
)
if ($unlistedTests.Count -gt 0) {
    $names = $unlistedTests | ForEach-Object { $_.Name }
    throw "Test files missing from explicit manifest: $($names -join ', ')"
}
$luaExecutable = Resolve-Executable -Name $Lua
$luacExecutable = Resolve-Executable -Name $Luac

$luaFiles = @(
    Get-ChildItem -LiteralPath $wzxRoot -Recurse -File -Filter '*.lua' |
        Sort-Object -Property FullName
)
if ($luaFiles.Count -eq 0) {
    throw "No Lua files were found below the WZX boundary: $wzxRoot"
}

foreach ($file in $luaFiles) {
    $checkedPath = Assert-DescendantPath -Candidate $file.FullName -Root $projectRoot
    & $luacExecutable -p $checkedPath
    if ($LASTEXITCODE -ne 0) {
        throw "Lua syntax check failed: $checkedPath"
    }
}
Write-Host "Lua syntax check: $($luaFiles.Count) file(s) passed."

$pureRoots = @(
    (Join-Path $wzxRoot 'domain'),
    (Join-Path $wzxRoot 'application')
)
$forbiddenRules = @(
    [pscustomobject]@{ Name = 'Y3 engine token'; Pattern = '(?i)\by3\b' },
    [pscustomobject]@{ Name = 'GameAPI'; Pattern = '\bGameAPI\b' },
    [pscustomobject]@{ Name = 'GlobalAPI'; Pattern = '\bGlobalAPI\b' },
    [pscustomobject]@{ Name = 'include'; Pattern = '\binclude\b' },
    [pscustomobject]@{ Name = 'math.random'; Pattern = '\bmath\s*\.\s*random(?:seed)?\b' },
    [pscustomobject]@{ Name = 'os.time'; Pattern = '\bos\s*\.\s*time\b' },
    [pscustomobject]@{ Name = 'rawset authority bypass'; Pattern = '\brawset\s*\(' },
    [pscustomobject]@{ Name = 'debug library'; Pattern = '\bdebug\s*\.' }
)
$violations = New-Object 'System.Collections.Generic.List[string]'

foreach ($pureRoot in $pureRoots) {
    if (-not (Test-Path -LiteralPath $pureRoot -PathType Container)) {
        continue
    }
    $pureFiles = Get-ChildItem -LiteralPath $pureRoot -Recurse -File -Filter '*.lua'
    foreach ($file in $pureFiles) {
        $checkedPath = Assert-DescendantPath -Candidate $file.FullName -Root $projectRoot
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $checkedPath) {
            $lineNumber += 1
            foreach ($rule in $forbiddenRules) {
                if ($line -match $rule.Pattern) {
                    $relative = $checkedPath.Substring($projectRoot.Length).TrimStart('\', '/')
                    $violations.Add("${relative}:${lineNumber}: $($rule.Name)")
                }
            }
        }
    }
}

if ($violations.Count -gt 0) {
    Write-Error ("Pure Lua boundary violations:`n" + ($violations -join "`n"))
}
Write-Host 'Pure Lua static boundary scan: passed.'

$runnerArguments = @(
    $runner,
    '--project-root',
    $projectRoot,
    '--repeat',
    [string]$Repeat
)
if ($PSBoundParameters.ContainsKey('Match')) {
    if ([string]::IsNullOrWhiteSpace($Match)) {
        throw '-Match must not be empty when supplied.'
    }
    $runnerArguments += @('--match', $Match)
}
if ($FailFast) {
    $runnerArguments += '--fail-fast'
}
if ($List) {
    $runnerArguments += '--list'
}

& $luaExecutable @runnerArguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
exit 0
