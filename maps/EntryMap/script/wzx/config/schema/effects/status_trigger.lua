local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.effects.validation'

local StatusTrigger = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local type_value = type
local validation_boolean = Validation.boolean
local validation_content_id = Validation.content_id
local validation_enum = Validation.enum
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields

local SCHEMA = 'StatusTriggerDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    status_id = true,
    hook = true,
    effect_bundle_id = true,
    priority = true,
    limit_per_action = true,
    limit_per_combat = true,
    can_trigger_from_self = true,
    can_trigger_from_triggered_effect = true,
    consume_stack = true,
    deprecated = true,
}
local HOOKS = {
    COMBAT_STARTED = true,
    BEFORE_ACTION = true,
    BEFORE_DAMAGE = true,
    AFTER_DAMAGE = true,
    HP_CHANGED = true,
    ACTOR_DOWNED = true,
    ACTION_FINISHED = true,
    STATUS_REMOVED = true,
}

function StatusTrigger.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local priority = raw_get(value, 'priority')
    if priority == nil then
        priority = 0
    end
    local can_trigger_from_self = raw_get(value, 'can_trigger_from_self')
    if can_trigger_from_self == nil then
        can_trigger_from_self = true
    end
    local can_trigger_from_triggered = raw_get(value, 'can_trigger_from_triggered_effect')
    if can_trigger_from_triggered == nil then
        can_trigger_from_triggered = false
    end
    local consume_stack = raw_get(value, 'consume_stack')
    if consume_stack == nil then
        consume_stack = 0
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', raw_get(value, 'id'), 'trigger_'),
        validation_integer(SCHEMA, 'schema_version', raw_get(value, 'schema_version'), 1, 1),
        validation_content_id(SCHEMA, 'status_id', raw_get(value, 'status_id'), 'status_'),
        validation_enum(SCHEMA, 'hook', raw_get(value, 'hook'), HOOKS),
        validation_content_id(
            SCHEMA,
            'effect_bundle_id',
            raw_get(value, 'effect_bundle_id'),
            'effect_'
        ),
        validation_integer(SCHEMA, 'priority', priority, -1000, 1000),
        validation_integer(
            SCHEMA,
            'limit_per_action',
            raw_get(value, 'limit_per_action'),
            1,
            99
        ),
        validation_integer(
            SCHEMA,
            'limit_per_combat',
            raw_get(value, 'limit_per_combat'),
            1,
            9999
        ),
        validation_boolean(SCHEMA, 'can_trigger_from_self', can_trigger_from_self),
        validation_boolean(
            SCHEMA,
            'can_trigger_from_triggered_effect',
            can_trigger_from_triggered
        ),
        validation_integer(SCHEMA, 'consume_stack', consume_stack, 0, 99),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    return result_ok({
        id = raw_get(value, 'id'),
        schema_version = 1,
        status_id = raw_get(value, 'status_id'),
        hook = raw_get(value, 'hook'),
        effect_bundle_id = raw_get(value, 'effect_bundle_id'),
        priority = priority,
        limit_per_action = raw_get(value, 'limit_per_action'),
        limit_per_combat = raw_get(value, 'limit_per_combat'),
        can_trigger_from_self = can_trigger_from_self,
        can_trigger_from_triggered_effect = can_trigger_from_triggered,
        consume_stack = consume_stack,
        deprecated = deprecated,
    })
end

return StatusTrigger
