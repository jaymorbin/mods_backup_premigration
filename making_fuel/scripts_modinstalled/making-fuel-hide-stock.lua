--@ module = true
-- making-fuel-hide-stock.lua
-- ==========================================
-- MAKING FUEL: HIDE GLOB STOCKPILE SLOTS
-- ==========================================
-- Puts the hide materials into DF's Glob enumeration so a food
-- stockpile can address them, and grows the settings vectors that are
-- indexed by it.
--
-- ==========================================
-- WHY ONLY THIS ONE THING NEEDS IT
-- ==========================================
-- Every other injected material in every RM module hauls correctly,
-- because every other one is an inorganic stored in a category whose
-- settings vector is indexed by INORGANIC index. Measured on a live
-- fort: stone.mats, bars_mats, coins.mats, gems.cut_mats and
-- armor.mats all read 767, and the hide material sits at inorganic
-- index 765. Those vectors already cover us.
--
-- The food categories are different. They are indexed by position in
-- a per category ORGANIC enumeration held in
-- world.raws.mat_table.organic_types and organic_indexes, built from
-- the raws at world load. Measured:
--
--   Glob   len=2416   ours=ABSENT   fat=372
--
-- Vanilla llama fat is at position 372. Our material is absent from
-- all forty categories, because it did not exist when the enumeration
-- was built. There is therefore no position for a stockpile setting to
-- switch on, which is why STOCKPILE_GLOB on the material does nothing
-- and why clearing IS_STONE changed nothing.
--
-- The hide globs are the only thing in the module that claims an
-- ORGANIC storage category while being an inorganic material. Nothing
-- else has this problem and nothing else needs this file.
--
-- ==========================================
-- WHAT THIS WRITES, AND THE ONE HAZARD
-- ==========================================
-- Two appends per material, to organic_types[Glob] and
-- organic_indexes[Glob]. Those live in raws, are rebuilt from the mod
-- files every load, and are not saved, so the append has to be redone
-- every load. That is safe and self correcting.
--
-- The stockpile settings vectors ARE saved. Growing one writes into
-- fort data that outlives this mod. The consequences, stated rather
-- than assumed:
--   - Every load re-appends the same materials, so the enumeration
--     length is stable and the resize is idempotent. It grows to a
--     target, never by a delta, so it cannot creep.
--   - If the mod is later removed, a stockpile carries a few trailing
--     bytes DF's own enumeration does not reach. DF indexes by
--     position and stops at its own list length, so the tail should be
--     ignored. UNTESTED, and it is the one thing here that touches
--     data we do not own.
--
-- Nothing is ever removed from either vector. Shrinking a saved
-- settings vector would shift every position after the cut, which
-- would silently re-point the player's choices at other materials.
-- ==========================================

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
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'HIDE_STOCK'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

local repeatUtil = require('repeat-util')
local REPEAT_KEY = 'making_fuel_hide_stock'


-- ---- BODY IDENTITY ----
-- A fresh table per execution of this file body. reqscript re-executes
-- the body and makes a new one; a world load does not.
--
-- It exists because the two obvious ways to guard start() both fail,
-- in opposite directions. A file-local running flag resets on a new
-- body, so start() proceeds and rebinds correctly, but it knows
-- nothing about the world and can run against dead state. A _G flag
-- gets the world right and then refuses to rebind, so repeatUtil keeps
-- calling the PREVIOUS body's closure and the reloaded code never runs
-- while manual commands run the new code. Tracking both distinguishes
-- "already running in this same body" from "reloaded, needs rebinding".
local BODY = {}

-- Slow. The set only changes when a creature is butchered for the
-- first time ever, which is rare, and a missed day costs nothing
-- because the hide simply sits where it was made until the next poll.
local POLL_DAYS = 1

local OUR_PREFIX = 'MAKING_FUEL_HIDE'

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
-- SUBJECT is the correlation slot: SYNC for the daily pass, STOCKPILE
-- for a single pile, START and STOP. The status, reverse and usage
-- output answers commands typed at the console, so it prints.
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

_G.making_fuel_hide_stock_running = _G.making_fuel_hide_stock_running or false

-- ==========================================
-- THE INORGANIC LIST
-- ==========================================
-- raws.inorganics is a STRUCT holding several lists, not a vector. The
-- vector is .all inside it, which is what the rest of the engine uses
-- everywhere it touches inorganics. Taking # of the container returns
-- nothing, which is what made this fail twice and what made the stock
-- probe print inorganics=nil while 767 was visible in a dozen other
-- rows of the same output.
local function inorganics()
    local v = try(function()
        local x = df.global.world.raws.inorganics.all
        local _ = #x
        return x
    end)
    if v then return v, 'raws.inorganics.all' end
    return nil, nil
