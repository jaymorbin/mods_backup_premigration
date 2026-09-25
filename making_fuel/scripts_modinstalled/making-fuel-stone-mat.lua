-- making-fuel-stone-mat.lua
-- =====================================================================
-- AGGREGATE STONE TWIN PUSH
-- Every stone gets a TWIN inorganic appended to the raws: a clone of
-- the stone, same name, colour, thermals and density, PLUS the
-- AGGREGATE class. Its material flags do NOT come across, and RM's
-- refinish scan depends on that: see THE FLAGS DO NOT COME ACROSS in
-- start() before changing how a twin is copied. Gravel minted from a
-- stone is hopped onto that stone's twin after minting, so "granite
-- gravel" reads and weighs like
-- granite while real granite never carries AGGREGATE and a mason's
-- granite blocks stay out of the road mix.
--
-- WHY A TWIN AND NOT A CLASS ON THE STONE. A reagent asks by class, and
-- a tool wears the material of whatever it was made from, so gravel
-- carries granite's classes. Putting AGGREGATE on granite itself would
-- make every granite item legal in a road mix, boulders included.
--
-- WHERE THIS DIFFERS FROM THE FUEL WOOD TWIN, and it matters twice. A
-- wood twin hides inside its own plant's material list, a vector
-- nothing else appends to, so its index never moves. A stone twin is a
-- top level inorganic, in the same vector the module engine injects
-- every module material into:
--
--   * Each twin needs its own id, so it is MAKING_FUEL_AGG_<SOURCE>.
--   * ORDER IS THE CONTRACT. An item stores a mat_index number, not a
--     token, and RM's injected materials are not in the save. They are
--     re-pushed every session and the numbers have to land the same
--     way. So this push runs at one fixed point of the start sequence
--     and walks the inorganics in index order. Move the call, or change
--     which stones qualify, and every saved gravel silently becomes a
--     different stone. The engine's own materials already live under
--     this rule; these twins only add more that rides on it.
--
-- APPEND ONLY, and pop LIFO in stop(), before the engine sweeps its own
-- materials. The engine washes TOOLS mid session, never materials, so
-- nothing moves under a live item while a fort runs.
--
-- THE HOP LIVES HERE TOO, rather than in a watcher of its own: one file
-- owns the twins and the only write that depends on them. It is the
-- fuel wood hop with an inorganic's addressing, which is simpler, since
-- an inorganic item's mat_index IS the inorganic index and mat_type is
-- always 0.
-- =====================================================================

--@ module = true

local eventful   = require('plugins.eventful')
local repeatUtil = require('repeat-util')
local REPEAT_KEY = 'making_fuel_stone_mat'

-- Twin ids are this plus the source stone's id. Also the marker the
-- pop scans for, so nothing else needs a manifest.
local TWIN_PREFIX = 'MAKING_FUEL_AGG_'

-- What the twin carries that the stone does not.
local CLASSES = { 'AGGREGATE' }

-- Ids the push refuses to twin. This module's own materials are stone
-- classed (pitch, asphalt, naphthalene) and have no business being road
-- aggregate, and twinning a twin would compound every session.
local SKIP_PREFIXES = { TWIN_PREFIX, 'MAKING_FUEL_' }

-- Every tool itemdef whose items must wear the twin instead of the
-- stone they were crushed from. Add an id here and the hop covers it.
local HOP_TOOLS = {
    'MAKING_FUEL_GRAVEL',
}

-- ---- THE SPRITE FIELDS ----
-- MEASURED in play: oil shale reads boulder_texpos1 and 2 as 3014, and
-- its twin read 0, with every other field matching, colour included.
-- assign does not carry these. That zero is what made gravel render see
-- through on a twin while the same art on the same sheet was solid on
-- any other material.
--
-- It cannot be a copy at creation either. The 3014 is OUR dressing,
-- written onto the source stone by the sprite pass, which runs after
-- this push. So the copy is a SYNC that catches up, run at the end of
-- start and again on a slow cadence from the sweep.
--
-- The list is the engine's own: the seven texpos fields a material
-- carries plus texflag, which it copies verbatim including zero.
local SPRITE_FIELDS = {
    'bar_texpos',
    'boulder_texpos1', 'boulder_texpos2',
    'rough_texpos1',   'rough_texpos2',
    'cheese_texpos1',  'cheese_texpos2',
    'texflag',
}

-- The sweep runs every 5 frames; the sync runs every twelfth of those,
-- so roughly once a second. Cheap enough to keep doing forever, which
-- beats a settled flag that would go stale the moment anything dressed
-- a stone later in a session.
local SYNC_EVERY = 12
local sweeps_since_sync = SYNC_EVERY

-- Resolved on first need, then cached: itemdef subtype integer -> true.
-- Reset by start() so a recycle re-resolves against the freshly
-- injected itemdefs rather than last session's indices.
local hop_subtypes = nil

-- ---- LOG IDENTITY, DECLARED HERE ----
-- The onus is on the module to hand RM correct information, so the
-- system and subsystem are stated here rather than inferred anywhere.
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'STONE_MAT'
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
-- SUBJECT is the correlation slot: PUSH and POP for the two halves of
-- the lifecycle, TWIN for a single stone, RESOLVE for the tool lookup,
-- SPRITE and SWEEP for the two polls.
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

