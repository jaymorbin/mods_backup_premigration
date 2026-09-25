-- making-fuel-hijack-probe.lua
-- ==========================================
-- JOB SURVEY PROBE
-- ==========================================
-- Answers two mechanical questions per job type, and nothing else.
--
--   1. Can the INPUT be read while the job runs?
--   2. Is the OUTPUT findable when the job completes?
--
-- Both were true for MakeCharcoal and ConstructBlocks, which is what
-- made the vanilla charcoal rework possible. Neither is guaranteed
-- for anything else, and a job failing either one needs a different
-- approach rather than a hopeful attempt at the same one.
--
-- USAGE
--   making-fuel-hijack-probe on      start
--   making-fuel-hijack-probe off     stop and print the report
--   making-fuel-hijack-probe report  print without stopping
--
-- Nothing is created, moved, removed or modified anywhere in here.
--
-- WHAT CHANGED FROM BUILD P1
--   P1 looked only for WOOD items and only inside a building, which
--   was all MakeCharcoal needed. Dig has no building and consumes no
--   items at all, so it returned nothing useful. This build reads ANY
--   attached item and finds output on the ground as well as in a
--   workshop, and it tallies results per job type instead of leaving
--   the reading to be done by eye across a long log.
-- ==========================================

local BUILD = 'P2'

local eventful   = require('plugins.eventful')
local repeatUtil = require('repeat-util')
local utils      = require('utils')

local EVENT_KEY = 'refinish_hijack_probe'
local POLL_KEY  = 'refinish_hijack_probe_poll'

-- How far from job.pos to look for output when there is no building.
--
-- Nine wide and one z level each way. Three was not enough: felled
-- logs land well outside it, which the branch spawner established the
-- hard way before this probe existed. Below matters because things
-- fall; above matters because a tree being cut drops from higher up.
local GROUND_RADIUS = 9
local GROUND_Z      = 1

-- ---- LOG IDENTITY, DECLARED HERE ----
-- RM core does not know this module exists and must never have to, so
-- the probe states its own system and subsystem. Guarded reqscript: a
-- bare top level one is a hard load time dependency.
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'HIJACK_PROBE'
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
-- SUBJECT is the correlation slot: JOB for a finished job's findings,
-- REPORT for the survey table, START and STOP.
--
-- The findings are INFO: the probe only runs when started by hand, and
-- those lines are what it was started for.
--
-- This replaces a log() that wrote bare untagged lines under the PROBE
-- prefix, and printed them to the console when RM was not loaded.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- The probe is only ever typed at the console, so the report and the
-- start and stop lines are also printed: see answer() below. The
-- findings arrive later, as jobs complete, so they go to the log
-- alone.
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

-- ---- THE ANSWER TO A TYPED COMMAND ----
-- Printed as is, since the report is a table and a prefix on every row
-- would break its columns, and logged, because everything goes in the
-- log.
local function answer(typ, msg, subject)
    print(msg)
    log(typ, msg, subject)
end

-- ==========================================
-- WHAT TO WATCH
-- ==========================================
-- Every name goes through pcall so a job type absent from this DF
-- version is skipped rather than taking the table down. SplitLog was
-- found that way: it does not exist.
-- ==========================================
local WATCH = {}

local function watch(name)
    pcall(function()
        local t = df.job_type[name]
        if t then WATCH[t] = name end
    end)
end

-- Vanilla custom reactions are all one job type, so they cannot be
-- told apart by job_type. The discriminator is the reaction_name
-- string. These matter more than they look: they have real
-- df.reaction objects, so the GHOST can swap them the way it swaps
-- the module's own, with nothing deleted.
local WATCH_RXN = {}

local function watch_rxn(code)
    WATCH_RXN[code] = true
end

