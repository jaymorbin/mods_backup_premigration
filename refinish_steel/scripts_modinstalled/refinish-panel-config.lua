--@ module = true
-- refinish-panel-config.lua

local gui = require('gui')
local widgets = require('gui.widgets')
local dialogs = require('gui.dialogs')
local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt

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
-- SUBJECT is the correlation slot: the setting a line is about. Nil
-- renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'CONFIG'
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

RefinishPanelConfig = defclass(RefinishPanelConfig, widgets.Panel)
RefinishPanelConfig.ATTRS = { theme = DEFAULT_NIL }

function RefinishPanelConfig:init()
    local function get_pref(id, default)
        local state = dfhack.persistent.getSiteData(id)
        return (state and state ~= "") and state or default
    end

    self.theme = self.theme or reqscript('refinish-theme').get_current_theme()

    local C_LBL = self.theme.SEC
    local C_VAL = self.theme.PRI
    local C_KEY = self.theme.PRI
    local C_NEG = self.theme.SEC

    local current_perf = get_pref('refinish_config_perf', 'ON')
    
    local hk_config   = get_pref('refinish_hk_config',   'Ctrl-Shift-C')
    local hk_metals   = get_pref('refinish_hk_metals',   'Ctrl-Shift-M')
    local hk_civs     = get_pref('refinish_hk_civs',     'Ctrl-Shift-V')
    local hk_status   = get_pref('refinish_hk_status',   'Ctrl-Shift-I')
    local hk_log      = get_pref('refinish_hk_log',      'Ctrl-Shift-L')
    local hk_inspect  = get_pref('refinish_hk_inspect',  'Ctrl-Shift-E')
    local hk_help     = get_pref('refinish_hk_help',     'Ctrl-Shift-H')
    local hk_autosave = get_pref('refinish_hk_autosave', 'Ctrl-Shift-S')
    local hk_wipe     = get_pref('refinish_hk_wipe',     'Ctrl-Shift-X')
    local hk_startup  = get_pref('refinish_hk_startup',  'Ctrl-Alt-X')
    local hk_hardwipe = get_pref('refinish_hk_hardwipe', 'Ctrl-Shift-Q')

    local function safe_rebind(old_k, new_k, cmd)
        if old_k and old_k ~= "" then pcall(function() dfhack.run_command('keybinding', 'clear', old_k) end) end
        pcall(function() dfhack.run_command('keybinding', 'add', new_k, cmd) end)
    end

    local function make_hk_changer(pref_id, script_cmd, old_key)
        local choices = {}
        for _, mod in ipairs({'Ctrl-', 'Ctrl-Shift-', 'Ctrl-Alt-'}) do
            for char = 65, 90 do table.insert(choices, {text = mod .. string.char(char), value = mod .. string.char(char)}) end
        end
        dialogs.showListPrompt("Rebind Hotkey", "Select new hotkey for: " .. script_cmd .. "\n(Current: " .. old_key .. ")", self.theme.PRI, choices,
            function(idx, choice)
                dfhack.persistent.saveSiteData(pref_id, choice.value)
                safe_rebind(old_key, choice.value, script_cmd)
                -- INFO: a setting the player changed. script_cmd names
                -- which hotkey it was.
                log('INFO', 'Hotkey for ' .. tostring(script_cmd) .. ' bound to '
                    .. tostring(choice.value) .. '.', 'HOTKEY')
                if _G.refinish_hud_view then _G.refinish_hud_view:dismiss() end
                dfhack.run_script('refinish-hud', 'show', 'config')
            end)
    end

    -- ==========================================
    -- THEMED CYCLE WIDGET FACTORY
    -- ==========================================
    self.cycles = {}
    self.actions = {}

    local function make_themed_cycle(t_pos, key_token, label_text, options, pref_id, default_val, on_change_extra)
        local current_val = get_pref(pref_id, default_val)
        local current_idx = 1
        for i, opt in ipairs(options) do if opt.value == current_val then current_idx = i; break end end
        local state = { idx = current_idx, options = options }

        local function get_display_text()
            local opt = state.options[state.idx]
            return {
                {text = dfhack.screen.getKeyDisplay(df.interface_key[key_token]), pen = C_KEY},
                {text = ": " .. label_text .. " ", pen = C_LBL},
                {text = opt.label, pen = opt.pen or C_VAL}
            }
        end

        local function do_cycle()
            state.idx = (state.idx % #state.options) + 1
            local opt = state.options[state.idx]
            dfhack.persistent.saveSiteData(pref_id, opt.value)
            if on_change_extra then on_change_extra(opt.value, state) end
        end

        -- 1. Create the widget without the on_click handler
        local w = widgets.Label{ frame = {t = t_pos, l = 0, w = 32}, text = get_display_text() }
        
        -- 2. Assign the click handler AFTER instantiation so 'w' is correctly in scope
        w.on_click = function() 
            do_cycle()
            w:setText(get_display_text()) 
        end

        table.insert(self.cycles, { key = key_token, widget = w, state = state,
            cycle = function() do_cycle(); w:setText(get_display_text()) end, get_display_text = get_display_text })
        return w
    end

    local function make_key_label(key_token, label_text, pen_label)
        return {
            {text = dfhack.screen.getKeyDisplay(df.interface_key[key_token]), pen = C_KEY},
            {text = ": " .. label_text, pen = pen_label}
        }
    end

    -- ==========================================
    -- SYSTEM SETTINGS
    -- ==========================================
    self.w_autosave = make_themed_cycle(4, 'CUSTOM_SHIFT_Q', 'Autosave:', {
        {label = 'Seasonal', value = 'SEASONAL', pen = C_VAL}, {label = 'Semi-Annual', value = 'SEMIANNUAL', pen = C_VAL},
        {label = 'Yearly', value = 'YEARLY', pen = C_VAL}, {label = '15 Min', value = 'REAL_15', pen = C_VAL},
        {label = '30 Min', value = 'REAL_30', pen = C_VAL}, {label = '1 Hour', value = 'REAL_60', pen = C_VAL},
        {label = 'Off', value = 'NONE', pen = C_NEG},
    }, 'refinish_config_interval', 'SEASONAL')

    self.w_pause = make_themed_cycle(6, 'CUSTOM_SHIFT_W', 'Pause on Save:', {
        {label = 'Yes', value = 'YES', pen = C_VAL}, {label = 'No', value = 'NO', pen = C_NEG},
    }, 'refinish_config_pause', 'YES')

    self.w_save_protocol = make_themed_cycle(8, 'CUSTOM_SHIFT_E', 'Save Protocol:', {
        {label = 'Hotsave', value = 'HOTSAVE', pen = self.theme.RISK_L}, {label = 'Autosave', value = 'AUTOSAVE', pen = C_VAL},
    }, 'refinish_config_save_protocol', 'AUTOSAVE')

    self.w_menu = make_themed_cycle(10, 'CUSTOM_SHIFT_R', 'Menu Data Cycle:', {
        {label = 'Auto', value = 'AUTO', pen = C_VAL}, {label = 'Manual', value = 'MANUAL', pen = C_NEG},
    }, 'refinish_config_esc', 'AUTO')

    -- Load Delay. Instant is the only safe setting; the risk pens used
    -- to say the opposite. Any delay leaves a window in which a save's
    -- module material items point past the end of the inorganics
    -- array, where LIQUID_MISC resolves to magma. Longer delay, wider
    -- window, hotter pen. Kept selectable for diagnosis only.
    -- LOAD DELAY OPTION (removed)
    -- Startup always runs Instant now, hardcoded in refinish_steel.lua.
    -- Any delay leaves a window in which a save's module material items
    -- point past the end of the inorganics array, where LIQUID_MISC
    -- resolves to magma. There is no setting here worth offering.
    -- CUSTOM_SHIFT_T is free.
    -- self.w_delay = make_themed_cycle(12, 'CUSTOM_SHIFT_T', 'Load Delay:', {
    --     {label = 'Instant', value = 'NONE', pen = C_VAL}, {label = '1 Tick', value = 'TICK', pen = self.theme.RISK_L},
    --     {label = '20 Frames', value = 'FRAMES_20', pen = self.theme.RISK_M}, {label = '100 Frames', value = 'FRAMES_100', pen = self.theme.RISK_H},
    -- }, 'refinish_config_delay', 'NONE')

    self.w_perf = make_themed_cycle(14, 'CUSTOM_SHIFT_Y', 'Material Finishes:', {
        {label = 'ON', value = 'ON', pen = C_VAL}, {label = 'OFF', value = 'OFF', pen = C_NEG},
    }, 'refinish_config_perf', current_perf, function(val, state)
        RefinishPrompt{
            text = "Changing this configuration will cancel all active jobs involving Refinish Metal materials and trigger data cycling.\n\nAre you sure you want to proceed?",
            text_pen = self.theme.PRI,
            on_yes = function()
                current_perf = val
                -- INFO: a setting the player changed, and why the data
                -- cycle that follows ran.
                log('INFO', 'Material finishes set to ' .. tostring(val)
                    .. '. Triggering a data cycle.', 'FINISHES')
                dfhack.run_script('refinish-hard-shutdown', 'SILENT')
                dfhack.run_script('refinish-startup', 'SILENT')
                local jobs_killed = _G.refinish_last_jobs_canceled or 0; _G.refinish_last_jobs_canceled = nil
                local msg_setting = get_pref('refinish_config_msg', 'GUIDED')
                if msg_setting == 'GUIDED' or msg_setting == 'DEBUG' then
                    local action_txt = (val == 'OFF') and "purged from active RAM and saved.\n\nChanging this configuration setting to ON will restore and inject data." or "retrieved and injected into active RAM.\n\nChanging this configuration setting to OFF will save and purge data."
                    local debug_txt = (msg_setting == 'DEBUG') and ("\n\n[DEBUG: Material Finishes flag toggled to " .. val .. ". " .. jobs_killed .. " jobs canceled.]") or ""
                    RefinishPrompt{ frame_h = (msg_setting == 'DEBUG') and 18 or 12, text = "Material finish data has been successfully " .. action_txt .. debug_txt, text_pen = self.theme.PRI, on_ok = function() end }:show()
                elseif msg_setting == 'PASSIVE' then
                    dfhack.gui.showAnnouncement('Refinish Metal: RAM cycled successfully.', self.theme.PRI, true)
                end
            end,
            on_no = function()
                dfhack.persistent.saveSiteData('refinish_config_perf', current_perf)
                for _, c in ipairs(self.cycles) do
                    if c.key == 'CUSTOM_SHIFT_Y' then
                        for i, opt in ipairs(c.state.options) do
                            if opt.value == current_perf then c.state.idx = i; c.widget:setText(c.get_display_text()); break end
                        end; break
                    end
                end
            end
        }:show()
    end)

    self.w_msg = make_themed_cycle(16, 'CUSTOM_SHIFT_I', 'Invasiveness:', {
        {label = 'Guided', value = 'GUIDED', pen = C_VAL}, {label = 'Passive', value = 'PASSIVE', pen = self.theme.RISK_L},
        {label = 'Silent', value = 'SILENT', pen = self.theme.RISK_M}, {label = 'Debug', value = 'DEBUG', pen = C_NEG},
    }, 'refinish_config_msg', 'GUIDED')

    self.w_protect = make_themed_cycle(18, 'CUSTOM_SHIFT_O', 'Protect Bases:', {
        {label = 'Yes', value = 'YES', pen = C_VAL}, {label = 'No', value = 'NO', pen = C_NEG},
    }, 'refinish_config_protect', 'YES')

    -- Polling Rate: Controls how frequently the reaction watcher and
    -- UI monitor loops fire. Lower values = more responsive but heavier
    -- on the CPU. Large forts benefit from relaxed polling.
    -- ---- UI LOG VERBOSITY ----
    -- Display only. The session file on disk is always debug-verbose,
    -- because a setting that reduces what gets RECORDED is a setting
    -- that loses the one line you needed.
    --
    -- Filters on the TYPE tag, which the emitter already declares and
    -- which already drives the colour, so one classification serves
    -- both and no module has to supply anything new.
    self.w_loglevel = make_themed_cycle(20, 'CUSTOM_SHIFT_P', 'Log Detail:', {
        {label = 'Quiet',  value = 'QUIET',  pen = self.theme.RISK_L},
        {label = 'Normal', value = 'NORMAL', pen = C_VAL},
        {label = 'Debug',  value = 'DEBUG',  pen = C_NEG},
    }, 'refinish_config_log', 'NORMAL', function()
        -- Bumped so the log panel notices without polling the
        -- persistent store every frame. make_themed_cycle already
        -- saves the value before calling this.
        _G.refinish_log_filter_gen = (_G.refinish_log_filter_gen or 0) + 1
    end)

    self.w_poll = make_themed_cycle(12, 'CUSTOM_SHIFT_U', 'Polling Rate:', {
        {label = 'Fast',    value = 'FAST',    pen = C_VAL},
        {label = 'Normal',  value = 'NORMAL',  pen = C_VAL},
        {label = 'Relaxed', value = 'RELAXED', pen = self.theme.RISK_L},
    }, 'refinish_config_poll_rate', 'FAST')

    -- ==========================================
    -- RESTORE DEFAULTS
    -- ==========================================
    -- Moved off SHIFT_P so Log Detail can sit under Protect Bases.
    -- STRING_A043 is ASCII 43, the plus sign: onInput dispatches on a
    -- plain keys[name] lookup, so a STRING key binds the same way a
    -- letter does.
    self.actions.STRING_A043 = function()
        RefinishPrompt{ text = "Are you sure you want to revert all configurations to their original defaults?", text_pen = self.theme.PRI,
            on_yes = function()
                for _, kv in ipairs({
                    {'refinish_config_interval','SEASONAL'}, {'refinish_config_save_protocol','AUTOSAVE'}, {'refinish_config_pause','YES'},
                    -- LOAD DELAY OPTION (removed): {'refinish_config_delay','NONE'},
                    {'refinish_config_esc','AUTO'}, {'refinish_config_msg','GUIDED'},
                    {'refinish_config_protect','YES'}, {'refinish_config_perf','ON'},
                    {'refinish_config_poll_rate','FAST'},
                    {'refinish_config_log','NORMAL'},
                    {'refinish_theme_pri','LIGHTGREEN'}, {'refinish_theme_sec','LIGHTBLUE'}, {'refinish_theme_ter','CYAN'},
                    {'refinish_theme_neutral_b','WHITE'}, {'refinish_theme_neutral_s','DARKGREY'},
                    {'refinish_theme_risk_l','YELLOW'}, {'refinish_theme_risk_m','LIGHTRED'}, {'refinish_theme_risk_h','RED'},
                    {'refinish_hk_config','Ctrl-Shift-C'}, {'refinish_hk_metals','Ctrl-Shift-M'}, {'refinish_hk_civs','Ctrl-Shift-V'},
                    {'refinish_hk_status','Ctrl-Shift-I'}, {'refinish_hk_log','Ctrl-Shift-L'}, {'refinish_hk_inspect','Ctrl-Shift-E'},
                    {'refinish_hk_help','Ctrl-Shift-H'}, {'refinish_hk_autosave','Ctrl-Shift-S'}, {'refinish_hk_wipe','Ctrl-Shift-X'},
                    {'refinish_hk_startup','Ctrl-Alt-X'}, {'refinish_hk_hardwipe','Ctrl-Shift-Q'},
                }) do dfhack.persistent.saveSiteData(kv[1], kv[2]) end
                safe_rebind(hk_config,'Ctrl-Shift-C','refinish-hud show config'); safe_rebind(hk_metals,'Ctrl-Shift-M','refinish-hud show metals')
                safe_rebind(hk_civs,'Ctrl-Shift-V','refinish-hud show civs'); safe_rebind(hk_status,'Ctrl-Shift-I','refinish-hud show status')
                safe_rebind(hk_log,'Ctrl-Shift-L','refinish-hud show log'); safe_rebind(hk_inspect,'Ctrl-Shift-E','refinish-hud show inspect')
                safe_rebind(hk_help,'Ctrl-Shift-H','refinish-hud show help'); safe_rebind(hk_autosave,'Ctrl-Shift-S','refinish-autosave')
                safe_rebind(hk_wipe,'Ctrl-Shift-X','refinish-shutdown'); safe_rebind(hk_startup,'Ctrl-Alt-X','refinish-startup')
                safe_rebind(hk_hardwipe,'Ctrl-Shift-Q','refinish-hard-shutdown')
                if _G.refinish_hud_view then _G.refinish_hud_view:dismiss() end
                dfhack.run_script('refinish-hud', 'show', 'config')
            end }:show()
    end

    self.btn_restore = widgets.Label{ frame = {t = 22, l = 0, w = 32},
        text = make_key_label('STRING_A043', 'Restore Default Settings', self.theme.PRI),
        on_click = self.actions.STRING_A043 }

    -- ==========================================
    -- HOTKEY REBINDERS
    -- ==========================================
    local hk_defs = {
        {t=25, key='STRING_A049', lbl="Config:",    pref='refinish_hk_config',   cmd='refinish-hud show config',  cur=hk_config},
        {t=26, key='STRING_A050', lbl="Metals:",    pref='refinish_hk_metals',   cmd='refinish-hud show metals',  cur=hk_metals},
        {t=27, key='STRING_A051', lbl="Civs:",      pref='refinish_hk_civs',     cmd='refinish-hud show civs',    cur=hk_civs},
        {t=28, key='STRING_A052', lbl="Status:",    pref='refinish_hk_status',   cmd='refinish-hud show status',  cur=hk_status},
        {t=29, key='STRING_A053', lbl="Log:",       pref='refinish_hk_log',      cmd='refinish-hud show log',     cur=hk_log},
        {t=30, key='STRING_A054', lbl="Inspect:",   pref='refinish_hk_inspect',  cmd='refinish-hud show inspect', cur=hk_inspect},
        {t=31, key='STRING_A055', lbl="Help:",      pref='refinish_hk_help',     cmd='refinish-hud show help',    cur=hk_help},
        {t=34, key='STRING_A056', lbl="Startup:",   pref='refinish_hk_startup',  cmd='refinish-startup',          cur=hk_startup},
        {t=35, key='STRING_A057', lbl="Mem Wipe:",  pref='refinish_hk_wipe',     cmd='refinish-shutdown',         cur=hk_wipe},
        {t=36, key='STRING_A048', lbl="Hard Wipe:", pref='refinish_hk_hardwipe', cmd='refinish-hard-shutdown',    cur=hk_hardwipe},
        {t=37, key='STRING_A045', lbl="Autosave:",  pref='refinish_hk_autosave', cmd='refinish-autosave',         cur=hk_autosave},
    }

    local hk_widgets = {}
    for _, hk in ipairs(hk_defs) do
        local action = function() make_hk_changer(hk.pref, hk.cmd, hk.cur) end
        self.actions[hk.key] = action
        table.insert(hk_widgets, widgets.Label{ frame = {t = hk.t, l = 0, w = 32},
            text = { {text = dfhack.screen.getKeyDisplay(df.interface_key[hk.key]), pen = C_KEY},
                     {text = ": " .. string.format("%-10s [%s]", hk.lbl, hk.cur), pen = self.theme.SEC} },
            on_click = action })
    end

    -- ==========================================
    -- THEME COLOUR PICKERS
    -- ==========================================
    local COLOR_OPTIONS = {
        {label='Black',    value='BLACK',       pen=COLOR_BLACK},
        {label='Blue',     value='BLUE',        pen=COLOR_BLUE},
        {label='Green',    value='GREEN',       pen=COLOR_GREEN},
        {label='Cyan',     value='CYAN',        pen=COLOR_CYAN},
        {label='Red',      value='RED',         pen=COLOR_RED},
        {label='Magenta',  value='MAGENTA',     pen=COLOR_MAGENTA},
        {label='Brown',    value='BROWN',       pen=COLOR_BROWN},
        {label='Grey',     value='GREY',        pen=COLOR_GREY},
        {label='Dgrey',    value='DARKGREY',    pen=COLOR_DARKGREY},
        {label='Lblue',    value='LIGHTBLUE',   pen=COLOR_LIGHTBLUE},
        {label='Lgreen',   value='LIGHTGREEN',  pen=COLOR_LIGHTGREEN},
        {label='Lcyan',    value='LIGHTCYAN',   pen=COLOR_LIGHTCYAN},
        {label='Lred',     value='LIGHTRED',    pen=COLOR_LIGHTRED},
        {label='Lmagenta', value='LIGHTMAGENTA',pen=COLOR_LIGHTMAGENTA},
        {label='Yellow',   value='YELLOW',      pen=COLOR_YELLOW},
        {label='White',    value='WHITE',        pen=COLOR_WHITE},
    }

    local function make_color_opts()
        local opts = {}; for _, o in ipairs(COLOR_OPTIONS) do table.insert(opts, {label=o.label, value=o.value, pen=o.pen}) end; return opts
    end

    local function make_theme_picker(t_pos, key_token, label_text, pref_id, default_color)
        return make_themed_cycle(t_pos, key_token, label_text, make_color_opts(), pref_id, default_color, function(val)
            -- Deferred to next frame: dismissing the HUD from inside a click
            -- handler destroys the widget tree mid-event, which crashes the UI.
            dfhack.timeout(1, 'frames', function()
                if _G.refinish_hud_view then
                    _G.refinish_hud_restore_left = _G.refinish_hud_view.router_left:getSelected()
                    _G.refinish_hud_restore_right = _G.refinish_hud_view.router_center:getSelected()
                    _G.refinish_hud_view:dismiss()
                end
                dfhack.run_script('refinish-hud', 'show', 'config')
            end)
        end)
    end

    self.w_theme_pri = make_theme_picker(40, 'STRING_A033', 'Primary:',     'refinish_theme_pri',       'LIGHTGREEN')
    self.w_theme_sec = make_theme_picker(41, 'STRING_A064', 'Secondary:',   'refinish_theme_sec',       'LIGHTBLUE')
    self.w_theme_ter = make_theme_picker(42, 'STRING_A035', 'Tertiary:',    'refinish_theme_ter',       'CYAN')
    self.w_theme_nb  = make_theme_picker(43, 'STRING_A036', 'Neutral Bold:','refinish_theme_neutral_b', 'WHITE')
    self.w_theme_ns  = make_theme_picker(44, 'STRING_A037', 'Neutral Soft:','refinish_theme_neutral_s', 'DARKGREY')
    self.w_theme_rl  = make_theme_picker(45, 'STRING_A094', 'Caution:',     'refinish_theme_risk_l',    'YELLOW')
    self.w_theme_rm  = make_theme_picker(46, 'STRING_A038', 'Warning:',     'refinish_theme_risk_m',    'LIGHTRED')
    self.w_theme_rh  = make_theme_picker(47, 'STRING_A094', 'Danger:',      'refinish_theme_risk_h',    'RED')

    -- ==========================================
    -- TOOLTIP HELPER
    -- ==========================================
    local function bind_tooltip(target_widget, title, body)
        return widgets.TooltipLabel{ frame = {t = 2, l = 0, r = 0}, text_to_wrap = title .. "\n\n" .. body,
            text_pen = self.theme.SEC, show_tooltip = function() return target_widget:getMousePos() ~= nil end }
    end

    -- ==========================================
    -- VIEW ASSEMBLY
    -- ==========================================
    local views = {
        widgets.Label{ frame = {t = 0, l = 0}, text = "CONFIGURATION", text_pen = self.theme.PRI },
        widgets.Label{ frame = {t = 2, l = 0}, text = "SYSTEM SETTINGS", text_pen = self.theme.NEUTRAL_B },
        -- LOAD DELAY OPTION (removed): self.w_delay
        self.w_autosave, self.w_pause, self.w_save_protocol, self.w_menu,
        self.w_perf, self.w_msg, self.w_protect, self.w_poll,
        self.w_loglevel, self.btn_restore,
        widgets.Label{ frame = {t = 24, l = 0}, text = "UI NAVIGATION HOTKEYS", text_pen = self.theme.NEUTRAL_B },
    }
    for _, hw in ipairs(hk_widgets) do table.insert(views, hw) end
    table.insert(views, widgets.Label{ frame = {t = 33, l = 0}, text = "SYSTEM COMMAND HOTKEYS", text_pen = self.theme.NEUTRAL_B })
    table.insert(views, widgets.Label{ frame = {t = 39, l = 0}, text = "THEME COLOURS", text_pen = self.theme.NEUTRAL_B })
     for _, tw in ipairs({self.w_theme_pri, self.w_theme_sec, self.w_theme_ter, self.w_theme_nb, self.w_theme_ns, self.w_theme_rl, self.w_theme_rm, self.w_theme_rh}) do
        table.insert(views, tw)
    end
    table.insert(views, widgets.Panel{ frame = {t = 0, l = 34, r = 0, b = 0}, subviews = {
        widgets.Label{ frame = {t = 0, l = 0}, text = "INFORMATION", text_pen = self.theme.PRI },
        bind_tooltip(self.w_autosave, "Autosave Interval",
            "How often the mod performs a full save cycle. In-game options trigger on season/year boundaries. Real-time options use wall-clock minutes regardless of game speed. 'Off' disables automatic saves entirely; use the quicksave hotkey to save manually."),
        bind_tooltip(self.w_pause, "Pause on Autosave",
            "When enabled, the simulation is paused at the start of each autosave cycle. This prevents dwarves from starting new workshop jobs or building constructions while the RAM is being purged, eliminating a class of edge-case race conditions. Recommended: Yes."),
        bind_tooltip(self.w_save_protocol, "Save Protocol",
            "Hotsave performs a lightweight in-place cycle: purge RAM, quicksave, restore RAM. It is fast but does not write a full JSON payload to site data; finish records are held in memory only. Autosave (Legacy) performs the full JSON wash cycle used by the autosave routine, writing all finish data to disk before saving. Use Autosave if you want full payload persistence on every manual save."),
        bind_tooltip(self.w_menu, "Menu-Bound Data Cycle",
            "Controls how mod data is handled when the ESC Options menu is opened. Auto purges RAM the moment the menu opens and reloads it on close, ensuring vanilla Save and Save & Continue buttons are always safe to use. Manual leaves data loaded for faster menu performance, but requires a manual shutdown before using any vanilla save options. Recommended for large forts: Manual."),
        -- LOAD DELAY OPTION (removed). Tooltip text kept for reference;
        -- note that its advice was backwards, which is how the window
        -- stayed open as long as it did.
        -- bind_tooltip(self.w_delay, "Startup Load Delay",
        --     "Controls when mod data is injected into RAM after a map loads. '1 Tick' waits for the player to unpause the game, giving the engine time to fully settle after a heavy load. Faster options inject while the game is still paused. Non-Tick options may cause instability on large saves or heavily modded worlds and are not recommended."),
        bind_tooltip(self.w_perf, "Material Finishes",
            "When ON, the scanner generates a unique 1:1 named finish for every valid reagent in the world; e.g. 'obsidian steel', 'malachite iron'. When OFF, only condensed Colour Finishes and hardcoded Special Finishes are generated, significantly reducing the total number of injected materials and reactions. Toggling this mid-game cancels active jobs and triggers a full data cycle. Existing Material Finish data is preserved in the JSON payload and restored if the setting is turned back ON."),
        bind_tooltip(self.w_msg, "System Invasiveness",
            "Controls how the mod communicates with you during background operations. Guided shows confirmation prompts and post-cycle telemetry reports. Passive sends cycle results to the announcement log without interrupting gameplay. Silent suppresses all non-critical output. Debug adds internal timing data and diagnostic detail to every prompt and log entry."),
        bind_tooltip(self.w_protect, "Protect Base Metals",
            "When enabled, dwarves assigned a generic metal grinding job will refuse to pick up bars of any metal currently configured as an active base. The job is canceled and an announcement is generated. Finished bars of any base metal are always protected regardless of this setting."),
        bind_tooltip(self.w_loglevel, "Log Detail",
            "Controls how much the live event log DISPLAYS. The session file on disk is always fully verbose regardless of this setting, so nothing is ever lost by turning it down. Quiet shows only what pops: faults, warnings, completions and session milestones. Normal adds the ordinary activity you would come to the log with a question about. Debug adds per-item detail such as individual sprite writes."),

        bind_tooltip(self.w_poll, "Polling Rate",
            "Controls how frequently the reaction watcher and UI monitor fire. Fast (10 frames) is the most responsive but uses the most CPU. Normal (25 frames) is a good balance. Relaxed (50 frames) reduces CPU load on large forts at the cost of slightly delayed reaction detection. The calendar loop is unaffected."),
        bind_tooltip(self.btn_restore, "Restore Default Settings",
            "Resets every configuration value and all hotkey bindings to their original defaults. This includes autosave interval, save protocol, pause behavior, menu cycling, load delay, material finishes, invasiveness, base metal protection, all theme colours, and all eleven global hotkeys. A confirmation prompt will appear before any changes are applied."),
        bind_tooltip(self.w_theme_pri, "Primary Colour",
            "The dominant foreground colour. Used for panel headers, active/selected values in cycle widgets, hotkey key labels, and confirmation prompt text."),
        bind_tooltip(self.w_theme_sec, "Secondary Colour",
            "The standard body text colour. Used for list entries, cycle widget labels, button text, and most informational labels throughout the UI."),
        bind_tooltip(self.w_theme_ter, "Tertiary Colour",
            "A general-purpose accent colour. Used for DETAIL lines in the event log, the debug output shown at the Debug log level."),
        bind_tooltip(self.w_theme_nb, "Neutral Bold",
            "Used for section divider headers such as 'SYSTEM SETTINGS', 'UI NAVIGATION HOTKEYS', and 'THEME COLOURS'."),
        bind_tooltip(self.w_theme_ns, "Neutral Soft",
            "A secondary neutral used for visual separation elements, subdued dividers, and de-emphasized structural labels."),
        bind_tooltip(self.w_theme_rl, "Caution",
            "Used for low-severity alerts; confirmation prompts, advisory notices, and settings that carry a minor risk such as non-default load delay options."),
        bind_tooltip(self.w_theme_rm, "Warning",
            "Used for mid-severity notices; safety announcements, the ESC menu overlay when mod data is active, and settings that carry meaningful risk such as the Silent invasiveness mode."),
        bind_tooltip(self.w_theme_rh, "Danger",
            "Used for high-severity states; critical failures, fatal RAM errors, and the strongest safety warnings in the system. Appears in the ESC overlay when conditions for guaranteed save corruption are present."),
    }})
    self:addviews(views)
end

-- ==========================================
-- KEY INPUT HANDLER
-- ==========================================
function RefinishPanelConfig:onInput(keys)
    for _, c in ipairs(self.cycles) do if keys[c.key] then c.cycle(); return true end end
    for key_name, action in pairs(self.actions) do if keys[key_name] then action(); return true end end
    return RefinishPanelConfig.super.onInput(self, keys)
end

return _ENV