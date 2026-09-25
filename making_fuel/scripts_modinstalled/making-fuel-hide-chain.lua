--@ module = true
-- making-fuel-hide-chain.lua
-- ==========================================
-- MAKING FUEL: HIDE CHAIN REACTIONS
-- ==========================================
-- Drives the two reactions in making_fuel_reactions_hide.json:
--
--   COMBINE_PARTIAL_SKIN   two leftovers of the same animal -> one
--                          whole skin, plus a smaller leftover
--   PROCESS_SKIN           one skin's worth of glob -> one rawhide
--                          corpsepiece the vanilla tanner accepts
--
-- ==========================================
-- WHY A WATCHER AND NOT JUST THE RAWS
-- ==========================================
-- Two things the raws cannot express, and each one is why a piece of
-- this file exists.
--
-- SAME CREATURE. A reagent can name a reaction_class, which selects
-- the partial TIER, but there is no token for "same material as
-- reagent A". Declared alone, DF binds a llama partial to slot A and a
-- wolf partial to slot B without complaint.
--
-- Sealing slot B AFTER slot A binds does not fix it. DF dispatches a
-- hauler for every slot the moment the job posts, so by the time slot
-- A has an item standing in the workshop, slot B's hauler is already
-- carrying the wrong animal with flags.in_job set. The seal arrives
-- after the search it was meant to constrain has finished.
--
-- TWO DIFFERENT ITEMS is the same story. For a DIMENSIONED reagent DF
-- checks available dimension rather than distinct items, so a single
-- 7 dimension partial satisfies two slots asking for 1 each. The
-- reaction never goes red, a dwarf hauls the only partial there is,
-- and it sits waiting for a second that cannot come.
--
-- So DF never gets to choose. This file claims BOTH partials itself
-- before either slot is searched: pick a creature that has two free
-- and reachable ones, seal both filters to those exact items, attach
-- both, and zero both quantities so nothing is left to seek. If no
-- creature has two, the job is sealed shut and cancels without a
-- single item being touched. That is fill() in making-fuel-rot-watcher
-- applied to two slots instead of one.
--
-- CORPSEPIECE OUT. CORPSEPIECE is in REAGENT_TYPES and NOT in
-- PRODUCT_TYPES, and no vanilla reaction emits a body component
-- either. A reaction can eat a corpsepiece but cannot make one, so
-- PROCESS_SKIN consumes its glob and this file spawns the rawhide
-- through modtools/create-item's hackWish, which is the only route
-- that builds one correctly.
--
-- ==========================================
-- WHAT THE GLOB ARITHMETIC GUARANTEES
-- ==========================================
-- Whole globs are minted ONLY at exact multiples of 150 and partials
-- only below 150. That is what makes both reactions simple:
--
--   PROCESS_SKIN drains 150 at a time from a multiple of 150, so it
--   NEVER leaves a fraction and needs no quantity rewrite at all. A
--   1000% glob is ten runs and ends at zero.
--
--   COMBINE is then the only thing in the whole system that ever adds
--   two dimensions together, which is why the fraction logic lives in
--   one place instead of being smeared across the module.
-- ==========================================

local eventful = require('plugins.eventful')
local repeatUtil = require('repeat-util')

-- listpairs, for walking DF's linked job list. Used by poll; compiling
-- without it succeeds because Lua resolves globals at runtime, so a
-- missing require here throws on the first tick rather than at load.
local utils = require('utils')

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
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'HIDE_REACTIONS'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)
local MOD_PREFIX = 'MAKING_FUEL_'
local EVENT_KEY  = 'making_fuel_hide_rxn'

-- Dimension in one whole skin. Must match the watcher that mints them.
local PER_SKIN = 150

