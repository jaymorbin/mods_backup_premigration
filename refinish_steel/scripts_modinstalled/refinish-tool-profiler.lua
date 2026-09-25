--@ module = true
-- refinish-tool-profiler.lua
-- ==========================================
-- SCRIPT LOGIC: REFINISH PROFILER (v7, TWO MECHANISMS, ALWAYS ON)
-- ==========================================
-- RM's loop profiler. Times every scheduled Lua loop in the session
-- and reports milliseconds per wall second per loop, so the frame
-- budget is a measurement rather than an argument.
--
-- Two ways to run it:
--
--   LIVE, always on. refinish_steel starts it at map load and the map
--   unload stops it. It times every scheduled loop in the session, RM's,
--   its modules' and any other mod's, and the telemetry panel reads a
--   rolling one minute window from it. Nothing is logged on a timer.
--   See LIVE MODE below.
--
--   A FIXED WINDOW, by hand. `arm` zeroes the counters and starts a
--   window that runs until `report` prints it. With live mode on it
--   times nothing extra, since live mode already times everything; it
--   only gives a clean start. A map unload disarms it automatically.
--
-- ---- WHAT EACH VERSION GOT WRONG, SO IT STAYS FIXED ----
--
-- v1 replaced repeat-util's scheduleEvery and relied on the module
-- being restarted so its loops would re-register through the
-- replacement. There is no such restart: making_fuel.lua takes no
-- arguments, and its loops start inside run_module_pipeline() at map
-- load. Nothing re-registered, so nothing was timed.
--
-- v2 adopted live timers instead, which is the right mechanism, but
-- it read v1's leftover state out of _G and assumed its own field
-- shape. v1 wrote {calls, ms, max_ms, rebinds}; v2 wanted `adopts`,
-- found nil, and threw. v3 makes state shape a non-issue: slot()
-- backfills any missing field, and a state block from another
-- version is retired rather than inherited.
--
-- v2 also had two latent faults worth naming, both fixed here:
--   ORPHANED COUNTERS. Each wrapper captured its stats table, so
--   wiping stats left live wrappers counting into tables nobody
--   read. Counters are now looked up BY NAME at fire time, so a
--   wipe can never silently undercount.
--   DOUBLE WRAPPING. reset() cleared the wrapper registry while the
--   wrappers were still installed, so the next adopt would wrap a
--   wrapper and count every fire twice. Every wrapper is now
--   recorded in an identity set and is never wrapped again.
--
-- v3 measured only repeat-util loops. RM CORE DOES NOT USE
-- repeat-util: refinish_steel.lua, refinish-module-inject-building
-- and refinish-menu-icons all self chain raw dfhack.timeout, which
-- never appears in repeat-util's registry. So RM's own load was
-- invisible to the probe, which is why not one refinish key showed
-- up in a 32 row status listing. v4 adds that second mechanism.
--
-- ---- HOW IT WORKS: TWO MECHANISMS ----
--
-- MECHANISM 1, ADOPTION, for repeat-util loops.
-- dfhack.timeout_active(id, new_callback) replaces a live timer's
-- callback, so a loop scheduled minutes ago at map load can be
-- wrapped right now: no restart, no recycle, no ordering rules.
--
-- MECHANISM 2, INTERCEPTION, for self chaining dfhack.timeout loops.
-- There is no registry to walk, so dfhack.timeout itself is wrapped.
-- A self chaining loop re-registers on every fire, so it is caught
-- on its next iteration and stays caught. Rows are named by where
-- the callback is DEFINED, as t:<file>:<line>, because these loops
-- have no keys to be named by.
--
-- THE TWO MUST NOT OVERLAP. repeat-util registers through
-- dfhack.timeout as well, so a repeat-util loop would be counted by
-- both. Mechanism 2 therefore skips any registration whose CALLER is
-- repeat-util, leaving those to adoption. If that skip ever fails a
-- t:repeat-util.lua row appears in the report, which is the tell.
--
-- USAGE (console), with the fort running:
--   refinish-tool-profiler arm      adopt every live loop, start window
--   refinish-tool-profiler status   what was found and adopted
--   ...let the fort run UNPAUSED for 30+ seconds...
--   refinish-tool-profiler report   the table, sorted by cost
--   refinish-tool-profiler reset    zero counters, stay adopted
--   refinish-tool-profiler disarm   hand every loop back
--   refinish-tool-profiler live     the live window, as the panel shows it
--   refinish-tool-profiler live on | off
--
-- The report goes to the console AND to RM's log, so a run survives
-- the console scrollback and can be read back in the log panel.
--
-- ---- WHAT IT CANNOT SEE ----
-- Scheduled Lua only. Eventful hooks are diffed by EventManager on
-- the C++ side and cost nothing this can attribute; overlay widgets
-- run on the render path, not a timer; and DF's own simulation is
-- invisible to it. A loop absent from the report is not proof of an
-- idle mod, only of a mod that schedules nothing.
--
-- WHAT THE TIME INCLUDES. The adopted callback is repeat-util's own
-- repeating helper, so each sample covers the poll body plus one
-- dfhack.timeout re-registration. That overhead is a rounding error
-- next to the loops this exists to weigh, and counting it is the
-- honest choice: it is real cost the loop imposes.
--
-- RESOLUTION. dfhack.getTickCount() is milliseconds. A loop whose
-- calls all read 0 costs under 1 ms each; the report's bound column
-- prints the most such a loop could still be hiding.
-- ==========================================

