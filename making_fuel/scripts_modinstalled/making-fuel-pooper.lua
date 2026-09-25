--@ module = true
-- making-fuel-pooper.lua
-- ==========================================
-- MAKING FUEL: DUNG SPAWNER
-- ==========================================
-- Grazing livestock drop dung where they stand. That is the
-- whole script. No labour, no workshop, no reaction: the fuel
-- source is already standing in a pasture.
--
-- One pass on a weekly poll: a tame adult grazer may drop one
-- dung. It is a dice roll rather than a timer, so nothing is
-- stamped and a reload mid-cycle just carries on from whatever
-- items are lying on the ground.
--
-- SAVE PROTOCOL NOTE
--
-- This script itself stores nothing. The ITEMS it makes are a
-- different matter: dung is now a tool carrying an injected
-- subtype, so every dung pile on the map goes through the same
-- wash and restore that every other injected tool does. That is
-- handled by refinish-tool-wash.lua, not here, but it means the
-- wash payload now carries up to MAX_DUNG records at save time
-- where it previously carried none from this source.
-- ==========================================

local repeatUtil = require('repeat-util')

local REPEAT_KEY = 'making_fuel_pooper'
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
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'POOPER'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)


-- ==========================================
-- TUNING
-- ==========================================
-- POOP_DAYS is the average gap between droppings for ONE animal.
--
-- Twenty is roughly twice a month, matched to how rarely dwarves
-- eat. DF does not simulate three meals a day because the
-- hauling would bury the game, and the same argument applies
-- here: an animal that poops realistically would bury the map in
-- items. Twice a month is plenty to make the source real.
--
-- The resulting economy, at eight dung to one charcoal:
--   10 grazers  ~1 charcoal every 16 days
--   30 grazers  ~1 charcoal every 5 days
--   50 grazers  ~1 charcoal every 3 days
--
-- POLL_DAYS is how often the check runs. IT IS NOT A COSMETIC
-- SETTING. One in game day is about twelve real seconds at 100
-- FPS, so a daily poll would walk every item in the fort five
-- times a minute. Weekly is 84 seconds apart and still gives
-- roughly three rolls per animal per POOP_DAYS window.
--
-- POLL_DAYS must stay below POOP_DAYS. Above it the per poll
-- chance clamps at 1 and every animal drops on every poll.
--
-- MAX_DUNG caps how many dung items may exist at once. THIS
-- MATTERS, and it matters more than it used to. A hundred
-- grazers with no cap would keep adding items forever and
-- quietly strangle the framerate, and every one of those items
-- is now a wash record at save time. At the cap the pass simply
-- does nothing.
-- ==========================================
-- POOP_DAYS AND MAX_DUNG ARE PLAYER SETTINGS NOW. Both live in
-- making-fuel-tuning's T, where the Making Fuel page of the RM HUD
-- writes each fort's choice over the shipped default, and both are read
-- once per poll, so a change lands on the next one. The reasoning above
-- is for the defaults. POLL_DAYS stays here: it is not a setting.
local POLL_DAYS = 3

-- Guarded like the log composer. Without the tuning file there is no
-- interval or cap, and the poll says so and drops nothing rather than
-- guess either.
local tuning = nil
pcall(function() tuning = reqscript('making-fuel-tuning') end)
local function poop_days()
    return tuning and tuning.T and tuning.T.POOP_DAYS
end
local function max_dung()
    return tuning and tuning.T and tuning.T.MAX_DUNG
end
local settings_missing_said = false

-- True once the cap line has been logged, so a fort sitting at the cap
-- hears about it once rather than on every poll. Cleared when the count
-- drops back below the cap, and by start().
local cap_logged = false


