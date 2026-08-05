-- Chapter 01 reward placeholders (soft currency only; numbers not final balance).

local RewardCatalog = require 'wzx.config.schema.reward.catalog'

local Chapter01 = {}

local function copper_bundle(id, amount)
    return {
        id = id,
        schema_version = 1,
        overflow_policy = 'REJECT',
        entries = {
            {
                entry_order = 1,
                entry_type = 'CURRENCY',
                target_id = 'currency_copper',
                quantity_min = amount,
                quantity_max = amount,
            },
        },
        deprecated = false,
    }
end

function Chapter01.build_source()
    local bundles = {}
    local mains = {
        { 'reward_main_01', 20 },
        { 'reward_main_02', 40 },
        { 'reward_main_03', 40 },
        { 'reward_main_04', 50 },
        { 'reward_main_05', 80 },
        { 'reward_main_06', 50 },
        { 'reward_main_07', 60 },
        { 'reward_main_08', 100 },
        { 'reward_main_09', 80 },
    }
    local sides = {
        { 'reward_side_01', 15 },
        { 'reward_side_02', 25 },
        { 'reward_side_03', 20 },
    }
    local encs = {
        { 'reward_enc_main_02', 30 },
        { 'reward_enc_main_05', 60 },
        { 'reward_enc_main_08', 80 },
    }

    local index
    for index = 1, #mains do
        bundles[#bundles + 1] = copper_bundle(mains[index][1], mains[index][2])
    end
    for index = 1, #sides do
        bundles[#bundles + 1] = copper_bundle(sides[index][1], sides[index][2])
    end
    for index = 1, #encs do
        bundles[#bundles + 1] = copper_bundle(encs[index][1], encs[index][2])
    end

    return { reward_bundles = bundles }
end

function Chapter01.reward_ids()
    local source = Chapter01.build_source()
    local ids = {}
    local index
    for index = 1, #source.reward_bundles do
        ids[index] = source.reward_bundles[index].id
    end
    return ids
end

function Chapter01.build()
    return RewardCatalog.build(Chapter01.build_source())
end

return Chapter01