-- ==========================================
-- THE SURVEY LIST
-- ==========================================
-- Replace wholesale. Kept apart from the machinery above so swapping
-- it touches nothing else.
-- ==========================================
-- DIG (PRODUCTIVE)
watch('Dig')
watch('CarveUpwardStaircase')
watch('CarveDownwardStaircase')
watch('CarveUpDownStaircase')
watch('CarveRamp')
watch('DigChannel')
watch('CarveTrack')

-- STRANGE (PRODUCTIVE*)
watch('StrangeMoodCrafter')
watch('StrangeMoodJeweller')
watch('StrangeMoodForge')
watch('StrangeMoodMagmaForge')
watch('StrangeMoodBrooding')
watch('StrangeMoodFell')
watch('StrangeMoodCarpenter')
watch('StrangeMoodMason')
watch('StrangeMoodBowyer')
watch('StrangeMoodTanner')
watch('StrangeMoodWeaver')
watch('StrangeMoodGlassmaker')
watch('StrangeMoodMechanics')

-- RAW COLLECTION (PRODUCTIVE)
watch('GatherPlants')
watch('CollectWebs')
watch('CollectSand')
watch('HarvestPlants')
watch('CollectClay')
watch('CollectHiveProducts')
watch('Fish')
watch('Hunt')
watch('HuntVermin')
watch('FellTree')

-- COLLECT WATER (PRODUCTIVE*)
watch('FillWaterskin')
watch('DrainAquarium')
watch('FillAquarium')
watch('FillPond')

-- MAKE (PRODUCTIVE)
watch('ConstructBuilding')
watch('ConstructDoor')
watch('ConstructFloodgate')
watch('ConstructBed')
watch('ConstructThrone')
watch('ConstructCoffin')
watch('ConstructTable')
watch('ConstructChest')
watch('ConstructBag')
watch('ConstructBin')
watch('ConstructArmorStand')
watch('ConstructWeaponRack')
watch('ConstructCabinet')
watch('ConstructStatue')
watch('ConstructBlocks')
watch('ConstructCatapultParts')
watch('ConstructBallistaParts')
watch('ConstructMechanisms')
watch('ConstructHatchCover')
watch('ConstructGrate')
watch('ConstructQuern')
watch('ConstructMillstone')
watch('ConstructSplint')
watch('ConstructCrutch')
watch('ConstructTractionBench')
watch('ConstructBoltThrowerParts')
watch('ConstructSlab')
watch('MakeRawGlass')
watch('MakeCrafts')
watch('MakeWeapon')
watch('MakeArmor')
watch('MakeHelm')
watch('MakePants')
watch('MakeGloves')
watch('MakeShoes')
watch('MakeShield')
watch('MakeCage')
watch('MakeChain')
watch('MakeFlask')
watch('MakeGoblet')
watch('MakeToy')
watch('MakeAnimalTrap')
watch('MakeBarrel')
watch('MakeBucket')
watch('MakeWindow')
watch('MakeTotem')
watch('MakeAmmo')
watch('MakeBackpack')
watch('MakeQuiver')
watch('MakeBallistaArrowHead')
watch('MakeTrapComponent')
watch('MakeCharcoal')
watch('MakeAsh')
watch('MakeLye')
watch('MakePotashFromLye')
watch('MakePotashFromAsh')
watch('MakeTool')
watch('MakeFigurine')
watch('MakeAmulet')
watch('MakeScepter')
watch('MakeCrown')
watch('MakeRing')
watch('MakeEarring')
watch('MakeBracelet')
watch('MakeGem')
watch('MakePipeSection')
watch('MakeCheese')
watch('ForgeAnvil')
watch('WeaveCloth')
watch('MintCoins')
watch('CutGems')
watch('CutGlass')
watch('SmeltOre')
watch('MeltMetalObject')
watch('ExtractMetalStrands')
watch('ButcherAnimal')
watch('MillPlants')
watch('ProcessPlants')
watch('ProcessPlantsVial')
watch('ProcessPlantsBarrel')
watch('PrepareMeal')
watch('PrepareRawFish')
watch('ExtractFromPlants')
watch('ExtractFromRawFish')
watch('ExtractFromLandAnimal')
watch('ShearCreature')
watch('MilkCreature')
watch('MixDye')
watch('SpinThread')
watch('AssembleSiegeAmmo')

