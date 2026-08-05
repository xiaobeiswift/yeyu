-- Offline application facade for system 08 equip/create/enhance + optional save bridge.
-- Enhance debits currency (10) and materials (09) with skip_save, then writes equipment
-- instance + slot-5 operation receipt. Not a full ADR-0002 PREPARED multi-slot saga.

local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local CharacterLoadout = require 'wzx.domain.equipment.character_loadout'
local EconomyService = require 'wzx.application.use_cases.economy.economy_service'
local EnhancementPolicy = require 'wzx.domain.equipment.enhancement_policy'
local EquipmentCatalog = require 'wzx.config.schema.equipment.catalog'
local EquipmentErrorCodes = require 'wzx.domain.equipment.error_codes'
local EquipmentInstance = require 'wzx.domain.equipment.equipment_instance'
local EquipmentSaveBridge = require 'wzx.application.use_cases.equipment.equipment_save_bridge'
local EquipmentSaveCodec = require 'wzx.domain.equipment.equipment_save_codec'
local InventoryService = require 'wzx.application.use_cases.inventory.inventory_service'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'

local EquipmentService = {}
local canonical_derive = CanonicalReceiptHashV1.derive
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type
local validate_derived = RuntimeId.validate_derived

local Service = {}
Service.__index = Service
Service.__newindex = function()
    error_value('equipment service is read-only', 2)
end
Service.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.equipment.' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid(reason, details)
    return fail(EquipmentErrorCodes.EQUIPMENT_ARGUMENT_INVALID, reason, details, false)
end

local DEFAULT_COPPER_CURRENCY = 'currency_copper'

local function is_equipment_store(value)
    return type_value(value) == 'table'
        and type_value(value.get_instance) == 'function'
        and type_value(value.put_instance) == 'function'
        and type_value(value.get_loadout) == 'function'
        and type_value(value.get_instances_map) == 'function'
        and type_value(value.replace_instances_and_loadouts) == 'function'
end

local function is_safe_integer(value, minimum, maximum)
    if type_value(value) ~= 'number'
        or value ~= value
        or value == math.huge
        or value == -math.huge
        or value ~= math.floor(value)
    then
        return false
    end
    if minimum ~= nil and value < minimum then
        return false
    end
    if maximum ~= nil and value > maximum then
        return false
    end
    return true
end

local function copy_planned_cost(cost)
    local copied = {
        copper_cost = cost.copper_cost,
        material_count = cost.material_count,
        required_player_chapter = cost.required_player_chapter,
    }
    if cost.material_item_id ~= nil then
        copied.material_item_id = cost.material_item_id
    end
    return copied
end

local function maybe_persist_save(state, input)
    if type_value(input) == 'table' and raw_get(input, 'skip_save') == true then
        return result_ok({ status = 'SKIPPED', reason = 'SKIP_SAVE' })
    end
    if state.save_bridge == nil then
        return result_ok({ status = 'SKIPPED', reason = 'SAVE_BRIDGE_UNBOUND' })
    end
    local player_save_scope = type_value(input) == 'table'
        and raw_get(input, 'player_save_scope')
        or nil
    if player_save_scope == nil then
        return result_ok({
            status = 'SKIPPED',
            reason = 'PLAYER_SAVE_SCOPE_MISSING',
        })
    end
    local saved = state.save_bridge:persist_player_equipment({
        player_save_scope = player_save_scope,
        player_ref = raw_get(input, 'player_ref') or player_save_scope,
        request_id = raw_get(input, 'request_id') or 'request_equipment_save',
        command_id = raw_get(input, 'command_id'),
        save_seed = raw_get(input, 'save_seed'),
        content_version = raw_get(input, 'content_version'),
    })
    if not saved.ok then
        return saved
    end
    return result_ok(saved.value)
end

local function loadouts_map_excluding(store, character_id)
    local exported = store:export_save_bundle()
    if not exported.ok then
        return exported
    end
    local decoded = EquipmentSaveCodec.decode(exported.value)
    if not decoded.ok then
        return decoded
    end
    local next_loadouts = {}
    local index
    for index = 1, #decoded.value.loadouts do
        local row = decoded.value.loadouts[index]
        if row.character_id ~= character_id then
            next_loadouts[row.character_id] = row
        end
    end
    return result_ok(next_loadouts)
