--@ module = true
-- making-fuel-tinder-watcher.lua
-- ==========================================
-- THE FUEL WOOD HOP
-- ==========================================
-- THE INVARIANT: no module fuel tool in the world carries real
-- species WOOD, ever.
--
-- The reactions that mint these tools inherit their material from a
-- reagent (PRESS_TINDER from sawdust, every SPLIT_ from the item
-- being split), which is the species' wood and the RIGHT SPECIES,
-- wrong twin: real wood must never carry FUEL (the container
-- doctrine ruling, or every wooden bed in the fort becomes furnace
-- feed), so the fuel class lives on the twin that
-- making-fuel-tinder-mat appended to the same plant. The hop is two
-- field writes, and the item arrives already knowing its plant, so
-- there is nothing to capture and no job to watch.
--
-- THE TWIN IS A MATERIAL. A hopped kindling is still a kindling:
-- it keeps its own itemdef, its own name, its own size and every
-- reaction that names it. All that changes is which material it
-- is made of, from real oak WOOD to the oak twin beside it. An
-- oak kindling still reads 'oak kindling'.
--
-- WHAT HOPS, and why each one:
--   TINDER    fire starting grade, pressed from sawdust or bark.
--   KINDLING  the split currency. Everything wooden in the fort
--             becomes this, and it is the fort's bulk fuel, so it
--             has to burn like one.
-- BRANCH is deliberately absent. A branch is raw wood off a tree,
-- not a made fuel, and it enters the economy by being split.
--
-- SOURCES, coal watcher doctrine: onItemCreated for the instant
-- path, plus a 5 frame sweep of the TOOL vector for traders,
-- migrants and anything else the event misses. The sweep spares
-- trader owned goods until bought, same rule, same reason.
--
-- COST NOTE: kindling is numerous where tinder never was, so the
-- sweep gets an integer only early out for items already wearing
-- their twin. Without it every kindling in the fort pays a matinfo
-- decode every 5 frames forever.
-- ==========================================

local eventful   = require('plugins.eventful')
local repeatUtil = require('repeat-util')

local REPEAT_KEY = 'making_fuel_tinder_watcher'
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
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'TINDER_WATCHER'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

-- Every tool itemdef whose items must wear the fuel twin instead of
-- real wood. Add an id here and the hop covers it; nothing else in
-- this file needs to know how many there are.
local HOP_TOOLS = {
    'MAKING_FUEL_TINDER',
    'MAKING_FUEL_KINDLING',
}

-- Resolved on first need, then cached: itemdef subtype integer ->
-- true. Reset by start() so a recycle re-resolves against the
-- freshly injected itemdefs rather than last session's indices.
local hop_subtypes = nil

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed
-- by refinish-log. The identity above is declared by the module, not
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
-- SUBJECT is the correlation slot: RESOLVE for the tool lookup, TWIN
-- for a single plant, SWEEP for the poll, START and STOP.
--
-- This replaces a log() that let refinish-log guess TYPE from the
-- words (read_type) and printed to the console when RM was not loaded.
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

-- Plants already reported as having no twin, so the sweep, which runs
-- every 5 frames, reports each one once rather than on every pass.
-- Reset by start().
local no_twin_logged = {}

-- ==========================================
-- SUBTYPE RESOLUTION
-- ==========================================
-- One walk of the itemdef list builds the whole set. Returns nil
-- until at least one id resolves, so a hop attempted before
-- injection simply declines rather than caching an empty set and
-- declining forever.
local function resolve_subtypes()
    if hop_subtypes then return hop_subtypes end
    local want, found = {}, {}
    for _, id in ipairs(HOP_TOOLS) do want[id] = true end
    local n = 0
    for _, td in ipairs(df.global.world.raws.itemdefs.tools) do
        if want[td.id] then
            found[td.subtype] = true
            n = n + 1
        end
    end
    if n == 0 then return nil end
    hop_subtypes = found
    if n < #HOP_TOOLS then
        -- ERROR: the unresolved tools stay on real wood, which carries
        -- no fuel class, so they will not burn.
        log('ERROR', ('only %d of %d fuel tools resolved; the rest will keep '
             .. 'real wood, report it.'):format(n, #HOP_TOOLS), 'RESOLVE')
    end
    return hop_subtypes
end

-- ==========================================
-- THE HOP
-- ==========================================
-- True = converted. False = not ours, or already wearing the twin.
local function hop(item)
    local ok, did = pcall(function()
        if not df.item_toolst:is_instance(item) then return false end
        local subs = resolve_subtypes()
        -- item.subtype is a POINTER to the itemdef, not an integer.
        -- The integer is one field further in.
        if not subs or not subs[item.subtype.subtype] then return false end
        if item.flags.trader then return false end

        local twins = _G.making_fuel_fuelwood_twin
        if not twins then return false end

        -- ---- EARLY OUT, NO DECODE ----
        -- For a plant material the item's mat_index IS the plant
        -- index, which is exactly how the twin map is keyed. So an
        -- item already wearing its twin is two integer reads away
        -- from being skipped, and the sweep stays affordable at
        -- kindling volumes.
        --
        -- mat_type alone would not do it: it is 419 plus the
        -- material's position WITHIN its plant, so two different
        -- plants can share the number. The pair is what identifies.
        local twin = twins[item.mat_index]
        if twin and item.mat_type == twin.mat_type then return false end

        local mi = dfhack.matinfo.decode(item)
        if not mi or not mi.material then return false end
        -- Bark strips inherit the BARK material through the press;
        -- the hop lands both on the same wood cloned twin, which is
        -- physically right, since bark tinder burns as its tree.
        local mid = mi.material.id
        if mid ~= 'WOOD' and mid ~= 'BARK' then return false end

        -- Re-read off the decoded index rather than trusting the
        -- raw field: BARK and WOOD both live on the plant, so
        -- mi.index is the authoritative plant number here.
        twin = twins[mi.index]
        if not twin then
            -- ERROR, once per plant: this tool stays on real wood and
            -- will not burn. Without the once, the 5 frame sweep would
            -- repeat it for every such tool on every pass.
            if not no_twin_logged[mi.index] then
                no_twin_logged[mi.index] = true
                log('ERROR', ('no twin for plant %d; fuel tool left as wood, '
                     .. 'report it.'):format(mi.index), 'TWIN')
            end
            return false
        end
        item.mat_type  = twin.mat_type
        item.mat_index = twin.mat_index
        return true
    end)
    return ok and did or false
end

local function sweep()
    local n = 0
    pcall(function()
        for _, item in ipairs(df.global.world.items.other.TOOL) do
            if hop(item) then n = n + 1 end
        end
    end)
    if n > 0 then
        log('DETAIL', ('sweep hopped %d fuel tool(s) to twin wood.'):format(n),
            'SWEEP')
    end
end

function start()
    -- Injection may have moved subtypes since last session, so the
    -- cache never survives a start.
    hop_subtypes = nil
    no_twin_logged = {}
    eventful.onItemCreated[REPEAT_KEY] = function(item_id)
        local item = df.item.find(item_id)
        if item then hop(item) end
    end
    repeatUtil.scheduleEvery(REPEAT_KEY, 5, 'frames', sweep)
    log('DETAIL', 'active. No tinder and no kindling wears real wood.',
        'START')
end

function stop()
    eventful.onItemCreated[REPEAT_KEY] = nil
    repeatUtil.cancel(REPEAT_KEY)
    hop_subtypes = nil
    log('DETAIL', 'stopped.', 'STOP')
end

return _ENV