--@ module = true
-- making-fuel-hijacker.lua
-- ==========================================
-- MAKING FUEL: JOB HIJACKER
-- ==========================================
-- Adds outputs to jobs we do not own, without editing anything that
-- belongs to DF.
--
-- TWO KINDS OF VANILLA JOB, AND WHY IT MATTERS
--
--   RAWS REACTIONS are real df.reaction objects, defined in files like
--   reaction_other.txt. Their products can be edited in RAM. That is
--   the editing engine, and it needs a wash on shutdown because the
--   change lives inside a DF object.
--
--   BUILT IN JOBS have no reaction object at all. MakeCharcoal,
--   ConstructBlocks, SplitLog and the rest are hardcoded job types.
--   There is nothing to edit, so "make charcoal" cannot be hijacked by
--   the ghost swap the char watcher uses.
--
-- This file handles the second kind, and handles the first kind too as
-- a side effect, because it never touches either. It watches for a job
-- FINISHING and then spawns the extra output itself.
--
-- WHY THIS IS THE SAFE ONE
--
-- Nothing is injected, nothing is mutated, nothing is washed. No DF
-- object is different because this script ran, so there is no save
-- protocol, no LIFO ordering problem, and no state to get out of step
-- with a reload. Stopping it is one unregister call. Every failure
-- mode is "the byproduct did not appear", never a corrupt job.
--
-- WHY onJobCompleted RATHER THAN POLLING
--
-- eventful fires this only when a job actually finishes. Polling the
-- job list and noticing a job vanished cannot distinguish completion
-- from cancellation, suspension, or the workshop being deconstructed,
-- and would pay out on all four.
-- ==========================================

local eventful = require('plugins.eventful')
local repeatUtil = require('repeat-util')

local POLL_KEY   = 'making_fuel_hijacker_memo'
local EVENT_KEY = 'making_fuel_hijacker'
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
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'HIJACKER'
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
-- SUBJECT is the correlation slot: ADAPTIVE for the vanilla charcoal
-- rework, WASTE and CAP for loss recovery, SPAWN and BYPRODUCT for the
-- items it makes, GUARD for the product guard, FEEDSTOCK for the memo,
-- CONFIG for a tuning table that disagrees with itself, HOOK, START and
-- STOP.
--
-- A job's output is a YIELD. A byproduct that could not be made is an
-- ERROR, and a config fault that pays nothing is a WARNING or ERROR by
-- how much it costs the player.
--
-- This replaces a log() gated by a private level shared with the
-- ghost (refinish_fuel_loglevel, default 2). The panel's Log Detail
-- setting does that job now, so the level and its global are gone:
-- every line reaches the disk log, and the calls that were level 2 are
-- DETAIL. The old log() also let refinish-log guess TYPE from the
-- words (read_type).
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
-- ADAPTIVE VANILLA OUTPUT
-- ==========================================
-- Vanilla has all the data and does not use it. Every wood in the game
-- carries a solid_density, from feather tree at 100 to blood thorn at
-- 1250, and MakeCharcoal hands back exactly one bar for all seventy of
-- them. The species is decoration.
--
-- MakeCharcoal is a HARDCODED JOB TYPE. There is no df.reaction to
-- edit and no reaction_name to point at a clone, so the ghost swap
-- that handles every custom reaction cannot reach it. The only way in
-- is to let the job finish, remove what it produced, and produce the
-- right thing instead.
--
-- CONFIRMED BY PROBE, making-fuel-hijack-probe build P1:
--   The input IS readable. The wood memo poll catches the log while
--   the job runs. A feather tree log read PLANT:FEATHER:WOOD,
--   density 100, volume 5000.
--   The output IS present at onJobCompleted. A completed MakeCharcoal
--   showed 16 items in the furnace, 2 of them new, and the 2 new were
--   exactly the vanilla bar and one previously hijacked cinder.
--   So deletion is inline. No deferred pass is needed.
--
-- Anchored to size and density rather than to numbers chosen here. If
-- a mod rewrites every wood density tomorrow, this adapts without a
-- line changing, because it was never holding a table of species.
-- ==========================================

-- ---- MODES ----
-- Per job, and every one of them shares a single valuation path, so
-- moving a job between them is one word.
--
--   OFF        registered and inert. A kill switch.
--   BYPRODUCT  vanilla untouched, spawn a fixed extra. The original
--              behaviour, kept because sawdust and straw want it.
--   TOP_UP     vanilla untouched, spawn only the positive shortfall.
--              Never removes anything, so a light wood keeps the free
--              bar vanilla gave it.
--   REPLACE    delete the vanilla product, pay what the curve says.
--              The only mode where a feather tree log is honestly
--              worth less than a blood thorn one.
local MODE_OFF       = 'OFF'
local MODE_BYPRODUCT = 'BYPRODUCT'
local MODE_TOP_UP    = 'TOP_UP'
local MODE_REPLACE   = 'REPLACE'

-- Once per key for the session. The old body handed its subject to
-- log()'s level slot, so every line it wrote lost its subject and
-- TYPE; with the level gone the arguments line up.
local seen = {}
local function log_once(key, typ, msg, subject)
    if seen[key] then return end
    seen[key] = true
    log(typ, msg, subject)
end

-- ==========================================
-- TUNING, SOFTLY
-- ==========================================
-- Same source of truth the ghost uses, so a constant changed once
-- moves both. Wrapped because a bare reqscript at top level is a hard
-- load time dependency: it executes while DFHack scans the mod's
-- scripts, and a missing tuning file then takes the whole module down
-- before it is ever called. That happened once already.
-- ==========================================
local tuning = nil
pcall(function() tuning = reqscript('making-fuel-tuning') end)

-- ---- THE CLASSIFIER LIVES IN THE GHOST ----
-- Pricing vanilla's smelter coke means knowing lignite from
-- bituminous, and that split is 300 lines of measured knowledge in
-- the ghost. A second copy here would drift the first time either
-- is tuned, so this borrows the original instead.
--
-- LAZY, not at load. reqscript at file scope runs the ghost while
-- this file is still loading, and the order the two come up in is
-- not this file's to decide. Resolved on first use and remembered
-- either way, so a missing ghost costs one failed call, not one
-- per job. false rather than nil for 'asked and it was not there'.
local ghost_cache = nil
local function ghost_env()
    if ghost_cache == nil then
        local ok, g = pcall(function()
            return reqscript('making-fuel-ghost')
        end)
        ghost_cache = (ok and g) or false
    end
    return ghost_cache or nil
end

local function have_tuning()
    return tuning and tuning.T and tuning.yield
end

-- The BYPRODUCTS switch for smelter coal ash, read at spawn time so
-- flipping it needs no restart of this script.
local function coal_ash_enabled()
    if not have_tuning() then return true end
    local b = tuning.T.BYPRODUCTS
    return not (b and b.COAL_ASH == false)
end

-- ==========================================
-- THE BANK
-- ==========================================
-- The same global the ghost writes to, deliberately. A log that pays
-- 0.33 charcoal is not a loss, it is a deposit, and the barrel charred
-- an hour later finishes what it started. One pool across the whole
-- mod means vanilla output and module output are the same currency.
-- ==========================================
local function bank_get()
    _G.refinish_fuel_bank = _G.refinish_fuel_bank or {}
    return _G.refinish_fuel_bank
end

-- ==========================================
-- OWNERSHIP
-- ==========================================
-- [item id] = true for everything this script has ever created.
--
-- The delete pass finds its victims by diffing the workshop against a
-- before picture, and this script's own output lands in exactly that
-- window. Without this, a spawned cinder is indistinguishable from a
-- vanilla bar and REPLACE eats its own product on the next job that
-- finishes in the same furnace.
--
-- Never pruned. An id is a number and a fort produces tens of
-- thousands of items, not millions, so the table stays small enough
-- that the alternative, checking whether an item still exists, costs
-- more than the memory saves.
-- ==========================================
local ours = {}

-- ==========================================
-- PRODUCT SIGNATURES
-- ==========================================
-- What a job is KNOWN to produce, so deletion can match rather than
-- guess. Deleting by newness would take anything that happened to
-- enter the workshop on that tick.
--
-- This is also the answer to a mod or a DF version changing what a
-- furnace makes. The signature stops matching, nothing is deleted, the
-- unrecognised item is logged, and the job falls back to producing
-- vanilla's output untouched. It fails inert, never destructive.
-- ==========================================
local function is_vanilla_charcoal(item)
    local t, tok = -1, ''
    pcall(function() t = item:getType() end)
    if t ~= df.item_type.BAR then return false end
    pcall(function()
        local m = dfhack.matinfo.decode(item)
        if m then tok = m:getToken() end
    end)
    return tok == 'COAL:CHARCOAL'
end

-- Vanilla ash is the builtin ASH material and nothing else is, so
-- the numeric test is exact and does not depend on how getToken
-- spells a builtin. Same test the coal watcher uses for COAL.
-- Vanilla's smelter coke. Builtin COAL carries two flavours and the
-- token spells them apart: index 1 is charcoal, index 0 is coke, the
-- same pair the coal watcher's REPLACEMENT_FOR map is keyed on. So
-- this is the coke twin of is_vanilla_charcoal and nothing else can
-- match it.
local function is_vanilla_coke(item)
    local t, tok = -1, ''
    pcall(function() t = item:getType() end)
    if t ~= df.item_type.BAR then return false end
    pcall(function()
        local m = dfhack.matinfo.decode(item)
        if m then tok = m:getToken() end
    end)
    return tok == 'COAL:COKE'
end

local function is_vanilla_ash(item)
    local hit = false
    pcall(function()
        hit = item:getType() == df.item_type.BAR
            and item.mat_type == df.builtin_mats.ASH
    end)
    return hit
end

-- ==========================================
-- FUEL ON A HARDCODED JOB
-- ==========================================
-- reagent_index -1 names DF's fuel filter, but only inside a CUSTOM
-- REACTION, because -1 there means "not one of the reaction's
-- reagents". A hardcoded job has no reaction, so DF writes -1 on every
-- filter and the test means nothing. SmeltOre still burns fuel.
--
-- What is true on both: fuel arrives as a BAR of something that
-- burns. Vanilla's two builtin flavours have exact token tests
-- already, and everything this module makes carries FUEL_CLASS, which
-- is the same contract that lets any furnace accept it. So the item
-- itself answers the question without needing the job to.
--
-- rc[i].value, not tostring(rc[i]). tostring on a reaction_class
-- entry yields a pointer address and every comparison silently fails.
-- ==========================================
local function bar_is_fuel(item)
    local t = -1
    pcall(function() t = item:getType() end)
    if t ~= df.item_type.BAR then return false end
    if is_vanilla_charcoal(item) or is_vanilla_coke(item) then
        return true
    end
    local want = (have_tuning() and tuning.T.FUEL_CLASS) or 'FUEL'
    local hit = false
    pcall(function()
        local m = dfhack.matinfo.decode(item)
        local rc = m and m.material and m.material.reaction_class
        if rc then
            for i = 0, #rc - 1 do
                if rc[i].value == want then hit = true return end
            end
        end
    end)
    return hit
end

-- ==========================================
-- IS A MATERIAL FUEL
-- ==========================================
-- bar_is_fuel above answers for an ITEM and returns false on
-- anything that is not a BAR, which is right for reading a job's
-- inputs. The product guard asks about a finished WEAPON or ARMOR
-- piece: is the material it was built from one of the fuels. So this
-- drops the item type test and reads the material directly.
--
-- Both classes count. A forge burns FUEL_SMELTING and a kiln burns
-- FUEL, either can be what leaked onto a product, and a guard that
-- knew only one would miss half the cases.
--
-- rc[i].value, not tostring(rc[i]), for the reason bar_is_fuel
-- states: tostring on a reaction_class entry yields a pointer.
local function mat_is_fuel(mat_type, mat_index)
    if mat_type == nil or mat_index == nil then return false end
    -- Builtin coal is vanilla charcoal and coke without needing a
    -- class, the same pair the coal watcher is keyed on.
    if mat_type == df.builtin_mats.COAL then return true end

    local primary = (have_tuning() and tuning.T.FUEL_CLASS) or 'FUEL'
    local smith   = (have_tuning() and tuning.T.FUEL_SMITH_CLASS)
                    or 'FUEL_SMELTING'
    local hit = false
    pcall(function()
        local m = dfhack.matinfo.decode(mat_type, mat_index)
        local rc = m and m.material and m.material.reaction_class
        if rc then
            for i = 0, #rc - 1 do
                local v = rc[i].value
                if v == primary or v == smith then hit = true return end
            end
        end
    end)
    return hit
