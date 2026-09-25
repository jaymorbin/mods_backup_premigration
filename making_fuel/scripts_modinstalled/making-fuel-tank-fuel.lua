--@ module = true
-- making-fuel-tank-fuel.lua
-- =====================================================================
-- MAKING FUEL: LIQUID FUEL TANKS
-- =====================================================================
-- A furnace with a burner installed and charge in its tank runs its
-- jobs without solid fuel, paying the tank instead.
--
-- THIS FILE OWNS THE TANK, THE FILL AND THE FIT: the numbers, the
-- reservations, the outfitting rule, and the fill and fit reactions.
-- It does NOT own the job
-- cycle. making-fuel-access.lua owns the fuel filter on a live job and
-- the per cycle bookkeeping, and calls reserve_job, settle_job and
-- release_job below.
--
-- ---------------------------------------------------------------------
-- WHAT SURVIVES A SAVE
-- ---------------------------------------------------------------------
-- The CHARGE, under the site data key CHARGE_KEY, written through on
-- every change: install, uninstall, fill, and every settled debit. Site
-- data is held in memory and DF writes it with the save, so whatever
-- protocol takes the save, it carries the current charge. Restored in
-- start(), before making-fuel-access.lua starts and re-adopts its jobs
-- against it.
--
-- NOT the reservations. They are rebuilt on every start: this file
-- clears them, and access.lua reserves again as it re-adopts, after
-- judging any verdict a save caught mid retry. A reservation was never
-- a debit, so the persisted charge is exact without them.
--
-- The job side (which jobs the tank owns, and each one's fuel slot) is
-- persisted by access.lua under its own key, because that file owns
-- the job.
--
-- ---------------------------------------------------------------------
-- HOW access.lua REACHES THIS FILE
-- ---------------------------------------------------------------------
-- Through _G.making_fuel_tank_api, published in start() and cleared in
-- stop(). NOT reqscript: about 2 ms a call (engine notes), and access
-- asks on every job on every 5 frame poll. A cleared table is also what
-- stops the waiver the moment this file stops.
--
-- ---------------------------------------------------------------------
-- HOW MUCH A TANK HOLDS
-- ---------------------------------------------------------------------
-- The tank is cauldron sized, so it holds what a cauldron holds, read
-- off the vanilla cauldron's itemdef at run time: 166 liquid units (see
-- capacity() for the arithmetic and where it was measured).
--
-- Capacity is a VOLUME, and charge is not one: each fuel carries its
-- own energy per unit (see WHAT EACH FUEL IS WORTH), so the same charge
-- can fill very different volumes. So each tank carries VOLUME beside
-- its charge. A fill adds both. A job burns its charge from the tank as
-- a MIXTURE, so volume falls in the same proportion as charge: no
-- arbitrary rule about which fuel burns first.
--
-- ---------------------------------------------------------------------
-- THE ATOMISER
-- ---------------------------------------------------------------------
-- A bare burner burns light fuel only. Heavy fuel is too thick for it:
-- it has to be preheated before it flows and sprayed before it burns
-- cleanly, and that is what a fuel atomiser adds, fitted to a furnace
-- that already has a burner, as a second permanent part. With one,
-- the furnace takes both grades, heavy first. This is the hardware
-- rule, and it replaced a smith tier rule for liquids that had no
-- physical basis: every liquid fuel reaches smithing heat once it burns
-- properly, so what a furnace can use depends on its fit-out, not on
-- what it is for. See set_fill_mode and THE ATOMISER MUST STILL BE
-- THERE.
--
-- A fill pours WHAT FITS. The fill reagent is preserved, so DF consumes
-- nothing and fill_done is the only thing that ever takes liquid out of
-- a vessel: all of it when it all fits, otherwise just the room, with
-- the rest left in the vessel through DF's own setDimension. A tank with
-- no room for even one unit offers no fill, and a fill job waiting at a
-- full tank is cancelled. See POUR WHAT FITS and A FULL TANK CANCELS
-- ITS FILLS.
--
-- ---------------------------------------------------------------------
-- WHO MAY CARRY A TANK
-- ---------------------------------------------------------------------
-- Every furnace except the wood furnace, the retort and the magma
-- furnaces. The wood furnace and the retort burn no fuel, and a magma
-- furnace burns magma. install() refuses those by name.
--
-- ---------------------------------------------------------------------
-- RESERVE AT POSTING, PAY AT THE BURN
-- ---------------------------------------------------------------------
-- The tank used to be debited when the fuel slot was erased, at
-- posting. MEASURED wrong, job 7192: the debit landed the instant the
-- job posted, long before anything burned, so a job cancelled after
-- posting had emptied the tank for nothing.
--
-- So posting RESERVES, and the end of the cycle settles. access.lua
-- finds the end of a cycle the way its own surcharge does (held
-- something, holds nothing now) and judges it with the ghost's burn
-- test. Consumed settles, which is the debit. Untouched releases, which
-- hands the units back.
--
-- has_charge reads what is AVAILABLE, the charge less every open
-- reservation, so two jobs posted together can never both spend the
-- last whole job's worth.
--
-- Reservations are keyed '<job id>:<cycle>', not by job id. A repeat
-- job keeps its id forever, and one cycle's verdict can still be out
-- when the next cycle reserves.
--
-- ---------------------------------------------------------------------
-- WHY THE WAIVER LIVES IN making-fuel-access.lua
-- ---------------------------------------------------------------------
-- The first version cloned the job's reaction with flags.FUEL cleared.
-- MEASURED, job 7252: the swap logged and the dwarf still fetched four
-- fuel bars. DF builds a job's filter list from the BASE reaction at
-- job creation, so a swap changes what a job PRODUCES and nothing about
-- what it COLLECTS. The waiver is an erase of the fuel slot, done where
-- that vector is owned. MEASURED WORKING, jobs 7177 and 7251.
--
-- ---------------------------------------------------------------------
-- THE FILL IS MEASURED, NOT COUNTED
-- ---------------------------------------------------------------------
-- A whole vessel goes in. Whatever it holds is measured, credited, and
-- destroyed, and the vessel walks back out empty. Both reagents are
-- declared preserve, so DF consumes nothing and this file is the only
-- thing that touches the liquid. The pitch chain's shape, copied: the
-- ghost reads tar out of its jug with getContainedItems and witnesses
-- it by id.
--
-- Witnessed during the job, because at completion the liquid can be
-- gone. MEASURED, jobs 7175 and 7190 under the first version: both
-- completed with no graded liquid. And classes are read with .value:
-- tostring on a reaction_class entry is an ADDRESS, not the text
-- (access.lua says so above rc_value, which is copied here).
--
-- MEASURED WORKING, job 7175: liquid #6616 witnessed at dimension 2400,
-- 16 units credited, the jug returned empty. 100% of a vessel is one
-- unit, 150 dimension.
--
-- REMOVE IS DEFERRED (making-fuel-cremate-watcher.lua): a removed item
-- can still be found for several polls, so credited keys on the
-- liquid's id and a lingering item is never paid twice.
--
-- ---------------------------------------------------------------------
-- FITTING THE BURNER
-- ---------------------------------------------------------------------
-- A tankable furnace without a tank shows "fit fuel burner". The job
-- takes a burner, preserved, and on completion the burner is moved into
-- the furnace with dfhack.items.moveToBuilding as a PERMANENT part,
-- which Lua_API describes as "treated as part of the building", the way
-- a mechanism sits in a lever. Only then does the tank open, recording
-- the burner's id. From then on that furnace shows the fill instead.
--
-- The slow poll checks the burner is still there by identity and
-- location, never by type: see THE BURNER MUST STILL BE THERE.
--
-- ---------------------------------------------------------------------
-- THE FILL AND THE FIT: ONE CLONE PER BUILDING
-- ---------------------------------------------------------------------
-- Visibility is the building field and ONLY that: four parallel
-- vectors, all empty means no menu anywhere. Only one sheet is open at
-- a time, so the open building's clone gets the field and every other
-- clone gets nothing. Values are read off the LIVE building, which is
-- why this works on any furnace without naming a building type.
-- MEASURED WORKING: "fill clone cut for building 6".
--
-- CLONES ARE HELD BY CODE, NEVER AS OBJECTS. The engine DELETES swept
-- reactions (refinish-module-engine.lua:1267) in the shutdown sequence,
-- which runs before the save, while this file keeps running until
-- after SC_MAP_UNLOADED. The first version held the objects, so for
-- that whole window it held freed memory, and wrote building fields
-- into it: from view() if the selection changed mid save, and from
-- stop() on EVERY save. Now every write resolves its clones by code
-- prefix in one walk of the live array, so a swept clone is simply not
-- found. drain-key holds its clones the same way this file used to.
--
-- Clones are registered with ghost.register_alias and RE-ASSERTED
-- EVERY SLOW POLL, because the ghost rebuilds JIT_CONFIG and AUTHORED
-- in its own start(). No cleanup code for clones: the engine sweeps by
-- prefix (refinish-module-engine.lua:1203), and a stop() that popped
-- them would be a double free.
-- =====================================================================

local eventful   = require('plugins.eventful')
local repeatUtil = require('repeat-util')

local FAST_KEY  = 'making_fuel_tank_fuel_fast'
local SLOW_KEY  = 'making_fuel_tank_fuel_slow'
local EVENT_KEY = 'making_fuel_tank_fuel'

-- Same cadences drain-key runs. The fill witness rides the fast poll,
-- which is well inside a fill job's working time.
local FAST_FRAMES = 5
local SLOW_FRAMES = 100

