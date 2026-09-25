-- making-fuel-air-dry.lua  (v4)
-- =====================================================================
-- AIR DRYING
-- Dung cakes, mash cakes, straw bales, and peat boulders convert to
-- their dried materials after DRY_DAYS wherever they sit. The kiln
-- DRY reactions remain the pay-fuel fast path.
--
-- Runs on the module's proven loop: repeat-util scheduleEvery in
-- 'days' mode, the pooper's scheduler and guards.
--
-- v4 staggers by TRUE ITEM AGE. start() probes whether items carry
-- an age field in this build and logs the mode. In age mode, an
-- item dries when its own age crosses the threshold: piles placed
-- at different times dry at different times, and drying survives
-- reloads because the item remembers, not this script. The age
-- unit is unverified, so the heartbeat prints the oldest wet age
-- next to the threshold; one reading calibrates AGE_PER_DAY if the
-- pace is wrong. Without an age field, the v3 poll-clock runs
-- instead (synchronized, resets on reload) and says so.
--
-- Expected on first age-mode poll: everything already older than
-- the threshold dries at once, because it genuinely is that old.
-- Stagger shows from then on.
-- =====================================================================

--@ module = true

local repeatUtil = require('repeat-util')

local REPEAT_KEY = 'making-fuel-air-dry'
local POLL_DAYS  = 3

-- ---- THE DRYING TIME IS A PLAYER SETTING ----
-- It lives in making-fuel-tuning's T as DRY_DAYS, where the Making
-- Fuel page of the RM HUD writes each fort's choice, and it is
-- read once per poll so a change lands on the next one. Guarded like
-- the log composer: with no tuning file there is no drying time, and
-- the poll says so and dries nothing rather than guess one.
local tuning = nil
pcall(function() tuning = reqscript('making-fuel-tuning') end)
local function dry_days()
    return tuning and tuning.T and tuning.T.DRY_DAYS
end
local dry_missing_said = false

-- wet inorganic id -> dried inorganic id
local WET = {
    MAKING_FUEL_DUNG  = 'MAKING_FUEL_DUNG_DRIED',
    MAKING_FUEL_MASH  = 'MAKING_FUEL_MASH_DRIED',
    MAKING_FUEL_STRAW = 'MAKING_FUEL_STRAW_DRIED',
    PEAT              = 'MAKING_FUEL_PEAT_DRIED',
}

-- Tool swaps, run alongside the material swap. A tool's art lives on
-- its itemdef and cannot vary by material, so a dried cake only
-- LOOKS dried if the item changes subtype too. Keyed by the wet
-- tool. A tool with no entry keeps its shape, which is why a raw
-- dung pile still wears wet art: there is no dried pile itemdef.
local TOOL_SWAP = {
    MAKING_FUEL_STRAW      = 'MAKING_FUEL_STRAW_DRIED',
}

-- Age units per calendar day. UNVERIFIED: calibrate from the
-- heartbeat's "oldest wet age" against real days if drying paces
-- wrong. 1200 is one day in ticks, the most likely unit.
local AGE_PER_DAY = 120

local clock = {}     -- item id -> accumulated days (clock mode only)
local polls = 0
local age_mode = false

-- ---- LOG IDENTITY, DECLARED HERE ----
-- RM core does not know this module exists and must never have to.
-- The onus is on the module to hand RM correct information, so the
-- system and subsystem are stated here rather than inferred anywhere
-- else.
--
-- Guarded reqscript: a bare top level one is a hard load time
-- dependency and has taken a module down before. Without it the log
-- falls back to the same grammar, unsanitised, and the script still
-- loads.
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'AIR_DRY'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed
-- by refinish-log. The identity is declared by the module, not
-- inferred anywhere: RM core does not know this module exists.
--
-- The panel filters on TYPE and nothing else, so each call site states
-- its own:
--   DETAIL   debugging material, shown in Debug only
--   INFO     what a player might check during play, Normal and up
--   YIELD    the module made something, Normal and up
--   faults, and the few confirmations a player wants at a glance
--   (COMPLETE, SYSTEM, ONLINE and the like), show in Quiet as well
-- TYPE comes first so no call site can drop it unnoticed: a nil TYPE
-- still renders, as UNTYPED, which shows at every Log Detail level
-- instead of being guessed at.
--
-- SUBJECT is the correlation slot: POLL for the drying pass, DRY for
-- a single item, START for the lifecycle.
--
-- This replaces a log() that let refinish-log guess TYPE from the
-- words (read_type) unless a call site said otherwise, and printed to
-- the console when RM was not loaded.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else.
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

-- Materials are resolved on every poll, not at start(): start runs
-- at the token call, before the engine injects anything, so the
-- module inorganics genuinely do not exist yet. Same lesson the
-- pooper's deferral comment records.
local function resolve_map()
    local m = {}
    for wet, dry in pairs(WET) do
        local wi = dfhack.matinfo.find('INORGANIC:' .. wet)
        local di = dfhack.matinfo.find('INORGANIC:' .. dry)
        if wi and di then m[wi.index] = di.index end
    end
    return m
end

