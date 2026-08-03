local Harness = require 'wzx.tests.harness'
local DeriveSeed = require 'wzx.domain.common.derive_seed_v1'
local ParkMiller = require 'wzx.domain.common.park_miller_rng'

local case = Harness.case
local assert = Harness.assert

local MODULUS = 2147483647
local MULTIPLIER = 48271
local SCHRAGE_QUOTIENT = 44488
local SCHRAGE_REMAINDER = 3399

-- Independent reference step: Schrage reduction avoids using the production
-- implementation's direct (state * MULTIPLIER) % MODULUS expression.
local function reference_step(state)
    local next_state = MULTIPLIER * (state % SCHRAGE_QUOTIENT)
        - SCHRAGE_REMAINDER * math.floor(state / SCHRAGE_QUOTIENT)
    if next_state <= 0 then
        next_state = next_state + MODULUS
    end
    return next_state
end

local function reference_derive(root_seed, namespace, context_id)
    local input = tostring(root_seed) .. '\0' .. namespace .. '\0' .. context_id
    local state = root_seed
    local index
    for index = 1, #input do
        state = (reference_step(state) + input:byte(index) + 1) % MODULUS
    end
    if state == 0 then
        state = 1
    end
    return state
end

return {
    case('Park-Miller raw stream matches the reference sequence', function()
        local created = ParkMiller.new(1)
        assert.equal(created.ok, true)
        local rng = created.value
        local expected = {
            48271,
            182605794,
            1291394886,
            1914720637,
            2078669041,
        }
        local index
        for index = 1, #expected do
            assert.equal(rng:next_raw(), expected[index])
        end
        assert.deep_equal(rng:get_state(), {
            state = expected[#expected],
            draw_count = #expected,
        })
    end),

    case('bounded RNG is repeatable and validates its arguments', function()
        local left = ParkMiller.new(777).value
        local right = ParkMiller.new(777).value
        local index
        for index = 1, 30 do
            local left_value = left:uniform(17)
            local right_value = right:uniform(17)
            assert.equal(left_value.ok, true)
            assert.equal(left_value.value, right_value.value)
            assert.truthy(left_value.value >= 0 and left_value.value < 17)
        end

        assert.error_code(ParkMiller.new(0), 'INVALID_ARGUMENT')
        assert.error_code(left:uniform(0), 'INVALID_ARGUMENT')
        assert.error_code(left:roll_bp(-1), 'INVALID_ARGUMENT')
        assert.error_code(left:roll_bp(10001), 'INVALID_ARGUMENT')
    end),

    case('basis-point edge rolls do not consume the random stream', function()
        local rng = ParkMiller.new(99).value
        assert.equal(rng:roll_bp(0).value, false)
        assert.equal(rng:roll_bp(10000).value, true)
        assert.equal(rng:get_state().draw_count, 0)
    end),

    case('seed derivation matches the independent Foundation V1 vector', function()
        local root_seed = 123456789
        local namespace = 'combat'
        local context_id = 'encounter:bridge:1'
        local independent = reference_derive(root_seed, namespace, context_id)
        assert.equal(independent, 540902197)

        local derived = DeriveSeed.derive(root_seed, namespace, context_id)
        assert.equal(derived.ok, true)
        assert.equal(derived.value.algorithm_version, 1)
        assert.equal(derived.value.seed, independent)
        assert.equal(derived.value.seed, 540902197)
        assert.is_nil(derived.value.digest)

        local repeated = DeriveSeed.derive(root_seed, namespace, context_id)
        assert.deep_equal(repeated, derived)
        local changed = DeriveSeed.derive(root_seed, namespace, 'encounter:bridge:2')
        assert.equal(changed.ok, true)
        assert.truthy(changed.value.seed ~= derived.value.seed)

        local reward_seed = DeriveSeed.derive(root_seed, 'reward', context_id)
        assert.equal(reward_seed.ok, true)
        assert.equal(
            reward_seed.value.seed,
            reference_derive(root_seed, 'reward', context_id)
        )
    end),

    case('seed derivation rejects invalid integer roots, namespaces, and derived IDs', function()
        assert.error_code(DeriveSeed.derive(0, 'combat', 'encounter01'), 'INVALID_ARGUMENT')
        assert.error_code(DeriveSeed.derive(1.5, 'combat', 'encounter01'), 'INVALID_ARGUMENT')
        assert.error_code(DeriveSeed.derive(1, 'bad:namespace', 'encounter01'), 'INVALID_ARGUMENT')
        assert.error_code(DeriveSeed.derive(1, 'traversal', 'encounter01'), 'INVALID_ARGUMENT')
        assert.error_code(DeriveSeed.derive(1, 'combat', 'bad::context'), 'ID_INVALID')
        assert.error_code(
            DeriveSeed.derive(1, 'combat', string.rep('a', 65) .. ':context'),
            'ID_INVALID'
        )
    end),
}