end

-- ==========================================
-- ANNOUNCEMENT
-- ==========================================
-- Honours RM's own message setting rather than a switch of this
-- script's own. Four values, set in the config panel:
--
--   SILENT   nothing
--   PASSIVE  the event log only
--   GUIDED   a bubble in plain language
--   DEBUG    the bubble plus the numbers behind it
--
-- The bubble exists for one case: a payout that rounds to nothing. A
-- log goes in, the bar is removed, and without a word on screen the
-- only available reading is that the furnace ate it. With one, the
-- explanation is there for anyone who looks.
-- ==========================================
local function msg_mode()
    local m = nil
    pcall(function()
        m = dfhack.persistent.getSiteData('refinish_config_msg')
    end)
    if not m or m == '' then m = 'GUIDED' end
    return m
end

local function announce(plain, detail)
    local m = msg_mode()
    if m == 'SILENT' then return end
    -- INFO: the payout rounded to nothing and the value banked, which
    -- is what the announcement explains in game.
    if m == 'PASSIVE' then
        log('INFO', plain .. (detail and ('  ' .. detail) or ''), 'ADAPTIVE')
        return
    end
    local text = plain
    if m == 'DEBUG' and detail then text = plain .. '  [' .. detail .. ']' end
    pcall(function()
        dfhack.gui.showAnnouncement(text, COLOR_BROWN, false)
    end)
    log('INFO', plain .. (detail and ('  ' .. detail) or ''), 'ADAPTIVE')
end

-- ==========================================
-- VALUATION
-- ==========================================
-- What the input is worth on the curve, in charcoal.
--
-- A log is always 5000 volume, confirmed by the size probe and again
-- by the hijack probe, so MakeCharcoal varies on density alone. The
-- memo already holds the material, which is the only thing needed.
--
-- Returns value, token, density. nil when the memo missed the input
-- or tuning is unavailable, and the caller then leaves the job alone
-- entirely rather than guessing at a number.
-- ==========================================
local function input_value(job)
    if not have_tuning() then return nil end

    local memo = wood_memo[job.id]
    if not memo then return nil end

    local mat = nil
    pcall(function()
        mat = dfhack.matinfo.decode(memo.type, memo.index)
    end)
    if not mat then return nil end

    local dens, tok = nil, '?'
    pcall(function() dens = mat.material.solid_density end)
    pcall(function() tok = mat:getToken() end)

    local vol = memo.vol or tuning.T.ANCHOR_VOLUME

    -- ---- CLASS, NOT ALWAYS WOOD ----
    -- This said 'WOOD' outright while the only adaptive jobs were
    -- MakeCharcoal and MakeAsh. A coking job hands it a coal
    -- boulder, and pricing that as wood would read a 1346 density
    -- against the wood curve and pay nonsense.
    --
    -- Falls back to WOOD if the ghost is not up, which is exactly
    -- what this line did before and is right for the wood jobs that
    -- are the only ones running in that case.
    local class = 'WOOD'
    local g = ghost_env()
    if g and g.classify then
        local ok, c = pcall(g.classify, mat)
        if ok and c then class = c end
    end

    -- ctx carries the token, matching how the ghost calls yield, so
    -- any factor keyed on it behaves the same down both paths.
    return tuning.yield(vol, class, dens, { mat_token = tok }),
           tok, dens, vol, class
end

-- ==========================================
-- PAYOUT
-- ==========================================
-- Adds value to a bank, takes out whole products, leaves the
-- fraction. Identical arithmetic to the ghost's, on the same pools:
-- BANK_CHARCOAL and BANK_ASH are the keys the ghost writes.
--
-- Two shapes, because the two currencies pack differently. Charcoal
-- has a ladder, boulders four at a time and cinders for the
-- remainder; ash is whole bars, and everything under one banks.
-- ==========================================

-- ---- THE TWO LADDERS ----
-- Mirrored from the ghost's LADDER_WOOD and LADDER_COAL. Wood and
-- coal pack identically: a middle rung that IS the currency, a top
-- rung holding four of it, and a bottom rung worth a quarter each.
--
--   charcoal:  1 char boulder = 4 charcoal,  1 charcoal = 4 cinder
--   coke:      1 green coke   = 4 coke,      1 coke     = 4 breeze
--
-- Constants are NAMED, not inlined, so a missing one fails by name
-- rather than as arithmetic on a nil. The bank key is here too
-- because it is the one thing that genuinely differs per ladder.
local LADDER_WOOD = {
    currency = 'CHARCOAL',
    per_top  = 'CHARCOAL_PER_BOULDER',
    per_sub  = 'CINDERS_PER_CHARCOAL',
}
local LADDER_COAL = {
    currency = 'COKE',
    per_top  = 'COKE_PER_GREEN_COKE',
    per_sub  = 'BREEZE_PER_COKE',
}

-- Returns bars, packed, subs, paid, projected, carry.
-- One writer for both ladders: this used to be payout_charcoal with
-- the wood constants inlined, and a second copy for coal would have
-- been a second place to forget PAY_CINDERS or the epsilon.
local function payout_ladder(value, bld, ladder)
    ladder = ladder or LADDER_WOOD
    local T    = tuning.T
    local bank = bank_get()
    -- Per furnace, matching the ghost exactly. See the note on
    -- bank_key there: a shared pool is double spent when two
    -- furnaces project against it at once, and with overflow banks
    -- the error is the whole balance rather than one package.
    local key  = 'BANK_' .. ladder.currency
    if bld then key = key .. '@' .. tostring(bld.id) end

    local projected = (bank[key] or 0) + value

    -- Epsilon goes INTO the floor. Without it a value landing a hair
    -- under a whole number floors to nothing and the product it earned
    -- disappears.
    local whole = math.floor(projected + T.EPSILON)
    if whole < 0 then whole = 0 end
    local remainder = projected - whole
    if remainder < 0 then remainder = 0 end

    local per_top = T[ladder.per_top]
    local per_sub = T[ladder.per_sub]

    local packed = math.floor(whole / per_top)
    local bars   = whole % per_top
    local subs   = 0
    if T.PAY_CINDERS then
        subs = math.floor(remainder * per_sub)
    end

    local paid = whole + (subs / per_sub)
    local carry = projected - paid
    if carry < 0 then carry = 0 end
    bank[key] = carry

    return bars, packed, subs, paid, projected, carry
end

-- Returns bars, paid, projected, carry.
-- currency defaults to ASH, so every existing call is unchanged.
-- Coal ash banks through the same arithmetic on its own key.
local function payout_ash(value, bld, currency)
    local T    = tuning.T
    local bank = bank_get()
    local key  = 'BANK_' .. (currency or 'ASH')
    if bld then key = key .. '@' .. tostring(bld.id) end

    local projected = (bank[key] or 0) + value
    local whole = math.floor(projected + T.EPSILON)
    if whole < 0 then whole = 0 end

    local carry = projected - whole
    if carry < 0 then carry = 0 end
    bank[key] = carry

    return whole, whole, projected, carry
end

-- ==========================================
-- WOOD MEMO
-- ==========================================
-- [job.id] = { type = mat_type, index = mat_index }
--
-- onJobCompleted fires AFTER the reagents are consumed, so a carpentry
-- job has an empty job.items by the time we see it: the log is gone,
-- it is a chair now. Confirmed in game, items=1 while working and
-- items=0 at completion.
--
-- So the wood is recorded at job initiation, while the log is still
-- attached, and read back at completion. Numbers rather than a matinfo
-- object, because the object holds pointers and this outlives the tick
-- that made it.
-- ==========================================
wood_memo = {}

-- ==========================================
-- INPUT PREDICATES
-- ==========================================
-- Reads the plant that went into the job and asks a question about it.
--
-- WHY MILLING, AND WHY THIS TEST
--
-- Straw is the stalk left after the grain is taken, so it belongs to
-- the job that takes the grain. Milling is that job, but milling is
-- not cereal-only: dimple cup, blade weed, hide root and sliver barb
-- all mill, and they are mushrooms and shrubs with nothing to thresh.
--
-- The mill product's EDIBLE_COOKED flag separates them exactly. Every
-- grain, pseudocereal and millet mills to edible flour; all four dye
-- plants mill to inedible dye powder. Verified against the full plant
-- raws, 33 milling plants, zero misclassified.
--
-- KNOWN AND ACCEPTED, all confirmed against the live plant raws:
-- flax and hemp pass, and both are bast fibre crops whose stalks are
-- exactly what straw is, so they are correct. Sugarcane and the two
-- grasses pass and all three are stalks. VINE_WHIP passes and is a
-- vine with no stalk; it is let through deliberately, because
-- excluding one plant means a species list, which is the thing this
-- test exists to avoid.
-- ==========================================
local function job_input_plant(job)
    local plant = nil
    pcall(function()
        for _, iref in ipairs(job.items) do
            local m = dfhack.matinfo.decode(iref.item)
            if m and m.plant then plant = m.plant; break end
        end
    end)
    return plant
end

local function mills_to_flour(job)
    local plant = job_input_plant(job)
    if not plant then return false end

    local edible = false
    pcall(function()
        local d = plant.material_defs
        if d.type.mill < 0 then return end
        local m = dfhack.matinfo.decode(d.type.mill, d.idx.mill)
        edible = m and m.material.flags.EDIBLE_COOKED or false
    end)
    return edible
end

-- ==========================================
-- WOOD INPUT
-- ==========================================
-- The carpentry job types do not care what they are built from, so
-- ConstructThrone covers stone and metal chairs as well as wooden
-- ones. The item type of the reagent is the discriminator, not the
-- job: if a WOOD item went in, a tree was cut for it.
--
-- Returns the matinfo of that log, which is also the material the
-- sawdust should be, so one function serves as both the predicate and
-- the material resolver.
-- ==========================================
local function wood_input(job)
    local memo = wood_memo[job.id]
    if memo then
        local mat = nil
        pcall(function()
            mat = dfhack.matinfo.decode(memo.type, memo.index)
        end)
        return mat
    end

    -- Fallback for any job that still has its reagents at completion.
    local mat = nil
    pcall(function()
        for _, iref in ipairs(job.items) do
            if iref.item:getType() == df.item_type.WOOD then
                mat = dfhack.matinfo.decode(iref.item)
                break
            end
        end
    end)
    return mat
end

-- ==========================================
-- THE HIJACK TABLE
-- ==========================================
-- Keyed by df.job_type for built in jobs, or by reaction code string
-- for raws reactions. One lookup covers both because job_type is a
-- number and a reaction code is a string.
--
-- Each entry is a list of byproducts:
--
--   item_type  df.item_type value
--   tool_id    itemdef id string, TOOL only, resolved at spawn time
--              because injected subtypes move between versions
--   mat        material token, e.g. 'INORGANIC:MAKING_FUEL_CHAR'
--   count      how many
--   chance     0 to 1, rolled once per byproduct, omit for always
--
-- MakeCharcoal is the worked example. One log becomes one charcoal in
-- vanilla and that number is inviolable, so the hijack adds what the
-- vanilla reaction throws away rather than more fuel: the ash and
-- fines that a real kiln leaves behind.
-- ==========================================
local HIJACK = {
    -- MakeCharcoal produces nothing through this table any more. It
    -- runs in REPLACE mode instead: the vanilla bar is removed and the
    -- curve pays what the wood is actually worth. The placeholder
    -- cinder that used to sit here was standing in for exactly that
    -- and would now be paid twice.
    --
    -- The empty list keeps it in HIJACK, which is what makes the memo
    -- poll record its log.
    [df.job_type.MakeCharcoal] = {},

    -- MakeAsh is MakeCharcoal's mirror and runs the same way: an
    -- empty list here so the memo poll records its log, REPLACE in
    -- MODES so the vanilla bar is removed and the curve pays what
    -- the wood is worth in ash, plus the char that never quite
    -- burned. See THE TWO BURNS below.
    [df.job_type.MakeAsh] = {},

    -- Straw. The stalk the mill throws away.
    [df.job_type.MillPlants] = {
        { item_type = df.item_type.TOOL,
          tool_id   = 'MAKING_FUEL_STRAW',
          mat       = 'INORGANIC:MAKING_FUEL_STRAW',
          count     = 1,
          when      = mills_to_flour },
          chance    = 1
    },

    -- Kitchen cinders. No predicate: every cooked meal banks a fire.
    [df.job_type.PrepareMeal] = {
        -- A bar of the plant host's cinder material, not a tool of
        -- the char material. spawn resolves a token string through
        -- matinfo.find, which takes a plant token unchanged, so the
        -- only thing that moves here is the token itself.
        { item_type = df.item_type.BAR,
          mat       = 'PLANT_MAT:MAKING_FUEL_COAL_HOST:CINDER',
          count     = 1,
          chance    = 0.25 },
    },
    -- Spent mash from the still. Every brewable plant leaves it, so no
    -- predicate. Keyed on the reaction code because BREW_DRINK_FROM_PLANT
    -- is a raws reaction, not a built in job type, and the table takes
    -- strings for exactly that case.
    --
    -- chance 0.5 puts brewing at four jobs per charcoal, the same rate
    -- as milling. Raise it to 1.0 and the still becomes the best fuel
    -- source in the fort, which is not what a still is for.
    ['BREW_DRINK_FROM_PLANT'] = {
        { item_type = df.item_type.TOOL,
          tool_id   = 'MAKING_FUEL_MASH',
          mat       = 'INORGANIC:MAKING_FUEL_MASH',
          count     = 1,
          chance    = 0.25 },
    },

    -- Coal ash off vanilla's smelter coke. The coke count is
    -- vanilla's and stays vanilla's, 5 from lignite and 9 from
    -- bituminous; the smelter's version of "each stream leaves the
    -- other behind" is the ash a coal fire cannot help making. The
    -- retort pays the same coke and captures the tar as well, which
    -- is the whole reason to build one. Raws reactions, so the key
    -- is the reaction code, as with brewing above.
    ['LIGNITE_TO_COKE'] = {
        { item_type = df.item_type.BOULDER,
          mat       = 'PLANT_MAT:MAKING_FUEL_COAL_HOST:ASH_COAL',
          count     = 1,
          when      = function() return coal_ash_enabled() end },
    },
    ['BITUMINOUS_COAL_TO_COKE'] = {
        { item_type = df.item_type.BOULDER,
          mat       = 'PLANT_MAT:MAKING_FUEL_COAL_HOST:ASH_COAL',
          count     = 1,
          when      = function() return coal_ash_enabled() end },
    },
}

