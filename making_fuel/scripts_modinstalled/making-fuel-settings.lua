--@ module = true
-- making-fuel-settings.lua
-- ==========================================
-- MAKING FUEL: PLAYER SETTINGS
-- ==========================================
-- What a player can change about Making Fuel from the RM HUD (the
-- MODULE SETTINGS page), and how each change reaches the running
-- module. RM stores the choices per fort and draws the page; this file
-- declares the settings and applies them.
--
-- ---- EVERY SETTING IS A TUNING VALUE ----
-- Each key below is a key in making-fuel-tuning's T, and the value
-- written there is the shipped default. A player's choice is written
-- over T for the loaded fort, so every script that already reads T sees
-- it with no plumbing of its own. If RM's settings store is missing or
-- refuses this spec, nothing is written and the module runs on T's
-- shipped values exactly as before.
--
-- ---- WHEN A CHANGE LANDS ----
--   now      T is read at use, so the next payout, poll or job sees it
--   restart  T is written and a subsystem is stopped or started now
--   reload   T is written only at the fort's first token call, so the
--            value a session starts with holds until the next load
--            (see FUEL_ACCESS_ENABLED for why)
--
-- ---- CHECKED SETTINGS ----
-- A setting marked check = true moves the fuel economy, so every change
-- to it runs the tuning file's own invariant checks (check(), the same
-- ones making-fuel-curve prints). A value that fails any of them is
-- refused and the reason logged. The preset lists below already pass,
-- measured; the check is there for the day the tuning file changes
-- under a stored choice.
--
-- ---- WHERE IT IS CALLED ----
--   register()   making_fuel.lua, at load, so the page exists early
--   apply_all()  making_fuel.lua, first thing in the token call, before
--                any background script starts or any job pays
-- ==========================================

local MODULE_ID = 'making_fuel'

-- ==========================================
-- LOG FUNNEL
-- ==========================================
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'SETTINGS'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

local function log(typ, msg, subject)
    if not _G.refinish_log_event then return end
    local line
    if rlog then
        line = rlog.compose(LOG_SYS, LOG_SUB, subject, typ, msg)
    else
        line = string.format('%s %s %s %s | %s', LOG_SYS, LOG_SUB,
            tostring(subject or '-'), tostring(typ or 'UNTYPED'),
            tostring(msg))
    end
    _G.refinish_log_event(line)
end

-- Guarded like every cross-file load in this module: a failure is
-- reported where it bites rather than taking this file down at load.
local tuning = nil
pcall(function() tuning = reqscript('making-fuel-tuning') end)
local cfg = nil
pcall(function() cfg = reqscript('refinish-module-config') end)

-- ==========================================
-- THE SETTINGS
-- ==========================================
-- Order is page order. Labels and option labels are held to RM's
-- limits (22 and 14 characters); RM refuses the whole spec otherwise.
--
-- A number's options are presets, never typed. `days` builds a preset
-- list of day counts with matching labels.
local function days(list)
    local out = {}
    for i, d in ipairs(list) do out[i] = { value = d, label = d .. ' days' } end
    return out
end

