--@ module = true
-- refinish-module-config.lua
-- ==========================================
-- MODULE SETTINGS: REGISTRY, CHECKS, STORE, READS AND CHANGES
-- ==========================================
-- A module that wants settings on the RM HUD declares them here, and RM
-- does the rest: it checks the declaration against RM's limits, keeps
-- the chosen values for each fort, hands them back cheaply, and draws
-- the page (refinish-panel-modules). The module never builds UI and RM
-- never decides what a module's setting means.
--
-- ---- WHO DOES WHAT ----
--   RM      checks the spec, stores values per fort in site data, reads
--           them back, cycles them from the HUD, logs every change.
--   module  declares the spec, reads each value where it uses it, and
--           applies a change through its on_change hook, which may
--           refuse one with a reason.
--
-- ---- THE SPEC ----
--   register(module_id, {
--       title     = 'Making Fuel',      -- page section heading
--       on_change = function(key, value, old) ... end,  -- optional
--       settings  = {
--           { key = 'ANCHOR_YIELD', label = 'Fuel Yield',
--             kind = 'number',          -- 'toggle', 'choice' or 'number'
--             options = { { value = 1.5, label = '1.5' }, ... },
--             default = 2.0,
--             applies = 'now',          -- 'now', 'restart' or 'reload'
--             restart_note = '...',     -- required when 'restart', shown
--                                       -- on the page: what starts or stops
--             description = '...' },
--       },
--   })
--
-- A toggle may leave out options: it gets On (true) and Off (false).
-- A number is chosen from a preset list, never typed, so there is
-- nothing to parse and a module author can run their own checks over
-- every value the page can produce before shipping it.
--
-- ---- WHEN A CHANGE LANDS ----
-- RM does not act on applies; the module's hook does. It is what the
-- page tells the player:
--   now      the module reads the value at use
--   restart  the module stops or starts part of itself on the spot
--   reload   it takes effect the next time the fort loads
--
-- ---- A CHANGE ----
-- set() checks the value is one of the setting's options, offers it to
-- the module's on_change, and stores it only if the hook accepts. A hook
-- that returns false (and a reason) refuses: nothing is stored and the
-- reason is logged. A hook that throws is logged as an ERROR and the
-- value is not stored either.
--
-- ---- A BAD SPEC ----
-- RM is always compatible. A spec that breaks a limit is refused whole,
-- with an ERROR naming the first problem, and the module is left to run
-- on its own defaults. get() answers nil for a refused module, so a
-- module must treat nil as "use your default".
--
-- ---- STORAGE ----
-- One site data table per module, 'refinish_module_config_<id>', so the
-- values belong to the fort, like RM's own settings. Only values the
-- player has chosen are stored; everything else reads as its default,
-- so a module that ships a new default moves every fort that never
-- touched the setting.
-- ==========================================

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body. SUBJECT
-- is the module the line is about, so one module's settings history
-- lines up in the SUBJECT column.
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'MODULE_CONFIG'
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

-- ==========================================
-- LIMITS
-- ==========================================
-- What a module may ask for. Sized to the HUD page: a label and a value
-- label side by side in the list column, the description wrapped in
-- the information column beside it.
local LIMITS = {
    SETTINGS     = 16,    -- settings per module
    TITLE        = 24,    -- section heading
    KEY          = 32,    -- setting key
    LABEL        = 22,    -- setting label
    OPTIONS      = 12,    -- options per setting
    OPTION_LABEL = 14,    -- option label
    DESCRIPTION  = 600,   -- description
    RESTART_NOTE = 48,    -- what a restart setting restarts
}
local KINDS   = { toggle = true, choice = true, number = true }
local APPLIES = { now = true, restart = true, reload = true }

-- ==========================================
-- STATE
-- ==========================================
-- In _G so a reload of this file keeps every registration: modules
-- register once, at their own load, and would not do it again.
--   refinish_module_configs       module id -> accepted spec, normalised
--   refinish_module_config_cache  module id -> stored values, for the
--                                 loaded fort only (see values_for)
--   refinish_module_config_refused  module id -> why its spec was refused
_G.refinish_module_configs = _G.refinish_module_configs or {}

-- ---- A REFUSAL IS KEPT, NOT ONLY LOGGED ----
-- Modules register at their own load, which can come before RM's log is
-- up, and a log line with nowhere to go is a silent failure. So the
-- reason is held here too and the settings page shows it in place of
-- the module's settings.
_G.refinish_module_config_refused = _G.refinish_module_config_refused or {}

-- Once-per-session guard for a stored value that is no longer one of
-- its setting's options. Keyed 'module_id:KEY'.
local stale_said = {}

-- ==========================================
-- VALIDATION
-- ==========================================
-- Returns the normalised spec, or nil and the first problem found. The
-- normalised copy is what RM keeps: the module's own table is never
-- held, so a module editing its table later cannot bypass the checks.
local function text_ok(v, max)
    return type(v) == 'string' and #v > 0 and #v <= max
end

