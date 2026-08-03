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
}