-- ==========================================
-- ADAPTIVE MODES
-- ==========================================
-- Which jobs have their output recomputed from the curve, and how.
-- Anything absent runs BYPRODUCT, which is the original behaviour.
--
--   OFF        registered and inert
--   BYPRODUCT  vanilla untouched, spawn the fixed extras above
--   TOP_UP     vanilla untouched, spawn only a positive shortfall
--   REPLACE    delete the vanilla product, pay what the curve says
--
-- ConstructBlocks is deliberately NOT here. Four blocks from a log is
-- a number people know, and the loss it represents is answered by the
-- sawdust byproduct rather than by changing the count. Solid blocks
-- still come out, and the wood that used to vanish now changes form.
-- ==========================================
local MODES = {
    [df.job_type.MakeCharcoal] = 'REPLACE',
    [df.job_type.MakeAsh]      = 'REPLACE',

    -- ---- VANILLA'S COKE, ON OUR CURVE ----
    -- String keys, because these are raws reactions and on_completed
    -- resolves a CustomReaction to its code before looking here.
    --
    -- REPLACE, the same as MakeCharcoal, and for the same reason:
    -- vanilla pays a flat 5 and 9 across every coal in the game and
    -- has the density to know better. If coke adapts anywhere it
    -- adapts everywhere, whoever wrote the reaction.
    --
    -- These leave BYPRODUCT by doing so, which is where their coal
    -- ash was being spawned. adaptive_output spawns it on the coal
    -- branch now, on the same switch.
    ['LIGNITE_TO_COKE']         = 'REPLACE',
    ['BITUMINOUS_COAL_TO_COKE'] = 'REPLACE',
}

-- ==========================================
-- THE TWO BURNS
-- ==========================================
-- MakeCharcoal and MakeAsh are one job with the damper in different
-- positions, and the module treats them as mirror images. Each has
-- a PRIMARY, the thing vanilla pays one bar of per log, priced on
-- the curve at what the wood is actually worth; and a SECONDARY,
-- what the other burn would have made, at a tuned fraction of that.
-- The fractions and the reasoning live in making-fuel-tuning.lua
-- under THE TWO BURNS, and the ghost pays the same two streams on
-- every custom char and ash reaction.
--
-- Each entry names the primary currency, the test that recognises
-- vanilla's bar of it, and the words the announcement uses when a
-- job pays nothing visible.
-- ==========================================
local BURNS = {
    [df.job_type.MakeCharcoal] = {
        primary  = 'CHARCOAL',
        vanilla  = is_vanilla_charcoal,
        announce = 'Char has accumulated in the wood furnace.',
    },
    [df.job_type.MakeAsh] = {
        primary  = 'ASH',
        vanilla  = is_vanilla_ash,
        announce = 'Ash has accumulated in the wood furnace.',
    },

    -- ---- THE COAL FAMILY ----
    -- family is what adaptive_output branches on. ABSENT MEANS WOOD,
    -- so the two entries above are untouched and any future wood burn
    -- keeps working without knowing this field exists.
    --
    -- Both coals share an entry shape because rank is not decided
    -- here: the classifier reads it off the boulder that actually
    -- walked in, so a lignite job that somehow received bituminous
    -- is priced as bituminous. The reaction only says which vanilla
    -- bar to take back.
    ['LIGNITE_TO_COKE'] = {
        family   = 'COAL',
        primary  = 'COKE',
        vanilla  = is_vanilla_coke,
        announce = 'Coke breeze has accumulated in the smelter.',
    },
    ['BITUMINOUS_COAL_TO_COKE'] = {
        family   = 'COAL',
        primary  = 'COKE',
        vanilla  = is_vanilla_coke,
        announce = 'Coke breeze has accumulated in the smelter.',
    },
}

-- ==========================================
-- MEASURED WASTE
-- ==========================================
-- Which jobs give back part of what they lose. The kind string on
-- each entry is legacy: waste_output now recovers VALUE from the
-- measured loss and pays it as bark and sawdust both.
--
-- The size is not declared here. It is measured: input volume minus
-- output volume, times WASTE_RECOVERY. A door loses 2000, an armor
-- stand loses 4000, scroll rollers lose 4990. No table could keep up
-- with that, and a table would go stale the moment DF changed an
-- item's volume.
--
-- The byproduct inherits the input's material, so a feather wood door
-- gives feather wood sawdust and species carries through to whatever
-- chars it later.
--
-- ConstructBlocks is here even though the block COUNT stays vanilla.
-- Four blocks from a log is a number people know; the 2600 that
-- disappears making them is not, and that is what comes back.
-- ==========================================
-- ==========================================
-- FEEDSTOCK
-- ==========================================
-- Which attached item a job counts as having been made OUT OF, and
-- which LOSS_STREAMS class that puts it in.
--
-- There is no BONE item type in DF. Bone, shell, horn and tooth all
-- arrive as CORPSEPIECE, which is why one entry covers the lot.
local FEEDSTOCK_ORDER = {
    df.item_type.WOOD,          -- 5
    df.item_type.BOULDER,       -- 4
    df.item_type.BAR,           -- 0
    df.item_type.SKIN_TANNED,   -- 55
    df.item_type.CLOTH,         -- 58
    df.item_type.THREAD,        -- 57
    df.item_type.ROUGH,         -- 3
    df.item_type.SMALLGEM,      -- 1
    df.item_type.CORPSEPIECE,   -- 46
}

local FEEDSTOCK_CLASS = {
    [df.item_type.WOOD]        = 'WOOD',
    [df.item_type.BOULDER]     = 'STONE',
    [df.item_type.BAR]         = 'METAL',
    [df.item_type.SKIN_TANNED] = 'LEATHER',
    [df.item_type.CLOTH]       = 'CLOTH',
    [df.item_type.THREAD]      = 'CLOTH',
    [df.item_type.ROUGH]       = 'GEM',
    [df.item_type.SMALLGEM]    = 'GEM',
    [df.item_type.CORPSEPIECE] = 'BONE',
}

-- ROUGH and SMALLGEM are gems OR glass and the item type cannot say
-- which. Token substring, the same technique the ghost's classifier
-- already uses for coal and peat, because a material's id is not its
-- token and there is no IS_GLASS predicate to lean on here.
local function is_glass_mat(mtype, mindex)
    local tok = nil
    pcall(function()
        local mi = dfhack.matinfo.decode(mtype, mindex)
        tok = mi and mi:getToken() or nil
    end)
    return tok ~= nil and tostring(tok):find('GLASS', 1, true) ~= nil
end

-- ==========================================
-- WHAT KIND OF CORPSEPIECE
-- ==========================================
-- CORPSEPIECE is not one material. Bone, skin, shell, horn, tooth,
-- hair, fat and meat all arrive under that single item type, which is
-- also why a raw hide is a CORPSEPIECE while tanned leather is a
-- SKIN_TANNED. Mapping the item type straight to BONE therefore priced
-- every hide on the bone curve and minted bone dust off a buffalo.
--
-- The MATERIAL says which. matinfo gives LLAMA:BONE against
-- BUFFALO:SKIN, so the tail after the last colon is the answer. Same
-- technique as is_glass_mat above, and the same reason: the item type
-- cannot carry the distinction and the material already does.
--
-- Anything not listed returns nil, which means no class and nothing
-- owed. Meat and fat belong to butchery rather than to a loss stream,
-- so that silence is correct.
-- ==========================================
local CORPSE_CLASS = {
    -- Hard carvable tissue. Carving it leaves dust, which is the same
    -- substance as bone meal however it was produced.
    --
    -- HOOF and CHITIN are keratin rather than bone, but they carve and
    -- dust the same way, and DF already groups hoof with horn: a horse
    -- hoof arrives as CREATURE:HORSE:HOOF carrying flags[horn].
    BONE      = 'BONE',
    SHELL     = 'BONE',
    HORN      = 'BONE',
    HOOF      = 'BONE',
    TOOTH     = 'BONE',
    IVORY     = 'BONE',
    PEARL     = 'BONE',
    CHITIN    = 'BONE',
    CARTILAGE = 'BONE',

    -- Raw hide, before tanning. SKIN_TANNED covers the other half.
    --
    -- SCALE is a reptile's hide and it REPLACES skin rather than
    -- accompanying it. MEASURED: a giant copperhead snake butchers to
    -- SCALE and no SKIN at all, so without this entry every reptile
    -- hide in the fort classifies as nothing and owes nothing.
    SKIN      = 'LEATHER',
    SCALE     = 'LEATHER',
    LEATHER   = 'LEATHER',

    -- Fibre off the animal, which behaves like thread rather than hide.
    HAIR      = 'CLOTH',
    WOOL      = 'CLOTH',
    SILK      = 'CLOTH',
    FEATHER   = 'CLOTH',

    -- Deliberately absent: NERVE, BRAIN, GUT, MUSCLE and the rest of
    -- the organ tissues. They arrive as MEAT or GLOB rather than as a
    -- carvable piece, nobody shapes an amulet out of a spleen, and a
    -- loss stream is the wrong home for them. Butchery is.
}

local function corpse_class(mtype, mindex)
    local tok = nil
    pcall(function()
        local mi = dfhack.matinfo.decode(mtype, mindex)
        tok = mi and mi:getToken() or nil
    end)
    if not tok then return nil end
    local tail = tostring(tok):match('([^:]+)$')
    if not tail then return nil end
    return CORPSE_CLASS[tail:upper()]
end

