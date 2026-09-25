--@ module = true
-- making-fuel-access.lua
-- ==========================================
-- MAKING FUEL: UNIVERSAL FUEL ACCESS, v2
-- ==========================================
-- Every fuel the ecosystem tags burns in vanilla furnaces, tiered
-- by PHYSICS: what temperature a fire of that fuel can actually
-- reach, not what DF's hardcoded coal check happens to accept.
--
--   FUEL            anything that burns. 700 to 900 degree fires:
--                   dung, straw, raw peat. Enough for pottery,
--                   lime, ash. The KILN demands this and nothing
--                   more, which is dung fired pottery working the
--                   way it has for most of human history.
--
--   FUEL_SMELTING   FINISHED fuel only: charcoal and coke. Char is
--                   deliberately below this line: incomplete
--                   carbonisation retains volatiles and moisture,
--                   a cooler and smokier fire, and finishing it
--                   through CHAR_CHAR_BOULDER is what earns entry.
--                   Iron wants 1300 degrees sustained, and the
--                   reason charcoal EXISTS is that raw wood's
--                   moisture and volatiles cap what its fire can
--                   reach. SMELTER, FORGE and GLASS FURNACE demand
--                   this, glass on the charcoal and coal glasshouse
--                   model since raw wood is not direct fuel here.
--
-- ---- TWO AXES: HEAT AND FORM ----
-- The reaction class says how hot a fuel's fire can get. The ITEM
-- TYPE says whether the furnace can physically take it. Both are
-- real constraints and neither substitutes for the other.
--
-- The smith tier carries an item floor of BAR. With char demoted
-- the cinder exploit is already closed by class, so the floor is
-- doing the other job: a forge is hand fed solid fuel, and no
-- future material tagged FUEL_SMELTING should arrive as a liquid,
-- a powder, or somebody's furniture. Liquid fuels from the retort
-- line are the proving case: pitch and tar carry the heat to smith
-- but no vanilla furnace burns a liquid, and it is the item type
-- that refuses them, not the class.
--
-- The KILN sets no floor on purpose. It is a chamber loose
-- material is shovelled into, so boulders, tools and bars all fit.
--
-- Where a fuel has the heat but the wrong form, the answer is
-- PROCESSING, not a wider filter. Char is the worked example: soil
-- classed, bulk, kiln grade as it comes, and finished into charcoal
-- bars through CHAR_CHAR_BOULDER at the wood furnace, four bars per
-- boulder, no fuel required. Storage form in, finished form out,
-- for the price of the labour.
--
-- The WOOD FURNACE appears nowhere in this file, correctly. Its
-- reagents ARE the grade zero fuels, so it is tiered by
-- construction, and none of its jobs post a coal filter anyway:
-- vanilla charcoal making and MakeAsh are fuel free and the
-- module's reactions are fuel false. There is nothing to widen.
--
-- Vanilla wood materials stay UNTAGGED, deliberately. flags3
-- gating was tested and does not narrow a widened filter, so
-- tagging wood makes every wooden bed eligible fuel. Physics
-- agrees with the constraint: raw wood does not belong in a
-- smelter, and the wood furnace is wood's door into the fuel
-- economy.
--
-- ---- MEASURED FACTS THIS FILE STANDS ON ----
-- Fuel is a per job ITEM FILTER, attached at posting: BAR of
-- builtin COAL, quantity 1, vector BAR. Magma jobs post no filter
-- at all (two byte identical dumps except that element), so magma
-- can never regress. Rewriting the filter to a reaction class over
-- IN_PLAY makes DF fetch AND CONSUME tagged items: verified end to
-- end with a peat boulder completing a hardcoded melt.
--
-- vector_id is the field that is easy to miss: it selects WHICH
-- item vector DF searches. Left at BAR, boulders and tools are
-- invisible no matter how open the other fields are.
--
-- Menu availability is pressable(), a vmethod recomputed per
-- frame. Blanking objection strips the text and leaves the entry
-- orange; injected clones render orange too; a furnace flipped to
-- its magma twin off magma has NO menu. What pressable() reads is
-- whether a coal bar is available for work.
--
-- ---- THE FLAG MATRIX, MEASURED ----
-- Each line read off a live fort holding exactly ONE coal bar, so
-- nothing could mask anything:
--
--   hidden=true  artifact=false   WHITE. Invisible on the map and
--                                 still counted.
--   hidden=false artifact=true    RED. Measured twice, brand new
--                                 world, flags verified on the bar
--                                 before looking at the menu.
--   hidden=true  artifact=true    RED.
--
-- DF's fuel count SKIPS ARTIFACTS, full stop. hidden does not
-- exclude a bar from the count; it is a visibility flag, which is
-- also why it was never a haul barrier.
--
-- ---- THE MISATTRIBUTION, SO IT IS NEVER RELITIGATED ----
-- An earlier session concluded the opposite: that an artifact bar
-- counts. The observation behind that was a white kiln beside a red
-- smelter after flipping the live key to artifact by hand. But at
-- that moment hide_key still set HIDDEN ONLY, and the per building
-- conditional key was live: viewing the smelter DESTROYED the key,
-- viewing the kiln MINTED A FRESH ONE, and every fresh mint came
-- out hidden, not artifact. The hand flipped bar was gone within
-- one view change. The white kiln was a hidden key. The result was
-- the per building mechanism working, and it was read as the
-- artifact flag working. A full day of red menus followed from that
-- one wrong sentence.
--
-- artifact also has no upside left: it was tried as the haul guard
-- for a tagged key, and a bar that is never counted cannot be the
-- key at all. It is finished here.
--
-- dump, owned, in_job and forbid each go red on their own. They all
-- mean not available for work, which is the question pressable()
-- asks.
--
-- ---- THE EXPOSURE, CLOSED STRUCTURALLY ----
-- There is NO flag that keeps a selectable key: every candidate
-- either does not stop selection (hidden) or removes the bar from
-- the count (artifact, forbid, owned, dump, in_job). So no flag is
-- asked to. Builtin COAL is never tagged (machinery removed, see
-- the ruling below), so the key carries no class and matches no
-- widened filter; and widening happens at job POSTING via
-- onJobInitiated, so the vanilla BAR/COAL filter never exists while
-- a dwarf is choosing items. The one dependency this creates is
-- that vanilla charcoal and coke need module owned replacement
-- materials to count as fuel, which is the standing work item.
--
-- Do not retry: reagent quantity edits (spurious peat bar out of a
-- melt), flags3 material gating (grabbed dung), click time prompts
-- (ghost renames jobs to per job codes that embed the job id, and
-- items attach before any poll can ask), and flags.artifact on the
-- key in any combination.
--
-- ---- SHUTDOWN ----
-- Strict reverse order, before any save: destroy the key, pop
-- every class this session pushed onto builtin COAL. Filters die
-- with their jobs.
-- ==========================================

local repeatUtil = require('repeat-util')
-- Widening happens at job POSTING via onJobInitiated, which fires
-- before any hauler is dispatched (confirmed in the hijacker: items
-- are empty at initiate). The poll remains as the backstop sweep.
local eventful   = require('plugins.eventful')

local REPEAT_KEY = 'making_fuel_fuel_access'
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
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'FUEL_ACCESS'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

local tuning = nil
pcall(function() tuning = reqscript('making-fuel-tuning') end)

local function T()
    return (tuning and tuning.T) or {}
end

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
-- SUBJECT is the correlation slot: KEY for the menu key, MENU for the
-- fuel menus locking and unlocking, JOB for a single job's fuel slots,
-- TIER and ADOPT, POLL, START and STOP. The prints in status() and the
-- usage line answer commands typed at the console.
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

-- ==========================================
-- THE CONTRACT
-- ==========================================
-- Eight conditions, all simultaneously true, each with its named
-- mechanism. If a change here cannot say which condition it serves,
-- it does not belong in this file.
--
--   1/7  FUEL activates the kiln and the kiln consumes it.
--        Kiln is ABSENT from FUEL_TIERS, so it resolves to the
--        primary class with no item floor. Widened filters proven
--        end to end (peat completed a hardcoded job).
--   2/8  FUEL does not activate the smelter and the smelter never
--        consumes it. FUEL_TIERS: Smelter, GlassFurnace and
--        MetalsmithsForge demand FUEL_SMELTING with a BAR floor.
--   3/4  Menus tell the truth per building. HONEST_MENUS: the key
--        exists only while the viewed building's tier can be fed,
--        so red carries DF's own fuel objection.
--   5    Dwarves can NEVER interact with the key.
--        Lock A: builtin COAL is NEVER tagged. The machinery to tag
--                it has been REMOVED from this file, not switched
--                off. A classless key matches no widened filter.
--        Lock B: widening happens at onJobInitiated, before any
--                hauler is dispatched, so the vanilla BAR/COAL
--                filter never exists while a dwarf is choosing.
--                The poll is the backstop sweep.
--        Lock C: claim recovery. Anything that somehow holds the
--                key gets it abandoned and a fresh one minted.
--   6    The key is hidden: never rendered on the map. The stocks
--        listing remains, accepted at the time as the price.
--
-- TIERS_ENABLED and HONEST_MENUS exist as kill switches for
-- bisection only. The shipped state is both TRUE.
-- ==========================================
local TIERS_ENABLED = true
local HONEST_MENUS  = true

local reported    = {}     -- building name -> tier logged once
local key_id      = nil
local widened     = {}
local n_widened   = 0


-- ==========================================
-- THE COAL TAGS
-- ==========================================
-- Builtin COAL is one material struct covering coke and charcoal.
-- It receives BOTH classes: coal is the reference fuel of every
-- tier. Only classes this session added are popped at stop, so a
-- tag something else placed is never stolen.
-- ==========================================
-- material.reaction_class is a vector of string POINTERS. tostring()
-- on one yields an address, not the text, so every comparison
-- written that way silently fails and no class ever matches. The
-- text is on .value. Same trap the ghost's classifier fell into.
local function rc_value(s)
    local v = nil
    pcall(function() v = tostring(s.value) end)
    return v