local function new_string_ptr(s)
    local p = df.new('string'); p.value = s; return p
end

local function is_ours(id)
    return tostring(id):sub(1, #TWIN_PREFIX) == TWIN_PREFIX
end

local function skipped(id)
    id = tostring(id)
    for _, p in ipairs(SKIP_PREFIXES) do
        if id:sub(1, #p) == p then return true end
    end
    return false
end

-- ==========================================
-- THE PUSH
-- ==========================================
-- One twin per stone, in source index order. A stone is anything the
-- raws flagged IS_STONE, which is Jay's rule: all stones, no filter on
-- economics or ores, because a road takes whatever is quarried.
function start()
    _G.making_fuel_aggregate_twin = {}
    _G.making_fuel_aggregate_is_twin = {}
    hop_subtypes = nil

    local raws = df.global.world.raws.inorganics.all
    local made, had, n_src = 0, 0, #raws

    -- The source list is snapshotted BEFORE anything is appended:
    -- walking a vector that grows underneath is how a push twins its
    -- own twins.
    local sources = {}
    for i = 0, n_src - 1 do
        local ok = false
        pcall(function()
            ok = raws[i].material.flags.IS_STONE and not skipped(raws[i].id)
        end)
        if ok then sources[#sources + 1] = i end
    end

    -- An existing twin means a start ran without its stop. Reuse it
    -- rather than pushing a second one: the ids are unique, so the
    -- match is exact.
    local existing = {}
    for i = 0, n_src - 1 do
        pcall(function()
            if is_ours(raws[i].id) then existing[tostring(raws[i].id)] = i end
        end)
    end

    for _, si in ipairs(sources) do
        local src_id = tostring(raws[si].id)
        local twin_id = TWIN_PREFIX .. src_id
        local at = existing[twin_id]
        if at then
            had = had + 1
        else
            local ok, err = pcall(function()
                local twin = df.inorganic_raw:new()
                -- Copy of the whole stone, material and all. One call,
                -- so a twin cannot drift from what it mirrors.
                --
                -- ---- THE FLAGS DO NOT COME ACROSS, AND THAT IS LOAD BEARING ----
                -- MEASURED from the console: granite reads IS_STONE true
                -- and MAKING_FUEL_AGG_GRANITE reads false, so this copy
                -- does not carry IS_STONE. Only IS_STONE was checked;
                -- the likely reason is that assign leaves the flag
                -- arrays behind. Names, colours and value do copy.
                --
                -- Do NOT restore the flags on their own. RM's refinish
                -- scan takes every stone, metal, gem or soil inorganic
                -- outside RM as a reagent, and the twins are already in
                -- the array when it runs. It passes over them only
                -- because they read as none of those (measured: zero
                -- twin reactions and zero twin powder renames in the
                -- blueprint). A twin with its flags back becomes a
                -- second reagent for every stone: a duplicate row per
                -- base in the refinish menu, and each stone's finish
                -- counted twice, which costs it its conserved value.
                -- Restoring the flags has to land together with a way
                -- for this module to tell RM to leave the twins out.
                twin:assign(raws[si])
                twin.id = twin_id
                twin.material.id = twin_id
                for _, c in ipairs(CLASSES) do
                    twin.material.reaction_class:insert('#',
                        new_string_ptr(c))
                end
                raws:insert('#', twin)          -- APPEND: '#' is end
                at = #raws - 1
            end)
            if ok and at then made = made + 1
            else
                -- ERROR: gravel of this stone keeps the raw stone and will not answer an
                -- AGGREGATE reagent.
                log('ERROR', ('aggregate twin FAILED on inorganic %d: %s')
                    :format(si, tostring(err)), 'TWIN')
                at = nil
            end
        end
        if at then
            _G.making_fuel_aggregate_twin[si] = at
            _G.making_fuel_aggregate_is_twin[at] = true
        end
    end

    eventful.onItemCreated[REPEAT_KEY] = function(item_id)
        local item = df.item.find(item_id)
        if item then hop(item) end
    end
    repeatUtil.scheduleEvery(REPEAT_KEY, 5, 'frames', sweep)

    -- First pass now, the rest on the sweep's cadence. At this point the
    -- sprite pass may not have run yet, so this one usually copies
    -- nothing and the catch up happens a second later.
    sweeps_since_sync = SYNC_EVERY
    pcall(sync_twins)

    if made == 0 and had == 0 then
        log('ERROR', 'Aggregate twin push wrote NOTHING with stones present. '
            .. 'That is a bug, report it.', 'PUSH')
    else
        log('DETAIL', ('Aggregate twin push: %d twins made, %d already present, '
             .. 'from %d stone(s).'):format(made, had, #sources), 'PUSH')
    end
end

-- ==========================================
-- THE POP
-- ==========================================
-- From the end down, so indices below never move while it runs, and
-- before the engine sweeps its own materials.
function stop()
    eventful.onItemCreated[REPEAT_KEY] = nil
    repeatUtil.cancel(REPEAT_KEY)
    hop_subtypes = nil

    local popped = 0
    local raws = df.global.world.raws.inorganics.all
    for i = #raws - 1, 0, -1 do
        local ours = false
        pcall(function() ours = is_ours(raws[i].id) end)
        if ours then
            local m = raws[i]
            raws:erase(i)
            df.delete(m)
            popped = popped + 1
        end
    end
    _G.making_fuel_aggregate_twin = nil
    _G.making_fuel_aggregate_is_twin = nil
    log('DETAIL', ('Aggregate twin pop, %d cleared.'):format(popped), 'POP')
end

-- ==========================================
-- SUBTYPE RESOLUTION
-- ==========================================
-- One walk of the itemdef list builds the whole set. Returns nil until
-- at least one id resolves, so a hop attempted before injection
-- declines rather than caching an empty set and declining forever.
function resolve_subtypes()
    if hop_subtypes then return hop_subtypes end
    local want, found, n = {}, {}, 0
    for _, id in ipairs(HOP_TOOLS) do want[id] = true end
    pcall(function()
        for _, td in ipairs(df.global.world.raws.itemdefs.tools) do
            if want[td.id] then
                found[td.subtype] = true
                n = n + 1
            end
        end
    end)
    if n == 0 then return nil end
    hop_subtypes = found
    if n < #HOP_TOOLS then
        -- ERROR: each unresolved tool keeps the raw stone and will not answer an
        -- AGGREGATE reagent.
        log('ERROR', ('only %d of %d aggregate tools resolved; the rest keep the '
             .. 'raw stone, report it.'):format(n, #HOP_TOOLS), 'RESOLVE')
    end
    return hop_subtypes
end

-- ==========================================
-- THE HOP
-- ==========================================
-- True = converted. False = not ours, or already wearing the twin.
function hop(item)
    local ok, did = pcall(function()
        if not df.item_toolst:is_instance(item) then return false end
        local subs = resolve_subtypes()
        -- item.subtype is a POINTER to the itemdef, not an integer.
        -- The integer is one field further in.
        if not subs or not subs[item.subtype.subtype] then return false end
        if item.flags.trader then return false end

        local twins = _G.making_fuel_aggregate_twin
        local is_twin = _G.making_fuel_aggregate_is_twin
        if not twins then return false end

        -- ---- EARLY OUT, NO DECODE ----
        -- An inorganic item's mat_index IS the inorganic index, which
        -- is how both maps are keyed, so an item already wearing its
        -- twin is two integer reads away from being skipped.
        if item.mat_type ~= 0 then return false end
        if is_twin and is_twin[item.mat_index] then return false end

        local twin = twins[item.mat_index]
        if not twin then
            -- Gravel of something that is not a twinned stone: glass,
            -- a module material, anything the push skipped. Left as it
            -- is, and said once so the gap is visible rather than
            -- guessed at.
            log_once_missing(item.mat_index)
            return false
        end
        item.mat_index = twin
        return true
    end)
    return ok and did or false
end

-- One line per material, not per item: a fort can mint a lot of gravel.
local missing_said = {}
function log_once_missing(mi)
    if missing_said[mi] then return end
    missing_said[mi] = true
    log('ERROR', ('no aggregate twin for inorganic %d; that gravel keeps its raw '
         .. 'stone and will not answer an AGGREGATE reagent.'):format(mi), 'TWIN')
end

-- ==========================================
-- THE SPRITE SYNC
-- ==========================================
-- Copies the source stone's sprite fields onto its twin, so a twin
-- wears whatever the sprite pass gave the stone it mirrors, whenever
-- that happened. Only writes what differs, so a settled fort does the
-- comparisons and nothing else.
function sync_twins()
    local changed = 0
    local raws = df.global.world.raws.inorganics.all
    for si, ti in pairs(_G.making_fuel_aggregate_twin or {}) do
        pcall(function()
            local sm, tm = raws[si].material, raws[ti].material
            for _, f in ipairs(SPRITE_FIELDS) do
                if tm[f] ~= sm[f] then
                    tm[f] = sm[f]
                    changed = changed + 1
                end
            end
        end)
    end
    if changed > 0 then
        log('DETAIL', ('%d sprite field(s) synced onto twins.'):format(changed), 'SPRITE')
    end
    return changed
end

-- ==========================================
-- THE SWEEP
-- ==========================================
-- The backstop the created event cannot cover: anything that arrived
-- while the module was off, or a save written before the twins existed.
-- The TOOL vector is small and the early out above is two reads.
function sweep()
    sweeps_since_sync = sweeps_since_sync + 1
    if sweeps_since_sync >= SYNC_EVERY then
        sweeps_since_sync = 0
        pcall(sync_twins)
    end
    local n = 0
    pcall(function()
        for _, item in ipairs(df.global.world.items.other.TOOL) do
            if hop(item) then n = n + 1 end
        end
    end)
    if n > 0 then
        log('DETAIL', ('sweep hopped %d gravel to twin stone.'):format(n), 'SWEEP')
    end
end