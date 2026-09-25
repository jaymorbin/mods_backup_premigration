--@ module = true
-- refinish-theme.lua
-- ==========================================
-- TOOL: DYNAMIC COLOR REGISTRY
-- ==========================================

local function get_color(pref_id, default_color_name, default_color_int)
    local saved = dfhack.persistent.getSiteData(pref_id)
    if saved and saved ~= "" and _G['COLOR_' .. saved] then
        return _G['COLOR_' .. saved]
    end
    return default_color_int
end

function get_current_theme()
    return {
        PRI       = get_color('refinish_theme_pri', 'LIGHTGREEN', COLOR_LIGHTGREEN),
        SEC       = get_color('refinish_theme_sec', 'LIGHTBLUE', COLOR_LIGHTBLUE),
        TER       = get_color('refinish_theme_ter', 'CYAN', COLOR_CYAN),
        NEUTRAL_B = get_color('refinish_theme_neutral_b', 'WHITE', COLOR_WHITE),
        NEUTRAL_S = get_color('refinish_theme_neutral_s', 'DARKGREY', COLOR_DARKGREY),
        RISK_L    = get_color('refinish_theme_risk_l', 'YELLOW', COLOR_YELLOW),
        RISK_M    = get_color('refinish_theme_risk_m', 'LIGHTRED', COLOR_LIGHTRED),
        RISK_H    = get_color('refinish_theme_risk_h', 'RED', COLOR_RED),
        BG        = COLOR_BLACK,
        GREY      = COLOR_GREY
    }
end

return _ENV