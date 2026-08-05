-- Chapter 01 content package aggregator (direction 3).
-- Seals quest / dialogue / world / encounter / reward interim packs.

local QuestChapter01 = require 'wzx.config.content.quest.chapter_01'
local DialogueChapter01 = require 'wzx.config.content.dialogue.chapter_01'
local WorldChapter01 = require 'wzx.config.content.world.chapter_01'
local EncounterChapter01 = require 'wzx.config.content.encounter.chapter_01'
local RewardChapter01 = require 'wzx.config.content.reward.chapter_01'

local Bundle = {}

function Bundle.seal_all()
    local quest = QuestChapter01.seal()
    if not quest.ok then
        return quest
    end
    local dialogue = DialogueChapter01.seal()
    if not dialogue.ok then
        return dialogue
    end
    local world = WorldChapter01.seal()
    if not world.ok then
        return world
    end
    local encounter = EncounterChapter01.seal()
    if not encounter.ok then
        return encounter
    end
    local reward = RewardChapter01.build()
    if not reward.ok then
        return reward
    end

    return {
        ok = true,
        value = {
            quest = quest.value,
            dialogue = dialogue.value,
            world = world.value,
            encounter = encounter.value,
            reward = reward.value,
        },
    }
end

--- Collect quest TALK / REACH / SEARCH / ENCOUNTER targets for cross-pack checks.
function Bundle.collect_quest_targets(quest_catalog)
    local targets = {
        dialogue = {},
        location = {},
        interact = {},
        encounter = {},
        reward = {},
    }

    local quests = quest_catalog:list('quest_definitions')
    if not quests.ok then
        return quests
    end

    local qi
    for qi = 1, #quests.value do
        local quest = quests.value[qi]
        if quest.reward_id ~= nil then
            targets.reward[quest.reward_id] = true
        end
        local si
        for si = 1, #quest.stage_ids do
            local stage = quest_catalog:require_stage(quest.stage_ids[si])
            if stage.ok then
                local oi
                for oi = 1, #stage.value.objective_ids do
                    local objective = quest_catalog:require_objective(
                        stage.value.objective_ids[oi]
                    )
                    if objective.ok then
                        local obj = objective.value
                        local tid = obj.target_id
                        if tid ~= nil then
                            if obj.objective_type == 'TALK' then
                                targets.dialogue[tid] = true
                            elseif obj.objective_type == 'REACH_LOCATION' then
                                targets.location[tid] = true
                            elseif obj.objective_type == 'SEARCH_POINT'
                                or obj.objective_type == 'OPEN_CHEST'
                            then
                                targets.interact[tid] = true
                            elseif obj.objective_type == 'COMPLETE_ENCOUNTER' then
                                targets.encounter[tid] = true
                            end
                        end
                    end
                end
            end
        end
    end

    return { ok = true, value = targets }
end

return Bundle
