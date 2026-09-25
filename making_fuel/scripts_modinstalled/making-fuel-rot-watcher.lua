-- making-fuel-rot-watcher.lua  (v4)
-- =====================================================================
-- ROT TARGETING
-- CHAR_ROT is a normal furnace reaction the player queues natively.
-- Its raws reagent asks class ROT_LOCK, carried only by the rot key
-- material, so the menu reads available exactly when the key exists
-- and is reachable. This watcher does what DF cannot: it selects
-- items where item.flags.rotten is true (or vermin REMAINS) and
-- attaches them to each queued job, and it keeps the key itself out
-- of the fetcher's hands.
--
-- Measured so far: a hidden key fails only when unreachable, so the
-- key lives at a completed wood furnace. DF honors and re-tests the
-- live job filter on delivery, so the seal mirrors the chosen item.
-- A linked item in transit does not count toward quantity, so after
-- attaching, quantity goes to zero. Claiming
-- the key with in_job was tried and measured: the scanner does not
-- count claimed items (menu red), so the key stays unclaimed and
-- hidden (measured fine), and the seal is its protection.
--
-- Nothing is silent: every state prints once on entry and exit.
-- =====================================================================

--@ module = true

local repeatUtil = require('repeat-util')

-- ---- TWO SPEEDS, AND WHY ----
-- Measured 2026-09-13: this file cost 527 ms of every wall second,
-- 21 full item walks a second, because ensure_key() ran on the job
-- poll's cadence. The two halves do not need the same clock.
--
-- JOBS stay at one frame. The seal has to land before DF's own
-- fetcher reaches the key, and that race is the reason this cadence
-- was chosen in the first place; nothing measured justifies risking
-- it. What made one frame expensive was the key walk riding along,
-- not the job walk itself, which only ever touches the job list.
--
-- KEYS go to 100 frames. The key invariant is "a key exists here
-- exactly while rot is reachable from here", and a menu light that
-- settles a second or two late is invisible in play. The drain key
-- watcher already holds its invariant at exactly this cadence and
-- measured 1.1 ms/sec doing the same class of work.
local REPEAT_KEY  = 'making-fuel-rot-watcher'
local POLL_FRAMES = 1
local KEY_KEY     = 'making-fuel-rot-watcher-keys'
local KEY_FRAMES  = 100
-- The engine composes reaction codes as prefix .. 'RXN_' .. key
-- (refinish-module-react.lua:1234), and the ghost renames a job's
-- reaction to a _GHOST_ clone at pickup, so match by prefix, not by
-- equality. v1 through v4 matched a name no job ever carried.
-- Both rot reactions, matched by prefix because the ghost renames a
-- job's reaction to a per-job clone at pickup. One key serves both:
-- they ask the same class, so the menu opens and closes for the pair
-- together.
local REACTIONS = {
    'MAKING_FUEL_RXN_CHAR_ROT',
    'MAKING_FUEL_RXN_ASH_ROT',
    'MAKING_FUEL_RXN_RETORT_ROT',
}