local WASTE = {
    [df.job_type.ConstructDoor]             = 'SAWDUST',
    [df.job_type.ConstructFloodgate]        = 'SAWDUST',
    [df.job_type.ConstructBed]              = 'SAWDUST',
    [df.job_type.ConstructThrone]           = 'SAWDUST',
    [df.job_type.ConstructCoffin]           = 'SAWDUST',
    [df.job_type.ConstructTable]            = 'SAWDUST',
    [df.job_type.ConstructChest]            = 'SAWDUST',
    [df.job_type.ConstructBin]              = 'SAWDUST',
    [df.job_type.ConstructArmorStand]       = 'SAWDUST',
    [df.job_type.ConstructWeaponRack]       = 'SAWDUST',
    [df.job_type.ConstructCabinet]          = 'SAWDUST',
    [df.job_type.ConstructBlocks]           = 'SAWDUST',
    [df.job_type.ConstructHatchCover]       = 'SAWDUST',
    [df.job_type.ConstructGrate]            = 'SAWDUST',
    [df.job_type.ConstructSplint]           = 'SAWDUST',
    [df.job_type.ConstructCrutch]           = 'SAWDUST',
    [df.job_type.ConstructCatapultParts]    = 'SAWDUST',
    [df.job_type.ConstructBallistaParts]    = 'SAWDUST',
    [df.job_type.ConstructBoltThrowerParts] = 'SAWDUST',
    [df.job_type.MakeBarrel]                = 'SAWDUST',
    [df.job_type.MakeBucket]                = 'SAWDUST',
    [df.job_type.MakeCage]                  = 'SAWDUST',
    [df.job_type.MakeAnimalTrap]            = 'SAWDUST',
    [df.job_type.MakeGoblet]                = 'SAWDUST',
    [df.job_type.MakeToy]                   = 'SAWDUST',
    [df.job_type.MakeTool]                  = 'SAWDUST',
    [df.job_type.MakeWindow]                = 'SAWDUST',

    -- Folded in from the old bark-only set, so every wood job now
    -- recovers from what it measurably lost instead of rolling a
    -- flat chance. Small jobs mostly bank; that is the point.
    [df.job_type.ConstructStatue]           = 'SAWDUST',
    [df.job_type.ConstructTractionBench]    = 'SAWDUST',
    [df.job_type.ConstructMechanisms]       = 'SAWDUST',
    [df.job_type.MakeChain]                 = 'SAWDUST',
    [df.job_type.MakeFlask]                 = 'SAWDUST',
    [df.job_type.MakeTotem]                 = 'SAWDUST',
    [df.job_type.MakeBackpack]              = 'SAWDUST',
    [df.job_type.MakeQuiver]                = 'SAWDUST',
    [df.job_type.MakeTrapComponent]         = 'SAWDUST',
    [df.job_type.MakeCrafts]                = 'SAWDUST',
    [df.job_type.MakeWeapon]                = 'SAWDUST',
    [df.job_type.MakeAmmo]                  = 'SAWDUST',
    [df.job_type.MakeShield]                = 'SAWDUST',
    [df.job_type.MakePipeSection]           = 'SAWDUST',
}

-- ==========================================
-- SAWDUST ACROSS ALL CARPENTRY
-- ==========================================
-- Every one of these is a built in job type that consumes whole logs.
-- Registered in a loop because the spec is identical for all of them
-- and a table of thirty hand written copies is thirty chances to get
-- one wrong.
--
-- wood_input serves twice: as the predicate, returning nil and
-- skipping the spawn when the job built something out of stone or
-- metal, and as the material, so the sawdust is the same wood as the
-- log that made the furniture.
--
-- chance 0.5 puts carpentry at eight items per charcoal, since four
-- sawdust make one. That is deliberately poor. Sawdust is a nuisance
-- the carpenter sweeps up, not a reason to build furniture.
-- ==========================================
local SAWDUST_JOBS = {
    df.job_type.ConstructDoor,      df.job_type.ConstructFloodgate,
    df.job_type.ConstructBed,       df.job_type.ConstructThrone,
    df.job_type.ConstructCoffin,    df.job_type.ConstructTable,
    df.job_type.ConstructChest,     df.job_type.ConstructCabinet,
    df.job_type.ConstructBin,       df.job_type.ConstructArmorStand,
    df.job_type.ConstructWeaponRack, df.job_type.ConstructStatue,
    df.job_type.ConstructHatchCover, df.job_type.ConstructGrate,
    df.job_type.ConstructSplint,    df.job_type.ConstructCrutch,
    df.job_type.ConstructTractionBench,
    df.job_type.MakeBarrel,         df.job_type.MakeBucket,
    df.job_type.MakeWindow,         df.job_type.MakeCage,
    df.job_type.MakeChain,          df.job_type.MakeFlask,
    df.job_type.MakeGoblet,         df.job_type.MakeToy,
    df.job_type.MakeAnimalTrap,     df.job_type.MakeTotem,
    df.job_type.MakeBackpack,       df.job_type.MakeQuiver,
    df.job_type.MakeTrapComponent,  df.job_type.MakeTool,
    df.job_type.MakeCrafts,         df.job_type.MakeWeapon,
    df.job_type.MakeAmmo,           df.job_type.MakeShield,
    df.job_type.MakePipeSection,    df.job_type.ConstructMechanisms,
    df.job_type.ConstructBallistaParts,
    df.job_type.ConstructCatapultParts,
    df.job_type.ConstructBoltThrowerParts,

    -- ConstructBlocks needs to be here even though the block COUNT
    -- stays vanilla. Four blocks from a log is a number people know
    -- and is not being changed; the 2600 that disappears making them
    -- is not, and that is what comes back as sawdust.
    --
    -- Membership in WASTE alone does nothing. HIJACK is what makes
    -- the memo poll record a job's input, and without a memo
    -- waste_output returns before it computes anything.
    df.job_type.ConstructBlocks,
}

-- ==========================================
-- WHICH LOSS CLASS A JOB IS IN
-- ==========================================
-- DECLARED AFTER WASTE ON PURPOSE. Written above the table it reads,
-- WASTE resolves as a nil GLOBAL rather than the local one line down,
-- the function silently never finds an override, and luac -p reports
-- nothing wrong because a forward reference to a local is legal Lua.
--
-- WASTE's value is an override only when it names a real LOSS_STREAMS
-- class. Every legacy 'SAWDUST' row falls through to the feedstock
-- classifier and behaves exactly as it always did, so the forty one
-- carpentry rows need no edit.
-- ==========================================
local function loss_class(memo, key)
    if not have_tuning() then return nil end
    local streams = tuning.T.LOSS_STREAMS
    if not streams then return nil end

    local override = WASTE[key]
    if override and streams[override] then return override end

    local cls = FEEDSTOCK_CLASS[memo.itype]
    if cls == 'GEM' and is_glass_mat(memo.type, memo.index) then
        cls = 'GLASS'
    elseif memo.itype == df.item_type.CORPSEPIECE then
        -- Overrides the table's BONE entirely rather than refining it,
        -- because a corpsepiece is as likely to be a hide as a bone and
        -- neither is the default. nil here means meat or fat, which
        -- owes nothing to a loss stream.
        cls = corpse_class(memo.type, memo.index)
    end
    if cls and streams[cls] then return cls end
    return nil
end

-- ==========================================
-- EVERY OTHER JOB THAT DESTROYS SOMETHING
-- ==========================================
-- The carpentry set above predates LOSS_STREAMS and is wood only.
-- These are the rest of the MAKE group: jobs where a dwarf turns a
-- measurable amount of material into a smaller finished thing and
-- vanilla drops the difference.
--
-- The value is the CLASS OVERRIDE. 'AUTO' means classify from the
-- feedstock, which is right wherever the item type already says what
-- the job worked: a stone quern memos a BOULDER, an iron helm memos a
-- BAR, a cloth bag memos CLOTH.
--
-- Two cannot be inferred and say so explicitly. SmeltOre memos a
-- BOULDER like any mason job, but an ore boulder becomes slag and a
-- microcline boulder becomes gravel, and the item cannot tell them
-- apart. MeltMetalObject memos a finished item whose type is not in
-- FEEDSTOCK_ORDER at all.
--
-- DELIBERATELY ABSENT, because they owe nothing and inventing a
-- byproduct for them would be exactly the arbitrary output this
-- system exists to remove:
--   MakeLye, MakePotashFromLye, MakePotashFromAsh  chemical
--     conversions, nothing is physically lost
--   MixDye, ShearCreature, MilkCreature            mixes and
--     harvests, no material destroyed
--   MakeRawGlass                                   feedstock is sand
--     in a bag, no classifiable feedstock item
--   ButcherAnimal                                  owed, but it is an
--     output count correction rather than a loss stream
--   MakeCheese, PrepareRawFish, ExtractFrom*, ProcessPlants*
--     food and plant feedstock, which FEEDSTOCK_CLASS has no entry
--     for yet; registering them now would log once and do nothing
-- ==========================================
local LOSS_JOBS = {
    -- Stone and general construction
    [df.job_type.ConstructBuilding]   = 'AUTO',
    [df.job_type.ConstructQuern]      = 'AUTO',
    [df.job_type.ConstructMillstone]  = 'AUTO',
    [df.job_type.ConstructSlab]       = 'AUTO',
    [df.job_type.ConstructBag]        = 'AUTO',

    -- Forge and anvil
    [df.job_type.MakeArmor]           = 'AUTO',
    [df.job_type.MakeHelm]            = 'AUTO',
    [df.job_type.MakePants]           = 'AUTO',
    [df.job_type.MakeGloves]          = 'AUTO',
    [df.job_type.MakeShoes]           = 'AUTO',
    [df.job_type.MakeBallistaArrowHead] = 'AUTO',
    [df.job_type.ForgeAnvil]          = 'AUTO',
    [df.job_type.MintCoins]           = 'AUTO',

    -- Craftsdwarf, any material
    [df.job_type.MakeFigurine]        = 'AUTO',
    [df.job_type.MakeAmulet]          = 'AUTO',
    [df.job_type.MakeScepter]         = 'AUTO',
    [df.job_type.MakeCrown]           = 'AUTO',
    [df.job_type.MakeRing]            = 'AUTO',
    [df.job_type.MakeEarring]         = 'AUTO',
    [df.job_type.MakeBracelet]        = 'AUTO',

    -- Gem and glass
    [df.job_type.CutGems]             = 'AUTO',
    [df.job_type.CutGlass]            = 'AUTO',
    [df.job_type.MakeGem]             = 'AUTO',

    -- Cloth and thread
    [df.job_type.WeaveCloth]          = 'AUTO',
    [df.job_type.SpinThread]          = 'AUTO',

    -- Cannot be inferred from the feedstock item
    [df.job_type.SmeltOre]            = 'ORE',
    [df.job_type.MeltMetalObject]     = 'METAL',
    [df.job_type.ExtractMetalStrands] = 'METAL',
}

-- WASTE carries the override, HIJACK carries membership. Both are
-- needed: without WASTE waste_output returns on its first line, and
-- without HIJACK memo_poll never records the job's input.
--
-- HIJACK is only filled where it is EMPTY. Several of these already
-- have byproduct specs and overwriting them with a blank table would
-- silently delete work that is already correct.
for jt, cls in pairs(LOSS_JOBS) do
    if jt then
        WASTE[jt] = cls
        if HIJACK[jt] == nil then HIJACK[jt] = {} end
    end
end

for _, jt in ipairs(SAWDUST_JOBS) do
    HIJACK[jt] = {
        -- EMPTY ON PURPOSE, like MakeCharcoal above. Membership is
        -- what makes the memo poll record the job's input; the
        -- byproducts themselves live in waste_output, which pays
        -- bark and sawdust from the VALUE the job measurably lost.
        --
        -- Bark used to sit here on a flat 0.25 chance. That model
        -- paid the same bark for a toy as for a bed and nothing for
        -- the loss behind either. Debarking happens during working,
        -- so bark now rides the loss stream at BYPRODUCT_BARK_SHARE
        -- of recovered value, species carried through by the memo
        -- exactly like sawdust.
    }
end


-- ==========================================
-- RESOLVERS
-- ==========================================
-- Both resolved at spawn time rather than cached. Injected tool
-- subtypes are array positions and they shift whenever a tool key is
-- added, so a number cached at load is a number that goes stale.
-- ==========================================
local function find_tool(id)
    local defs = df.global.world.raws.itemdefs.tools
    for i, td in ipairs(defs) do
        local ok, tid = pcall(function() return td.id end)
        if ok and tid == id then
            local ok2, sub = pcall(function() return td.subtype end)
            if ok2 and type(sub) == 'number' and sub >= 0 then return sub end
            return i
        end
    end
    return nil
end

-- The building the job was posted at. moveToGround drops an item on
-- the tile, which is not the same as being IN the workshop: the real
-- output is registered in the building's contained_items list, which
-- is what makes it show in the workshop's item list and stack with the
-- charcoal instead of sitting under it unnoticed.
-- ==========================================
-- NAMING A JOB IN THE LOG
-- ==========================================
-- df.job_type[job.job_type] answers "CustomReaction" for every raws
-- reaction in the game, so a log line built from it names the
-- MECHANISM and not the job. Three different reactions running at
-- once are three identical labels.
--
-- on_completed already solves this for its lookup key: a
-- CustomReaction keys on job.reaction_name instead. The warning paths
-- never got the same treatment, which is the whole reason a mill line
-- tells you nothing about what was being milled.
--
-- Falls back to the job_type name, then to the raw number, so this
-- can never be the thing that throws inside a log call.
local function job_label(job)
    local name = nil
    pcall(function()
        if job.job_type == df.job_type.CustomReaction then
            name = tostring(job.reaction_name)
        end
    end)
    if name and name ~= '' and name ~= 'nil' then return name end
    pcall(function()
        name = tostring(df.job_type[job.job_type] or job.job_type)
    end)
    return name or '?'
