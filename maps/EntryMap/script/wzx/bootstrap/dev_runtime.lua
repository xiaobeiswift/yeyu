local previous = rawget(_G, 'WZX_RUNTIME_HOST')
local ReloadGuard = require 'wzx.bootstrap.reload_guard'
local stopped = ReloadGuard.stop_previous(previous)
if not stopped.ok then
    print('[WZX] reload blocked: previous development runtime is still authoritative')
    return
end
rawset(_G, 'WZX_RUNTIME_HOST', nil)

package.loaded['wzx.bootstrap.reload_manifest'] = nil
local reload_modules = require 'wzx.bootstrap.reload_manifest'
local module_index
for module_index = 1, #reload_modules do
    package.loaded[reload_modules[module_index]] = nil
end
package.loaded['wzx.bootstrap.reload_manifest'] = nil

local Y3Runtime = require 'wzx.bootstrap.y3_runtime'
local generation = (rawget(_G, 'WZX_RUNTIME_GENERATION') or 0) + 1
local started = Y3Runtime.start({ generation = generation })
if started.ok then
    rawset(_G, 'WZX_RUNTIME_GENERATION', generation)
    rawset(_G, 'WZX_RUNTIME_HOST', started.value)
    print('[WZX] Foundation V1 development runtime ready; platform features remain disabled')
else
    print('[WZX] Foundation V1 development runtime failed: ' .. tostring(started.error.code))
end