end

function EquipmentService.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local catalog = raw_get(options, 'catalog')
    if not EquipmentCatalog.is_authority(catalog) then
        return invalid('CATALOG_AUTHORITY_REQUIRED', { field = 'catalog' })
    end
    local store = raw_get(options, 'store')
    if not is_equipment_store(store) then
        return invalid('EQUIPMENT_STORE_REQUIRED', { field = 'store' })
    end
    local save_bridge = raw_get(options, 'save_bridge')
    if save_bridge ~= nil
        and not EquipmentSaveBridge.is_authority(save_bridge)
    then
        return invalid('SAVE_BRIDGE_AUTHORITY_REQUIRED', {
            field = 'save_bridge',
        })
    end
    local economy_service = raw_get(options, 'economy_service')
    if economy_service ~= nil
        and not EconomyService.is_authority(economy_service)
    then
        return invalid('ECONOMY_SERVICE_AUTHORITY_REQUIRED', {
            field = 'economy_service',
        })
    end
    local inventory_service = raw_get(options, 'inventory_service')
    if inventory_service ~= nil
        and not InventoryService.is_authority(inventory_service)
    then
        return invalid('INVENTORY_SERVICE_AUTHORITY_REQUIRED', {
            field = 'inventory_service',
        })
    end
    local copper_currency_id = raw_get(options, 'copper_currency_id')
        or DEFAULT_COPPER_CURRENCY
    if type_value(copper_currency_id) ~= 'string' or copper_currency_id == '' then
        return invalid('COPPER_CURRENCY_ID_INVALID', {
            field = 'copper_currency_id',
        })
    end

    local view = set_metatable({}, Service)
    STATES[view] = {
        catalog = catalog,
        store = store,
        save_bridge = save_bridge,
        economy_service = economy_service,
        inventory_service = inventory_service,
        copper_currency_id = copper_currency_id,
    }
    return result_ok(view)
end

function EquipmentService.is_authority(value)
    return type_value(value) == 'table' and STATES[value] ~= nil
end

function Service:get_instance(instance_id)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    return state.store:get_instance(instance_id)
end

function Service:get_loadout(character_id)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    return state.store:get_loadout(character_id)
end