end

local function job_building(job)
    local bld = nil
    pcall(function() bld = dfhack.job.getHolder(job) end)
    return bld
end


-- ==========================================
-- SPAWN
-- ==========================================
-- createItem returns a LIST, because the underlying call can produce
-- several. Indexing [1] without checking throws on failure instead of
-- logging it.
--
-- Everything is inside pcall. A byproduct that fails to spawn is a
-- missing item; an error escaping into eventful is a broken hook for
-- every other listener in the process.
-- ==========================================
local function spawn(spec, bld)
    -- An optional predicate on the job, checked before the dice.
    -- Straw needs it because milling is not a cereal-only job, and the
    -- kitchen and still will need it for the same reason.
    local what = tostring(spec.tool_id or spec.mat)

    if spec.when then
        local ok, allow = pcall(spec.when, spec.job)

        -- ---- A THROW IS NOT A NO ----
        -- These shared one line and one silence, so a broken
        -- predicate looked exactly like a working one declining an
        -- input it was always meant to decline. A predicate reads
        -- live DF structures, so a throw is a real possibility and
        -- has to be visible at any level.
        if not ok then
            log_once('prederr:' .. what, 'ERROR', string.format(
                'predicate for %s ERRORED and was treated as no: %s',
                what, tostring(allow)), 'SPAWN')
            return false
        end

        if not allow then
            log('DETAIL', string.format('%s declined: predicate said no.', what), 'SPAWN')
            return false
        end
        log('DETAIL', string.format('%s passed its predicate.', what), 'SPAWN')
    end

    if spec.chance and math.random() >= spec.chance then
        log('DETAIL', string.format('%s lost its chance roll (%.2f).',
            what, spec.chance), 'SPAWN')
        return false
    end

    -- mat is either a token string, or a function taking the job and
    -- returning a matinfo. The function form is how a byproduct
    -- inherits its material from the job's input, so sawdust off an
    -- oak log is oak sawdust rather than one generic sawdust material.
    local mat
    if type(spec.mat) == 'function' then
        pcall(function() mat = spec.mat(spec.job) end)
    else
        mat = dfhack.matinfo.find(spec.mat)
    end
    if not mat then
        log('WARNING', 'material unresolved for ' .. tostring(spec.tool_id), 'SPAWN')
        return false
    end

    local subtype = -1
    if spec.tool_id then
        subtype = find_tool(spec.tool_id) or -1
        if subtype < 0 then
            log('WARNING', 'itemdef not found: ' .. tostring(spec.tool_id), 'SPAWN')
            return false
        end
    end

    local made = nil
    local ok = pcall(function()
        made = dfhack.items.createItem(df.global.world.units.active[0],
            spec.item_type, subtype, mat.type, mat.index)
    end)
    if not ok or type(made) ~= 'table' or not made[1] then
        log('ERROR', 'create failed for ' .. tostring(spec.mat), 'SPAWN')
        return false
    end

    -- ---- DIMENSION ----
    -- createItem does not set one, and every BAR the module authors
    -- in JSON carries 150. A bar spawned without it is not the same
    -- object as the identical bar a reaction made.
    --
    -- OPT IN, so nothing that spawns today changes. The charcoal and
    -- cinder bars below have never set it and are left exactly as
    -- they are: if they are wrong they have been wrong in every save
    -- since they shipped, and correcting them blind would move the
    -- value of coal already sitting in stockpiles. That wants a
    -- probe on a live bar, not a guess here.
    if spec.dimension then
        pcall(function() made[1].dimension = spec.dimension end)
    end

    -- TEMP is what a reaction product is: sitting in the workshop,
    -- haulable, stockpileable, gone when someone carries it off.
    --
    -- NOTE FOR LATER, this was worth finding. Passing 0 here is PERM,
    -- not "loose". PERM makes the item a semi-permanent part of the
    -- building, drawn with a purple infinity glyph, the same treatment
    -- as an item on display or the anvil in a forge. It cannot be
    -- hauled and it is destroyed with the building.
    --
    -- That is wrong for a byproduct and right for several things we do
    -- not have yet: a workshop that visibly holds its charge, a
    -- decorated or upgraded building, a furnace that shows its lining.
    -- We can put an arbitrary item permanently inside any building
    -- with one call and no raws. Worth coming back to.
    --
    -- force_in_building stays false. It is for items a trap is holding
    -- temporarily, not for reaction output.
    for _, item in ipairs(made) do
        -- Recorded before placement, so the delete pass can never take
        -- this script's own output for vanilla's.
        pcall(function() ours[item.id] = true end)
        local placed = false
        pcall(function()
            placed = dfhack.items.moveToBuilding(item, bld,
                df.building_item_role_type.TEMP, false)
        end)
        if not placed then
            pcall(function()
                dfhack.items.moveToGround(item, bld.centerx
                    and { x = bld.centerx, y = bld.centery, z = bld.z }
                    or item.pos)
            end)
        end
    end
    return true
end

-- Runs while the reagents are still attached. Records nothing unless
-- the job is one we hijack and a WOOD item is on it, so the table only
-- ever holds carpentry jobs in flight.
-- ==========================================
-- WOOD MEMO POLL
-- ==========================================
-- Neither event can see the log. onJobInitiated fires when the job is
-- posted, before a hauler has fetched anything, so job.items is empty.
-- onJobCompleted fires after the reagents are consumed, so it is empty
-- again. Confirmed both ways in game: items=0 at initiate, items=1
-- mid-job, items=0 at completion.
--
-- The window between them is only visible by looking. This walks the
-- job list on a slow poll and records the wood for any hijacked job
-- that currently has some attached. A carpentry job holds its log for
-- the whole build, which is many seconds, so 100 frames cannot miss it.
--
-- Idempotent: a job already memoed is skipped.
-- ==========================================
-- Consecutive polls a job has been seen with no recognisable
-- feedstock. Exists so the diagnostic below can wait for the hauler
-- instead of reporting the empty instant before one arrives. Cleared
-- alongside wood_memo when the job leaves.
local nofeed_polls = {}

local function memo_poll()
    if not dfhack.isMapLoaded() or not _G.refinish_active then return end
    local utils = require('utils')
    pcall(function()
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            -- Built in jobs key on job_type. Raws reactions key on
            -- their code and their job_type is always CustomReaction,
            -- exactly as on_completed resolves it. This line read the
            -- bare job_type, so HIJACK's string keyed entries were
            -- never found here and the vanilla coke jobs got no memo
            -- at all: they could spawn a fixed byproduct, which needs
            -- nothing, but never price anything, which needs this.
            local mkey = job.job_type
            if mkey == df.job_type.CustomReaction then
                mkey = tostring(job.reaction_name)
            end
            if HIJACK[mkey] and not wood_memo[job.id] then
                -- Total input volume across EVERY attached item, for
                -- measured waste. The material memo below still keys
                -- on wood because that is what decides species, but
                -- the loss calculation needs the lot: a traction bench
                -- takes a table, mechanisms and a rope.
                -- ---- THE FUEL BAR IS NOT FEEDSTOCK ----
                -- DF's own fuel filter carries reagent_index -1: it is
                -- not a reaction reagent, it is the furnace burning.
                --
                -- CUSTOM REACTIONS ONLY, and this is the whole point.
                -- reagent_index is an index INTO reaction.reagents. A
                -- hardcoded job has no reaction behind it, so DF writes
                -- -1 on EVERY filter, and a bare -1 test therefore
                -- calls the log in a carpentry job fuel. MEASURED the
                -- expensive way: it excluded every item from total_in,
                -- left the feedstock search with nothing to find, wrote
                -- no memo at all, and waste_output returned silently
                -- because a missing memo says nothing when the job type
                -- is in HIJACK. Forty one carpentry job types stopped
                -- producing anything and the log stayed clean.
                --
                -- Hardcoded jobs that DO burn fuel, SmeltOre and the
                -- like, need a different test because -1 cannot carry
                -- the meaning there either. None are registered yet,
                -- so that rule lands with the jobs that need it.
                local is_custom = false
                pcall(function()
                    is_custom = (job.job_type == df.job_type.CustomReaction)
                end)
                local function is_fuel(iref)
                    -- Hardcoded job: no reaction, so the filter index
                    -- cannot say. The BAR itself does.
                    if not is_custom then
                        return bar_is_fuel(iref.item)
                    end
                    local ri = nil
                    pcall(function()
                        local ix = iref.job_item_idx
                        if ix and ix >= 0 then
                            ri = job.job_items.elements[ix].reagent_index
                        end
                    end)
                    return ri == -1
                end

                -- ---- ONE PCALL PER ITEM, NOT ONE PER LOOP ----
                -- Wrapped around the whole loop, a single unreadable
                -- reference throws, pcall swallows it, and every
                -- REMAINING item is abandoned. A job whose first
                -- attachment is not yet readable then measures as empty
                -- no matter how many times it is polled, while a single
                -- item job never shows the fault at all.
                local total_in = 0
                for _, iref in ipairs(job.items) do
                    pcall(function()
                        if not is_fuel(iref) then
                            local v = iref.item:getVolume()
                            if v and v > 0 then total_in = total_in + v end
                        end
                    end)
                end

                -- ---- WHICH ITEM IS THE FEEDSTOCK ----
                -- This took the first WOOD and nothing else, which is
                -- correct for every carpentry and charring job and
                -- blind to a coking job, whose feedstock is a BOULDER.
                --
                -- Wood still wins where a job has both, so no existing
                -- job can start memoing a stone it used to ignore. The
                -- boulder case only fires when there is no wood at all.
                -- FEEDSTOCK_ORDER is the priority list, and the order
                -- is load bearing rather than cosmetic. WOOD is first
                -- so no carpentry job changes what it memos. BOULDER
                -- is second so no coking job starts memoing a bar.
                -- Everything after those two is new ground and cannot
                -- disturb what already works.
                -- Same fix as above, one pcall per item. This loop had
                -- the same shape and the same failure, and it is the one
                -- that decides whether a memo gets written at all.
                local want, saw = nil, {}
                local n_items, n_unread = 0, 0
                local have = {}
                for _, iref in ipairs(job.items) do
                    n_items = n_items + 1
                    local ok = pcall(function()
                        if not is_fuel(iref) then
                            local t = iref.item:getType()
                            have[t] = true
                            -- Name resolved HERE. By the time
                            -- waste_output runs the items are consumed
                            -- and there is nothing left to ask.
                            --
                            -- ---- AND THE SAME IS TRUE OF THE REST ----
                            -- The type alone says BAG and PLANT, which
                            -- describes the shape of the job and not
                            -- the job. What it was and how much of it
                            -- are the two facts that make the line
                            -- readable, and they are just as gone once
                            -- the reagents are consumed.
                            local label = tostring(df.item_type[t] or t)

                            local mname = nil
                            pcall(function()
                                local m = dfhack.matinfo.decode(iref.item)
                                if m then mname = m:getToken() end
                            end)
                            if mname then label = label .. ' ' .. mname end

                            -- Stacks only. A lone item saying "x1"
                            -- is noise, and 7000 rye is the entire
                            -- point of the line.
                            local sz = 1
                            pcall(function()
                                sz = iref.item.stack_size or 1
                            end)
                            if sz > 1 then
                                label = label .. ' x' .. tostring(sz)
                            end

                            saw[t] = label
                        end
                    end)
                    if not ok then n_unread = n_unread + 1 end
                end
                pcall(function()
                    for _, t in ipairs(FEEDSTOCK_ORDER) do
                        if have[t] then want = t break end
                    end
                end)

                -- ---- NOTHING IN THE PRIORITY LIST MATCHED ----
                -- Three situations that used to look identical, now
                -- separated by the counts:
                --   0 attached          polled before the hauler
                --                       arrived. Harmless, and the next
                --                       poll retries.
                --   attached, unread    references present but not
                --                       readable. This is the shape
                --                       that hid behind the loop wide
                --                       pcall and made a bone amulet
                --                       report nothing for its whole
                --                       life.
                --   attached, readable  a real item type missing from
                --                       FEEDSTOCK_ORDER, and the line
                --                       names it so it can be added.
                -- ---- NOTHING IN THE PRIORITY LIST MATCHED ----
                -- KEYED ON THE JOB, AND NOT ON THE FIRST POLL. Keyed on
                -- job TYPE, log_once showed the first instant of the
                -- first such job ever seen, which is always before the
                -- hauler arrives, and stayed silent for the sixty polls
                -- afterwards that actually mattered. It reported "0
                -- attached" and that told us nothing at all.
                --
                -- Now it counts consecutive empty polls per job and
                -- speaks once, after the hauler has had roughly five
                -- seconds to turn up. A job still showing nothing by
                -- then is not a timing artefact.
                --
                -- Filter count is in the line because it separates the
                -- two remaining cases: filters present with no items
                -- means DF never attached anything we can see, while no
                -- filters at all means this job does not take a reagent
                -- through the job item path in the first place.
                if want == nil then
                    -- ---- ONLY COUNT POLLS WHERE THE DWARF IS WORKING ----
                    -- A posted job with no items yet is a hauler still
                    -- walking, which is completely normal and can take
                    -- far longer than five seconds. Job 363 tripped the
                    -- old threshold purely by waiting for someone to go
                    -- fetch a bone, which is not a fault and not worth
                    -- a line.
                    --
                    -- job.flags.working means the dwarf is standing at
                    -- the building doing the work, so the reagents
                    -- should already be attached. Nothing usable AT
                    -- THAT POINT is the real anomaly, and it is exactly
                    -- the shape the corpsepiece throw produced.
                    local working = false
                    pcall(function() working = job.flags.working end)
                    if working then
                        local n = (nofeed_polls[job.id] or 0) + 1
                        nofeed_polls[job.id] = n
                        if n == 5 then
                            local list = {}
                            for _, name in pairs(saw) do
                                table.insert(list, name)
                            end
                            table.sort(list)
                            local n_filt = -1
                            pcall(function()
                                n_filt = #job.job_items.elements
                            end)
                            -- DETAIL: expected on any job built from a material with no
                            -- FEEDSTOCK_CLASS entry, so it is not a fault by itself.
                            log('DETAIL', string.format(
                                'FEEDSTOCK: %s job %d WORKING with'
                                .. ' nothing usable after %d polls: %d'
                                .. ' attached, %d unreadable, %d'
                                .. ' filter(s), types [%s].',
                                job_label(job),
                                job.id, n, n_items, n_unread, n_filt,
                                #list > 0 and table.concat(list, ', ')
                                           or 'none readable'), 'FEEDSTOCK')
                        end
                    end
                    want = df.item_type.BOULDER
                else
                    nofeed_polls[job.id] = nil
                end

                -- Third loop with the same flaw as the two above, and
                -- the worst placed of the three: it sits inside the
                -- poll wide pcall that wraps the WHOLE job list, so one
                -- unreadable reference here abandoned every remaining
                -- job in the fort for that poll, not just this one.
                for _, iref in ipairs(job.items) do
                    local match = false
                    pcall(function()
                        match = (iref.item:getType() == want)
                                and not is_fuel(iref)
                    end)
                    if match then
                        -- Volume as well as material. A log is always
                        -- 5000, confirmed twice, but reading it costs
                        -- nothing and means a mod that changes log
                        -- size is handled without an edit here.
                        local vol = nil
                        pcall(function() vol = iref.item:getVolume() end)

                        -- The workshop's contents BEFORE completion.
                        -- Anything present afterwards and absent here
                        -- is this job's output. Highest item id would
                        -- usually work and would be silently wrong the
                        -- one time two furnaces finish together.
                        local seen = {}
                        pcall(function()
                            local b = dfhack.job.getHolder(job)
                            if b then
                                for _, ci in ipairs(b.contained_items) do
                                    if ci.item then seen[ci.item.id] = true end
                                end
                            end
                        end)

                        -- The item's name, purely so the log can say
                        -- what the sawdust came from. Reading the
                        -- density back tells you the species is right
                        -- but not which log it was.
                        local desc = '?'
                        pcall(function()
                            desc = dfhack.items.getDescription(iref.item, 0)
                        end)

                        -- ---- NOT EVERY ITEM HAS mat_type ----
                        -- item_corpsepiecest carries no material pair
                        -- at all: bone, shell, horn and tooth store
                        -- race and caste instead. Reading mat_type on
                        -- one THROWS, and this assignment sits inside
                        -- the poll wide pcall, so the throw was
                        -- invisible and it abandoned every REMAINING
                        -- job in the list for that poll as well.
                        --
                        -- That is why a bone amulet wrote no memo and
                        -- why the feedstock diagnostic never fired: a
                        -- bone IS in FEEDSTOCK_ORDER, so want was never
                        -- nil and the empty poll counter kept
                        -- resetting. The failure sat one line past the
                        -- place being watched.
                        --
                        -- matinfo.decode answers for both shapes, the
                        -- same reason the ghost uses it on corpses
                        -- rather than getMaterial, which returns -1
                        -- there.
                        local mt, mi = nil, nil
                        pcall(function()
                            mt = iref.item.mat_type
                            mi = iref.item.mat_index
                        end)
                        if mt == nil then
                            pcall(function()
                                local m = dfhack.matinfo.decode(iref.item)
                                if m then mt, mi = m.type, m.index end
                            end)
                        end

                        if mt == nil then
                            -- Neither route worked. Says so instead of
                            -- writing a memo with a nil material that
                            -- would fail again further down.
                            log_once('nomat:' .. tostring(job.job_type), 'WARNING', string.format(
                                    'FEEDSTOCK: %s fed a %s whose'
                                    .. ' material reads through neither'
                                    .. ' mat_type nor matinfo.decode.'
                                    .. ' No memo, so nothing is owed.',
                                    job_label(job),
                                    tostring(df.item_type[want] or want)), 'FEEDSTOCK')
                        else
                            wood_memo[job.id] = {
                                type  = mt,
                                index = mi,
                                -- Which item type won the priority
                                -- list. waste_output turns this into a
                                -- LOSS_STREAMS class, and it cannot be
                                -- re-derived at completion because the
                                -- items are gone by then.
                                itype = want,
                                desc  = desc,
                                vol   = vol,
                                seen  = seen,
                                total_in = total_in,
                            }
                        end
                        break
                    end
                end
            end
        end
    end)
