-- Retired: CommonTip greybox was wiped for a clean UI slate.
-- Keep a no-op module so old requires do not error during hot reload.

local CommonTipPanel = {}

function CommonTipPanel.last_error()
    return 'common_tip_retired'
end

function CommonTipPanel.bind()
    return false, 'common_tip_retired'
end

function CommonTipPanel.is_bound()
    return false
end

function CommonTipPanel.show(_opts)
    return false
end

function CommonTipPanel.hide()
end

function CommonTipPanel.release()
end

function CommonTipPanel.reset()
end

return CommonTipPanel