-- Slow polls a reservation may sit with its job gone before this file
-- releases it on its own. access.lua settles or releases within ten
-- frames of a job leaving, so this only ever fires if access is not
-- running: it is a backstop, not the mechanism.
local ORPHAN_POLLS = 3

local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'TANK_FUEL'

local rlog, tuning, ghost = nil, nil, nil
pcall(function() rlog   = reqscript('refinish-log') end)
pcall(function() tuning = reqscript('making-fuel-tuning') end)
pcall(function() ghost  = reqscript('making-fuel-ghost') end)

local function T()
    if tuning and tuning.get then return tuning.get() end
    return {}
end

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
-- about (FILL, BURNER, ATOMISER, TANK, RESERVE, CLONE, WITNESS). Job
-- and building ids stay in the body.
--
-- This replaces a log() that called rlog.emit, which refinish-log does
-- not have. Every line fell through to the untagged 'MAKING_FUEL TANK_FUEL -'
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

-- Charge is fractional now (see WHAT EACH FUEL IS WORTH), and %d on a
-- fraction is an error in Lua 5.3, so charge figures in the log go
-- through this: two decimals at most, trailing zeros dropped.
local function num(n)
    local s = string.format('%.2f', tonumber(n) or 0)
    s = s:gsub('0+$', '')
    s = s:gsub('%.$', '')
    return s
end

local RXN_PREFIX = 'MAKING_FUEL_RXN_'

-- The invisible base the fill clones are cut from. Declared with
-- building NONE, so it is orderable nowhere and exists only to be
-- copied.
local BASE_FILL = RXN_PREFIX .. 'FILL_TANK'

-- The invisible base the fit clones are cut from, declared the same way.
local BASE_INSTALL = RXN_PREFIX .. 'INSTALL_BURNER'

-- The invisible base the atomiser fit clones are cut from.
local BASE_ATOMISE = RXN_PREFIX .. 'INSTALL_ATOMISER'

-- Per building clone codes are these plus the building id. Every clone
-- this file owns starts with one of the three, which is how show_only
-- finds them in the live array.
local FILL_PREFIX    = BASE_FILL .. '_B'
local INSTALL_PREFIX = BASE_INSTALL .. '_B'
local ATOMISE_PREFIX = BASE_ATOMISE .. '_B'

-- The itemdef ids of the two fitted parts, for recognising one among a
-- job's items.
local BURNER_ID   = 'MAKING_FUEL_BURNER'
local ATOMISER_ID = 'MAKING_FUEL_ATOMISER'

-- The fill's liquid classes. FUEL_LIQUID is the union both grades
-- carry; each grade class names one grade alone.
local CLASS_ANY   = 'FUEL_LIQUID'
local CLASS_HEAVY = 'FUEL_LIQUID_HEAVY'
local CLASS_LIGHT = 'FUEL_LIQUID_LIGHT'

-- The fill reagent's code. DF's requirement line read "Fuel-containing
-- item" while the code was "fuel", and nothing else in the reaction
-- spells it that way, so the code is taken to be what DF prints there.
-- That is an inference: if renaming it does not change the line, the
-- text comes from elsewhere.
--
-- Applied at RUN TIME to every fill clone, never in the JSON: RM's
-- validator refuses a code with a space, and DF accepts one (vanilla's
-- own "lye container", "oil container" and "tool stone", the last also
-- named by a product). The base keeps "fuel". MEASURED since: the
-- rename did change the line, to "Liquid fuel-containing item". Each
-- fill clone says what its furnace can burn (see set_fill_mode).
local CODE_ANY   = 'liquid fuel'
local CODE_LIGHT = 'light liquid fuel'

-- The fill's two descriptions, one per fit-out, written onto each fill
-- clone as fresh objects by set_fill_mode. DF renders descriptions under
-- the Produces/Requires block, one entry per paragraph
-- (refinish-module-react.lua, step 3c).
local LIGHT_TEXT = {
    "Pours a vessel of light liquid fuel, such as kerosene, into this"
        .. " furnace's tank, as much as the tank has room for. Whatever"
        .. " does not fit stays in the vessel, and a fill waiting at a"
        .. " full tank is cancelled.",
    "Heavy fuels such as tar are too thick for a bare burner: fit a fuel"
        .. " atomiser to this furnace to burn them. Each fuel is worth its"
        .. " energy: most fill about one job per unit, the alcohols about"
        .. " half of one.",
}
local ATOMISED_TEXT = {
    "Pours a vessel of liquid fuel into this furnace's tank, as much as"
        .. " the tank has room for. Whatever does not fit stays in the"
        .. " vessel, and a fill waiting at a full tank is cancelled.",
    "With an atomiser fitted, heavy fuel such as tar is taken first, and"
        .. " light fuel such as kerosene only when no heavy fuel is to hand."
        .. " Each fuel is worth its energy: most fill about one job per"
        .. " unit, the alcohols about half of one.",
}

-- One unit of liquid. Every liquid product in the module is authored
-- at dimension 150, and 100% of a vessel reads as exactly one of these.
local UNIT_DIM = 150

-- The cauldron, whose capacity a tank takes, and the internal capacity
-- one liquid unit costs. VOLUME_PER_UNIT is mirrored from
-- making-fuel-ghost.lua:1466, where it is a DF constant MEASURED three
-- ways: a bone oil package in a jug reads volume 60; the wiki's 600 per
-- unit at raws scale, over the ten DF divides raws by on load; and
-- dimension 2400 written into a jug of capacity 1000 landing as exactly
-- sixteen units. The fallback is the cauldron's own figure, used only if
-- the itemdef cannot be read.
local VOLUME_PER_UNIT   = 60
local CAULDRON_ID       = 'ITEM_TOOL_CAULDRON'
local CAULDRON_FALLBACK = 10000


-- =====================================================================
-- NUMBERS, ALL DERIVED
-- =====================================================================
-- FUEL_BULK_PER_SMELTING is 4 because the whole fuel tree is base
-- four, and it is the cost of one job in tank charge.
local function per_smelting() return tonumber(T().FUEL_BULK_PER_SMELTING) or 4 end
local function units_per_job() return per_smelting() end