end

-- ==========================================
-- WASTE OUTPUT
-- ==========================================
-- Gives back part of what a job destroyed, sized from what it
-- actually destroyed rather than from a number written here.
--
-- Runs alongside whatever else the job does. A carpentry job keeps
-- its vanilla furniture untouched and simply gains the sawdust.
--
-- Banked like everything else, so a job losing less than one whole
-- sawdust does not lose the value, and so the item cap can hold
-- excess over rather than throwing it away.
-- ==========================================
local function waste_output(job, bld, key)
    if not WASTE[key] then return end
    if not have_tuning() then return end
    if not tuning.T.WASTE_ENABLED then return end
    -- Per stream switches are checked per stream below. The old
    -- single kind gate here would let BYPRODUCTS.SAWDUST = false
    -- silence bark along with it.

    local memo = wood_memo[job.id]
    if not memo or not memo.total_in then
        -- ---- THIS RETURN USED TO BE SILENT AND IT COST THREE RUNS ----
        -- A job in HIJACK with no memo returned without a word, on the
        -- reasoning that a rock door legitimately owes no sawdust. Then
        -- is_fuel started excluding every item on every hardcoded job,
        -- no memo was ever written, all forty one carpentry types
        -- stopped producing, and the log stayed perfectly clean. A
        -- correct silence and a total failure looked identical.
        --
        -- Both cases now speak, once per job type, and the wording
        -- separates them. Missing from HIJACK is a config fault.
        -- Present in HIJACK with no memo means memo_poll looked and
        -- found no feedstock it recognises, which is either fine or
        -- the bug above, and the next line up in the log says which.
        if HIJACK[key] == nil then
            log_once('nomemo:' .. tostring(key), 'WARNING', string.format(
                '%s is in WASTE but has no memo and no HIJACK entry.',
                tostring(df.job_type[key])), 'CONFIG')
        else
            log_once('nofeed:' .. tostring(key), 'DETAIL', string.format(
                '%s completed with no memo. memo_poll found no'
                .. ' feedstock it recognises in this job, so nothing'
                .. ' is owed. Expected on a job built from a material'
                .. ' with no FEEDSTOCK_CLASS entry; NOT expected on'
                .. ' wood, stone, bar, leather, cloth, gem or bone.',
                tostring(df.job_type[key])), 'WASTE')
        end
        return
    end

    -- What came out. Same diff the REPLACE path uses: anything in the
    -- building now that was not there before and is not ours.
    local out_vol = 0
    pcall(function()
        local seen = memo.seen or {}
        for _, ci in ipairs(bld.contained_items) do
            local it = ci.item
            if it and not seen[it.id] and not ours[it.id] then
                local v = it:getVolume()
                if v and v > 0 then out_vol = out_vol + v end
            end
        end
    end)

    local lost = memo.total_in - out_vol
    if lost <= 0 then
        -- ---- THE LAST SILENT RETURN ----
        -- A job whose output is at least as big as its input destroyed
        -- nothing, so it owes nothing, and that is a real and common
        -- case: a cloth bag is about the size of the cloth it was
        -- sewn from. But silent, it is indistinguishable from a
        -- broken one, and "no logs at all" on clothing and bags is
        -- exactly what it produced.
        --
        -- Once per job type, with both numbers, so the reason is in
        -- the line rather than in someone's head.
        log_once('noloss:' .. tostring(key), 'DETAIL', string.format(
            '%s: %s went in at %d and came out at %d, so nothing was'
            .. ' lost and nothing is owed. Correct where the product'
            .. ' is about the size of its stock; suspicious if the'
            .. ' output should obviously be smaller.',
            tostring(df.job_type[key]), tostring(memo.desc or '?'),
            memo.total_in, out_vol), 'WASTE')
        return
    end

    -- ---- WHICH CLASS OF LOSS THIS IS ----
    -- No class means the feedstock is something LOSS_STREAMS has no
    -- entry for, which is usually legitimate rather than a fault: a
    -- rock door owes no sawdust and never did.
    --
    -- BUT IT SAYS WHY. Three silent returns went in here and the very
    -- next run produced no byproducts and no log line at all, which
    -- left no way to tell a correct silence from a broken one without
    -- reading the source. A guard that cannot be observed is a guard
    -- that will cost a day the second time it bites. Once per job
    -- type, so a fort full of rock doors says it once.
    local cls = loss_class(memo, key)
    if not cls then
        log_once('noclass:' .. tostring(key), 'DETAIL', string.format(
            'no loss class for %s: feedstock item type %s, WASTE says'
            .. ' %s. Nothing owed, which is correct for a job that ran'
            .. ' on a material with no LOSS_STREAMS entry.',
            tostring(df.job_type[key]),
            tostring(memo.itype and df.item_type[memo.itype] or memo.itype),
            tostring(WASTE[key])), 'WASTE')
        return
    end

    local spec_cls = tuning.T.LOSS_STREAMS[cls]
    if not spec_cls or not spec_cls.streams then
        log_once('noclassdef:' .. cls, 'ERROR', string.format(
            'class %s has no streams block in LOSS_STREAMS. This one'
            .. ' IS a config fault: the classifier named a class the'
            .. ' tuning file does not define.', cls), 'CONFIG')
        return
    end
    if (spec_cls.recovery or 0) <= 0 then
        log_once('zerorec:' .. cls, 'DETAIL', string.format(
            'class %s has recovery 0, so its loss is deliberately not'
            .. ' recovered. Nothing is broken.', cls), 'WASTE')
        return
    end

    local mat = nil
    pcall(function()
        mat = dfhack.matinfo.decode(memo.type, memo.index)
    end)
    local dens = nil
    pcall(function() dens = mat.material.solid_density end)

    -- ---- TWO WAYS TO PRICE A LOSS, AND THEY MUST NOT MIX ----
    -- VALUE runs the loss through the fuel curve, so a dense hardwood
    -- pays more than a softwood, and the bank holds CHARCOAL VALUE.
    -- Right only for things that burn, because yield() is the fuel
    -- curve and nothing else.
    --
    -- VOLUME counts raw volume and the bank holds volume. Right for
    -- everything recovered as mass. Pricing a rock on the fuel curve
    -- would mint free fuel out of a boulder.
    --
    -- SEPARATE BANK PREFIXES, and that is the load bearing part. The
    -- old BANK_WASTE keys held volume, and when the code moved to
    -- value the two meanings shared a key and a volume balance paid
    -- out as fuel. BANK_BP_ is value, BANK_BV_ is volume, and a key
    -- written under one meaning can never be read under the other.
    --
    -- tuning.T rather than a bare T. T is a local inside payout(), not
    -- a file level one, so referring to it here resolved as a nil
    -- global. have_tuning() above already guarantees tuning.T exists.
    local by_value = (spec_cls.mode ~= 'VOLUME')
    local prefix   = by_value and 'BANK_BP_' or 'BANK_BV_'

    local recovered
    if by_value then
        recovered = tuning.yield(lost, cls, dens) * spec_cls.recovery
    else
        recovered = lost * spec_cls.recovery
    end

    -- ---- THE CAP IS A SAFETY VALVE, NOT A GOVERNOR ----
    -- Per class first, global second. A cap that sits below the true
    -- output does not reduce the output, it STRANDS it: the excess
    -- stays banked, the next job adds more than the cap can pay, and
    -- the purse grows forever while the declared recovery rate
    -- quietly becomes a lie. Measured on stone at the first sizing:
    -- one block job wanted 19 gravel against a cap of 4.
    --
    -- So the real output sets the number and the cap only catches a
    -- runaway. When it does bite it SAYS SO, once per form, because
    -- value disappearing into a bank with nothing in the log is the
    -- kind of silence that costs a week to find.
    local cap = spec_cls.max_items or tuning.T.WASTE_MAX_ITEMS

    local bank = bank_get()
    local report = {}
    for _, st in ipairs(spec_cls.streams) do
        local enabled = not (tuning.T.BYPRODUCTS
            and tuning.T.BYPRODUCTS[st.kind] == false)
        if enabled and (st.share or 0) > 0 then
            -- Keyed on the FORM, not the class, so a stone dust
            -- remainder and a bone dust remainder share one purse.
            -- Deliberate, and it matches how the wood banks already
            -- work: banks hold worth, and only minted ITEMS carry
            -- species.
            local bkey = prefix .. st.kind
            -- Same race, same fix. waste_output already carries bld.
            if bld then bkey = bkey .. '@' .. tostring(bld.id) end

            local unit
            if by_value then
                unit = tuning.yield(st.vol, cls, dens)
            else
                unit = st.vol
            end

            local projected = (bank[bkey] or 0) + recovered * st.share
            local n = 0
            if unit > 0 then n = math.floor(projected / unit) end
            if cap and n > cap then
                log_once('cap:' .. cls .. ':' .. st.kind, 'INFO', string.format(
                    'CAP: %s %s wanted %d item(s) and the cap is %d.'
                    .. ' The rest stays banked and the bank will keep'
                    .. ' growing until the cap is raised or the'
                    .. ' recovery lowered.', cls, st.kind, n, cap), 'CAP')
                n = cap
            end
            local made = 0
            if n < 1 then
                bank[bkey] = projected
            else
                bank[bkey] = projected - (n * unit)

                -- ---- FORM VERSUS SUBSTANCE ----
                -- No mat on the stream and the byproduct INHERITS the
                -- feedstock, so a feather wood door gives feather wood
                -- bark and a microcline block gives microcline dust.
                -- mat as a FUNCTION is the form spawn provides for
                -- exactly that.
                --
                -- A stream that names a mat is a substance the input
                -- was not: scale is iron oxide rather than iron and
                -- slag is the gangue rather than the ore, so neither
                -- can inherit and both say what they are.
                local matspec
                if st.mat then
                    matspec = st.mat
                else
                    matspec = function()
                                  return dfhack.matinfo.decode(
                                      memo.type, memo.index)
                              end
                end

                local spec = {
                    item_type = df.item_type.TOOL,
                    tool_id   = 'MAKING_FUEL_' .. st.kind,
                    mat       = matspec,
                    count     = n,
                    job       = job,
                }
                for _ = 1, n do
                    if spawn(spec, bld) then made = made + 1 end
                end
            end
            table.insert(report, string.format('%s %d (%.3f/%.3f)',
                string.lower(st.kind), made, bank[bkey], unit))
        end
    end

    log('DETAIL', string.format('%s: %s -> %d lost, %s %.3f in | %s  class=%s d=%s',
        tostring(df.job_type[key]), tostring(memo.desc or '?'),
        lost, by_value and 'value' or 'volume', recovered,
        table.concat(report, ' | '), cls, tostring(dens)), 'WASTE')
