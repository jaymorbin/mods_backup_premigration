--@ module = true
-- making-fuel-bank-readout.lua
--
-- ==========================================
-- THE SHOULDER TAP
-- ==========================================
-- A small always-on readout that appears beside the building sheet
-- whenever a furnace that banks is open, showing what the fuel banks
-- are currently holding back.
--
-- WHY THIS EXISTS. Adaptive reactions pay whole denominations and
-- bank the remainder. On small inputs a job can complete and drop
-- NOTHING, correctly, several runs in a row. A log line explains
-- that to nobody, because nobody reads the log while wondering if
-- the mod is broken. This panel sits in their eyeline instead: the
-- job finishes empty, these numbers tick up, and the mechanism
-- explains itself.
--
-- PATTERN PARENT: refinish-warning.lua. Same overlay plugin, same
-- discovery path, same visible() shape gated on _G.refinish_active.
-- Registered by the OVERLAY_WIDGETS export at the bottom, so nothing
-- in making_fuel.lua needs to start or stop it. Dormant saves hide
-- it the same way the warning hides.
--
-- DATA SOURCE. The ghost publishes its bank at _G.refinish_fuel_bank
-- with keys BANK_<CURRENCY> under PROFILE scope. This file only ever
-- READS that table. If the ghost is not loaded the table is nil and
-- the widget hides, so load order cannot hurt it.
--
-- The one exception is the still's spirit, which is not the ghost's:
-- making-fuel-still.lua keeps it per still and publishes the table at
-- _G.making_fuel_spirit_carry, read here the same way, never written.
--
-- Each building shows every currency it can bank, zero included (THE
-- DISPLAY LAW, below): the retort its pyrolysis liquids, the still its
-- spirit, fractions and purses, the kitchen its pitch and bitumen.
-- ==========================================

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui     = require('gui')

-- ==========================================
-- WHICH FURNACES BANK, AND IN WHAT
-- ==========================================
-- Kindling appears only at the wood furnace because the split
-- reactions run there. Vanilla smelter and kiln are listed because
-- the hijacker banks their vanilla jobs into the same three pools.
-- Values are the row list for that furnace, in display order.
local ROWS_WOOD    = { 'CHARCOAL', 'ASH', 'KINDLING' }
local ROWS_GENERIC = { 'CHARCOAL', 'ASH' }

-- The smelter banks COKE and nothing else. It was on ROWS_GENERIC,
-- which showed it charcoal and ash: two rows that can never move
-- there, because a bank key is per furnace and no charring job can
-- run in a smelter. Meanwhile the one bank it does hold, filled by
-- every vanilla coking job since those went adaptive, had no row at
-- all. Metered in breeze through STEP, like every other ladder.
--
-- Coal ash is deliberately absent: it is one bar per job, paid
-- outright, and a bank row for something that never banks is the
-- same lie in the other direction.
local ROWS_SMELTER = { 'COKE', 'ASH_COAL' }

-- Enum keys are MIXED CASE, WoodFurnace not WOOD_FURNACE. A wrong
-- key here is nil, and a nil table index THROWS AT LOAD, which kills
-- the whole script silently from the overlay's point of view. That
-- is exactly how this panel failed to appear on first delivery. The
-- resolver below turns any future enum rename into a hidden row
-- instead of a dead file.
local FURNACE_ROWS = {}
local function furnace_rows(name, rows)
    local v = df.furnace_type[name]
    if v ~= nil then FURNACE_ROWS[v] = rows end
end
furnace_rows('WoodFurnace',  ROWS_WOOD)
furnace_rows('Smelter',      ROWS_SMELTER)
furnace_rows('Kiln',         ROWS_GENERIC)
furnace_rows('MagmaSmelter', ROWS_SMELTER)
furnace_rows('MagmaKiln',    ROWS_GENERIC)

-- WORKSHOPS BANK TOO. The still and the kitchen are workshops, not
-- furnaces. Keyed on the WORKSHOP enum, resolved the same guarded way
-- as FURNACE_ROWS, so a renamed key is a hidden row rather than a dead
-- file. Still is 15 and Kitchen 19 in the enum dump.
--
-- THE STILL banks everything distilled there: its spirit, carried
-- between barrels by making-fuel-still.lua; the six fraction liquids,
-- through the 'FRACTIONS' sentinel below; coal tar's two solid
-- fractions, which crystallise and pay boulders; and both purses, pitch
-- from the two tars and bitumen from crude oil, each tar's side named
-- by the PITCH_MAT it declares.
-- THE KITCHEN banks both purses too. Its tar boil takes tar alone
-- (class TAR_ORGANIC), which declares pitch, but its coal tar boil takes
-- any TAR_INORGANIC liquid: coal tar, which declares pitch, and crude
-- oil, which declares bitumen. Its oil sand boil mints bitumen outright
-- and banks nothing.
local ROWS_STILL   = { 'SPIRIT', 'FRACTIONS', 'NAPHTHALENE', 'ANTHRACENE',
                       'PITCH', 'BITUMEN' }
local ROWS_KITCHEN = { 'PITCH', 'BITUMEN' }
local WORKSHOP_ROWS = {}
local function workshop_rows(name, rows)
    local v = df.workshop_type[name]
    if v ~= nil then WORKSHOP_ROWS[v] = rows end
end
workshop_rows('Still',   ROWS_STILL)
workshop_rows('Kitchen', ROWS_KITCHEN)