-- MATERIALS carry MOD_PREFIX. REACTIONS carry MOD_PREFIX .. 'RXN_',
-- because refinish-module-react.lua:1411 composes every code as
--   full_id = prefix .. "RXN_" .. def.key
-- Getting this wrong is silent: is_ours simply never matches, the poll
-- finds none of our jobs, and the file prints its start line and then
-- nothing for the rest of the session. MEASURED, twice.
local RXN_PREFIX = MOD_PREFIX .. 'RXN_'

local COMBINE = RXN_PREFIX .. 'COMBINE_PARTIAL_SKIN'
local PROCESS = RXN_PREFIX .. 'PROCESS_SKIN'

local running = false

-- job id -> { a = {mt,mi,dim}, b = {mt,mi,dim}, settled, claimed }
-- a and b are filled while the job runs, because onJobCompleted fires
-- AFTER the reagents are consumed and there is nothing left to measure
-- by then. settled and claimed are COMBINE bookkeeping: settled means
-- the pair claim has been attempted, claimed means it succeeded.
local snap = {}

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
-- SUBJECT is the correlation slot: JOB while a job is claimed, PAY
-- when it completes, MINT for a new glob, START and STOP. The status
-- and usage output answers commands typed at the console, so it
-- prints.
--
-- A job's payout is a YIELD. A payout that fails after the job has
-- consumed its inputs is an ERROR, since the player lost them.
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

local function is_ours(job, key)
    local ok = false
    pcall(function()
        if job.job_type ~= df.job_type.CustomReaction then return end
        ok = (tostring(job.reaction_name) == key)
    end)
    return ok
end

-- ==========================================
-- READING AN ATTACHED REAGENT
-- ==========================================
-- job.items holds what has actually been brought to the workshop.
-- Index is the reagent slot the item filled, so slot 0 is reagent A.
-- ==========================================
local function attached(job, slot)
    local r = nil
    pcall(function()
        for _, iref in ipairs(job.items) do
            if iref.job_item_idx == slot and iref.item then
                local it = iref.item
                local dim = 0
                pcall(function() dim = it.dimension or 0 end)
                -- ---- age, NOT rot_timer ----
                -- MEASURED: rot_timer on a GLOB recycles at 200 and
                -- never sets flags.rotten, on a vanilla llama fat glob
                -- as much as on ours. It is a counter that wraps, not a
                -- clock that expires, so carrying it forward carried
                -- nothing. age counts ticks since creation, never
                -- resets, and is the clock the air dryer already runs
                -- on. See making-fuel-hide-rot.lua.
                local age = 0
                pcall(function() age = it.age or 0 end)
                r = { item = it, mt = it.mat_type, mi = it.mat_index,
                      dim = dim, age = age }
                return
            end
        end
    end)
    return r
end

-- The reagent FILTERS, which is a different vector from job.items.
-- job_items is what DF is looking for; items is what it found.
local function filters(job)
    local vec = nil
    pcall(function()
        local jil = job.job_items
        vec = jil.elements or jil
    end)
    return vec
end

-- ==========================================
-- MINTING
-- ==========================================

local function creator_unit()
    local u = nil
    pcall(function()
        local c = dfhack.units.getCitizens(true)
        if c and c[1] then u = c[1] end
    end)
    return u
end

-- A glob of a known inorganic, placed in the workshop that made it.
-- `age` carries the decay of whatever was consumed to make this. A
-- minted glob starts at zero, so without it every reaction that
-- re-mints a remainder hands the player a brand new hide, and one unit
-- processed off a rotting one resets the clock.
--
-- This was rot_timer until it was measured. A GLOB's rot_timer recycles
-- at 200 and never flips flags.rotten, vanilla fat included, so there
-- was never anything in it to carry. age is ticks since creation, it
-- never resets, and making-fuel-hide-rot.lua spoils on it.
local function mint_glob(mat_index, dim, holder, pos, age)
    local unit = creator_unit()
    if not unit then return nil end

    local g = nil
    local ok = pcall(function()
        local made = dfhack.items.createItem(
            unit, df.item_type.GLOB, -1, 0, mat_index)
        g = made and made[1] or nil
    end)
    if not ok or not g then return nil end

    pcall(function() g:setDimension(dim) end)
    if age and age > 0 then
        local ok_r = pcall(function() g.age = age end)
        if not ok_r then
            log('WARNING', 'could not carry age onto the minted glob. The output'
                .. ' starts fresh and decay has been laundered.', 'MINT')
        end
    end

    local placed = false
    if holder then
        pcall(function()
            placed = dfhack.items.moveToBuilding(g, holder) and true or false
        end)
    end
    if not placed and pos then
        pcall(function() dfhack.items.moveToGround(g, pos) end)
    end
    return g
