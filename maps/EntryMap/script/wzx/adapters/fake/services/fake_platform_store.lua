local ScriptedPort = require "wzx.adapters.fake.scripted_port"
local PlatformStore = require "wzx.application.ports.platform_store"

local FakePlatformStore = {}

function FakePlatformStore.new(options)
    return ScriptedPort.new(PlatformStore, options)
end

return FakePlatformStore
