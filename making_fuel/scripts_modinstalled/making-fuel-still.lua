--@ module = true
-- making-fuel-still.lua
-- =====================================================================
-- MAKING FUEL: SPIRIT FROM BOOZE
-- =====================================================================
-- The still's "distil spirit from booze" (DISTIL_ETHANOL) takes a WHOLE
-- BARREL of booze and makes ONE vessel of spirit from it, the way the
-- retort burns a whole stack. Nobody wants a jug for every eight units.
--
-- ---------------------------------------------------------------------
-- WHY A WATCHER DOES IT
-- ---------------------------------------------------------------------
-- DF cannot say "however much is in the barrel". A reaction's product is
-- fixed when it is authored, and raising a reagent's quantity on a live
-- job deadlocks it (RM_Adaptive_Reactions.md, 2.3). So the reaction does
-- nothing by itself: its booze, barrel and vessel are all preserved, and
-- its one product is the module's watcher-owned placeholder, count 0 and
-- probability 0, which never mints and which the ghost leaves alone
-- (making-fuel-ghost.lua, derive_config: WATCHER OWNED IS NOT ADAPTIVE).
-- This file does the work at completion, the way the tank fill does:
--   1. the whole barrel empties: every drink item in it goes, however
--      many units they held, not only the one the reagent named;
--   2. the spirit is worked out: booze at wine strength, 12% alcohol,
--      distilled to 95%, so each unit of booze makes 12/95 of a unit;
--   3. the fraction this still carried from earlier barrels is added,
--      the whole units go into the vessel as ONE liquid item, and the
--      rest carries to this still's next barrel.
--
-- EACH STILL CARRIES ITS OWN, the way the ghost banks per furnace: two
-- stills never share one invisible fraction. The carry is saved with
-- the fort, and published at _G.making_fuel_spirit_carry for the bank
-- readout, which draws it on the still's sheet (see THE CARRY).
--
-- ---------------------------------------------------------------------
-- THE NUMBERS
-- ---------------------------------------------------------------------
-- Wine strength: a typical wine is 12 to 14% alcohol by volume and a
-- beer about 5%, and most dwarven drinks are wines, so 12%.
-- Spirit strength: ethanol and water form an azeotrope at 95.6% by mass,
-- so no distillation passes it. A pot still tops out at 60 to 80%; a
-- column still reaches 95%, which suits the module's industrial
-- chemistry. The fuel value of that 95% is in making-fuel-tank-fuel.lua's
-- energy table.
-- A barrel holds at most 100 units, which make 12.6 units of spirit,
-- under a jug's 16, so one barrel always fits one vessel.
--
-- ---------------------------------------------------------------------
-- FULL VESSELS, AND WHY THEY ARE SAFE HERE
-- ---------------------------------------------------------------------
-- The ghost's standing rule is ONE PACKAGE PER CONTAINER
-- (making-fuel-ghost.lua, VESSEL EXPANSION): a reaction takes the first
-- item meeting its requirements, so a container holding more than one
-- package breaks every consumer that meets it. Spirit is exempt ONLY
-- because its one consumer is the tank fill, which pours whatever a
-- vessel holds, measured on 16-unit jugs of tar. If any reaction ever
-- takes ETHANOL by class or by material, revisit this first.

local eventful   = require('plugins.eventful')
local repeatUtil = require('repeat-util')

local FAST_KEY  = 'making_fuel_still_fast'
local EVENT_KEY = 'making_fuel_still'

-- The witness rides a fast poll, well inside a distillation's working
-- time, the same cadence the tank fill's witness uses.
local FAST_FRAMES = 5

local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'STILL'

local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

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
-- SUBJECT is the correlation slot: the part of the system a line is
-- about (DISTIL, POUR, WITNESS). Job and building ids stay in the
-- body.
--
-- This replaces a log() that called rlog.emit, which refinish-log does
-- not have. Every line fell through to the untagged 'MAKING_FUEL STILL -'
-- form, and its DETAIL flag never took effect.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
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

-- Carries are fractional, and %d on a fraction is an error in Lua 5.3:
-- two decimals at most, trailing zeros dropped.
local function num(n)
    local s = string.format('%.2f', tonumber(n) or 0)
    s = s:gsub('0+$', '')
    s = s:gsub('%.$', '')
    return s