-- ---- WHAT EACH FUEL IS WORTH: ITS ENERGY PER LITRE ----
-- A tank unit is a unit of VOLUME, so a fuel's worth is the heat in that
-- volume. Kerosene is the anchor, one unit worth exactly one job, and
-- every other fuel's charge per unit is
--     units_per_job() * (its MJ per litre) / (kerosene's MJ per litre)
-- which makes charge fractional. It replaced a flat rule, light four and
-- heavy one, that had no physical basis: per litre the heavy fuels hold
-- as much heat as the light ones or more. What the grades still decide
-- is HANDLING, which furnace hardware can burn them.
--
-- Higher heating values throughout, times the REAL density, which is not
-- always the module's. Every figure is sourced; ANALOGUE marks a fuel
-- measured through its nearest documented relative.
local FUEL_MJ_PER_L = {
    -- light
    MAKING_FUEL_KEROSENE   = 36.96, -- 46.2 MJ/kg at 0.80 (Wikipedia, Kerosene)
    MAKING_FUEL_TURPENTINE = 38.10, -- 44.0 MJ/kg at 0.865 (Engineering ToolBox)
    MAKING_FUEL_BENZENE    = 36.23, -- coke-oven light oil, 130,000 Btu/gal
                                    -- (US Minerals Yearbook 1962); NIST's
                                    -- -3267.6 kJ/mol agrees
    MAKING_FUEL_NAPHTHA    = 34.90, -- 48.1 MJ/kg at 0.725 (Engineering ToolBox)
    MAKING_FUEL_ETHANOL    = 22.23, -- rectified spirit, 95% ethanol by
                                    -- volume: the most distillation can
                                    -- give, since ethanol and water form
                                    -- an azeotrope at 95.6% by mass.
                                    -- Pure ethanol is 1366.91 kJ/mol over
                                    -- 46.07 g/mol, 29.66 MJ/kg, at 0.789,
                                    -- so 23.40 MJ/L, and 95% of it 22.23
    MAKING_FUEL_METHANOL   = 17.94, -- 725.7 kJ/mol over 32.04 g/mol is
                                    -- 22.65 MJ/kg, at 0.792
    -- heavy
    MAKING_FUEL_TAR_COAL   = 41.81, -- coke-oven tar, 150,000 Btu/gal
                                    -- (US Minerals Yearbook 1962)
    MAKING_FUEL_OIL_CRUDE  = 38.56, -- 45.543 MJ/kg at 0.847 (GREET)
    MAKING_FUEL_OIL_LUBRICANT   = 36.87, -- 41.9 MJ/kg, waste distilled engine
                                    -- oil, at 0.88
    MAKING_FUEL_OIL_TALLOW = 34.65, -- 38.5 MJ/kg, the middle of 35 to 42
                                    -- across two sources, at 0.90
    MAKING_FUEL_OIL_BONE   = 31.46, -- ANALOGUE: meat-and-bone-meal pyrolysis
                                    -- oil, 34.2 MJ/kg, at 0.92
    MAKING_FUEL_CREOSOTE   = 31.25, -- 12,500 Btu/lb is 29.07 MJ/kg (NOAA
                                    -- CAMEO Chemicals), at 1.075
    MAKING_FUEL_TAR        = 30.24, -- 28.8 MJ/kg, birch pyrolytic tar oils,
                                    -- at 1.05
}
local KEROSENE_MJ_PER_L = FUEL_MJ_PER_L.MAKING_FUEL_KEROSENE

-- The old grade rule, kept ONLY as the fallback for a material carrying
-- a fuel class that the table above does not know yet. charge_per_unit
-- says so out loud, once per material, so the gap gets filled.
local function units_for(grade)
    if grade == 'LIGHT' then return per_smelting() end
    return 1
end

-- The charge one unit of this liquid is worth. grade is what
-- grade_of_liquid read, and nil means the liquid is not a fuel.
local warned_energy = {}
local function charge_per_unit(liq, grade)
    if not grade then return nil end
    local id = nil
    pcall(function()
        local mi = dfhack.matinfo.decode(liq)
        id = mi and mi.inorganic and mi.inorganic.id or nil
    end)
    local mjl = id and FUEL_MJ_PER_L[id]
    if mjl then return units_per_job() * mjl / KEROSENE_MJ_PER_L end
    local key = id or '?'
    if not warned_energy[key] then
        warned_energy[key] = true
        log('WARNING', string.format('fuel %s has no energy entry; charged by its'
            .. ' grade until it gets one.', key), 'ENERGY')
    end
    return units_for(grade)
end

-- Buildings that may never carry a tank. Names as building_name gives
-- them: the vanilla enum names, and the custom def code for the retort.
local NO_TANK = {
    WoodFurnace       = true,
    MagmaSmelter      = true,
    MagmaGlassFurnace = true,
    MagmaKiln         = true,
    MagmaForge        = true,
    MAKING_FUEL_RETORT = true,
}


-- =====================================================================
-- TANK STATE
-- =====================================================================
-- [building id] = { units = n, burner = item id }
-- [reservation key] = { bld = building id, cost = n, gone = polls }
--
-- Both published on _G so the readout and the console read them
-- without a reqscript on a per frame path, and so a reload of this
-- script mid session keeps what it had promised.
_G.making_fuel_tanks        = _G.making_fuel_tanks or {}
_G.making_fuel_tank_holds   = _G.making_fuel_tank_holds or {}
local tanks    = _G.making_fuel_tanks
local reserved = _G.making_fuel_tank_holds

-- The charge, and only the charge. [building id as a string] = { units,
-- burner }. String keys, because building ids are sparse and a sparse
-- integer table is not a safe shape for the save's json.
local CHARGE_KEY = 'MAKING_FUEL_TANKS'

local function persist_charge()
    local out = {}
    for id, t in pairs(tanks) do
        out[tostring(id)] = { units = t.units or 0, volume = t.volume or 0,
                              burner = t.burner, atomiser = t.atomiser }
    end
    pcall(function() dfhack.persistent.saveSiteData(CHARGE_KEY, out) end)
end

-- Refills the SAME table rather than replacing it, so _G and the bank
-- readout, which hold it by reference, keep seeing the live one. A tank
-- whose building is gone is dropped, and the drop is written back.
local function restore_charge()
    for k in pairs(tanks) do tanks[k] = nil end
    local saved = {}
    pcall(function()
        saved = dfhack.persistent.getSiteData(CHARGE_KEY, {}) or {}
    end)
    local kept_n, dropped = 0, 0
    for sid, v in pairs(saved) do
        local id = tonumber(sid)
        if id and type(v) == 'table' and df.building.find(id) then
            -- A record saved before volume existed is read as though
            -- every unit were heavy, one volume per charge. That can only
            -- overstate how full it is, never understate it, so an old
            -- tank refuses a fill early rather than overflowing, and the
            -- figure corrects itself as the tank burns down.
            local units = tonumber(v.units) or 0
            tanks[id] = { units = units,
                          volume = tonumber(v.volume) or units,
                          burner = v.burner,
                          atomiser = tonumber(v.atomiser) }
            kept_n = kept_n + 1
        else
            dropped = dropped + 1
        end
    end
    if dropped > 0 then persist_charge() end
    return kept_n, dropped
end

-- One name for any building, vanilla or custom. The building's CLASS
-- picks the enum, or a workshop entry silently captures a furnace.
local function building_name(b)
    local name = nil
    pcall(function()
        local cls = b:getType()
        if cls == df.building_type.Furnace then
            if b.type == df.furnace_type.Custom then
                name = df.global.world.raws.buildings.all[b.custom_type].code
            else
                name = tostring(df.furnace_type[b.type])
            end
        elseif cls == df.building_type.Workshop then
            if b.type == df.workshop_type.Custom then
                name = df.global.world.raws.buildings.all[b.custom_type].code
            else
                name = tostring(df.workshop_type[b.type])
            end
        end
    end)
    return name
end

-- "building 26 (Kiln)", for every log line that names a furnace.
local function where(b)
    if not b then return 'an unknown building' end
    return string.format('building %d (%s)', b.id,
        tostring(building_name(b) or '?'))
end

function charge_of(bld_id)
    local t = tanks[bld_id]
    return t and t.units or 0
end

-- Units promised to jobs at this building that have not burned yet.
-- A handful of entries at most, so a walk is cheaper than a counter
-- that could drift out of step with the table it summarises.
function reserved_for(bld_id)
    local n = 0
    for _, r in pairs(reserved) do
        if r.bld == bld_id then n = n + (r.cost or 0) end
    end
    return n
end

function available(bld_id)
    return charge_of(bld_id) - reserved_for(bld_id)
end

-- The question making-fuel-access.lua asks on every job posting. It
-- reads AVAILABLE, so a charge already promised to a running job is
-- never offered to a second one.
function has_charge(bld_id)
    return available(bld_id) >= units_per_job()
end

-- Opens the tank. The caller does the PERM move, so the installed item
-- stays the single source of truth for whether a burner is fitted and
-- this table only carries charge.
function install(bld_id, item_id)
    local b = df.building.find(bld_id)
    if not b then
        log('WARNING', string.format('install refused: no building %s.', tostring(bld_id)), 'BURNER')
        return false
    end
    local name = building_name(b)
    if name and NO_TANK[name] then
        log('WARNING', string.format('install refused: building %d is a %s, which'
            .. ' cannot carry a fuel tank.', bld_id, name), 'BURNER')
        return false
    end
    tanks[bld_id] = tanks[bld_id] or { units = 0, volume = 0 }
    tanks[bld_id].burner = item_id
    persist_charge()
    log('INFO', string.format('burner installed in building %d (%s).',
        bld_id, tostring(name or '?')), 'BURNER')
    return true
end

function uninstall(bld_id)
    local t = tanks[bld_id]
    if t then
        log('INFO', string.format('burner removed from building %d, %s unit(s) lost.',
            bld_id, num(t.units)), 'TANK')
    end
    tanks[bld_id] = nil
    for k, r in pairs(reserved) do
        if r.bld == bld_id then reserved[k] = nil end
    end
    persist_charge()
end

-- amount is in LIQUID units: whole multiples of UNIT_DIM. Returns tank
-- units added, or nil plus a reason the caller can act on.
-- Whole liquid units a tank holds. The cauldron's container_capacity
-- is the INTERNAL figure, the raws value over ten, so its
-- [CONTAINER_CAPACITY:100000] reads 10000 here, and 10000 over 60 is 166
-- whole units. Read once per session; the cauldron is vanilla, so it is
-- present from the raws before anything is injected.
local cap_units = nil

function capacity()
    if cap_units then return cap_units end
    local cap = nil
    pcall(function()
        for _, td in ipairs(df.global.world.raws.itemdefs.tools) do
            if td.id == CAULDRON_ID then cap = td.container_capacity end
        end
    end)
    if not cap or cap <= 0 then cap = CAULDRON_FALLBACK end
    cap_units = math.floor(cap / VOLUME_PER_UNIT)
    return cap_units
end

function volume_of(bld_id)
    local t = tanks[bld_id]
    return t and (t.volume or 0) or 0
end

function room_of(bld_id)
    return capacity() - volume_of(bld_id)
end

-- per_unit is the charge one unit of this liquid is worth, from
-- charge_per_unit. what names the fuel and job_id the fill job, for the
-- log. A console call may leave all three out: the charge then falls
-- back to the grade rule and the line names the grade.
function fill(bld_id, grade, amount, per_unit, what, job_id)
    amount = amount or 1
    local b = df.building.find(bld_id)
    if not b then return nil, 'no such building' end
    local t = tanks[bld_id]
    if not t then return nil, 'no burner installed' end
    -- The hardware gate lives here and nowhere else: heavy fuel needs an
    -- atomiser (see THE ATOMISER in the header).
    if grade == 'HEAVY' and not t.atomiser then
        return nil, 'heavy fuel needs an atomiser, and this burner has none'
    end
    -- The capacity gate. A vessel whose whole contents do not fit is
    -- refused whole, so it comes back full rather than half poured.
    local room = math.floor(capacity() - (t.volume or 0))
    if amount > room then
        return nil, string.format('the tank has room for %d unit(s) and'
            .. ' the vessel holds %d', math.max(0, room), amount)
    end
    local each = per_unit or units_for(grade)
    local add  = each * amount
    t.units  = (t.units or 0) + add
    t.volume = (t.volume or 0) + amount
    persist_charge()
    -- What went in, where, for which job, and what it was worth.
    log('INFO', string.format('%s took %d unit(s) of %s%s: %s grade, %s charge each,'
        .. ' %s in all; tank now %s charge, %d of %d volume.', where(b),
        amount, tostring(what or grade), job_id and (' for job ' .. job_id) or '',
        string.lower(tostring(grade)), num(each), num(add), num(t.units),
        math.floor(t.volume + 0.5), capacity()), 'FILL')
    return add
end


-- =====================================================================
-- RESERVATIONS: CALLED BY making-fuel-access.lua
-- =====================================================================
-- key is '<job id>:<cycle>'. Returns true when a whole job's worth was
-- available and is now held for that cycle.
function reserve_job(bld_id, key)
    if reserved[key] then return true end
    if not tanks[bld_id] then return false end
    local cost = units_per_job()
    if available(bld_id) < cost then return false end
    reserved[key] = { bld = bld_id, cost = cost, gone = 0 }
    log('DETAIL', string.format('building %d reserved %d unit(s) for %s, %s still'
        .. ' free.', bld_id, cost, key, num(available(bld_id))), 'RESERVE')
    return true
end

-- The cycle burned: the reservation becomes the debit. Idempotent, so
-- a verdict that lands twice charges once.
function settle_job(key)
    local r = reserved[key]
    if not r then return false end
    reserved[key] = nil
    local t = tanks[r.bld]
    if not t then return false end
    -- The tank is a mixture, so the job burns its charge from the whole
    -- contents and volume falls in the same proportion.
    local before = t.units or 0
    t.units = math.max(0, before - r.cost)
    if before > 0 then
        t.volume = math.max(0, (t.volume or 0) * (t.units / before))
    else
        t.volume = 0
    end
    persist_charge()
    -- DETAIL: one line per burn at every tank furnace, chatter in
    -- ordinary play. The tank's charge is on the bank readout.
    log('DETAIL', string.format('building %d paid %d unit(s) for %s at the burn,'
        .. ' %s left.', r.bld, r.cost, key, num(t.units)), 'RESERVE')
    return true
end

-- The cycle burned nothing: the units go back. Idempotent.
function release_job(key, why)
    local r = reserved[key]
    if not r then return false end
    reserved[key] = nil
    log('DETAIL', string.format('building %d released %d unit(s) held for %s: %s.',
        r.bld, r.cost, key, tostring(why or 'released')), 'RESERVE')
    return true
end


-- =====================================================================
-- CLONE PLUMBING
-- =====================================================================
local function find_reaction(code)
    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        if rxn.code == code then return rxn end
    end
    return nil
end

-- assign() copies the reagent and product vectors BY REFERENCE, so
-- both are rebuilt. Without that the clone and the base share them and
-- any later write to one reaches every job running the other.
-- Starts invisible in every case: show_only hands out building fields.
local function cut_clone(base_code, new_code)
    local base = find_reaction(base_code)
    if not base then return nil end

    local arr = df.global.world.raws.reactions.reactions
    local rxn = df.reaction:new()
    rxn:assign(base)
    rxn.code = new_code

    rxn.building.type:resize(0)
    rxn.building.subtype:resize(0)
    rxn.building.custom:resize(0)
    pcall(function() rxn.building.hotkey:resize(0) end)

    rxn.reagents:resize(0)
    for _, r in ipairs(base.reagents) do
        local nr = r._type:new() nr:assign(r) rxn.reagents:insert('#', nr)
    end
    rxn.products:resize(0)
    for _, p in ipairs(base.products) do
        local np = p._type:new() np:assign(p) rxn.products:insert('#', np)
    end

    pcall(function() rxn.flags.FORTRESS_MODE_ENABLED = true end)

    rxn.index = #arr
    arr:insert('#', rxn)
    return rxn
end

-- [building id] = clone CODE, one table per kind. Codes only, never the
-- reaction objects: see CLONES ARE HELD BY CODE in the header. These
-- tables exist so the slow poll can re-assert each clone's alias.
local fill_code, install_code, atomise_code = {}, {}, {}

-- Configures a fill clone for its furnace's fit-out. Declared here, so
-- ensure_clone can call it, and assigned in HEAVY FIRST below, where
-- the stock check it needs is defined.
local set_fill_mode

local function adopt_all()
    if not (ghost and ghost.register_alias) then return end
    for _, code in pairs(fill_code) do
        pcall(ghost.register_alias, code, BASE_FILL)
    end
    for _, code in pairs(install_code) do
        pcall(ghost.register_alias, code, BASE_INSTALL)
    end
    for _, code in pairs(atomise_code) do
        pcall(ghost.register_alias, code, BASE_ATOMISE)
    end
end

-- Finds or cuts one kind of clone for one building and returns its
-- code. kind is 'F' for the fill, 'I' for fitting a burner, 'A' for
-- fitting an atomiser. Nil when the base is not in the array, which is
-- true for the whole sweep window, so nothing is ever cut against a
-- deleted base. The code tables are read at call time, never cached,
-- because start() replaces them.
local function ensure_clone(kind, bid)
    local base, prefix, codes, label
    if kind == 'F' then
        base, prefix, codes, label = BASE_FILL, FILL_PREFIX, fill_code, 'fill'
    elseif kind == 'I' then
        base, prefix, codes, label = BASE_INSTALL, INSTALL_PREFIX, install_code, 'fit'
    else
        base, prefix, codes, label = BASE_ATOMISE, ATOMISE_PREFIX, atomise_code, 'atomiser fit'
    end
    local code = prefix .. bid
    if not find_reaction(code) then
        if not cut_clone(base, code) then return nil end
        -- A fill clone is configured for this furnace's fit-out the
        -- moment it exists: light only with a bare burner, both grades
        -- with an atomiser. See set_fill_mode.
        if kind == 'F' then set_fill_mode(bid) end
        log('DETAIL', label .. ' clone cut for building ' .. bid, 'CLONE')
        -- ---- JOBS FOLLOW THE CLONE ----
        -- A job saved against this clone points its filters at the
        -- clone's position in the session that made it, and a clone
        -- re-cut this session sits somewhere else, so DF would test its
        -- items against the wrong reaction or none. MEASURED on fill job
        -- 8631: an empty jug accepted as fuel. The engine's repoint runs
        -- after the inject, before any clone exists, so every cut asks
        -- for it again (refinish-module-engine.lua, JOB FILTERS FOLLOW
        -- THEIR REACTION).
        if _G.refinish_repoint_jobs then
            local ok, n_jobs, n_filters = pcall(_G.refinish_repoint_jobs)
            if ok and n_jobs and n_jobs > 0 then
                log('DETAIL', string.format('%s clone for building %d: re-pointed %d'
                    .. ' filter(s) on %d saved job(s).', label, bid,
                    n_filters, n_jobs), 'CLONE')
            end
        end
    end
    codes[bid] = code
    if ghost and ghost.register_alias then
        pcall(ghost.register_alias, code, base)
    end
    return code
end

-- Only the clones in want carry a building field, and only for the open
-- building; want is a set of codes, or nil for none. A tanked furnace
-- without an atomiser offers two at once, the fill and the atomiser fit,
-- which is why this takes a set. Every clone this file owns is found by
-- prefix in ONE walk of the live array, so a clone the engine has swept
-- is never touched. Values are read off the live building so they
-- cannot drift: its building type, its furnace or workshop sub, and its
-- building_def index. Hotkey 0 is "no hotkey", which is what every
-- module reaction gets.
local function show_only(want, b)
    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        local c = nil
        pcall(function() c = rxn.code end)
        if c and (c:sub(1, #FILL_PREFIX) == FILL_PREFIX
                  or c:sub(1, #INSTALL_PREFIX) == INSTALL_PREFIX
                  or c:sub(1, #ATOMISE_PREFIX) == ATOMISE_PREFIX) then
            pcall(function()
                rxn.building.type:resize(0)
                rxn.building.subtype:resize(0)
                rxn.building.custom:resize(0)
                rxn.building.hotkey:resize(0)
                if b and want and want[c] then
                    rxn.building.type:insert('#', b:getType())
                    rxn.building.subtype:insert('#', b.type)
                    rxn.building.custom:insert('#', b.custom_type)
                    rxn.building.hotkey:insert('#', 0)
                end
            end)
        end
    end
end

-- Every furnace except the wood furnace, the retort and the magma
-- furnaces, plus the metalsmith's forge, which is a workshop by class
-- but burns fuel like a furnace. A custom furnace from another mod is a
-- furnace; NO_TANK names every exclusion.
local function tankable(b)
    local name = building_name(b)
    if not name or NO_TANK[name] then return false end
    local cls = nil
    pcall(function() cls = b:getType() end)
    if cls == df.building_type.Furnace then return true end
    return name == 'MetalsmithsForge'
end

-- What the open sheet should offer, as a key naming the clone kinds
-- and the building: 'F' the fill, for a tanked building with room; 'A'
-- the atomiser fit, for a tanked building without one; 'I' the burner
-- fit, for a tankable building without a tank. Compared against the
-- last answer, so the live array is walked only when the answer
-- changes, and it changes by itself the moment a tank opens, fills, or
-- gains or loses an atomiser.
local last_key = nil

local function view()
    local b = nil
    pcall(function() b = dfhack.gui.getSelectedBuilding(true) end)

    local kinds = {}
    if b then
        local t = tanks[b.id]
        if t then
            -- A tank with no room for one more unit offers no fill: a
            -- vessel brought to it would only be refused and carried
            -- back. The key flips on its own as the tank burns down.
            if room_of(b.id) >= 1 then kinds[#kinds + 1] = 'F' end
            if not t.atomiser then kinds[#kinds + 1] = 'A' end
        elseif tankable(b) then
            kinds[#kinds + 1] = 'I'
        end
    end
    local key = (b and #kinds > 0) and (table.concat(kinds) .. b.id) or nil
    if key == last_key then return end
    last_key = key

    -- No key goes dark everywhere. A clone must never be left showing
    -- in a building the player walked away from, or the next sheet
    -- opened would carry a foreign entry.
    local want = nil
    if key then
        want = {}
        for _, k in ipairs(kinds) do
            local code = ensure_clone(k, b.id)
            if code then want[code] = true end
        end
    end
    show_only(want, b)
end


-- =====================================================================
-- THE FILL: WITNESS, THEN CREDIT
-- =====================================================================
-- access.lua's helper, copied. tostring on a reaction_class entry is
-- an address; the text is on .value.
local function rc_value(s)
    local v = nil
    pcall(function() v = tostring(s.value) end)
    return v
end

-- The fuel's own name, "tar" or "kerosene", for the log: the material's
-- liquid state name, the field the ghost reads for the same purpose.
local function fuel_name(liq)
    local n = nil
    pcall(function()
        local mi = dfhack.matinfo.decode(liq)
        n = mi and mi.material and mi.material.state_name.Liquid or nil
    end)
    return n and tostring(n) or '?'
end

-- LIGHT, HEAVY, or nil, read off the liquid's own material. A material
-- carrying both would be an authoring error; LIGHT wins, since it is
-- the grade a bare burner can burn.
local function grade_of_liquid(liq)
    local grade = nil
    pcall(function()
        local mi = dfhack.matinfo.decode(liq)
        if not (mi and mi.material) then return end
        for _, rc in ipairs(mi.material.reaction_class) do
            local s = rc_value(rc)
            if s == 'FUEL_LIQUID_LIGHT' then grade = 'LIGHT' end
            if s == 'FUEL_LIQUID_HEAVY' and grade == nil then grade = 'HEAVY' end
        end
    end)
    return grade
end

local function is_fill(j)
    local code = nil
    pcall(function() code = tostring(j.reaction_name or '') end)
    return code ~= nil and code:find('FILL_TANK', 1, true) ~= nil
end

local function is_install(j)
    local code = nil
    pcall(function() code = tostring(j.reaction_name or '') end)
    return code ~= nil and code:find('INSTALL_BURNER', 1, true) ~= nil
end

-- item_toolst.subtype is a pointer to the itemdef with its own .id
-- (refinish-tool-wash.lua), so a burner is a TOOL whose subtype.id is
-- the burner's.
local function is_burner(it)
    local hit = false
    pcall(function()
        hit = it:getType() == df.item_type.TOOL and it.subtype.id == BURNER_ID
    end)
    return hit
end

-- [job id] = burner item id, the first burner seen attached to a fit
-- job. Witnessed for the same reason as the fill's liquid: what a job
-- carried may not be readable off j.items once it completes.
local burners = {}

-- The same three things for the atomiser's fit job.
local function is_atomise(j)
    local code = nil
    pcall(function() code = tostring(j.reaction_name or '') end)
    return code ~= nil and code:find('INSTALL_ATOMISER', 1, true) ~= nil
end

local function is_atomiser(it)
    local hit = false
    pcall(function()
        hit = it:getType() == df.item_type.TOOL and it.subtype.id == ATOMISER_ID
    end)
    return hit
end

local atomisers = {}

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

-- [job id]    = { liquid = item id, grade = 'LIGHT'|'HEAVY', dim = n }
-- [liquid id] = true once paid, because remove is deferred.
local witness  = {}
local credited = {}
-- [job id] = true for a fill that completed carrying no fuel. Cancelled
-- by cancel_fills on the next slow poll: see A FILL WITH NOTHING IN IT.
local dud = {}

-- Finds the graded liquid a fill job is carrying. It may be attached
-- directly, or riding inside the attached vessel, which is the pitch
-- chain's case: both are searched and the first graded one wins.
local function find_fuel(j)
    local found = nil
    pcall(function()
        for _, iref in ipairs(j.items) do
            local it = iref.item
            if it and not found then
                local cands = { it }
                for _, c in ipairs(dfhack.items.getContainedItems(it) or {}) do
                    cands[#cands + 1] = c
                end
                for _, c in ipairs(cands) do
                    if not found
                       and c:getType() == df.item_type.LIQUID_MISC
                       and not credited[c.id] then
                        local g = grade_of_liquid(c)
                        if g then
                            local dm = nil
                            pcall(function() dm = c.dimension end)
                            found = { liquid = c.id, grade = g, dim = dm or 0,
                                      per_unit = charge_per_unit(c, g),
                                      name = fuel_name(c) }
                        end
                    end
                end
            end
        end
    end)
    return found
end

-- ---------------------------------------------------------------------
-- HEAVY FIRST, LIGHT AS THE FALLBACK
-- ---------------------------------------------------------------------
-- The liquid twin of access.lua's BULK FIRST, FINISHED FUEL AS THE
-- FALLBACK, for the same economy: a furnace that can burn the cheap
-- grade burns it while any exists and reaches for the dear one only
-- when it is gone. MEASURED that it did not: a kiln's fill took
-- kerosene with tar on hand (job 7605, light liquid #9551), because the
-- fill asks for FUEL_LIQUID and DF takes whichever vessel is nearest.
--
-- ON THE CLONE, NOT THE JOB. The first build of this rewrote the class
-- on the fill JOB's filter, as access.lua does for fuel, and never
-- logged a single decision: no filter on a fill job carried
-- FUEL_LIQUID, and kerosene was taken again with tar on hand (job 6654,
-- light liquid #9151). A rewrite on the CLONE's reagent, by contrast,
-- measurably governed what the forge collected. MEASURED since, by the
-- filter dump in diagnose: a fill job carries exactly one filter, the
-- container, with no class and "contains {0}" pointing at the liquid,
-- which has no job filter at all. DF checks a contained liquid against
-- the reaction's own reagent, so the clone is the only place its class
-- can live.
--
-- So each tanked furnace WITH AN ATOMISER has its fill clone's liquid
-- reagent switched between FUEL_LIQUID_HEAVY and the union.
-- Mirrored from access.lua, each for the reason it records there:
--   the FORT'S STOCK decides, not the dwarf;
--   a separate class, because a reagent asks for exactly one;
--   decided at POSTING, through onJobInitiated, before any hauler.
-- Re-decided every slow poll, so stock changes and repeat cycles are
-- followed, but never while one of that furnace's fill jobs holds a
-- vessel: the reagent does not change under an item already claimed
-- against it.
--
-- A furnace without an atomiser is left alone: its clone asks for light
-- only (see set_fill_mode).

-- Free for work, the same test as access.lua's count_bulk.
local function usable(it)
    local ok = false
    pcall(function()
        local f = it.flags
        ok = not (f.hidden or f.forbid or f.dump or f.garbage_collect
            or f.in_job or f.removed or f.owned or f.artifact)
    end)
    return ok
end

-- Is there heavy liquid fuel the fort could fill with right now: at
-- least one whole unit, in a vessel, neither it nor its vessel tied up.
-- Walks the liquid vector, falling back to everything in play (the
-- vector access.lua walks) if it cannot be read. Stops at the first.
local function heavy_on_hand()
    local vec = nil
    pcall(function() vec = df.global.world.items.other.LIQUID_MISC end)
    if not vec then
        pcall(function() vec = df.global.world.items.other.IN_PLAY end)
    end
    if not vec then return false end
    local hit = false
    pcall(function()
        for _, it in ipairs(vec) do
            if it:getType() == df.item_type.LIQUID_MISC
               and not credited[it.id]
               and grade_of_liquid(it) == 'HEAVY' and usable(it) then
                local dim, vessel = 0, nil
                pcall(function() dim = it.dimension end)
                pcall(function() vessel = dfhack.items.getContainer(it) end)
                if dim >= UNIT_DIM and vessel and usable(vessel) then
                    hit = true
                    return
                end
            end
        end
    end)
    return hit
end

-- [building id] = the class last set on that furnace's fill clone, so a
-- change is logged once and the reactions array is walked only when the
-- answer changes. Reset each session, since the clones are re-cut.
local clone_class = {}

-- Points a furnace's fill clone at the heavy class or back at the
-- union. Resolved by code from the live array, never held (see CLONES
-- ARE HELD BY CODE), and the reagent found by the class it asks for,
-- never by slot.
local function set_clone_class(bid, cls)
    if clone_class[bid] == cls then return end
    local rxn = find_reaction(FILL_PREFIX .. bid)
    if not rxn then return end
    local done = false
    pcall(function()
        for _, r in ipairs(rxn.reagents) do
            local rc = tostring(r.reaction_class)
            if rc == CLASS_ANY or rc == CLASS_HEAVY then
                r.reaction_class = cls
                done = true
                return
            end
        end
    end)
    if done then
        clone_class[bid] = cls
        log('DETAIL', string.format(cls == CLASS_HEAVY
            and 'building %d: fill takes heavy fuel first.'
            or 'building %d: no heavy fuel to hand; fill takes light fuel too.',
            bid), 'FILL')
    end
end

-- ---- WHAT A FILL ASKS FOR: THE FIT-OUT DECIDES ----
-- Writes the furnace's fit-out onto its fill clone: the liquid reagent's
-- class and code, which decide what a fill job collects and what its
-- requirement line reads (both MEASURED), and the description. A bare
-- burner asks for light fuel only. With an atomiser the clone asks for
-- the union or heavy, whichever the stock decides right now, and the
-- heavy first functions below keep it current from then on.
--
-- Called when a fill clone is cut, and whenever an atomiser is fitted
-- or leaves, so the menu always matches the hardware. The reagent is
-- found by the class it asks for, whichever of the three it is now,
-- never by slot. Descriptions get fresh objects, because cut_clone does
-- not deep copy them and the clone would otherwise share the base's.
set_fill_mode = function(bid)
    local rxn = find_reaction(FILL_PREFIX .. bid)
    if not rxn then return end
    local t = tanks[bid]
    local atomised = t ~= nil and t.atomiser ~= nil
    local cls  = CLASS_LIGHT
    if atomised then cls = heavy_on_hand() and CLASS_HEAVY or CLASS_ANY end
    local code = atomised and CODE_ANY or CODE_LIGHT
    local text = atomised and ATOMISED_TEXT or LIGHT_TEXT
    local wrote, old = 0, nil
    pcall(function()
        for _, r in ipairs(rxn.reagents) do
            local rc = tostring(r.reaction_class)
            if rc == CLASS_ANY or rc == CLASS_HEAVY or rc == CLASS_LIGHT then
                old = tostring(r.code)
                r.code = code
                r.reaction_class = cls
                wrote = wrote + 1
            end
        end
        -- The product names its source reagent by CODE, so it follows.
        -- Products are deep copied, so this touches the clone only.
        for _, pr in ipairs(rxn.products) do
            pcall(function()
                if old and pr.get_material.reagent_code == old then
                    pr.get_material.reagent_code = code
                end
            end)
        end
        rxn.descriptions:resize(0)
        for _, line in ipairs(text) do
            local d = df.reaction_description:new()
            d.text = line
            rxn.descriptions:insert('#', d)
        end
    end)
    -- The heavy first memo follows, so it neither skips nor repeats.
    clone_class[bid] = atomised and cls or nil
    if wrote ~= 1 then
        -- ERROR: this building's fill filters are wrong until the clone
        -- is cut again.
        log('ERROR', string.format('fill clone for building %d: expected one liquid'
            .. ' reagent, found %d, so its fit-out could not be written.',
            bid, wrote), 'FILL')
    end
end

-- The furnaces with a fill job holding a vessel right now. `except` is
-- a job id to leave out: the job completing, which still lists its
-- items during the completion event and would otherwise block its own
-- furnace's decision.
local function busy_fills(except)
    local busy = {}
    local l = df.global.world.jobs.list.next
    while l do
        local j = l.item
        if j and j.id ~= except and is_fill(j) then
            local n = 0
            pcall(function() n = #j.items end)
            if n > 0 then
                local b = job_building(j)
                if b then busy[b.id] = true end
            end
        end
        l = l.next
    end
    return busy
end

-- Rides the slow poll: every idle furnace's clone follows the stock.
local function grade_fills()
    local busy, heavy = nil, nil
    for bid in pairs(tanks) do
        if fill_code[bid] then
            local b = df.building.find(bid)
            if b and tanks[bid].atomiser then
                busy = busy or busy_fills()
                if not busy[bid] then
                    if heavy == nil then heavy = heavy_on_hand() end
                    set_clone_class(bid, heavy and CLASS_HEAVY or CLASS_ANY)
                end
            end
        end
    end
end

-- ---- ONE LOOK AT A FILL JOB'S FILTERS ----
-- Settles the inference above. The first fill job of each session
-- prints every filter it carries: the reagent it serves, its item type,
-- its class, and what it contains.
local shape_logged = false

local function diagnose(j)
    if shape_logged then return end
    shape_logged = true
    local parts = {}
    pcall(function()
        for i, e in ipairs(j.job_items.elements) do
            local inner = {}
            pcall(function()
                for _, c in ipairs(e.contains) do inner[#inner + 1] = tostring(c) end
            end)
            parts[#parts + 1] = string.format('[%d] reagent %s, item type %s,'
                .. ' class "%s", contains {%s}', i, tostring(e.reagent_index),
                tostring(e.item_type), tostring(e.reaction_class),
                table.concat(inner, ','))
        end
    end)
    log('DETAIL', string.format('job %d: fill filters: %s', j.id,
        #parts > 0 and table.concat(parts, '; ') or 'none'), 'FILL')
end

-- At posting, before any hauler is dispatched: the new job holds
-- nothing, so its furnace's clone may follow the stock now, unless
-- another fill there already holds a vessel.
local function on_posted(j)
    if not is_fill(j) then return end
    diagnose(j)
    local b = job_building(j)
    if not (b and tanks[b.id] and tanks[b.id].atomiser) then return end
    if busy_fills()[b.id] then return end
    set_clone_class(b.id, heavy_on_hand() and CLASS_HEAVY or CLASS_ANY)
end

-- Rides the fast poll. One walk of the job list serves both kinds.
-- A fill job's liquid and a fit job's burner are each recorded the
-- first time they are seen attached and never overwritten, so what is
-- acted on is what walked in.
local function witness_jobs()
    local l = df.global.world.jobs.list.next
    while l do
        local j = l.item
        if j and is_fill(j) then
            local n = 0
            pcall(function() n = #j.items end)
            if n > 0 and not witness[j.id] then
                local w = find_fuel(j)
                if w then
                    local wb = job_building(j)
                    w.bld = wb and wb.id or nil
                    witness[j.id] = w
                    log('DETAIL', string.format('job %d at %s: witnessed %s #%d, %s'
                        .. ' grade, dimension %d.', j.id, where(wb), w.name,
                        w.liquid, string.lower(w.grade), w.dim), 'WITNESS')
                end
            end
        elseif j and not burners[j.id] and is_install(j) then
            pcall(function()
                for _, iref in ipairs(j.items) do
                    if iref.item and is_burner(iref.item) then
                        burners[j.id] = iref.item.id
                        return
                    end
                end
            end)
        elseif j and not atomisers[j.id] and is_atomise(j) then
            pcall(function()
                for _, iref in ipairs(j.items) do
                    if iref.item and is_atomiser(iref.item) then
                        atomisers[j.id] = iref.item.id
                        return
                    end
                end
            end)
        end
        l = l.next
    end
end

local function fill_done(j)
    local b = job_building(j)
    if not b then return end

    -- The witness first. A read now is the fallback, for a job that
    -- attached and finished between two fast polls.
    local w = witness[j.id] or find_fuel(j)
    witness[j.id] = nil
    if not w then
        -- ---- A FILL WITH NOTHING IN IT ----
        -- MEASURED: repeating fill job 8631 at a kiln poured its jug dry,
        -- then completed again every 12 seconds or so carrying no fuel,
        -- across three reloads, until noticed. A fill that completes
        -- with nothing did nothing, and on repeat it does nothing
        -- forever, so it is marked here and cancel_fills removes it on
        -- the next slow poll, vessel or not. Never removed from inside
        -- this completion event. A fill is re-queued by hand when fuel
        -- is to hand.
        dud[j.id] = true
        log('WARNING', string.format('job %d at %s: fill completed with no fuel in'
            .. ' its vessel, so nothing was credited; cancelling it before'
            .. ' it can repeat.', j.id, where(b)), 'FILL')
        return
    end
    if credited[w.liquid] then return end

    local amount = math.floor((w.dim or 0) / UNIT_DIM)
    local spare  = (w.dim or 0) - amount * UNIT_DIM
    if amount < 1 then
        log('WARNING', string.format('job %d: liquid #%d held %d, under one unit of'
            .. ' %d. Nothing credited, the liquid is left in the vessel.',
            j.id, w.liquid, w.dim or 0, UNIT_DIM), 'FILL')
        return
    end

    -- ---- POUR WHAT FITS ----
    -- The reagent is PRESERVED, so DF consumes nothing and this function
    -- is the only thing that ever takes liquid out of a vessel. MEASURED
    -- why: unpreserved, DF took the reagent's 150 at every completion
    -- whatever was decided here, so a refused fill still cost a unit and
    -- a repeating one cost a unit per cycle. Liquid #6569 was refused at
    -- dimension 1950 and again, one cycle later, at 1800.
    --
    -- The tank takes what it has room for. All of it: the liquid goes,
    -- as it always has. Part of it: the rest stays in the vessel, resized
    -- with DF's own setDimension, the call the hide watcher makes on its
    -- globs. The resize comes BEFORE the credit, so a failed write
    -- credits nothing, and a credit refused after it puts the dimension
    -- back. No path creates fuel or loses it.
    local room = math.floor(capacity() - volume_of(b.id))
    local take = math.min(amount, room)
    if take < 1 then
        log('INFO', string.format('job %d: the tank at %s is full; the vessel keeps'
            .. ' all %d unit(s) of %s.', j.id, where(b), amount, tostring(w.name)), 'FILL')
        return
    end

    local liq     = df.item.find(w.liquid)
    local partial = take < amount
    local now     = w.dim or 0
    if partial then
        pcall(function() now = liq.dimension end)
        local ok = liq and pcall(function()
            liq:setDimension(now - take * UNIT_DIM)
        end)
        if not ok then
            log('WARNING', string.format('job %d: the part that did not fit could not'
                .. ' be left in the vessel, so nothing was poured.', j.id), 'FILL')
            return
        end
    end

    local added, why = fill(b.id, w.grade, take, w.per_unit, w.name, j.id)
    if not added then
        -- Refused, most likely heavy fuel at a furnace with no atomiser.
        -- Nothing was consumed, and a resize made above is put back.
        if partial then pcall(function() liq:setDimension(now) end) end
        log('WARNING', string.format('job %d: %s refused %s: %s. The vessel keeps its'
            .. ' liquid.', j.id, where(b), tostring(w.name), tostring(why)), 'FILL')
        return
    end

    if partial then
        log('INFO', string.format('job %d: poured %d of %d unit(s) of %s into %s;'
            .. ' the rest stays in the vessel.', j.id, take, amount,
            tostring(w.name), where(b)), 'FILL')
        return
    end

    -- All of it went in, so the liquid goes. Marked first, because the
    -- removal is deferred and the item can still be found for several
    -- polls.
    credited[w.liquid] = true
    if liq then pcall(dfhack.items.remove, liq) end
    if spare > 0 then
        log('DETAIL', string.format('job %d: dimension %d held %d unit(s) and %d'
            .. ' spare; the spare went with the liquid.',
            j.id, w.dim, amount, spare), 'FILL')
    end
end

-- The fit. The burner goes into the furnace as a PERMANENT part and
-- only then does the tank open, recording the burner's id, which is
-- what the slow poll checks from then on.
local function install_done(j)
    local b = job_building(j)
    if not b then return end
    local burner = burners[j.id]
    burners[j.id] = nil

    if tanks[b.id] then
        log('WARNING', string.format('job %d: building %d already has a burner; the'
            .. ' second one is left where it is.', j.id, b.id), 'BURNER')
        return
    end
    if not tankable(b) then
        log('WARNING', string.format('job %d: building %d cannot carry a tank; the'
            .. ' burner is left where it is.', j.id, b.id), 'BURNER')
        return
    end

    -- The witness first. A read now is the fallback, for a job that
    -- attached and finished between two fast polls.
    if not burner then
        pcall(function()
            for _, iref in ipairs(j.items) do
                if iref.item and is_burner(iref.item) then
                    burner = iref.item.id
                    return
                end
            end
        end)
    end
    local it = burner and df.item.find(burner) or nil
    if not it then
        -- ERROR: the job finished and the furnace has no tank, which
        -- the player will notice.
        log('ERROR', string.format('job %d: fit completed but no burner was'
            .. ' witnessed; building %d has no tank.', j.id, b.id), 'BURNER')
        return
    end

    local ok, res = pcall(dfhack.items.moveToBuilding, it, b,
        df.building_item_role_type.PERM)
    if not ok or res == false then
        log('ERROR', string.format('job %d: burner #%d could not be fitted to'
            .. ' building %d (%s); no tank opened.', j.id, it.id, b.id,
            tostring(res)), 'BURNER')
        return
    end
    install(b.id, it.id)
end

-- The atomiser's fit. It goes into the furnace as a PERMANENT part,
-- beside the burner, and only then is it recorded on the tank and the
-- fill reconfigured to take heavy fuel too.
local function atomise_done(j)
    local b = job_building(j)
    if not b then return end
    local aid = atomisers[j.id]
    atomisers[j.id] = nil

    local t = tanks[b.id]
    if not t then
        log('WARNING', string.format('job %d: %s has no burner to fit an atomiser to;'
            .. ' the atomiser is left where it is.', j.id, where(b)), 'ATOMISER')
        return
    end
    if t.atomiser then
        log('WARNING', string.format('job %d: %s already has an atomiser; the second'
            .. ' one is left where it is.', j.id, where(b)), 'ATOMISER')
        return
    end

    -- The witness first, then a read now for a job that attached and
    -- finished between two fast polls.
    if not aid then
        pcall(function()
            for _, iref in ipairs(j.items) do
                if iref.item and is_atomiser(iref.item) then
                    aid = iref.item.id
                    return
                end
            end
        end)
    end
    local it = aid and df.item.find(aid) or nil
    if not it then
        -- ERROR: the job finished and the furnace is unchanged, which
        -- the player will notice.
        log('ERROR', string.format('job %d: atomiser fit completed but no atomiser'
            .. ' was witnessed; %s is unchanged.', j.id, where(b)), 'ATOMISER')
        return
    end

    local ok, res = pcall(dfhack.items.moveToBuilding, it, b,
        df.building_item_role_type.PERM)
    if not ok or res == false then
        log('ERROR', string.format('job %d: atomiser #%d could not be fitted to %s'
            .. ' (%s).', j.id, it.id, where(b), tostring(res)), 'ATOMISER')
        return
    end
    t.atomiser = it.id
    persist_charge()
    set_fill_mode(b.id)
    log('INFO', string.format('atomiser #%d fitted to %s: it now burns heavy fuel'
        .. ' too, heavy first.', it.id, where(b)), 'ATOMISER')
end

-- ---- THE NEXT CYCLE IS DECIDED AT COMPLETION ----
-- MEASURED: the poll lost a race to DF. Job 7137 poured its last tar at
-- 15:21:41, the slow poll switched the clone to light at 15:21:42, and
-- in between DF started the repeat cycle, searched for heavy fuel,
-- found none and cancelled the job. The same race went the other way
-- at 15:19:30, where job 7050 switched in time and took kerosene. So
-- the class for the next cycle is decided here, inside the completion
-- event, the one moment guaranteed to fall between a repeat job's
-- cycles and before its next search. Every completion path counts, a
-- refusal included, since the job is between cycles either way.
local function regrade(j)
    local b = job_building(j)
    if not (b and tanks[b.id] and tanks[b.id].atomiser) then return end
    if busy_fills(j.id)[b.id] then return end
    set_clone_class(b.id, heavy_on_hand() and CLASS_HEAVY or CLASS_ANY)
end

local function on_completed(j)
    if is_fill(j) then
        fill_done(j)
        regrade(j)
    elseif is_install(j) then
        install_done(j)
    elseif is_atomise(j) then
        atomise_done(j)
    end
end


-- =====================================================================
-- POLLS
-- =====================================================================
local function fast()
    if not dfhack.isMapLoaded() then return end
    view()
    pcall(witness_jobs)
end

-- ---- A FULL TANK CANCELS ITS FILLS ----
-- With the reagent preserved, a fill at a full tank no longer costs fuel,
-- but a repeating one would still send a dwarf to carry the same vessel
-- back and forth for nothing, forever. So an IDLE fill job, one holding
-- nothing, at a tank with no room for a unit is cancelled outright with
-- dfhack.job.removeJob, which Lua_API documents as cancelling the job,
-- cleaning up every reference to it and removing it from the world.
-- Suspended jobs included, since a fill parked at a full tank has nothing
-- to wait for. A fill still carrying its vessel is left to finish, and
-- its completion pours what fits, which at a full tank is nothing.
--
-- Deliberately not a pause: the first build suspended these, and a
-- suspended job sits in the workshop's queue. A repeating fill is
-- re-queued by hand when the tank wants more.
local function cancel_fills()
    local doomed = {}
    local l = df.global.world.jobs.list.next
    while l do
        local j = l.item
        if j and is_fill(j) then
            local b = job_building(j)
            if dud[j.id] then
                -- A fill that completed empty goes whatever it holds: the
                -- vessel it holds is the fault. See A FILL WITH NOTHING IN
                -- IT in fill_done.
                table.insert(doomed, { j = j, id = j.id, bid = b and b.id,
                                       why = 'it completed with no fuel' })
            elseif b and tanks[b.id] and room_of(b.id) < 1 then
                local held = 0
                pcall(function() held = #j.items end)
                if held == 0 then
                    table.insert(doomed, { j = j, id = j.id, bid = b.id,
                                           why = 'the tank is full' })
                end
            end
        end
        l = l.next
    end
    -- Removed after the walk, never during it: removeJob unlinks the job
    -- from the very list being walked. The id is read beforehand, since
    -- the job is gone afterwards.
    for _, d in ipairs(doomed) do
        local ok = pcall(dfhack.job.removeJob, d.j)
        dud[d.id] = nil
        -- INFO when the fill is gone. ERROR when it could not be removed,
        -- since it then repeats doing nothing.
        log(ok and 'INFO' or 'ERROR', string.format('job %d at building %s: %s; fill %s.', d.id,
            tostring(d.bid or '?'), d.why,
            ok and 'cancelled' or 'could not be cancelled'), 'FILL')
    end
end

-- Once per session, reset in start().
local bases_checked = false

local function poll()
    if not dfhack.isMapLoaded() then return end

    -- ---- ONE CHECK PER SESSION: ARE THE BASES THERE ----
    -- Every clone is cut from its base, so a base that never reached the
    -- raws makes every cut fail SILENTLY: the fill or the fit simply
    -- never appears in any menu, with nothing in the log to say why.
    -- MEASURED exactly that way: INSTALL_BURNER was missing from the
    -- JSON the game loaded (the builder reported 427 reactions where 428
    -- were due) and no fit was offered anywhere. Checked in the slow
    -- poll rather than in start(), which runs at the module broadcast,
    -- before the inject.
    --
    -- And even the poll must WAIT for the inject. MEASURED:
    -- repeat-util's scheduleEvery runs its function once immediately,
    -- so the first poll runs inside start(), at the module broadcast,
    -- before anything is injected. Unguarded, this check logged both
    -- bases missing ahead of "built 428 reactions" on every load, and
    -- then both were cut from normally. So it only judges once the
    -- module's reactions exist at all; before that, a missing base
    -- means nothing yet.
    local injected = false
    if not bases_checked then
        pcall(function()
            for _, r in ipairs(df.global.world.raws.reactions.reactions) do
                if r.code:sub(1, #RXN_PREFIX) == RXN_PREFIX then
                    injected = true
                    break
                end
            end
        end)
    end
    if not bases_checked and injected then
        bases_checked = true
        for _, base in ipairs({ BASE_FILL, BASE_INSTALL, BASE_ATOMISE }) do
            if not find_reaction(base) then
                log('ERROR', 'MISSING BASE REACTION ' .. base .. ': it is not in'
                    .. ' the raws, so nothing can be cut from it and it'
                    .. ' will appear in no menu this session.', 'BASE_REACTION')
            end
        end

        -- ---- JOBS SAVED ON CLONES GET THEIR CLONES NOW ----
        -- A clone is otherwise cut only when its building's sheet is
        -- opened, and until then a job saved against it runs on a
        -- reaction that does not exist (the ghost reports these), with
        -- its filters at a stale position. So at the first poll after
        -- the inject, every live job on one of this file's clones has
        -- its clone cut, which re-points it (JOBS FOLLOW THE CLONE, in
        -- ensure_clone). A cut clone starts invisible; show_only still
        -- decides what any menu offers.
        local wanted = {}
        local PREFIXES = { F = FILL_PREFIX, I = INSTALL_PREFIX,
                           A = ATOMISE_PREFIX }
        local l = df.global.world.jobs.list.next
        while l do
            local j, code = l.item, nil
            if j then
                pcall(function() code = tostring(j.reaction_name or '') end)
            end
            if code then
                for kind, prefix in pairs(PREFIXES) do
                    if code:sub(1, #prefix) == prefix then
                        local bid = tonumber(code:sub(#prefix + 1))
                        if bid then
                            wanted[kind .. bid] = { kind = kind, bid = bid }
                        end
                    end
                end
            end
            l = l.next
        end
        for _, w in pairs(wanted) do ensure_clone(w.kind, w.bid) end
    end

    -- Re-asserted here rather than at mint, because the ghost rebuilds
    -- JIT_CONFIG and AUTHORED in its own start().
    adopt_all()

    -- A tank whose building is gone takes its clone's visibility and
    -- its reservations with it. The clone itself is left for the
    -- prefix sweep.
    for id in pairs(tanks) do
        if not df.building.find(id) then
            log('INFO', string.format('building %d is gone, dropping its tank.', id), 'TANK')
            uninstall(id)
        end
    end

    -- ---- THE BURNER MUST STILL BE THERE ----
    -- A tank exists because a burner is fitted, so the burner is checked
    -- by IDENTITY and LOCATION only: its item id, among this building's
    -- contained items. Deliberately NOT by type: at every save the tool
    -- wash repoints module tool items to a vanilla jug until the reload
    -- restores them, and this poll can run inside that window, so a type
    -- test would read a washed burner as missing and remove a good tank.
    --
    -- A burner that has gone takes its tank with it, loudly. The one
    -- open question about a PERMANENT building item is whether DF ever
    -- claims one as a reagent; if it does, this line is where it shows.
    -- Console tanks from before the burner existed carry no burner id
    -- and are not checked.
    for id, t in pairs(tanks) do
        local burner = tonumber(t.burner)
        local b = df.building.find(id)
        if b and burner and burner > 0 then
            local here = false
            pcall(function()
                for _, ci in ipairs(b.contained_items) do
                    if ci.item and ci.item.id == burner then
                        here = true
                        return
                    end
                end
            end)
            if not here then
                log('WARNING', string.format('burner #%d is no longer in building %d;'
                    .. ' its tank is removed, %s unit(s) with it.',
                    burner, id, num(t.units)), 'BURNER')
                uninstall(id)
            end
        end
    end

    -- ---- THE ATOMISER MUST STILL BE THERE ----
    -- Checked exactly as the burner is, by identity and location and
    -- never by type, for the same reason: the tool wash. An atomiser that
    -- has gone takes only itself. The tank stays and its fill goes back
    -- to light fuel only. Charge already in the tank keeps burning, since
    -- the tank does not track which grade each unit came from.
    for id, t in pairs(tanks) do
        local aid = tonumber(t.atomiser)
        local b = df.building.find(id)
        if b and aid and aid > 0 then
            local here = false
            pcall(function()
                for _, ci in ipairs(b.contained_items) do
                    if ci.item and ci.item.id == aid then
                        here = true
                        return
                    end
                end
            end)
            if not here then
                t.atomiser = nil
                persist_charge()
                set_fill_mode(id)
                log('WARNING', string.format('atomiser #%d is no longer in %s; its fill'
                    .. ' takes light fuel only again.', aid, where(b)), 'ATOMISER')
            end
        end
    end

    -- Live job ids, walked off the job list the way access.lua does it.
    -- NOT df.job.find, which the first version of this file used: it is
    -- in no API doc and no working call anywhere in the project, since
    -- jobs live in a linked list rather than an id-indexed vector.
    local live = {}
    pcall(function()
        local l = df.global.world.jobs.list.next
        while l do
            if l.item then live[l.item.id] = true end
            l = l.next
        end
    end)

    -- BACKSTOP ONLY. access.lua settles or releases every reservation
    -- within ten frames of its job leaving. One whose job has been gone
    -- for ORPHAN_POLLS slow polls means access was not running to judge
    -- it, and a promise nobody will ever settle is released rather than
    -- held against the tank forever.
    for key, r in pairs(reserved) do
        local jid = tonumber(tostring(key):match('^(%d+):'))
        if jid and live[jid] then
            r.gone = 0
        else
            r.gone = (r.gone or 0) + 1
            if r.gone >= ORPHAN_POLLS then
                release_job(key, 'its job is gone and nothing judged it')
            end
        end
    end

    -- Witnesses for fill jobs that no longer exist were cancelled:
    -- nothing was paid and nothing was removed, so they are forgotten.
    -- But said out loud first. MEASURED: four kiln fills that collected
    -- kerosene (jobs 6954, 6959, 7050, 7199) left the job list without
    -- pouring and without a line, while the same jug poured at the
    -- forge. This line records what each one held and what its
    -- furnace's fill was asking for at that moment, which is the
    -- evidence the cause has to come from.
    for jid, w in pairs(witness) do
        if not live[jid] then
            local asked = '?'
            pcall(function()
                local rxn = w.bld and find_reaction(FILL_PREFIX .. w.bld)
                if rxn then
                    for _, r in ipairs(rxn.reagents) do
                        local rc = tostring(r.reaction_class)
                        if rc ~= '' then asked = rc end
                    end
                end
            end)
            log('WARNING', string.format('job %d: fill left the job list before pouring.'
                .. ' It held %s liquid #%d (%s); building %s\'s fill asked for %s.',
                jid, tostring(w.grade), w.liquid,
                df.item.find(w.liquid) and 'still exists' or 'gone',
                tostring(w.bld), asked), 'FILL')
            witness[jid] = nil
        end
    end
    for jid in pairs(burners) do
        if not live[jid] then burners[jid] = nil end
    end
    for jid in pairs(atomisers) do
        if not live[jid] then atomisers[jid] = nil end
    end
    pcall(cancel_fills)
    pcall(grade_fills)

    -- A liquid is only worth remembering until it has actually gone.
    for lid in pairs(credited) do
        if not df.item.find(lid) then credited[lid] = nil end
    end
end

function start()
    fill_code, install_code, atomise_code, last_key = {}, {}, {}, nil
    cap_units = nil
    bases_checked = false
    witness, burners, atomisers, credited, dud = {}, {}, {}, {}, {}
    clone_class, shape_logged = {}, false

    -- The charge comes back from the save first, before anything can
    -- ask about it. Reservations start clean: access.lua rebuilds every
    -- one as it re-adopts, which happens after this, because it starts
    -- after this file.
    local n_back, n_drop = restore_charge()
    for k in pairs(reserved) do reserved[k] = nil end

    -- Published before access.lua starts, which is what lets its
    -- re-adoption reserve against the restored charge.
    _G.making_fuel_tank_api = {
        charge_of    = charge_of,
        capacity     = capacity,
        available    = available,
        has_charge   = has_charge,
        reserve_job  = reserve_job,
        settle_job   = settle_job,
        release_job  = release_job,
    }

    eventful.onJobCompleted[EVENT_KEY] = function(j) pcall(on_completed, j) end
    eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)
    -- Posting, for heavy first. Its own key, beside access.lua's.
    eventful.onJobInitiated[EVENT_KEY] = function(j) pcall(on_posted, j) end
    eventful.enableEvent(eventful.eventType.JOB_INITIATED, 0)

    repeatUtil.scheduleEvery(FAST_KEY, FAST_FRAMES, 'frames', fast)
    repeatUtil.scheduleEvery(SLOW_KEY, SLOW_FRAMES, 'frames', poll)

    -- The ghost sweeps orphans in its own start(), before any alias
    -- from this file can exist, so a fill left mid job across a data
    -- cycle is passed over. Asserting the aliases and re-running the
    -- sweep is what reverts it.
    adopt_all()
    if ghost and ghost.resweep_orphans then pcall(ghost.resweep_orphans) end

    -- DETAIL as a rule. WARNING when saved tanks were dropped because
    -- their building is gone, since their charge went with them.
    log(n_drop > 0 and 'WARNING' or 'DETAIL', string.format('active. %d tank(s) restored from the save, %d'
        .. ' dropped, %d unit(s) per job.', n_back, n_drop, units_per_job()), 'START')
end

function stop()
    -- First, so access.lua stops waiving the moment this file stops. It
    -- stops before this file and settles nothing on the way out: every
    -- record it needs was written through as it happened.
    _G.making_fuel_tank_api = nil
    eventful.onJobCompleted[EVENT_KEY] = nil
    eventful.onJobInitiated[EVENT_KEY] = nil
    repeatUtil.cancel(FAST_KEY)
    repeatUtil.cancel(SLOW_KEY)
    -- Every clone goes dark on the way out, so a session that died
    -- cannot leave an entry showing in the wrong building. Found by code
    -- in the live array, so the clones the engine already swept in the
    -- shutdown sequence are never touched.
    pcall(show_only, nil, nil)
    last_key = nil
    -- Clones are NOT popped. The engine sweeps by prefix and a pop
    -- would be a double free.
    log('DETAIL', 'stopped.', 'STOP')
end