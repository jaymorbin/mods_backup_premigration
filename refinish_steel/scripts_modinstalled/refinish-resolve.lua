-- refinish-resolve.lua
-- ==========================================
-- SCRIPT LOGIC: REFINISH RESOLVE
-- ==========================================
-- One place to turn a material TOKEN or an itemdef CODE into the
-- number the engine wants, under one invalidation rule.
--
-- ---- WHY THIS EXISTS ----
-- Five scripts each carried their own version of this: a
-- matinfo.find on every use, or a walk of world.raws.itemdefs.tools
-- that tostring'd every definition it passed. Two of them ran it
-- once per frame, which was part of the 885 ms/sec the profiler
-- measured before the rot and cremate hotfix.
--
-- ---- WHY A NUMBER CANNOT BE CACHED FOREVER ----
-- Injected materials and itemdefs are appended at startup and
-- removed again on the save protocol, so a number cached before a
-- clear points at whatever has since moved into that slot.
--
-- A STALE HIT LOOKS EXACTLY LIKE A GOOD ONE. The miss branch only
-- fires when a token is ABSENT, never when a cached number is wrong.
-- Same failure shape as the ghost reaction use after free and the
-- itemdef cache staleness that refinish-module-react already
-- documents.
--
-- ---- SO INVALIDATION IS A HANDSHAKE, NOT A GUESS ----
-- Anything that adds or removes assets raises a global, and every
-- lookup checks it first for the price of one table read.
--
-- THIS IS DELIBERATELY NOT AN EPOCH COMPARED AGAINST
-- _G.refinish_ram_loaded. That flag is a BOOLEAN. A script whose
-- poll is gated on _G.refinish_active never observes the false
-- window during a wash, so it reads true before the cycle and true
-- after it and concludes nothing changed, keeping a stale index.
-- The first version of the rot and cremate hotfix did exactly that.
-- A dirty flag has no such blind spot, because the party that
-- invalidates is the party that changed something.
--
-- ---- A MISS IS NEVER CACHED ----
-- Injection lands after the module scripts start, so a stored nil
-- would defer forever. Only hits are kept.
--
-- ---- NO DF POINTER IS RETAINED ----
-- material() answers with a plain Lua table of numbers, not the
-- matinfo object, because matinfo carries a pointer to the material
-- struct and holding one across a clear is the use after free this
-- file exists to prevent.
-- ==========================================

--@ module = true

-- token -> { type = <mat_type>, index = <mat_index> }
local mat_cache = {}

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
-- SUBJECT is the correlation slot: the step or thing a line is
-- about. Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- Console prints only where they answer a typed command. A print only
-- appears as the direct answer to a command typed into the DFHack
-- console, and nowhere else. The CONSOLE section at the bottom is
-- exactly that, so its prints stay.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'RESOLVE'
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
-- INVALIDATION
-- ==========================================
-- Raised by whoever injects or clears; lowered here on the next
-- lookup. Two globals rather than one because the itemdef cache
-- lives in refinish-module-react and already has its own handshake
-- with the tool injector. Materials get the matching one.
local function check_dirty()
    if _G.refinish_material_cache_dirty then
        mat_cache = {}
        _G.refinish_material_cache_dirty = false
    end
end

-- Drops everything this file knows and asks module-react to drop the
-- itemdef side too. Call after any change to injected assets that
-- does not already raise the globals.
function invalidate()
    mat_cache = {}
    _G.refinish_material_cache_dirty = false
    _G.refinish_itemdef_cache_dirty = true
    log('DETAIL', 'Caches dropped.', 'CACHE')
end

-- ==========================================
-- MATERIALS
-- ==========================================
-- token is the FULL token, because callers do not agree on the
-- branch: the key watchers ask INORGANIC:X and the coal watcher asks
-- a plant host. Prefixing here would hide that difference and get
-- one of them wrong.
--
-- Returns { type = n, index = n } or nil.
function material(token)
    check_dirty()

    local hit = mat_cache[token]
    if hit then return hit end

    local mi = nil
    pcall(function() mi = dfhack.matinfo.find(token) end)
    if not mi then return nil end

    -- Copied out of the matinfo immediately. See NO DF POINTER above.
    local rec = { type = mi.type, index = mi.index }
    mat_cache[token] = rec
    return rec
end

-- The common case by a wide margin: callers compare against an
-- item's mat_index and test mat_type separately.
function material_index(token)
    local rec = material(token)
    return rec and rec.index or nil
end

-- ==========================================
-- ITEMDEFS
-- ==========================================
-- Delegated rather than duplicated. refinish-module-react owns the
-- itemdef cache, the tool injector already calls its invalidator on
-- both ends of every injection and every clear, and a second cache
-- of the same thing would be a second thing to keep correct.
--
-- QUIET. The react resolver logs "slot left unrestricted" on a miss,
-- which is true when it is building a reagent and nonsense when a
-- key watcher is simply polling before injection has landed. The
-- quiet flag suppresses that line; the caller says its own piece
-- once through its own state logging.
--
-- Returns the subtype integer, or nil when absent. react answers -1
-- for absent, which is a valid-looking number in the wrong hands.
-- ---- ONE TABLE READ ON THE NORMAL PATH ----
-- This is called once per poll by watchers running at one frame, so
-- what it costs is multiplied by the frame rate. The first version
-- called reqscript here, which is a script name resolution and
-- therefore filesystem work: about 2 ms a call, 407 ms of every wall
-- second once two watchers were doing it.
--
-- module-react publishes its resolver on load, so the steady state
-- is reading one global. reqscript survives only as the cold start
-- path, for the window before module-react has been loaded at all,
-- and it stops being taken the moment it succeeds once.
--
-- No closure is built for the pcall either. pcall(fn, args) passes
-- the arguments straight through; wrapping it in an anonymous
-- function allocates one per call for nothing.
function tool_subtype(code, item_type)
    local fn = _G.refinish_resolve_tool_subtype

    if not fn then
        -- Cold start. Loading module-react is what publishes the
        -- global, so this is asked for once and then never again.
        pcall(reqscript, 'refinish-module-react')
        fn = _G.refinish_resolve_tool_subtype
        if not fn then return nil end
    end

    local ok, sub = pcall(fn, code, item_type, true)
    if not ok or type(sub) ~= 'number' or sub < 0 then return nil end
    return sub
end

-- ==========================================
-- CONSOLE
-- ==========================================
local args = {...}
if args[1] == 'test' and args[2] then
    local rec = material(args[2])
    if rec then
        print(('%s -> type %d index %d'):format(args[2], rec.type, rec.index))
    else
        print(('%s -> not found'):format(args[2]))
    end
elseif args[1] == 'tool' and args[2] then
    print(('%s -> subtype %s'):format(args[2], tostring(tool_subtype(args[2]))))
elseif args[1] == 'invalidate' then
    invalidate()
    print('refinish-resolve: caches dropped.')
elseif args[1] then
    print('refinish-resolve: test <TOKEN> | tool <CODE> | invalidate')
end

return _ENV