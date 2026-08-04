local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'

local TalentListDigest = {}
local bytewise_string_less = Ordered.bytewise_string_less
local canonical_derive = CanonicalReceiptHashV1.derive
local is_dense_array = Ordered.is_dense_array
local result_err = Result.err
local result_ok = Result.ok
local table_concat = table.concat
local validate_content_id = RuntimeId.validate_content

local MAX_TALENT_IDS = 4096
local DIGEST_FIELDS = {
    { name = 'talent_count', type = 'INTEGER' },
    { name = 'joined_talent_ids', type = 'STRING' },
}

local function invalid(reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        'CHARACTER_TALENT_LIST_INVALID',
        'error.character.talent_list_invalid',
        false,
        details
    )
end

function TalentListDigest.derive(talent_ids)
    if type(talent_ids) ~= 'table'
        or getmetatable(talent_ids) ~= nil
        or not is_dense_array(talent_ids)
    then
        return invalid('PLAIN_DENSE_ARRAY_REQUIRED')
    end
    if #talent_ids > MAX_TALENT_IDS then
        return invalid('TALENT_COUNT_LIMIT_EXCEEDED', {
            maximum = MAX_TALENT_IDS,
            actual = #talent_ids,
        })
    end

    local previous
    local index
    for index = 1, #talent_ids do
        local talent_id = rawget(talent_ids, index)
        local checked = validate_content_id(
            talent_id,
            'talent_',
            'talent_ids[' .. tostring(index) .. ']'
        )
        if not checked.ok then
            return invalid('TALENT_ID_INVALID', {
                index = index,
                cause_code = checked.error.code,
            })
        end
        if previous ~= nil
            and not bytewise_string_less(previous, talent_id)
        then
            return invalid('STRICT_ASCENDING_ORDER_REQUIRED', {
                index = index,
            })
        end
        previous = talent_id
    end

    local derived = canonical_derive(
        'character_unlocked_talent_list',
        DIGEST_FIELDS,
        {
            talent_count = #talent_ids,
            joined_talent_ids = table_concat(talent_ids, '\0'),
        }
    )
    if not derived.ok then
        return invalid('CANONICAL_DIGEST_FAILED', {
            cause_code = derived.error.code,
        })
    end
    return result_ok({
        count = #talent_ids,
        digest = derived.value.digest,
    })
end

TalentListDigest.MAX_TALENT_IDS = MAX_TALENT_IDS

return TalentListDigest
