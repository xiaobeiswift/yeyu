local ScriptedPort = require "wzx.adapters.fake.scripted_port"
local GachaService = require "wzx.application.ports.gacha_service"

local FakeGachaService = {}

function FakeGachaService.new(options)
    return ScriptedPort.new(GachaService, options)
end

return FakeGachaService