local SETTINGS = {
    {
        key = 'ANCHOR_YIELD', label = 'Fuel Yield', kind = 'number',
        applies = 'now', check = true,
        -- MEASURED against the tuning checks: 1.45 and up pass every
        -- one, 1.40 and below fail "retort route stays under its
        -- ceiling", because liquid fuel is measured on its own anchor
        -- and does not scale with this. At 1.0 the retort and tank route
        -- returns 1.453 of the log against a ceiling of 1.25. Hence the
        -- floor of 1.5.
        options = {
            { value = 1.5, label = '1.5' }, { value = 2.0, label = '2.0' },
            { value = 2.5, label = '2.5' }, { value = 3.0, label = '3.0' },
        },
        description = 'Charcoal from one reference log. Every solid fuel'
            .. ' yield in the module is measured against it, so this scales'
            .. ' charring, ashing and splitting together and keeps every'
            .. ' relative value intact. Liquid fuels have their own anchor'
            .. ' and do not move. Below 1.5 the retort and tank route would'
            .. ' out-pay charring the log, which the tuning checks forbid,'
            .. ' so the list starts there. Applies from the next payout.',
    },
    {
        key = 'PAY_CINDERS', label = 'Pay Cinders', kind = 'toggle',
        applies = 'now',
        description = 'On pays a cinder as soon as the bank can afford one.'
            .. ' Off pays only whole charcoal and banks everything below it.'
            .. ' Neither loses value; only the form of the payout changes.',
    },
    {
        key = 'WASTE_ENABLED', label = 'Measured Waste', kind = 'toggle',
        applies = 'now',
        description = 'On, workshop waste such as sawdust and bark is measured'
            .. ' from what each job destroys. Off returns to fixed byproduct'
            .. ' counts, as before volumes were read.',
    },
    {
        key = 'HIDE_SPOIL_DAYS', label = 'Hide Spoil Time', kind = 'number',
        applies = 'now', options = days({ 14, 21, 28, 42 }),
        description = 'Days an untanned hide or scrap lasts before it spoils.'
            .. ' A tannery working the butchery queue as it comes never sees'
            .. ' a rotten one; hides stockpiled against a later project are'
            .. ' lost. A rotten hide is later destroyed outright unless a job'
            .. ' holds it. Applies from the next daily check.',
    },
    {
        key = 'DRY_DAYS', label = 'Drying Time', kind = 'number',
        applies = 'now', options = days({ 7, 14, 21, 28 }),
        description = 'Days wet fuel (dung, mash, straw and peat) takes to'
            .. ' air dry into its dried form. Applies from the next check.',
    },
    {
        key = 'POOP_DAYS', label = 'Dung Interval', kind = 'number',
        applies = 'now', options = days({ 10, 20, 30, 40 }),
        description = 'Average days between droppings for each grazing'
            .. ' animal. At the default of 20, ten grazers make about one'
            .. ' charcoal worth of dung every 16 days and fifty about one'
            .. ' every 3. Applies from the next check.',
    },
    {
        key = 'MAX_DUNG', label = 'Dung Cap', kind = 'number',
        applies = 'now',
        options = {
            { value = 120, label = '120 piles' }, { value = 240, label = '240 piles' },
            { value = 480, label = '480 piles' },
        },
        description = 'Most dung piles allowed on the map at once. At the cap'
            .. ' animals stop dropping until some is used. Every pile is an'
            .. ' item the game tracks and a record at each save, so a high'
            .. ' cap on a big herd costs frame rate.',
    },
    {
        key = 'POOPER_ENABLED', label = 'Dung From Animals', kind = 'toggle',
        applies = 'restart', restart_note = 'The dung drops start or stop.',
        restart = 'making-fuel-pooper',
        description = 'Grazing animals drop dung, a fuel that dries into a'
            .. ' better one. Off stops new drops; dung already on the map'
            .. ' stays and burns as before.',
    },
    {
        key = 'AIR_DRY_ENABLED', label = 'Air Drying', kind = 'toggle',
        applies = 'restart', restart_note = 'Air drying starts or stops.',
        restart = 'making-fuel-air-dry',
        description = 'Wet fuel dries with time into its dried form. Off'
            .. ' leaves wet fuel wet; it still burns as wet fuel.',
    },
    {
        key = 'BRANCH_SPAWNER_ENABLED', label = 'Canopy Wood', kind = 'toggle',
        applies = 'restart', restart_note = 'Canopy drops start or stop.',
        restart = 'making-fuel-branch-spawner',
        description = 'A felled tree drops the rest of itself, limb logs and'
            .. ' branches, where vanilla pays for the trunk only. Off returns'
            .. ' felling to vanilla.',
    },
    {
        key = 'FUEL_ACCESS_ENABLED', label = 'Fuel Access', kind = 'toggle',
        applies = 'reload',
        -- Not restarted on the spot. Fuel access is woven into jobs in
        -- progress and into the liquid fuel tanks, and its start and
        -- stop are built for session boundaries: stop() deliberately
        -- settles nothing and leaves tanked jobs for the next start()
        -- to take back. Stopping it mid session with no start to
        -- follow would strand those jobs, so the change waits for the
        -- next load, where start() reads it.
        --
        -- Waits for the LOAD, not the next save. start() runs at every
        -- token call, and RM's save cycles make one, but stop() runs
        -- only at map unload. Written at once, Off would do nothing
        -- until the unload anyway, while On would start fuel access at
        -- the next save. So T is written for this setting only at the
        -- fort's first token call, and both directions wait for a load.
        description = 'On, furnaces accept any fuel in the module directly.'
            .. ' Off returns to vanilla: fuels must be charred to charcoal'
            .. ' before any furnace accepts them.',
    },
}

-- ==========================================
-- SHIPPED VALUES
-- ==========================================
-- T's values as the tuning file ships them, captured before any
-- override, so a setting can be put back to its default. Keyed by the
-- T table itself: reloading this file must not capture values already
-- overridden, while reloading the tuning file builds a new T with
-- fresh shipped values and so gets a fresh capture.
_G.making_fuel_settings_shipped = _G.making_fuel_settings_shipped
    or setmetatable({}, { __mode = 'k' })

local function shipped()
    local T = tuning and tuning.T
    if not T then return nil end
    local s = _G.making_fuel_settings_shipped[T]
    if not s then
        s = {}
        for _, def in ipairs(SETTINGS) do s[def.key] = T[def.key] end
        _G.making_fuel_settings_shipped[T] = s
    end
    return s
end

local BY_KEY = {}
for _, def in ipairs(SETTINGS) do BY_KEY[def.key] = def end