local repeatUtil = require('repeat-util')

local VERSION = 7

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body.
--
-- The panel filters on TYPE and nothing else, so each call site states
-- its own:
--   DETAIL   debugging material, shown in Debug only
--   INFO     what a player might check during play, Normal and up
--   faults, and the few confirmations a player wants at a glance
--   (COMPLETE, SYSTEM, ONLINE and the like), show in Quiet as well
-- TYPE comes first so no call site can drop it unnoticed: a nil TYPE
-- still renders, as UNTYPED, which shows at every Log Detail level
-- instead of being guessed at.
--
-- SUBJECT is the correlation slot: the command a line answers (ARM,
-- DISARM, RESET, STATUS, REPORT, LIVE), or ADOPT, TIMEOUT, REGISTRY
-- and VERSION for what went on inside one.
--
-- This replaces a log() that let refinish-log guess TYPE from the
-- words (read_type) and printed every line, including the two that
-- run when nobody typed anything (see answer below).
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'PROFILER'
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

-- ---- THE ANSWER TO A TYPED COMMAND ----
-- Every command here is typed at the console, so its answer is printed
-- there: that print is the direct response to what was typed. It is
-- logged as well, because everything goes in the log, and the log is
-- still readable after a recycle, which is the point of keeping a
-- before and an after.
--
-- Some lines run when nobody typed anything, and those use log() alone:
-- an adoption failure in the sweep or the live sampler, the disarm at
-- map unload, and live mode starting and stopping with the map.
local function answer(typ, msg, subject)
    print(LOG_SUB .. ': ' .. tostring(msg))
    log(typ, msg, subject)
end

-- Report rows. Console for reading now, log for reading after a
-- recycle. DETAIL with REPORT as the subject, because a table row is
-- not a message and should be visually separable from one.
local function emit(line)
    print(line)
    log('DETAIL', line, 'REPORT')
end

-- ==========================================
-- STATE
-- ==========================================
-- Lives in _G so adoptions and counters survive re-running this
-- script. Wall clock based, so a reload mid window just keeps
-- accumulating.
--
--   stats       repeat key -> {calls, ms, max_ms, adopts}
--   wrappers    repeat key -> the timing function installed for it
--   is_wrapper  wrapper function -> repeat key (identity set)
--   origins     repeat key -> the callback displaced, for disarm
--   reg         repeat-util's live timer registry, once found
--   live        live mode on (see LIVE MODE)
--   real_timeout  the dfhack.timeout the interception wraps, while it is
--                 installed
--   patch_fn    the interception itself, to know whether it is still
--               the one standing before taking it out
--   ring        live mode's snapshots, oldest first
--   adopt_warned  repeat key -> true, an adoption failure already logged
_G.refinish_perf_probe = _G.refinish_perf_probe or {}
local P = _G.refinish_perf_probe

-- ---- RETIRING AN OLDER STATE BLOCK ----
-- A state block written by another version may hold rows in a shape
-- this build does not understand, and mixing its numbers into a new
-- report would be worse than losing them. Counters go; the wrapper
-- identity set is KEPT, because those wrappers are still installed
-- on live timers and forgetting them is what causes double wrapping.
if P.version ~= VERSION then
    -- Printed only when typed. As a module (refinish_steel at map load,
    -- the telemetry panel) nobody is at the console, so it logs alone.
    local say = (dfhack_flags and dfhack_flags.module) and log or answer
    if P.orig then
        -- v1 left its replacement on scheduleEvery. Left there it
        -- would wrap future registrations and double count them
        -- against adoption, so it goes back first.
        repeatUtil.scheduleEvery = P.orig
        P.orig = nil
        say('INFO', 'v1 scheduleEvery patch found and removed.', 'VERSION')
    end
    if P.stats and next(P.stats) then
        say('INFO', ('state from an older probe version retired (%d row(s)'
            .. ' dropped).'):format((function()
                local n = 0
                for _ in pairs(P.stats) do n = n + 1 end
                return n
            end)()), 'VERSION')
    end
    P.stats = {}
    P.t0 = nil
    P.version = VERSION