end

-- ==========================================
-- ADAPTIVE OUTPUT
-- ==========================================
-- Recomputes a vanilla job's output from the properties of what went
-- into it.
--
-- Vanilla has all the data and does not use it. Seventy woods carry a
-- solid_density from 100 to 1250 and MakeCharcoal returns one bar for
-- every one of them, so the species is decoration. MakeAsh does the
-- same with ash. Both are hardcoded job types with no reaction
-- object, so the ghost swap that handles custom reactions cannot
-- reach them. Letting the job finish and correcting the result is
-- the only door.
--
-- CONFIRMED BY PROBE before this was written: the input is readable
-- from the memo, and the output IS already in the workshop when
-- onJobCompleted fires, so deletion is inline.
--
-- TWO INDEPENDENT GUARDS ON DELETION
--   Ownership. Nothing this script created is ever deletable, so a
--   spawned cinder cannot be mistaken for vanilla output by the next
--   job to finish in the same furnace.
--   Signature. Only the job's own known vanilla product is removed.
--   Anything new and unrecognised is logged and left alone, which is
--   also what happens if a mod or a DF version changes what the
--   furnace makes. It fails inert rather than destructive.
-- ==========================================
local function adaptive_output(job, bld, key, mode)
    -- Which burn this is decides the primary and its signature. A
    -- job in an adaptive mode with no burn entry has nothing to
    -- price, so it is left exactly as vanilla left it.
    local burn = BURNS[key]
    if not burn then
        log_once('noburn:' .. tostring(key), 'WARNING', string.format(
            '%s is in MODES but not in BURNS, left untouched.',
            tostring(df.job_type[key])), 'CONFIG')
        return
    end

    local value, tok, dens, vol, class = input_value(job)
    if not value then
        -- No readable input, or no tuning. Leave the job exactly as
        -- vanilla left it. Guessing at a number here is how a fuel
        -- economy quietly drifts.
        log('WARNING', string.format('%s: input unreadable, left untouched.',
            tostring(key)), 'ADAPTIVE')
        return
    end

    -- ---- WHAT VANILLA MADE ----
    local new_items = {}
    pcall(function()
        local seen = (wood_memo[job.id] and wood_memo[job.id].seen) or {}
        for _, ci in ipairs(bld.contained_items) do
            local it = ci.item
            if it and not seen[it.id] and not ours[it.id] then
                table.insert(new_items, it)
            end
        end
    end)

    -- ---- THE PRIMARY VANILLA PAID ----
    -- Counted in every mode, removed only in REPLACE. TOP_UP needs
    -- the count without the removal: it credits the shortfall over
    -- what vanilla already gave, and a count that only rose on
    -- removal made it credit the whole value on top of the free bar.
    local found, removed = 0, 0
    for _, it in ipairs(new_items) do
        if burn.vanilla(it) then
            found = found + 1
            if mode == MODE_REPLACE then
                local ok = pcall(function() dfhack.items.remove(it) end)
                if ok then removed = removed + 1 end
            end
        else
            local d = '?'
            pcall(function() d = dfhack.items.getDescription(it, 0) end)
            log('WARNING', string.format(
                '%s produced an unrecognised item, left alone: %s',
                tostring(key), tostring(d)), 'ADAPTIVE')
        end
    end

    -- TOP_UP credits only what vanilla did not already give. REPLACE
    -- took the bar back, so it credits the whole value.
    local credit = value
    if mode == MODE_TOP_UP then
        credit = value - found
        if credit <= 0 then return end
    end

    -- ---- THE TWO STREAMS ----
    -- The primary takes the whole credit. The secondary is the OTHER
    -- burn's product at its tuned fraction of that. Both draw on the
    -- pools the ghost shares, so the stray char from a MakeAsh job
    -- finishes a cinder that CHAR_BARREL started.
    local T = tuning.T

    -- ---- SPAWN, HOISTED ----
    -- out and emit used to sit below the payouts. They are above them
    -- now because the coal branch has to spawn and return BEFORE the
    -- wood payouts run: those write BANK_CHARCOAL and BANK_ASH, and a
    -- coking job must not move either.
    local out = {}
    local function emit(n, item_type, tool_id, mat, label, dim)
        if n < 1 then return end
        local spec = {
            item_type = item_type,
            tool_id   = tool_id,
            mat       = mat,
            count     = n,
            job       = job,
            dimension = dim,
        }
        for _ = 1, n do
            if spawn(spec, bld) then
                table.insert(out, label)
            end
        end
    end

    -- ---- COAL: THE SAME SHAPE, THE OTHER LADDER ----
    -- A smelter coking job is a wood furnace charring job with coal in
    -- it. One primary on a packing ladder, and one leftover the fire
    -- cannot help making. Coke packs into green coke four at a time
    -- and pays its fraction in breeze, exactly as charcoal packs into
    -- char and pays in cinders.
    --
    -- WHY THE PLANT MATERIAL AND NOT BUILTIN COAL:COKE. The charcoal
    -- line below still emits a builtin because it predates the plant
    -- host, and the coal watcher converts it a tick later. Emitting
    -- the plant material outright means no builtin coal bar ever
    -- exists, which is the watcher's stated invariant, and it matches
    -- the two rungs beside it that were always plant materials.
    --
    -- COAL ASH IS A BAR, AND FIXED. A bar of 150 like every other
    -- ash, not the boulder it used to be: ash is ash whatever fire
    -- made it, and nothing outside this module consumes it, so the
    -- change costs no cross module contract.
    --
    -- Still ONE per job on the same coal_ash_enabled switch. It is
    -- spawned here only because the extras table fires in BYPRODUCT
    -- and these jobs are REPLACE now. Turning it into a fifth banked
    -- currency is a processing question, not this one.
    if burn.family == 'COAL' then
        local coke, packed, breeze, k_paid, k_proj, k_carry =
            payout_ladder(credit, bld, LADDER_COAL)

        emit(coke, df.item_type.BAR, nil,
             'PLANT_MAT:MAKING_FUEL_COAL_HOST:COKE', 'coke')
        emit(packed, df.item_type.BAR, nil,
             'PLANT_MAT:MAKING_FUEL_COAL_HOST:GREEN_COKE', 'green coke')
        emit(breeze, df.item_type.BAR, nil,
             'PLANT_MAT:MAKING_FUEL_COAL_HOST:BREEZE_COKE', 'breeze')
        -- Coal ash is a CURRENCY now, not a flat bar. Same
        -- arithmetic the ghost uses on the retort side, on the
        -- same BANK_ASH_COAL key, so a smelter and a retort in
        -- the same fort fill one pocket per building rather than
        -- paying two different rates for the same rock.
        local coal_ash, ca_paid, ca_proj, ca_carry = 0, 0, 0, 0
        if coal_ash_enabled() then
            coal_ash, ca_paid, ca_proj, ca_carry =
                payout_ash(credit * T.ASH_FROM_COKING, bld,
                           'ASH_COAL')
            emit(coal_ash, df.item_type.BAR, nil,
                 'PLANT_MAT:MAKING_FUEL_COAL_HOST:ASH_COAL',
                 'coal ash', 150)
        end

        local d = string.format(
            '%s d=%s vol=%s class=%s -> %.4f | coke bank %.4f'
            .. ' paid %.4f carry %.4f | coal ash bank %.4f'
            .. ' paid %.4f carry %.4f',
            tostring(tok), tostring(dens), tostring(vol),
            tostring(class), value,
            k_proj - credit, k_paid, k_carry,
            ca_proj - (credit * T.ASH_FROM_COKING), ca_paid, ca_carry)
        if #out == 0 then
            announce(burn.announce, d)
        else
            log('YIELD', string.format('%s: %s (removed %d vanilla)  %s',
                tostring(key), table.concat(out, ', '), removed, d), 'ADAPTIVE')
        end
        return
    end

    local charcoal_in, ash_in
    if burn.primary == 'ASH' then
        ash_in      = credit
        charcoal_in = credit * T.CHARCOAL_FROM_ASHING
    else
        charcoal_in = credit
        ash_in      = credit * T.ASH_FROM_CHARRING
    end

    local charcoal, boulders, cinders, c_paid, c_proj, c_carry =
        payout_ladder(charcoal_in, bld, LADDER_WOOD)
    local ash, a_paid, a_proj, a_carry = payout_ash(ash_in, bld)

    emit(charcoal, df.item_type.BAR, nil, 'COAL:CHARCOAL', 'charcoal')
    emit(boulders, df.item_type.BOULDER, nil,
         'INORGANIC:MAKING_FUEL_CHAR', 'boulder')
    emit(cinders, df.item_type.BAR, nil,
         'PLANT_MAT:MAKING_FUEL_COAL_HOST:CINDER', 'cinder')
    -- Builtin ASH by number, the way the coal watcher and the memo
    -- decode materials, handed over as a function because that is
    -- the form spawn takes for anything that is not a token string.
    emit(ash, df.item_type.BAR, nil,
         function()
             return dfhack.matinfo.decode(df.builtin_mats.ASH, -1)
         end,
         'ash')

    local detail = string.format(
        '%s d=%s vol=%s -> %.4f | charcoal bank %.4f paid %.4f'
        .. ' carry %.4f | ash bank %.4f paid %.4f carry %.4f',
        tostring(tok), tostring(dens), tostring(vol), value,
        c_proj - charcoal_in, c_paid, c_carry,
        a_proj - ash_in, a_paid, a_carry)

    if #out == 0 then
        -- The case the announcement exists for. A log went in, the bar
        -- came out and was removed, and nothing visible replaced it.
        -- Without a word on screen the only available reading is that
        -- the furnace ate it.
        announce(burn.announce, detail)
    else
        log('YIELD', string.format('%s: %s (removed %d vanilla)  %s',
            tostring(key), table.concat(out, ', '), removed, detail), 'ADAPTIVE')
    end