end

-- ==========================================
-- BUILTIN COAL IS NEVER TAGGED. RULING, NOT A SWITCH.
-- ==========================================
-- The tagging machinery that used to live here is deliberately
-- gone. Pushing the fuel classes onto builtin COAL made the KEY,
-- which is a coal bar, legal fuel for every widened filter, and a
-- dwarf burned it. There is no flag that closes that while keeping
-- the bar countable: hidden does not bar selection, and artifact,
-- forbid, owned, dump and in_job all remove the bar from the fuel
-- count (artifact measured twice, one bar worlds, verified flags).
--
-- The consequence is that vanilla charcoal and coke do not satisfy
-- widened filters. That is the standing work item: the module owns
-- its own charcoal and coke materials carrying the classes, and
-- all coal production is hijacked into them. Condition 5 depends
-- on this ruling. Do not reintroduce a tag here for any reason.
-- ==========================================


-- ==========================================
-- DOES THE FORT ACTUALLY HAVE FUEL
-- ==========================================
-- The key must not lie. Minted unconditionally it makes every menu
-- white forever, so a fort with no fuel at all still shows white
-- entries that post and immediately cancel. Gating the key on real
-- fuel restores honest availability: white means the fort holds
-- something burnable, red means it does not.
--
-- One tier of resolution only, because the key is a single coal bar
-- and cannot say different things to different buildings. A fort
-- holding dung but no charcoal shows a white smelter that cancels
-- with "needs FUEL_SMELTING". Vanilla does the same when its coal
-- exists but cannot be reached, so this is parity, not a new seam.
--
-- Throttled hard. This walks the item vector, so it runs on a
-- counter rather than every poll, and exits on the first hit.
-- ==========================================
-- Keyed on the building being VIEWED, because a single hidden bar
-- can only say one thing at a time, while tiers differ per
-- building. pressable() is evaluated live, so setting the key to
-- answer whichever panel is open makes every building tell the
-- truth about its own tier: a kiln with dung shows white while the
-- smelter beside it shows red.
local fuel_check_countdown = 0
local fuel_present = false
local last_viewed  = -1

local function item_has_class(it, cls)
    local hit = false
    pcall(function()
        local mi = dfhack.matinfo.decode(it)
        if not mi or not mi.material then return end
        for _, s in ipairs(mi.material.reaction_class) do
            if rc_value(s) == cls then hit = true return end
        end
    end)
    return hit
end

local function scan_for_fuel(spec)
    local cls = (spec and spec.class) or T().FUEL_CLASS
    local itype = spec and spec.item_type
    if not cls then return false end
    local want = itype and df.item_type[itype] or nil
    local found = false
    local vec = nil
    pcall(function() vec = df.global.world.items.other.IN_PLAY end)
    if not vec then
        pcall(function() vec = df.global.world.items.all end)
    end
    if not vec then return true end   -- cannot tell: do not lock menus
    pcall(function()
        for _, it in ipairs(vec) do
            if it.id ~= key_id then
                local usable = false
                pcall(function()
                    local f = it.flags
                    -- artifact included: a genuine artifact bar
                    -- cannot be burned, so it must not unlock a
                    -- menu it can never feed. The key never gets
                    -- here anyway (skipped by id above) and is
                    -- never an artifact.
                    usable = not (f.hidden or f.forbid or f.dump
                        or f.garbage_collect or f.in_job
                        or f.removed or f.owned or f.artifact)
                end)
                if usable and want then
                    local t = nil
                    pcall(function() t = it:getType() end)
                    if t ~= want then usable = false end
                end
                if usable and item_has_class(it, cls) then
                    found = true
                    return
                end
            end
        end
    end)
    return found
end

-- ==========================================
-- THE KEY
-- ==========================================
-- Found by SIGNATURE, not by remembered id. key_id is only a cache:
-- if it resolves, use it; if not, adopt the first bar matching the
-- signature (BAR, builtin COAL, mat_index -1, which vanilla cannot
-- produce). A stockpile haul moves the key, a reload forgets the
-- id, and neither may ever orphan it, because an orphan on open
-- ground gets a store job, a store job used to trigger a remint,
-- and that loop turned one key into eight.
local function key_item()
    local it = nil
    if key_id then
        pcall(function() it = df.item.find(key_id) end)
        if it then return it end
        key_id = nil
    end
    pcall(function()
        for _, c in ipairs(df.global.world.items.other.IN_PLAY) do
            local hit = false
            pcall(function()
                hit = c:getType() == df.item_type.BAR
                    and c.mat_type == df.builtin_mats.COAL
                    and c:getMaterialIndex() == -1
            end)
            if hit then
                it = c
                key_id = c.id
                _G.refinish_fuel_key_id = c.id
                return
            end
        end
    end)
    return it
end

-- HIDDEN ONLY. The one configuration that counts, per the matrix
-- in the header. artifact is never set: DF's fuel count skips
-- artifacts, so an artifact key reds every furnace.
--
-- hidden keeps the bar off the map. It does not keep it out of
-- stocks and it is not a haul barrier; while builtin COAL carries
-- no reaction class neither of those matters, because the key
-- matches no filter and nothing can select it.
--
-- forbid stays false: a forbidden bar reads as unavailable and the
-- menu goes red, which defeats the purpose.
local function hide_key(it)
    pcall(function()
        it.flags.artifact = false
        it.flags.hidden   = true
        it.flags.forbid   = false
        it.flags.dump     = false
        it.flags.owned    = false
    end)
end

-- Availability is also a REACHABILITY question: an item nothing
-- can path to does not count. units.active[0] is whatever unit is
-- first in the list, including caged and offsite creatures. A
-- living, uncaged citizen is standing on fort connected ground by
-- definition, so the key mints under one.
local function fort_citizen()
    local found = nil
    pcall(function()
        for _, u in ipairs(df.global.world.units.active) do
            local ok_u = false
            pcall(function()
                ok_u = dfhack.units.isCitizen(u)
                    and dfhack.units.isAlive(u)
                    and not u.flags1.caged
                    and not u.flags1.chained
                    and u.pos.x >= 0
            end)
            if ok_u then found = u return end
        end
    end)
    return found
end

local function mint_key()
    if key_item() then return true end
    local ok, err = pcall(function()
        local u = fort_citizen()
        if not u then error('no reachable citizen to mint against') end
        local made = dfhack.items.createItem(
            u, df.item_type.BAR, -1, df.builtin_mats.COAL, -1)
        local it = made and made[1]
        if not it then error('createItem returned nothing') end
        dfhack.items.moveToGround(it, {
            x = u.pos.x, y = u.pos.y, z = u.pos.z })
        hide_key(it)
        key_id = it.id
        -- Published for the coal watcher: it spares exactly this
        -- item and exterminates every other builtin coal bar.
        _G.refinish_fuel_key_id = key_id
    end)
    if ok then
        log('DETAIL', string.format('menu key minted, item %d, hidden.', key_id), 'KEY')
    else
        log('ERROR', 'KEY MINT FAILED: ' .. tostring(err), 'KEY')
    end
    return ok
end

-- ==========================================
-- DESTROY BY SIGNATURE, NOT BY MEMORY
-- ==========================================
-- key_id is a script local and every recycle wipes it, so any
-- destroy that asks "the key I remember" finds nothing after a
-- restart and the orphan lives forever. That is why stop never
-- cleared the key across sessions and worlds kept being abandoned.
--
-- The key does not need remembering. It has a signature nothing
-- vanilla produces: a BAR of builtin COAL at mat_index -1. Vanilla
-- coal bars are coke (0) or charcoal (1), always. So destroy is a
-- sweep for the signature, and it kills orphans from ANY past
-- session. Run at start and at stop.
-- ==========================================
-- keep_one: spare the first signature bar found and adopt it as the
-- session's key. Used at start. stop and the honest lock pass
-- nothing and destroy every last one.
local function destroy_key(keep_one)
    local removed, failed = 0, 0
    pcall(function()
        local doomed = {}
        for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
            local hit = false
            pcall(function()
                hit = it:getType() == df.item_type.BAR
                    and it.mat_type == df.builtin_mats.COAL
                    and it:getMaterialIndex() == -1
            end)
            if hit then
                if keep_one then
                    keep_one = false
                    key_id = it.id
                    _G.refinish_fuel_key_id = it.id
                    hide_key(it)
                else
                    table.insert(doomed, it)
                end
            end
        end
        for _, it in ipairs(doomed) do
            -- Flags cleared first so nothing half destroyed carries
            -- a hazardous state into a save if the remove fails.
            pcall(function()
                it.flags.artifact = false
                it.flags.forbid   = false
            end)
            local ok = pcall(function() dfhack.items.remove(it) end)
            if ok then removed = removed + 1
            else
                failed = failed + 1
                pcall(function()
                    it.flags.garbage_collect = true
                    it.flags.hidden = true
                end)
            end
        end
    end)
    if removed + failed > 0 then
        log(failed > 0 and 'WARNING' or 'DETAIL', string.format('key sweep: %d destroyed%s.', removed,
            failed > 0 and (', ' .. failed .. ' FAILED, flagged')
            or ''), 'KEY')
    end
    key_id = nil
    _G.refinish_fuel_key_id = nil
end