end

P.stats      = P.stats      or {}
P.wrappers   = P.wrappers   or {}
P.is_wrapper = P.is_wrapper or {}
P.origins    = P.origins    or {}
P.armed      = P.armed      or false
P.reg        = P.reg        or nil
P.sweep_id   = P.sweep_id   or nil
P.t0         = P.t0         or nil
P.live       = P.live       or false
P.patch_fn   = P.patch_fn   or nil
P.icpt_inner = P.icpt_inner or {}

-- ---- WHAT EACH INTERCEPTION WRAPPER WRAPS ----
-- Interception wrapper -> the callback inside it, so adoption can take
-- the callback itself. Weak keys, like the identity set, so a wrapper
-- on no timer is let go.
setmetatable(P.icpt_inner, { __mode = 'k' })
P.live_id    = P.live_id    or nil
P.ring       = P.ring       or {}
P.adopt_warned = P.adopt_warned or {}

-- ---- WEAK KEYS ON THE IDENTITY SET ----
-- Live mode stays on for a whole session, and a loop that a save cycle
-- stops and restarts is adopted again with a fresh wrapper each time.
-- The old wrapper is on no timer and in no other table, so weak keys
-- let it go instead of piling up. An installed wrapper is held by the
-- timer itself and by P.wrappers, so it is never collected while it
-- can still fire, and the double wrapping guard still sees it.
setmetatable(P.is_wrapper, { __mode = 'k' })

-- Returns the counter row for a key, creating it if absent and
-- BACKFILLING any field it is missing. The backfill is why a shape
-- change can never throw again: a row from any version is repaired
-- on first touch rather than trusted.
local function slot(key)
    local s = P.stats[key]
    if not s then
        s = {}
        P.stats[key] = s
    end
    s.calls  = s.calls  or 0
    s.ms     = s.ms     or 0
    s.max_ms = s.max_ms or 0
    s.adopts = s.adopts or 0
    return s
end

local function count(t)
    local n = 0
    if t then for _ in pairs(t) do n = n + 1 end end
    return n
end

-- ==========================================
-- FINDING THE REGISTRY
-- ==========================================
-- repeat-util keeps its live timers in a table inside its module,
-- mapping repeat key to timer id. The field name is not documented
-- anywhere in the DFHack docs bundled with this project, so it is
-- DISCOVERED rather than assumed: walk the module's own fields and
-- accept the first table whose string keys hold values that
-- dfhack.timeout_active resolves to a live function. That test is
-- the definition of a timer id, so a false positive would have to
-- be a table of live timer ids, which is the thing being looked for.
local function find_registry()
    if P.reg then return P.reg end
    for _, v in pairs(repeatUtil) do
        if type(v) == 'table' then
            for k, id in pairs(v) do
                if type(k) == 'string'
                   and type(dfhack.timeout_active(id)) == 'function' then
                    P.reg = v
                    return v
                end
            end
        end
    end
    return nil
end

-- ==========================================
-- ADOPTION
-- ==========================================
-- Install a timing wrapper as the live callback for one repeat key.
--
-- THE RE-ADOPT IS THE WHOLE TRICK. repeat-util's helper reschedules
-- itself on every fire, and the new timer carries the ORIGINAL
-- helper as its callback, not ours. So after calling it, the key's
-- new id is looked up and the wrapper installed again. Miss this
-- and the probe times exactly one fire per loop, then goes quiet.
-- If a report ever shows every row at calls=1, this is the line
-- that stopped working.
local function adopt(name)
    local reg = P.reg
    if not reg then return false end

    local id = reg[name]
    local cb = dfhack.timeout_active(id)
    if type(cb) ~= 'function' then return false end

    -- Already one of ours, possibly installed by an earlier run of
    -- this script. Re-point the name at it and stop: wrapping a
    -- wrapper counts every fire twice and nests the timing.
    if P.is_wrapper[cb] then
        P.wrappers[name] = cb
        return false
    end

    -- ---- AN INTERCEPTED FIRST REGISTRATION ----
    -- With the interception in from map load, a repeat-util loop
    -- scheduled later passes through it once. The caller check should
    -- recognise repeat-util and let it by; if it ever does not, the
    -- timer holds an interception wrapper, and adopting that would time
    -- every fire twice, once by each mechanism. So adoption takes the
    -- callback from inside it, and the loop is timed once, here.
    cb = P.icpt_inner[cb] or cb

    slot(name).adopts = slot(name).adopts + 1
    P.origins[name] = cb

    local w
    w = function()
        -- Looked up by NAME, not captured. A counter wipe therefore
        -- cannot orphan this wrapper's numbers.
        local s = slot(name)

        local t = dfhack.getTickCount()
        -- pcall so a throwing poll still gets its time booked and
        -- still gets re-adopted; the error is rethrown below so
        -- repeat-util sees exactly what it would have seen without
        -- the probe in the way.
        local ok, err = pcall(cb)
        local dt = dfhack.getTickCount() - t

        s.calls = s.calls + 1
        s.ms = s.ms + dt
        if dt > s.max_ms then s.max_ms = dt end

        -- Re-adopt on the id the helper just created. A nil here
        -- means the loop cancelled itself, which is a legitimate end
        -- of life: stop chasing it and let the sweep notice.
        local nid = reg[name]
        if nid ~= nil and dfhack.timeout_active(nid) ~= nil then
            dfhack.timeout_active(nid, w)
        end

        if not ok then error(err, 0) end
    end

    P.wrappers[name] = w
    P.is_wrapper[w] = name
    dfhack.timeout_active(id, w)
    return true
