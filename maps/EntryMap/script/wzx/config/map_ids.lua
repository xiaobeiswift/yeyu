-- Map / level IDs for y3.game.switch_level.
-- Engine convert_level_id expects a UUID string, NOT the decimal in header.map.
-- Decimal ↔ UUID: uuid.UUID(int=header.map.id)  (verified in LocalLog).

local MapIds = {
    ---@type string EntryMap (header.id 153474936276712664214184199110824525261)
    ENTRY = '73763292-8f4c-11f1-9d30-93a4cd3b7dcd',
    ---@type integer EntryMap decimal (debug / header.map only)
    ENTRY_DEC = '153474936276712664214184199110824525261',

    ---@type string CreateCharacter 立档图 (header.id 160897935248241842341095906248275415972)
    CREATE_CHARACTER = '790bd0ad-91e6-11f1-a87d-25a4c7a653a4',
    ---@type string CreateCharacter decimal (header.map only)
    CREATE_CHARACTER_DEC = '160897935248241842341095906248275415972',
}

return MapIds