end

-- Every hide material we have injected, as inorganic indices.
local function our_indices()
    local out = {}
    local list, path = inorganics()
    if not list then
        -- ERROR: no hide glob can be given a stockpile slot.
        fault_once('inorganics', 'ERROR',
            'could not read df.global.world.raws.inorganics.all.'
            .. ' No slots can be registered.', 'SYNC')
        return out, nil
    end
    local n = try(function() return #list end, 0)
    for i = 0, n - 1 do
        local id = try(function() return list[i].id end)
        if id and tostring(id):find(OUR_PREFIX, 1, true) == 1 then
            out[#out + 1] = i
        end
    end
    return out, path
end

-- ==========================================
-- THE GLOB ENUMERATION
-- ==========================================
local function glob_vectors()
    local cat = try(function() return df.organic_mat_category.Glob end)
    if cat == nil then
        fault_once('glob', 'ERROR',
            'df.organic_mat_category.Glob did not resolve.', 'SYNC')
        return nil
    end
    local mt = try(function() return df.global.world.raws.mat_table end)
    if not mt then
        fault_once('mat_table', 'ERROR', 'world.raws.mat_table unreadable.',
            'SYNC')
        return nil
    end
    local types = try(function() return mt.organic_types[cat] end)
    local idxs  = try(function() return mt.organic_indexes[cat] end)
    if not types or not idxs then
        fault_once('glob_vectors', 'ERROR',
            'organic_types / organic_indexes unreadable for Glob.', 'SYNC')
        return nil
    end
    return types, idxs
end

-- Position of (mat_type, mat_index) in the enumeration, or nil.
local function position_of(types, idxs, mt, mi)
    local n = try(function() return #types end, 0)
    for k = 0, n - 1 do
        if try(function() return types[k] end) == mt
           and try(function() return idxs[k] end) == mi then
            return k
        end
    end
    return nil
end

-- ==========================================
-- STOCKPILE SETTINGS
-- ==========================================
-- Grow settings.food.glob on every stockpile to the enumeration
-- length. Grows to a target, never by a delta, so running it twice in
-- one session is a no op and a stale save cannot make it creep.
--
-- New slots inherit the stockpile's existing intent: if any glob is
-- already enabled there, a hide is enabled too. A player who switched
-- globs on for that pile meant globs, and a new one appearing switched
-- off would read as the feature not working. A pile with no globs
-- enabled stays untouched in spirit and gets a disabled slot.
local function resize_settings(target)
    local bld = try(function() return df.global.world.buildings.all end)
    local nb = bld and try(function() return #bld end, 0) or 0
    local grown = 0

    for i = 0, nb - 1 do
        local b = try(function() return bld[i] end)
        if b and df.building_stockpilest:is_instance(b) then
            local vec = try(function() return b.settings.food.glob end)
            local len = vec and try(function() return #vec end)
            -- A stockpile with a zero length vector is one that does
            -- not carry food settings at all. Leave it alone; growing
            -- it would hand it a food category it never had.
            if vec and len and len > 0 and len < target then
                local any_on = false
                for k = 0, len - 1 do
                    if try(function() return vec[k] end) ~= 0 then
                        any_on = true
                        break
                    end
                end
                local fill = any_on and 1 or 0
                local ok = pcall(function()
                    for _ = len, target - 1 do vec:insert('#', fill) end
                end)
                if ok then
                    grown = grown + 1
                    log('DETAIL', string.format('stockpile %s: food.glob %d -> %d,'
                        .. ' new slots %s.', tostring(try(function()
                        return b.id end)), len, target,
                        fill == 1 and 'ENABLED (pile already takes globs)'
                                   or 'disabled'), 'STOCKPILE')
                else
                    -- ERROR, once per pile: that pile cannot take the
                    -- new hide slots, so hides never reach it.
                    local pid = tostring(try(function() return b.id end))
                    fault_once('grow:' .. pid, 'ERROR', string.format(
                        'stockpile %s: could not grow food.glob from %d to'
                        .. ' %d.', pid, len, target), 'STOCKPILE')
                end
            end
        end
    end
    return grown
end

-- ==========================================
-- THE REVERSE INDEX
-- ==========================================
-- Appending to organic_types and organic_indexes builds one direction
-- only: position to material. DF also has to go material to position,
-- and it will not linearly search 2420 entries every time a hauler
-- considers an item. That reverse lookup lives on the material.
--
-- So a material can be in the enumeration, have an enabled settings
-- slot, and still never be hauled, because the lookup that would reach
-- the settings never resolves a position. That is the state measured
-- after the first sync: registered, enabled, inert.
--
-- The field name is not assumed. It is tried, and if it is not there
-- the `reverse` command below prints what the material actually
-- carries so the next attempt is against a real name rather than a
-- fourth guess.
local function set_reverse(mi, cat, pos)
    local mat = try(function()
        return df.global.world.raws.inorganics.all[mi].material end)
    if not mat then return false, 'material unreadable' end
    local ok = pcall(function() mat.food_mat_index[cat] = pos end)
    if not ok then return false, 'no food_mat_index on this build' end
    local back = try(function() return mat.food_mat_index[cat] end)
    if back ~= pos then
        return false, string.format('wrote %d, reads back %s', pos,
            tostring(back))
    end
    return true
end

-- ==========================================
-- COMMAND: reverse
-- ==========================================
-- Ours beside vanilla llama fat, on whatever the material carries.
-- Fat is hauled, so whatever fat has and we do not is the difference.
function reverse()
    local cat = try(function() return df.organic_mat_category.Glob end)
    local fat = try(function()
        return dfhack.matinfo.find('CREATURE:LLAMA:FAT') end)
    local fmat = fat and fat.material

    local function report(label, mat)
        if not mat then print(label .. ': material unreadable') return end
        local v = try(function() return mat.food_mat_index[cat] end)
        print(string.format('%s food_mat_index[Glob] = %s', label,
            tostring(v)))
        -- Every field on the material whose name could be a lookup
        -- table, so a wrong guess at the name is visible rather than
        -- silent. Top level only; no tree walk.
        local names = {}
        pcall(function()
            for k, _ in pairs(mat) do
                local n = tostring(k)
                if n:find('index') or n:find('food') or n:find('mat_') then
                    names[#names + 1] = n
                end
            end
        end)
        table.sort(names)
        print('   candidate fields: [' .. table.concat(names, ',') .. ']')
    end

    local mine = our_indices()
    if mine[1] then
        local m = try(function()
            return df.global.world.raws.inorganics.all[mine[1]].material end)
        report('ours', m)
    end
    report('fat ', fmat)
end

-- ---- WHAT WAS LAST SAID ----
-- sync runs daily forever, so an unconditional log line is a line
-- repeated for the life of the fort. These hold the last reported
-- answer so the log carries state CHANGES rather than a heartbeat.
-- Reset in start(), because a recycle should report once.
local said_path  = nil
local said_count = nil
local said_fixed = nil

-- ==========================================
-- THE ONE OPERATION
-- ==========================================
function sync()
    local types, idxs = glob_vectors()
    if not types then return end

    local mine, path = our_indices()
    if path and (path ~= said_path or #mine ~= said_count) then
        -- Says what MOVED when it moves. A count that changes is a
        -- material injected or swept since the last sync, which is
        -- worth a line; the same count a day later is not.
        if said_count and #mine ~= said_count then
            log('DETAIL', string.format('inorganic list read from %s, %d hide'
                .. ' material(s) (was %d).', path, #mine, said_count), 'SYNC')
        else
            log('DETAIL', string.format('inorganic list read from %s, %d hide'
                .. ' material(s).', path, #mine), 'SYNC')
        end
        said_path, said_count = path, #mine
    end
    if #mine == 0 then return end

    local added = 0
    for _, mi in ipairs(mine) do
        -- mat_type 0 is the inorganic branch. The enumeration holds
        -- (mat_type, mat_index) pairs and has no objection to an
        -- inorganic living in it; it simply was not built with one.
        if not position_of(types, idxs, 0, mi) then
            local ok = pcall(function()
                types:insert('#', 0)
                idxs:insert('#', mi)
            end)
            if ok then
                added = added + 1
            else
                -- ERROR, once per material: hides of it cannot be
                -- stockpiled.
                fault_once('append:' .. tostring(mi), 'ERROR', string.format(
                    'could not append inorganic %d to the Glob'
                    .. ' enumeration.', mi), 'SYNC')
            end
        end
    end

    local target = try(function() return #types end, 0)
    if added > 0 then
        log('DETAIL', string.format('%d hide material(s) registered in the Glob'
            .. ' enumeration. Length now %d.', added, target), 'SYNC')
    end

    -- ---- AND THE REVERSE DIRECTION ----
    -- Done for every material every sync, not only the newly appended
    -- ones, because the enumeration is rebuilt from raws each load
    -- while positions can land differently, and a stale reverse index
    -- pointing at another material is worse than an absent one.
    local cat = try(function() return df.organic_mat_category.Glob end)
    local fixed, failed = 0, nil
    for _, mi in ipairs(mine) do
        local pos = position_of(types, idxs, 0, mi)
        if pos then
            local ok, why = set_reverse(mi, cat, pos)
            if ok then fixed = fixed + 1 else failed = why end
        end
    end
    -- The WRITE still happens every sync, every material. Only the
    -- line is conditional: the same count a day later says nothing
    -- new, and a different one is the fact worth having.
    if fixed > 0 and fixed ~= said_fixed then
        log('DETAIL', string.format('reverse index set on %d material(s).', fixed), 'SYNC')
        said_fixed = fixed
    end
    if failed then
        -- ERROR: without the reverse index hides are not hauled to a
        -- pile.
        fault_once('reverse', 'ERROR',
            'reverse index could NOT be set: ' .. tostring(failed)
            .. '. Run `making-fuel-hide-stock reverse` to see what the'
            .. ' material actually carries.', 'SYNC')
    end

    resize_settings(target)
end

-- ==========================================
-- LIFECYCLE
-- ==========================================
function start(silent)
    faults_said = {}
    if _G.making_fuel_hide_stock_running then
        if _G.making_fuel_hide_stock_body == BODY then
            log('DETAIL', 'already running.', 'START')
            return
        end
        _G.making_fuel_hide_stock_body = BODY
        sync()
        repeatUtil.scheduleEvery(REPEAT_KEY, POLL_DAYS, 'days', sync)
        log('DETAIL', 'reloaded: sync rebound to the new body.', 'START')
        return
    end
    _G.making_fuel_hide_stock_body = BODY
    _G.making_fuel_hide_stock_running = true
    said_path, said_count, said_fixed = nil, nil, nil
    sync()
    repeatUtil.scheduleEvery(REPEAT_KEY, POLL_DAYS, 'days', sync)
    if not silent then
        log('DETAIL', 'active. Hide globs carry a Glob enumeration slot so'
            .. ' stockpiles can address them.', 'START')
    end
end

function stop()
    pcall(function() repeatUtil.cancel(REPEAT_KEY) end)
    _G.making_fuel_hide_stock_running = false
    -- Nothing is unwound. The enumeration is raws and is rebuilt from
    -- the mod files on the next load anyway; the settings vectors must
    -- not shrink, per the note at the top of this file.
    log('DETAIL', 'stopped. Registered slots left in place, deliberately.', 'STOP')
end

-- ==========================================
-- COMMAND: status
-- ==========================================
function status()
    local types, idxs = glob_vectors()
    if not types then return end
    local target = try(function() return #types end, 0)
    print(string.format('Glob enumeration length %d.', target))

    local mine = our_indices()
    for _, mi in ipairs(mine) do
        local info = try(function() return dfhack.matinfo.decode(0, mi) end)
        local pos = position_of(types, idxs, 0, mi)
        print(string.format('  %-40s inorganic %-5d  Glob slot %s',
            tostring(info and try(function() return info:getToken() end)),
            mi, pos and tostring(pos) or 'ABSENT'))
    end

    local bld = try(function() return df.global.world.buildings.all end)
    local nb = bld and try(function() return #bld end, 0) or 0
    for i = 0, nb - 1 do
        local b = try(function() return bld[i] end)
        if b and df.building_stockpilest:is_instance(b) then
            local len = try(function() return #b.settings.food.glob end)
            print(string.format('  stockpile %-6s food.glob len=%s%s',
                tostring(try(function() return b.id end)), tostring(len),
                (len and len > 0 and len < target) and '   SHORT' or ''))
        end
    end
end

-- ==========================================
-- CLI
-- ==========================================
if dfhack_flags and dfhack_flags.module then return end

local cmd = ...
if cmd == 'on' then start()
elseif cmd == 'off' then stop()
elseif cmd == 'sync' then sync()
elseif cmd == 'reverse' then reverse()
elseif cmd == 'status' then status()
else print('usage: making-fuel-hide-stock on | off | sync | status'
        .. ' | reverse') end