-- ==========================================
-- WHAT A DUNG PILE IS
-- ==========================================
-- A TOOL, made of the injected dung material.
--
-- The three item types this went through, and why it landed
-- here:
--
--   POWDER  spawns loose but cannot be HAULED loose. DF moves
--           powder into a bag, there is no bag step for
--           something lying in a field, and it sits where it
--           lands forever.
--
--   BLOCKS  hauls correctly and reads as a bare material name,
--           which is what powder was giving. But a block draws
--           whatever the material's stone graphics say and has
--           no itemdef of its own, so there is nowhere to hang
--           a sprite.
--
--   TOOL    has its own itemdef, so it can carry its own
--           sprite through the donor system in
--           refinish-tool-graphics.lua. NO_DEFAULT_JOB on that
--           itemdef keeps it out of the craftsdwarf's make-tool
--           menu, which otherwise would let a player mould dung
--           piles out of any material in the fort.
--
-- Tools are not dimension bearing, exactly as blocks were not,
-- so one dung item is one dung and reagent quantity on the
-- reaction counts ITEMS. Eight dung to one charcoal is a plain
-- quantity of 8, unchanged by this move.
--
-- Both halves are injected by the module, so neither exists
-- until Making Fuel has loaded.
-- ==========================================
local MAT_DUNG  = 'INORGANIC:MAKING_FUEL_DUNG'
local TOOL_DUNG = 'MAKING_FUEL_DUNG'

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
-- SUBJECT is the correlation slot: POLL, DROP and CAP for the poll,
-- CREATE for a single dung item, START and STOP. The prints in
-- census() answer a command typed at the console.
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
-- MATERIAL AND ITEMDEF LOOKUP
-- ==========================================
-- Both resolved fresh on every poll rather than cached.
--
-- Not because indices move at runtime; RM injects in a sorted,
-- deterministic order, so they do not. It is that two lookups a
-- week cost nothing, and it means the script keeps working if
-- anything is ever inserted ahead of DUNG in the module JSON
-- between versions. That second point is worth more now than it
-- was: adding one tool key re-sorts every tool that follows it
-- alphabetically, so DUNG's subtype is not a fixed number
-- across versions of the module.
-- ==========================================
local function find_mat()
    return dfhack.matinfo.find(MAT_DUNG)
end

local function find_tool()
    local defs = df.global.world.raws.itemdefs.tools
    for i, td in ipairs(defs) do
        local ok, id = pcall(function() return td.id end)
        if ok and id == TOOL_DUNG then
            -- The struct's own subtype field is what DF reads, so
            -- prefer it. It is the same number as the array
            -- position while injection is healthy; if the two ever
            -- disagree, the struct is the one that matters.
            local ok2, sub = pcall(function() return td.subtype end)
            if ok2 and type(sub) == 'number' and sub >= 0 then
                return sub
            end
            return i
        end
    end
    return nil
end


-- ==========================================
-- WHO POOPS
-- ==========================================
-- Tame adult grazers that are alive and on the map.
--
-- isGrazer is the right test rather than a hand written species
-- list: it reads the GRAZER token, so it picks up modded animals
-- and anything anyone adds without this file knowing about
-- them.
--
-- Babies are excluded because they are still nursing, and caged
-- animals because dung inside a cage cannot be hauled out.
-- ==========================================
local function is_pooper(unit)
    if not unit then return false end
    if not dfhack.units.isActive(unit) then return false end
    if not dfhack.units.isAlive(unit) then return false end
    if not dfhack.units.isTame(unit) then return false end
    if not dfhack.units.isAdult(unit) then return false end
    if not dfhack.units.isGrazer(unit) then return false end
    if unit.flags1.caged then return false end
    -- A unit being hauled or in a cage has no meaningful floor
    -- position to drop onto.
    if unit.pos.x < 0 then return false end
    return true
end