end

-- ==========================================
-- MAPPING A CURRENCY MATERIAL BACK TO ITS CREATURE
-- ==========================================
-- The glob knows its inorganic; the inorganic's id carries the
-- creature token. Read from the id rather than kept in a side table,
-- because a side table is a second thing that can fall out of step
-- with the roster.
--
--   MAKING_FUEL_HIDE_LLAMA      -> LLAMA, whole
--   MAKING_FUEL_HIDEPART_LLAMA  -> LLAMA, partial
-- ==========================================
local function decode_currency(mat_index)
    local id = nil
    pcall(function()
        id = tostring(df.global.world.raws.inorganics.all[mat_index].id)
    end)
    if not id then return nil end

    local cid = id:match('^' .. MOD_PREFIX .. 'HIDEPART_(.+)$')
    if cid then return cid, 'partial' end
    cid = id:match('^' .. MOD_PREFIX .. 'HIDE_(.+)$')
    if cid then return cid, 'whole' end
    return nil
end

local function currency_index(cid, tier)
    local want = MOD_PREFIX .. (tier == 'partial' and 'HIDEPART_' or 'HIDE_') .. cid
    local idx = nil
    pcall(function()
        local mi = dfhack.matinfo.find('INORGANIC:' .. want)
        if mi then idx = mi.index end
    end)
    return idx
end

-- ==========================================
-- CLAIMING BOTH PARTIALS
-- ==========================================
-- Lives here rather than higher up the file because it calls
-- decode_currency to tell a partial from a whole skin, and a Lua local
-- is invisible above its own definition. Moving it up compiles fine
-- and then fails on the first tick with an attempt to call a nil.
-- ==========================================

-- A reaction_class no material in the world carries. Written onto a
-- filter it makes DF's own search run, fail, and cancel the job the
-- way a furnace out of ore does. Taken from making-fuel-rot-watcher,
-- where a ZEROED quantity was measured to leave the job idling engaged
-- forever instead, because DF saw nothing missing and never searched.
-- Unprefixed, like every other class in the module, because DF prints
-- it at the workshop. "Needs HIDE_PAIR item" at least tells the player
-- what the job wanted. No material carries it, which is the point.
local SEAL_CLASS = 'SKIN_PAIR'

-- Free means DF has not already promised this glob to something else.
-- forbid is respected rather than cleared: a forbidden hide is the
-- player saying do not use this one, and the rot watcher only clears
-- it because rot is garbage nobody meant to keep.
local function free_glob(it)
    local f = it.flags
    return it:getType() == df.item_type.GLOB
       and not f.in_job and not f.artifact and not f.in_building
       and not f.garbage_collect and not f.in_inventory
       and not f.forbid
       -- ---- ROTTEN IS NOT FREE ----
       -- The reagents now carry flags1.unrotten, so DF refuses a
       -- rotten glob when the hauled item arrives and it re-tests the
       -- filter. That check is downstream of this one. If the picker
       -- chose a rotten glob anyway it would seal the filter onto it,
       -- and the job would then stall against a filter that refuses
       -- the exact item we sent it.
       --
       -- The seal at the bottom of this file rewrites item_type,
       -- mat_type, mat_index and quantity but never touches flags1, so
       -- unrotten survives sealing. That is deliberate and is what
       -- makes a partial rotting in transit get turned away at the
       -- door rather than quietly consumed.
       and not f.rotten