-- IMPROVE (PRODUCTIVE*)
watch('EncrustWithGems')
watch('EncrustWithGlass')
watch('EncrustWithStones')
watch('StudWith')
watch('PolishStones')
watch('DecorateWith')
watch('DyeThread')
watch('DyeCloth')
watch('DyeLeather')
watch('SewImage')
watch('EngraveSlab')


-- ==========================================
-- VANILLA CUSTOM REACTIONS
-- ==========================================
-- Keyed on reaction code, not job type. Every one of these is
-- job_type.CustomReaction, so the WATCH table above cannot tell them
-- apart. There is no sub id on a job; the discriminator is the
-- reaction_name string.
--
-- WHY THIS LIST MATTERS MORE THAN THE OTHER ONE
--
-- These have real df.reaction objects, declared in reaction_other.txt
-- and its siblings. That means the GHOST can swap them, exactly the
-- way it swaps the module's own 122. No deletion, no output diffing,
-- nothing destroyed.
--
-- So the probe is asking a different question here. Not "can this be
-- hijacked" but "is this worth ghosting", which is a design question
-- rather than a mechanical one. The probe answers it by showing what
-- actually went in and what actually came out.
-- ==========================================
local WATCH_RXN = {
    ['MAKE_PEARLASH']            = true,
    ['MAKE_QUICKLIME']           = true,
    ['MAKE_MILK_OF_LIME']        = true,
    ['MAKE_PLASTER_POWDER']      = true,
    ['TAN_A_HIDE']               = true,
    ['RENDER_FAT']               = true,
    ['MAKE_SOAP_FROM_TALLOW']    = true,
    ['MAKE_SOAP_FROM_OIL']       = true,
    ['PRESS_OIL']                = true,
    ['PRESS_OIL_FRUIT']          = true,
    ['PRESS_HONEYCOMB']          = true,
    ['MILL_SEEDS_NUTS_TO_PASTE'] = true,
    ['BREW_DRINK_FROM_PLANT']    = true,
    ['BREW_DRINK_FROM_PLANT_GROWTH'] = true,
    ['MAKE_MEAD']                = true,
    ['PROCESS_PLANT_TO_BAG']     = true,
    ['MAKE_SHEET_FROM_PLANT']    = true,
    ['MAKE_SLURRY_FROM_PLANT']   = true,
    ['PRESS_PLANT_PAPER']        = true,
    ['MAKE_PARCHMENT']           = true,
}

local function watched(job)
    local n = WATCH[job.job_type]
    if n then return n end
    if job.job_type == df.job_type.CustomReaction then
        local code = tostring(job.reaction_name)
        if WATCH_RXN[code] then return 'rxn ' .. code end
    end
    return nil
end

-- ==========================================
-- FINDING OUTPUT
-- ==========================================
-- Two places a job can put things, and which applies is not something
-- to assume per job. A workshop job registers output in the
-- building's contained_items. A mining or gathering job drops it on
-- the ground near job.pos and has no building at all.
--
-- Both are handled the same way: a set of item ids before, the same
-- set after, and the difference is the output.
-- ==========================================
local function building_of(job)
    local b = nil
    pcall(function() b = dfhack.job.getHolder(job) end)
    return b
end

local function near(a, b, r)
    if not a or not b then return false end
    return math.abs(a.x - b.x) <= r
       and math.abs(a.y - b.y) <= r
       and math.abs(a.z - b.z) <= GROUND_Z
end

