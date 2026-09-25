-- making-fuel-cremate-watcher.lua
-- =====================================================================
-- CREMATION
-- =====================================================================
-- Two reactions the player queues natively, CREMATE_CITIZEN and
-- CREMATE_PET. This file does the one thing DF cannot: it picks the
-- corpse.
--
-- WHY DF CANNOT DO IT, measured rather than assumed
--
-- Nothing on a corpse ITEM separates a citizen from an invader.
-- `dead_dwarf` looks like it should and does not: it is true for a
-- dwarf citizen, a pet sheep AND an amphibian man spearman, and false
-- only for a wild animal. It is the inverse of `butcherable`, which is
-- what a butcher will take. `ANY_DEAD_DWARF`, the job item vector,
-- holds the same three. `ANY_BUTCHERABLE` holds all nine corpses in
-- the fort including the citizen and the pet. See L16 and L17 in the
-- register; every one of those was read off a live fort.
--
-- What DOES separate them lives on the UNIT, reached through the
-- corpse's `unit_id`:
--
--   dfhack.units.isCitizen(unit, true)   true on a DEAD citizen
--   dfhack.units.isPet(unit)             true on a dead pet
--
-- The API describes isCitizen as "non-dead". With the second parameter
-- it answers on a corpse anyway, which is measured, and it is the
-- whole reason this feature is possible at all.
--
-- HOW IT WORKS, and it is the rot watcher's shape because that shape
-- is proven and has been debugged hard
--
--   1. A key exists at a furnace exactly while a cremateable corpse is
--      reachable from it. The reaction's reagent asks for the key's
--      class, so the menu reads white when there is something to burn
--      and red when there is not. No key, no lie.
--   2. When a job is queued, the filter is SEALED to the chosen corpse,
--      its exact type and material, and the corpse is attached. DF
--      re-tests the live filter on delivery, so the seal is what makes
--      the corpse acceptable on arrival. The key stops matching the
--      moment the seal lands, which is its protection.
--   3. If there is nothing to burn, the filter is sealed SHUT and DF
--      cancels the job itself, the way a furnace out of ore does.
--
-- THE KEY IS NEVER CONSUMED. It is a menu light, not a reagent. The
-- corpse is what the reaction eats.
--
-- ITS OWN ITEMDEF, `MAKING_FUEL_CREMATE_KEY`. The drain key watcher
-- sweeps every `DRAIN_KEY` tool it does not recognise as one of its
-- retorts, and the rot watcher owns `ROT_KEY`. Sharing an itemdef with
-- either would have that watcher delete this one on its next poll.
--
-- TWO KEYS, ONE PER KIND, so the two menus light independently. A fort
-- with a dead sheep and no dead dwarves reads white on the pet
-- reaction and red on the citizen one, which is the truth.
--
-- NO CLEANUP HERE. The engine sweeps materials and reactions by
-- prefix. Keys are ITEMS, so they are purged at session start instead:
-- a per retort style material is minted after `ledger.write()` every
-- session without exception, so a key that survived a data cycle
-- carries an index the ledger never recorded and can never fix. Purged
-- by TOOL SUBTYPE, which matches whatever the material became.
--
-- Nothing is silent: every state prints once on entry and once on exit.
-- =====================================================================

--@ module = true

local repeatUtil = require('repeat-util')

-- ---------------------------------------------------------------------
-- CONSTANTS
-- ---------------------------------------------------------------------
-- ---- TWO SPEEDS ----
-- Measured 2026-09-13: 358 ms of every wall second, because
-- tend_keys() rode the job poll's one frame cadence and walked every
-- item in the fort five times per frame.
--
-- The jobs keep the one frame cadence for the seal race described
-- below. The key invariant moves to 100 frames, matching the drain
-- key watcher, which holds the same kind of invariant over the same
-- kind of sweep for 1.1 ms/sec.
local REPEAT_KEY  = 'making-fuel-cremate-watcher'
-- One frame, the same as the rot watcher and for the same reason: the
-- seal has to land before DF's own fetcher reaches the key.
local POLL_FRAMES = 1
local KEY_KEY     = 'making-fuel-cremate-watcher-keys'
local KEY_FRAMES  = 100