-- Custom furnaces are matched on their building_def code instead of
-- the subtype enum. Only the retort banks today.
-- The retort's last entry is dynamic: 'LIQUID' is a sentinel that
-- EXPANDS at render time into one row per PYROLYSIS liquid, ALL of
-- them, always, zero or not, in table order so the panel reads the
-- same every time you open it. The still's 'FRACTIONS' does the same
-- for its fraction liquids. Neither is ever a bank key itself.
-- COKE joined the solid rows when coal went adaptive. Its ladder is
-- the coal one, green coke and breeze rather than char and cinders,
-- but the row is the same shape: a bank that fills between whole
-- bars. lines_for and MAX_ROWS are computed from these tables, so
-- adding it here resizes the panel with no other edit.
-- The retort shows only what its own burns credit. The distillations,
-- whose fractions and purses it used to show, now run at the still:
-- see WORKSHOPS BANK TOO above.
local ROWS_RETORT = { 'CHARCOAL', 'ASH', 'COKE', 'ASH_COAL', 'LIQUID' }
local CUSTOM_ROWS = {
    MAKING_FUEL_RETORT = ROWS_RETORT,
}
-- Liquid currencies and their pack sizes, mirrored from tuning's
-- LIQUID_STANDARD so the bar counts down to a real bucket. Mirrored
-- rather than reqscripted because this panel must render even when
-- the fuel module is mid-reload; a stale pack size draws a slightly
-- wrong bar, a failed reqscript draws nothing.
-- Forward declaration. fullest_liquid below captures this name at
-- its own definition; the body lands further down, where the file
-- has always kept it. Without this line the capture is a permanent
-- nil, the retort's third row errors at render, and the Label
-- truncates it AND both footers: the bare-panel bug, in one line
-- of ordering.
local bank_value
-- THE CREDITABLE SET. A row exists only for a currency something
-- actually credits: the keys of tuning's FLUID_SPLIT, mirrored here
-- per this file's resilience doctrine. Adding a currency to
-- FLUID_SPLIT means adding it here.
--
-- COAL TAR NOW BANKS. It used to be a whole package output that only
-- ever paid outright, which is why the old note here grouped it with
-- crude, creosote, benzene and aniline as never drawing a row. Coal
-- going adaptive made TAR_COAL a FLUID_SPLIT key, and a bituminous
-- boulder credits 0.96 of a package: it banks every time and paid
-- nothing, invisibly, until this row existed. Measured on job 14.
-- Ordered by ROLE, not alphabetically, because the panel is read
-- top to bottom while a chain runs: the feedstock liquids first,
-- then what fractionating them yields, then everything that comes
-- from somewhere else entirely.
--
-- The six fraction rows arrived when FRACTION_SPLIT made the stills
-- conserve. Before that they paid one per cycle and banked nothing,
-- so there was nothing to show; now they credit fractions of a
-- package every run and a missing row hides real value.
--
-- SPLIT BY WHERE THEY BANK, since the distillations moved to the
-- still. PYRO_LIQUIDS are the retort's: the keys of tuning's
-- FLUID_SPLIT, what its burns credit. FRACTION_LIQUIDS are the still's:
-- the liquid keys of FRACTION_SPLIT, what its distillations credit.
-- LIQUIDS stays their union, for the flash, which watches every bank.
local PYRO_LIQUIDS = {
    'TAR', 'TAR_COAL', 'OIL_CRUDE',
    'VINEGAR_WOOD', 'VINEGAR_PLANT', 'AMMONIA',
    'OIL_BONE', 'OIL_TALLOW',
}
local FRACTION_LIQUIDS = {
    'TURPENTINE', 'CREOSOTE', 'BENZENE',
    'NAPHTHA', 'KEROSENE', 'OIL_LUBRICANT',
}
local LIQUIDS = {}
for _, c in ipairs(PYRO_LIQUIDS) do LIQUIDS[#LIQUIDS + 1] = c end
for _, c in ipairs(FRACTION_LIQUIDS) do LIQUIDS[#LIQUIDS + 1] = c end
-- Compound liquid names read qualifier-first in the reactions,
-- wood tar not tar wood, and the bank keys are the reversed
-- tokens. This flips them back, with the two odd ones named.
-- CRUDE is a qualifier like the rest: OIL_CRUDE reads "crude oil",
-- the same way OIL_BONE reads "bone oil". Without it the flip does
-- not fire and the row says "oil crude".
-- LUBRICATING joins CRUDE for the same reason: OIL_LUBRICANT
-- reads 'lubricating oil', not 'oil lubricating'.
local LIQUID_QUAL = { CRUDE = true, LUBRICATING = true,
                      WOOD = true, COAL = true, PLANT = true,
                      BONE = true, SHALE = true, PEAT = true,
                      TALLOW = true }
local function liquid_label(cur)
    -- Lubricant, not lubricating oil. A lubricant IS the substance;
    -- the longer form is the refinery cut's full name and it does
    -- not fit the name column beside plant vinegar. This fires
    -- BEFORE the qualifier flip, so whether LUBRICATING sits in
    -- LIQUID_QUAL below no longer matters either way.
    if cur == 'OIL_LUBRICANT' then return 'lubricant' end
    if cur == 'VINEGAR_WOOD' then return 'wood vinegar' end
    local base, qual = cur:match('^(.*)_([A-Z]+)$')
    if qual and LIQUID_QUAL[qual] then
        local s = string.lower(qual .. ' ' .. base):gsub('_', ' ')
        return s
    end
    local s = string.lower(cur):gsub('_', ' ')
    return s
end

-- ---- THE DISPLAY LAW ----
-- Every currency a furnace type can bank renders ALWAYS, zero
-- included. The row list is the documentation of what can bank
-- there; a row that appears only when nonzero teaches nothing and
-- confuses everyone. No caps, no overflow, no filtering.
local PURSES = { 'PITCH', 'BITUMEN' }
local PURSE_SET = {}
for _, p in ipairs(PURSES) do PURSE_SET[p] = true end

-- ---- THE FOOTERS ----
-- Tables rather than inline calls, so the row arithmetic below counts
-- them instead of carrying a hand written number that goes stale the
-- first time a line is added. That is the same reason the liquid and
-- purse counts are derived.
--
-- SOLID always. LIQUID only where liquid rows are drawn, which today
-- is the retort alone. The panel explained charcoal behaviour on every
-- furnace and said nothing at all about the liquids sitting above the
-- text, which is the half a player is most likely to misread: a bar
-- that fills and never pays looks broken until you know it is waiting
-- on a vessel.
local FOOT_SOLID = {
    'small runs fill these bars between drops',
    'large runs pay charcoal and char outright',
}
-- LENGTH IS LOAD BEARING. Usable width is the frame minus its border
-- minus the Label's left inset, 42 today. A longer line WRAPS, the row
-- count below does not see the extra row, and the panel comes up one
-- short and grows a scrollbar. That is exactly what the first version
-- of this table did at 47 characters. The two solid footers are 40 and
-- 41, which is the band the panel was sized to; stay in it.
--
-- The height calculation now counts wrapped rows anyway, so this is
-- belt and braces rather than the only defence. Both, because a
-- scrollbar on this panel has now been shipped three times.
local FOOT_LIQUID = {
    'excess liquids seek more vessels or bank',
    'drain retort fills vessels with overflow',
}

-- The still's and the kitchen's, under the LENGTH IS LOAD BEARING rule
-- above: 41 and 39, 35 and 35. The still's second line is the retort's
-- own, since the still now drains the same way (making-fuel-drain-key).
local FOOT_STILL = {
    'fractions of a unit wait for the next run',
    'drain still fills vessels with overflow',
}
local FOOT_KITCHEN = {
    'each boil credits part of a boulder',
    'crude to bitumen, the tars to pitch',
}

-- ---- WHICH FOOTERS, PER BUILDING ----
-- Chosen per ROW SET rather than inferred from the kinds of row drawn,
-- so each building explains its own mechanism: the solid footers talk
-- about charcoal, right at a kiln and wrong at a still. Filled in below
-- the ceiling's comment, once every set exists; declared here so
-- lines_for can see it.
local FOOTERS = {}

-- ---- THE ROW CEILING ----
-- The Label's line count is fixed when its token list is PARSED, not
-- when the text callbacks run. `token.line` is documented as reserved
-- for internal use, and it is assigned once, at construction. So the
-- widget always renders exactly this many rows whatever a given
-- furnace fills, and the frame must be tall enough for ALL of them or
-- the Label scrolls.
--
-- The old count was a formula, `3 + liquids + purses + footers`, which
-- added the wood furnace's THREE solid rows to the retort's full
-- liquid block. No furnace has both. That one surplus row is a blank
-- line at the bottom of the retort and one row of content the frame
-- had no room for, which is where the scrollbar came from.
--
-- Counted off the row sets instead, so it cannot drift from them
-- again: whatever the widest building actually draws IS the ceiling.
-- The footers come from FOOTERS, per set, and the draw loop in
-- lines_now reads the same table, so the height and the content still
-- agree. A tank-only panel at the forge carries no footer at all, which
-- would otherwise explain charcoal and ash where neither banks.
local function lines_for(rows)
    local n = 0
    for _, cur in ipairs(rows) do
        if cur == 'LIQUID' then
            n = n + #PYRO_LIQUIDS
        elseif cur == 'FRACTIONS' then
            n = n + #FRACTION_LIQUIDS
        else
            n = n + 1
        end
    end
    for _, block in ipairs(FOOTERS[rows] or {}) do n = n + #block end
    return n
end

-- The fuel tank line sits above the rows on a furnace with a burner
-- fitted, so the sets that can carry a tank count one more toward the
-- ceiling. The wood furnace and the retort burn no fuel and never
-- carry one. set_rows refuses anything over MAX_ROWS, so a ceiling
-- that forgot the tank line would refuse the tanked kiln outright.
-- A building that banks nothing but can carry a tank, the glass
-- furnace and the metalsmith's forge, shows the tank line alone. An
-- EMPTY set rather than nil, because nil means hide the panel.
local ROWS_TANK_ONLY = {}

local TANKABLE = { [ROWS_GENERIC] = true, [ROWS_SMELTER] = true,
                   [ROWS_TANK_ONLY] = true }

-- Every set's footers. The five sets that existed before keep exactly
-- the footers they drew then; the still and the kitchen carry their own.
FOOTERS[ROWS_WOOD]      = { FOOT_SOLID }
FOOTERS[ROWS_GENERIC]   = { FOOT_SOLID }
FOOTERS[ROWS_SMELTER]   = { FOOT_SOLID }
FOOTERS[ROWS_RETORT]    = { FOOT_SOLID, FOOT_LIQUID }
FOOTERS[ROWS_TANK_ONLY] = {}
FOOTERS[ROWS_STILL]     = { FOOT_STILL }
FOOTERS[ROWS_KITCHEN]   = { FOOT_KITCHEN }

local MAX_ROWS = 0
for _, rows in ipairs({ ROWS_WOOD, ROWS_GENERIC, ROWS_SMELTER,
                        ROWS_RETORT, ROWS_TANK_ONLY, ROWS_STILL,
                        ROWS_KITCHEN }) do
    local n = lines_for(rows) + (TANKABLE[rows] and 1 or 0)
    if n > MAX_ROWS then MAX_ROWS = n end
end

-- Purses read their own keys directly: the ghost routes by product
-- side now, BANK_PITCH and BANK_BITUMEN, and the transitional per
-- tar fold is gone with the keys it folded.
local function purse_value(cur)
    return bank_value(cur)
end

-- What one whole unit of each currency pays out as, for the footer.
-- These mirror the ghost's ladder and are display text only; the
-- numbers that matter live in tuning, not here.
local LABEL = {
    CHARCOAL = 'charcoal',
    ASH      = 'ash',
    KINDLING = 'kindling',
    COKE     = 'coke',
}

-- ==========================================
-- RESOLVING THE OPEN FURNACE
-- ==========================================
-- Returns the row list for the building on the open sheet, or nil
-- when it neither banks nor carries a tank. Everything is
-- pcall wrapped: a nil anywhere means hide, never an error painted
-- over the player's screen.
local function rows_for_open_building()
    local ok, rows = pcall(function()
        local bld = dfhack.gui.getSelectedBuilding(true)
        if not bld then return nil end
        local banked = nil
        if bld:getType() == df.building_type.Furnace then
            if bld.type == df.furnace_type.Custom then
                local def = df.building_def.find(bld.custom_type)
                banked = def and CUSTOM_ROWS[def.code] or nil
            else
                banked = FURNACE_ROWS[bld.type]
            end
        elseif bld:getType() == df.building_type.Workshop then
            banked = WORKSHOP_ROWS[bld.type]
        end
        if banked then return banked end
        -- Banks nothing, but a fitted tank is still worth showing: the
        -- glass furnace, and the metalsmith's forge, which is a workshop
        -- rather than a furnace and was never reached before. Read off
        -- the same table tank_line reads.
        local tanks = _G.making_fuel_tanks
        if tanks and tanks[bld.id] then return ROWS_TANK_ONLY end
        return nil
    end)
    if not ok then return nil end
    return rows
end

-- Assignment, not a fresh local: fills the forward declaration
-- above so every earlier capture points at this body.
bank_value = function(currency)
    -- ---- THE STILL'S SPIRIT ----
    -- Not the ghost's bank: the still watcher keeps it per still and
    -- publishes the table (see DATA SOURCE). Answered here, the one
    -- function every row, flash and pen already reads through, so the
    -- bar, the flash and the overfill pen all work with no other edit.
    if currency == 'SPIRIT' then
        local carry, sbid = _G.making_fuel_spirit_carry, nil
        pcall(function()
            local bld = dfhack.gui.getSelectedBuilding(true)
            if bld then sbid = bld.id end
        end)
        return (carry and sbid and tonumber(carry[sbid])) or 0
    end

    local bank = _G.refinish_fuel_bank
    if not bank then return 0 end

    -- Banks are per furnace now, so the sheet shows the furnace it is
    -- open on. Same key format the ghost and the hijacker write:
    -- 'BANK_<currency>@<building id>'. getSelectedBuilding is already
    -- how rows_for_open_building decides which rows to show, so the
    -- panel was always furnace scoped; only the numbers were not.
    local bid = nil
    pcall(function()
        local bld = dfhack.gui.getSelectedBuilding(true)
        if bld then bid = bld.id end
    end)
    if bid then
        local v = bank['BANK_' .. currency .. '@' .. tostring(bid)]
        if v then return tonumber(v) or 0 end
        -- A furnace that has never banked reads zero rather than
        -- falling through to a stale global balance.
        return 0
    end

    -- No furnace identified: the unscoped key, which is what a job
    -- with no holder writes.
    return tonumber(bank['BANK_' .. currency]) or 0
end

-- ==========================================
-- THE FUEL TANK LINE
-- ==========================================
-- Claims the top slot, above the bank rows, on a furnace with a burner
-- fitted, and draws nothing anywhere else, so a furnace without a tank
-- loses no row to it. Returns nil when there is nothing to draw, and
-- that nil is the ONE test both lines_now and overlay_onupdate use, so
-- the height and the content are decided by the same question.
--
-- Read straight off _G.making_fuel_tanks, which making-fuel-tank-fuel
-- publishes for exactly this: no reqscript on a per frame path.
--
-- The cost of a job is MIRRORED from tuning, the same way this file
-- mirrors CINDERS_PER_CHARCOAL and BREEZE_PER_COKE rather than reading
-- them. It is FUEL_BULK_PER_SMELTING, 4 today. If that moves, this
-- moves with it.
local TANK_UNITS_PER_JOB = 4

local function tank_line()
    local tanks = _G.making_fuel_tanks
    if not tanks then return nil end
    local bid = nil
    pcall(function()
        local bld = dfhack.gui.getSelectedBuilding(true)
        if bld then bid = bld.id end
    end)
    if not bid then return nil end
    local t = tanks[bid]
    if not t then return nil end

    local units = tonumber(t.units) or 0
    local jobs  = math.floor(units / TANK_UNITS_PER_JOB)

    -- ---- FULLNESS, NOT CHARGE ----
    -- The jobs field already says what the charge is worth, so the
    -- number shows how FULL the tank is: volume over capacity. It used
    -- to show the charge, and that read as over capacity whenever light
    -- fuel was in the mix. MEASURED: a tank at exactly 166 of 166 volume
    -- showed 169, because a light unit carries four charge in one volume
    -- while capacity is a volume (see HOW MUCH A TANK HOLDS in
    -- making-fuel-tank-fuel.lua).
    --
    -- Counted the way a fill counts room, floor(capacity - volume), so
    -- the panel reads full exactly when the tank refuses another unit.
    -- A mixture burns volume down in fractions, and 165.4 has no room
    -- for a whole unit, so it must read 166/166, not 165/166.
    --
    -- Capacity comes from tank-fuel's own capacity(), read off the
    -- vanilla cauldron, through the api it publishes. Without the api
    -- the charge is shown as before.
    local fill = tostring(units)
    pcall(function()
        local api = _G.making_fuel_tank_api
        local cap = api and api.capacity and api.capacity()
        if cap then
            local volume = tonumber(t.volume) or units
            local room   = math.max(0, math.floor(cap - volume))
            fill = string.format('%d/%d', cap - room, cap)
        end
    end)

    -- Same columns as a bank row: the 18 wide name, then a 12 wide
    -- field where a bank row draws its bar, then the fill. 40 of 43
    -- usable columns.
    local text = string.format('%-18s %-12s  %7s',
        'fuel tank',
        string.format('%d job%s', jobs, jobs == 1 and '' or 's'),
        fill)

    -- Red the moment the tank can no longer pay a whole job, because
    -- that is exactly when this furnace goes back to collecting solid
    -- fuel. Cyan otherwise, so the tank never reads as a bank row.
    local pen = (units >= TANK_UNITS_PER_JOB) and COLOR_LIGHTCYAN
        or COLOR_LIGHTRED
    return { t = text, p = pen }
end

-- ==========================================
-- THE WIDGET
-- ==========================================
MakingFuelBankReadout = defclass(MakingFuelBankReadout, overlay.OverlayWidget)
MakingFuelBankReadout.ATTRS = {
    desc = 'Making Fuel bank readout',
    -- POSITIONING RULE: never over gameplay. Positive coords anchor
    -- to the top left, same corner the building sheet anchors to, so
    -- sheet relative placement holds on any monitor size; y clears
    -- the top bar. Players drag it in gui/overlay and the position
    -- persists per player, so this is a starting point, not law.
    -- Negative x anchors from the RIGHT edge, same edge the sheet
    -- anchors to, so this holds its distance from the sheet on any
    -- monitor. The number is sheet width plus this panel plus a gap;
    -- nudge once if your sheet width differs, or just drag it in
    -- gui/overlay and the drag persists per player.
    default_pos = { x = -132, y = 5 },
    default_enabled = true,
    -- The shorter BUILDING prefix, which the furnace work OBSERVED
    -- working: matching is by prefix. It was once narrowed to /Furnace
    -- to spare the widget on other sheets, which also shut out the
    -- metalsmith's forge, a WORKSHOP, whose sheet sits under its own
    -- segment. That segment is recorded nowhere, so this uses the
    -- prefix that is measured rather than guessing one. On any other
    -- building sheet rows_for_open_building returns nil and visible()
    -- hides the panel.
    viewscreens = 'dwarfmode/ViewSheets/BUILDING',
    version = '1.1',

    -- The default throttle is FIVE SECONDS. The panel has to resize
    -- the moment the player opens a different furnace, so it asks to
    -- be called at the maximum rate. The work per call is one integer
    -- compare in the common case, and the widget only runs at all
    -- while a building sheet is open, so this is not a frame cost that
    -- shows up anywhere.
    overlay_onupdate_max_freq_seconds = 0,

    -- OUTER size: the header line, the widest furnace's rows, and the
    -- 2 the border consumes. MAX_ROWS is counted off the row sets, so
    -- adding a currency, a purse or a footer moves this on its own and
    -- a hand count can never fall behind the content again.
    --
    -- This is a CEILING, not a fit. The Label always renders MAX_ROWS
    -- rows, so shorter furnaces draw their few and leave blanks below.
    -- Sizing the frame to what a furnace actually uses does not work:
    -- the line count is fixed at parse time, so a shorter frame just
    -- scrolls the same rows. Undersizing this produced the scrollbar
    -- squish three times, the last of which was exactly one row.
    frame = { w = 45, h = 1 + MAX_ROWS + 2 },
    frame_style = gui.FRAME_BOLD,
    frame_background = gui.CLEAR_PEN,

    visible = function()
        if not _G.refinish_active then return false end
        if not _G.refinish_fuel_bank then return false end
        -- Interference guard. Negative x is a right-edge offset and
        -- the framework does not clamp, so on an interface grid
        -- narrower than the offset this panel would walk into the
        -- map. An overlay that cannot fit HIDES; it never overlaps
        -- gameplay on someone else's monitor.
        local sw = dfhack.screen.getWindowSize()
        if sw and sw < 104 then return false end
        -- Stand down under a modal child. The magnifying glass
        -- pushes JobDetails ON TOP of the furnace sheet without
        -- replacing it, so the viewscreens prefix still matches
        -- Furnace and this panel keeps its z-order over the popup.
        --
        -- THE LAST ENTRY IS THE TOP OF THE STACK. getCurFocus(true)
        -- returns parents too, so a furnace always reports several
        -- strings and only the last says what is drawn above us.
        -- Measured with the job list open:
        --   dwarfmode/ViewSheets/BUILDING/Furnace/Custom/Tasks
        --   dwarfmode/ViewSheets/BUILDING/Furnace/Custom/Items
        --   dwarfmode/JobDetails/BUILDING_TASK_LIST
        --
        -- Inline, NOT a local function: this block is inside a TABLE
        -- CONSTRUCTOR, where `local` is a parse error and the whole
        -- script fails to load.
        local ok, covered = pcall(function()
            local st = dfhack.gui.getCurFocus(true) or {}
            local top = st[#st]
            if not top then return false end
            return not top:find('ViewSheets/BUILDING', 1, true)
        end)
        if ok and covered then return false end
        return rows_for_open_building() ~= nil
    end,
}

function MakingFuelBankReadout:init()
    -- Label tokens whose text is a FUNCTION re-evaluate every render,
    -- which is the whole trick: a job completes while the sheet is
    -- open and the numbers move in front of the player with no
    -- refresh machinery in this file at all.
    -- ---- PAYOUT PROGRESS ROWS ----
    -- The bank drains to its remainder at every completion, so
    -- between jobs charcoal always holds under one cinder and ash
    -- under one bar. The only readable meaning of the number is HOW
    -- CLOSE THE NEXT DROP IS, so each row is a payout item with a
    -- fill bar toward one of it: cinder first, because on small
    -- inputs it is what actually falls out of the furnace.
    --
    -- next_step: charcoal pays on the cinder ladder at quarter
    -- steps; ash and kindling only in wholes. Display truth mirrors
    -- ladder truth or the panel teaches the wrong lesson.
    -- ---- WHAT THIS PANEL TEACHES ----
    -- The bank is the REMAINDER PURSE, not the product source. A
    -- completing job pays what its inputs are worth PLUS this purse,
    -- greedily in the largest coins: char boulder 4, charcoal 1,
    -- cinder a quarter; ash and kindling in wholes. So the purse can
    -- never hold a full coin between jobs, big drops are explained
    -- by big inputs, and the legend line carries that whole model.
    --
    -- The purse is GLOBAL. Every furnace, the retort, and the
    -- hijacked vanilla burns draw the same three pools, which is why
    -- the header says so: numbers moving while this furnace idles is
    -- the system working.
    --
    -- Mash and kitchen cinders are hijacker chance spawns, not bank
    -- draws. They are deliberately absent; putting them here would
    -- teach a mechanism that does not exist.
    -- ---- ROWS ARE THE NEXT DROP, NOT THE POOL ----
    -- A bar labelled with the pool that fills toward a different
    -- item teaches nothing. Each row is named for the exact thing
    -- that will fall out of the furnace and counts DOWN to it. The
    -- pool names appear nowhere; the player never needed them.
    -- COKE MIRRORS CHARCOAL. Both ladders bank in their middle rung
    -- and pay their fraction in the sub unit, so both rows must be
    -- METERED in that sub unit or the number lies about what the
    -- next payout will be. A coke row on a 1.0 step can never read
    -- past 0.25, because the ghost flushes to breeze the moment the
    -- bank crosses a quarter; on a 0.25 step it reads 0.00 to 1.00
    -- breeze, which is the payout actually being waited on.
    --
    -- 0.25 is 1 / BREEZE_PER_COKE, mirrored from tuning the same way
    -- charcoal's 0.25 mirrors CINDERS_PER_CHARCOAL. Both are 4 today.
    -- If either constant moves, its step here moves with it.
    -- ASH_COAL sits at 1.0 like ASH: neither has a sub-unit
    -- rung, so anything under one whole bar banks and the row
    -- counts toward a bar rather than toward a crumb.
    -- The two solid fractions sit at 1.0 like ASH and ASH_COAL:
    -- no sub-unit rung, so the row counts toward a whole boulder.
    -- SPIRIT counts toward one whole unit of the ethanol that will go
    -- into the next vessel, so it steps in wholes like ash.
    local STEP = { CHARCOAL = 0.25, ASH = 1.0, KINDLING = 1.0,
                   COKE = 0.25, ASH_COAL = 1.0,
                   NAPHTHALENE = 1.0, ANTHRACENE = 1.0,
                   SPIRIT = 1.0 }
    local NEXT = { CHARCOAL = 'cinder',
                   ASH      = 'ash',
                   KINDLING = 'kindling',
                   COKE     = 'breeze',
                   ASH_COAL = 'coal ash',
                   NAPHTHALENE = 'naphthalene',
                   ANTHRACENE  = 'anthracene',
                   SPIRIT      = 'ethanol' }
    -- SOLIDS is what observe_banks walks for the green flash. A
    -- currency with a row but no entry here draws correctly and
    -- never flashes, which is how the coke row shipped.
    -- SPIRIT rides this list for the flash only; it is drawn as its own
    -- kind (see lines_for).
    local SOLIDS = { 'CHARCOAL', 'ASH', 'KINDLING', 'COKE',
                     'ASH_COAL', 'NAPHTHALENE', 'ANTHRACENE', 'SPIRIT' }

    -- One bar, one line. Shared by solid and liquid rows so both
    -- kinds teach with the same picture.
    local function bar_line(cur)
        local step = STEP[cur] or 1.0
        local label = NEXT[cur]
            or (PURSE_SET[cur] and ('' .. string.lower(cur)))
            or ('' .. liquid_label(cur))
        local raw = PURSE_SET[cur] and purse_value(cur)
            or bank_value(cur)
        -- ---- THE NUMBER IS THE BANK, IN THE ROW'S OWN UNIT ----
        -- The countdown described the fraction toward the next unit,
        -- which was the whole story when a run could not bank more
        -- than one. A run can now earn far more than it can bottle,
        -- and a bank holding 45 read '0.85 to go' and hid the 45,
        -- which is the state a player most needs to see.
        --
        -- Divided by the step, so 1.00 means one of whatever the row
        -- actually pays, on every row. Charcoal banks in charcoal but
        -- pays in cinders at a quarter each, so a raw 0.43 charcoal
        -- showed as a confusing quarter scale; as cinders it is 1.74,
        -- and 4.00 is a charcoal and 16.00 is a char. Everything
        -- overfills at 1.
        --
        -- Under one the bar fills as it did. At one or more it sits
        -- FULL, because there is nothing left to fill toward, and a
        -- full bar beside a number above one reads as overfilled at a
        -- glance. Also four characters narrower than the countdown.
        local shown = raw / step
        local fill  = (shown >= 1) and 10
            or math.floor((shown % 1) * 10 + 0.0001)
        -- 18, not 13. The bar and the number are FIXED width, 12
        -- and 6, so the whole row is name + 20 against 43 usable
        -- columns inside a 45 wide frame. At 13 the row used 33
        -- and left ten columns doing nothing while plant vinegar
        -- sat exactly on the limit; at 18 it uses 38 and still
        -- has five spare.
        return string.format('%-18s [%s%s]  %6.2f',
            label,
            string.rep(string.char(219), fill),
            string.rep(string.char(250), 10 - fill),
            shown)
    end

    -- ---- THE FLASH ----
    -- A bank that just grew turns its row light green for FLASH_MS,
    -- then falls back on its own. The clock is wall time from
    -- getTickCount, so pausing right after a run cannot freeze a
    -- green row. First sight of a currency records silently; growth
    -- that happened while the sheet was closed flashes once on the
    -- next open, which is the feature working: what moved since you
    -- last looked.
    local FLASH_MS = 900
    local last_raw, flash_until = {}, {}

    local function observe_banks()
        -- Any movement flashes: growth AND payout. A bank that just
        -- paid drops by a whole coin, and that drop is the moment
        -- worth catching the eye with, per the design ask.
        local now = dfhack.getTickCount()
        for _, set in ipairs({ SOLIDS, LIQUIDS, PURSES }) do
            for _, c in ipairs(set) do
                local raw = PURSE_SET[c] and purse_value(c)
                    or bank_value(c)
                local seen = last_raw[c]
                if seen ~= nil and math.abs(raw - seen) > 1e-9 then
                    flash_until[c] = now + FLASH_MS
                end
                last_raw[c] = raw
            end
        end
    end

    local function pen_for(cur)
        -- An overfilled bank holds output that is earned and waiting
        -- on containers, so its row stays green while that is true
        -- rather than for FLASH_MS. Green, a full bar and a number
        -- above one is the overfill state, readable without a legend.
        local raw = PURSE_SET[cur] and purse_value(cur) or bank_value(cur)
        local step = ({ CHARCOAL = 0.25, ASH = 1.0, KINDLING = 1.0 })[cur]
                     or 1.0
        if raw and raw >= step then return COLOR_LIGHTGREEN end

        local until_ms = flash_until[cur]
        if until_ms and dfhack.getTickCount() < until_ms then
            return COLOR_LIGHTGREEN
        end
        return nil
    end

    -- ---- LINES, BUILT ONCE PER RENDER PASS ----
    -- Back on the file's own proven ground: Label tokens re-evaluate
    -- FUNCTION text every render, and the token spec allows pen to
    -- be a callback too, so the skeleton below is built once and
    -- never touched again. No setText, no render hooks, no super
    -- calls: every construct that shipped blank is gone.
    --
    -- The first slot's text callback rebuilds this cache; every
    -- other callback only reads it, so one render pass sees one
    -- consistent picture. Pens are computed at build, which
    -- quantises the flash to the start of the pass: invisible at
    -- frame rate. Bars carry COLOR_WHITE explicitly because what a
    -- pen callback returning nil does is unspecified, and this
    -- panel is done shipping on unspecified behaviour.
    local cache = nil
    local function lines_now(rebuild)
        if cache and not rebuild then return cache end
        local built = {}
        local function line(text, pen)
            built[#built + 1] = { t = text, p = pen }
        end
        local ok = pcall(function()
            observe_banks()
            local rows = rows_for_open_building()
            if not rows then return end
            -- The tank claims the top slot, and only where one exists.
            -- overlay_onupdate counts it through the same tank_line,
            -- so the height and the content cannot disagree.
            local tl = tank_line()
            if tl then line(tl.t, tl.p) end
            for _, cur in ipairs(rows) do
                if cur == 'LIQUID' then
                    for _, c in ipairs(PYRO_LIQUIDS) do
                        line(bar_line(c), pen_for(c) or COLOR_WHITE)
                    end
                elseif cur == 'FRACTIONS' then
                    for _, c in ipairs(FRACTION_LIQUIDS) do
                        line(bar_line(c), pen_for(c) or COLOR_WHITE)
                    end
                else
                    line(bar_line(cur), pen_for(cur) or COLOR_WHITE)
                end
            end
            -- The footers this building's set carries (WHICH FOOTERS, PER
            -- BUILDING), the same table lines_for counts.
            for _, block in ipairs(FOOTERS[rows] or {}) do
                for _, s in ipairs(block) do line(s, COLOR_DARKGREY) end
            end
        end)
        if not ok then
            built = { { t = 'bank rows: ?', p = COLOR_WHITE } }
        end
        cache = built

        -- NO ADAPTIVE HEIGHT HERE, deliberately, and this is the third
        -- time the panel has been sized wrong so it is worth the
        -- paragraph. Shrinking the frame to the rows a furnace
        -- actually fills does not shorten the panel: the Label still
        -- holds MAX_ROWS parsed lines, so a shorter frame scrolls them
        -- instead of dropping them. That is what put a scrollbar on
        -- the retort. Changing the line count needs setText, which
        -- rebuilds the token list, and this file does not do that.
        return cache
    end

    -- Slot count is the frame arithmetic from ATTRS, derived from
    -- the tables so adding a currency never needs a hand count:
    -- max solids, every liquid, every purse, two footers.
    local function text_at(i)
        return function()
            local e = lines_now(i == 1)[i]
            return e and e.t or ''
        end
    end
    local function pen_at(i)
        return function()
            local e = lines_now(false)[i]
            return e and e.p or COLOR_WHITE
        end
    end

    -- Names the furnace this panel is reading. The line used to say
    -- "shared across all furnaces", which was true before the banks
    -- became per furnace and has been wrong since. A subtitle that
    -- contradicts the numbers under it is worse than no subtitle.
    --
    -- A function rather than a string, the same as every row below,
    -- because the widget is built once and the open building changes
    -- underneath it.
    --
    -- getName gives the custom def's name for a retort and the vanilla
    -- name for the rest. The id is what separates two of the same kind,
    -- and it is the same id the bank keys use, so a player reading
    -- 'BANK_OIL_BONE@5' in the log can find furnace 5 on screen.
    local function subtitle()
        local s = nil
        pcall(function()
            local bld = dfhack.gui.getSelectedBuilding(true)
            if not bld then return end
            local name = dfhack.buildings.getName(bld)
            if name and name ~= '' then
                s = string.format('  %s [ID:%d]', tostring(name), bld.id)
            else
                s = string.format('  furnace [ID:%d]', bld.id)
            end
        end)
        return s or '  this furnace'
    end

    -- ---- THE SKELETON IS A FUNCTION OF THE ROW COUNT ----
    -- The Label's line count is fixed when its token list is PARSED,
    -- not when the text callbacks run: `token.line` is documented as
    -- reserved for internal use and is assigned once, at
    -- construction. So a callback can change what a row SAYS but
    -- never how many rows there are, and shrinking the frame alone
    -- just scrolls the same lines. Resizing to content therefore
    -- means rebuilding this list.
    -- The title says what the panel is reading. The still is a
    -- workshop, not a furnace, and banks spirit, not fuel. A function,
    -- like the subtitle, because the open building changes underneath
    -- a widget that is built once.
    local function title()
        local t = 'furnace bank'
        pcall(function()
            local rows = rows_for_open_building()
            if rows == ROWS_STILL then
                t = 'still bank'
            elseif rows == ROWS_KITCHEN then
                t = 'kitchen bank'
            end
        end)
        return t
    end

    local function build_tokens(n)
        local t = {
            { text = title, pen = COLOR_YELLOW },
            { text = subtitle, pen = COLOR_DARKGREY },
        }
        for i = 1, n do
            t[#t + 1] = NEWLINE
            t[#t + 1] = { text = text_at(i), pen = pen_at(i) }
        end
        return t
    end

    -- ---- REBUILT ON SHAPE CHANGE, NOT ON RENDER ----
    -- This is `setText`, which this file swore off after it shipped
    -- blank, so it is worth saying exactly how this differs. That
    -- failure was setText on the render path with a nil upvalue
    -- underneath it. This runs from overlay_onupdate, which is off
    -- the render path entirely, and only when the ROW COUNT changes,
    -- which is once when the player opens a different kind of
    -- furnace. A steady panel never calls it.
    --
    -- Guarded so a failure is a stale size rather than a blank panel:
    -- if anything here throws, the previous token list and frame are
    -- still in place and still correct for the previous furnace.
    self.rows_built = MAX_ROWS
    self.set_rows = function(n)
        if type(n) ~= 'number' or n < 1 or n > MAX_ROWS then return end
        if n == self.rows_built then return end
        local ok = pcall(function()
            self.subviews.bank_body:setText(build_tokens(n))
            self.frame.h = 1 + n + 2
        end)
        if ok then self.rows_built = n end
    end

    self:addviews{
        widgets.Label{
            view_id = 'bank_body',
            frame = { t = 0, l = 1 },
            text = build_tokens(MAX_ROWS),
        },
    }
end

-- ---- THE RESIZE ----
-- Off the render path, throttle set to 0 above so it lands the frame
-- the sheet opens on. lines_for is the same counter the ceiling is
-- derived from, so the panel's height and its content can never be
-- computed two different ways.
--
-- Does nothing when no banking furnace is open: `visible` already
-- hides the panel there, and leaving the last size alone means
-- reopening the same furnace needs no rebuild at all.
function MakingFuelBankReadout:overlay_onupdate()
    local rows = rows_for_open_building()
    if not rows then return end
    -- One more slot when this furnace carries a tank, decided by the
    -- same tank_line that lines_now draws from. Installing a burner
    -- while the sheet is open changes the count by one and the panel
    -- rebuilds here, off the render path, like any other shape change.
    local n = lines_for(rows) + (tank_line() and 1 or 0)
    if self.set_rows then self.set_rows(n) end
end

OVERLAY_WIDGETS = { banks = MakingFuelBankReadout }