end

-- Two partials of ONE creature, both reachable from this job's own
-- workshop. Reachability matters for the same reason it does in the
-- rot watcher: the first match in the world item list once sat across
-- a canyon, and a job sealed to something unwalkable never completes.
--
-- First creature to reach two wins. No preference for the largest sum
-- or the oldest glob, because any pair is a legal pair and picking
-- cleverly would only add a rule to maintain.
local function find_pair(job)
    local b = nil
    pcall(function() b = dfhack.job.getHolder(job) end)
    if not b then return nil end

    local home = xyz2pos(b.centerx, b.centery, b.z)
    local by_mat, found = {}, nil

    pcall(function()
        for _, it in ipairs(df.global.world.items.all) do
            -- mat_type 0 is INORGANIC, which is what the watcher mints.
            -- Without it, a creature-material glob's mat_index would be
            -- read as an inorganic index and decode to a stranger.
            if free_glob(it) and it.mat_type == 0 and (it.dimension or 0) > 0 then
                local cid, tier = decode_currency(it.mat_index)
                if cid and tier == 'partial'
                   and dfhack.maps.canWalkBetween(it.pos, home) then
                    local bucket = by_mat[it.mat_index] or {}
                    by_mat[it.mat_index] = bucket
                    bucket[#bucket + 1] = it
                    if #bucket == 2 then found = bucket return end
                end
            end
        end
    end)
    return found, b
end

-- A filter nothing can match, quantity left at 1 so DF still searches.
local function seal_shut(job)
    local vec = filters(job)
    if not vec then return end
    pcall(function()
        for i = 0, #vec - 1 do
            vec[i].item_type      = -1
            vec[i].item_subtype   = -1
            vec[i].reaction_class = SEAL_CLASS
            vec[i].mat_type       = -1
            vec[i].mat_index      = -1
            vec[i].quantity       = 1
        end
    end)
end

-- Returns true once the job owns two items, false once it has been
-- sealed shut. Either way it is a final answer and the caller stops
-- asking; a pair that shows up later belongs to the next job.
local function claim_pair(job)
    local vec = filters(job)
    if not vec or #vec < 2 then
        log('ERROR', string.format('job %d has %d filter(s), expected 2. Sealed shut.',
            job.id, vec and #vec or 0), 'JOB')
        seal_shut(job)
        return false
    end

    local pair, b = find_pair(job)
    if not pair then
        -- INFO: it answers why the job the player queued cancelled.
        log('INFO', string.format('job %d: no creature has two free reachable'
            .. ' partials. Cancelling before anything is hauled.', job.id), 'JOB')
        seal_shut(job)
        return false
    end

    for slot = 0, 1 do
        local it = pair[slot + 1]

        -- Mirror the chosen item onto its filter. Measured in the rot
        -- watcher: DF re-tests the live filter when the hauled item
        -- arrives, so the filter has to still match the thing we sent.
        local ok_seal, err_seal = pcall(function()
            local mi = dfhack.matinfo.decode(it)
            vec[slot].item_type      = it:getType()
            vec[slot].item_subtype   = it:getSubtype()
            vec[slot].reaction_class = ''
            vec[slot].mat_type       = mi and mi.type or -1
            vec[slot].mat_index      = mi and mi.index or -1
            vec[slot].quantity       = 1
        end)
        if not ok_seal then
            log('ERROR', string.format('job %d slot %d SEAL failed: %s. Sealed shut.',
                job.id, slot, tostring(err_seal)), 'JOB')
            seal_shut(job)
            return false
        end

        -- Already standing on the workshop's tiles: Reagent. Anywhere
        -- else: Hauled, and a dwarf brings it.
        local on_site = it.pos.z == b.z
            and dfhack.buildings.containsTile(b, it.pos.x, it.pos.y)
        local role = on_site and df.job_role_type.Reagent
                              or df.job_role_type.Hauled

        local ok_att, err_att = pcall(function()
            dfhack.job.attachJobItem(job, it, role, slot, -1)
        end)
        if not ok_att then
            log('ERROR', string.format('job %d slot %d ATTACH of item %d failed: %s.'
                .. ' Sealed shut.', job.id, slot, it.id, tostring(err_att)), 'JOB')
            seal_shut(job)
            return false
        end

        -- Nothing left to seek. An attached item in transit does NOT
        -- count toward the quantity, so leaving it at 1 sends a second
        -- hauler after a second item, which is the bug this replaces.
        local ok_q, err_q = pcall(function() vec[slot].quantity = 0 end)
        if not ok_q then
            log('WARNING', string.format('job %d slot %d QUANTITY zero failed: %s.',
                job.id, slot, tostring(err_q)), 'JOB')
        end
    end

    local cid = decode_currency(pair[1].mat_index) or '?'
    log('DETAIL', string.format('job %d claimed %s partials #%d (%d) and #%d (%d).',
        job.id, cid, pair[1].id, pair[1].dimension,
        pair[2].id, pair[2].dimension), 'JOB')
    return true
end

-- ==========================================
-- COMBINE PAYOUT
-- ==========================================
-- Sum the two partials. At or above one skin's worth, pay a whole glob
-- and hand back whatever is left as a smaller partial. Below it, pay a
-- single larger partial, which is the two-wolves case: 86 plus 86 is
-- 172, so one whole skin and a 22 leftover.
-- ==========================================
local function pay_combine(job)
    local s = snap[job.id]
    if not s or not s.a then return end

    -- BOTH slots or nothing. With one partial bound, an earlier version
    -- summed A alone and re-minted the same glob it had just eaten: a
    -- job that costs labour, looks successful and changes nothing.
    --
    -- DF does not stop this on its own. For DIMENSIONED reagents it
    -- checks available dimension rather than distinct items, so a
    -- single 7 dimension partial appears to satisfy two slots asking
    -- for 1 each, and the reaction never goes red. The declaration
    -- cannot express "two different items", so the guard lives here.
    if not s.b then
        log('ERROR', string.format('job %d had only one partial bound. Nothing paid;'
            .. ' the glob is gone. This job should have been cancelled'
            .. ' before it ran.', job.id), 'PAY')
        return
    end

    local total = (s.a.dim or 0) + (s.b.dim or 0)
    if total <= 0 then
        log('WARNING', string.format('job %d combined to nothing.', job.id), 'PAY')
        return
    end

    local cid = decode_currency(s.a.mi)
    if not cid then
        log('ERROR', string.format('job %d: could not decode currency material %d.',
            job.id, s.a.mi), 'PAY')
        return
    end

    local holder, pos = nil, nil
    pcall(function() holder = dfhack.job.getHolder(job) end)
    pcall(function() if holder then pos = holder.centerx and
        xyz2pos(holder.centerx, holder.centery, holder.z) or nil end end)

    local whole = math.floor(total / PER_SKIN)
    local rem   = total - whole * PER_SKIN

    -- ---- CONSUME THE SOURCES WHOLE ----
    -- A GLOB reagent's quantity is DIMENSION, and both slots ask for 1
    -- because any partial has to satisfy them. So DF takes exactly 1
    -- from each and leaves the rest. MEASURED: job 370 claimed #3354
    -- and #3392 at 36 each, and job 375 claimed the SAME TWO ITEMS a
    -- minute later, because 35 of each was still lying there.
    --
    -- Raising the declared quantity cannot fix it: a fixed number
    -- would reject every partial smaller than it, and the whole point
    -- of a partial is that its size is unknown until it exists. So the
    -- reagent stays at 1 to keep the reaction green, and the two globs
    -- are removed here, where their exact dimensions are already known
    -- and already counted into total.
    for _, side in ipairs({ s.a, s.b }) do
        if side.id then
            local ok = pcall(function()
                local it = df.item.find(side.id)
                if it then dfhack.items.remove(it) end
            end)
            if not ok then
                log('WARNING', string.format('job %d: could not remove source glob'
                    .. ' #%d. It is still on the floor with its last'
                    .. ' dimension.', job.id, side.id), 'PAY')
            end
        end
    end

    -- ---- THE WORST TIMER OF WHAT WENT IN ----
    -- Read BEFORE the sources are removed above would be tidier, but
    -- they are gone by here, so it is captured into the snapshot at
    -- pickup instead. Highest rather than average: combining a fresh
    -- scrap with a nearly rotten hide must not refresh the hide.
    local carried = math.max(s.a.age or 0, (s.b and s.b.age) or 0)

    local made = 0
    if whole > 0 then
        local idx = currency_index(cid, 'whole')
        if idx and mint_glob(idx, whole * PER_SKIN, holder, pos, carried) then
            made = made + 1
        end
    end
    if rem > 0 then
        local idx = currency_index(cid, 'partial')
        if idx and mint_glob(idx, rem, holder, pos, carried) then
            made = made + 1
        end
    end

    -- YIELD when anything was made. When nothing was, the line below
    -- is the ERROR and this one is only the arithmetic.
    log(made > 0 and 'YIELD' or 'DETAIL', string.format('job %d: %s %d + %d = %d -> %d whole skin(s), %d left.',
        job.id, cid, s.a.dim, (s.b and s.b.dim) or 0, total, whole, rem), 'PAY')
    if made == 0 then
        log('ERROR', string.format('job %d paid NOTHING. %d dimension lost.',
            job.id, total), 'PAY')
    end
end

-- ==========================================
-- PROCESS PAYOUT
-- ==========================================
-- One rawhide corpsepiece per completion. Built through hackWish
-- rather than by hand: a corpsepiece needs race, normal_race,
-- normal_caste, sex, largest_tissue, largest_unrottable_tissue,
-- bp_modifiers, body_part_relsize, body_part_status, layer_status and
-- caste written LAST, and modtools/create-item does all of it in the
-- right order.
-- ==========================================
local function pay_process(job)
    local s = snap[job.id]
    if not s or not s.a then return end

    local cid = decode_currency(s.a.mi)
    if not cid then
        log('ERROR', string.format('job %d: could not decode currency material %d.',
            job.id, s.a.mi), 'PAY')
        return
    end

    local race, race_raw = nil, nil
    pcall(function()
        for i, cr in ipairs(df.global.world.raws.creatures.all) do
            if tostring(cr.creature_id) == cid then race, race_raw = i, cr return end
        end
    end)
    if not race then
        log('ERROR', string.format('job %d: no creature called %s in this world.',
            job.id, cid), 'PAY')
        return
    end

    -- The tissue index inside the creature's own material list.
    -- createCorpsePiece reads a generic tissue as
    -- creatorRaceRaw.material[partlayer].id, so this is a direct zero
    -- based index found by NAME, never assumed.
    local mat_idx = nil
    pcall(function()
        for i, m in ipairs(race_raw.material) do
            if tostring(m.id):upper() == 'SKIN' then mat_idx = i return end
        end
    end)
    if not mat_idx then
        log('ERROR', string.format('job %d: %s has no SKIN tissue.', job.id, cid), 'PAY')
        return
    end

    local unit = creator_unit()
    if not unit then
        log('ERROR', string.format('job %d: no citizen to build against.', job.id), 'PAY')
        return
    end

    -- The accessor contract, read off gui/create-item. For a GENERIC
    -- corpsepiece get_mat returns:
    --   ok, mattype, matindex, caste, bodypart, partlayer, generic
    local accessors = {
        get_unit        = function() return unit end,
        get_item_type   = function()
            return true, df.item_type.CORPSEPIECE, -1
        end,
        get_mat         = function()
            return true, -1, race, 0, 1, mat_idx, true
        end,
        get_quality     = function() return true, df.item_quality.Ordinary end,
        get_description = function() return true, '' end,
        get_count       = function() return true, 1 end,
    }

    local made = nil
    local ok, err = pcall(function()
        local mod = reqscript('modtools/create-item')
        made = mod.hackWish(accessors, { count = 1, pos = unit.pos })
    end)
    if not ok or not made or #made == 0 then
        log('ERROR', string.format('job %d: rawhide creation failed: %s',
            job.id, tostring(err)), 'PAY')
        return
    end

    local it = made[1]

    -- ==========================================
    -- IT COMES OUT AS LEATHER. MAKE IT A HIDE.
    -- ==========================================
    -- MEASURED, side by side against a rawhide DF's own butchery made:
    --
    --   DF's     corpse_flags: rottable use_blood_color
    --            material_amount: empty
    --   hackWish corpse_flags: leather
    --            material_amount: Leather=1
    --
    -- Leather does not rot, so DF was right to leave the timer at zero
    -- for the whole session. The material token still decodes as
    -- CREATURE:<x>:SKIN either way, which is what hid it.
    --
    -- Written to match the reference exactly rather than only adding
    -- rottable. A piece still flagged leather carrying one unit of
    -- leather is a tanned product to everything downstream of here,
    -- including whatever the player queues next.
    for _, fix in ipairs({ { 'leather', false },
                           { 'rottable', true },
                           { 'use_blood_color', true } }) do
        local ok_f = pcall(function() it.corpse_flags[fix[1]] = fix[2] end)
        if not ok_f then
            log('WARNING', string.format('job %d: could not set corpse_flags.%s.',
                job.id, fix[1]), 'PAY')
        end
    end
    pcall(function()
        for i in ipairs(it.material_amount) do it.material_amount[i] = 0 end
    end)

    -- ---- NO UNROTTABLE TISSUE ----
    -- MEASURED against a DF built skin: the donor reads -1/-1, ours
    -- came out pointing at the creature's own material. A raw skin has
    -- no unrottable part, and this is the field DF reads to decide what
    -- survives once the piece finishes rotting. Left as it was, the
    -- hide would rot down and leave something behind that a real one
    -- does not.
    for _, f in ipairs({ 'mat_type', 'mat_index' }) do
        local ok_u = pcall(function()
            it.largest_unrottable_tissue[f] = -1 end)
        if not ok_u then
            log('WARNING', string.format('job %d: could not clear'
                .. ' largest_unrottable_tissue.%s.', job.id, f), 'PAY')
        end
    end

    -- ---- BEFORE IT CAN BE SEEN ----
    -- The butcher watcher hunts raw hides, and this IS a raw hide. Left
    -- unmarked it pays currency for the thing we just finished paying
    -- currency to make. Marked here, synchronously, so the watcher's
    -- poll cannot land between the creation and the mark.
    pcall(function()
        reqscript('making-fuel-hide-watcher').ignore(it.id)
    end)

    local holder = nil
    pcall(function() holder = dfhack.job.getHolder(job) end)
    if holder then pcall(function() dfhack.items.moveToBuilding(it, holder) end) end

    local desc = '?'
    pcall(function() desc = dfhack.items.getDescription(it, 0) end)
    log('YIELD', string.format('job %d: %s -> #%d "%s"', job.id, cid, it.id, desc), 'PAY')
end

-- ==========================================
-- EVENTS
-- ==========================================
-- There is NO onJobInitiated hook here, and that is deliberate.
-- eventful only calls a hook if something has enabled that event type,
-- and nothing in Making Fuel enables JOB_INITIATED. MEASURED: with the
-- hook installed this file printed its start line and then nothing at
-- all across a full COMBINE and a full PROCESS, because on_init never
-- ran, nothing was ever put in snap, and the poll had nothing to visit.
--
-- So jobs are discovered the way making-fuel-rot-watcher discovers
-- them: by walking the job list in our own poll. That depends on
-- nothing outside this file and also picks up jobs that were already
-- queued when the script started.
-- ==========================================

-- Called every poll for every tracked job. Two jobs of its own: get a
-- COMBINE its two partials on the first look, and keep a live copy of
-- what is attached, because at completion the items no longer exist.
--
-- The claim runs ONCE. s.settled records that the question has been
-- answered either way, so a job that was sealed shut is not re-sealed
-- and re-logged every ten frames while DF gets around to cancelling
-- it. A pair that appears later belongs to the next job.
local function measure(job)
    local s = snap[job.id]
    if not s then return end

    if is_ours(job, COMBINE) and not s.settled then
        s.settled = true
        s.claimed = claim_pair(job)
    end

    -- The item ID is kept because pay_combine has to destroy the two
    -- source globs itself. See the note there.
    -- age rides along, or the carry below has nothing to read. The
    -- previous version of this line dropped it, which is why the
    -- laundering guard has never once fired: carried was computed from
    -- a field the snapshot did not store.
    local a = attached(job, 0)
    if a then s.a = { id = a.item.id, mt = a.mt, mi = a.mi, dim = a.dim,
                      age = a.age } end
    local b = attached(job, 1)
    if b then s.b = { id = b.item.id, mt = b.mt, mi = b.mi, dim = b.dim,
                      age = b.age } end
end

local function on_done(job)
    if not running then return end
    pcall(function()
        if is_ours(job, COMBINE) then pay_combine(job)
        elseif is_ours(job, PROCESS) then pay_process(job) end
    end)
    snap[job.id] = nil
end

-- ==========================================
-- POLL
-- ==========================================
-- Walks every live job, registers ours on first sight, then measures.
-- A job seen here for the first time has not had a reagent attached
-- yet in the normal case, which is the window claim_pair needs.
--
-- The sweep at the end drops snapshots for jobs that left the list
-- without completing, which is what a cancellation looks like from in
-- here. Without it snap grows for the whole session. on_done clears
-- its own entry, so anything this sweep finds was cancelled.
local function poll()
    if not dfhack.isMapLoaded() then return end
    pcall(function()
        local live = {}
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            if is_ours(job, COMBINE) or is_ours(job, PROCESS) then
                live[job.id] = true
                if not snap[job.id] then snap[job.id] = {} end
                measure(job)
            end
        end
        for id in pairs(snap) do
            if not live[id] then snap[id] = nil end
        end
    end)
end

-- ==========================================
-- LIFECYCLE
-- ==========================================
function start()
    if running then log('DETAIL', 'already running.', 'START') return end
    running = true
    -- Enable it ourselves rather than relying on the hijacker having
    -- done it. A hook on an event nobody enabled is simply never
    -- called, and it fails without a word in the log.
    pcall(function()
        eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)
    end)
    eventful.onJobCompleted[EVENT_KEY] = on_done
    repeatUtil.scheduleEvery(EVENT_KEY, 10, 'frames', poll)
    log('DETAIL', 'watching ' .. COMBINE .. ' and ' .. PROCESS, 'START')
end

function stop()
    running = false
    eventful.onJobCompleted[EVENT_KEY] = nil
    repeatUtil.cancel(EVENT_KEY)
    snap = {}
    log('DETAIL', 'stopped.', 'STOP')
end

function status()
    local n = 0
    for _ in pairs(snap) do n = n + 1 end
    print(string.format('running %s, %d job(s) tracked', tostring(running), n))
end

-- ==========================================
-- CLI
-- ==========================================
-- The guard is not optional. `--@ module = true` only makes the file
-- reqscript-able; it does NOT stop the body running.
-- ==========================================
if dfhack_flags and dfhack_flags.module then return end

local cmd = ...
if cmd == 'on' then start()
elseif cmd == 'off' then stop()
elseif cmd == 'status' then status()
else print('usage: making-fuel-hide-chain on | off | status') end