function Service:create_instance(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end

    local draft = raw_get(input, 'draft')
    if draft == nil then
        local prepared = EquipmentInstance.prepare_instance(
            state.catalog,
            {
                equipment_id = raw_get(input, 'equipment_id'),
                origin_type = raw_get(input, 'origin_type'),
                origin_ref = raw_get(input, 'origin_ref'),
                creation_ordinal = raw_get(input, 'creation_ordinal') or 0,
                config_version = raw_get(input, 'config_version') or 1,
            },
            { seed = raw_get(input, 'seed') }
        )
        if not prepared.ok then
            return prepared
        end
        draft = prepared.value
    end

    local materialize = EquipmentInstance.from_draft(
        draft,
        raw_get(input, 'instance_id')
    )
    if not materialize.ok then
        return materialize
    end
    local instance = materialize.value
    if raw_get(input, 'created_receipt_id') ~= nil then
        instance.created_receipt_id = raw_get(input, 'created_receipt_id')
    end

    local put = state.store:put_instance(instance)
    if not put.ok then
        return put
    end
    local save = maybe_persist_save(state, input)
    if not save.ok then
        return save
    end
    return result_ok({
        status = 'COMMITTED',
        instance = instance,
        store = put.value,
        save = save.value,
    })
end

function Service:equip(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end

    local character_id = raw_get(input, 'character_id')
    local instance_id = raw_get(input, 'instance_id')
    local character_context = raw_get(input, 'character_context')
    if type_value(character_context) ~= 'table' then
        return invalid('CHARACTER_CONTEXT_REQUIRED', {
            field = 'character_context',
        })
    end

    local loadout = state.store:get_loadout(character_id)
    if not loadout.ok then
        return loadout
    end
    local instances = state.store:get_instances_map()
    if not instances.ok then
        return instances
    end

    local equipped = CharacterLoadout.equip(
        loadout.value,
        instances.value,
        state.catalog,
        character_context,
        instance_id,
        { replace = raw_get(input, 'replace') }
    )
    if not equipped.ok then
        return equipped
    end

    local next_loadouts = loadouts_map_excluding(state.store, character_id)
    if not next_loadouts.ok then
        return next_loadouts
    end
    next_loadouts.value[character_id] = equipped.value.loadout

    local replaced = state.store:replace_instances_and_loadouts(
        equipped.value.instances,
        next_loadouts.value
    )
    if not replaced.ok then
        return replaced
    end
    local save = maybe_persist_save(state, input)
    if not save.ok then
        return save
    end
    return result_ok({
        status = 'COMMITTED',
        loadout = equipped.value.loadout,
        slot = equipped.value.slot,
        replaced_instance_id = equipped.value.replaced_instance_id,
        store = replaced.value,
        save = save.value,
    })
end

function Service:unequip(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end

    local character_id = raw_get(input, 'character_id')
    local slot = raw_get(input, 'slot')
    local loadout = state.store:get_loadout(character_id)
    if not loadout.ok then
        return loadout
    end
    local instances = state.store:get_instances_map()
    if not instances.ok then
        return instances
    end

    local unequipped = CharacterLoadout.unequip(
        loadout.value,
        instances.value,
        slot
    )
    if not unequipped.ok then
        return unequipped
    end

    local next_loadouts = loadouts_map_excluding(state.store, character_id)
    if not next_loadouts.ok then
        return next_loadouts
    end
    next_loadouts.value[character_id] = unequipped.value.loadout

    local replaced = state.store:replace_instances_and_loadouts(
        unequipped.value.instances,
        next_loadouts.value
    )
    if not replaced.ok then
        return replaced
    end
    local save = maybe_persist_save(state, input)
    if not save.ok then
        return save
    end
    return result_ok({
        status = 'COMMITTED',
        loadout = unequipped.value.loadout,
        slot = unequipped.value.slot,
        unequipped_instance_id = unequipped.value.unequipped_instance_id,
        store = replaced.value,
        save = save.value,
    })
end

--- Enhance instance by exactly +1 level.
--- Debits copper via economy (purpose EQUIP_ENHANCE) and materials via inventory
--- with skip_save, then commits equipment instance + equipment operation receipt.
function Service:enhance(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end

    local receipt_id = raw_get(input, 'receipt_id')
    local checked_receipt = validate_derived(receipt_id, 'receipt_id')
    if not checked_receipt.ok then
        return invalid('RECEIPT_ID_INVALID', { field = 'receipt_id' })
    end

    local instance_id = raw_get(input, 'instance_id')
    local checked_instance_id = validate_derived(instance_id, 'instance_id')
    if not checked_instance_id.ok then
        return invalid('INSTANCE_ID_INVALID', { field = 'instance_id' })
    end

    if type_value(state.store.get_receipt) ~= 'function'
        or type_value(state.store.put_committed_receipt) ~= 'function'
    then
        return invalid('RECEIPT_STORE_REQUIRED', { field = 'store' })
    end

    -- Request identity must not depend on post-apply instance level/revision so
    -- the same receipt_id can replay after the enhance has already committed.
    local request = canonical_derive('equipment_enhance_request', {
        { name = 'instance_id', type = 'STRING' },
        { name = 'operation', type = 'STRING' },
    }, {
        instance_id = instance_id,
        operation = 'ENHANCE_PLUS_ONE',
    })
    if not request.ok then
        return request
    end
    local request_hash = request.value.digest

    local existing = state.store:get_receipt(receipt_id)
    if not existing.ok then
        return existing
    end
    if existing.value ~= nil then
        if existing.value.request_hash ~= request_hash
            or existing.value.instance_id ~= instance_id
            or existing.value.operation_type ~= 'ENHANCE_EQUIPMENT'
        then
            return fail(
                EquipmentErrorCodes.EQUIPMENT_RECEIPT_CONFLICT,
                'RECEIPT_PAYLOAD_MISMATCH',
                {
                    receipt_id = receipt_id,
                    expected_request_hash = existing.value.request_hash,
                    actual_request_hash = request_hash,
                },
                false
            )
        end
        local save = maybe_persist_save(state, input)
        if not save.ok then
            return save
        end
        return result_ok({
            status = 'COMMITTED',
            already_committed = true,
            receipt_id = receipt_id,
            request_hash = existing.value.request_hash,
            result_hash = existing.value.result_hash,
            instance_id = existing.value.instance_id,
            from_level = existing.value.from_level,
            to_level = existing.value.to_level,
            planned_cost = copy_planned_cost({
                copper_cost = existing.value.copper_cost,
                material_item_id = existing.value.material_item_id,
                material_count = existing.value.material_count,
                required_player_chapter = 0,
            }),
            equipment_save_revision =
                existing.value.equipment_save_revision_after,
            save = save.value,
        })
    end

    local instance = state.store:get_instance(instance_id)
    if not instance.ok then
        return instance
    end
    instance = instance.value

    if raw_get(input, 'expected_instance_revision') ~= nil
        and raw_get(input, 'expected_instance_revision') ~= instance.instance_revision
    then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_REVISION_CONFLICT,
            'INSTANCE_REVISION_MISMATCH',
            {
                expected = raw_get(input, 'expected_instance_revision'),
                actual = instance.instance_revision,
                instance_id = instance_id,
            },
            false
        )
    end

    local plan = EnhancementPolicy.plan_enhance(instance, state.catalog)
    if not plan.ok then
        return plan
    end
    local planned = plan.value
    local cost = planned.planned_cost

    local player_chapter = raw_get(input, 'player_chapter')
    if player_chapter == nil then
        player_chapter = 0
    end
    if not is_safe_integer(player_chapter, 0, 999) then
        return invalid('PLAYER_CHAPTER_INVALID', { field = 'player_chapter' })
    end
    if player_chapter < cost.required_player_chapter then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_CHAPTER_LOCKED,
            'PLAYER_CHAPTER_TOO_LOW',
            {
                required_player_chapter = cost.required_player_chapter,
                player_chapter = player_chapter,
                instance_id = instance_id,
            },
            false
        )
    end

    -- Preflight cost services before any debit.
    if cost.copper_cost > 0 and state.economy_service == nil then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_COST_SERVICE_REQUIRED,
            'ECONOMY_SERVICE_REQUIRED_FOR_COPPER_COST',
            { copper_cost = cost.copper_cost },
            false
        )
    end
    if cost.material_count > 0 and state.inventory_service == nil then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_COST_SERVICE_REQUIRED,
            'INVENTORY_SERVICE_REQUIRED_FOR_MATERIAL_COST',
            {
                material_item_id = cost.material_item_id,
                material_count = cost.material_count,
            },
            false
        )
    end

    if cost.copper_cost > 0 then
        local balance = state.economy_service:get_balance(state.copper_currency_id)
        if not balance.ok then
            return balance
        end
        if balance.value.available < cost.copper_cost then
            return fail(
                'ECONOMY_CURRENCY_INSUFFICIENT',
                'COPPER_INSUFFICIENT',
                {
                    currency_id = state.copper_currency_id,
                    required = cost.copper_cost,
                    available = balance.value.available,
                },
                false
            )
        end
    end
    if cost.material_count > 0 then
        local held = state.inventory_service:get_count(cost.material_item_id)
        if not held.ok then
            return held
        end
        if held.value.count < cost.material_count then
            return fail(
                'INVENTORY_ITEM_INSUFFICIENT',
                'MATERIAL_INSUFFICIENT',
                {
                    item_id = cost.material_item_id,
                    required = cost.material_count,
                    available = held.value.count,
                },
                false
            )
        end
    end

    local economy_spend = nil
    if cost.copper_cost > 0 then
        local economy_receipt = canonical_derive(
            'equipment_enhance_economy_spend',
            {
                { name = 'parent_receipt_id', type = 'STRING' },
            },
            { parent_receipt_id = receipt_id }
        )
        if not economy_receipt.ok then
            return economy_receipt
        end
        local source_occurrence = canonical_derive(
            'equipment_enhance_economy_source',
            {
                { name = 'parent_receipt_id', type = 'STRING' },
            },
            { parent_receipt_id = receipt_id }
        )
        if not source_occurrence.ok then
            return source_occurrence
        end
        -- source_occurrence_id must be a component (no colon); use digest prefix.
        local source_id = 'eqenh_' .. string.sub(source_occurrence.value.digest, 1, 48)
        local spent = state.economy_service:spend_resources({
            costs = {
                {
                    currency_id = state.copper_currency_id,
                    amount = cost.copper_cost,
                },
            },
            purpose_type = 'EQUIP_ENHANCE',
            purpose_ref = instance_id,
            receipt_id = economy_receipt.value.receipt_id,
            source_occurrence_id = source_id,
            skip_save = true,
        })
        if not spent.ok then
            return spent
        end
        economy_spend = spent.value
    end

    local inventory_consume = nil
    if cost.material_count > 0 then
        local consumed = state.inventory_service:consume_items({
            costs = {
                {
                    item_id = cost.material_item_id,
                    amount = cost.material_count,
                },
            },
            skip_save = true,
        })
        if not consumed.ok then
            return consumed
        end
        inventory_consume = consumed.value
    end

    local applied = EnhancementPolicy.enhance(instance, state.catalog)
    if not applied.ok then
        return applied
    end
    local next_instance = applied.value.instance
    local put = state.store:put_instance(next_instance)
    if not put.ok then
        return put
    end

    local result = canonical_derive('equipment_enhance_result', {
        { name = 'request_hash', type = 'STRING' },
        { name = 'to_level', type = 'INTEGER' },
        { name = 'instance_revision_after', type = 'INTEGER' },
        { name = 'equipment_save_revision_after', type = 'INTEGER' },
    }, {
        request_hash = request_hash,
        to_level = applied.value.to_level,
        instance_revision_after = next_instance.instance_revision,
        equipment_save_revision_after = put.value.equipment_save_revision,
    })
    if not result.ok then
        return result
    end

    local receipt_row = {
        receipt_id = receipt_id,
        request_hash = request_hash,
        result_hash = result.value.digest,
        status = 'COMMITTED',
        operation_type = 'ENHANCE_EQUIPMENT',
        instance_id = instance_id,
        from_level = applied.value.from_level,
        to_level = applied.value.to_level,
        copper_cost = cost.copper_cost,
        material_count = cost.material_count,
        equipment_save_revision_after = put.value.equipment_save_revision,
    }
    if cost.material_item_id ~= nil and cost.material_count > 0 then
        receipt_row.material_item_id = cost.material_item_id
    end
    local stored = state.store:put_committed_receipt(receipt_row)
    if not stored.ok then
        return stored
    end
    if stored.value.already_present then
        if stored.value.receipt ~= nil
            and stored.value.receipt.request_hash == request_hash
        then
            local save = maybe_persist_save(state, input)
            if not save.ok then
                return save
            end
            return result_ok({
                status = 'COMMITTED',
                already_committed = true,
                receipt_id = receipt_id,
                request_hash = stored.value.receipt.request_hash,
                result_hash = stored.value.receipt.result_hash,
                instance_id = stored.value.receipt.instance_id,
                from_level = stored.value.receipt.from_level,
                to_level = stored.value.receipt.to_level,
                planned_cost = copy_planned_cost(cost),
                equipment_save_revision =
                    stored.value.receipt.equipment_save_revision_after,
                save = save.value,
            })
        end
        return fail(
            EquipmentErrorCodes.EQUIPMENT_RECEIPT_CONFLICT,
            'RECEIPT_STORE_CONFLICT',
            { receipt_id = receipt_id },
            false
        )
    end

    local save = maybe_persist_save(state, input)
    if not save.ok then
        return save
    end
    return result_ok({
        status = 'COMMITTED',
        already_committed = false,
        receipt_id = receipt_id,
        request_hash = request_hash,
        result_hash = result.value.digest,
        instance = next_instance,
        from_level = applied.value.from_level,
        to_level = applied.value.to_level,
        planned_cost = copy_planned_cost(cost),
        equipment_save_revision = put.value.equipment_save_revision,
        economy_spend = economy_spend,
        inventory_consume = inventory_consume,
        save = save.value,
    })
end

return EquipmentService
