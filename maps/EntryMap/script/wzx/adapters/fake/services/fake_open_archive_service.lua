local ScriptedPort = require "wzx.adapters.fake.scripted_port"
local OpenArchiveService = require "wzx.application.ports.open_archive_service"

local FakeOpenArchiveService = {}

function FakeOpenArchiveService.new(options)
    return ScriptedPort.new(OpenArchiveService, options)
end

return FakeOpenArchiveService