-- ==========================================
-- COUNTING WHAT IS ALREADY OUT THERE
-- ==========================================
-- Walks the tool items once and counts the dung, for the cap.
--
-- world.items.other.TOOL is a prebuilt index of just that item
-- type, far cheaper than walking every item in the fort. It is
-- read inside pcall because it is an optional index and falling
-- back to the full list is correct, only slower.
--
-- Three tests, cheapest first. Type and material are plain field
-- reads; the subtype goes through the accessor inside a pcall
-- because item_toolst.subtype may be stored as a pointer rather
-- than a number, so it is the expensive one and runs last.
-- refinish-ledger-tool.lua carries the full three way version of
-- that read if this one ever proves not enough.
-- ==========================================
local function count_dung(mat, subtype)
    local list
    local ok = pcall(function()
        list = df.global.world.items.other.TOOL
    end)
    if not ok or not list then list = df.global.world.items.all end

    local total = 0
    for _, item in ipairs(list) do
        if item:getType() == df.item_type.TOOL
           and item.mat_type == mat.type
           and item.mat_index == mat.index then
            local ok2, sub = pcall(function() return item:getSubtype() end)
            if ok2 and sub == subtype then
                total = total + 1
            end
        end
    end
    return total
end


-- ==========================================
-- POOP PASS
-- ==========================================
-- createItem returns a LIST of items, not one item, because the
-- underlying call can produce several. Indexing [1] without
-- checking would throw on failure rather than logging it.
--
-- The item is created against the unit, which drops it at the
-- unit's feet. moveToGround is called anyway as a safety net: if
-- the item ever lands in the animal's inventory instead of on
-- the floor it would be unreachable forever.
--
-- UNPROVEN, and the one thing here worth watching on the first
-- run: createItem has not been used with an injected tool
-- subtype in this module. making-fuel-branch-spawner.lua takes
-- the other road, modtools/create-item with -i TOOL:CODE, which
-- IS proven against an injected tool. If the log fills with
-- create failures, that is the swap to make.
-- ==========================================
local function drop_dung(unit, mat, subtype)
    local ok, made = pcall(function()
        return dfhack.items.createItem(unit, df.item_type.TOOL,
            subtype, mat.type, mat.index)
    end)

    if not ok or type(made) ~= 'table' or not made[1] then
        log('WARNING', 'create failed at unit ' .. tostring(unit.id)
            .. ': ' .. tostring(made), 'CREATE')
        return false
    end

    local item = made[1]

    -- No dimension write. Tools are discrete items with no
    -- dimension field, so one dung tool is simply one dung.

    pcall(function()
        dfhack.items.moveToGround(item,
            { x = unit.pos.x, y = unit.pos.y, z = unit.pos.z })
    end)
    return true
end

local function poop_pass(mat, subtype, total, poop, cap)
    -- Chance per animal per POLL. Scaled by how far apart the
    -- polls are, so changing POLL_DAYS retunes the frequency of
    -- the check without changing how often an animal poops.
    local chance = POLL_DAYS / poop
    if chance > 1 then chance = 1 end
    local dropped = 0

    for _, unit in ipairs(df.global.world.units.active) do
        -- Re-checked inside the loop rather than once at the top,
        -- because each drop raises the total and the cap has to
        -- hold within a single pass as well as across passes.
        if total + dropped >= cap then break end

        if is_pooper(unit) and math.random() < chance then
            if drop_dung(unit, mat, subtype) then dropped = dropped + 1 end
        end
    end

    return dropped
end


