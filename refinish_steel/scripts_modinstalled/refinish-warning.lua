--@ module = true
-- refinish-warning.lua

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body. The
-- panel filters on TYPE and nothing else, so each call site states
-- its own:
--   DETAIL   debugging material, shown in Debug only
--   INFO     what a player might check during play, Normal and up
--   faults, and the few confirmations a player wants at a glance
--   (COMPLETE, SYSTEM, ONLINE and the like), show in Quiet as well
-- TYPE comes first so no call site can drop it unnoticed: a nil TYPE
-- still renders, as UNTYPED, which shows at every Log Detail level
-- instead of being guessed at.
--
-- SUBJECT is the correlation slot: the overlay control a line is
-- about. Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'OVERLAY'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

local function log(typ, msg, subject)
    if not _G.refinish_log_event then return end
    local line
    if rlog then
        line = rlog.compose(LOG_SYS, LOG_SUB, subject, typ, msg)
    else
        -- The composer failed to load. Same grammar, unsanitised.
        line = string.format('%s %s %s %s | %s', LOG_SYS, LOG_SUB,
            tostring(subject or '-'), tostring(typ or 'UNTYPED'),
            tostring(msg))
    end
    _G.refinish_log_event(line)
end

RefinishWarningOverlay = defclass(RefinishWarningOverlay, overlay.OverlayWidget)
RefinishWarningOverlay.ATTRS = {
    desc = "Refinish Warning Overlay",
    default_pos = {x = 70, y = 10},
    default_enabled = true,
    viewscreens = 'dwarfmode/Options',
    version = "3.2",

    frame = {w = 52, h = 11},
    frame_style = gui.FRAME_BOLD,
    frame_background = gui.CLEAR_PEN,

    visible = function() 
        -- Hide entirely if the master mod state is dormant (Vanilla saves)
        if not _G.refinish_active then return false end

        local focus = dfhack.gui.getCurFocus()
        
        if type(focus) == 'table' and #focus == 1 and focus[1] == 'dwarfmode/Options' then
            return true
        end
        
        return false
    end,
}

function RefinishWarningOverlay:init()
    local function is_safe()
        return (not _G.refinish_data_loaded) and (not _G.refinish_ram_loaded)
    end

    -- HELPER: Check the active menu wipe setting
    local function get_esc_mode()
        local mode = dfhack.persistent.getSiteData('refinish_config_esc')
        return (mode and mode ~= "") and mode or 'AUTO'
    end

    -- HELPER: Read the user's custom hotkeys
    local function get_hk(id, default)
        local hk = dfhack.persistent.getSiteData(id)
        return (hk and hk ~= "") and hk or default
    end

    self:addviews{
        widgets.Label{
            frame = {l = 1, t = 1},
            text = {
                {
                    text = function() return is_safe() and "*** REFINISH METAL DATA IS NOT LOADED ***" or "!!! REFINISH METAL DATA IS LOADED !!!" end,
                    pen = function() return is_safe() and COLOR_LIGHTGREEN or COLOR_RED end
                }
            }
        },
        widgets.Label{
            frame = {l = 1, t = 3},
            text = {
                {
                    text = function() return is_safe() and "It is safe to manually save the game." or "DO NOT MANUALLY SAVE WHILE DATA IS LOADED!" end,
                    pen = function() return is_safe() and COLOR_LIGHTGREEN or COLOR_RED end
                }
            }
        },
        widgets.Label{
            frame = {l = 1, t = 5},
            text = {
                {
                    text = function()
                        local mode = get_esc_mode()
                        local hk_startup = get_hk('refinish_hk_startup', 'Ctrl-Alt-X')
                        local hk_wipe = get_hk('refinish_hk_wipe', 'Ctrl-Shift-X')
                        
                        if mode == 'AUTO' then
                            return is_safe() and "Close this menu to reload Refinish Metal" or "Please wait. Your data is being unloaded and preserved"
                        else
                            return is_safe() and "Press " .. hk_startup .. " to manually reload" or "Press " .. hk_wipe .. " to prevent save corruption"
                        end
                    end,
                    pen = function() return is_safe() and COLOR_LIGHTGREEN or COLOR_RED end
                }
            }
        },
        widgets.Label{
            frame = {l = 1, t = 6},
            text = {
                {
                    text = function()
                        local mode = get_esc_mode()
                        if mode == 'AUTO' then
                            return is_safe() and "data automatically and resume the game." or "to prevent manual save corruption and data loss."
                        else
                            return is_safe() and "Refinish Metal data and resume the game." or "by unloading the data BEFORE A MANUAL SAVE!"
                        end
                    end,
                    pen = function() return is_safe() and COLOR_LIGHTGREEN or COLOR_RED end
                }
            }
        },
        widgets.HotkeyLabel{
            frame = {l = 1, b = 0},
            key = 'CUSTOM_ALT_C',
            label = 'Refinish Metal Configuration',
            on_activate = function() 
                -- DETAIL: menu navigation is only useful when debugging.
                log('DETAIL', 'User opened the config menu with the overlay'
                    .. ' hotkey.', 'HOTKEY')
                dfhack.run_script('refinish-config', 'show') 
            end,
            text_pen = COLOR_LIGHTBLUE
        }
    }
end

OVERLAY_WIDGETS = { warning = RefinishWarningOverlay }