end

-- Adopt everything currently registered, and pick up anything that
-- slipped: a loop cancelled and rescheduled carries a fresh helper
-- again, and a module started after arm was never adopted at all.
-- Returns how many were newly taken.
local function adopt_all()
    if not find_registry() then return 0 end
    local n = 0
    for name in pairs(P.reg) do
        -- pcall per key so one awkward entry cannot abort the walk
        -- and leave the set half adopted, which is exactly what the
        -- v2 crash did.
        local ok, took = pcall(adopt, name)
        if ok and took then n = n + 1
        elseif not ok and not P.adopt_warned[name] then
            -- log() alone: the sweep and the live sampler reach this
            -- about once a second with nobody at the console. WARNING,
            -- since that loop goes unmeasured, and once per key, or a
            -- loop that cannot be adopted would repeat it all session.
            P.adopt_warned[name] = true
            log('WARNING', ('could not adopt %q: %s'):format(tostring(name),
                tostring(took)), 'ADOPT')
        end
    end
    return n
end

-- ==========================================
-- MECHANISM 2: INTERCEPTING dfhack.timeout
-- ==========================================
-- Only the file name, so a row reads refinish_steel.lua:695 rather
-- than a full Windows path that wraps the terminal.
local function basename(p)
    return tostring(p):match('([^/\\]+)$') or tostring(p)
end

-- Where a callback was DEFINED, which is the only stable name a raw
-- timeout loop has. Cached on the function itself with WEAK KEYS:
-- a self chaining loop passes the same function object every fire,
-- so this is one debug.getinfo per loop rather than one per fire,
-- and closures built fresh each iteration can still be collected.
-- ---- THIS FILE'S OWN NAME, COMPUTED ----
-- The caller skip below has to recognise the profiler's own sweep
-- registrations. Hardcoding the filename means a rename silently
-- stops the skip from matching, which is the same class of failure
-- as the stack level bug this guard already survived once. Asking
-- the chunk what it is called cannot go stale.
local MY_SRC = (function()
    local i = debug and debug.getinfo and debug.getinfo(1, 'S')
    return i and basename(i.short_src) or ''
end)()

local site_cache = setmetatable({}, { __mode = 'k' })

local function site_of(cb)
    local k = site_cache[cb]
    if k then return k end
    local ok, info = pcall(debug.getinfo, cb, 'S')
    if ok and info then
        k = ('t:%s:%d'):format(basename(info.short_src),
                               info.linedefined or 0)
    else
        k = 't:unknown'
    end
    site_cache[cb] = k
    return k
end

