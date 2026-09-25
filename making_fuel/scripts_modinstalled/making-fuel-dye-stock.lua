--@ module = true
-- making-fuel-dye-stock.lua
-- ==========================================
-- MAKING FUEL: DYE STOCKPILE SLOTS (FOOD / MILLED PLANTS)
-- ==========================================
-- Registers the module's dyes in DF's PlantPowder enumeration, the one
-- behind Food / Milled Plants, so a stockpile can address them the way
-- it addresses every vanilla dye.
--
-- ==========================================
-- WHY IT IS NEEDED
-- ==========================================
-- Every vanilla dye is a plant powder. The Milled Plants settings are
-- indexed by position in a per category ORGANIC enumeration,
-- world.raws.mat_table.organic_types / organic_indexes, built from the
-- raws at world load. Our dyes are inorganics injected after that, so
-- they have no position and no setting can switch them on. The hides
-- had the same gap in the Glob category. The mechanism and what was
-- measured are in making-fuel-hide-stock.lua and
-- RM_Organic_Category_Registration.md:
--
--   - Both directions are required: the enumeration entry, and the
--     reverse index on the material, food_mat_index[PlantPowder].
--     Either one alone hauls nothing (O5).
--   - settings.food.powder_plant on each stockpile is indexed by that
--     position and IS saved. It is grown to a target, never shrunk,
--     and a zero length vector (a pile with no food settings) is left
--     alone.
--
-- Registration makes a dye ADDRESSABLE. Which category DF files the
-- item under is a separate gate (O8).
--
-- ==========================================
-- WHY THE DYES ARE PLANT MATERIALS (measured 2026-09-23)
-- ==========================================
-- The dyes were first injected as INORGANICS, and that failed both
-- ways a player could see:
--
--   With the plant powder claim (POWDER_MISC, POWDER_MISC_PLANT) and
--   a Milled Plants registration, they were listed by name but never
--   hauled: flags, back-reference and switched-on slots all matched a
--   vanilla dye that hauled at once (making-fuel-stock-probe diff).
--
--   Without the claim, DF hauled their bags straight to Furniture as
--   Bags, exactly as it stores vanilla plaster, and they were listed
--   nowhere. Unlisted reads as missing and broken.
--
-- No stockpile category lists an inorganic powder by name and also
-- hauls by that listing. So the dyes live on the module's DYE_HOST
-- plant (making_fuel_plants.json) as plant materials, where DF files
-- them under Milled Plants natively. Plant materials made at run time
-- are missing from the list DF builds at load too, so this script
-- still registers them. An inorganic module dye is reported, never
-- registered: registering one is what stranded them in the dyer.
--
-- ==========================================
-- GROWING A SETTINGS VECTOR: NUMBERS, NOT BOOLEANS
-- ==========================================
-- df-structures declares settings.food.* as vectors of bool, but at
-- run time DFHack exposes them as vector<char>. Its own error says so:
-- "Cannot write field vector<char>.101: integer expected" (session log
-- 2026-09-23 15:10:04). So an element is a NUMBER, 0 or 1, and must be
-- written as one; a Lua boolean is refused, which is what failed both
-- earlier grows here. insert works on a char vector, and appending 1
-- or 0 with insert('#', n) is the form making-fuel-hide-stock.lua has
-- used successfully from the start. Each new slot is read back.
--
-- ==========================================
-- LIFECYCLE, AS MEASURED (session log 2026-09-23)
-- ==========================================
-- START. making_fuel.lua starts this during RM's token call, BEFORE
-- RM injects the module's materials: start found 0 dyes at 13:53:48,
-- and RM injected them at 13:53:49. So start() arms a short frame poll
-- that syncs until the dyes are there, then drops out. Frames advance
-- while paused; game days do not. The daily poll carries on after.
--
-- RE-INJECTION. An in-session hotsave re-runs RM's token call while
-- this is still running (15:11:27, "already running"), and RM then
-- rebuilds the dyes as new material objects with no reverse index.
-- So a start() that finds itself running re-arms the settle poll, and
-- the reverse index is back within a few frames instead of a day.
--
-- STOP. Cancels the polls and removes nothing. The PlantPowder
-- enumeration is rebuilt from raws at load (109 before a hotsave, 101
-- after it), an in-session hotsave re-injects the dyes at the same
-- indices so the entries stay true, and RM's rule is one prefix sweep
-- rather than every script cleaning up after itself. The stockpile
-- settings vectors are the one thing carried in a save: they are the
-- player's data, grown only, never shrunk.
-- ==========================================