end


-- =====================================================================
-- CONSTANTS
-- =====================================================================
-- The reaction's code as the module registers it, its key under the
-- module's reaction prefix. Matched EXACTLY, never by substring:
-- "ETHANOL" is inside "METHANOL", so a loose match would also claim the
-- retort's methanol distillation.
local RXN_CODE  = 'MAKING_FUEL_RXN_DISTIL_ETHANOL'
local SPIRIT_ID = 'INORGANIC:MAKING_FUEL_ETHANOL'

-- See THE NUMBERS in the header.
local BOOZE_STRENGTH  = 0.12
local SPIRIT_STRENGTH = 0.95

-- One liquid unit. Every module liquid is authored at dimension 150, and
-- a drink unit is 150 too. MEASURED: dwarven wine [58] read stack 58,
-- dimension 150, in its barrel.
local UNIT_DIM = 150

-- Slack for floating point when taking whole units off the carry.
local EPSILON = 1e-9

-- The carries, saved with the fort under this key.
local CARRY_KEY = 'MAKING_FUEL_SPIRIT_CARRY'


-- =====================================================================
-- STATE
-- =====================================================================
-- [job id] = { drink = item id, box = item id, vessel = item id }
local witness = {}
-- [drink item id] = true once distilled. dfhack.items.remove defers its
-- collection, so a spent drink can outlive its job for a moment; this
-- keeps it from ever being witnessed twice.
local spent = {}

-- ---------------------------------------------------------------------
-- THE CARRY
-- ---------------------------------------------------------------------
-- [still building id] = spirit waiting for that still's next barrel, in
-- liquid units, always under one after a distillation pays out. The
-- bank readout holds this SAME table through _G.making_fuel_spirit_carry
-- and reads it every frame, so it is only ever refilled in place, never
-- replaced. Saved with string keys, because building ids are sparse and
-- a sparse integer table is not a safe shape for the save's json (the
-- tank table's rule, for the same reason).
local carry = {}

local function persist_carry()
    local out = {}
    for id, v in pairs(carry) do out[tostring(id)] = v end
    pcall(function() dfhack.persistent.saveSiteData(CARRY_KEY, out) end)
end

-- A still that no longer exists takes its carry with it, as a furnace's
-- bank goes with the furnace. Returns how many came back.
local function restore_carry()
    for k in pairs(carry) do carry[k] = nil end
    local saved = {}
    pcall(function()
        saved = dfhack.persistent.getSiteData(CARRY_KEY, {}) or {}
    end)
    local n, dropped = 0, 0
    for sid, v in pairs(saved) do
        local id = tonumber(sid)
        if id and df.building.find(id) then
            carry[id] = tonumber(v) or 0
            n = n + 1
        else
            dropped = dropped + 1
        end
    end
    if dropped > 0 then persist_carry() end
    return n
end


-- =====================================================================
-- READING A JOB
-- =====================================================================
local function is_distil(j)
    local code = nil
    pcall(function() code = tostring(j.reaction_name or '') end)
    return code == RXN_CODE
end

local function job_building(j)
    local b = nil
    pcall(function()
        for _, ref in ipairs(j.general_refs) do
            if ref._type == df.general_ref_building_holderst then
                b = df.building.find(ref.building_id)
            end
        end
    end)
    return b
end

-- "building 88 (Still)", for every log line that names the still. The
-- reaction exists only at stills, so the name is known.
local function where(b)
    if not b then return 'a still' end
    return string.format('building %d (Still)', b.id)
end

-- The drink's own name, "dwarven wine": its material's liquid state
-- name, the field tank-fuel and the ghost read for the same purpose.
local function drink_name(it)
    local n = nil
    pcall(function()
        local mi = dfhack.matinfo.decode(it)
        n = mi and mi.material and mi.material.state_name.Liquid or nil
    end)
    return n and tostring(n) or 'booze'
end

-- Units a drink item holds: its stack times its dimension over one unit.
local function units_of(it)
    local st, dm = 1, UNIT_DIM
    pcall(function() st = it.stack_size end)
    pcall(function() dm = it.dimension end)
    return (tonumber(st) or 1) * (tonumber(dm) or UNIT_DIM) / UNIT_DIM