-- typed is true only for the console, which prints its answer.
local function patch_timeout(typed)
    if P.real_timeout then return end
    -- Attribution and the repeat-util skip both depend on the debug
    -- library. Without it this mechanism cannot tell one loop from
    -- another or avoid double counting, so it declines to run rather
    -- than report something it cannot stand behind.
    if not (debug and debug.getinfo) then
        local say = typed and answer or log
        say('WARNING', 'debug.getinfo unavailable; self chaining timeout'
            .. ' loops will NOT be measured.', 'TIMEOUT')
        return
    end

    -- ---- SAFE TO LEAVE IN FOR A WHOLE SESSION ----
    -- Live mode installs this at map load and keeps it until unload,
    -- and any script that loads meanwhile can keep its own reference
    -- to dfhack.timeout, which is this function. So it has to go on
    -- working after the profiler is off:
    --   It holds the real function as an upvalue. It used to read
    --   P.real_timeout at call time, and that field is cleared when the
    --   interception comes out, so a script holding this function
    --   would have called nil on every timeout from then on.
    --   It passes every call straight through, untimed, whenever
    --   neither live mode nor a fixed window is running.
    local real = dfhack.timeout
    P.real_timeout = real

    local patched = function(t, mode, cb)
        if type(cb) ~= 'function' or not (P.live or P.armed) then
            return real(t, mode, cb)
        end

        -- ---- WHO IS ASKING ----
        -- repeat-util's registrations belong to adoption, and the
        -- probe's own sweep belongs to nobody. Wrapping either here
        -- would double count it.
        --
        -- NOT THROUGH pcall. debug.getinfo counts stack levels from
        -- ITSELF, so pcall(debug.getinfo, 2, ...) puts pcall's own C
        -- frame at level 1 and resolves level 2 to this wrapper
        -- instead of its caller. That read this file's own name for
        -- every registration, matched the self skip below, and
        -- silently declined to wrap anything at all. Called directly,
        -- level 2 is the caller. An out of range level returns nil
        -- rather than throwing, so the pcall bought nothing.
        local info = debug.getinfo(2, 'S')
        local caller = info and basename(info.short_src) or ''
        if P.is_wrapper[cb]
           or caller:find('repeat%-util')
           or (MY_SRC ~= '' and caller == MY_SRC) then
            return real(t, mode, cb)
        end

        local name = site_of(cb)
        local w = function(...)
            local s = slot(name)
            local t0 = dfhack.getTickCount()
            local ok2, err = pcall(cb, ...)
            local dt = dfhack.getTickCount() - t0
            s.calls = s.calls + 1
            s.ms = s.ms + dt
            if dt > s.max_ms then s.max_ms = dt end
            if not ok2 then error(err, 0) end
        end
        P.icpt_inner[w] = cb
        -- No re-adopt needed here, unlike mechanism 1: a self
        -- chaining loop calls dfhack.timeout again from inside cb,
        -- and that call comes straight back through this wrapper.
        return real(t, mode, w)
    end
    P.patch_fn = patched
    dfhack.timeout = patched
end

local function unpatch_timeout()
    if not P.real_timeout then return end
    -- Only if ours is still the one standing. If something wrapped it
    -- after it went in, taking ours out would cut that script's chain.
    -- Then ours stays: it passes every call straight through while
    -- nothing is timing, and the next start finds it still installed
    -- and reuses it rather than stacking a second one.
    --
    -- Timers already registered keep their wrappers until they next
    -- fire, which is harmless: they time one more call and then chain
    -- through whatever dfhack.timeout is by then.
    if dfhack.timeout == P.patch_fn then
        dfhack.timeout = P.real_timeout
        P.real_timeout, P.patch_fn = nil, nil
    end
end

-- ==========================================
-- THE SWEEP
-- ==========================================
-- Self chaining dfhack.timeout rather than a repeat-util loop, for
-- two reasons: it stays out of the registry so it cannot adopt
-- itself, and 'frames' timers survive a world unload, so the probe
-- keeps working across a reload.
--
-- 100 frames. Its own cost is one walk over a dozen keys, which is
-- nothing, and it is what catches loops that restart.
local SWEEP_FRAMES = 100

local function sweep()
    if not P.armed then return end
    pcall(adopt_all)
    P.sweep_id = dfhack.timeout(SWEEP_FRAMES, 'frames', sweep)
end

-- ==========================================
-- COMMANDS
-- ==========================================
-- Zeroes in place rather than replacing the rows, so the identity of
-- each row survives and no wrapper is left writing somewhere unread.
local function zero_counters()
    for _, s in pairs(P.stats) do
        s.calls, s.ms, s.max_ms = 0, 0, 0
    end
    P.t0 = dfhack.getTickCount()
    -- The live window is built from differences between snapshots of
    -- these counters, so it restarts with them rather than reading a
    -- negative difference across the reset.
    P.ring = {}
end

-- Hand each loop back its original callback, but only where our
-- wrapper is still the one standing. If something else has taken the
-- slot since, writing over it would be the kind of silent damage this
-- probe must not do.
--
-- A wrapper that could NOT be handed back stays in the identity set.
-- It is still installed and still firing, and forgetting it is what
-- would let a later adoption wrap it a second time.
--
-- Returns how many were handed back and how many are still installed.
local function release_loops()
    local restored, kept = 0, {}
    if P.reg then
        for name, w in pairs(P.wrappers) do
            local id = P.reg[name]
            if id and dfhack.timeout_active(id) == w and P.origins[name] then
                dfhack.timeout_active(id, P.origins[name])
                P.is_wrapper[w] = nil
                restored = restored + 1
            else
                kept[name] = w
            end
        end
    end
    P.wrappers = kept
    P.origins = {}
    return restored, count(kept)