local PREFIX      = 'MAKING_FUEL_'
local RXN_PREFIX  = 'MAKING_FUEL_RXN_'
local KEY_TOOL    = 'MAKING_FUEL_CREMATE_KEY'
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
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'CREMATE_WATCHER'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

-- The two kinds, and everything that differs between them. Adding a
-- third is a row here and a reaction; nothing below knows how many
-- there are.
--
-- `pick` is handed the corpse's UNIT and answers whether this kind
-- claims it. Order matters only in that a unit answering true to two
-- rows would be claimed by whichever is checked first, and a unit
-- cannot be both a citizen and a pet.
--
-- `class` is the reaction_class the reagent asks for, which is ALSO
-- the word the workshop prints in its requirement line, so it is
-- player facing and will be renamed for how it reads. It has to be
-- stated here rather than derived.
--
-- It used to be pulled out of `rxn` with a pattern, on the assumption
-- that the reaction key and the class would always share a name. They
-- do not: the class changed to CITIZEN and PET for the workshop text
-- while the reaction keys stayed CREMATE_CITIZEN and CREMATE_PET. The
-- pattern kept returning the old word and the only place it showed
-- was the cancellation message, which would have read "needs
-- CREMATE_CITIZEN" under a workshop line reading "CITIZEN".
--
-- `mat` is the material KEY and is a different thing again. Renaming a
-- class does not touch it. If it is ever wrong the watcher says
-- "cremation key materials not injected yet" forever, which is loud.
local KINDS = {
    {
        name  = 'citizen',
        rxn   = RXN_PREFIX .. 'CREMATE_CITIZEN',
        mat   = PREFIX .. 'CREMATE_CITIZEN',
        class = 'CITIZEN',
        pick  = function(u) return dfhack.units.isCitizen(u, true) == true end,
    },
    {
        name  = 'pet',
        rxn   = RXN_PREFIX .. 'CREMATE_PET',
        mat   = PREFIX .. 'CREMATE_PET',
        class = 'PET',
        pick  = function(u) return dfhack.units.isPet(u) == true end,
    },
}

-- Both reactions live at the wood furnace, the pyre. Matched on the
-- furnace_type enum by NAME, because the enum keys are mixed case and
-- a wrong key is nil, and a nil table index throws at load and kills
-- the whole file from the overlay's point of view.
local SITE_FURNACES = { 'WoodFurnace' }

-- ---------------------------------------------------------------------
-- SESSION STATE
-- ---------------------------------------------------------------------
-- All dropped in start(). A data cycle deletes the materials these
-- indices point at, and start() runs again on the next cycle.
local said         = {}    -- log-once keys
local mat_index    = {}    -- kind name -> inorganic index
local key_subtype  = nil
local filled       = {}    -- job id -> item id attached
local attach_fail  = {}    -- job id -> true, so a failure prints once
local purged       = false

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
-- SUBJECT is the correlation slot: KEY for the menu keys, MENU for a
-- menu opening or closing, JOB for a single cremation, RESOLVE and SITE
-- for what the watcher waits on, POLL, START and STOP.
--
-- once() and clear() say a state once and its recovery once. Each call
-- states its TYPE and SUBJECT like any log line: the state is usually a
-- fault, and its recovery usually DETAIL. clear() with no message
-- only resets the state.
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
local function once(k, typ, msg, subject)
    if not said[k] then said[k] = true log(typ, msg, subject) end
end
local function clear(k, typ, msg, subject)
    if said[k] then said[k] = nil if msg then log(typ, msg, subject) end end
end

