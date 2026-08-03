local ScriptedPort = require "wzx.adapters.fake.scripted_port"
local RankService = require "wzx.application.ports.rank_service"

local FakeRankService = {}

function FakeRankService.new(options)
    return ScriptedPort.new(RankService, options)
end

return FakeRankService
