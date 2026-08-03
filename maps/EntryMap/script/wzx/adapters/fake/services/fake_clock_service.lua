local ScriptedPort = require "wzx.adapters.fake.scripted_port"
local ClockService = require "wzx.application.ports.clock_service"

local FakeClockService = {}

function FakeClockService.new(options)
    return ScriptedPort.new(ClockService, options)
end

return FakeClockService
