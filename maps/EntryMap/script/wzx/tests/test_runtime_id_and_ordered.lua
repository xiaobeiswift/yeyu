local Harness = require 'wzx.tests.harness'
local Ordered = require 'wzx.domain.common.ordered'
local RuntimeId = require 'wzx.domain.common.runtime_id'

local case = Harness.case
local assert = Harness.assert

return {
    case('runtime id components and derived ids enforce grammar', function()
        assert.equal(RuntimeId.validate_component('Player_01.alpha-2', 'id').ok, true)
        assert.equal(RuntimeId.validate_component(string.rep('a', 64), 'id').ok, true)
        assert.error_code(RuntimeId.validate_component(':bad', 'id'), 'ID_INVALID')
        assert.error_code(RuntimeId.validate_component('bad:part', 'id'), 'ID_INVALID')
        assert.error_code(RuntimeId.validate_component(string.rep('a', 65), 'id'), 'ID_INVALID')

        assert.equal(RuntimeId.validate_derived('combat:Player_01:7', 'id').ok, true)
        assert.error_code(RuntimeId.validate_derived('combat::7', 'id'), 'ID_INVALID')
        assert.error_code(RuntimeId.validate_derived('combat:', 'id'), 'ID_INVALID')
    end),

    case('content ids are lower-case and optionally prefix-scoped', function()
        assert.equal(RuntimeId.validate_content('martial_cloud_step', 'martial_', 'id').ok, true)
        assert.equal(RuntimeId.validate_content(string.rep('a', 96), nil, 'id').ok, true)
        assert.error_code(RuntimeId.validate_content(string.rep('a', 97), nil, 'id'), 'ID_INVALID')
        assert.error_code(RuntimeId.validate_content('Martial_cloud_step', 'martial_', 'id'), 'ID_INVALID')
        assert.error_code(RuntimeId.validate_content('item_sword', 'martial_', 'id'), 'ID_INVALID')
    end),

    case('runtime id composition is deterministic and rejects invalid parts', function()
        local composed = RuntimeId.compose({ 'combat', 'player-1', 17 })
        assert.equal(composed.ok, true)
        assert.equal(composed.value, 'combat:player-1:17')

        assert.error_code(RuntimeId.compose({ 'only-one' }), 'ID_INVALID')
        assert.error_code(RuntimeId.compose({ 'combat', 0 }), 'ID_INVALID')
        assert.error_code(RuntimeId.compose({ 'combat', 'bad:part' }), 'ID_INVALID')
        assert.error_code(RuntimeId.compose({ string.rep('a', 64), string.rep('b', 64), string.rep('c', 64) }), 'ID_TOO_LONG')
    end),

    case('runtime id composition requires an exact dense plain array', function()
        assert.error_code(RuntimeId.compose({ 'combat', 'player-1', extra = 'ignored' }), 'ID_INVALID')
        assert.error_code(RuntimeId.compose({
            [1] = 'combat',
            [2] = 'player-1',
            [1000000] = 'remote-extra',
        }), 'ID_INVALID')
        assert.error_code(RuntimeId.compose({
            [1] = 'combat',
            [3] = 'player-1',
        }), 'ID_INVALID')

        local calls = {
            index = 0,
            len = 0,
            pairs = 0,
        }
        local hostile = setmetatable({ 'combat', 'player-1' }, {
            __index = function()
                calls.index = calls.index + 1
                return 'forged'
            end,
            __len = function()
                calls.len = calls.len + 1
                return 2
            end,
            __pairs = function()
                calls.pairs = calls.pairs + 1
                return next, { 'combat', 'player-1' }, nil
            end,
        })

        assert.error_code(RuntimeId.compose(hostile), 'ID_INVALID')
        assert.deep_equal(calls, {
            index = 0,
            len = 0,
            pairs = 0,
        })
    end),

    case('ordered helpers reject sparse data and sort without mutating input', function()
        assert.equal(Ordered.is_dense_array({ 'a', 'b', 'c' }), true)
        assert.equal(Ordered.is_dense_array({ [1] = 'a', [3] = 'c' }), false)
        assert.equal(Ordered.is_dense_array({ [1] = 'a', named = 'b' }), false)

        local source = { 3, 1, 2 }
        local copied = Ordered.copy_array(source)
        assert.equal(copied.ok, true)
        copied.value[1] = 99
        assert.equal(source[1], 3)

        local sorted = Ordered.sorted_copy(source, function(left, right)
            return left < right
        end)
        assert.deep_equal(sorted.value, { 1, 2, 3 })
        assert.deep_equal(source, { 3, 1, 2 })

        local keys = Ordered.sorted_string_keys({ z = 1, a = 2, m = 3 })
        assert.deep_equal(keys.value, { 'a', 'm', 'z' })
        assert.error_code(Ordered.sorted_string_keys({ [1] = 'bad' }), 'INVALID_ARGUMENT')
    end),

    case('reference keys preserve 96-byte components and 320/512-byte limits', function()
        local source_320 = string.rep('a', 96)
            .. ':' .. string.rep('b', 96)
            .. ':' .. string.rep('c', 96)
            .. ':' .. string.rep('d', 29)
        local source_321 = source_320 .. 'd'
        local stable_512 = string.rep('a', 96)
            .. ':' .. string.rep('b', 96)
            .. ':' .. string.rep('c', 96)
            .. ':' .. string.rep('d', 96)
            .. ':' .. string.rep('e', 96)
            .. ':' .. string.rep('f', 27)
        local stable_513 = stable_512 .. 'f'

        assert.equal(#source_320, 320)
        assert.equal(#stable_512, 512)
        assert.equal(RuntimeId.validate_source_reference(string.rep('a', 65), 'source').ok, true)
        assert.equal(RuntimeId.validate_source_reference(string.rep('a', 96), 'source').ok, true)
        assert.error_code(
            RuntimeId.validate_source_reference(string.rep('a', 97), 'source'),
            'ID_INVALID'
        )
        assert.equal(RuntimeId.validate_source_reference(source_320, 'source').ok, true)
        assert.error_code(RuntimeId.validate_source_reference(source_321, 'source'), 'ID_INVALID')
        assert.equal(RuntimeId.validate_stable_order_key(stable_512, 'order').ok, true)
        assert.error_code(RuntimeId.validate_stable_order_key(stable_513, 'order'), 'ID_INVALID')

        local malformed = {
            'foo:-bar',
            'foo:.',
            'foo::bar',
            'foo:',
        }
        local index
        for index = 1, #malformed do
            assert.error_code(
                RuntimeId.validate_source_reference(malformed[index], 'source'),
                'ID_INVALID'
            )
            assert.error_code(
                RuntimeId.validate_stable_order_key(malformed[index], 'order'),
                'ID_INVALID'
            )
        end
    end),

    case('dense array checks reject adversarial holes beyond the length operator', function()
        local sparse = {
            [1] = 'one',
            [2] = 'two',
            [4] = 'four',
            [6] = 'six',
        }
        assert.equal(Ordered.is_dense_array(sparse), false)
        assert.error_code(Ordered.copy_array(sparse), 'INVALID_ARGUMENT')
        assert.error_code(Ordered.sorted_copy(sparse, function(left, right)
            return left < right
        end), 'INVALID_ARGUMENT')
    end),

    case('ordered helpers reject hostile metatables without invoking them', function()
        local calls = {
            index = 0,
            len = 0,
            pairs = 0,
        }
        local hostile = setmetatable({}, {
            __index = function()
                calls.index = calls.index + 1
                return 'forged'
            end,
            __len = function()
                calls.len = calls.len + 1
                return 2
            end,
            __pairs = function()
                calls.pairs = calls.pairs + 1
                return next, { forged = true }, nil
            end,
        })

        assert.equal(Ordered.is_dense_array(hostile), false)
        assert.error_code(Ordered.copy_array(hostile), 'INVALID_ARGUMENT')
        assert.error_code(Ordered.sorted_string_keys(hostile), 'INVALID_ARGUMENT')
        assert.deep_equal(calls, {
            index = 0,
            len = 0,
            pairs = 0,
        })
    end),

    case('runtime id and ordered helpers retain captured builtin authorities', function()
        local original_type = _G.type
        local original_getmetatable = _G.getmetatable
        local original_next = _G.next
        local original_rawget = _G.rawget
        local original_tostring = _G.tostring
        local original_floor = math.floor
        local original_huge = math.huge
        local original_min = math.min
        local original_math_type = math.type
        local original_byte = string.byte
        local original_char = string.char
        local original_find = string.find
        local original_gmatch = string.gmatch
        local original_match = string.match
        local original_sub = string.sub
        local original_concat = table.concat
        local original_sort = table.sort
        local protected_call = pcall
        local monkeypatch_calls = 0
        local function forbidden_patch()
            monkeypatch_calls = monkeypatch_calls + 1
            error('captured builtin authority was bypassed')
        end
        local hostile = setmetatable({}, { __index = function() return 'forged' end })

        _G.type = forbidden_patch
        _G.getmetatable = forbidden_patch
        _G.next = forbidden_patch
        _G.rawget = forbidden_patch
        _G.tostring = forbidden_patch
        math.floor = forbidden_patch
        math.huge = 0
        math.min = forbidden_patch
        math.type = forbidden_patch
        string.byte = forbidden_patch
        string.char = forbidden_patch
        string.find = forbidden_patch
        string.gmatch = forbidden_patch
        string.match = forbidden_patch
        string.sub = forbidden_patch
        table.concat = forbidden_patch
        table.sort = forbidden_patch

        local call_ok, valid_content, invalid_content, invalid_derived,
            invalid_reference, composed, dense, hostile_dense, keys = protected_call(function()
                return RuntimeId.validate_content('char_hero', 'char_', 'id'),
                    RuntimeId.validate_content('item_intruder', 'char_', 'id'),
                    RuntimeId.validate_derived('combat::7', 'id'),
                    RuntimeId.validate_source_reference('foo::bar', 'source'),
                    RuntimeId.compose({ 'combat', 'player-1', 17 }),
                    Ordered.is_dense_array({ 'a', 'b' }),
                    Ordered.is_dense_array(hostile),
                    Ordered.sorted_string_keys({ z = true, a = true })
            end)

        _G.type = original_type
        _G.getmetatable = original_getmetatable
        _G.next = original_next
        _G.rawget = original_rawget
        _G.tostring = original_tostring
        math.floor = original_floor
        math.huge = original_huge
        math.min = original_min
        math.type = original_math_type
        string.byte = original_byte
        string.char = original_char
        string.find = original_find
        string.gmatch = original_gmatch
        string.match = original_match
        string.sub = original_sub
        table.concat = original_concat
        table.sort = original_sort

        assert.equal(call_ok, true)
        assert.equal(valid_content.ok, true)
        assert.error_code(invalid_content, 'ID_INVALID')
        assert.error_code(invalid_derived, 'ID_INVALID')
        assert.error_code(invalid_reference, 'ID_INVALID')
        assert.equal(composed.value, 'combat:player-1:17')
        assert.equal(dense, true)
        assert.equal(hostile_dense, false)
        assert.deep_equal(keys.value, { 'a', 'z' })
        assert.equal(monkeypatch_calls, 0)
    end),
}
