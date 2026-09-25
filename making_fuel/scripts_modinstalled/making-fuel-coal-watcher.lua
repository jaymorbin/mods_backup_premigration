--@ module = true
-- making-fuel-coal-watcher.lua
-- ==========================================
-- MAKING FUEL: THE COAL EXTERMINATOR
-- ==========================================
-- THE INVARIANT: no builtin coal bar exists in the fort's world,
-- ever, except the menu key. Charcoal (mat_index 1), coke (0) and
-- refined coal (-1) are replaced the moment they appear with the
-- module's own materials, which carry the fuel reaction classes.
-- Builtin COAL itself is NEVER tagged, so the fuel-access key,
-- a builtin refined coal bar, matches no widened filter and no
-- dwarf can ever select it.
--
-- WHY: fuel selection in this module runs on reaction classes.
-- Tagging builtin COAL made the key legal fuel and a dwarf burned
-- it, and there is no item flag that closes that while keeping the
-- key countable (measured, repeatedly, at cost). So the classes
-- live on module materials instead, and this watcher guarantees
-- every actual lump of coal in the world IS a module material.
--
-- SOURCES COVERED:
--   * onItemCreated: fires for reactions (vanilla and injected),
--     jobs, and scripts. This is the instant path: coal from any
--     reaction is converted the frame it exists.
--   * The poll: sweeps the BAR item vector. The API notes that
--     onItemCreated does NOT fire for traders, migrants and
--     invaders, so purchased or seized coal arrives silently.
--     The BAR vector is small, so the sweep runs cheap at the
--     same 5 frame cadence as the rest of the module.
--
-- SPARE RULES, exactly two:
--   * The menu key. fuel-access publishes its id as
--     _G.refinish_fuel_key_id, and only that exact item is spared.
--     Signature is not enough here, because a mod-made refined
--     coal bar shares the key's mat_index and must still die.
--   * Trader-owned items (flags.trader). A caravan's own goods are
--     not the fort's to transmute, and rewriting them mid-visit
--     risks the trade contract. The instant a coal bar is bought,
--     the flag clears and the next sweep converts it.
--
-- ITEM TYPE: BAR. The smith tier's item floor is BAR by design
-- (a forge is hand fed solid fuel), so the replacements must be
-- bars to pass their own tier. If BAR misbehaves anywhere, the
-- fallback is TOOL: change REPLACEMENT_ITYPE below and give the
-- three tools defs and sprites, nothing else in this file moves.
-- ==========================================

local eventful   = require('plugins.eventful')
local repeatUtil = require('repeat-util')

local REPEAT_KEY = 'making_fuel_coal_watcher'
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
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'COAL_WATCHER'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

-- The single fallback lever. df.item_type.BAR today; df.item_type
-- .TOOL (plus subtype resolution in make_replacement) if bars ever
-- prove wrong.
local REPLACEMENT_ITYPE = df.item_type.BAR

-- builtin mat_index -> module material key. Every index dies,
-- including -1, which is why the key is spared by id, not by
-- signature.
--
-- Bare keys now, no prefix. The two resolvers below turn a key into
-- a token, and there are two possible tokens for the same coal.
local REPLACEMENT_FOR = {
    [1]  = 'CHARCOAL',
    [0]  = 'COKE',
    [-1] = 'COAL',
}

-- ==========================================
-- WHERE THE COAL MATERIALS LIVE
-- ==========================================
-- The same three coals exist twice, on purpose.
--
-- The three coals live on the injected plant host, as PLANT
-- materials, and nowhere else.
--
-- WHY A PLANT. A bar of an inorganic material displays "charcoal
-- bars"; the same bar of a plant material displays "charcoal".
-- Measured both ways on one item. The suffix belongs to the
-- inorganic branch of DF's item description code and no flag, name
-- or colour suppresses it, so material MODE is the only lever.
--
-- The inorganic coals that used to sit beside these were deleted
-- once the plant path was proven: an unused inorganic still appears
-- in stone stockpile settings and material lists, which is the same
-- class of seam the plant path exists to close.
--
-- SO THERE IS NO FALLBACK. If the host fails to inject, the token
-- does not resolve, and builtin coal is left exactly as DF made it.
-- Reverting to inorganics means restoring those three material
-- definitions and a second lookup in module_mat.
local PLANT_HOST = 'PLANT_MAT:MAKING_FUEL_COAL_HOST:'

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
-- SUBJECT is the correlation slot: RESOLVE for the coal materials,
-- START, POLL and STOP. The prints in status() and the usage line
-- answer commands typed at the console.
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
-- MODULE MATERIAL RESOLUTION
-- ==========================================
-- Injected materials get a fresh index every world load, so the
-- cache is per session and start() clears it. A miss is warned
-- once and the item is left alone rather than destroyed: a coal
-- bar is better than a vanished one if the module band is absent.
local mat_cache  = {}
-- Two flags, not one. start() runs at the module broadcast, which is
-- BEFORE injection, so the first lookup of a grade legitimately misses
-- and warns. The lookup recovers on its own, because a miss sets no
-- cache entry and every later call retries the find. With a single
-- flag that recovery was silent: the miss claimed the grade was left
-- untouched and nothing ever corrected it, which reads like a
-- permanent fault instead of a startup ordering artifact.
local mat_warned = {}
local mat_missed = {}