-- ---------------------------------------------------------------------
-- LOOKUPS
-- ---------------------------------------------------------------------
-- Resolved fresh and A MISS IS NEVER CACHED. Materials and itemdefs
-- inject AFTER this script starts, so a cached nil would poison the
-- entry for the whole session and the watcher would silently never
-- work again.
local function find_material(id)
    local idx = nil
    pcall(function()
        local mi = dfhack.matinfo.find('INORGANIC:' .. id)
        if mi then idx = mi.index end
    end)
    return idx
end

-- Resolution is RM's job now; see the note in the rot watcher.
local resolve = reqscript('refinish-resolve')

-- ---- EPOCH CACHED RESOLVERS ----
-- The tool subtype and both key material indices were rebuilt every
-- frame: one itemdefs walk that tostring'd every tool definition,
-- plus a raws search per kind. They change only when the injected
-- data does, and _G.refinish_ram_loaded is the flag that says so.
--
-- Misses are never cached. Injection lands after this script starts,
-- so a stored nil would defer forever; only hits are kept, and the
-- deferral lines below fire until they arrive.
local last_epoch = nil

-- ---- RESOLVED EVERY POLL, CACHED IN THE CORE ----
-- Same correction as the rot watcher: the local epoch compared
-- against _G.refinish_ram_loaded could not see a wash it was gated
-- out of, so a stale index survived a data cycle. mat_index is now
-- rebuilt from the core cache each poll rather than remembered, and
-- stays a table because is_key_of reads it per item inside a walk.
local function ensure_resolved()
    key_subtype = resolve.tool_subtype(KEY_TOOL)
    if not key_subtype then
        -- DETAIL: every startup waits here until the module injects.
        once('tool', 'DETAIL', KEY_TOOL .. ' itemdef not injected yet;'
             .. ' deferring.', 'RESOLVE')
        return false
    end
    clear('tool', 'DETAIL', KEY_TOOL .. ' itemdef resolved.', 'RESOLVE')

    local ready = true
    for _, k in ipairs(KINDS) do
        mat_index[k.name] = resolve.material_index('INORGANIC:' .. k.mat)
        if not mat_index[k.name] then ready = false end
    end
    if not ready then
        once('mat', 'DETAIL', 'cremation key materials not injected yet;'
             .. ' deferring.', 'RESOLVE')
        return false
    end
    clear('mat', 'DETAIL', 'cremation key materials resolved.', 'RESOLVE')

    return true
end

-- ---------------------------------------------------------------------
-- SITES
-- ---------------------------------------------------------------------
local function sites()
    local out = {}
    pcall(function()
        for _, b in ipairs(df.global.world.buildings.all) do
            pcall(function()
                if b:getType() ~= df.building_type.Furnace then return end
                if b:getBuildStage() ~= b:getMaxBuildStage() then return end
                local name = df.furnace_type[b.type]
                for _, want in ipairs(SITE_FURNACES) do
                    if name == want then table.insert(out, b) return end
                end
            end)
        end
    end)
    return out
end

-- ---------------------------------------------------------------------
-- THE KEYS
-- ---------------------------------------------------------------------
-- Matched on TOOL SUBTYPE alone for the purge and the stray sweep, so
-- a key whose material went stale across a data cycle is still found.
-- Matched on subtype AND material to say which kind it is.
-- ---- NO pcall INSIDE AN ITEM LOOP ----
-- A pcall allocates a closure on every call, and this predicate runs
-- once per item per walk: at five walks a frame that was the bulk of
-- this file's 358 ms/sec.
--
-- Nothing is less protected than before. Every caller already wraps
-- its whole walk in one pcall (keys_at, the session purge, the stray
-- sweep, and poll itself), so a throw here is still caught, one
-- level up, once per walk instead of once per item.
local function is_any_key(it)
    if not key_subtype then return false end
    if it:getType() ~= df.item_type.TOOL then return false end
    return it:getSubtype() == key_subtype
end