-- ---- LOG IDENTITY, DECLARED HERE ----
-- Same shape as making-fuel-hide-stock.lua: the module states its own
-- system and subsystem, and a guarded reqscript keeps a missing logger
-- from taking this file down.
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'DYE_STOCK'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

local repeatUtil = require('repeat-util')
local REPEAT_KEY = 'making_fuel_dye_stock'
local SETTLE_KEY = 'making_fuel_dye_stock_settle'

-- Daily. Only a stockpile built mid-session can need it, and a day's
-- delay only means a dye waits where it was made.
local POLL_DAYS = 1

-- The settle poll after start. RM's whole pipeline took under two
-- seconds in the measured session; 100 tries of 10 frames is far past
-- that, and the poll stops as soon as the dyes are registered. Frame
-- timers survive a world unload, so stop() cancels it and the try cap
-- ends it regardless.
local SETTLE_FRAMES = 10
local SETTLE_TRIES  = 100

-- Ours: the module prefix AND IS_DYE. Varnish and every other module
-- material carry the prefix without the flag.
local OUR_PREFIX = 'MAKING_FUEL_'

-- The stockpile category flags, in stockpile_group_set order.
local GROUPS = {
    'animals', 'food', 'furniture', 'corpses', 'refuse', 'stone',
    'ammo', 'coins', 'bars_blocks', 'gems', 'finished_goods',
    'leather', 'cloth', 'wood', 'weapons', 'armor', 'sheet',
}

-- ---- BODY IDENTITY ----
-- A fresh table per execution of this file body, so a reload rebinds
-- the polls to the new code. Why both this and the _G flag are needed
-- is written up at BODY IDENTITY in making-fuel-hide-stock.lua.
local BODY = {}
_G.making_fuel_dye_stock_running = _G.making_fuel_dye_stock_running or false

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
-- SUBJECT is the correlation slot: SYNC and SETTLE for the two polls,
-- STOCKPILE for a single pile, START and STOP. The status and usage
-- output answers commands typed at the console, so it prints.
--
-- A fault that leaves module dyes unable to reach a stockpile is an
-- ERROR, the same as in making-fuel-hide-stock.lua.
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

-- ---- FAULTS ON THE DAILY SYNC, ONCE EACH ----
-- sync runs every in game day, about twelve real seconds, and a
-- structural fault fails the same way on every pass. Each distinct fault
-- is logged once per session under its own key; start() clears the set.
-- Same shape as making-fuel-hide-stock.lua.
local faults_said = {}
local function fault_once(key, typ, msg, subject)
    if faults_said[key] then return end
    faults_said[key] = true
    log(typ, msg, subject)
end

local function try(fn, dflt)
    local ok, v = pcall(fn)
    if ok then return v end
    return dflt
end

-- The "switched on" test for a settings element. They read back as
-- numbers on this build (see GROWING A SETTINGS VECTOR); a boolean is
-- accepted too, so the test holds whichever DFHack hands back.
local function is_on(v)
    return v == true or (type(v) == 'number' and v ~= 0)
end


-- ==========================================
-- OUR DYES
-- ==========================================
-- Every dye on one of the module's host plants, as a list of
--   { mt = material type, mi = material index, mat = material,
--     token = 'PLANT_MAT:<plant>:<key>' }
-- A host plant is any plant whose id carries the module prefix. The
-- type and index come from dfhack.matinfo.find on the token, so the
-- plant material numbering is DF's own, not worked out here.
local function our_dyes()
    local out = {}
    local plants = try(function() return df.global.world.raws.plants.all end)
    if not plants then return out end
    for _, p in ipairs(plants) do
        local pid = try(function() return p.id end, '')
        if pid:find(OUR_PREFIX, 1, true) == 1 then
            local mats = try(function() return p.material end)
            if mats then
                for _, m in ipairs(mats) do
                    if try(function() return m.flags.IS_DYE end) then
                        local token = 'PLANT_MAT:' .. pid .. ':' .. tostring(m.id)
                        local info = try(function() return dfhack.matinfo.find(token) end)
                        if info then
                            out[#out + 1] = { mt = info.type, mi = info.index,
                                              mat = m, token = token }
                        end
                    end
                end
            end
        end
    end
    return out