local function module_mat(mat_key)
    if mat_cache[mat_key] then return mat_cache[mat_key] end

    -- Plant host only. The inorganic coals were deleted once the
    -- plant path was proven, because an unused inorganic still shows
    -- up in stone stockpile settings and material lists, which is
    -- the same class of seam the plant path exists to close.
    --
    -- THE UNDO IS NO LONGER FREE. Reverting means restoring those
    -- three material definitions AND putting the inorganic fallback
    -- back here. Until then, a missing host means coal is left as
    -- builtin, which the log says out loud below rather than
    -- silently converting to something wrong.
    local mi, from = nil, nil
    if PLANT_HOST then
        pcall(function() mi = dfhack.matinfo.find(PLANT_HOST .. mat_key) end)
        if mi then from = 'plant host' end
    end

    if mi then
        mat_cache[mat_key] = mi
        -- Once per key per session, because which of the two answered
        -- is the single fact that explains whether coal bars read
        -- "charcoal" or "charcoal bars" in this fort.
        if not mat_warned[mat_key] then
            mat_warned[mat_key] = true
            if mat_missed[mat_key] then
                -- Cancels the startup miss out loud, so the log's last
                -- word on the grade is the true one.
                log('DETAIL', mat_key .. ' resolved from the ' .. tostring(from)
                    .. ' after the startup miss. Coal of that grade is'
                    .. ' converted from here on.', 'RESOLVE')
            else
                log('DETAIL', mat_key .. ' resolved from the ' .. tostring(from) .. '.', 'RESOLVE')
            end
        end
    elseif not mat_missed[mat_key] then
        mat_missed[mat_key] = true
        -- DETAIL: this miss happens at every startup, since the watcher
        -- starts before the host injects, and the resolve line above cancels
        -- it. A host that never injects is reported by the module engine as
        -- an ERROR, which is where that fault belongs.
        log('DETAIL', 'MATERIAL MISSING: ' .. mat_key
            .. ' is not on the plant host yet. Coal of that grade is'
            .. ' left untouched until it injects. Expected once at'
            .. ' startup, since the lookup is retried on every call.', 'RESOLVE')
    end
    return mi
end

-- ==========================================
-- A CREATOR TO MINT AGAINST
-- ==========================================
-- createItem needs a unit. A living, uncaged citizen is standing
-- on fort connected ground by definition; units.active[0] is not
-- a citizen and has misplaced items before.
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

-- ==========================================
-- THE CONVERSION
-- ==========================================
-- One builtin coal bar in, one module bar out, same place, same
-- stack, same forbid/dump state, original destroyed. Guards first,
-- so a skip is always deliberate and named.
local converted = { [1] = 0, [0] = 0, [-1] = 0 }
local skipped_in_job = 0

local function is_builtin_coal_bar(it)
    local hit = false
    pcall(function()
        hit = it:getType() == df.item_type.BAR
            and it.mat_type == df.builtin_mats.COAL
    end)
    return hit
end