-- ---- TYPE FIRST. NOT AN OPTIMISATION CHOICE ----
-- is_any_key asks getType, which is virtual and implemented by every
-- item class. mat_index and mat_type are fields only item_actualst
-- subclasses carry, and reading them on a corpse THROWS. This walk
-- visits every item in the fort, so it meets one immediately.
--
-- Reordering these to put the cheap integer compares first was
-- wrong, and it failed SILENTLY here where the rot watcher failed
-- loudly: keys_at wraps its walk in its own pcall, so the throw was
-- swallowed, the returned list came back empty, and this file would
-- have minted a duplicate key every poll the moment any citizen or
-- pet remains became reachable.
local function is_key_of(it, kind)
    local idx = mat_index[kind.name]
    if not idx then return false end
    if not is_any_key(it) then return false end
    if it.mat_index ~= idx then return false end
    return it.mat_type == 0
end

-- Hidden, unforbidden, never an artifact, unclaimed. Measured on the
-- rot key: claiming it with in_job reds the menu, because the scanner
-- does not count claimed items. So the seal is its protection, not a
-- claim.
local function dress(it)
    pcall(function()
        it.flags.hidden   = true
        it.flags.forbid   = false
        it.flags.artifact = false
        it.flags.dump     = false
        it.flags.in_job   = false
    end)
end

-- ---------------------------------------------------------------------
-- WHAT CAN BE CREMATED
-- ---------------------------------------------------------------------
-- A corpse or a body part whose unit this kind claims. The unit lookup
-- is the whole discriminator; nothing on the item can do it.
local function corpse_unit(it)
    local u = nil
    pcall(function() u = df.unit.find(it.unit_id) end)
    return u
end

-- Same pcall reasoning as is_any_key: find_remains wraps its walk,
-- so this is caught one level up and costs no closure per item.
local function is_remains(it)
    local ty = it:getType()
    if ty ~= df.item_type.CORPSE and ty ~= df.item_type.CORPSEPIECE then
        return false
    end
    local f = it.flags
    return not f.in_job and not f.artifact and not f.construction
       and not f.in_building and not f.garbage_collect
end

-- Reachability, not list order. The rot watcher learned this the hard
-- way: the first matching item in the world list once sat across a
-- canyon and the job flickered forever. Items inside containers are
-- skipped, since hauling out of a container is a separate DF flow this
-- file does not manage.
local function find_remains(kind, b)
    local home = xyz2pos(b.centerx, b.centery, b.z)
    local hit = nil
    pcall(function()
        for _, it in ipairs(df.global.world.items.all) do
            if is_remains(it) and not it.flags.in_inventory then
                local u = corpse_unit(it)
                if u and kind.pick(u)
                   and dfhack.maps.canWalkBetween(it.pos, home) then
                    hit = it
                    return
                end
            end
        end
    end)
    return hit
end

-- ---------------------------------------------------------------------
-- THE KEY INVARIANT
-- ---------------------------------------------------------------------
-- Exactly one key of each kind at each site that can reach something
-- of that kind. None anywhere else.
local function keys_at(p, kind)
    local found = {}
    pcall(function()
        for _, it in ipairs(df.global.world.items.all) do
            if is_key_of(it, kind) and it.pos.x == p.x and it.pos.y == p.y
               and it.pos.z == p.z then
                table.insert(found, it)
            end
        end
    end)
    return found
end

local function mint(kind, b, p)
    local maker = nil
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(u) then maker = u break end
    end
    if not maker then
        once('citizen', 'WARNING', 'no living citizen to credit the mint; deferring.', 'KEY')
        return nil
    end
    clear('citizen', 'DETAIL', 'citizen available.', 'KEY')

    local ok, made = pcall(dfhack.items.createItem, maker,
        df.item_type.TOOL, key_subtype, 0, mat_index[kind.name])
    local it = ok and made or nil
    if type(it) == 'table' and it[1] ~= nil then it = it[1] end
    if not it then
        log('ERROR', ('%s key mint FAILED (%s).'):format(kind.name, tostring(made)), 'KEY')
        return nil
    end
    dress(it)
    if not dfhack.items.moveToGround(it, p) then
        log('WARNING', ('%s key minted but could not be placed. Report this line.')
            :format(kind.name), 'KEY')
        return nil
    end
    return it
