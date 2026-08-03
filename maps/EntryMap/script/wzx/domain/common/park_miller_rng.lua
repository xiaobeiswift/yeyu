local Result = require 'wzx.domain.common.result'

local ParkMiller = {}
ParkMiller.__index = ParkMiller

local MODULUS = 2147483647
local RANGE = MODULUS - 1
local MULTIPLIER = 48271

function ParkMiller.new(seed)
    if type(seed) ~= 'number' or seed ~= math.floor(seed) or seed < 1 or seed > RANGE then
        return Result.err('INVALID_ARGUMENT', 'error.foundation.rng_seed_invalid', false, {
            min = 1,
            max = RANGE,
        })
    end
    return Result.ok(setmetatable({ state = seed, draw_count = 0 }, ParkMiller))
end

function ParkMiller:next_raw()
    local next_state = (self.state * MULTIPLIER) % MODULUS
    self.state = next_state
    self.draw_count = self.draw_count + 1
    return next_state
end

function ParkMiller:uniform(upper_exclusive)
    if type(upper_exclusive) ~= 'number'
        or upper_exclusive ~= math.floor(upper_exclusive)
        or upper_exclusive < 1
        or upper_exclusive > RANGE
    then
        return Result.err('INVALID_ARGUMENT', 'error.foundation.rng_upper_bound_invalid', false)
    end

    local limit = RANGE - (RANGE % upper_exclusive)
    local sample
    repeat
        sample = self:next_raw() - 1
    until sample < limit
    return Result.ok(sample % upper_exclusive)
end

function ParkMiller:roll_bp(chance_bp)
    if type(chance_bp) ~= 'number'
        or chance_bp ~= math.floor(chance_bp)
        or chance_bp < 0
        or chance_bp > 10000
    then
        return Result.err('INVALID_ARGUMENT', 'error.foundation.rng_chance_invalid', false)
    end
    if chance_bp == 0 then
        return Result.ok(false)
    end
    if chance_bp == 10000 then
        return Result.ok(true)
    end
    local rolled = self:uniform(10000)
    if not rolled.ok then
        return rolled
    end
    return Result.ok(rolled.value < chance_bp)
end

function ParkMiller:get_state()
    return {
        state = self.state,
        draw_count = self.draw_count,
    }
end

return ParkMiller