local function convert(it)
    -- Spare rule 1: the menu key, by exact id.
    if it.id == _G.refinish_fuel_key_id then return false end

    local f = it.flags
    -- Spare rule 2: a caravan's own goods until purchased.
    local skip = false
    pcall(function()
        skip = f.trader or f.removed or f.garbage_collect
    end)
    if skip then return false end

    -- Mid job items are deferred, not spared: removing an item a
    -- job holds corrupts the job. The poll converts it after.
    local held = false
    pcall(function() held = f.in_job end)
    if held then skipped_in_job = skipped_in_job + 1 return false end

    local idx = nil
    pcall(function() idx = it:getMaterialIndex() end)
    local mat_key = REPLACEMENT_FOR[idx]
    if not mat_key then mat_key = 'CHARCOAL' end
    local mi = module_mat(mat_key)
    if not mi then return false end

    local ok = pcall(function()
        local pos   = { x = it.pos.x, y = it.pos.y, z = it.pos.z }
        local box   = dfhack.items.getContainer(it)
        -- Captured BEFORE the original is removed: the holder ref
        -- dies with the item. A reaction product belongs to its
        -- workshop until hauled, and a replacement dropped on the
        -- tile instead skips that state and lies loose on the
        -- floor.
        local bld   = dfhack.items.getHolderBuilding(it)
        local stack = it.stack_size
        local forbid, dump = it.flags.forbid, it.flags.dump

        local u = fort_citizen()
        if not u then error('no citizen to mint against') end
        local made = dfhack.items.createItem(
            u, REPLACEMENT_ITYPE, -1, mi.type, mi.index)
        local new = made and made[1]
        if not new then error('createItem returned nothing') end

        pcall(function() new.stack_size = stack end)
        pcall(function()
            new.flags.forbid = forbid
            new.flags.dump   = dump
        end)
        -- Same shelf it was on: container first, then the holder
        -- building (TEMP role, the normal product awaiting haul
        -- state, which is moveToBuilding's default), ground last.
        if box then
            dfhack.items.moveToContainer(new, box)
        elseif bld then
            if not dfhack.items.moveToBuilding(new, bld) then
                dfhack.items.moveToGround(new, pos)
            end
        else
            dfhack.items.moveToGround(new, pos)
        end
        dfhack.items.remove(it)
        converted[idx] = (converted[idx] or 0) + 1
    end)
    return ok
end

-- ==========================================
-- THE REWRITE: EVERY OTHER ITEM TYPE, IN PLACE
-- ==========================================
-- A bar is replaced, above. Anything else is rewritten where it lies:
-- same item, same stack, same container, only the material changes.
-- Replacing one would cost its quality, decorations, wear and contents,
-- and there is nothing to gain: the item is already the shape whoever
-- made it wanted.
--
-- MEASURED, making-fuel-coal-form-probe build C1, one fort: DF accepted
-- builtin coal in every type tried, BAR, POWDER_MISC, GLOB, BLOCKS,
-- FIGURINE, BOULDER, ROUGH and SMALLGEM, the last three being types DF
-- itself only makes of stone or glass. Each one sat inert as fuel while
-- it was builtin coal, because builtin COAL carries no reaction class.
-- Writing our charcoal, a PLANT material, into mat_type and mat_index
-- gave each of them FUEL and FUEL_SMELTING, the right description
-- ("rough charcoal", "charcoal blocks"), an unchanged value, and a
-- kiln burned every one. Nothing crashed. Register L23.
--
-- The write is the same one the hijacker's product guard makes on a
-- non-bar product in play.
local rewritten = { [1] = 0, [0] = 0, [-1] = 0 }

-- Ids left alone because a job held them, retried by the poll. A
-- handful at most: a job holds an item for one cycle.
local deferred = {}

local function is_builtin_coal_other(it)
    local hit = false
    pcall(function()
        hit = it.mat_type == df.builtin_mats.COAL
            and it:getType() ~= df.item_type.BAR
    end)
    return hit
end

local function rewrite(it)
    -- The same spare as the bar path. The menu key is a bar, so it
    -- never reaches here, and a caravan's goods are not ours to
    -- transmute until they are bought.
    local skip = false
    pcall(function()
        skip = it.flags.trader or it.flags.removed
            or it.flags.garbage_collect
    end)
    if skip then return false end

    -- Held by a job: deferred, not spared. The job matched this item on
    -- the very material being rewritten, so it waits until the job lets
    -- go. Counted once, however many polls it takes.
    local held = false
    pcall(function() held = it.flags.in_job end)
    if held then
        if not deferred[it.id] then
            skipped_in_job  = skipped_in_job + 1
            deferred[it.id] = true
        end
        return false
    end

    local idx = nil
    pcall(function() idx = it:getMaterialIndex() end)
    if idx == nil then idx = 1 end
    local mi = module_mat(REPLACEMENT_FOR[idx] or 'CHARCOAL')
    if not mi then return false end

    local ok = pcall(function()
        it.mat_type  = mi.type
        it.mat_index = mi.index
    end)
    if ok then rewritten[idx] = (rewritten[idx] or 0) + 1 end
    return ok
end

-- The opening sweep for everything that is not a bar. The event below
-- catches every item a reaction, job or script mints, so this is here
-- for the other two doors: a save written before this coverage, and
-- anything that arrived while the module was off. Once, at start, not
-- on the poll: the BAR vector is small and cheap every 5 frames, all
-- items is neither.
local function sweep_other()
    if not dfhack.isMapLoaded() then return end
    local found = {}
    pcall(function()
        for _, it in ipairs(df.global.world.items.all) do
            if is_builtin_coal_other(it) then table.insert(found, it) end
        end
    end)
    for _, it in ipairs(found) do rewrite(it) end
    if #found > 0 then
        log('DETAIL', string.format('%d non bar coal item(s) found at start.',
            #found), 'START')
    end
end

-- ==========================================
-- THE TWO TRIGGERS
-- ==========================================
-- Event: the instant path for every created item. Everything stays
-- inside pcall; an error escaping into eventful breaks every other
-- listener in the process.
local function on_created(item_id)
    pcall(function()
        if not dfhack.isMapLoaded() then return end
        if not _G.refinish_active then return end
        local it = df.item.find(item_id)
        if not it then return end
        if is_builtin_coal_bar(it) then
            convert(it)
        elseif is_builtin_coal_other(it) then
            rewrite(it)
        end
    end)
end

-- Poll: the backstop for trade, migrants, invaders, and anything
-- deferred while in_job. Sweeps only the BAR vector, which is
-- small, and collects first so removal never disturbs the vector
-- mid walk.
local function poll()
    if not dfhack.isMapLoaded() then return end
    if not _G.refinish_active then return end
    local ok, err = pcall(function()
        local doomed = {}
        for _, it in ipairs(df.global.world.items.other.BAR) do
            if is_builtin_coal_bar(it)
               and it.id ~= _G.refinish_fuel_key_id then
                table.insert(doomed, it)
            end
        end
        for _, it in ipairs(doomed) do convert(it) end

        -- Non bar coal the rewrite deferred while a job held it. Ids,
        -- not items, so one that DF removed meanwhile just drops out.
        for id in pairs(deferred) do
            local it = df.item.find(id)
            if not (it and is_builtin_coal_other(it)) then
                deferred[id] = nil
            elseif rewrite(it) then
                deferred[id] = nil
            end
        end
    end)
    if not ok then log('ERROR', 'POLL ERROR: ' .. tostring(err), 'POLL') end
end

-- ==========================================
-- PUBLIC API
-- ==========================================
function start()
    mat_cache, mat_warned, mat_missed = {}, {}, {}
    converted = { [1] = 0, [0] = 0, [-1] = 0 }
    rewritten = { [1] = 0, [0] = 0, [-1] = 0 }
    deferred = {}
    skipped_in_job = 0
    eventful.onItemCreated[REPEAT_KEY] = on_created
    eventful.enableEvent(eventful.eventType.ITEM_CREATED, 0)
    repeatUtil.scheduleEvery(REPEAT_KEY, 5, 'frames', poll)
    -- Opening sweep: coal already sitting in this save dies now.
    poll()
    sweep_other()
    log('DETAIL', 'active. Builtin coal is terminated on sight;'
        .. ' the menu key alone is spared.', 'START')
end

function stop()
    eventful.onItemCreated[REPEAT_KEY] = nil
    repeatUtil.cancel(REPEAT_KEY)
    log('DETAIL', string.format(
        'stopped. Converted: %d charcoal, %d coke, %d refined;'
        .. ' rewritten in place: %d.',
        converted[1] or 0, converted[0] or 0, converted[-1] or 0,
        (rewritten[1] or 0) + (rewritten[0] or 0) + (rewritten[-1] or 0)), 'STOP')
end

-- Console only: a status line belongs to whoever typed the command.
function status()
    print(string.format(
        'COAL WATCH: converted %d charcoal, %d coke, %d refined'
        .. ' this session; %d deferred while in_job.',
        converted[1] or 0, converted[0] or 0, converted[-1] or 0,
        skipped_in_job))
    print(string.format(
        '  rewritten in place (not bars): %d charcoal, %d coke,'
        .. ' %d refined.',
        rewritten[1] or 0, rewritten[0] or 0, rewritten[-1] or 0))
    -- Counted over every item, not just the BAR vector: a console
    -- command can afford one walk, and the number is meaningless if it
    -- only looks where the poll looks.
    local n, other = 0, 0
    pcall(function()
        for _, it in ipairs(df.global.world.items.all) do
            if it.id ~= _G.refinish_fuel_key_id then
                if is_builtin_coal_bar(it) then n = n + 1
                elseif is_builtin_coal_other(it) then other = other + 1 end
            end
        end
    end)
    print(string.format(
        '  builtin coal at large right now: %d bar(s), %d other'
        .. ' item(s) (both should be 0)', n, other))
end

if dfhack_flags and dfhack_flags.module then return end
local args = {...}
if args[1] == 'start' then start()
elseif args[1] == 'stop' then stop()
elseif args[1] == 'status' then status()
else print('usage: making-fuel-coal-watcher start | stop | status') end