local function validate(module_id, spec)
    if not text_ok(module_id, 48) or not module_id:match('^[%w_]+$') then
        return nil, 'module id must be 1 to 48 letters, digits or underscores'
    end
    if type(spec) ~= 'table' then return nil, 'the spec is not a table' end
    if not text_ok(spec.title, LIMITS.TITLE) then
        return nil, ('title must be text of 1 to %d characters'):format(LIMITS.TITLE)
    end
    if spec.on_change ~= nil and type(spec.on_change) ~= 'function' then
        return nil, 'on_change must be a function'
    end
    local list = spec.settings
    if type(list) ~= 'table' or #list == 0 then
        return nil, 'settings must be a non-empty list'
    end
    if #list > LIMITS.SETTINGS then
        return nil, ('%d settings asked for, the limit is %d'):format(#list, LIMITS.SETTINGS)
    end

    local out = { id = module_id, title = spec.title, on_change = spec.on_change,
                  settings = {}, by_key = {} }
    for i, s in ipairs(list) do
        local where = ('setting %d'):format(i)
        if type(s) ~= 'table' then return nil, where .. ' is not a table' end
        if type(s.key) ~= 'string' or #s.key > LIMITS.KEY
           or not s.key:match('^[A-Z][A-Z0-9_]*$') then
            return nil, where .. (': key must be UPPER_CASE, at most %d characters')
                :format(LIMITS.KEY)
        end
        where = s.key
        if out.by_key[s.key] then return nil, where .. ' is declared twice' end
        if not text_ok(s.label, LIMITS.LABEL) then
            return nil, where .. (': label must be text of 1 to %d characters')
                :format(LIMITS.LABEL)
        end
        if not text_ok(s.description, LIMITS.DESCRIPTION) then
            return nil, where .. (': description must be text of 1 to %d characters')
                :format(LIMITS.DESCRIPTION)
        end
        if not KINDS[s.kind] then
            return nil, where .. ': kind must be toggle, choice or number'
        end
        local applies = s.applies or 'now'
        if not APPLIES[applies] then
            return nil, where .. ': applies must be now, restart or reload'
        end
        if applies == 'restart' and not text_ok(s.restart_note, LIMITS.RESTART_NOTE) then
            return nil, where .. (': a restart setting needs a restart_note of 1 to %d'
                .. ' characters saying what restarts'):format(LIMITS.RESTART_NOTE)
        end

        -- ---- OPTIONS ----
        -- A toggle without options gets On and Off. Everything else
        -- brings its own list, and every value in it must be of the
        -- kind's type, unique, and labelled.
        local opts = s.options
        if s.kind == 'toggle' and opts == nil then
            opts = { { value = true, label = 'On' }, { value = false, label = 'Off' } }
        end
        if type(opts) ~= 'table' or #opts < 2 or #opts > LIMITS.OPTIONS then
            return nil, where .. (': options must list 2 to %d choices'):format(LIMITS.OPTIONS)
        end
        local want = ({ toggle = 'boolean', choice = 'string', number = 'number' })[s.kind]
        local norm, valid = {}, {}
        for j, o in ipairs(opts) do
            if type(o) ~= 'table' or type(o.value) ~= want then
                return nil, where .. (': option %d must have a %s value'):format(j, want)
            end
            if not text_ok(o.label, LIMITS.OPTION_LABEL) then
                return nil, where .. (': option %d label must be text of 1 to %d characters')
                    :format(j, LIMITS.OPTION_LABEL)
            end
            if valid[o.value] ~= nil then
                return nil, where .. (': option value %s is listed twice'):format(tostring(o.value))
            end
            valid[o.value] = j
            norm[j] = { value = o.value, label = o.label }
        end
        if s.default == nil or valid[s.default] == nil then
            return nil, where .. ': default must be one of its options'
        end

        local ns = { key = s.key, label = s.label, description = s.description,
                     kind = s.kind, applies = applies, restart_note = s.restart_note,
                     options = norm, index = valid, default = s.default }
        out.settings[i] = ns
        out.by_key[s.key] = ns
    end
    return out
end

-- ==========================================
-- STORE
-- ==========================================
-- Site data belongs to the loaded fort, so values are read per fort and
-- cached until the map changes. getSiteData hands back a copy each
-- call, which is why the cache exists: get() runs on module poll paths.
local function store_key(module_id)
    return 'refinish_module_config_' .. module_id
end

local function values_for(module_id)
    if not dfhack.isMapLoaded() then return nil end
    local cache = _G.refinish_module_config_cache
    if not cache then
        cache = {}
        _G.refinish_module_config_cache = cache
    end
    local vals = cache[module_id]
    if vals then return vals end
    local ok, t = pcall(dfhack.persistent.getSiteData, store_key(module_id), {})
    vals = (ok and type(t) == 'table') and t or {}
    cache[module_id] = vals
    return vals
end

-- A new fort is a new set of values. Keyed so a reload of this file
-- replaces the handler rather than stacking a second one.
dfhack.onStateChange.refinish_module_config = function(code)
    if code == SC_MAP_LOADED or code == SC_MAP_UNLOADED then
        _G.refinish_module_config_cache = nil
        stale_said = {}
    end
end

-- ==========================================
-- PUBLIC API
-- ==========================================

-- Called by a module at its own load. Returns true, or false and the
-- problem. A module registering again replaces its earlier spec.
function register(module_id, spec)
    local built, err = validate(module_id, spec)
    if not built then
        local id = tostring(module_id)
        _G.refinish_module_configs[id] = nil
        _G.refinish_module_config_refused[id] = { title =
            (type(spec) == 'table' and type(spec.title) == 'string') and spec.title or id,
            reason = err }
        log('ERROR', 'Settings refused: ' .. err .. '. The module runs on its'
            .. ' own defaults and gets no settings page.', id)
        return false, err
    end
    _G.refinish_module_configs[module_id] = built
    _G.refinish_module_config_refused[module_id] = nil
    log('DETAIL', ('%d setting(s) registered for the HUD.'):format(#built.settings),
        module_id)
    return true
end

-- The value in force for this fort: the stored choice, or the default.
-- nil for a module or key RM does not hold, which the caller reads as
-- "use your own default". A stored value that is no longer an option,
-- because a module update changed its list, reads as the default and
-- says so once.
function get(module_id, key)
    local spec = _G.refinish_module_configs[module_id]
    local s = spec and spec.by_key[key]
    if not s then return nil end
    local vals = values_for(module_id)
    local v = vals and vals[key]
    if v == nil then return s.default end
    if s.index[v] == nil then
        local tag = module_id .. ':' .. key
        if not stale_said[tag] then
            stale_said[tag] = true
            log('WARNING', ('%s: the stored %s is no longer one of its options;'
                .. ' using the default.'):format(s.label, tostring(v)), module_id)
        end
        return s.default
    end
    return v
end

-- The label of the value in force, for the page.
function label_of(module_id, key)
    local spec = _G.refinish_module_configs[module_id]
    local s = spec and spec.by_key[key]
    if not s then return '?' end
    local i = s.index[get(module_id, key)]
    return i and s.options[i].label or '?'
end

-- Change one setting. Returns true, or false and a reason.
function set(module_id, key, value)
    local spec = _G.refinish_module_configs[module_id]
    local s = spec and spec.by_key[key]
    if not s then return false, 'no such setting' end
    if s.index[value] == nil then return false, 'not one of its options' end
    local vals = values_for(module_id)
    if not vals then return false, 'no fort is loaded' end
    local old = get(module_id, key)
    if value == old then return true end
    local new_label = s.options[s.index[value]].label

    -- ---- THE MODULE'S SAY ----
    -- Offered before anything is stored, so a refusal leaves the store
    -- and the module agreeing with each other.
    if spec.on_change then
        local ok, accepted, reason = pcall(spec.on_change, key, value, old)
        if not ok then
            log('ERROR', ('%s: changing it to %s failed in the module: %s'):format(
                s.label, new_label, tostring(accepted)), module_id)
            return false, 'the module failed to apply it'
        end
        if accepted == false then
            log('WARNING', ('%s stays %s: %s'):format(s.label,
                s.options[s.index[old]].label, tostring(reason or 'refused by the module')),
                module_id)
            return false, reason
        end
    end

    vals[key] = value
    local ok_save, err = pcall(dfhack.persistent.saveSiteData, store_key(module_id), vals)
    if not ok_save then
        log('ERROR', ('%s: set to %s but could not be saved: %s'):format(
            s.label, new_label, tostring(err)), module_id)
        return false, 'not saved'
    end
    -- A reload setting says when it lands; the others have landed.
    local when = (s.applies == 'reload')
        and ' Takes effect the next time this fort loads.' or ''
    log('INFO', ('%s set to %s.%s'):format(s.label, new_label, when), module_id)
    return true
end

-- Step one setting to its next option, or its previous with step -1,
-- wrapping at either end. What the HUD calls on Enter and click.
function cycle(module_id, key, step)
    local spec = _G.refinish_module_configs[module_id]
    local s = spec and spec.by_key[key]
    if not s then return false, 'no such setting' end
    local i = s.index[get(module_id, key)] or 1
    local n = #s.options
    local j = ((i - 1 + (step or 1)) % n) + 1
    return set(module_id, key, s.options[j].value)
end

-- Every accepted spec, sorted by title, for the page.
function list()
    local out = {}
    for _, spec in pairs(_G.refinish_module_configs) do out[#out + 1] = spec end
    table.sort(out, function(a, b) return a.title < b.title end)
    return out
end

-- Every refused spec, as { id, title, reason }, sorted by title, so the
-- page can show why a module has no settings.
function refused()
    local out = {}
    for id, r in pairs(_G.refinish_module_config_refused) do
        out[#out + 1] = { id = id, title = r.title, reason = r.reason }
    end
    table.sort(out, function(a, b) return a.title < b.title end)
    return out
end

return _ENV