-- ==========================================
-- THE ECONOMY CHECK
-- ==========================================
-- Runs the tuning file's invariant checks against T as it stands.
-- Returns true, or false and the names of the checks that failed.
local function economy_ok()
    if not (tuning and tuning.check) then return true end
    local ok, res = pcall(tuning.check)
    if not ok then return false, 'the checks could not run: ' .. tostring(res) end
    local failed = {}
    for _, r in ipairs(res) do
        if not r.ok then failed[#failed + 1] = '"' .. tostring(r.name) .. '"' end
    end
    if #failed > 0 then return false, 'fails ' .. table.concat(failed, ', ') end
    return true
end

-- ==========================================
-- RESTARTS
-- ==========================================
-- Only while RM is running and the module's scripts are up. Otherwise
-- there is nothing to stop, and the next token call starts or skips
-- the subsystem by reading T.
local function restart(def, on)
    if not (_G.refinish_active and _G.refinish_modules_injected) then return end
    local ok, m = pcall(reqscript, def.restart)
    if not (ok and m) then
        log('ERROR', ('%s: could not load %s to %s it: %s'):format(def.label,
            def.restart, on and 'start' or 'stop', tostring(m)), def.key)
        return
    end
    local fn = on and m.start or m.stop
    if not fn then return end
    local ok_run, err = pcall(fn)
    if not ok_run then
        log('ERROR', ('%s: %s failed: %s'):format(def.label,
            on and 'start' or 'stop', tostring(err)), def.key)
    end
end

-- ==========================================
-- A CHANGE FROM THE PAGE
-- ==========================================
-- RM calls this before it stores anything. Returning false with a
-- reason refuses the change and leaves the stored value as it was.
local function on_change(key, value, old)
    local def = BY_KEY[key]
    local T = tuning and tuning.T
    if not (def and T) then return false, 'the tuning file is not loaded' end
    -- Stored by RM, read into T at the next load (see apply_all).
    if def.applies == 'reload' then return true end
    T[key] = value
    if def.check then
        local ok, why = economy_ok()
        if not ok then
            T[key] = old
            return false, why
        end
    end
    if def.restart then restart(def, value) end
    return true
end

-- ==========================================
-- PUBLIC
-- ==========================================

-- Declare the settings to RM. Called once at load by making_fuel.lua.
function register()
    if not cfg then
        log('WARNING', 'RM module settings are not available; the module runs'
            .. ' on its tuning defaults and has no settings page.', 'REGISTER')
        return false
    end
    local T = tuning and tuning.T
    local base = shipped()
    if not (T and base) then
        log('ERROR', 'making-fuel-tuning did not load; settings not registered.',
            'REGISTER')
        return false
    end
    local list = {}
    for i, def in ipairs(SETTINGS) do
        list[i] = { key = def.key, label = def.label, kind = def.kind,
                    options = def.options, default = base[def.key],
                    applies = def.applies, restart_note = def.restart_note,
                    description = def.description }
    end
    return cfg.register(MODULE_ID, { title = 'Making Fuel', settings = list,
                                     on_change = on_change })
end

-- Write this fort's choices over T. Called first thing in the token
-- call, so a new fort never runs on the last fort's values: every
-- setting is written, stored or default. A checked value that fails the
-- economy checks falls back to its shipped default, with a WARNING.
function apply_all()
    local T = tuning and tuning.T
    local base = shipped()
    if not (T and base) then return end
    -- The first token call since a load, when reload settings are read.
    -- nil at the first load after DF starts, true after every unload.
    local fresh = _G.making_fuel_settings_fresh ~= false
    _G.making_fuel_settings_fresh = false
    for _, def in ipairs(SETTINGS) do
        if def.applies ~= 'reload' or fresh then
            local v = cfg and cfg.get(MODULE_ID, def.key)
            if v == nil then v = base[def.key] end
            T[def.key] = v
        end
    end
    local ok, why = economy_ok()
    if not ok then
        for _, def in ipairs(SETTINGS) do
            if def.check then T[def.key] = base[def.key] end
        end
        local ok2, why2 = economy_ok()
        if ok2 then
            log('WARNING', 'This fort\'s economy settings ' .. why .. ' against the'
                .. ' current tuning file, so they run at their defaults. Choose'
                .. ' again on the Module Settings page.', 'APPLY')
        else
            -- Not the player's choice: the shipped values fail too.
            log('ERROR', 'The tuning file ' .. why2 .. ' at its own defaults.'
                .. ' Run making-fuel-curve for the numbers.', 'APPLY')
        end
    end
    -- What T holds now, after any fallback above, not what was asked.
    local changed = {}
    for _, def in ipairs(SETTINGS) do
        if T[def.key] ~= base[def.key] then
            changed[#changed + 1] = def.key .. '=' .. tostring(T[def.key])
        end
    end
    log('DETAIL', (#changed > 0) and ('In force: ' .. table.concat(changed, ', ')
        .. '.') or 'All settings at their defaults.', 'APPLY')
end

-- A map unload ends the session: the next token call is a load, and
-- reads the reload settings again. Keyed so a reload of this file
-- replaces the handler rather than stacking a second one.
dfhack.onStateChange.making_fuel_settings = function(code)
    if code == SC_MAP_UNLOADED then _G.making_fuel_settings_fresh = true end
end

-- True unless the setting is explicitly off. For the start gates in
-- making_fuel.lua, which read after apply_all has run.
function is_on(key)
    local T = tuning and tuning.T
    return not (T and T[key] == false)
end

return _ENV