end

-- Module dyes still declared as inorganics, by id. Reported, never
-- registered: see WHY THE DYES ARE PLANT MATERIALS.
local function inorganic_dyes()
    local out = {}
    local list = try(function() return df.global.world.raws.inorganics.all end)
    if not list then return out end
    for _, inorg in ipairs(list) do
        local hit = try(function()
            return inorg.id:find(OUR_PREFIX, 1, true) == 1 and inorg.material.flags.IS_DYE
        end, false)
        if hit then out[#out + 1] = inorg.id end
    end
    return out
end


-- ==========================================
-- THE PLANTPOWDER ENUMERATION
-- ==========================================
-- Returns types, idxs, cat, or nil when any part is unreadable.
local function vectors()
    local cat = try(function() return df.organic_mat_category.PlantPowder end)
    if cat == nil then
        -- ERROR, once: no module dye can be given a stockpile slot.
        fault_once('powder', 'ERROR',
            'df.organic_mat_category.PlantPowder did not resolve.', 'SYNC')
        return nil
    end
    local mt = try(function() return df.global.world.raws.mat_table end)
    local types = mt and try(function() return mt.organic_types[cat] end)
    local idxs  = mt and try(function() return mt.organic_indexes[cat] end)
    if not types or not idxs then
        fault_once('powder_vectors', 'ERROR',
            'organic_types / organic_indexes unreadable for PlantPowder.',
            'SYNC')
        return nil
    end
    return types, idxs, cat
end

-- The two vectors are parallel; read only as far as both reach.
local function length(types, idxs)
    return math.min(#types, #idxs)
end

-- Position of (mat_type, mat_index) in the enumeration, or nil.
local function position_of(types, idxs, mt, mi)
    for k = 0, length(types, idxs) - 1 do
        if types[k] == mt and idxs[k] == mi then return k end
    end
    return nil
end


-- ==========================================
-- STOCKPILE SETTINGS
-- ==========================================
-- One vector, from len up to target: append 1 or 0 per new slot, then
-- read back the length and every new slot. Returns true, or false and
-- the reason. See GROWING A SETTINGS VECTOR above.
local function grow_vector(vec, len, target, fill)
    local n = fill and 1 or 0
    local ok, err = pcall(function()
        for _ = len, target - 1 do vec:insert('#', n) end
    end)
    if not ok then return false, tostring(err) end
    local now = try(function() return #vec end)
    if now ~= target then
        return false, 'length reads back ' .. tostring(now)
    end
    for k = len, target - 1 do
        if is_on(try(function() return vec[k] end)) ~= fill then
            return false, string.format('slot %d reads back wrong', k)
        end
    end
    return true
end

-- Grows settings.food.powder_plant on every stockpile to the
-- enumeration length. To a target, never by a delta and never
-- shrunk; a zero length vector is a pile with no food settings and is
-- left alone. The header of making-fuel-hide-stock.lua has why.
--
-- A new slot is switched on only when EVERY existing slot on that pile
-- is on: that pile takes all milled plants, so it takes ours too. A
-- pile taking some milled plants and not others made a choice this
-- cannot read, so ours start off there, and the player can switch them
-- on by name. The hides use "any switched on", which suits globs;
-- milled plants mix flour with dye, and a flour pile should not start
-- filling with dye.
local function grow_settings(target)
    local bld = try(function() return df.global.world.buildings.all end)
    local nb = bld and try(function() return #bld end, 0) or 0
    local grown = 0

    for i = 0, nb - 1 do
        local b = try(function() return bld[i] end)
        if b and df.building_stockpilest:is_instance(b) then
            local vec = try(function() return b.settings.food.powder_plant end)
            local len = vec and try(function() return #vec end)
            if vec and len and len > 0 and len < target then
                local all_on = true
                for k = 0, len - 1 do
                    if not is_on(try(function() return vec[k] end)) then
                        all_on = false
                        break
                    end
                end
                local ok, why = grow_vector(vec, len, target, all_on)
                local id = tostring(try(function() return b.id end))
                if ok then
                    grown = grown + 1
                    log('DETAIL', string.format('stockpile %s: food.powder_plant %d -> %d, new slots %s.',
                        id, len, target,
                        all_on and 'ON (the pile takes every milled plant)' or 'off'), 'STOCKPILE')
                else
                    -- ERROR, once per pile: that pile cannot take the
                    -- new dye slots.
                    fault_once('grow:' .. id, 'ERROR', string.format(
                        'stockpile %s: could not grow food.powder_plant from'
                        .. ' %d to %d: %s', id, len, target, tostring(why)),
                        'STOCKPILE')
                end
            end
        end
    end
    return grown
end


-- ==========================================
-- THE REVERSE INDEX
-- ==========================================
-- Material to position. Written and read back, so a build without the
-- field, or one that ignores the write, says so.
local function set_reverse(mat, cat, pos)
    if not mat then return false, 'material unreadable' end
    if not pcall(function() mat.food_mat_index[cat] = pos end) then
        return false, 'no food_mat_index on this build'
    end
    local back = try(function() return mat.food_mat_index[cat] end)
    if back ~= pos then
        return false, string.format('wrote %d, reads back %s', pos, tostring(back))
    end
    return true
end


-- ---- WHAT WAS LAST SAID ----
-- sync runs often, so the log carries changes, not a heartbeat.
-- Reset in start(), so a recycle reports once.
local said_count, said_len, said_inorg = nil, nil, nil


-- ==========================================
-- SYNC: REGISTER, REVERSE, GROW
-- ==========================================
-- Returns the number of module dyes found, so the settle poll knows
-- when RM has injected them.
function sync()
    if not dfhack.isMapLoaded() then return 0 end
    local types, idxs, cat = vectors()
    if not types then return 0 end

    local mine = our_dyes()

    -- ---- APPEND WHAT IS MISSING ----
    -- Each entry is the (mat_type, mat_index) pair of a plant material,
    -- the same shape as every vanilla entry.
    local added = 0
    for _, d in ipairs(mine) do
        if not position_of(types, idxs, d.mt, d.mi) then
            local ok, err = pcall(function()
                types:insert('#', d.mt)
                idxs:insert('#', d.mi)
            end)
            if ok then
                added = added + 1
            else
                -- ERROR, once per dye: it cannot be stockpiled.
                fault_once('append:' .. tostring(d.token), 'ERROR',
                    string.format('could not append %s to PlantPowder: %s',
                    d.token, tostring(err)), 'SYNC')
            end
        end
    end

    -- ---- REVERSE INDEX, EVERY DYE, EVERY SYNC ----
    -- Not only the new ones: a stale reverse index pointing at another
    -- material is worse than none.
    local fixed, failed = 0, nil
    for _, d in ipairs(mine) do
        local pos = position_of(types, idxs, d.mt, d.mi)
        if pos then
            local ok, why = set_reverse(d.mat, cat, pos)
            if ok then fixed = fixed + 1 else failed = why end
        end
    end

    local target = length(types, idxs)
    grow_settings(target)

    if added > 0 or #mine ~= said_count or target ~= said_len then
        log('DETAIL', string.format('%d dye(s) in PlantPowder (%d appended now), reverse index on %d,'
            .. ' enumeration length %d.', #mine, added, fixed, target), 'SYNC')
        said_count, said_len = #mine, target
    end
    if failed then
        -- ERROR, once: without the reverse index dyes are not hauled.
        fault_once('reverse', 'ERROR', 'reverse index NOT set: '
            .. tostring(failed), 'SYNC')
    end

    local stray = inorganic_dyes()
    if #stray ~= said_inorg then
        if #stray > 0 then
            log('WARNING', string.format('%d module dye(s) declared as inorganics, NOT registered: %s.'
                .. ' DF stores an inorganic powder as its bag under Furniture, unlisted;'
                .. ' declare dyes on a plant host.', #stray, table.concat(stray, ', ')), 'SYNC')
        end
        said_inorg = #stray
    end
    return #mine
end


-- ==========================================
-- THE SETTLE POLL
-- ==========================================
-- Runs sync every SETTLE_FRAMES frames until the dyes are found and
-- registered, then cancels itself. See LIFECYCLE in the header.
local settle_tries = 0

local function settle()
    settle_tries = settle_tries + 1
    local n = sync()
    if n > 0 or settle_tries >= SETTLE_TRIES then
        pcall(function() repeatUtil.cancel(SETTLE_KEY) end)
        if n == 0 then
            log('WARNING', string.format('no module dyes found after %d tries; the daily poll keeps looking.',
                settle_tries), 'SETTLE')
        end
    end
end

local function arm_settle()
    settle_tries = 0
    repeatUtil.scheduleEvery(SETTLE_KEY, SETTLE_FRAMES, 'frames', settle)
end


-- ==========================================
-- LIFECYCLE
-- ==========================================
function start(silent)
    faults_said = {}
    if _G.making_fuel_dye_stock_running then
        if _G.making_fuel_dye_stock_body == BODY then
            -- RM re-running its token call: the dyes are about to be
            -- rebuilt. See RE-INJECTION in the header.
            arm_settle()
            log('DETAIL', 'already running; settle poll re-armed for the re-injection.', 'START')
            return
        end
        _G.making_fuel_dye_stock_body = BODY
        sync()
        repeatUtil.scheduleEvery(REPEAT_KEY, POLL_DAYS, 'days', sync)
        arm_settle()
        log('DETAIL', 'reloaded: polls rebound to the new body.', 'START')
        return
    end
    _G.making_fuel_dye_stock_body = BODY
    _G.making_fuel_dye_stock_running = true
    said_count, said_len, said_inorg = nil, nil, nil
    sync()
    repeatUtil.scheduleEvery(REPEAT_KEY, POLL_DAYS, 'days', sync)
    arm_settle()
    if not silent then
        log('DETAIL', 'active. Module dyes carry a Milled Plants slot, as vanilla dyes do.', 'START')
    end
end

function stop()
    pcall(function() repeatUtil.cancel(REPEAT_KEY) end)
    pcall(function() repeatUtil.cancel(SETTLE_KEY) end)
    _G.making_fuel_dye_stock_running = false
    log('DETAIL', 'stopped. Nothing removed; see STOP in the header.', 'STOP')
end


-- ==========================================
-- COMMAND: status
-- ==========================================
-- Three parts, all read only:
--   1. each dye: its slot, reverse index and powder flags;
--   2. each stockpile: the categories it takes, its Milled Plants
--      vector length, and how many of our slots it has and has on;
--   3. every dye ITEM on the map, ours and vanilla: the container it
--      sits in, the building on its tile, and the flags that decide
--      whether a hauler may take it. A vanilla dye stuck the same way
--      as ours points at the pile; a vanilla dye hauled while ours sits
--      points at how DF files ours.
local function building_label(b)
    if not b then return '-' end
    local t = try(function() return df.building_type[b:getType()] end, '?')
    return string.format('%s %s', tostring(t), tostring(try(function() return b.id end)))
end

local function item_label(i)
    local t = try(function() return df.item_type[i:getType()] end, '?')
    return string.format('%s %s', tostring(t), tostring(try(function() return i.id end)))
end

-- Names of every flag set in a bitfield, space separated.
local function true_flags(bf)
    local out = {}
    pcall(function()
        for k, v in pairs(bf) do
            if v == true then out[#out + 1] = tostring(k) end
        end
    end)
    table.sort(out)
    return table.concat(out, ' ')
end

function status()
    local types, idxs, cat = vectors()
    if not types then return end
    local target = length(types, idxs)
    local mine = our_dyes()
    -- Keyed "type:index", so an item can be matched to one of ours.
    local ours = {}
    for _, d in ipairs(mine) do ours[d.mt .. ':' .. d.mi] = true end
    print(string.format('PlantPowder enumeration length %d.', target))

    -- ---- 1. DYES ----
    for _, d in ipairs(mine) do
        local rev = try(function() return d.mat.food_mat_index[cat] end)
        local f   = try(function() return d.mat.flags end)
        local pos = position_of(types, idxs, d.mt, d.mi)
        print(string.format('  %-44s %4d:%-4d slot %-6s reverse %-6s %s%s',
            d.token, d.mt, d.mi, pos and tostring(pos) or 'ABSENT', tostring(rev),
            (f and try(function() return f.POWDER_MISC end)) and 'POWDER_MISC ' or '',
            (f and try(function() return f.POWDER_MISC_PLANT end)) and 'POWDER_MISC_PLANT' or ''))
    end
    for _, id in ipairs(inorganic_dyes()) do
        print('  ' .. id .. '  declared as an inorganic: not registered (see sync)')
    end

    -- ---- 2. STOCKPILES ----
    local bld = try(function() return df.global.world.buildings.all end)
    local nb = bld and try(function() return #bld end, 0) or 0
    for i = 0, nb - 1 do
        local b = try(function() return bld[i] end)
        if b and df.building_stockpilest:is_instance(b) then
            local on = {}
            for _, g in ipairs(GROUPS) do
                if try(function() return b.settings.flags[g] end) then on[#on + 1] = g end
            end
            local vec = try(function() return b.settings.food.powder_plant end)
            local len = vec and try(function() return #vec end)
            local have, lit = 0, 0
            for _, d in ipairs(mine) do
                local pos = position_of(types, idxs, d.mt, d.mi)
                if pos and len and pos < len then
                    have = have + 1
                    if is_on(try(function() return vec[pos] end)) then lit = lit + 1 end
                end
            end
            print(string.format('  stockpile %-6s takes [%s]  food.powder_plant len=%s  our slots %d/%d, on %d%s',
                tostring(try(function() return b.id end)),
                #on == #GROUPS and 'everything' or table.concat(on, ' '),
                tostring(len), have, #mine, lit,
                (len and len > 0 and len < target) and '   SHORT' or ''))
        end
    end

    -- ---- 3. DYE ITEMS ----
    -- Where each dye sits: its container chain out to the outermost
    -- holder, the tile and the building on it, any building or unit
    -- holding that outermost item, and every flag set on the item and
    -- on the outermost container. getPosition returns x, y, z as three
    -- values, not a coord. The deep comparison lives in
    -- making-fuel-stock-probe.lua.
    local items = try(function() return df.global.world.items.other.POWDER_MISC end)
    local n_items = 0
    if items then
        for _, it in ipairs(items) do
            local mt, mi = it.mat_type, it.mat_index
            local info = try(function() return dfhack.matinfo.decode(mt, mi) end)
            if info and try(function() return info.material.flags.IS_DYE end) then
                n_items = n_items + 1
                local chain, outer = {}, it
                local c = try(function() return dfhack.items.getContainer(it) end)
                while c do
                    chain[#chain + 1] = item_label(c)
                    outer = c
                    local cur = c
                    c = try(function() return dfhack.items.getContainer(cur) end)
                end
                local ok_p, x, y, z = pcall(dfhack.items.getPosition, it)
                if not ok_p then x, y, z = nil, nil, nil end
                local tile = x and try(function() return dfhack.buildings.findAtTile(x, y, z) end)
                local hold = try(function() return dfhack.items.getHolderBuilding(outer) end)
                local unit = try(function() return dfhack.items.getHolderUnit(outer) end)
                print(string.format('  item %-7s %-7s %-34s in [%s] at %s on %s | held by %s%s',
                    tostring(it.id), ours[mt .. ':' .. mi] and 'OURS' or 'vanilla',
                    tostring(try(function() return info:getToken() end)),
                    #chain > 0 and table.concat(chain, ' > ') or 'nothing',
                    x and string.format('%d,%d,%d', x, y, z) or '?',
                    building_label(tile), building_label(hold),
                    unit and (' | carried by unit ' .. tostring(unit.id)) or ''))
                print(string.format('       item flags [%s]   outermost flags [%s]',
                    true_flags(it.flags), outer ~= it and true_flags(outer.flags) or '-'))
            end
        end
    end
    print(string.format('%d dye item(s) on the map.', n_items))
end


-- ==========================================
-- CLI
-- ==========================================
if dfhack_flags and dfhack_flags.module then return end

local cmd = ...
if cmd == 'on' then start()
elseif cmd == 'off' then stop()
elseif cmd == 'sync' then sync()
elseif cmd == 'status' then status()
else print('usage: making-fuel-dye-stock on | off | sync | status')
end