end

local function contents(it)
    local out = {}
    pcall(function() out = dfhack.items.getContainedItems(it) or {} end)
    return out
end

-- The booze, its container and the vessel a distillation job holds. The
-- booze is the DRINK item, listed itself or inside its barrel. The
-- vessel is told apart from the booze's container by being EMPTY and not
-- that container, never by item type alone: a large pot is a TOOL too,
-- and can hold drink.
local function find_parts(j)
    local drink, box, vessel = nil, nil, nil
    pcall(function()
        for _, iref in ipairs(j.items) do
            local it = iref.item
            if it and not drink then
                if it:getType() == df.item_type.DRINK then
                    drink = it
                else
                    for _, c in ipairs(contents(it)) do
                        if not drink and c:getType() == df.item_type.DRINK then
                            drink = c
                        end
                    end
                end
            end
        end
        if drink then box = dfhack.items.getContainer(drink) end
        for _, iref in ipairs(j.items) do
            local it = iref.item
            if it and not vessel and it:getType() == df.item_type.TOOL
               and not (box and it.id == box.id)
               and #contents(it) == 0 then
                vessel = it
            end
        end
    end)
    if not drink then return nil end
    return { drink = drink.id, box = box and box.id or nil,
             vessel = vessel and vessel.id or nil }
end