-- ==========================================
-- THE WEEKLY POLL
-- ==========================================
local function poll()
    if not dfhack.isMapLoaded() then return end
    -- Gated on RM being live because the dung material and the
    -- dung itemdef only exist while injected. Spawning against a
    -- washed material would produce a default rock rather than
    -- dung, and against a missing itemdef a cauldron.
    if not _G.refinish_active then return end

    local ok, err = pcall(function()
        -- The material is looked up on the FIRST POLL, not here.
        -- start() runs at the token call, before the engine injects
        -- anything, so INORGANIC:MAKING_FUEL_DUNG genuinely does not
        -- exist yet and this reported a fault for a module that was
        -- about to be perfectly fine. Every runtime path already
        -- resolves it after injection, which is why dung has kept
        -- working the whole time this line has been complaining.
        local mat = find_mat()
        if not mat then
            log('DETAIL', 'material not resolved yet, deferring to first poll.', 'POLL')
        end

        -- Same story as the material above: tools inject with the
        -- rest of the module, after this runs, so the itemdef is not
        -- there yet either. The poll resolves both.
        local subtype = find_tool()
        if not subtype then
            log('DETAIL', 'itemdef not resolved yet, deferring to first poll.', 'POLL')
            return
        end

        -- Read once per poll, so a change on the settings page lands
        -- whole on the next one.
        local poop, cap = poop_days(), max_dung()
        if not (poop and cap) then
            if not settings_missing_said then
                settings_missing_said = true
                -- ERROR: no dung drops until this is fixed.
                log('ERROR', 'no POOP_DAYS or MAX_DUNG in making-fuel-tuning, so'
                    .. ' no dung drops. Check that the tuning file loads.', 'POLL')
            end
            return
        end

        local total   = count_dung(mat, subtype)
        local dropped = poop_pass(mat, subtype, total, poop, cap)

        if dropped > 0 then
            -- DETAIL, not YIELD: an ambient tally on every poll, about every 36
            -- real seconds, rather than a job the player ordered. At Normal it
            -- would drown everything else.
            log('DETAIL', string.format('%d pooped, %d dung on map.',
                dropped, total + dropped), 'DROP')
        end

        if total + dropped >= cap then
            -- INFO, once per time the cap is reached: it answers why no
            -- more dung is appearing.
            if not cap_logged then
                cap_logged = true
                log('INFO', 'dung cap reached (' .. cap
                    .. '). No more will drop until some is used.', 'CAP')
            end
        else
            cap_logged = false
        end
    end)

    if not ok then log('ERROR', 'POLL ERROR: ' .. tostring(err), 'POLL') end
end


-- ==========================================
-- DEBUG READOUT
-- ==========================================
--   :lua reqscript('making-fuel-pooper').census()
-- ==========================================
function census()
    if not dfhack.isMapLoaded() then
        print('Pooper: no map loaded.')
        return
    end

    local mat = find_mat()
    if not mat then
        print('Pooper: dung material not injected.')
        return
    end

    local subtype = find_tool()
    if not subtype then
        print('Pooper: dung itemdef not injected.')
        return
    end

    local total = count_dung(mat, subtype)
    local poop, cap = poop_days(), max_dung()
    if not (poop and cap) then
        print('Pooper: no POOP_DAYS or MAX_DUNG in making-fuel-tuning.')
        return
    end

    local grazers = 0
    for _, unit in ipairs(df.global.world.units.active) do
        if is_pooper(unit) then grazers = grazers + 1 end
    end

    print(string.format('Pooper: %d eligible grazer(s)', grazers))
    print(string.format('  dung itemdef at subtype %d', subtype))
    print(string.format('  %d dung on map (cap %d)', total, cap))
    print(string.format('  ~%.2f dung/day, ~%.1f days per charcoal',
        grazers / poop,
        grazers > 0 and (8 * poop / grazers) or 0))
end

-- ==========================================
-- LIFECYCLE
-- ==========================================
-- One poll per POLL_DAYS in game days. Nothing here needs to be
-- responsive, and at weekly the item walk lands about once every
-- 84 real seconds at 100 FPS.
-- ==========================================
function start()
    cap_logged = false
    repeatUtil.scheduleEvery(REPEAT_KEY, POLL_DAYS, 'days', poll)
    log('DETAIL', 'active. watching pastures.', 'START')
end

function stop()
    repeatUtil.cancel(REPEAT_KEY)
    log('DETAIL', 'terminated.', 'STOP')
end

return _ENV