-- Highest item id in existence right now.
--
-- Set membership alone is not enough to say an item is new. Eight dig
-- jobs queued together all took their before picture before any
-- boulder existed, so when one dropped it looked new to all eight and
-- was reported eight times. DF item ids only ever increase, so
-- anything above the mark at snapshot time was genuinely created
-- after it, and nothing else was.
local function high_water()
    local hi = 0
    pcall(function()
        local all = df.global.world.items.all
        local n = #all
        if n > 0 then hi = all[n - 1].id end
    end)
    return hi
end

-- Returns a set of item ids and a label saying where it looked. The
-- label matters in the report: "no new items" means something very
-- different depending on whether it searched a workshop or a patch of
-- floor.
local function snapshot(job)
    local bld = building_of(job)
    local ids = {}

    if bld then
        pcall(function()
            for _, ci in ipairs(bld.contained_items) do
                if ci.item then ids[ci.item.id] = true end
            end
        end)
        return ids, 'building'
    end

    -- No building. Look on the ground around the job.
    --
    -- This walks items.all, which is expensive, so the caller takes it
    -- ONCE per job rather than every poll. Safe, because the question
    -- is only what APPEARED: something hauled away in the meantime
    -- leaves the set, it does not enter it.
    local pos = nil
    pcall(function() pos = job.pos end)
    if not pos then return ids, 'nowhere' end

    pcall(function()
        for _, item in ipairs(df.global.world.items.all) do
            if item.flags.on_ground and near(item.pos, pos, GROUND_RADIUS) then
                ids[item.id] = true
            end
        end
    end)
    return ids, 'ground'
end

-- ==========================================
-- READING INPUT
-- ==========================================
-- Every attached item, not just wood. P1 looked for WOOD only because
-- MakeCharcoal takes a log, which made it useless on every job that
-- takes something else or takes nothing.
--
-- A job with no attached items is a real and useful answer. Dig
-- consumes nothing: its input is the stone layer of the tile, which
-- is not an item, and there is no documented maps call that returns a
-- tile's material. That is a finding, not a failure.
-- ==========================================
local function read_inputs(job)
    local out = {}
    pcall(function()
        for _, iref in ipairs(job.items) do
            local it = iref.item
            if it then
                local rec = { id = it.id }
                pcall(function() rec.type = df.item_type[it:getType()] end)
                pcall(function() rec.vol = it:getVolume() end)
                pcall(function() rec.stack = it.stack_size end)
                pcall(function()
                    local m = dfhack.matinfo.decode(it)
                    if m then
                        rec.token = m:getToken()
                        rec.dens  = m.material.solid_density
                    end
                end)
                pcall(function()
                    rec.desc = dfhack.items.getDescription(it, 0)
                end)
                table.insert(out, rec)
            end
        end
    end)
    return out
end

local function describe_item(item)
    local d, t, tok, vol = '?', -1, '?', -1
    pcall(function() d = dfhack.items.getDescription(item, 0) end)
    pcall(function() t = item:getType() end)
    pcall(function() vol = item:getVolume() end)
    pcall(function()
        local m = dfhack.matinfo.decode(item)
        if m then tok = m:getToken() end
    end)
    return string.format('id=%d %s  type=%s  vol=%s  %s',
        item.id, tostring(d), tostring(df.item_type[t]),
        tostring(vol), tok)
end

-- ==========================================
-- STATE
-- ==========================================
local seen = {}

-- [name] = { runs, input_ok, output_ok, where }
-- One row per job type, which is the actual deliverable. A single run
-- tells you about one job; the tally tells you what is wireable.
local results = {}

local function tally(name, input_ok, output_ok, where)
    local r = results[name]
    if not r then
        r = { runs = 0, input_ok = 0, output_ok = 0, where = where }
        results[name] = r
    end
    r.runs = r.runs + 1
    if input_ok  then r.input_ok  = r.input_ok  + 1 end
    if output_ok then r.output_ok = r.output_ok + 1 end
    r.where = where
end