end

-- arm always starts a FRESH window. Arming twice is therefore a
-- restart, not a silent continuation of an older window whose
-- elapsed time would flatten every average.
local function arm()
    if not find_registry() then
        -- ERROR: arm failed outright, so nothing will be measured.
        answer('ERROR', 'could not find the repeat-util timer registry.'
            .. ' Nothing adopted. Run "refinish-tool-profiler status" and'
            .. ' send the output.', 'REGISTRY')
        return
    end
    patch_timeout(true)
    local n = adopt_all()
    if not P.armed then
        P.armed = true
        P.sweep_id = dfhack.timeout(SWEEP_FRAMES, 'frames', sweep)
    end
    zero_counters()
    answer('INFO', ('armed. %d loop(s) newly adopted, %d held, %d registered;'
        .. ' dfhack.timeout intercepted for self chaining loops.'
        .. ' Window reset. Run the fort UNPAUSED, then: report')
        :format(n, count(P.wrappers), count(P.reg)), 'ARM')
end

-- quiet is true for the disarm at map unload, which nobody typed, so
-- it logs without printing (see answer above).
local function disarm(quiet)
    local say = quiet and log or answer
    if not P.armed then say('INFO', 'not armed.', 'DISARM') return end
    P.armed = false
    if P.sweep_id then
        dfhack.timeout_active(P.sweep_id, nil)
        P.sweep_id = nil
    end

    -- Live mode is still timing through both mechanisms, so with it on
    -- nothing is handed back; only the fixed window ends.
    if P.live then
        say('INFO', 'disarmed. Live timing carries on, every loop still'
            .. ' timed.', 'DISARM')
        return
    end
    unpatch_timeout()
    local restored, kept = release_loops()
    say('INFO', ('disarmed. %d loop(s) handed back, %d wrapper(s) still'
        .. ' installed and tracked.'):format(restored, kept), 'DISARM')
end

local function reset()
    zero_counters()
    pcall(adopt_all)
    answer('INFO', 'counters zeroed, window restarted.', 'RESET')
end

-- What the probe can see. This is the command that would have caught
-- v1's failure in one line instead of one 221 second window.
local function status()
    local reg = find_registry()
    local traw = 0
    for k in pairs(P.stats) do
        if tostring(k):sub(1, 2) == 't:' then traw = traw + 1 end
    end
    answer('INFO', ('version=%d armed=%s live=%s registry=%s rows=%d'
        .. ' timeout_patch=%s raw_timeout_rows=%d'):format(VERSION,
        tostring(P.armed), tostring(P.live), reg and 'found' or 'NOT FOUND',
        count(P.stats), P.real_timeout and 'ON' or 'off', traw), 'STATUS')
    if not reg then
        print('repeat-util module fields:')
        for k, v in pairs(repeatUtil) do
            print(('  %-28s %s'):format(tostring(k), type(v)))
        end
        return
    end
    print(('%-36s %-10s %8s'):format('repeat key', 'state', 'calls'))
    for name, id in pairs(reg) do
        local cur = dfhack.timeout_active(id)
        local state = 'foreign'
        if cur == nil then state = 'dead'
        elseif P.is_wrapper[cur] then state = 'ADOPTED' end
        local s = P.stats[name]
        print(('%-36s %-10s %8d'):format(name, state, s and s.calls or 0))
    end
end