end

-- ==========================================
-- THE PRODUCT GUARD
-- ==========================================
-- THE DEFECT, measured end to end: a blue steel battle axe came out
-- of a normal forge made of PLANT:MAKING_FUEL_COAL_HOST:CHARCOAL.
-- Not mis-coloured. Literally made of fuel.
--
-- WHY DF GETS IT WRONG. A hardcoded forge job attaches two bars, the
-- metal and the fuel, and DF decides which is which by asking
-- whether a bar is builtin COAL. Every fuel this module ships is a
-- module material instead, because builtin COAL is never tagged (the
-- fuel-access ruling: tagging it made the menu key burnable). DF's
-- test then identifies NEITHER bar as fuel and the product takes its
-- material from the wrong one. A magma forge posts no fuel filter,
-- has one bar to choose from, and is correct. That was the control.
--
-- WHY THE MEMO IS THE ANSWER. memo_poll already recorded this job's
-- feedstock mid-job with the fuel bar excluded by is_fuel, so
-- memo.type and memo.index ARE the metal the player picked. The memo
-- that prices the job's waste now also repairs its product. Nothing
-- new is polled and no second completion hook is added.
--
-- WHY memo.seen FINDS THE OUTPUT. seen is the workshop's contents
-- snapshotted before completion, so anything present now and absent
-- there is this job's output. Highest item id would usually work and
-- would be silently wrong the one time two forges finish together.
--
-- WHY IT RUNS FIRST. Called before adaptive_output and waste_output,
-- so the only new items in the building are DF's own products. RM's
-- byproducts spawn after this returns and are never candidates.
--
-- WHY BARS ARE EXCLUDED. Fuel is hauled last, after the memo
-- snapshot, so a bar hauled in for the NEXT queued job can be
-- present at completion and absent from seen. Rewriting that would
-- turn a fuel bar into a metal bar, which is duplication. Bar
-- producing jobs (SmeltOre, MeltMetalObject) are therefore reported
-- once and never touched, so the case is visible without acting on
-- a guess. Every reported product type so far is a non bar.
--
-- THE TRIGGER IS NARROW. A product is repaired only when its
-- material is FUEL and differs from the memo. A correct product
-- matches and is untouched, so the guard is inert on magma forges,
-- on unfueled jobs, and in forts running RM without this module.
-- No legitimate forge product is made of charcoal.
local function guard_products(job, bld, key)
    local memo = wood_memo[job.id]
    if not memo or memo.seen == nil then return end
    if memo.type == nil or memo.index == nil then return end

    -- A feedstock that is itself fuel makes the comparison
    -- meaningless. is_fuel should prevent it; checked anyway.
    if mat_is_fuel(memo.type, memo.index) then return end

    pcall(function()
        for _, ci in ipairs(bld.contained_items) do
            local it = ci.item
            if it and not memo.seen[it.id] then
                local mt, mi = it.mat_type, it.mat_index
                if (mt ~= memo.type or mi ~= memo.index)
                   and mat_is_fuel(mt, mi) then
                    local was = '?'
                    pcall(function()
                        local m = dfhack.matinfo.decode(mt, mi)
                        if m then was = m:getToken() end
                    end)

                    -- Hardcoded jobs key on a numeric job_type, so a
                    -- bare %s prints "96" instead of "MakeWeapon".
                    -- Custom reactions key on their code string and
                    -- pass through untouched.
                    local kname = key
                    if type(key) == 'number' then
                        kname = df.job_type[key] or key
                    end

                    if it:getType() == df.item_type.BAR then
                        -- Reported, never rewritten. See the note
                        -- above on why a bar cannot be trusted to be
                        -- this job's output.
                        log_once('guardbar:' .. tostring(key), 'WARNING', string.format(
                            'PRODUCT GUARD: %s left a BAR of %s'
                            .. ' untouched. Bars are never rewritten;'
                            .. ' if this is a real swapped product,'
                            .. ' it needs its own measurement.',
                            tostring(kname), was), 'GUARD')
                    else
                        it.mat_type  = memo.type
                        it.mat_index = memo.index
                        log('DETAIL', string.format(
                            'PRODUCT GUARD: %s came out of %s,'
                            .. ' repaired to the job feedstock (%s).',
                            tostring(kname), was, tostring(memo.desc)), 'GUARD')
                    end
                end
            end
        end
    end)
end


-- ==========================================
-- THE HOOK
-- ==========================================
-- ==========================================
-- GLASS GALL
-- ==========================================
-- The alkali scum that rises on a melt and is skimmed off before the
-- glass is worked. Historically collected and sold rather than
-- discarded, which is what makes it a byproduct rather than a loss.
--
-- ---- WHY IT IS NOT A LOSS STREAM ----
-- Every LOSS_STREAMS class recovers a share of what a job DESTROYED.
-- A glass job destroys nothing: 60 of sand becomes 600 of glass, so
-- lost = total_in - out_vol is never positive and the payout would
-- return on every glass job forever. Gall scales with the BATCH, one
-- pearlash bar, so a flat spawn is the physically right shape and no
-- output basis has to be invented for it.
--
-- ---- WHY job.mat_type AND NOT A PEARLASH SCAN ----
-- Clear and crystal are exactly the pearlash bearing glasses, and
-- the job carries its product material the whole time it runs:
-- measured on four jobs across three job types, reading GLASS_CLEAR
-- and GLASS_GREEN correctly and -1 on a non glass job. One integer
-- test beats scanning attachments, and it cannot be fooled by a
-- pearlash bar that merely happens to be in the workshop.
--
-- Symbolic constants on purpose. GLASS_CLEAR read as 4 in this
-- build; writing 4 would break silently the day that moves.
--
-- GREEN GETS NOTHING, and that is correct rather than an omission:
-- vanilla green glass is sand and fuel with no alkali flux, so there
-- is no scum to skim.
local function glass_gall(job)
    if not have_tuning() then return end
    if tuning.T.BYPRODUCTS
       and tuning.T.BYPRODUCTS.GALL == false then return end

    local mt = nil
    pcall(function() mt = job.mat_type end)
    if mt ~= df.builtin_mats.GLASS_CLEAR
       and mt ~= df.builtin_mats.GLASS_CRYSTAL then return end

    local bld = job_building(job)
    if not bld then return end

    -- CAKE is the FORM and GALL is the SUBSTANCE, so this reads
    -- "gall cake". The split is deliberate and is the same one as
    -- SLAG plus WASTE: a fixed material surfaces wherever DF lists
    -- materials, not only in the item string, so it has to be named
    -- distinctively rather than naturally. The first cut named this
    -- material "glass", which would have collided with real glass in
    -- every stockpile and trade list it appeared in.
    local spec = {
        item_type = df.item_type.TOOL,
        tool_id   = 'MAKING_FUEL_CRUST',
        mat       = 'INORGANIC:MAKING_FUEL_GALL',
        count     = 1,
        job       = job,
    }
    if spawn(spec, bld) then
        log('YIELD', string.format('glass gall skimmed from a %s job.',
            job_label(job)), 'SPAWN')
    end
end

local function on_completed(job)
    -- Gated on RM being live because the materials and itemdefs these
    -- byproducts name only exist while injected. Spawning against a
    -- washed material produces a default rock.
    if not _G.refinish_active then return end

    -- ---- BEFORE THE HIJACK LOOKUP, DELIBERATELY ----
    -- Glass items come off many job types: MakeRawGlass, MakeTool,
    -- ConstructChest and ConstructBlocks were all observed, and
    -- crafts and furniture add more. on_completed returns early when
    -- a job type is absent from HIJACK, so keying gall on job type
    -- would mean one entry per type and a silent miss for every type
    -- forgotten. Asked here, it covers all of them and needs no
    -- table entry at all.
    pcall(glass_gall, job)

    local ok, err = pcall(function()
        -- Built in jobs key on job_type. Raws reactions key on the
        -- reaction code, and their job_type is always CustomReaction.
        local key = job.job_type
        if key == df.job_type.CustomReaction then
            key = tostring(job.reaction_name)
        end

        local specs = HIJACK[key]
        if not specs then
            -- A job configured for waste but absent from HIJACK produces
            -- nothing and says nothing, because the warning that would
            -- explain it lives past this return. ConstructBlocks sat in
            -- that gap.
            if WASTE[key] then
                log_once('nohijack:' .. tostring(key), 'WARNING', string.format(
                    '%s is in WASTE but not in SAWDUST_JOBS, so it has no'
                    .. ' memo and produces nothing.',
                    tostring(df.job_type[key])), 'CONFIG')
            end
            return
        end

        local bld = job_building(job)
        if not bld then
            -- Distinct from a job that produced nothing: this one was
            -- never placed. A quern or millstone that does not resolve
            -- as a holder stops everything below silently.
            log('DETAIL', string.format('%s completed but its holder did not'
                .. ' resolve; nothing can be paid into it.',
                tostring(key)), 'HOOK')
            return
        end
        log('DETAIL', string.format('%s completed, holder resolved, mode %s.',
            tostring(key), tostring(MODES[key] or MODE_BYPRODUCT)), 'HOOK')

        -- BEFORE any spawn. Were this run after adaptive_output or
        -- waste_output, RM's own byproducts would be new items in
        -- the building and would become guard candidates.
        guard_products(job, bld, key)

        local mode = MODES[key] or MODE_BYPRODUCT

        if mode ~= MODE_OFF and mode ~= MODE_BYPRODUCT then
            adaptive_output(job, bld, key, mode)
        end

        -- Independent of mode. A carpentry job keeps its vanilla
        -- furniture and gains sawdust; it is not an either/or with
        -- output replacement.
        waste_output(job, bld, key)

        if mode == MODE_BYPRODUCT then
            local made = 0
            local n = 0
            for _, spec in ipairs(specs) do
                n = n + 1
                -- The predicate needs the job; the table is static and
                -- shared, so it is handed over per call rather than
                -- stored.
                spec.job = job
                if spawn(spec, bld) then made = made + spec.count end
                spec.job = nil
            end
            if made > 0 then
                log('YIELD', string.format('%s -> %d byproduct(s).',
                    tostring(key), made), 'BYPRODUCT')
            else
                -- ZERO IS A RESULT TOO. Silence here could mean the
                -- hook never fired, the spec list was empty, or every
                -- spec declined, and those need different fixes.
                log('DETAIL', string.format('%s -> nothing, from %d spec(s).'
                    .. ' The lines above say which declined and why.',
                    tostring(key), n), 'BYPRODUCT')
            end
        end

        -- Done with it either way. A cancelled job never reaches here
        -- and leaks one small entry, so the table is also emptied on
        -- stop rather than trusted to drain itself.
        wood_memo[job.id] = nil
        nofeed_polls[job.id] = nil
    end)

    if not ok then log('ERROR', 'HOOK ERROR: ' .. tostring(err), 'HOOK') end
end


-- ==========================================
-- LIFECYCLE
-- ==========================================
-- Frequency 0 means every tick, which is correct here: the handler
-- does nothing at all unless a job in HIJACK just finished, and a
-- missed completion cannot be recovered later.
-- ==========================================
function start()
    repeatUtil.scheduleEvery(POLL_KEY, 100, 'frames', memo_poll)
    eventful.onJobCompleted[EVENT_KEY] = on_completed
    eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)
    local n = 0
    for _ in pairs(HIJACK) do n = n + 1 end
    log('DETAIL', 'active. watching ' .. n .. ' job type(s).', 'START')
end

function stop()
    repeatUtil.cancel(POLL_KEY)
    eventful.onJobCompleted[EVENT_KEY] = nil
    wood_memo = {}
    log('DETAIL', 'terminated.', 'STOP')
end

return _ENV