-- ==========================================
-- POLL
-- ==========================================
local function poll()
    if not dfhack.isMapLoaded() then return end
    pcall(function()
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            if watched(job) then
                local rec = seen[job.id]

                -- Building snapshots refresh every poll, because a
                -- workshop's contents move constantly and a stale
                -- picture would report hauled-in items as output.
                -- Ground snapshots are taken once, because walking
                -- items.all repeatedly would cost real frames.
                if not rec or rec.where == 'building' then
                    local ids, where = snapshot(job)
                    rec = rec or {}
                    rec.ids   = ids
                    rec.where = where
                    -- Only set once. Refreshing it on a building job
                    -- would move the cut-off past output already
                    -- produced.
                    if not rec.mark then rec.mark = high_water() end
                    pcall(function()
                        rec.pos = { x = job.pos.x,
                                    y = job.pos.y,
                                    z = job.pos.z }
                    end)
                    seen[job.id] = rec
                end

                -- Inputs are re-read while any are attached, so the
                -- last reading before completion is the one kept.
                local inp = read_inputs(job)
                if #inp > 0 then seen[job.id].inputs = inp end
            end
        end
    end)
end

-- ==========================================
-- COMPLETION
-- ==========================================
local function on_completed(job)
    local name = watched(job)
    if not name then return end

    local ok, err = pcall(function()
        local rec = seen[job.id] or {}
        log('INFO', '==========================================', 'JOB')
        log('INFO', string.format('%s  job %d', name, job.id), 'JOB')

        -- ---- INPUT ----
        local inputs = rec.inputs or {}
        if #inputs == 0 then
            log('INFO', '  INPUT  none captured. Either the job consumes no'
                .. ' items, or it finished inside the poll window.', 'JOB')
        else
            for _, i in ipairs(inputs) do
                log('INFO', string.format(
                    '  INPUT  %s  type=%s vol=%s stack=%s dens=%s  %s',
                    tostring(i.desc), tostring(i.type), tostring(i.vol),
                    tostring(i.stack), tostring(i.dens),
                    tostring(i.token)), 'JOB')
            end
        end

                -- ---- OUTPUT ----
        -- Four places, not one. The first survey found only the
        -- workshop, which is why MakeLye, MAKE_QUICKLIME,
        -- MAKE_MILK_OF_LIME and BREW_DRINK_FROM_PLANT_GROWTH all
        -- reported nothing: their product went into a bucket, bag or
        -- barrel that was ITSELF an input, so the container was not
        -- new and its contents were never looked at.
        local where  = rec.where or 'nowhere'
        local before = rec.ids or {}
        local mark   = rec.mark or 0
        local fresh  = {}
        local looked = {}

        -- Anything created after the snapshot, and not already
        -- counted. The id test does the real work; the set catches
        -- the case where an item existed but moved into view.
        local counted = {}
        local function consider(item)
            if not item then return end
            if counted[item.id] then return end
            if item.id <= mark and before[item.id] then return end
            if item.id <= mark then return end
            counted[item.id] = true
            table.insert(fresh, item)
        end

        if where == 'building' then
            table.insert(looked, 'workshop')
            local bld = building_of(job)
            if bld then
                pcall(function()
                    for _, ci in ipairs(bld.contained_items) do
                        consider(ci.item)
                    end
                end)
            end
        elseif where == 'ground' then
            table.insert(looked, 'ground')
            pcall(function()
                for _, item in ipairs(df.global.world.items.all) do
                    if item.flags.on_ground
                       and near(item.pos, rec.pos, GROUND_RADIUS) then
                        consider(item)
                    end
                end
            end)
        end

        -- ---- INSIDE THE INPUT CONTAINERS ----
        -- A bucket that went in as a reagent and came out holding lye
        -- is not a new item, but what is inside it is.
        pcall(function()
            for _, i in ipairs(rec.inputs or {}) do
                local holder = df.item.find(i.id)
                if holder then
                    local inside = dfhack.items.getContainedItems(holder)
                    if inside and #inside > 0 then
                        table.insert(looked, 'inside ' .. tostring(i.desc))
                        for _, it in ipairs(inside) do consider(it) end
                    end
                end
            end
        end)

        -- ---- THE WORKER'S HANDS ----
        -- GatherPlants and Fish put output straight into the unit's
        -- inventory and it never touches a floor or a workshop.
        pcall(function()
            local unit = dfhack.job.getWorker(job)
            if unit and unit.inventory and #unit.inventory > 0 then
                table.insert(looked, 'worker inventory')
                for _, entry in ipairs(unit.inventory) do
                    consider(entry.item)
                end
            end
        end)

        log('INFO', string.format('  LOOKED in %s',
            (#looked > 0) and table.concat(looked, ', ') or 'nowhere'), 'JOB')

        if #fresh == 0 then
            log('INFO', '  OUTPUT not found. Either it goes somewhere this does'
                .. ' not look, or the job produces nothing here.', 'JOB')
        else
            for _, item in ipairs(fresh) do
                log('INFO', '  OUTPUT ' .. describe_item(item), 'JOB')
            end
        end

        tally(name, #inputs > 0, #fresh > 0, where)
        seen[job.id] = nil
    end)

    if not ok then log('ERROR', 'ERROR: ' .. tostring(err), 'JOB') end
end

-- ==========================================
-- REPORT
-- ==========================================
-- The deliverable. One row per job type: runs seen, how many had a
-- readable input, how many had findable output, and where it looked.
--
-- Both columns full means the job can be treated the way MakeCharcoal
-- was. Anything short of that needs a different approach, and knowing
-- which is the whole point of running this.
-- ==========================================
local function report()
    local names = {}
    for n in pairs(results) do table.insert(names, n) end
    table.sort(names)

    answer('INFO', '==========================================', 'REPORT')
    answer('INFO', 'SURVEY REPORT  build ' .. BUILD, 'REPORT')
    answer('INFO', '==========================================', 'REPORT')
    if #names == 0 then
        answer('INFO', '  Nothing seen yet. Run some jobs first.', 'REPORT')
        return
    end
    answer('INFO', string.format('  %-28s %5s %7s %8s  %s',
        'job', 'runs', 'input', 'output', 'looked in'), 'REPORT')
    for _, n in ipairs(names) do
        local r = results[n]
        answer('INFO', string.format('  %-28s %5d %7s %8s  %s',
            n, r.runs,
            r.input_ok .. '/' .. r.runs,
            r.output_ok .. '/' .. r.runs,
            tostring(r.where)), 'REPORT')
    end
    answer('INFO', '', 'REPORT')
    answer('INFO', '  Both columns full means the job can be treated the way',
        'REPORT')
    answer('INFO', '  MakeCharcoal was. Anything less needs another approach.',
        'REPORT')
end

-- ==========================================
-- LIFECYCLE
-- ==========================================
local args = {...}
local mode = (args[1] or 'on'):lower()

if mode == 'off' then
    repeatUtil.cancel(POLL_KEY)
    eventful.onJobCompleted[EVENT_KEY] = nil
    report()
    seen = {}
    answer('INFO', 'build ' .. BUILD .. ' stopped.', 'STOP')
    return
end

if mode == 'report' then
    report()
    return
end

repeatUtil.scheduleEvery(POLL_KEY, 10, 'frames', poll)
eventful.onJobCompleted[EVENT_KEY] = on_completed
eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)

local n = 0
for _ in pairs(WATCH) do n = n + 1 end
local nr = 0
for _ in pairs(WATCH_RXN) do nr = nr + 1 end

answer('INFO', 'build ' .. BUILD .. ' started. Watching ' .. n
    .. ' job type(s) and ' .. nr .. ' vanilla reaction(s).', 'START')
answer('INFO', 'Reads only. Nothing is created, moved or removed.', 'START')
answer('INFO', 'Run jobs, then: making-fuel-hijack-probe report', 'START')