-- ==========================================
-- PER BUILDING SPECS
-- ==========================================
-- What this job's building demands: a class, an item type floor, or
-- both, from FUEL_TIERS in the tuning file. Unlisted buildings get
-- the primary class with no floor, which is the kiln's tier by
-- omission: dung piles and peat boulders must both fit, so its
-- type stays open on purpose.
-- ==========================================
-- One name for any building, vanilla or custom, any module. The
-- name exists ONLY so the tier map can offer overrides; a building
-- this returns nil or an unlisted name for takes the primary tier,
-- so nothing anywhere depends on being named.
--
-- b.type is a small integer and both vanilla enums will happily
-- decode it, so a glass furnace reports furnace "GlassFurnace" and
-- workshop "Masons" at the same time. The building's CLASS picks
-- the enum, or a mason's workshop entry could silently capture a
-- furnace.
--
-- Vanilla names are mixed case as DF returns them: Smelter, Kiln,
-- WoodFurnace, GlassFurnace, MetalsmithsForge. The all caps tokens
-- in df-structures are not what comes back, and matching against
-- those missed every building once already.
--
-- CUSTOM buildings all decode to the literal name "Custom" on both
-- enums, one bucket for every custom building of every module, so
-- they resolve by their RAW CODE instead, whatever module they
-- come from. That makes every custom building overridable in
-- FUEL_TIERS by its code, with none required to be.
local function building_name(b)
    local name = nil
    pcall(function()
        local cls = b:getType()
        if cls == df.building_type.Furnace then
            if b.type == df.furnace_type.Custom then
                name = df.global.world.raws.buildings
                    .all[b.custom_type].code
            else
                name = tostring(df.furnace_type[b.type])
            end
        elseif cls == df.building_type.Workshop then
            if b.type == df.workshop_type.Custom then
                name = df.global.world.raws.buildings
                    .all[b.custom_type].code
            else
                name = tostring(df.workshop_type[b.type])
            end
        end
    end)
    return name
end

-- ==========================================
-- THE TANK OVERRIDE
-- ==========================================
-- A furnace with a burner fitted and charge in its tank pays its own
-- fuel, so its jobs get no fuel slot at all: widen_job ERASES the
-- filter rather than widening it, and expand_fuel appends nothing.
--
-- Reached through _G.making_fuel_tank_api, which making-fuel-tank-fuel
-- publishes in its start() and clears in its stop(). NOT reqscript:
-- that costs about 2 ms a call (engine notes) and this runs for every
-- job on every 5 frame poll. Not a handle cached here either, because a
-- reload builds a new environment. A cleared table is also what stops
-- the waiver the moment the tank script stops, which a reqscript
-- handle never did: it returned the environment whether or not anything
-- had started it.
--
-- class is still filled in beside the flag. The menu path calls
-- spec_for_building too, and a spec carrying no class would paint a
-- tanked furnace red. That leaves one refinement outstanding: a full
-- tank in a fort with no solid fuel anywhere still reads red, because
-- the key is minted off the fort's stock and knows nothing of tanks.
local function tanked(b)
    if not b then return false end
    local api = _G.making_fuel_tank_api
    if not (api and api.has_charge) then return false end
    local charged = false
    pcall(function() charged = api.has_charge(b.id) end)
    return charged
end

local function spec_for_building(b)
    if tanked(b) then
        return { class = T().FUEL_CLASS, tank = true }
    end
    local spec = { class = T().FUEL_CLASS }
    local map = T().FUEL_TIERS
    -- With tiers off every building gets the primary class and no
    -- item floor, which is what the working state did.
    if not TIERS_ENABLED then return spec end
    if not map or not next(map) or not b then return spec end
    local hit = nil
    pcall(function()
        local n = building_name(b)
        if n and map[n] then hit = map[n] end
    end)
    if hit then
        if hit.class then spec.class = hit.class end
        spec.item_type = hit.item_type
    end
    return spec
end

local function spec_for(j)
    local spec = { class = T().FUEL_CLASS }
    local map = T().FUEL_TIERS

    -- The holder is resolved FIRST and the tank answers before the
    -- tier gates, because a burner works whether or not tiers are
    -- switched on. The old order returned at the TIERS_ENABLED line
    -- and never reached the building at all, so a tanked furnace in a
    -- tiers-off fort would have gone on collecting fuel.
    local holder = nil
    pcall(function()
        for _, ref in ipairs(j.general_refs) do
            if ref._type == df.general_ref_building_holderst then
                holder = df.building.find(ref.building_id)
            end
        end
    end)
    if tanked(holder) then
        return { class = T().FUEL_CLASS, tank = true }
    end

    if not TIERS_ENABLED then return spec end
    if not map or not next(map) then return spec end
    pcall(function()
        local b = holder
        if not b then return end
        -- One resolver, not two. This used to carry its own copy of
        -- the lookup, so fixing the enum in one place left the other
        -- wrong and the job path kept resolving to the primary tier.
        spec = spec_for_building(b)

        -- One line per building type per session. A smelter that
        -- silently resolves to the primary class is how dung ends
        -- up in a forge, so the resolution says itself out loud
        -- once rather than never.
        local bname = building_name(b) or '?'
        if not reported[bname] then
            reported[bname] = true
            log('DETAIL', string.format('tier for %s: class %s, item %s',
                bname, tostring(spec.class),
                tostring(spec.item_type or 'any')), 'TIER')
        end
    end)
    return spec
end

-- Recognises the untouched vanilla filter AND a filter this poll
-- already widened for this building's tier, so a repeat job's
-- rebuilt filter is re processed rather than mistaken for done.
local function is_fuel_filter(e, spec)
    local hit = false
    pcall(function()
        if e.item_type == df.item_type.BAR
           and e.mat_type == df.builtin_mats.COAL then
            hit = true
        elseif spec.class
           and tostring(e.reaction_class) == spec.class then
            hit = true
        end
    end)
    return hit
end

local function widen(e, spec)
    local vec = T().FUEL_VECTOR or 'IN_PLAY'
    return pcall(function()
        -- Class and item floor together where the tier sets both.
        -- The smith tier is BAR plus FUEL_SMELTING: the class does
        -- the physics, the floor closes the cinder exploit.
        e.item_type      = spec.item_type
            and df.item_type[spec.item_type] or -1
        e.item_subtype   = -1
        e.mat_type       = -1
        e.mat_index      = -1
        e.reaction_class = spec.class or ''
        e.vector_id      = df.job_item_vector_id[vec]
    end)
end

-- One job, both callers. Returns true if it widened anything.
-- ==========================================
-- THE TANK CYCLE
-- ==========================================
-- A tanked job RESERVES its fuel at posting and PAYS at the end of the
-- cycle that actually burned it. Paying at posting was measured wrong:
-- job 7192's debit landed the instant it posted, so a job cancelled
-- after posting had emptied the tank for nothing.
--
-- A repeat job made posting the wrong moment twice over. It keeps its
-- id, never re-fires onJobInitiated, and job_items is never re-derived
-- (jobs 826 and 18, under THE RE-POST below). So the slot erased on
-- cycle one stayed erased, widened stayed true, and every later cycle
-- ran free, including on an empty tank.
--
-- So the cycle is tracked the way surcharge_step tracks it: held
-- something, holds nothing now, is DF's own boundary. The boundary
-- gets its verdict from the ghost's burn test, and the NEXT cycle
-- decides from the tank as it stands: reserve again and keep the slot
-- erased, or put the job's own fuel filter back so it burns solid fuel.
--
-- tank_st[job id] = {
--   bld      building id
--   cycle    counter, so every cycle's reservation has its own key
--   key      this cycle's reservation key, nil when it burns solid fuel
--   held     this cycle has attached something
--   seen     burn witness for this cycle: [item id] = { s = stack, d = dim }
--   pending  a finished cycle still waiting on its verdict:
--            { key, seen, wait }
-- }
-- kept[job id] is a clone of the job's own fuel filter, taken before
-- the first erase, so a restore puts back exactly what the job carried.
--
-- SAVED AS IT STANDS. A job the tank owns keeps its erased slot in the
-- save, and persist_jobs records it with a field for field copy of its
-- slot, so adopt_tank_jobs can take it back on the next start and a
-- restore after a reload is exact. See THE TANK AT STOP in stop().
local tank_st, kept = {}, {}

local function holder_id(j)
    local bid = nil
    pcall(function()
        for _, ref in ipairs(j.general_refs) do
            if ref._type == df.general_ref_building_holderst then
                bid = ref.building_id
            end
        end
    end)
    return bid
end

-- Same table tanked() reads, for the same reasons: no reqscript on a
-- per poll path, and gone the moment the tank script stops.
local function tank_fuel()
    local api = _G.making_fuel_tank_api
    if api and api.reserve_job then return api end
    return nil
end

-- Forward declared: the body lives with the surcharge code below and is
-- ASSIGNED there, so keep_fuel and drain_job above it reach it.
--
-- It matches every shape a fuel slot can be in: DF's raw BAR of builtin
-- COAL, and a slot widened to the primary, smith or bulk class. The tank
-- code used is_fuel_filter with the primary class alone, which cannot
-- see a slot widened to FUEL_SMELTING. At a smith tier furnace a
-- restored slot is widened to exactly that, so after a refill the next
-- cycle reserved the tank while drain_job left the slot in place, and
-- that cycle would have paid twice. Found by reading, not yet seen in
-- play: tonight's tests were all at a kiln, which is primary tier.
local is_any_fuel_filter

local function has_fuel_slot(j)
    local n = 0
    pcall(function()
        for _, e in ipairs(j.job_items.elements) do
            if is_any_fuel_filter(e) then n = n + 1 end
        end
    end)
    return n > 0
end

-- A clone, not a reference: the original is deleted by the erase.
local function keep_fuel(j)
    if kept[j.id] then return end
    pcall(function()
        for _, e in ipairs(j.job_items.elements) do
            if is_any_fuel_filter(e) then
                local k = e._type:new()
                k:assign(e)
                kept[j.id] = k
                return
            end
        end
    end)
end

-- ---- THE TANK'S JOB RECORDS ----
-- One site data key, owned here, because this file owns the job side of
-- the tank; making-fuel-tank-fuel owns the charge under its own key.
-- [job id as a string] = { bld = building id, slot = { fields } }.
-- String keys, because job ids are sparse and a sparse integer table is
-- not a safe shape for the save's json.
local JOBS_KEY = 'MAKING_FUEL_TANK_JOBS'