local function is_rot_job(name)
    for _, r in ipairs(REACTIONS) do
        if name:sub(1, #r) == r then return true end
    end
    return false
end
local KEY_MAT     = 'MAKING_FUEL_ROT_KEY'
-- ---- WHY A TOOL AND NOT A BOULDER ----
-- The key used to be minted as df.item_type.BOULDER. A boulder is a
-- construction material, so the key showed up in the stone list every
-- time the player placed a building: a seam with the module's own
-- plumbing hanging out of it.
--
-- A TOOL with no tool_use and no_default_job is inert. Nothing builds
-- with it, nothing hauls it to a stockpile job, and it still carries
-- the ROTTEN class that lights the menu.
--
-- ITS OWN ITEMDEF, deliberately, not the drain key's. The drain key
-- watcher sweeps every DRAIN_KEY tool it does not recognise as one of
-- its own retorts and removes it. Sharing the itemdef would have that
-- watcher delete this one on its next poll.
local KEY_TOOL    = 'MAKING_FUEL_ROT_KEY'
local key_subtype = nil
-- The abort filter asks for ROTTEN, same as the raws reagent, so the
-- cancellation reads "Needs non-artifact ROTTEN item". Nothing
-- carries the class at that moment because the key is withdrawn
-- when no rot is reachable, which is exactly why the search fails
-- and DF cancels the job on its own.
local SEAL_CLASS  = 'ROTTEN'
-- MEASURED: in_job on the key reds the menu (two runs, one variable).
-- The scanner does not count claimed items. Stays false forever;
-- the seal and the fill are the key's protection.
local KEY_CLAIM   = false

local filled    = {}    -- job id -> item id attached
local clone_cache = {}  -- clone reaction name -> reaction object or false
local attach_failed = {} -- job id -> true, so a failure prints once
local key_index = nil
local warned    = {}    -- state -> already said

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
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'ROT_WATCHER'
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
-- SUBJECT is the correlation slot: KEY for the menu keys, JOB for a
-- single burn job, RESOLVE and SITE for what the watcher waits on,
-- POLL and START.
--
-- once() and clear() say a state once and its recovery once. Each call
-- states its TYPE and SUBJECT like any log line: the state is usually a
-- fault, and its recovery usually DETAIL.
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

-- say once per state, and say when the state clears
local function once(state, typ, msg, subject)
    if not warned[state] then log(typ, msg, subject) warned[state] = true end
end
local function clear(state, typ, msg, subject)
    if warned[state] then log(typ, msg, subject) warned[state] = nil end
end

-- ---------------------------------------------------------------------
-- the key
-- ---------------------------------------------------------------------
local find_rot   -- defined below, used by ensure_key

-- Every completed building that can host a rot job. Wood furnace for
-- CHAR_ROT and ASH_ROT, retort for RETORT_ROT.
--
-- This used to return the FIRST wood furnace in the world list and use
-- it for everything, which was two bugs in one. A job at furnace B
-- drew its rot from furnace A's reachability, and the single key sat
-- at A whether or not the player worked at B. The rot reagent carries
-- `nearby`, so a key across the fort does not light the menu.
local ROT_BUILDINGS = { 'WoodFurnace' }
local RETORT_CODE   = 'MAKING_FUEL_RETORT'

local function hosts_rot(b)
    local hit = false
    pcall(function()
        if b:getType() ~= df.building_type.Furnace then return end
        if b:getBuildStage() ~= b:getMaxBuildStage() then return end
        if b.type == df.furnace_type.Custom then
            local def = df.building_def.find(b.custom_type)
            hit = def and tostring(def.code) == RETORT_CODE or false
            return
        end
        local name = df.furnace_type[b.type]
        for _, n in ipairs(ROT_BUILDINGS) do
            if name == n then hit = true return end
        end
    end)
    return hit
end

local function rot_buildings()
    local out = {}
    pcall(function()
        for _, b in ipairs(df.global.world.buildings.all) do
            if hosts_rot(b) then table.insert(out, b) end
        end
    end)
    return out
end

-- Resolved fresh and never cached on a miss: itemdefs inject AFTER
-- this script starts, so a cached nil would poison the lookup for the
-- whole session.
-- Resolution is RM's job now. The itemdefs walk that used to live
-- here is gone: refinish-module-react already keeps a cached code to
-- subtype map that the tool injector invalidates on both ends of
-- every cycle, and refinish-resolve is the front door to it.
local resolve = reqscript('refinish-resolve')

-- ---- EPOCH CACHED RESOLVERS ----
-- The material index and the tool subtype are both stable for as
-- long as the injected data is, and both were being rebuilt EVERY
-- FRAME: a raws search plus an itemdefs walk that tostring'd every
-- tool definition it passed. They are resolved once per RAM epoch
-- instead.
--
-- The epoch is _G.refinish_ram_loaded, the same flag the ghost
-- watches. It flips on every data cycle, which is exactly when an
-- index can move, so a change here means drop everything and look
-- again.
--
-- MISSES ARE STILL NEVER CACHED. Injection lands after this script
-- starts, so a nil stored now would poison the whole session. Only
-- a hit is kept, which is what the original comment above demanded
-- and what the nil checks below preserve.
--
-- Returns true when both are known, so callers can simply bail.
-- ---- RESOLVED EVERY POLL, CACHED IN THE CORE ----
-- No local epoch and no local memory of the answer. The first
-- version of this held both against _G.refinish_ram_loaded, which
-- is a boolean: this poll is gated on _G.refinish_active, so it
-- never runs during a wash, never sees the flag go false, and
-- therefore read true before a data cycle and true after it and
-- kept a stale index. That is a wrong material, silently, and a
-- stale hit looks exactly like a good one.
--
-- These are two table reads against a cache the injector and the
-- engine invalidate directly, so asking every poll costs almost
-- nothing and cannot go stale. The file locals still exist because
-- the per item predicates read them inside a walk, where an upvalue
-- beats a function call; they are simply refreshed here rather than
-- remembered.
local function ensure_resolved()
    key_index = resolve.material_index('INORGANIC:' .. KEY_MAT)
    if not key_index then
        -- DETAIL: every startup waits here until the module injects.
        once('mat', 'DETAIL', KEY_MAT .. ' not injected yet; deferring.', 'RESOLVE')
        return false
    end
    clear('mat', 'DETAIL', KEY_MAT .. ' resolved.', 'RESOLVE')

    key_subtype = resolve.tool_subtype(KEY_TOOL)
    if not key_subtype then
        once('tooldef', 'DETAIL', KEY_TOOL .. ' itemdef not injected yet;'
             .. ' deferring.', 'RESOLVE')
        return false
    end
    clear('tooldef', 'DETAIL', KEY_TOOL .. ' itemdef resolved.', 'RESOLVE')

    return true
end

-- ---- NO decode HERE ----
-- matinfo.decode() allocates a fresh table on every call, and this
-- predicate runs once per item per walk. At 20k items and five
-- walks a frame that is 100k allocations a frame, which is most of
-- the 527 ms/sec this file measured.
--
-- The raw fields answer the identical question. decode reads them
-- and wraps them; comparing them directly is the same test with no
-- table built. The cremate watcher has always matched its keys this
-- way (is_key_of), so this is the sibling's proven form, not a new
-- idea.
--
-- ---- TYPE GATE FIRST, AND IT IS NOT OPTIONAL ----
-- mat_index and mat_type are fields on item_actualst subclasses.
-- They are NOT on every item: a corpse is item_corpsest and carries
-- race and caste instead, so reading it.mat_index on one does not
-- answer false, it THROWS. This walk visits every item in the fort,
-- so it meets a corpse in the first second of any real save.
--
-- The first version of this gate read the fields directly, on the
-- reasoning that decode() reads them anyway. decode reads them
-- THROUGH the item's own accessors, which every class implements;
-- reading the raw field only works on classes that have it. That
-- cost a session: 539 throws, no rot key minted, and no rot job
-- filled, because ensure_key aborts at the first site.
--
-- getType is virtual and every item class implements it, so it is
-- always safe to ask. Two integer compares after it are then
-- guaranteed to be reading fields that exist.
--
-- BOTH TYPES ARE LET THROUGH ON PURPOSE. TOOL is what a key is.
-- BOULDER is what a key USED to be, and the migration path in
-- ensure_key depends on finding those to scrap them, so narrowing
-- this to TOOL would strand every pre-tool key in the fort and
-- light its menu forever.
local function is_key(it)
    if key_index == nil then return false end
    local ty = it:getType()
    if ty ~= df.item_type.TOOL and ty ~= df.item_type.BOULDER then
        return false
    end
    if it.mat_index ~= key_index then return false end
    return it.mat_type == 0
end

-- hidden, unforbidden, never artifact, claimed: the fetcher skips a
-- claimed item, the menu scan (measured) does not care about hidden.
local function dress_key(it)
    it.flags.hidden   = true
    it.flags.forbid   = false
    it.flags.artifact = false
    it.flags.dump     = false
    it.flags.in_job   = KEY_CLAIM
end

-- Keys are placed PER BUILDING now, one at each site that can host a
-- rot job. The rot reagent carries `nearby`, so a single key at one
-- furnace leaves the menu red at every other, and the retort added by
-- RETORT_ROT is usually nowhere near the wood furnace.
--
-- Same honest-menu rule as before, applied per site: a key exists at a
-- building exactly while rot is reachable FROM THAT BUILDING.
local function keys_at(p)
    local found = {}
    pcall(function()
        for _, it in ipairs(df.global.world.items.all) do
            if is_key(it) and it.pos.x == p.x and it.pos.y == p.y
               and it.pos.z == p.z then
                table.insert(found, it)
            end
        end
    end)
    return found
end

local function mint_key(b, p, mi)
    local maker = nil
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(u) then maker = u break end
    end
    if not maker then
        once('citizen', 'WARNING', 'no citizen to credit the mint; deferring.', 'KEY')
        return nil
    end
    clear('citizen', 'DETAIL', 'citizen available.', 'KEY')

    local ok, made = pcall(dfhack.items.createItem,
        maker, df.item_type.TOOL, key_subtype, mi.type, mi.index)
    local it = ok and made or nil
    if type(it) == 'table' and it[1] ~= nil then it = it[1] end
    if not it then
        log('ERROR', 'rot key mint FAILED (' .. tostring(made) .. ').', 'KEY')
        return nil
    end
    dress_key(it)
    if dfhack.items.moveToGround(it, p) then
        log('DETAIL', ('rot key minted at building %d, %d,%d,%d.')
            :format(b.id, p.x, p.y, p.z), 'KEY')
    else
        log('WARNING', 'rot key minted but could not be moved. Report this line.', 'KEY')
    end
    return it
end

local function ensure_key()
    -- Resolution, deferral and the once/clear lines all moved into
    -- ensure_resolved so the fast job poll can share them. A false
    -- return means the data is not injected yet and has already
    -- said so.
    if not ensure_resolved() then return end

    -- mint_key still wants the matinfo, and this runs at 100 frames
    -- now, so one lookup here is free where one per frame was not.
    local mi = dfhack.matinfo.find('INORGANIC:' .. KEY_MAT)
    if not mi then return end

    local sites = rot_buildings()

    -- No early return when there are no sites. The site loop below is
    -- a no-op on an empty list and the sweep after it then withdraws
    -- every key, which is the correct answer: demolish the last rot
    -- capable building and the keys should go with it rather than lie
    -- around as clutter carrying a live reaction class. Returning here
    -- left them, which the harness caught.

    if #sites == 0 then
        once('furnace', 'DETAIL', 'no completed wood furnace or retort;'
             .. ' keys mint when one exists.', 'SITE')
    else
        clear('furnace', 'DETAIL', ('%d rot capable building(s) watched.')
              :format(#sites), 'SITE')
    end

    -- Every key that belongs somewhere, so the sweep below can tell a
    -- placed key from one a dwarf carried off.
    local placed = {}
    for _, b in ipairs(sites) do
        local p = xyz2pos(b.centerx, b.centery, b.z)
        local held = keys_at(p)

        if find_rot(b) then
            if #held == 0 then
                local it = mint_key(b, p, mi)
                if it then placed[it.id] = true end
            else
                -- MIGRATION. is_key matches on MATERIAL, so a key
                -- minted as a boulder by an older build still answers
                -- to it. That is deliberate, because it is how the old
                -- one gets found and removed at all, but it must not
                -- be kept: a boulder is what put the key in the
                -- building materials list. Wrong item type, scrap it
                -- and mint a tool in its place.
                local keep = nil
                for _, k in ipairs(held) do
                    local is_tool = false
                    pcall(function()
                        is_tool = k:getType() == df.item_type.TOOL
                    end)
                    -- Never two at one site either. One key is one
                    -- menu light, so the first tool wins and the rest
                    -- go whatever they are.
                    if is_tool and not keep then
                        keep = k
                    else
                        pcall(dfhack.items.remove, k)
                        if not is_tool then
                            log('DETAIL', ('building %d: replacing an old boulder'
                                 .. ' key with a tool.'):format(b.id), 'KEY')
                        end
                    end
                end
                if keep then
                    dress_key(keep)
                    placed[keep.id] = true
                else
                    local it = mint_key(b, p, mi)
                    if it then placed[it.id] = true end
                end
            end
        else
            for _, k in ipairs(held) do
                pcall(dfhack.items.remove, k)
                log('DETAIL', ('building %d: no reachable rot; key withdrawn,'
                     .. ' its burn menu reads red.'):format(b.id), 'KEY')
            end
        end
    end

    -- A key anywhere else should not exist: one left by a demolished
    -- furnace, or one a dwarf picked up. Either would light a menu at
    -- a building that cannot reach any rot.
    -- Collected first, removed after. Removing inside the walk mutates
    -- the vector under the iterator and silently skips the next entry,
    -- which the harness caught: two strays went in, one came out. DF
    -- defers the actual delete so this may never have bitten in play,
    -- but a sweep that depends on that is a sweep that stops working
    -- the day it changes.
    local doomed = {}
    pcall(function()
        for _, it in ipairs(df.global.world.items.all) do
            if is_key(it) and not placed[it.id] and not it.flags.in_job then
                doomed[#doomed + 1] = it
            end
        end
    end)
    for _, it in ipairs(doomed) do pcall(dfhack.items.remove, it) end
end

-- ---------------------------------------------------------------------
-- jobs
-- ---------------------------------------------------------------------
local function is_rot(it)
    local f = it.flags
    return not f.in_job and not f.artifact and not f.construction
       and not f.in_building and not f.garbage_collect
       and not is_key(it)
       and f.rotten   -- rotten only; remains have their own reactions
end

-- Reachability, not list order: the first rotten item in the world
-- list once sat across a canyon and the job flickered forever. Items
-- inside containers are skipped; hauling out of a container is a
-- separate DF flow this watcher does not manage.
find_rot = function(b)
    local home = xyz2pos(b.centerx, b.centery, b.z)
    for _, it in ipairs(df.global.world.items.all) do
        if is_rot(it) and not it.flags.in_inventory
           and dfhack.maps.canWalkBetween(it.pos, home) then
            return it
        end
    end
    return nil
end

-- What is attached as reagent: nil, the key, or something else.
-- Roles per the DFHack Lua API: df.job_role_type. An item we attach
-- to be brought to the furnace is Hauled; DF treats it as the
-- reagent on arrival, so both roles mean "this job has its item."
local function reagent_of(job)
    for _, ref in ipairs(job.items) do
        if ref.role == df.job_role_type.Hauled
           or ref.role == df.job_role_type.Reagent then
            return ref.item
        end
    end
    return nil
end

-- The job's own filter, rewritten. Measured: DF honors the live
-- filter and RE-TESTS it when the hauled item arrives, so a filter
-- matching nothing cancels the job on delivery. The seal therefore
-- MIRRORS the chosen item, its type and exact material, satisfiable
-- by that item on arrival, while the fetcher stays idle because the
-- linked item already meets the quantity, and the key can never
-- match a filter shaped like meat. Both job_items shapes handled.
local function seal_to(job, it)
    return pcall(function()
        local jil = job.job_items
        local vec = jil.elements or jil
        if #vec == 0 then error('job has no item filter') end
        local mi = dfhack.matinfo.decode(it)
        vec[0].item_type = it:getType()
        vec[0].item_subtype = it:getSubtype()
        vec[0].mat_type = mi and mi.type or -1
        vec[0].mat_index = mi and mi.index or -1
        vec[0].reaction_class = ''
        vec[0].quantity = 1
    end)
end

-- Abort seal: a filter nothing matches, WITH quantity restored to
-- one, so DF's own search runs, fails, and cancels the job itself
-- the way a furnace out of ore does. Measured: a zeroed quantity
-- left the job idling engaged forever after the last burn, because
-- DF saw nothing missing and never searched.
local function seal_shut(job)
    pcall(function()
        local jil = job.job_items
        local vec = jil.elements or jil
        if #vec > 0 then
            -- Clear the mirrored item type too, not just the material.
            -- The mirror seal wrote the attached item's type, so a job
            -- aborted after burning meat announced "Needs non-artifact
            -- ROTTEN meat" while the workshop panel said "item". Back
            -- to ANY, and the two agree.
            vec[0].item_type = -1
            vec[0].item_subtype = -1
            vec[0].reaction_class = SEAL_CLASS
            vec[0].mat_type = -1
            vec[0].mat_index = -1
            vec[0].quantity = 1
        end
    end)
end

-- Whole stacks in one burn, using the module's own machinery: the
-- ghost swaps each job onto a PRIVATE clone of the reaction, and a
-- per-job reaction means a per-job quantity. Measured today: the
-- reagent quantity is an exact requirement, so it is written to the
-- linked stack's exact size, every poll, whatever the stack is.
-- Pre-swap the base reaction (quantity 1) runs as before, so at
-- worst one unit burns before the clone exists.
local function sync_clone(job, it)
    local name = job.reaction_name
    if not name:find('GHOST', 1, true) then return end
    local rx = clone_cache[name]
    if rx == nil then
        rx = false
        for _, r in ipairs(df.global.world.raws.reactions.reactions) do
            if r.code == name then rx = r break end
        end
        clone_cache[name] = rx
    end
    if not rx then return end
    local sz = 1
    pcall(function() sz = it.stack_size or 1 end)
    pcall(function()
        if rx.reagents[0].quantity ~= sz then
            rx.reagents[0].quantity = sz
            log('DETAIL', ('job %d clone quantity set to %d: the whole stack burns '
                .. 'as one.'):format(job.id, sz), 'JOB')
        end
    end)
end

local function fill(job, b)
    local it = find_rot(b)
    if not it then
        -- INFO: it answers why the job the player queued cancelled.
        once('norot', 'INFO', ('job %d: no reachable rot; it will cancel itself.'):format(job.id), 'JOB')
        seal_shut(job)
        return
    end
    clear('norot', 'DETAIL', 'reachable rot found.', 'JOB')

    local ok_s, err_s = seal_to(job, it)
    if not ok_s then
        attach_failed[job.id] = true
        seal_shut(job)
        log('ERROR', ('job %d seal FAILED: %s'):format(job.id, tostring(err_s)), 'JOB')
        return
    end

    -- Already on the building's tiles: Reagent. Elsewhere: Hauled.
    local on_site = it.pos.z == b.z
        and dfhack.buildings.containsTile(b, it.pos.x, it.pos.y)
    local role = on_site and df.job_role_type.Reagent
                          or df.job_role_type.Hauled

    local ok, err = pcall(function()
        it.flags.forbid = false
        dfhack.job.attachJobItem(job, it, role, 0, -1)
    end)
    if ok then
        filled[job.id] = it.id
        -- Measured on job 321: a linked item still in transit does not
        -- count toward the quantity, and DF fetched a second matching
        -- item through the mirrored filter. With the item attached,
        -- the quantity drops to zero so there is nothing left to seek;
        -- the reaction consumes the linked item on completion.
        pcall(function()
            local jil = job.job_items
            local vec = jil.elements or jil
            vec[0].quantity = 0
        end)
        -- Same frame, not next poll. A refill can hand the job a
        -- different stack size than the one it started with, and a
        -- clone still demanding the old count for even one frame is
        -- a cancellation: measured on a 2 stack of rotten turtle
        -- replaced by a 1 stack.
        sync_clone(job, it)
        log('DETAIL', ('job %d sealed to and filled with item %d (%s), %s.'):format(
            job.id, it.id, df.item_type[it:getType()],
            on_site and 'on site' or 'to be hauled'), 'JOB')
    else
        attach_failed[job.id] = true
        seal_shut(job)
        log('ERROR', ('job %d attach FAILED: %s'):format(job.id, tostring(err)), 'JOB')
    end
end

-- ---- THE SLOW HALF: THE KEY INVARIANT ----
-- Everything that walks items, buildings or raws lives here, at 100
-- frames. Pause gated because a paused fort mints nothing, moves
-- nothing and demolishes nothing, so every answer this computes
-- while paused is the answer it already has.
local function poll_keys()
    if not dfhack.isMapLoaded() then return end
    if not _G.refinish_active then return end
    if dfhack.world.ReadPauseState() then return end
    local ok, err = pcall(ensure_key)
    if not ok then log('ERROR', 'KEY POLL ERROR: ' .. tostring(err), 'KEY') end
end

-- ---- THE FAST HALF: THE JOBS ----
-- Job list only. It calls find_rot through fill() for a job that has
-- nothing attached yet, which is a walk, but that is a transient
-- state: once the item is attached the walk stops. The steady state
-- of this poll is the length of the job list.
local function poll()
    if not dfhack.isMapLoaded() then return end
    if not _G.refinish_active then return end
    if dfhack.world.ReadPauseState() then return end
    -- No ensure_key() here any more. is_key needs key_index, which
    -- ensure_resolved hands over for the price of two nil checks
    -- once it has been resolved.
    if not ensure_resolved() then return end
    local ok, err = pcall(function()
        local seen = {}
        local link = df.global.world.jobs.list.next
        while link do
            local nxt = link.next
            local job = link.item
            if job and is_rot_job(job.reaction_name) then
                seen[job.id] = true
                local rg = reagent_of(job)
                if rg and is_key(rg) then
                    -- The fetcher beat the seal to the key. Kill the
                    -- job so the key survives; the player re-queues.
                    log('WARNING', ('job %d took the KEY before the seal landed; '
                        .. 'cancelling it to save the key.'):format(job.id), 'JOB')
                    pcall(dfhack.job.removeJob, job)
                    filled[job.id] = nil
                elseif rg then
                    sync_clone(job, rg)
                elseif filled[job.id] then
                    log('ERROR', ('job %d: DF STRIPPED the attached item. Report.'):format(job.id), 'JOB')
                    filled[job.id] = nil
                elseif not attach_failed[job.id] then
                    -- The job's OWN workshop, not the first wood
                    -- furnace in the world list. find_rot tests
                    -- reachability from the building it is given, so
                    -- the old call could hand a retort job a rotten
                    -- item that only the wood furnace could reach.
                    local b = dfhack.job.getHolder(job)
                    if b then fill(job, b) end
                end
            end
            link = nxt
        end
        for id in pairs(filled) do
            if not seen[id] then filled[id] = nil end
        end
        for id in pairs(attach_failed) do
            if not seen[id] then attach_failed[id] = nil end
        end
    end)
    if not ok then log('ERROR', 'POLL ERROR: ' .. tostring(err), 'POLL') end
end

function start()
    filled, warned, attach_failed, clone_cache = {}, {}, {}, {}
    key_index, key_subtype = nil, nil
    repeatUtil.scheduleEvery(REPEAT_KEY, POLL_FRAMES, 'frames', poll)
    repeatUtil.scheduleEvery(KEY_KEY, KEY_FRAMES, 'frames', poll_keys)
    -- The key invariant runs once immediately so the menu is honest
    -- from the first frame rather than up to 100 frames later.
    poll_keys()
    log('DETAIL', 'active. Queue "burn rotten refuse" at a wood furnace.', 'START')
end

function stop()
    repeatUtil.cancel(REPEAT_KEY)
    repeatUtil.cancel(KEY_KEY)
    filled, warned, attach_failed, clone_cache = {}, {}, {}, {}
    key_index, key_subtype = nil, nil
end

return _ENV