-- Sorted by total ms, which over one window is the same order as ms
-- per second. The bound column exonerates the quiet loops: a loop
-- reading all zeros still cannot cost more than one sub-ms call per
-- fire, so calls/s is its ceiling in ms/s.
local function report()
    if not P.t0 then answer('INFO', 'never armed; nothing measured.', 'REPORT') return end
    local elapsed = (dfhack.getTickCount() - P.t0) / 1000.0
    if elapsed <= 0 then elapsed = 0.001 end

    local rows, total = {}, 0
    for key, s in pairs(P.stats) do
        rows[#rows + 1] = { key = key, s = s }
        total = total + s.ms
    end
    table.sort(rows, function(a, b) return a.s.ms > b.s.ms end)

    if #rows == 0 then
        -- WARNING: armed, yet nothing was adopted to measure.
        answer('WARNING', 'no loops adopted. Run "refinish-tool-profiler'
            .. ' status".', 'REPORT')
        return
    end

    emit(('PROFILER: %.1f s window, %d loop(s) timed, %.1f ms/sec'
        .. ' total.'):format(elapsed, #rows, total / elapsed))
    emit(('%-36s %9s %8s %9s %8s %9s'):format(
        'repeat key', 'ms/sec', 'calls/s', 'avg ms', 'max ms', 'bound'))
    for _, r in ipairs(rows) do
        local s = r.s
        local cps = s.calls / elapsed
        emit(('%-36s %9.1f %8.1f %9.2f %8d %9.1f'):format(
            r.key, s.ms / elapsed, cps,
            s.calls > 0 and (s.ms / s.calls) or 0, s.max_ms, cps))
    end
    emit('PROFILER: a row of zeros with LOW calls/s is exonerated.')
    emit('PROFILER: a row of zeros with HIGH calls/s costs at most its'
         .. ' bound column in ms/sec.')
    emit('PROFILER: max ms is quantised by the OS timer (about 15.6 ms'
         .. ' on Windows), so treat it as noise for any cheap row;'
         .. ' the averages are sound over thousands of samples.')
end

-- ==========================================
-- LIVE MODE, FOR THE TELEMETRY PANEL
-- ==========================================
-- On for the whole session: refinish_steel calls live_start() once
-- RM's own loops are up, and the map unload calls live_stop().
--
-- It uses both mechanisms, as arm always has: repeat-util loops are
-- adopted, and dfhack.timeout is intercepted, which catches every self
-- chaining loop, RM core's own and any other mod's, named by the file
-- and line that defined it. That is the point of leaving it on: when
-- the game slows, the panel shows whose loop it is, ours or not.
--
-- Once a second, by the wall clock, the sampler re-adopts anything new
-- and snapshots every counter into a ring covering LIVE_WINDOW_S
-- seconds. live_view() answers from the ring's first and last
-- snapshots: milliseconds and calls per second over that window, per
-- loop. Nothing is logged on a timer. The panel is where it is read,
-- and a report every minute would bury the log.
--
-- The registry is found on the first sample that can see it. At map
-- load no repeat-util loop exists yet, since the modules start theirs
-- later, and the registry cannot be recognised while it is empty.
--
-- Cost: the wrapper on each fire, two clock reads, a pcall and three
-- additions, measured at under a microsecond per call; one
-- debug.getinfo and one small closure per dfhack.timeout call from any
-- script, about the same again; and a snapshot of a few dozen numbers
-- once a second.
local LIVE_WINDOW_S    = 60     -- seconds the live view averages over
local LIVE_SAMPLE_MS   = 1000   -- one snapshot a second, by the wall clock
local LIVE_POLL_FRAMES = 10     -- how often the sampler checks the clock

local function snapshot(now)
    local rows = {}
    for key, s in pairs(P.stats) do
        rows[key] = { calls = s.calls, ms = s.ms }
    end
    return { t = now, rows = rows }
end

-- Self chaining on 'frames', like the sweep: out of the registry so it
-- cannot adopt itself, and skipped by the interception because this
-- file is its caller.
local function live_tick()
    if not P.live then return end
    local now = dfhack.getTickCount()
    local last = P.ring[#P.ring]
    if not last or now - last.t >= LIVE_SAMPLE_MS then
        pcall(adopt_all)
        table.insert(P.ring, snapshot(now))
        -- Keep the oldest snapshot that still covers the window and
        -- drop anything older.
        while #P.ring > 2 and now - P.ring[2].t >= LIVE_WINDOW_S * 1000 do
            table.remove(P.ring, 1)
        end
    end
    P.live_id = dfhack.timeout(LIVE_POLL_FRAMES, 'frames', live_tick)
end

-- typed is true only for the console command, which prints its answer.
function live_start(typed)
    local say = typed and answer or log
    if P.live then
        if typed then say('INFO', 'live timing is already on.', 'LIVE') end
        return true
    end
    P.live = true
    P.ring = {}
    P.adopt_warned = {}
    patch_timeout(typed)
    live_tick()
    say(typed and 'INFO' or 'DETAIL', 'live timing on: every scheduled loop'
        .. ' is timed, for the telemetry panel.', 'LIVE')
    return true
end

function live_stop(typed)
    local say = typed and answer or log
    if not P.live then
        if typed then say('INFO', 'live timing is already off.', 'LIVE') end
        return
    end
    P.live = false
    if P.live_id then
        dfhack.timeout_active(P.live_id, nil)
        P.live_id = nil
    end
    P.ring = {}
    -- A fixed window still armed keeps timing everything; otherwise
    -- the interception comes out and the loops go back.
    local restored = 0
    if not P.armed then
        unpatch_timeout()
        restored = release_loops()
    end
    say(typed and 'INFO' or 'DETAIL', ('live timing off. %d loop(s)'
        .. ' handed back.'):format(restored), 'LIVE')
end

-- The window, for the telemetry panel and the live command. nil when
-- live mode is off. Otherwise:
--   window_s    seconds the figures cover, 0 until two snapshots exist
--   all         true while dfhack.timeout is intercepted, so every
--               scheduled loop is included, not only repeat-util ones
--   total_ms_s  every row's ms per second, added up
--   rows        { key, ms_s, calls_s, avg_ms }, costliest first; a loop
--               that did not fire in the window has no row
function live_view()
    if not P.live then return nil end
    local view = { rows = {}, total_ms_s = 0, window_s = 0,
                   all = P.real_timeout ~= nil }
    local ring = P.ring
    local a, b = ring[1], ring[#ring]
    if not a or not b or b.t <= a.t then return view end
    view.window_s = (b.t - a.t) / 1000
    for key, rb in pairs(b.rows) do
        -- ---- EACH LOOP FROM ITS OWN FIRST SNAPSHOT ----
        -- Not the ring's first. A loop adopted partway through the
        -- window was only counted from then, so dividing its calls by
        -- the whole window understated it; measured at 62 calls/s for
        -- a loop really firing 83 times a second.
        local ra, ta = nil, nil
        for i = 1, #ring - 1 do
            local r = ring[i].rows[key]
            if r then ra, ta = r, ring[i].t break end
        end
        local span = ta and (b.t - ta) / 1000 or 0
        local dcalls = ra and (rb.calls - ra.calls) or 0
        if span > 0 and dcalls > 0 then
            local dms = rb.ms - ra.ms
            local r = { key = key, ms_s = dms / span,
                        calls_s = dcalls / span, avg_ms = dms / dcalls }
            view.rows[#view.rows + 1] = r
            view.total_ms_s = view.total_ms_s + r.ms_s
        end
    end
    table.sort(view.rows, function(x, y)
        if x.ms_s ~= y.ms_s then return x.ms_s > y.ms_s end
        return x.calls_s > y.calls_s
    end)
    return view
end

-- The live window at the console, the same figures the panel shows.
local function live_report()
    local v = live_view()
    if not v then
        answer('INFO', 'live timing is off. refinish-tool-profiler live on',
            'LIVE')
        return
    end
    if v.window_s <= 0 then
        answer('INFO', 'live timing is on but has no window yet; give it'
            .. ' a few seconds.', 'LIVE')
        return
    end
    emit(('PROFILER LIVE: last %.0f s, %d loop(s), %.1f ms/sec total%s.')
        :format(v.window_s, #v.rows, v.total_ms_s,
                v.all and ', every scheduled loop' or ', repeat-util loops only'))
    emit(('%-36s %9s %8s %9s'):format('repeat key', 'ms/sec', 'calls/s',
        'avg ms'))
    for _, r in ipairs(v.rows) do
        emit(('%-36s %9.1f %8.1f %9.2f'):format(r.key, r.ms_s, r.calls_s,
            r.avg_ms))
    end
end

-- ==========================================
-- LIFECYCLE
-- ==========================================
-- A map unload disarms and stops live mode. Without this the
-- dfhack.timeout patch and every installed wrapper would survive into
-- the next world, still pointing at callbacks whose scripts have been
-- stopped, and the next window would silently mix two forts' numbers.
-- Disarm first, so that live_stop, finding nothing armed, hands every
-- loop back.
--
-- Keyed so re-running this script replaces the handler rather than
-- stacking a second one.
dfhack.onStateChange.refinish_tool_profiler = function(code)
    if code ~= SC_MAP_UNLOADED then return end
    if P.armed then pcall(disarm, true) end
    if P.live then pcall(live_stop) end
end

-- Loaded as a module, by refinish_steel or the telemetry panel: export
-- the functions above and skip command dispatch.
if dfhack_flags and dfhack_flags.module then return _ENV end

local args = {...}
local cmd = args[1] or 'report'
if     cmd == 'arm'    then arm()
elseif cmd == 'disarm' then disarm()
elseif cmd == 'reset'  then reset()
elseif cmd == 'status' then status()
elseif cmd == 'report' then report()
elseif cmd == 'live'   then
    if     args[2] == 'on'  then live_start(true)
    elseif args[2] == 'off' then live_stop(true)
    else live_report() end
else
    print('refinish-tool-profiler: arm | status | report | reset'
        .. ' | disarm | live [on | off]')
end