-- Every drink in the barrel and the units they hold between them. With
-- no barrel on record, the witnessed drink alone.
local function barrel_drinks(w)
    local drinks, units = {}, 0
    local box = w.box and df.item.find(w.box) or nil
    if box then
        for _, c in ipairs(contents(box)) do
            if c:getType() == df.item_type.DRINK and not spent[c.id] then
                drinks[#drinks + 1] = c
            end
        end
    else
        local d = df.item.find(w.drink)
        if d and not spent[d.id] then drinks[1] = d end
    end
    for _, d in ipairs(drinks) do units = units + units_of(d) end
    return drinks, units
end


-- =====================================================================
-- MINTING THE SPIRIT
-- =====================================================================
-- The creating unit createItem requires: any citizen, as the hide chain
-- mints its globs. The item is moved into the vessel straight after, so
-- where it is created does not matter.
local function creator_unit()
    local u = nil
    pcall(function()
        local c = dfhack.units.getCitizens(true)
        if c and c[1] then u = c[1] end
    end)
    return u
end

-- One liquid item of spirit, `units` whole units, into the vessel, the
-- hide chain's proven createItem, setDimension, then place. Returns
-- true, or false and a reason. Nothing is ever left lying about: a
-- created item the vessel will not take is removed again.
local function mint(units, vessel)
    local mi = dfhack.matinfo.find(SPIRIT_ID)
    if not mi then return false, 'the ethanol material is not loaded' end
    local u = creator_unit()
    if not u then return false, 'no citizen to create it against' end
    local it = nil
    local ok = pcall(function()
        local made = dfhack.items.createItem(u, df.item_type.LIQUID_MISC, -1,
            mi.type, mi.index)
        it = made and made[1] or nil
    end)
    if not ok or not it then return false, 'createItem made nothing' end
    pcall(function() it:setDimension(units * UNIT_DIM) end)
    local placed = false
    pcall(function()
        placed = dfhack.items.moveToContainer(it, vessel) and true or false
    end)
    if not placed then
        pcall(dfhack.items.remove, it)
        return false, 'the vessel would not take it'
    end
    return true
end


-- =====================================================================
-- THE DISTILLATION
-- =====================================================================
-- The booze is spent FIRST and the spirit minted second. If minting then
-- fails, the whole amount goes to the carry, so a failure costs a
-- vessel's delay and never the booze.
local function distil_done(j)
    local w = witness[j.id] or find_parts(j)
    witness[j.id] = nil
    local b = job_building(j)
    if not w then
        log('WARNING', string.format('job %d at %s: distillation completed with no'
            .. ' booze witnessed; nothing distilled.', j.id, where(b)), 'DISTIL')
        return
    end

    -- The still this barrel is distilled in, whose carry it adds to. A
    -- job always has one; 0 is only a floor for the impossible case.
    local bid = b and b.id or 0
    local drinks, units = barrel_drinks(w)
    if units <= 0 then
        log('WARNING', string.format('job %d at %s: the barrel held no booze at'
            .. ' completion; nothing distilled.', j.id, where(b)), 'DISTIL')
        return
    end
    local name = drink_name(drinks[1])

    -- ---- THE WHOLE BARREL EMPTIES ----
    for _, d in ipairs(drinks) do
        spent[d.id] = true
        pcall(dfhack.items.remove, d)
    end

    -- ---- THE SPIRIT, AND WHAT CARRIES ----
    local spirit = units * BOOZE_STRENGTH / SPIRIT_STRENGTH + (carry[bid] or 0)
    local whole  = math.floor(spirit + EPSILON)
    local poured, why = 0, nil
    if whole >= 1 then
        local vessel = w.vessel and df.item.find(w.vessel) or nil
        if vessel then
            local ok, reason = mint(whole, vessel)
            if ok then poured = whole else why = reason end
        else
            why = 'no vessel was witnessed'
        end
    end
    carry[bid] = math.max(0, spirit - poured)
    persist_carry()

    if why then
        log('WARNING', string.format('job %d at %s: %s unit(s) of %s distilled, but'
            .. ' the spirit could not be poured (%s). All %s unit(s) are'
            .. ' carried to the next barrel.', j.id, where(b), num(units),
            name, why, num(carry[bid])), 'POUR')
        return
    end
    -- YIELD when ethanol was poured. INFO when the barrel only added to
    -- the carry, since nothing was made yet.
    log(poured > 0 and 'YIELD' or 'INFO', string.format('%s distilled %s unit(s) of %s into %d unit(s) of'
        .. ' ethanol for job %d, in vessel #%s; %s unit(s) carried to the'
        .. ' next barrel.', where(b), num(units), name, poured, j.id,
        tostring(w.vessel), num(carry[bid])), 'DISTIL')
end

local function on_completed(j)
    if is_distil(j) then distil_done(j) end
end


-- =====================================================================
-- THE WITNESS
-- =====================================================================
-- What a job carried may not be readable off j.items once it completes,
-- so the parts are recorded while it works, once all three are attached.
-- Witnesses for jobs that left the list without completing are dropped
-- in the same walk.
local function fast()
    local live = {}
    local l = df.global.world.jobs.list.next
    while l do
        local j = l.item
        if j then
            live[j.id] = true
            if not witness[j.id] and is_distil(j) then
                local n = 0
                pcall(function() n = #j.items end)
                if n > 0 then
                    local w = find_parts(j)
                    if w and w.vessel and not spent[w.drink] then
                        witness[j.id] = w
                        log('DETAIL', string.format('job %d at %s: witnessed booze #%d'
                            .. ' in barrel #%s, vessel #%d.', j.id,
                            where(job_building(j)), w.drink, tostring(w.box),
                            w.vessel), 'WITNESS')
                    end
                end
            end
        end
        l = l.next
    end
    for jid in pairs(witness) do
        if not live[jid] then witness[jid] = nil end
    end
end


-- =====================================================================
-- LIFECYCLE: CALLED BY making_fuel.lua
-- =====================================================================
function start()
    witness, spent = {}, {}
    local n = restore_carry()
    -- Published for the bank readout, after the restore so it never sees
    -- a half filled table. The same table object, always.
    _G.making_fuel_spirit_carry = carry
    eventful.onJobCompleted[EVENT_KEY] = function(j) pcall(on_completed, j) end
    eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)
    repeatUtil.scheduleEvery(FAST_KEY, FAST_FRAMES, 'frames', fast)
    log('DETAIL', string.format('active. %d still(s) carrying spirit from the save.', n), 'START')
end

function stop()
    -- First, so the readout stops drawing a carry nothing maintains.
    _G.making_fuel_spirit_carry = nil
    eventful.onJobCompleted[EVENT_KEY] = nil
    repeatUtil.cancel(FAST_KEY)
    log('DETAIL', 'stopped.', 'STOP')
end