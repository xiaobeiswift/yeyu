local ScriptedPort = require "wzx.adapters.fake.scripted_port"
local SaveStore = require "wzx.application.ports.save_store"

local FakeSaveStore = {}

function FakeSaveStore.new(options)
    return ScriptedPort.new(SaveStore, options)
end

return FakeSaveStore