-- Every top level field of a job_item, read off a live dump
-- (df_data_reference, vanilla_collect_sand_job_path_map.txt). Bitfields
-- travel as their .whole integer and contains, a vector, as a list.
-- reaction_id is deliberately NOT here: module reaction indices can move
-- between sessions, so a rebuilt slot takes it from a sibling filter in
-- the same job instead.
local SLOT_INTS = { 'item_type', 'item_subtype', 'mat_type', 'mat_index',
    'quantity', 'vector_id', 'flags4', 'flags5', 'metal_ore',
    'min_dimension', 'reagent_index', 'has_tool_use', 'dye_color' }
local SLOT_STRS = { 'reaction_class', 'has_material_reaction_product' }
local SLOT_BITS = { 'flags1', 'flags2', 'flags3', 'job_details_flags' }

local function slot_to_table(e)
    local t = { ints = {}, strs = {}, bits = {}, contains = {} }
    for _, f in ipairs(SLOT_INTS) do
        pcall(function() t.ints[f] = tonumber(e[f]) end)
    end
    for _, f in ipairs(SLOT_STRS) do
        pcall(function() t.strs[f] = tostring(e[f]) end)
    end
    for _, f in ipairs(SLOT_BITS) do
        pcall(function() t.bits[f] = tonumber(e[f].whole) end)
    end
    pcall(function()
        for _, v in ipairs(e.contains) do t.contains[#t.contains + 1] = v end
    end)
    return t
end

-- j is the job the slot is going back into, for its reaction_id.
local function table_to_slot(t, j)
    if type(t) ~= 'table' then return nil end
    local e = nil
    pcall(function() e = df.job_item:new() end)
    if not e then return nil end
    for f, v in pairs(t.ints or {}) do pcall(function() e[f] = v end) end
    for f, v in pairs(t.strs or {}) do pcall(function() e[f] = v end) end
    for f, v in pairs(t.bits or {}) do pcall(function() e[f].whole = v end) end
    pcall(function()
        e.contains:resize(0)
        for _, v in ipairs(t.contains or {}) do e.contains:insert('#', v) end
    end)
    pcall(function()
        local sib = j.job_items.elements[0]
        if sib then e.reaction_id = sib.reaction_id end
    end)
    return e
end

-- Write through, the documented site data pattern: the table is held in
-- memory and DF writes it with the save, so every save carries the
-- current records whatever protocol took it. Called whenever a job
-- joins or leaves tank_st and whenever a pending verdict opens or
-- closes. NEVER at stop: see THE TANK AT STOP.
local function persist_jobs()
    local out = {}
    for id, st in pairs(tank_st) do
        local k = kept[id]
        if k then
            local rec = { bld = st.bld, cycle = st.cycle,
                          slot = slot_to_table(k) }
            -- A finished cycle still waiting on its verdict rides the
            -- record, witness and all, so a save that lands inside the
            -- retry window is judged on the other side instead of lost.
            -- The burn test keys on item identity, and a consumed item
            -- is simply absent from the reloaded save.
            if st.pending then
                local seen = {}
                for iid, v in pairs(st.pending.seen or {}) do
                    seen[tostring(iid)] = { s = v.s, d = v.d }
                end
                rec.pending = { key = st.pending.key, seen = seen }
            end
            out[tostring(id)] = rec
        end
    end
    pcall(function() dfhack.persistent.saveSiteData(JOBS_KEY, out) end)
end

-- Erases every fuel filter on a tanked job instead of widening it.
--
-- WALKED BACKWARDS, because erasing shifts everything after the index
-- down by one and a forward walk would skip the next element.
--
-- LEGAL UNDER THE ERASE RULE. ghost.lua:1079 allows removal from the
-- END only, since nothing before the last entry may shift or every
-- job_item_idx and reagent_index needs a fixup. expand_fuel returns
-- early on a tanked job, so no surcharge clones exist and DF's own
-- fuel filter is then the last of the originals: job 21 put the clay
-- at filter 1 and the fuel filters at 2 to 5.
--
-- SAFE AT THIS MOMENT, and checked rather than assumed.
-- onJobInitiated fires before a hauler is dispatched, so j.items is
-- empty and no job_item_idx points at anything. If that is ever
-- untrue the erase is refused and the job keeps its slots.
local function drain_job(j)
    local held = 0
    pcall(function() held = #j.items end)
    if held > 0 then return 0 end

    local removed = 0
    pcall(function()
        local els = j.job_items.elements
        for i = #els - 1, 0, -1 do
            if is_any_fuel_filter(els[i]) then
                els[i]:delete()
                els:erase(i)
                removed = removed + 1
            end
        end
    end)
    return removed
end

-- ==========================================
-- COAL REAGENTS ARE ALWAYS OUR COALS
-- ==========================================
-- THE INVARIANT: while this module is installed, nothing may require
-- builtin coal. The FUEL SLOT is handled below, by the tiers or the
-- tank. A REAGENT typed as builtin coal (vanilla PIG_IRON_MAKING and
-- STEEL_MAKING, or any mod's) is swapped here, before either, for the
-- module's own coals, the same way at every building, tanked or not.
-- Told apart by the owner, register L21: a reagent's filter names its
-- reagent, the fuel slot names none. Reaction jobs only, since only a
-- reaction has reagents.
--
-- WHY FIRST. The tank branch of widen_job never widens: it erases the
-- fuel slot and returns. Before the owner test that erase took a coal
-- reagent as if it were fuel, and pig iron was made with no carbon.
-- After it, the reagent was left as raw builtin coal, which the coal
-- watcher makes sure never exists, so the job would be cancelled.
-- Swapping reagents before the tier or the tank sees the job closes
-- both.
--
-- PER VARIETY, matching what the coal watcher turns each builtin coal
-- into: a reagent naming coke (mat_index 0) takes the COKE class, coke
-- and coke briquettes; charcoal (1) takes CHARCOAL; naming no variety
-- (-1, which is what vanilla writes) takes the smith fuel class, which
-- only the module's three coals and their briquettes carry. The item
-- type the reagent asked for is kept, whatever it is: only the material
-- is swapped, the same swap the coal watcher makes on the item itself,
-- so a mod asking for coal powder is fed our coal powder. The
-- building's tier class is never used for a reagent: outside the smith
-- tier it is FUEL with no item floor, and a coal reagent there would
-- take dung.
local COAL_REAGENT_CLASS = { [0] = 'COKE', [1] = 'CHARCOAL' }

local function widen_coal_reagents(j)
    local hits = 0
    -- Only a reaction has reagents. A hardcoded job (smelting ore,
    -- smithing, raw glass) has an empty reaction_name and is left to the
    -- tiers and the tank exactly as before: how DF numbers the owners on
    -- its filters has not been measured, so nothing here relies on it.
    local rxn = ''
    pcall(function() rxn = j.reaction_name end)
    if rxn == '' then return 0 end
    pcall(function()
        for _, e in ipairs(j.job_items.elements) do
            if e.reagent_index >= 0
               and e.mat_type == df.builtin_mats.COAL then
                local cls = COAL_REAGENT_CLASS[e.mat_index]
                    or T().FUEL_SMITH_CLASS
                -- Its own item type back again, by name. A filter that
                -- named none keeps that too, and widen writes -1: any
                -- item of our coal.
                local itype = nil
                pcall(function() itype = df.item_type[e.item_type] end)
                if widen(e, { class = cls, item_type = itype }) then
                    hits = hits + 1
                end
            end
        end
    end)
    return hits
end

local function widen_job(j)
    if not j or widened[j.id] then return false end
    -- Coal reagents first, at every building, tanked or not. See COAL
    -- REAGENTS ARE ALWAYS OUR COALS, above.
    local coal_hits = widen_coal_reagents(j)
    local spec = spec_for(j)

    -- The tank RESERVES here and pays at the end of the cycle, in
    -- tank_step. A failed reservation means a job posted alongside this
    -- one took the last whole job's worth, so this job is left exactly
    -- as posted: has_charge now reads the tank as short, and the next
    -- poll widens it on the ordinary tier.
    if spec.tank then
        -- Two kinds of job give the tank nothing to take over, and both
        -- used to spin. MEASURED: job 6769 at kiln 6, charged, reserved
        -- four units, found nothing to erase, released them, and did it
        -- again on every poll, about 150 times in eight seconds, until
        -- the kiln was deconstructed. This branch returned without
        -- marking the job, so the next poll asked the same question.
        -- Both are settled here, before anything is reserved.
        --
        -- NO FUEL SLOT: the job burns nothing, so there is nothing to
        -- waive, ever. A deconstruction, or a fill topping up a tank that
        -- already holds a job's worth. Marked handled, never revisited.
        if not has_fuel_slot(j) then
            widened[j.id] = true
            return false
        end
        -- HOLDING ITEMS: the cycle is already under way on solid fuel,
        -- and drain_job refuses to erase from a job that holds anything.
        -- Skipped quietly, with no reservation, and taken over on a
        -- later poll once it holds nothing: the same boundary tank_step
        -- works on.
        local held = 0
        pcall(function() held = #j.items end)
        if held > 0 then return false end

        local bid = holder_id(j)
        local tf  = tank_fuel()
        local key = j.id .. ':1'
        if not (bid and tf and tf.reserve_job(bid, key)) then
            return false
        end
        keep_fuel(j)
        local removed = drain_job(j)
        if removed == 0 then
            -- Both known causes are ruled out above, so this should not
            -- happen. If it does, nothing was waived and nothing is owed,
            -- and the job is marked handled anyway so it cannot spin.
            tf.release_job(key, 'no fuel slot to erase')
            widened[j.id] = true
            return false
        end
        tank_st[j.id] = { bld = bid, cycle = 1, key = key,
                          held = false, seen = {} }
        persist_jobs()
        widened[j.id] = true
        n_widened = n_widened + 1
        pcall(function() j.recheck_cntdn = 0 end)
        log('DETAIL', string.format('job %d: %d fuel slot(s) erased, tank reserved.',
            j.id, removed), 'JOB')
        return true
    end

    local hits = 0
    pcall(function()
        for _, e in ipairs(j.job_items.elements) do
            if is_fuel_filter(e, spec) and widen(e, spec) then
                hits = hits + 1
            end
        end
    end)
    if hits > 0 or coal_hits > 0 then
        widened[j.id] = true
        n_widened = n_widened + 1
        pcall(function() j.recheck_cntdn = 0 end)
        return true
    end
    return false
end

-- ==========================================
-- THE BULK SURCHARGE
-- ==========================================
-- Four bulk fuels buy what one finished fuel buys.
--
-- MEASURED END TO END, job 21, MAKE_CLAY_JUG at a kiln: three clones
-- of the fuel filter appended at posting, filters 2 to 5, every extra
-- slot filled one at a time, the jug made, and the payment check
-- returned 5 of 5 attached items DESTROYED. Four orange kindling and
-- the clay, all consumed. The surcharge is really paid.
--
-- ---- WHY SLOTS AND NOT quantity ----
-- The fuel filter's quantity reads 1 and DF pays no attention to any
-- other value: fuel is one item per filter, hardcoded. Filters are
-- the only lever there is.
--
-- ---- WHY THE DECISION IS MADE AT POSTING ----
-- Measured twice, jobs 85 and 86: fuel covers its slot on the exact
-- tick coverage completes. It is hauled LAST, always, because the
-- reagents are what the dwarf is already fetching and fuel is the
-- afterthought. DF closes collection once the base filters are
-- covered, so a slot appended at the moment fuel attaches is appended
-- to a job that has stopped listening. There is no way to read the
-- dwarf's choice early enough to react to it, so the FORT'S STOCK
-- decides instead of the dwarf.
--
-- ---- WHY A SEPARATE CLASS ----
-- A filter demands exactly ONE reaction_class, and charcoal carries
-- FUEL as well as FUEL_SMELTING. Four FUEL slots would happily eat
-- four charcoal bars, which is sixteen times the intended cost.
-- FUEL_BULK names the low grades alone.
--
-- FUEL stays the union, and that is why the menu key needs no change:
-- scan_for_fuel still asks for FUEL, white still means the fort holds
-- something burnable, of either grade.
--
-- ---- BULK FIRST, FINISHED FUEL AS THE FALLBACK ----
-- Deliberate, and the opposite way round would be wrong. A kiln burns
-- dung, peat, straw and kindling while any exist and only reaches for
-- charcoal when they are gone, which is the economy the module is
-- built to reward. It is also what keeps a fort holding three dung and
-- no charcoal from posting a job it can never fill.
--
-- ---- THE RE-POST, WHICH IS THE PART THAT BITES ----
-- job_items is materialised once at job creation and NEVER re-derived,
-- so a repeat job grown to four slots is BORN demanding four every
-- later cycle. The ghost measured this on job 826: when the pile ran
-- dry the job asked, found nothing, and DF cancelled it inside one
-- second without ever entering the working phase. Seen again here on
-- job 18, which re-posted under the same id with all five filters
-- intact.
--
-- So the extras come off between cycles and the next cycle decides
-- again from current stock. Delete the object, erase the slot, and
-- only ever a fuel slot with no owner that is not the job's first: see
-- COLLAPSE, BETWEEN CYCLES. Between cycles no item holds a
-- job_item_idx, so erasing mid list shifts nothing that matters.
--
-- ---- THE TAIL IS SHARED WITH THE GHOST ----
-- The copies are appended at the END, and so are the ghost's jug slots
-- (a filter, a reagent and a product each, append_vessel_triple) on a
-- reaction that makes liquids. The ghost takes its jugs back off the
-- END by count, so if both ever land on one job it can take our copies
-- and leave its own jug filters naming reagents it has deleted, which
-- is the R22 crash. Fuel stays off every ghosted reaction that makes
-- liquids (the retort reactions and the distils) until collapse_vessels
-- removes its slots by owner. Register R31.
--
-- BETWEEN CYCLES means job.items is empty AND the cycle actually held
-- something. An empty item list also occurs before the first haul, and
-- collapsing there would strip the slots off a job that has not run.
--
-- ---- LOSING FUEL MID COLLECTION IS A CANCEL, AND THAT IS RIGHT ----
-- Measured: a job that expanded to four with four kindling available,
-- then had one forbidden while it was still fetching clay, went on
-- collecting and cancelled with an announcement. That is exactly what
-- vanilla does when the coal bar it counted on is forbidden after
-- posting, so it is parity and not a defect.
--
-- It costs nothing either: a cancel releases the items, which IS the
-- cycle boundary, so the extras come off and the next cycle decides
-- again against what the fort now holds. Verified in play on job 26.
--
-- Shrinking mid collection instead is not available and should not be
-- reached for. Erasing a slot while items are attached leaves a live
-- job_item_idx pointing past the end of the vector. This file used to
-- say that crashes at completion, reading R22 into it. MEASURED since,
-- job 10111: it did not. The job completed and burned only what it
-- held, 2 dried dung of the 4 owed. R22's crash was a different
-- mismatch, a filter naming a reagent the reaction does not have
-- (register L7, L22). The rule stands either way: the stranded item is
-- outside the job's shape, and the cycle underpays.
--
-- ---- THE SWITCH ----
-- Off returns the vanilla rate of one fuel item per job for every
-- building, which is the behaviour before this section existed.
-- ==========================================
local SURCHARGE_ON = true

-- ---- THE STALE DECISION ----
-- A decision is made once and then defended by st, so a job that
-- expands and never claims anything would keep the shape it was
-- born with forever: no items means no cycle boundary, and the
-- boundary is what re-decides. That is the job 826 failure by a
-- different door, and it is reachable in ordinary play, because a
-- job can sit waiting for an idle hauler while another kiln burns
-- the bulk out from under it.
--
-- So an unclaimed decision expires. 200 polls at 5 frames is 1000
-- frames, long enough that a job simply waiting its turn is not
-- churned every few seconds, short enough that stock changes are
-- tracked. Safe to collapse there BECAUSE the item list is empty:
-- job.items holds a ref the moment an item is CLAIMED, before it
-- arrives, so empty means nothing claimed and nothing in flight,
-- and no job_item_idx can be pointing at a slot being removed.
local REDECIDE_POLLS = 200

-- job_id -> { n = extras appended, held = this cycle held items,
--             none = this job has no fuel filter, stop looking }
local surcharge = {}

local function bulk_class()
    return T().FUEL_BULK_CLASS
end

-- How many usable bulk fuel items the fort holds, counting no further
-- than `limit`. Same usability test as scan_for_fuel, and for the same
-- reason: an item that is forbidden, claimed, owned, dumped or an
-- artifact is not available for work, so counting it toward a demand
-- would post a job that cannot be filled.
local function count_bulk(limit)
    local cls = bulk_class()
    if not cls then return 0 end
    local n = 0
    local vec = nil
    pcall(function() vec = df.global.world.items.other.IN_PLAY end)
    if not vec then return 0 end
    pcall(function()
        for _, it in ipairs(vec) do
            if it.id ~= key_id then
                local usable = false
                pcall(function()
                    local f = it.flags
                    usable = not (f.hidden or f.forbid or f.dump
                        or f.garbage_collect or f.in_job
                        or f.removed or f.owned or f.artifact)
                end)
                if usable and item_has_class(it, cls) then
                    n = n + 1
                    if n >= limit then return end
                end
            end
        end
    end)
    return n
end

-- Is this filter the job's FUEL SLOT, in any state it can be in: the
-- vanilla BAR/COAL shape before widening, a tier class after it, or
-- FUEL_BULK once this section has claimed it, and serving no reagent.
-- The owner half is what keeps a reagent that IS coal (pig iron and
-- steel) from being counted, copied, stripped or erased as fuel.
--
-- Defined once, as is_fuel_slot in making-fuel-tuning.lua, because the
-- ghost asks the same question: see THE FUEL SLOT, DEFINED ONCE there.
-- No tuning means no fuel slot is ever recognised, so nothing is
-- surcharged, stripped or erased, which is the safe way to fail.
--
-- Assigned, not declared: the local is forward declared above keep_fuel
-- so the tank code, which sits earlier in the file, reaches this body.
is_any_fuel_filter = function(e)
    if not (tuning and tuning.is_fuel_slot) then return false end
    return tuning.is_fuel_slot(e) == true
end

local function fuel_slot_index(j)
    local found = nil
    pcall(function()
        for i, e in ipairs(j.job_items.elements) do
            if is_any_fuel_filter(e) then found = i return end
        end
    end)
    return found
end

-- ==========================================
-- DECIDE AND SHAPE, ONCE PER CYCLE
-- ==========================================
local function expand_fuel(j)
    if not SURCHARGE_ON then return end
    if surcharge[j.id] then return end
    -- A tanked job has no fuel slot to surcharge, and appending clones
    -- of a filter widen_job is about to erase is exactly how job 7252
    -- collected four bars off a paid tank. Memoised as none so the
    -- poll stops walking it.
    if spec_for(j).tank then
        surcharge[j.id] = { none = true }
        return
    end
    -- Never shape a job that already holds or has claimed anything.
    -- Slots appended after collection closes are never hauled, which
    -- is R15, and the poll only calls this on an empty job anyway.
    -- The guard is here for the onJobInitiated path, which is
    -- believed to run before any attachment and is not going to be
    -- trusted on belief alone. No memo is written, so the next empty
    -- poll decides normally.
    local n_items = 0
    pcall(function() n_items = #j.items end)
    if n_items > 0 then return end

    local idx = fuel_slot_index(j)
    if idx then
        -- Not widened yet. Writing a class onto the untouched
        -- BAR/COAL shape would leave vector_id at BAR and every
        -- slot blind to boulders and tools. The next poll runs
        -- widen_job first and comes back here.
        local raw = false
        pcall(function()
            local e = j.job_items.elements[idx]
            raw = e.item_type == df.item_type.BAR
                and e.mat_type == df.builtin_mats.COAL
        end)
        if raw then return end
    end
    if not idx then
        -- Most jobs in the fort are not fuel jobs. Remembered so the
        -- poll stops walking their filters every five frames.
        surcharge[j.id] = { none = true }
        return
    end

    -- Smith tier is already one finished bar per job, by physics.
    -- There is nothing to surcharge and nothing below it to fall
    -- back to.
    local spec = spec_for(j)
    if spec.class == T().FUEL_SMITH_CLASS then
        surcharge[j.id] = { n = 0, held = false, age = 0 }
        return
    end

    local want = T().FUEL_BULK_PER_SMELTING or 4
    local cls  = bulk_class()
    local have = cls and count_bulk(want) or 0

    if have < want then
        -- ---- THE FALLBACK ----
        -- Not enough bulk to pay the surcharge, so this cycle runs on
        -- finished fuel at the vanilla rate of one. n = 0 records that
        -- a decision was made and nothing was appended, so the cycle
        -- boundary still clears it and the next cycle asks again with
        -- whatever the fort holds by then.
        pcall(function()
            j.job_items.elements[idx].reaction_class =
                T().FUEL_SMITH_CLASS
            j.recheck_cntdn = 0
        end)
        surcharge[j.id] = { n = 0, held = false, age = 0 }
        return
    end

    local made = 0
    pcall(function()
        local els   = j.job_items.elements
        local proto = els[idx]
        proto.reaction_class = cls
        for _ = 2, want do
            -- :assign off the filter DF wrote itself, so reagent_index
            -- stays -1 and every clone is a shape DF already completes.
            -- -1 claims no reagent, which is why these need no reagent
            -- list grown behind them the way vessel slots do.
            local ne = proto._type:new()
            ne:assign(proto)
            els:insert('#', ne)
            made = made + 1
        end
        j.recheck_cntdn = 0
    end)
    surcharge[j.id] = { n = made, held = false, age = 0 }
end

-- ==========================================
-- COLLAPSE, BETWEEN CYCLES
-- ==========================================
-- delete frees the object, erase drops the pointer. What comes off is
-- chosen by what it is, not where it sits: a fuel slot with no owner,
-- last first, never the job's first fuel slot, which is DF's own. Only
-- ever called with the job holding nothing, so no attached item points
-- at a slot and erasing mid list is safe. That is what lets it pass
-- over anything another hand appended after our copies, the ghost's
-- jug slots included, instead of taking it.
--
-- State is cleared whether or not anything was removed, because
-- clearing it is what lets the next cycle decide afresh.
local function collapse_fuel(j, quiet)
    local st = surcharge[j.id]
    local removed = 0
    if st and st.n and st.n > 0 then
        pcall(function()
            local els = j.job_items.elements
            -- The first fuel slot is DF's own and always stays.
            local first = nil
            for i = 0, #els - 1 do
                if is_any_fuel_filter(els[i]) then first = i break end
            end
            if first == nil then return end
            -- Downward, so an erase never moves a slot still to visit.
            for i = #els - 1, first + 1, -1 do
                if removed >= st.n then break end
                if is_any_fuel_filter(els[i]) then
                    els[i]:delete()
                    els:erase(i)
                    removed = removed + 1
                end
            end
        end)
        -- Fewer than recorded means something else already took some.
        -- Nothing real was touched; it is said so the log shows the
        -- memo and the job disagreed.
        if removed < st.n then
            log('DETAIL', string.format('job %d: released %d of %d bulk fuel'
                .. ' slot(s); the rest were already gone.',
                j.id, removed, st.n), 'JOB')
        end
        if removed > 0 and not quiet then
            log('DETAIL', string.format('job %d released %d bulk fuel slot(s).',
                j.id, removed), 'JOB')
        end
    end
    surcharge[j.id] = nil
    return removed
end

-- One job, one cycle step. Called from the poll after widening.
local function surcharge_step(j)
    if not SURCHARGE_ON then return end
    local st = surcharge[j.id]
    if st and st.none then return end

    local n_items = 0
    pcall(function() n_items = #j.items end)

    if n_items > 0 then
        -- The cycle is holding. Marked so the empty list below is
        -- read as the END of a cycle and not the window a job opens
        -- with before its first haul.
        if st then st.held = true end
    elseif st and st.held then
        -- ---- BETWEEN CYCLES ----
        -- Held something, holds nothing now. That is DF's own cycle
        -- boundary, whether the cycle ended in a completed jug or in
        -- a cancellation, and both want the same thing: extras off,
        -- next cycle decides from current stock.
        collapse_fuel(j)
    elseif st then
        -- ---- THE DECISION HAS NOT BEEN TAKEN UP ----
        -- Still waiting for its first claim. Expire it so the shape
        -- cannot outlive the stock it was chosen against.
        st.age = (st.age or 0) + 1
        if st.age >= REDECIDE_POLLS then
            collapse_fuel(j, true)
        end
    else
        expand_fuel(j)
    end
end

-- Every extra this module ever appended, off a job, without needing
-- to remember which. DF posts exactly ONE fuel slot, so a second one is
-- ours by definition. A reagent that IS coal (pig iron, steel) is not a
-- fuel slot and is never counted: see is_fuel_slot in tuning. Used at
-- stop, and it also clears extras left by a session that died mid
-- cycle.
--
-- ---- NEVER UNDER AN ATTACHED ITEM ----
-- MEASURED, one HOTSAVE, before this guard: the start sweep erased
-- job 10111's three bulk copies while dried dung sat in one of them.
-- The job kept working with 3 items against 2 filters and completed
-- without a crash, but burned only the 2 dung it already held where it
-- owed 4, because the empty copies it was still collecting into were
-- gone. The sweep's count of 4 also took, by count, pig iron job
-- 10109's fuel slot, because its carbon reagent looked like a second
-- fuel slot before the owner test. Register R30.
--
-- A job holding anything now keeps its copies, and the second value
-- returned says how many, so start() can adopt them and collapse_fuel
-- takes them off when the cycle ends.
local function strip_extras(j)
    local removed, left = 0, 0
    pcall(function()
        local els = j.job_items.elements
        local n = 0
        for _, e in ipairs(els) do
            if is_any_fuel_filter(e) then n = n + 1 end
        end
        local held = 0
        pcall(function() held = #j.items end)
        if held > 0 then
            if n > 1 then left = n - 1 end
            return
        end
        -- By what they are, last first, until one fuel slot is left. The
        -- job holds nothing here, so erasing mid list moves no item, and
        -- anything appended after our copies is passed over, not taken.
        for i = #els - 1, 0, -1 do
            if n <= 1 then break end
            if is_any_fuel_filter(els[i]) then
                els[i]:delete()
                els:erase(i)
                n, removed = n - 1, removed + 1
            end
        end
    end)
    return removed, left
end


-- ==========================================
-- THE TANK CYCLE, PER POLL
-- ==========================================
-- Retries a verdict gets before an untouched cycle is read as a cancel.
-- The ghost settles on one retry, because DF does not always free a
-- consumed reagent in the same frame the cycle closes. Two here, at
-- this file's 5 frame poll: ten frames.
local TANK_RETRY = 2

-- The ghost's burn witness: every attached item AND everything riding
-- inside one, since a liquid rides inside its jug and is never attached
-- itself. Stack and dimension both, because DF can consume part of a
-- stack or part of a liquid and leave the item standing.
local function tank_snapshot(j)
    local seen = {}
    pcall(function()
        for _, iref in ipairs(j.items) do
            local it = iref.item
            if it then
                local cands = { it }
                for _, c in ipairs(dfhack.items.getContainedItems(it) or {}) do
                    cands[#cands + 1] = c
                end
                for _, c in ipairs(cands) do
                    local s, d = 1, 0
                    pcall(function() s = c.stack_size or 1 end)
                    pcall(function() d = c.dimension or 0 end)
                    seen[c.id] = { s = s, d = d }
                end
            end
        end
    end)
    return seen
end

-- The ghost's untouched() inverted, clause for clause: gone, a smaller
-- stack, a drained dimension, or flagged for cleanup are all a burn.
local function tank_burned(seen)
    for id, was in pairs(seen or {}) do
        local it = nil
        pcall(function() it = df.item.find(id) end)
        if not it then return true end
        local s, d, gc = 1, 0, false
        pcall(function() s = it.stack_size or 1 end)
        pcall(function() d = it.dimension or 0 end)
        pcall(function() gc = it.flags.garbage_collect end)
        if s < was.s or d < was.d or gc then return true end
    end
    return false
end

local function tank_verdict(st, tf)
    local p = st.pending
    if not p then return end
    if tank_burned(p.seen) then
        tf.settle_job(p.key)
        st.pending = nil
        persist_jobs()
    elseif p.wait >= TANK_RETRY then
        tf.release_job(p.key, 'the cycle consumed nothing')
        st.pending = nil
        persist_jobs()
    else
        p.wait = p.wait + 1
    end
end

-- Puts the job's own fuel filter back, at the END, where adding one is
-- legal under ghost.lua:1079. Widened at once rather than on the next
-- poll. When the tank took the slot at first posting the kept filter is
-- DF's raw BAR of builtin COAL, which the coal watcher guarantees
-- nothing can satisfy, and a job asking for what cannot exist is
-- cancelled inside a second (job 826). After a reload it is the slot as
-- the save recorded it, possibly already widened; widening it again is
-- harmless. widened and the surcharge memo are cleared first, so from
-- here this job is decided exactly like a freshly posted untanked one,
-- bulk surcharge included.
local function restore_fuel(j)
    local proto = kept[j.id]
    if not proto then return false end
    local have = 0
    pcall(function()
        for _, e in ipairs(j.job_items.elements) do
            if is_any_fuel_filter(e) then have = have + 1 end
        end
    end)
    if have > 0 then return false end
    local ok = pcall(function()
        local ne = proto._type:new()
        ne:assign(proto)
        j.job_items.elements:insert('#', ne)
    end)
    if not ok then return false end
    widened[j.id], surcharge[j.id] = nil, nil
    widen_job(j)
    -- INFO: it answers why a job went back to asking for fuel.
    log('INFO', string.format('job %d: tank cannot pay the next cycle, fuel'
        .. ' slot restored.', j.id), 'JOB')
    return true
end

-- One step per poll for a tanked job. Order is the ghost's: a finished
-- cycle's verdict is settled FIRST, then the next cycle is decided.
local function tank_step(j)
    local st = tank_st[j.id]
    if not st then return end
    local tf = tank_fuel()
    if not tf then return end

    tank_verdict(st, tf)

    local n = 0
    pcall(function() n = #j.items end)
    if n > 0 then
        -- Holding. Refreshed while items arrive, so a reagent gathered
        -- one at a time is fully witnessed before the cycle can end,
        -- and first sight wins so each item is judged against what it
        -- walked in with.
        st.held = true
        if st.key then
            for id, v in pairs(tank_snapshot(j)) do
                if not st.seen[id] then st.seen[id] = v end
            end
        end
        return
    end
    if not st.held then return end

    -- ---- BETWEEN CYCLES ----
    -- The finished cycle goes to pending, where its verdict can take a
    -- retry. The NEXT cycle cannot wait for that verdict: it is decided
    -- now, before DF hauls for it. A pending reservation still counts
    -- against the tank, so this can refuse a cycle the tank could have
    -- paid if the last one turns out cancelled, but it can never spend
    -- the same units twice.
    if st.key then
        if st.pending then
            -- An older verdict still out: decided now on what it can
            -- see, so the newer one can queue behind it.
            local p = st.pending
            if tank_burned(p.seen) then tf.settle_job(p.key)
            else tf.release_job(p.key, 'the cycle consumed nothing') end
        end
        st.pending = { key = st.key, seen = st.seen, wait = 0 }
        tank_verdict(st, tf)
    end

    st.cycle = st.cycle + 1
    st.held, st.seen, st.key = false, {}, nil
    local key = j.id .. ':' .. st.cycle
    if tf.reserve_job(st.bld, key) then
        st.key = key
        drain_job(j)
        -- Never reserve against a slot that is still there. A cycle that
        -- keeps its fuel slot collects solid fuel, so it must not ALSO be
        -- charged to the tank.
        if has_fuel_slot(j) then
            tf.release_job(key, 'a fuel slot survived the erase')
            st.key = nil
        end
    else
        restore_fuel(j)
    end
    -- The boundary changed the record: a verdict may have opened and the
    -- cycle count moved. Written now, so a save a frame later has it.
    persist_jobs()
end

-- A tanked job that left the list: completed or cancelled. The cycle
-- that was running gets the same verdict as any other, with the same
-- retries, and the entry is kept until that verdict lands.
local function tank_gone(id)
    local st = tank_st[id]
    if not st then return end
    local tf = tank_fuel()
    if tf then
        if st.key then
            if st.held then
                if st.pending then
                    local p = st.pending
                    if tank_burned(p.seen) then tf.settle_job(p.key)
                    else tf.release_job(p.key, 'the cycle consumed nothing') end
                end
                st.pending = { key = st.key, seen = st.seen, wait = 0 }
            else
                tf.release_job(st.key, 'the job left before it ran')
            end
            st.key = nil
        end
        tank_verdict(st, tf)
        if st.pending then
            persist_jobs()
            return
        end
    end
    tank_st[id] = nil
    if kept[id] then
        pcall(function() kept[id]:delete() end)
        kept[id] = nil
    end
    persist_jobs()
end

-- ---- RE-ADOPTION AT START ----
-- Every job the save says the tank owned is taken back, with its slot
-- rebuilt from the record. Run inside start() BEFORE the poll is
-- scheduled, so the poll never meets one of these jobs first and
-- reserves it a second time: widened is set on each for the same reason.
--
-- A job with its slot still erased is a tank cycle in flight: it is
-- reserved again, which is exactly what stop() released, or given its
-- slot back if the tank can no longer pay. A job with its slot present
-- was burning solid fuel at the save and is left to decide at its next
-- boundary, as it would have in session.
local function adopt_tank_jobs()
    local saved = {}
    pcall(function()
        saved = dfhack.persistent.getSiteData(JOBS_KEY, {}) or {}
    end)
    local live = {}
    pcall(function()
        local l = df.global.world.jobs.list.next
        while l do
            if l.item then live[l.item.id] = l.item end
            l = l.next
        end
    end)
    local tf = tank_fuel()

    -- ---- PASS 1: VERDICTS A SAVE CAUGHT MID RETRY ----
    -- Judged FIRST and DEFINITIVELY. The retry exists only because DF
    -- does not always free a consumed reagent in the same frame the
    -- cycle closes; across a save and reload that lag is gone, so a
    -- consumed item is absent and anything still present is untouched.
    -- Each is reserved again before its verdict, because settle_job
    -- pays out of a reservation, and first, while the charge still
    -- holds what it held at the save. Run for jobs that have since left
    -- as well: a finished job's burned cycle is owed all the same.
    local verdicts = 0
    for _, rec in pairs(saved) do
        local p = type(rec) == 'table' and rec.pending or nil
        if tf and p and p.key and rec.bld then
            local seen = {}
            for siid, v in pairs(p.seen or {}) do
                local iid = tonumber(siid)
                if iid and type(v) == 'table' then
                    seen[iid] = { s = tonumber(v.s) or 1,
                                  d = tonumber(v.d) or 0 }
                end
            end
            if tf.reserve_job(rec.bld, p.key) then
                if tank_burned(seen) then tf.settle_job(p.key)
                else tf.release_job(p.key, 'nothing consumed, judged'
                    .. ' after the reload') end
                verdicts = verdicts + 1
            end
        end
    end

    -- ---- PASS 2: THE JOBS ----
    local adopted, dropped = 0, 0
    for sid, rec in pairs(saved) do
        local id = tonumber(sid)
        local j = id and live[id]
        local proto = nil
        if j and type(rec) == 'table' and rec.bld then
            proto = table_to_slot(rec.slot, j)
        end
        if not proto then
            dropped = dropped + 1
        else
            kept[id] = proto
            -- The count resumes past the saved one, so no key made here
            -- can collide with one pass 1 just settled.
            local st = { bld = rec.bld,
                         cycle = (tonumber(rec.cycle) or 0) + 1,
                         key = nil, held = false, seen = {} }
            tank_st[id] = st
            widened[id] = true
            if not has_fuel_slot(j) then
                local key = id .. ':' .. st.cycle
                if tf and tf.reserve_job(rec.bld, key) then
                    st.key = key
                else
                    restore_fuel(j)
                end
            end
            adopted = adopted + 1
        end
    end
    persist_jobs()
    if adopted > 0 or dropped > 0 or verdicts > 0 then
        log('DETAIL', string.format('%d tank job(s) re-adopted from the save, %d'
            .. ' stale record(s) dropped, %d saved verdict(s) judged.',
            adopted, dropped, verdicts), 'ADOPT')
    end
end


-- ==========================================
-- WIDEN AT POSTING (Lock B of condition 5)
-- ==========================================
-- onJobInitiated fires when the job is posted, before any hauler is
-- dispatched. Widening here means the vanilla BAR/COAL filter never
-- exists during item selection, so the key is never a legal pick,
-- closing the window the 5 frame poll left open. Everything stays
-- inside pcall: an error escaping into eventful breaks every other
-- listener in the process.
local function on_initiated(j)
    pcall(function()
        if not dfhack.isMapLoaded() then return end
        if not _G.refinish_active then return end
        widen_job(j)
        -- Immediately after the widen, while nothing is
        -- attached. This is the only moment a job's fuel
        -- demand can still be shaped: fuel is hauled last
        -- and collection closes the tick it lands.
        expand_fuel(j)
    end)
end


-- ==========================================
-- A SOLID FUEL JOB HANDED TO THE TANK
-- ==========================================
-- A job posted while its furnace's tank could not pay is widened onto
-- solid fuel and marked handled. A repeating one then stayed on solid
-- fuel for the rest of its life, even after the tank was filled,
-- because nothing watched its boundaries: it was never a tank job.
--
-- The switch needs no boundary tracking of its own. The one safe moment
-- to take a fuel slot away is when the job holds nothing, which is the
-- rule drain_job already enforces: before its first haul, or between
-- cycles. So a job the tank does not already own, at a furnace whose
-- tank can now pay, still carrying a fuel slot and holding nothing, is
-- simply un-marked, and widen_job meets it on the same pass exactly as
-- it meets a fresh posting: the tank branch reserves and erases. Its
-- surcharge memo goes with it, since the tank owns its fuel from here.
--
-- Cheapest tests first, because this runs for every widened job on
-- every poll: two table lookups, the item count, and only then the
-- building and its tank.
local function handover(j)
    if not widened[j.id] or tank_st[j.id] then return end
    local held = 0
    pcall(function() held = #j.items end)
    if held > 0 then return end
    local b = nil
    pcall(function() b = df.building.find(holder_id(j) or -1) end)
    if not (b and tanked(b)) then return end
    if not has_fuel_slot(j) then return end
    widened[j.id] = nil
    surcharge[j.id] = nil
end


-- ==========================================
-- THE POLL
-- ==========================================
local function poll()
    if not dfhack.isMapLoaded() then return end
    if not _G.refinish_active then return end

    local ok, err = pcall(function()
        -- ---- THE KEY ----
        -- With HONEST_MENUS off the key simply exists whenever the
        -- module is running. Every fuel menu is white. That is the
        -- seam to fix later, deliberately, not the thing to debug
        -- while the basic mechanism is unproven.
        if HONEST_MENUS then
            local viewed = nil
            pcall(function()
                local vs = df.global.game.main_interface.view_sheets
                if vs.open then
                    viewed = df.building.find(vs.viewing_bldid)
                end
            end)
            local vid = viewed and viewed.id or -1
            if vid ~= last_viewed then
                last_viewed = vid
                fuel_check_countdown = 0
            end
            fuel_check_countdown = fuel_check_countdown - 1
            if fuel_check_countdown <= 0 then
                fuel_check_countdown = 200
                local now = scan_for_fuel(
                    viewed and spec_for_building(viewed) or nil)
                if now ~= fuel_present then
                    if now then
                        if mint_key() then
                            fuel_present = true
                            log('INFO', 'fuel present, menus unlocked.', 'MENU')
                        end
                    else
                        fuel_present = false
                        destroy_key()
                        -- INFO: it answers why the fuel menus went red.
                        log('INFO', 'no fuel in the fort, menus locked.', 'MENU')
                    end
                end
            end
        end

        local k = key_item()
        if k then
            -- No claim recovery. The only job that can touch a
            -- classless key is hauling, which MOVES it and gives it
            -- back. Reminting on in_job is what multiplied one key
            -- into eight: the replacement lands on open ground,
            -- draws its own store job, and the loop feeds itself.
            -- The key is simply left alone while it rides.
            --
            -- hidden coming OFF exposes the bar; artifact coming ON
            -- removes it from the fuel count. Either is re-asserted.
            -- DF clears hidden when a tile reveals, so this fires
            -- on reveal in normal play.
            local lost = false
            pcall(function()
                lost = (not k.flags.hidden) or k.flags.artifact
            end)
            if lost then
                hide_key(k)
                log('DETAIL', 'key flags re-asserted.', 'KEY')
            end
        else
            -- No key and no gating: mint one. Covers a failed mint
            -- at start, a destroyed key, and a reload.
            key_id = nil
            if not HONEST_MENUS then mint_key() end
        end

        local live = {}
        local l = df.global.world.jobs.list.next
        while l do
            local j = l.item
            if j then
                live[j.id] = true
                -- Backstop only. The event at posting is primary;
                -- this catches anything the event missed, and the
                -- repeat job case where DF rebuilds filters on a
                -- job id already seen (is_fuel_filter recognises
                -- both shapes, and widened is pruned below when a
                -- job id leaves the list).
                --
                -- handover first, so a solid fuel job whose tank can
                -- now pay is un-marked in time for widen_job to hand
                -- it to the tank on this same pass.
                handover(j)
                widen_job(j)
                -- Expand, hold, collapse. The backstop for a
                -- job the event missed, and the ONLY path for
                -- a repeat cycle, which never re-fires
                -- onJobInitiated and would otherwise be born
                -- demanding four fuel items forever.
                surcharge_step(j)
                -- After the surcharge, so a boundary's extras are
                -- already collapsed before the tank decides the next
                -- cycle.
                tank_step(j)
            end
            l = l.next
        end
        for id in pairs(widened) do
            if not live[id] then widened[id] = nil end
        end
        for id in pairs(surcharge) do
            if not live[id] then surcharge[id] = nil end
        end
        -- A tanked job that left still owes a verdict, so it is not
        -- simply dropped: tank_gone settles or releases it, retrying
        -- like any boundary, and only then lets it go.
        for id in pairs(tank_st) do
            if not live[id] then tank_gone(id) end
        end
        for id, k in pairs(kept) do
            if not live[id] and not tank_st[id] then
                pcall(function() k:delete() end)
                kept[id] = nil
            end
        end
    end)
    if not ok then log('ERROR', 'POLL ERROR: ' .. tostring(err), 'POLL') end
end


-- ==========================================
-- PUBLIC API
-- ==========================================
function start()
    if T().FUEL_ACCESS_ENABLED == false then
        log('INFO', 'disabled in tuning, not starting.', 'START')
        return
    end
    widened, n_widened, reported = {}, 0, {}
    -- The tank's per job state starts empty, freeing any clones a
    -- session that never reached stop() left behind, then is rebuilt
    -- from the save before the poll exists. making-fuel-tank-fuel has
    -- already started by now and restored the charge.
    for _, k in pairs(kept) do pcall(function() k:delete() end) end
    tank_st, kept = {}, {}
    adopt_tank_jobs()
    -- Same discipline as the key sweep below: a session that died
    -- mid cycle leaves extra fuel slots on live jobs, and this
    -- script's memory of them died with it. Swept by signature
    -- instead, exactly as the key is.
    surcharge = {}
    -- A job holding items keeps its copies (strip_extras will not erase
    -- under an item) and they are ADOPTED into the surcharge memo as if
    -- this session had added them, so collapse_fuel takes them off at
    -- that job's cycle boundary like its own, and expand_fuel does not
    -- add three more on top.
    local left, adopted = 0, 0
    pcall(function()
        local l = df.global.world.jobs.list.next
        while l do
            if l.item then
                local r, kept = strip_extras(l.item)
                left = left + r
                if kept and kept > 0 then
                    surcharge[l.item.id] = { n = kept, held = true, age = 0 }
                    adopted = adopted + kept
                end
            end
            l = l.next
        end
    end)
    if left > 0 then
        log('DETAIL', string.format('%d orphan bulk fuel slot(s) swept at'
            .. ' start.', left), 'START')
    end
    if adopted > 0 then
        log('DETAIL', string.format('%d bulk fuel slot(s) on busy job(s) kept until'
            .. ' their cycle ends.', adopted), 'START')
    end
    -- Excess sweep FIRST: keep the first signature bar and destroy
    -- the rest. One survivor is adopted rather than executed, so a
    -- key already resting in a stockpile stays put across sessions
    -- instead of being reminted onto open ground and hauled all
    -- over again. Any multiplication remnants from earlier sessions
    -- die here.
    destroy_key(true)
    fuel_present, fuel_check_countdown = false, 0
    -- No blind mint while menus are honest: the first scan decides.
    if not HONEST_MENUS then mint_key() end
    eventful.onJobInitiated[REPEAT_KEY] = on_initiated
    eventful.enableEvent(eventful.eventType.JOB_INITIATED, 0)
    repeatUtil.scheduleEvery(REPEAT_KEY, 5, 'frames', poll)
    log('DETAIL', string.format('active. tiers=%s honest=%s',
        tostring(TIERS_ENABLED), tostring(HONEST_MENUS)), 'START')
end

function stop()
    eventful.onJobInitiated[REPEAT_KEY] = nil
    repeatUtil.cancel(REPEAT_KEY)
    -- ---- THE TANK AT STOP ----
    -- The tank's jobs are saved as they stand: an erased slot stays
    -- erased, and its record is what lets the next start take the job
    -- back. Putting every slot back instead would keep saves tidier,
    -- but a cycle in flight at the save would reload demanding fuel it
    -- did not need, and in a fort running on tanks with no solid fuel
    -- DF cancels it.
    --
    -- stop() WRITES NOTHING AND SETTLES NOTHING. MEASURED, job 7432: on
    -- a save that unloads the map, RM saves in its shutdown sequence and
    -- this file stops only after SC_MAP_UNLOADED, so anything written
    -- here misses the save; then a second stop follows with the tank's
    -- state already cleared. A write here was therefore at best too
    -- late, and on that second stop an EMPTY record set. HOTSAVE clears
    -- RAM before its quicksave, so there the empty set would have been
    -- saved and every tanked job orphaned (inferred from the protocol,
    -- not seen). Settling a pending verdict here had the mirror fault:
    -- the debit landed after the save while the record still carried
    -- the verdict, so a HOTSAVE would have charged it twice.
    --
    -- So the save carries only what was written through as it happened,
    -- and start() re-judges and re-reserves from that. Nothing is
    -- released either: making-fuel-tank-fuel clears every reservation
    -- in its own start().
    for _, k in pairs(kept) do pcall(function() k:delete() end) end
    tank_st, kept = {}, {}
    -- Extras come off every live job FIRST. A job left
    -- demanding four FUEL_BULK after the class is popped
    -- from every material matches nothing and cancels
    -- forever, which is a broken save, not a clean stop.
    -- EXCEPT a job holding items: it keeps its copies,
    -- because erasing under an item strands it and the
    -- cycle underpays (job 10111), and the next start
    -- adopts them. See strip_extras.
    local stripped = 0
    pcall(function()
        local l = df.global.world.jobs.list.next
        while l do
            if l.item then
                stripped = stripped + strip_extras(l.item)
            end
            l = l.next
        end
    end)
    if stripped > 0 then
        log('DETAIL', string.format('%d bulk fuel slot(s) stripped at'
            .. ' stop.', stripped), 'STOP')
    end
    surcharge = {}
    destroy_key()
    widened = {}
    log('DETAIL', string.format('stopped. %d job(s) widened this session.',
        n_widened), 'STOP')
end

-- Console only. log() routes to the RM log panel when the module is
-- running, and a status line belongs to whoever typed the command.
function status()
    local k = key_item()
    local where = ''
    if k then
        pcall(function()
            where = string.format(' at %d,%d,%d',
                k.pos.x, k.pos.y, k.pos.z)
        end)
    end
    print(string.format('FUEL ACCESS: key %s',
        k and string.format('item %d, hidden=%s%s', key_id,
            tostring(k.flags.hidden), where)
        or 'ABSENT (red menus everywhere is then correct)'))
    print(string.format('  tiers=%s honest=%s',
        tostring(TIERS_ENABLED), tostring(HONEST_MENUS)))
    print(string.format('  primary %s | smith %s | vector %s',
        tostring(T().FUEL_CLASS), tostring(T().FUEL_SMITH_CLASS),
        tostring(T().FUEL_VECTOR)))
    print(string.format('  widened: %d job(s) this session', n_widened))
end

if dfhack_flags and dfhack_flags.module then return end
local args = {...}
if args[1] == 'start' then start()
elseif args[1] == 'stop' then stop()
elseif args[1] == 'status' then status()
else print('usage: making-fuel-access start | stop | status') end