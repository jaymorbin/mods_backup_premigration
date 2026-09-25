-- refinish-tint.lua
-- =====================================================================
-- LIVE TINT TUNER
-- =====================================================================
-- Changes the three tint knobs while the game runs and pushes the
-- change out as far as it can reach, so a colour can be judged on
-- screen instead of across a recycle.
--
--   refinish-tint                      report the current values
--   refinish-tint value=0.9            set one
--   refinish-tint strength=1 desat=0.2 value=0.85
--   refinish-tint off                  value=0, the old darkening blend
--
-- WHAT EACH KNOB DOES, since they are easy to confuse:
--   strength  how much hue the multiply contributes, 0 none, 1 full
--   desat     how pure that hue is, pulling the descriptor toward its
--             own grey before it is applied
--   value     how light the result lands, 1.00 meaning as light as the
--             untinted art was. 0 turns the restore off entirely
--
-- WHAT GETS REPAINTED, and what does not. The art module's cache is
-- keyed by art and colour, not by the knobs, so this wipes it: the next
-- request manufactures with the new numbers. Nothing already written
-- into a texpos field changes by itself, so this then asks the
-- consumers to fetch again:
--   tools        the tool tint watcher refetches on its own poll, a
--                fraction of a second, so nothing is done here
--   ash sprite   has refresh(), called below
--   module JSON  material and tool slots are resolved during the
--                inject, so those want the module stopped and started.
--                No DF restart: the cache was the only thing that ever
--                forced one.
--
-- COST. Textures are never deleted, because deleting a handle takes the
-- process down (see refinish-sprite-art.lua). So every change leaks one
-- texture per art and colour pairing in use. Fine for a tuning session,
-- not something to put on a timer.
-- =====================================================================

--@ module = true

local art = reqscript('refinish-sprite-art')

-- RM core's own system name. This file said 'REFINISH', which the log
-- panel does not recognise as RM, so its lines rendered as a module's.
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'TINT'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

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
-- SUBJECT is the correlation slot: ARGS for a refused argument, VALUES
-- for the knobs, REFRESH for what was pushed out.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- This replaces a log() that let refinish-log guess TYPE from the
-- words (read_type) unless a call site said otherwise.
--
-- No console prints. The print this replaces only ran when RM's log
-- was not loaded.
-- ==========================================
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
-- ARGUMENTS
-- ==========================================
-- key=value pairs in any order, plus the bare word 'off'. Anything
-- unrecognised is reported rather than ignored, because a typo that
-- silently does nothing is worse than a refusal when the whole point
-- is watching a number change.
local ALIAS = {
    desat = 'desat', d = 'desat',
    strength = 'strength', s = 'strength',
    value = 'value', v = 'value', brightness = 'value', b = 'value',
}

local function parse(args)
    local opts, bad = {}, {}
    for _, a in ipairs(args or {}) do
        local word = tostring(a):lower()
        if word == 'off' then
            opts.value = 0
        else
            local k, v = word:match('^([%a_]+)=([%-%d%.]+)$')
            local key = k and ALIAS[k]
            if key and tonumber(v) then
                opts[key] = tonumber(v)
            else
                table.insert(bad, tostring(a))
            end
        end
    end
    return opts, bad
end

-- ==========================================
-- PUSH THE CHANGE OUT
-- ==========================================
-- Each consumer in its own pcall: one of them missing is a cosmetic
-- failure and must not stop the others.
local function refresh_consumers()
    local done = {}

    local ok_ash, ash = pcall(reqscript, 'making-fuel-ash-sprite')
    if ok_ash and ash and ash.refresh then
        if pcall(ash.refresh) then table.insert(done, 'ash sprite') end
    end

    -- The tool watcher would pick this up on its own poll; calling its
    -- pass here just makes the change land in the same frame.
    local ok_tt, tt = pcall(reqscript, 'making-fuel-tool-tint')
    if ok_tt and tt and tt.pass then
        local ok_n, n = pcall(tt.pass)
        if ok_n then
            table.insert(done, ('tool tint (%s field(s))'):format(tostring(n)))
        end
    end

    return done
end

function main(args)
    local opts, bad = parse(args)
    for _, b in ipairs(bad) do
        log('WARNING', 'ignored "' .. b .. '": expected desat=, strength=,'
            .. ' value= or off', 'ARGS')
    end

    local before = { art.tint() }
    local d, s, v = art.tint(opts)

    if not next(opts) then
        -- INFO throughout: every line here answers a command a player
        -- typed, so each is worth seeing at Normal.
        log('INFO', ('desat %.2f, strength %.2f, value %.2f'):format(d, s, v),
            'VALUES')
        return
    end

    local done = refresh_consumers()
    log('INFO', ('desat %.2f -> %.2f, strength %.2f -> %.2f, value %.2f -> %.2f')
        :format(before[1], d, before[2], s, before[3], v), 'VALUES')
    log('INFO', ('refreshed: %s'):format(#done > 0 and table.concat(done, ', ')
                                         or 'nothing live to refresh'), 'REFRESH')
    log('INFO', 'slots written during the inject need the module stopped and '
        .. 'started to pick this up. DF does not need restarting.', 'REFRESH')
end

if not dfhack_flags.module then
    main({ ... })
end