-- Tool key to subtype number, resolved fresh every poll. Adding one
-- tool key re-sorts every tool after it alphabetically, so these
-- numbers are not stable across versions of the module and must
-- never be cached across sessions. Prefer the struct's own subtype
-- field over the array position, the pooper's rule.
local function tool_subtypes()
    local want, by_id = {}, {}
    for wet, dry in pairs(TOOL_SWAP) do want[wet] = true want[dry] = true end
    for i, td in ipairs(df.global.world.raws.itemdefs.tools) do
        local ok, id = pcall(function() return td.id end)
        if ok and want[id] then
            local ok2, sub = pcall(function() return td.subtype end)
            by_id[id] = (ok2 and type(sub) == 'number' and sub >= 0) and sub or i
        end
    end
    local m = {}
    for wet, dry in pairs(TOOL_SWAP) do
        if by_id[wet] and by_id[dry] then m[by_id[wet]] = by_id[dry] end
    end
    return m
end

-- Write the dried material, and the dried subtype when one exists.
-- item_toolst.subtype may hold a pointer to the itemdef rather than
-- a plain number, so the write matches whatever is already in the
-- field instead of assuming which.
local function convert(it, mi, map, tmap)
    it.mat_index = map[mi.index]
    if not next(tmap) then return end
    if it:getType() ~= df.item_type.TOOL then return end
    local ok, sub = pcall(function() return it:getSubtype() end)
    if not ok or not tmap[sub] then return end
    local target = tmap[sub]
    local ok2, err = pcall(function()
        if type(it.subtype) == 'number' then
            it.subtype = target
        else
            it.subtype = df.global.world.raws.itemdefs.tools[target]
        end
    end)
    if not ok2 then
        -- WARNING: the item took its dried material but kept the wet
        -- tool, so its name and material disagree.
        log('WARNING', 'subtype write failed on item ' .. it.id .. ': ' .. tostring(err), 'DRY')
    end
end

local function poll()
    if not dfhack.isMapLoaded() then return end
    if not _G.refinish_active then return end

    local ok, err = pcall(function()
        polls = polls + 1
        local map = resolve_map()
        local tmap = tool_subtypes()
        if not next(map) then
            log('DETAIL', 'poll ' .. polls .. ': materials not resolved yet, deferring.', 'POLL')
            return
        end

        local dry = dry_days()
        if not dry then
            if not dry_missing_said then
                dry_missing_said = true
                -- ERROR: nothing dries until this is fixed.
                log('ERROR', 'no DRY_DAYS in making-fuel-tuning, so nothing'
                    .. ' dries. Check that the tuning file loads.', 'POLL')
            end
            return
        end

        local dried, tracking, seen, oldest = 0, 0, {}, 0
        for _, it in ipairs(df.global.world.items.all) do
            -- matinfo.decode, not raw fields: item classes like fish
            -- carry no mat_type at all and reading it throws. Decode
            -- works on every class; only true inorganics pass, and
            -- every class that can pass has the writable index below.
            local mi = dfhack.matinfo.decode(it)
            if mi and mi.type == 0 and map[mi.index]
               and not it.flags.in_job then
                seen[it.id] = true
                tracking = tracking + 1
                if age_mode then
                    local a = it.age
                    if a > oldest then oldest = a end
                    if a >= dry * AGE_PER_DAY then
                        convert(it, mi, map, tmap)
                        dried = dried + 1
                    end
                else
                    local t = (clock[it.id] or 0) + POLL_DAYS
                    if t >= dry then
                        convert(it, mi, map, tmap)
                        clock[it.id] = nil
                        dried = dried + 1
                    else
                        clock[it.id] = t
                    end
                end
            end
        end
        -- Forget items that left the world.
        for id in pairs(clock) do
            if not seen[id] then clock[id] = nil end
        end

        if age_mode then
            log('DETAIL', ('poll %d: %d wet item(s), %d dried, oldest wet age '
                .. '%d of %d.'):format(polls, tracking, dried, oldest,
                dry * AGE_PER_DAY), 'POLL')
        else
            log('DETAIL', ('poll %d: %d wet item(s) tracked, %d dried.')
                :format(polls, tracking, dried), 'POLL')
        end
    end)

    if not ok then log('ERROR', 'POLL ERROR: ' .. tostring(err), 'POLL') end
end

function start()
    clock, polls = {}, 0
    -- Probe once: does this build's item carry an age field?
    age_mode = false
    for _, it in ipairs(df.global.world.items.all) do
        local ok, v = pcall(function() return it.age end)
        age_mode = ok and type(v) == 'number'
        break
    end
    log('DETAIL', age_mode and 'age field present: true per-item staggering.'
                  or 'no age field: synchronized poll-clock mode.', 'START')
    repeatUtil.scheduleEvery(REPEAT_KEY, POLL_DAYS, 'days', poll)
    log('DETAIL', ('active. Wet fuel dries in %s days, polled every %d.')
        :format(tostring(dry_days() or '?'), POLL_DAYS), 'START')
end

function stop()
    repeatUtil.cancel(REPEAT_KEY)
    clock = {}
end

return _ENV