end

local function tend_keys()
    -- Resolution, deferral and the once/clear lines all moved into
    -- ensure_resolved so the fast job poll can share them.
    if not ensure_resolved() then return end

    -- ---- SESSION PURGE ----
    -- Every key from before the last data cycle carries a material
    -- index the ledger never recorded, because these are minted from a
    -- poll and a poll always lands after ledger.write(). None of them
    -- are trusted. A key held by a job in flight is left alone: that
    -- job either completes or is cancelled, and the sweep collects it
    -- afterwards.
    if not purged then
        purged = true
        local doomed = {}
        pcall(function()
            for _, it in ipairs(df.global.world.items.all) do
                if is_any_key(it) and not it.flags.in_job then
                    doomed[#doomed + 1] = it
                end
            end
        end)
        for _, it in ipairs(doomed) do pcall(dfhack.items.remove, it) end
        if #doomed > 0 then
            log('DETAIL', ('session start: %d key(s) from a previous data cycle'
                 .. ' scrapped. They mint again where they are owed.')
                :format(#doomed), 'KEY')
        end
    end

    local where = sites()
    if #where == 0 then
        once('site', 'DETAIL', 'no completed wood furnace yet; keys mint when one exists.', 'SITE')
    else
        clear('site', 'DETAIL', ('%d pyre(s) watched.'):format(#where), 'SITE')
    end

    -- Collected first, removed after. Removing inside the walk mutates
    -- the vector under the iterator and skips the next entry, which is
    -- how the rot watcher's sweep let one of two strays through.
    local placed = {}
    for _, b in ipairs(where) do
        local p = xyz2pos(b.centerx, b.centery, b.z)
        for _, k in ipairs(KINDS) do
            local held = keys_at(p, k)
            if find_remains(k, b) then
                if #held == 0 then
                    local it = mint(k, b, p)
                    if it then
                        placed[it.id] = true
                        -- Clearing the close key is what lets the pair
                        -- alternate. Without it the second closing of
                        -- the same menu would be SILENT, which is
                        -- worse than the spam it replaces. Cancel a
                        -- job and this is the path that runs.
                        clear('shut:' .. b.id .. ':' .. k.name)
                        log('DETAIL', ('%s remains are reachable from building %d;'
                             .. ' its menu opens.'):format(k.name, b.id), 'MENU')
                    end
                else
                    dress(held[1])
                    placed[held[1].id] = true
                    for i = 2, #held do
                        pcall(dfhack.items.remove, held[i])
                    end
                end
            elseif #held > 0 then
                for _, x in ipairs(held) do pcall(dfhack.items.remove, x) end
                -- ONCE, keyed on the building and the kind.
                -- `dfhack.items.remove` is DEFERRED: the item is
                -- flagged and collected later, so `keys_at` keeps
                -- finding it for several polls and this branch runs
                -- again each time. The first live run printed this
                -- line 96 times. The removal is idempotent and
                -- harmless to repeat; the LINE is not.
                once('shut:' .. b.id .. ':' .. k.name, 'DETAIL', ('no %s remains reachable from building %d;'
                      .. ' its menu closes.'):format(k.name, b.id), 'MENU')
            end
        end
    end

    local doomed = {}
    pcall(function()
        for _, it in ipairs(df.global.world.items.all) do
            if is_any_key(it) and not placed[it.id] and not it.flags.in_job then
                doomed[#doomed + 1] = it
            end
        end
    end)
    for _, it in ipairs(doomed) do pcall(dfhack.items.remove, it) end
end

-- ---------------------------------------------------------------------
-- THE JOBS
-- ---------------------------------------------------------------------
-- Matched by PREFIX, not equality: the ghost renames a job's reaction
-- to a per job clone at pickup, so a name test would stop matching the
-- moment the swap lands.
local function kind_of_job(name)
    for _, k in ipairs(KINDS) do
        if name:sub(1, #k.rxn) == k.rxn then return k end
    end
    return nil
end

local function attached(job)
    local it = nil
    pcall(function()
        for _, ref in ipairs(job.items) do
            if ref.role == df.job_role_type.Hauled
               or ref.role == df.job_role_type.Reagent then
                it = ref.item
                return
            end
        end
    end)
    return it
end

-- The seal MIRRORS the chosen item: its type, subtype and exact
-- material. DF re-tests the live filter when the hauled item arrives,
-- so a filter matching nothing cancels the job on delivery, and a
-- filter shaped like this corpse accepts this corpse. The key stops
-- matching at the same instant, which is what protects it.
local function seal_to(job, it)
    return pcall(function()
        local vec = job.job_items.elements or job.job_items
        if #vec == 0 then error('job has no item filter') end
        local mi = dfhack.matinfo.decode(it)
        vec[0].item_type      = it:getType()
        vec[0].item_subtype   = it:getSubtype()
        vec[0].mat_type       = mi and mi.type or -1
        vec[0].mat_index      = mi and mi.index or -1
        vec[0].reaction_class = ''
        vec[0].quantity       = 1
    end)
end

-- Abort seal: a filter nothing matches, with quantity restored to one
-- so DF's own search runs, fails, and cancels the job itself. Measured
-- on the rot watcher: a zeroed quantity left the job idling engaged
-- forever, because DF saw nothing missing and never searched.
local function seal_shut(job, kind)
    pcall(function()
        local vec = job.job_items.elements or job.job_items
        if #vec > 0 then
            vec[0].item_type      = -1
            vec[0].item_subtype   = -1
            -- The SAME class the raws reagent asks for, so the
            -- cancellation reads the same word the workshop does.
            -- It fails because the key has been withdrawn, not
            -- because the class is unknown to anything.
            vec[0].reaction_class = kind.class
            vec[0].mat_type       = -1
            vec[0].mat_index      = -1
            vec[0].quantity       = 1
        end
    end)
end

local function fill(job, kind, b)
    local it = find_remains(kind, b)
    if not it then
        -- INFO: it answers why the job the player queued cancelled.
        once('none:' .. job.id, 'INFO', ('job %d: no reachable %s remains; it will cancel itself.')
             :format(job.id, kind.name), 'JOB')
        seal_shut(job, kind)
        return
    end
    clear('none:' .. job.id, 'DETAIL', 'reachable remains found.', 'JOB')

    local ok_s, err_s = seal_to(job, it)
    if not ok_s then
        attach_fail[job.id] = true
        seal_shut(job, kind)
        log('ERROR', ('job %d seal FAILED: %s'):format(job.id, tostring(err_s)), 'JOB')
        return
    end

    local on_site = false
    pcall(function()
        on_site = it.pos.z == b.z
            and dfhack.buildings.containsTile(b, it.pos.x, it.pos.y)
    end)
    local role = on_site and df.job_role_type.Reagent
                          or df.job_role_type.Hauled

    local ok, err = pcall(function()
        it.flags.forbid = false
        dfhack.job.attachJobItem(job, it, role, 0, -1)
    end)
    if not ok then
        attach_fail[job.id] = true
        seal_shut(job, kind)
        log('ERROR', ('job %d attach FAILED: %s'):format(job.id, tostring(err)), 'JOB')
        return
    end

    filled[job.id] = it.id
    -- A linked item in transit does not count toward the quantity, so
    -- with it attached the demand drops to zero and DF has nothing
    -- left to seek. This is R25: leaving the demand up is exactly how
    -- a burn fetched a second item it never consumed.
    pcall(function()
        local vec = job.job_items.elements or job.job_items
        vec[0].quantity = 0
    end)
    log('DETAIL', ('job %d sealed to %s remains, item %d, %s.'):format(
        job.id, kind.name, it.id, on_site and 'on site' or 'to be hauled'), 'JOB')
end

-- ---------------------------------------------------------------------
-- THE POLL
-- ---------------------------------------------------------------------
-- ---- THE SLOW HALF: THE KEY INVARIANT ----
-- Every item, building and raws walk in this file lives here, at 100
-- frames, pause gated. A paused fort creates no corpses and builds
-- no furnaces, so nothing this computes can change while it waits.
local function poll_keys()
    if not dfhack.isMapLoaded() then return end
    if not _G.refinish_active then return end
    if dfhack.world.ReadPauseState() then return end
    local ok, err = pcall(tend_keys)
    if not ok then log('ERROR', 'KEY POLL ERROR: ' .. tostring(err), 'KEY') end
end

-- ---- THE FAST HALF: THE JOBS ----
local function poll()
    if not dfhack.isMapLoaded() then return end
    if not _G.refinish_active then return end
    if dfhack.world.ReadPauseState() then return end
    -- is_any_key needs key_subtype, which this hands over for the
    -- price of a few nil checks once it is resolved.
    if not ensure_resolved() then return end

    local ok, err = pcall(function()
        local seen = {}
        local link = df.global.world.jobs.list.next
        while link do
            local nxt = link.next
            local job = link.item
            local kind = job and kind_of_job(tostring(job.reaction_name))
            if kind then
                seen[job.id] = true
                local rg = attached(job)

                if rg and is_any_key(rg) then
                    -- DF's fetcher beat the seal to the key. Kill the
                    -- job so the key survives; the player re-queues.
                    log('WARNING', ('job %d took the KEY before the seal landed;'
                         .. ' cancelling it to save the key.'):format(job.id), 'JOB')
                    pcall(dfhack.job.removeJob, job)
                    filled[job.id] = nil
                elseif rg then
                    -- Already holding its corpse. Nothing to do.
                elseif filled[job.id] then
                    log('ERROR', ('job %d: DF STRIPPED the attached item. Report.')
                        :format(job.id), 'JOB')
                    filled[job.id] = nil
                elseif not attach_fail[job.id] then
                    -- The job's OWN workshop. find_remains tests
                    -- reachability from the building it is handed, so
                    -- taking the first furnace in the world list would
                    -- answer for the wrong one.
                    local b = dfhack.job.getHolder(job)
                    if b then fill(job, kind, b) end
                end
            end
            link = nxt
        end

        for id in pairs(filled) do
            if not seen[id] then filled[id] = nil end
        end
        for id in pairs(attach_fail) do
            if not seen[id] then attach_fail[id] = nil end
        end
    end)
    if not ok then log('ERROR', 'POLL ERROR: ' .. tostring(err), 'POLL') end
end

-- ---------------------------------------------------------------------
-- CONTRACT
-- ---------------------------------------------------------------------
-- Every cache is dropped here. start() runs again on every data cycle,
-- after the sweep has deleted the materials mat_index points at.
--
-- stop() deliberately removes nothing. The engine's prefix sweep owns
-- the materials and reactions, and the keys are handled by the session
-- purge on the next start rather than here, so a shutdown that races
-- the sweep cannot double free anything.
function start()
    said, mat_index, filled, attach_fail = {}, {}, {}, {}
    key_subtype, purged = nil, false
    repeatUtil.scheduleEvery(REPEAT_KEY, POLL_FRAMES, 'frames', poll)
    repeatUtil.scheduleEvery(KEY_KEY, KEY_FRAMES, 'frames', poll_keys)
    -- Once immediately, so the session purge and the first menu
    -- verdict do not wait 100 frames.
    poll_keys()
    log('DETAIL', 'active. Queue "cremate a citizen" or "cremate a pet"'
        .. ' at a wood furnace.', 'START')
end

function stop()
    repeatUtil.cancel(REPEAT_KEY)
    repeatUtil.cancel(KEY_KEY)
    mat_index, filled, attach_fail = {}, {}, {}
    key_subtype = nil
    log('DETAIL', 'stopped.', 'STOP')
end

if dfhack_flags and dfhack_flags.module then return end
start()