-- making-fuel-drain-key.lua
-- =====================================================================
-- PER BUILDING DRAIN: RETORTS AND STILLS
-- =====================================================================
-- RETORT_DRAIN pours a building's banked liquid into vessels without a
-- run. Banks are per building, so the reaction has to be per building
-- too, and this file is what makes one reaction behave like N.
--
-- TWO KINDS OF BUILDING DRAIN, in exactly the same way: the retort,
-- whose burns bank tar, vinegar, ammonia and the oils, and the still,
-- whose distillations bank the fractions (see drain_kind). The still's
-- clone is named "drain still" and nothing else about it differs:
-- everything below is keyed on the building id, and the ghost's DRAIN
-- profile pours whichever bank at THAT building is fullest.
--
-- THREE GHOSTS PER RETORT, all transient, all rebuilt on demand:
--
--   material   MAKING_FUEL_DRAIN_KEY_B<id>, carrying class DRAIN_B<id>
--   reaction   MAKING_FUEL_RXN_RETORT_DRAIN_B<id>, a clone of the
--              invisible base with its key reagent rewritten to ask
--              for DRAIN_B<id>
--   key item   a DRAIN_KEY tool made of that material, minted inside
--              the retort when its banks hold a whole package
--
-- WHY THIS SHAPE. Two properties were wanted and only this gets both.
--
--   No theft.  Retort 8's job cannot consume retort 7's key, because
--              retort 8's reaction asks for a class only retort 7's
--              material carries. Binding is by MATERIAL, not position.
--   Red when   Retort 8's menu entry is coloured from its own key
--   empty.     alone, so an empty retort reads red rather than reading
--              available and then cancelling on arrival.
--
-- `nearby: true` was tried for this and MEASURED TO FAIL. The log
-- showed one key, minted once, genuinely inside retort 5, with no
-- floor fallback line, and the adjacent retort still read the drain as
-- available. Position is not tight enough. Do not put it back.
--
-- VISIBILITY IS THE BUILDING FIELD, AND ONLY THAT.
--
-- A reaction's building is four parallel vectors: type, subtype,
-- custom, hotkey. All four empty and it appears in no menu anywhere.
-- All four naming the retort and it appears in every retort's menu.
-- Only one furnace sheet is open at a time, so the open retort's clone
-- gets the building and every other clone gets nothing, and the player
-- sees exactly one entry, the local one.
--
-- FORTRESS_MODE_ENABLED is set true once at mint and never touched
-- again. It bypasses permissions entirely; it is not a visibility
-- lever, and using it as one is a mistake this file has already made
-- and does not repeat.
--
-- THE CLONES MUST BE ADOPTED BY THE GHOST ENGINE.
--
-- JIT_CONFIG is keyed on the reaction key the module DECLARED, so a
-- clone cut at runtime is invisible to the adaptive engine no matter
-- how well formed it is. Its jobs fall through the swap, keep the
-- authored product counts, and DF mints liquid that nothing paid for.
-- Measured, not theorised: two drain runs filled two jugs each, the
-- bank never moved, and the only trace was
-- `REAPED unpaid INORGANIC:MAKING_FUEL_OIL_BONE`.
--
-- So adopt() tells the engine each clone behaves as the base, and it
-- is RE-ASSERTED every poll rather than once at mint, because the
-- ghost rebuilds JIT_CONFIG in its own start().
--
-- THE KEY IS CONSUMED, not preserved. That is what lets the drain
-- settle. A reaction with nothing consumed leaves an empty ledger and
-- the ghost engine can never recognise the cycle as having fired,
-- which would pay liquid out and never debit the bank. The key enters
-- the ordinary ledger, vanishes on completion, and settle sees it go.
--
-- LIFECYCLE, and why there is no cleanup code here.
--
-- The module engine sweeps by PREFIX, not by manifest
-- (refinish-module-engine.lua:1203 for reactions, :1239 for
-- materials). Everything minted here carries MAKING_FUEL_RXN_ or
-- MAKING_FUEL_, so the same loop that clears the declared materials
-- clears these. A stop() that popped them would be a double free.
-- Contrast making-fuel-tinder-mat.lua, whose twins hang off vanilla
-- plants where no sweep reaches, which is why THAT file needs its own
-- pop and this one must not have one.
--
-- WHY KEYS ARE PURGED AT SESSION START RATHER THAN PRESERVED.
--
-- start() is called from inside the module listener, which RM
-- broadcasts at Step 2 BEFORE injecting anything, and startup runs
-- synchronously through Step 8. So the first poll lands after
-- ledger.write(), which means a per-retort material is minted after
-- the snapshot every session without exception. The ledger can
-- therefore never remap a key item, and a key that survived a data
-- cycle would carry an index that no longer means what it meant.
--
-- Rather than defend against that, the first poll of each session
-- scraps every drain key in the world by TOOL SUBTYPE, which matches
-- regardless of what the material index has become. The invariant then
-- rebuilds from nothing. A key is worth 1 and mints instantly, so this
-- costs nothing and removes an entire class of stale state.
--
-- THE INVARIANT, which is all the slow poll does:
--
--   Exactly one key for each retort whose banks hold at least one
--   whole package of a liquid, WHEREVER IN THE FORT IT IS. None for
--   any other retort.
--
-- It used to say "inside each retort ... none anywhere else", and that
-- clause was the bug. MEASURED: with a tool stockpile up, a key minted
-- inside retort 8 was hauled out, the stray sweep scrapped it as being
-- outside any retort, and the next poll minted another, every three
-- seconds or so, 408 lines in one session, so the drain could never be
-- ordered. No flag can stop the haul without also making the key
-- unselectable (the menu key work in making-fuel-access.lua tried them
-- all). And the location never mattered: binding is by MATERIAL (see
-- WHY THIS SHAPE), so retort 8's key serves only retort 8 wherever it
-- sits. A stored key simply stays stored, and the drain job fetches it
-- like any other reagent.
--
-- Nothing here watches jobs. The key is consumed by a drain run, so
-- afterwards the count at that furnace is zero and the next poll
-- either mints a replacement because there is still something to drain
-- or does not because there is not.
--
-- Nothing is silent: every state prints once on entry and once on
-- exit, the same contract the rot watcher keeps.
-- =====================================================================

--@ module = true

local repeatUtil = require('repeat-util')

-- ---------------------------------------------------------------------
-- CONSTANTS
-- ---------------------------------------------------------------------
-- Two cadences, because the two jobs want different ones. The flip has
-- to be ready before the player opens the task list, which is a few
-- frames after the sheet opens. The invariant is not urgent.
local FAST_KEY    = 'making-fuel-drain-key-view'
local FAST_FRAMES = 5
local SLOW_KEY    = 'making-fuel-drain-key'
local SLOW_FRAMES = 100

local MOD_NAME    = 'Making Fuel'
local MAT_PREFIX  = 'MAKING_FUEL_'          -- materials
local RXN_PREFIX  = 'MAKING_FUEL_RXN_'      -- reactions, RXN_ infix

-- The invisible base every clone is cut from. Declared building NONE
-- in making_fuel_reactions_retort.json, so it is orderable nowhere and
-- exists only to be copied.
local BASE_RXN    = RXN_PREFIX .. 'RETORT_DRAIN'

-- The base material definition, read out of the module registry rather
-- than restated here. Its colour, thermals, strength and value belong
-- to the JSON and must not be duplicated in Lua, where they would
-- drift the first time either is edited alone.
local BASE_MAT    = 'DRAIN_KEY_MAT'

-- The class the base reagent asks for. Each clone's copy of that
-- reagent is rewritten to class_of(bid) instead.
local BASE_CLASS  = 'DRAIN'

local MAT_STEM    = 'DRAIN_KEY_'            -- + tag, after MAT_PREFIX
local RXN_STEM    = 'RETORT_DRAIN_'         -- + tag, after RXN_PREFIX
local CLASS_STEM  = 'DRAIN_'                -- + tag

local KEY_TOOL    = 'MAKING_FUEL_DRAIN_KEY' -- itemdef id, one for all
local RETORT_CODE = 'MAKING_FUEL_RETORT'    -- custom furnace building def

-- What each kind's clone is called in its task list. The base reads
-- "drain retort"; a still's clone says what it drains.
local DRAIN_NAME = { retort = 'drain retort', still = 'drain still' }

-- Every clone's code starts with this. The base's does not, having no
-- trailing underscore. A ghost's per-job clone of a drain clone does,
-- and show_only passes over those by their _GHOST_ infix.
local CLONE_PREFIX = RXN_PREFIX .. RXN_STEM
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
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'DRAIN_KEY'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

local tuning = reqscript('making-fuel-tuning')
local T      = tuning.T

-- ---------------------------------------------------------------------
-- SESSION STATE
-- ---------------------------------------------------------------------
-- Every one of these is dropped in start(), and start() runs again on
-- every data cycle, so nothing may survive one.
--
-- NO REACTION IS HELD AS AN OBJECT. This file used to keep each clone's
-- df.reaction pointer, and a data cycle deletes those objects: the
-- engine's sweep runs before this file's stop(), so for a moment the
-- polls could still reach a freed reaction through the cache. Clones
-- are now found by CODE in the live array every time (ensure_reaction,
-- show_only), so a swept clone is never touched. The same fix
-- making-fuel-tank-fuel.lua took for the same hazard.
local said        = {}    -- log-once keys
local mat_slot    = {}    -- building id -> inorganic index
local shown       = nil   -- building id whose clone currently has a building
local purged      = false -- has this session's stale key purge run
local reswept     = false -- has the ghost re-checked orphans this session
local had_key     = {}    -- building id -> did it hold a key at the END
                          --   of the last poll. See THE STUTTER below.
local minted_id   = nil   -- id of a key made THIS poll, see mint()

-- ---------------------------------------------------------------------
-- LOGGING
-- ---------------------------------------------------------------------
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
-- SUBJECT is the correlation slot: MINT for the per building material
-- and reaction, KEY for the keys, RESOLVE and SITE for what the watcher
-- waits on, ADOPT for the ghost engine, START and STOP.
--
-- once() and clear() say a state once and its recovery once. Each call
-- states its TYPE and SUBJECT like any log line: the state is usually a
-- fault, and its recovery usually DETAIL.
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

-- Says a thing once, and says the recovery once when it stops being
-- true. A state that appears and disappears in silence is the failure
-- mode this contract exists to prevent.
local function once(key, typ, msg, subject)
    if not said[key] then said[key] = true log(typ, msg, subject) end
end
local function clear(key, typ, msg, subject)
    if said[key] then said[key] = nil if msg then log(typ, msg, subject) end end
end

-- ---------------------------------------------------------------------
-- NAMES
-- ---------------------------------------------------------------------
-- Keyed on BUILDING ID, not on a count. Ids never shift, so a key
-- minted for retort 7 can never drift onto another furnace when some
-- other retort is demolished. The 'B' keeps the tag from ever reading
-- as a bare number inside a material id.
local function tag_of(bid)   return 'B' .. tostring(bid) end
local function mat_key(bid)  return MAT_STEM .. tag_of(bid) end
local function mat_id(bid)   return MAT_PREFIX .. mat_key(bid) end
local function rxn_code(bid) return RXN_PREFIX .. RXN_STEM .. tag_of(bid) end
local function class_of(bid) return CLASS_STEM .. tag_of(bid) end

-- ---------------------------------------------------------------------
-- LOOKUPS
-- ---------------------------------------------------------------------
-- Resolved fresh, and a MISS IS NEVER CACHED. Materials, itemdefs and
-- reactions are all injected AFTER this script starts, so a cached nil
-- would poison the entry for the whole session and the watcher would
-- silently never work again.
local function find_material(full_id)
    local idx = nil
    pcall(function()
        local mi = dfhack.matinfo.find('INORGANIC:' .. full_id)
        if mi then idx = mi.index end
    end)
    return idx
end

local function find_reaction(code)
    local hit = nil
    pcall(function()
        for _, r in ipairs(df.global.world.raws.reactions.reactions) do
            if r.code == code then hit = r return end
        end
    end)
    return hit
end

-- Was a full itemdefs walk per poll, tostring'ing every definition
-- it passed. refinish-module-react already holds this answer in a
-- cache the tool injector invalidates, so the walk was rebuilding
-- something RM had already built.
local resolve = reqscript('refinish-resolve')

local function find_tool_subtype()
    return resolve.tool_subtype(KEY_TOOL)
end

-- ---------------------------------------------------------------------
-- THE BUILDINGS THAT DRAIN
-- ---------------------------------------------------------------------
-- 'retort', 'still', or nil. A retort is a CUSTOM furnace, matched on
-- its building_def code the same way the bank readout matches it. The
-- still is a vanilla workshop, matched on its workshop enum; it drains
-- the fractions its distillations bank.
local function drain_kind(b)
    local kind = nil
    pcall(function()
        local t = b:getType()
        if t == df.building_type.Furnace then
            if b.type ~= df.furnace_type.Custom then return end
            local def = df.building_def.find(b.custom_type)
            if def and tostring(def.code) == RETORT_CODE then kind = 'retort' end
        elseif t == df.building_type.Workshop then
            if b.type == df.workshop_type.Still then kind = 'still' end
        end
    end)
    return kind
end

-- "retort 5", "still 22", for the log.
local function label(b)
    return (drain_kind(b) or 'building') .. ' ' .. tostring(b.id)
end

-- Every finished retort and still. Unfinished ones are skipped: a key
-- inside a construction site is a key nobody can use.
local function drainers()
    local out = {}
    pcall(function()
        for _, b in ipairs(df.global.world.buildings.all) do
            pcall(function()
                if not drain_kind(b) then return end
                if b:getBuildStage() ~= b:getMaxBuildStage() then return end
                table.insert(out, b)
            end)
        end
    end)
    return out
end

-- True when this furnace holds a whole package of any pourable liquid.
--
-- LIQUID_STANDARD is the whitelist, the same one the ghost drains by,
-- so a key can never appear for something the drain would then refuse
-- to pour. Banks also hold charcoal, ash and pitch, and a boulder does
-- not go in a jug.
local function bank_full(bid)
    local bank = _G.refinish_fuel_bank
    if type(bank) ~= 'table' then return false, nil end
    local std = (T and T.LIQUID_STANDARD) or {}
    local best, bestcur = nil, nil
    for cur, pack in pairs(std) do
        if type(pack) == 'number' and pack > 0 then
            local v = bank['BANK_' .. cur .. '@' .. tostring(bid)]
            if type(v) == 'number' and v + (T.EPSILON or 1e-6) >= pack then
                if not best or v > best then best, bestcur = v, cur end
            end
        end
    end
    return best ~= nil, bestcur
end

-- ---------------------------------------------------------------------
-- MINTING THE GHOST MATERIAL
-- ---------------------------------------------------------------------
-- A deep copy of the JSON definition with two fields changed, pushed
-- through the engine's own injector. Going through inject() rather
-- than building an inorganic_raw here is deliberate: that path owns
-- the clone donor, the class preset, the heat and strength writes and
-- the df.new('string') class vector, and none of it is worth
-- reimplementing badly.
local function deep_copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = deep_copy(val) end
    return out
end

local function template_mat_def()
    local reg = _G.refinish_module_registry
    local entry = reg and reg[MAT_PREFIX]
    if not entry then return nil end
    for _, m in ipairs(entry.materials or {}) do
        if m.key == BASE_MAT then return m end
    end
    return nil
end

local function ensure_material(bid)
    if mat_slot[bid] then return mat_slot[bid] end

    local full = mat_id(bid)
    local idx  = find_material(full)
    if idx then mat_slot[bid] = idx return idx end

    local tmpl = template_mat_def()
    if not tmpl then
        -- DETAIL: every startup waits here until the module injects.
        once('tmplmat', 'DETAIL', BASE_MAT .. ' is not in the module registry yet;'
             .. ' deferring. Nothing can be minted without it.', 'RESOLVE')
        return nil
    end
    clear('tmplmat', 'DETAIL', BASE_MAT .. ' template resolved.', 'RESOLVE')

    local def = deep_copy(tmpl)
    def.key = mat_key(bid)
    -- DRAIN_KEY is the family, for anything that ever wants to name
    -- keys in general. class_of(bid) is the BINDING, and it is the
    -- only class this retort's reaction will accept.
    def.reaction_classes = { 'DRAIN_KEY', class_of(bid) }
    -- The display name is deliberately NOT numbered. Every key reads
    -- "drain key"; the uniqueness is internal, and a player never has
    -- to tell two apart because each lives inside its own retort and
    -- is consumed there.

    -- A LIST OF ONE, ALWAYS, never merged into the module payload.
    -- inject() sorts the batch it is handed and appends past the end
    -- of the array, so a separate call leaves the declared materials
    -- in the positions they have always had. Merging these in would
    -- let the sort interleave them and shift the declared band by
    -- however many retorts happen to be standing.
    local ok, err = pcall(function()
        dfhack.script_environment('refinish-module-inject')
            .inject({ def }, MAT_PREFIX, MOD_NAME)
    end)
    if not ok then
        -- ERROR, once per building: the slow poll retries about once
        -- a second and would repeat it on every pass.
        once('mintmat:' .. tostring(bid), 'ERROR',
            ('material mint FAILED for building %d: %s')
            :format(bid, tostring(err)), 'MINT')
        return nil
    end

    idx = find_material(full)
    if not idx then
        once('noresolve:' .. tostring(full), 'ERROR',
            ('material %s was injected but does not resolve.'
             .. ' Report this line.'):format(full), 'MINT')
        return nil
    end
    mat_slot[bid] = idx
    return idx
end

-- ---------------------------------------------------------------------
-- MINTING THE GHOST REACTION
-- ---------------------------------------------------------------------
-- Clones the invisible base, on the same pattern build_ghost_jit uses
-- in making-fuel-ghost.lua. Cloning rather than re-running
-- inject_reactions is a real saving: that path rescans and re-scores
-- every loaded reaction to pick a structural donor, which is wasted
-- work when a finished donor is already sitting in the array.
-- kind is drain_kind's answer, which names the clone.
local function ensure_reaction(bid, kind)
    -- Found by code in the live array on every call, never cached: see
    -- NO REACTION IS HELD AS AN OBJECT.
    local code = rxn_code(bid)
    local hit  = find_reaction(code)
    if hit then return hit end

    local base = find_reaction(BASE_RXN)
    if not base then
        once('baserxn', 'DETAIL', BASE_RXN .. ' is not injected yet; deferring.', 'RESOLVE')
        return nil
    end
    clear('baserxn', 'DETAIL', BASE_RXN .. ' template resolved.', 'RESOLVE')

    local made = nil
    local ok, err = pcall(function()
        local arr = df.global.world.raws.reactions.reactions
        local rxn = df.reaction:new()
        rxn:assign(base)
        rxn.code = code
        -- "drain retort" or "drain still", by the building it serves.
        rxn.name = DRAIN_NAME[kind] or rxn.name

        -- DEEP COPY REAGENTS AND PRODUCTS. assign() copies these
        -- vectors of POINTERS, so without this the clone and the base
        -- share every reagent object, and rewriting the key reagent's
        -- class below would reach into the base and into every other
        -- clone.
        rxn.reagents:resize(0)
        for _, old in ipairs(base.reagents) do
            local n = old._type:new()
            n:assign(old)
            rxn.reagents:insert('#', n)
        end
        rxn.products:resize(0)
        for _, old in ipairs(base.products) do
            local n = old._type:new()
            n:assign(old)
            rxn.products:insert('#', n)
        end

        -- THE BINDING. Found by the class it asks for rather than by
        -- slot index, so reordering the reagents in the JSON cannot
        -- silently rewrite the wrong one. Exactly one match is
        -- required: zero means the base changed under us, more than
        -- one means the shape is not what this code was written for,
        -- and both are worth failing loudly over.
        local wrote = 0
        for _, r in ipairs(rxn.reagents) do
            if tostring(r.reaction_class) == BASE_CLASS then
                r.reaction_class = class_of(bid)
                wrote = wrote + 1
            end
        end
        if wrote ~= 1 then
            error(('expected exactly one reagent asking for class %s,'
                   .. ' found %d'):format(BASE_CLASS, wrote))
        end

        -- Starts invisible. show_only() gives exactly one clone a
        -- building, and only while its retort is the open sheet.
        rxn.building.type:resize(0)
        rxn.building.subtype:resize(0)
        rxn.building.custom:resize(0)
        rxn.building.hotkey:resize(0)

        rxn.index = #arr
        arr:insert('#', rxn)

        -- Set once, never flipped. This is permissions, not
        -- visibility: it means the player may order the reaction at
        -- all. The building field above decides where.
        rxn.flags.FORTRESS_MODE_ENABLED = true
        made = rxn
    end)

    if not ok or not made then
        once('mintrxn:' .. tostring(bid), 'ERROR',
            ('reaction mint FAILED for building %d: %s')
            :format(bid, tostring(err)), 'MINT')
        return nil
    end
    -- A drain job saved against this building's clone points its
    -- filters at the clone's old position, and a clone minted this
    -- session sits somewhere new. The engine's repoint moves every job
    -- back onto its reaction (refinish-module-engine.lua, JOB FILTERS
    -- FOLLOW THEIR REACTION). A drain job rides a ghost of this clone,
    -- and the ghost's _GHOST_ code names this clone as its base, so it
    -- lands here.
    if _G.refinish_repoint_jobs then pcall(_G.refinish_repoint_jobs) end
    return made
end

-- ---------------------------------------------------------------------
-- ADOPTION BY THE GHOST ENGINE
-- ---------------------------------------------------------------------
-- A clone is a well formed reaction that the adaptive engine has never
-- heard of, because JIT_CONFIG is keyed on declared reaction keys. Its
-- jobs would complete on the authored product counts, fill vessels,
-- and debit no bank. register_alias points the clone's code at the
-- SAME config table the base uses, so the two can never drift.
--
-- Called from ensure_slot, so it re-asserts every poll. The ghost
-- rebuilds JIT_CONFIG inside its own start(), and an alias registered
-- only at mint time would vanish there without a word.
local function adopt(bid)
    local ok = false
    pcall(function()
        ok = dfhack.script_environment('making-fuel-ghost')
                .register_alias(rxn_code(bid), BASE_RXN) == true
    end)

    if not ok then
        -- ERROR: an unadopted drain fills vessels and debits nothing. The
        -- ghost engine starts before this file, so this is a real fault.
        once('adopt', 'ERROR', 'the ghost engine has not adopted the drain clones.'
             .. ' A drain would fill vessels and debit nothing, so this'
             .. ' is not cosmetic.', 'ADOPT')
        return false
    end
    clear('adopt', 'DETAIL', 'drain clones adopted by the ghost engine.', 'ADOPT')

    -- The ghost sweeps orphaned jobs inside its start(), which runs
    -- BEFORE any alias can exist, so a job left mid drain across a
    -- data cycle is passed over and left pointing at a ghost code cut
    -- from a clone the engine did not yet recognise. Now that the
    -- aliases are back, ask for that sweep again. Once per session:
    -- the latch is dropped in start(), which runs on every cycle.
    if not reswept then
        reswept = true
        pcall(function()
            dfhack.script_environment('making-fuel-ghost').resweep_orphans()
        end)
    end
    return true
end

-- Both ghosts for one retort, and the engine told what they are.
-- Returns the material index, or nil if any part could not be made,
-- because a key with no reaction to unlock is as useless as a reaction
-- the engine will not pay out on.
local function ensure_slot(b)
    local idx = ensure_material(b.id)
    if not idx then return nil end
    if not ensure_reaction(b.id, drain_kind(b)) then return nil end
    if not adopt(b.id) then return nil end
    return idx
end

-- ---------------------------------------------------------------------
-- VISIBILITY
-- ---------------------------------------------------------------------
-- The building values are read off the LIVE BUILDING rather than from
-- a table, so they cannot drift from what it actually is: its building
-- type, its furnace or workshop sub, and its building_def index.
-- Hotkey 0 is "no hotkey", which is what every module reaction gets.
--
-- Every drain clone is found by CODE in ONE walk of the live array, so
-- a clone the engine has swept is never touched (NO REACTION IS HELD
-- AS AN OBJECT). A ghost's per-job clone of a drain clone shares the
-- prefix and is passed over: it is the ghost's, and never in a menu.
local function show_only(bid, b)
    local want = bid and rxn_code(bid) or nil
    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        local c = nil
        pcall(function() c = rxn.code end)
        if c and c:sub(1, #CLONE_PREFIX) == CLONE_PREFIX
           and not c:find('_GHOST_', 1, true) then
            pcall(function()
                rxn.building.type:resize(0)
                rxn.building.subtype:resize(0)
                rxn.building.custom:resize(0)
                rxn.building.hotkey:resize(0)
                if b and c == want then
                    rxn.building.type:insert('#', b:getType())
                    rxn.building.subtype:insert('#', b.type)
                    rxn.building.custom:insert('#', b.custom_type)
                    rxn.building.hotkey:insert('#', 0)
                end
            end)
        end
    end
end

-- ---------------------------------------------------------------------
-- THE KEY
-- ---------------------------------------------------------------------
-- Matching on SUBTYPE ALONE is what the purge and the stray sweep
-- want: it finds a key whose material index has gone stale across a
-- data cycle, which a material test would miss and leave lying there
-- forever.
local function is_any_key(it, tool_sub)
    local hit = false
    pcall(function()
        hit = it:getType() == df.item_type.TOOL
          and it:getSubtype() == tool_sub
    end)
    return hit
end

-- Every key in the fort, grouped by material index: [mat_index] = list.
-- One walk serves every retort, and a key counts wherever it is, in the
-- retort, in a stockpile, or in a hauler's hands. Keys held by a job
-- sort first in each list, so trimming extras never takes the one a
-- drain run is using. The tool vector, with the full item list as the
-- fallback, the same pair the ghost walks.
local function index_keys(tool_sub)
    local by_mat = {}
    local vec = nil
    pcall(function() vec = df.global.world.items.other.TOOL end)
    if not vec then pcall(function() vec = df.global.world.items.all end) end
    if not vec then return by_mat end
    for _, it in ipairs(vec) do
        if is_any_key(it, tool_sub) then
            local mi = nil
            pcall(function() if it.mat_type == 0 then mi = it.mat_index end end)
            if mi then
                by_mat[mi] = by_mat[mi] or {}
                table.insert(by_mat[mi], it)
            end
        end
    end
    for _, list in pairs(by_mat) do
        table.sort(list, function(a, b)
            local ja, jb = false, false
            pcall(function() ja = a.flags.in_job; jb = b.flags.in_job end)
            if ja ~= jb then return ja end
            return a.id < b.id
        end)
    end
    return by_mat
end

-- Housekeeping, so its reason is DETAIL: a spare key, a key with
-- nothing left to drain, or a stray.
local function scrap(it, why)
    pcall(function() dfhack.items.remove(it) end)
    if why then log('DETAIL', why, 'KEY') end
end

-- minted_id is set here so the stray sweep can see a key made THIS
-- poll. Without it the sweep, whose `seen` set was built before the
-- mint, removes the key it just made, every poll, forever, and the
-- reaction never goes white.
local function mint(b, tool_sub, mat_index)
    local maker = nil
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(u) then maker = u break end
    end
    if not maker then
        once('citizen', 'WARNING', 'no citizen to credit the mint; deferring.', 'KEY')
        return false
    end
    clear('citizen', 'DETAIL', 'citizen available.', 'KEY')

    local ok, made = pcall(dfhack.items.createItem,
        maker, df.item_type.TOOL, tool_sub, 0, mat_index)
    local it = ok and made or nil
    -- createItem may hand back the item or a LIST containing it.
    -- Unwrap on the list actually having a first element, which is
    -- true in both shapes; testing type == 'table' does not fire in
    -- play, because a real df item is userdata rather than a table.
    if type(it) == 'table' and it[1] ~= nil then it = it[1] end
    if not it then
        log('ERROR', 'key mint FAILED (' .. tostring(made) .. ').', 'KEY')
        return false
    end

    -- Visible, unforbidden, never an artifact. This key is a real
    -- reagent that the job consumes, so nothing here may hide it or
    -- claim it.
    pcall(function()
        it.flags.forbid   = false
        it.flags.artifact = false
        it.flags.dump     = false
        it.flags.in_job   = false
    end)

    minted_id = nil
    pcall(function() minted_id = it.id end)

    -- INSIDE the building, so it starts where the job needs it. A tool
    -- stockpile may still claim it, and that is fine: it counts
    -- wherever it is (see THE INVARIANT). The floor fallback keeps it
    -- usable and says so out loud.
    if not dfhack.items.moveToBuilding(it, b) then
        local p = xyz2pos(b.centerx, b.centery, b.z)
        if dfhack.items.moveToGround(it, p) then
            log('WARNING', ('key minted at %s but could not go inside it;'
                 .. ' left on the floor.'):format(label(b)), 'KEY')
        else
            log('WARNING', ('key minted at %s and could be placed nowhere.'
                 .. ' Report this line.'):format(label(b)), 'KEY')
            return false
        end
    end
    return true
end

-- ---------------------------------------------------------------------
-- THE FAST POLL: WHICH RETORT IS OPEN
-- ---------------------------------------------------------------------
-- The task list is rebuilt from the reactions array per view, which is
-- why the menu shaper has to re-shape at one frame. Flipping on the
-- SHEET opening rather than on the list building leaves several frames
-- of slack before the list is read.
local function view()
    if not dfhack.isMapLoaded() then return end

    local b = nil
    pcall(function()
        local sel = dfhack.gui.getSelectedBuilding(true)
        if sel and drain_kind(sel) then b = sel end
    end)

    if not b then
        -- No retort or still open, so everything goes dark. A clone must
        -- never be left showing in a building the player has walked away
        -- from, or the next one opened would carry a foreign drain.
        if shown ~= nil then
            show_only(nil, nil)
            shown = nil
        end
        return
    end

    if shown == b.id then return end

    -- Covers a retort built since the last slow poll: the click is the
    -- first time this file hears about it, and it gets its ghosts
    -- right then.
    ensure_slot(b)
    show_only(b.id, b)
    shown = b.id
end

-- ---------------------------------------------------------------------
-- THE SLOW POLL: HOLD THE INVARIANT
-- ---------------------------------------------------------------------
local function poll()
    if not dfhack.isMapLoaded() then return end

    local tool_sub = find_tool_subtype()
    if not tool_sub then
        once('tool', 'DETAIL', KEY_TOOL .. ' itemdef not injected yet; deferring.', 'RESOLVE')
        return
    end
    clear('tool', 'DETAIL', KEY_TOOL .. ' itemdef resolved.', 'RESOLVE')

    -- ---- SESSION PURGE ----
    -- Runs once, on the first poll that can resolve the itemdef. Every
    -- key from before the last data cycle carries a material index the
    -- ledger never recorded and can never fix, so none of them are
    -- trusted. A key held by a job in flight is left alone: that job
    -- consumes it and completes normally, and if it is cancelled the
    -- stray sweep below collects the key on a later poll.
    if not purged then
        purged = true
        local n = 0
        pcall(function()
            for _, it in ipairs(df.global.world.items.all) do
                if is_any_key(it, tool_sub) and not it.flags.in_job then
                    pcall(function() dfhack.items.remove(it) end)
                    n = n + 1
                end
            end
        end)
        if n > 0 then
            log('DETAIL', ('session start: %d key(s) from a previous data cycle'
                 .. ' scrapped. They mint again where they are owed.')
                :format(n), 'KEY')
        end
    end

    local seen = {}
    local rs = drainers()
    local keys = index_keys(tool_sub)
    local done = {}   -- { bid, mat_index } per building, for the re-count
    if #rs == 0 then
        once('retort', 'DETAIL', 'no completed retort or still yet; ghosts mint'
             .. ' when one exists.', 'SITE')
    else
        clear('retort', 'DETAIL', ('%d retort(s) and still(s) watched.'):format(#rs), 'SITE')
    end

    for _, b in ipairs(rs) do
        -- Ghosts for every standing retort, clicked or not. A key
        -- cannot be minted without its material, so this cannot wait
        -- for a click.
        local mat_index = ensure_slot(b)
        if mat_index then
            local held = keys[mat_index] or {}
            for _, k in ipairs(held) do seen[k.id] = true end

            local overflow, cur = bank_full(b.id)

            -- ---- THE STUTTER ----
            -- The key is consumed when the drain job COMPLETES, not
            -- when it starts. It sits attached and preserved for the
            -- whole run, so this poll sees it and does nothing, which
            -- is correct. The bank is debited a moment later still,
            -- when the job leaves the list and the ghost settles it.
            --
            -- That leaves a gap between the two, and the log caught a
            -- mint landing inside it:
            --
            --   DRAIN KEY: retort 5 holds a package of OIL_BONE; key minted.
            --   FUEL GHOST: RETORT_DRAIN_B5  job 13  BURNED
            --     bank oil_bone 0.575624 carried in BANK_OIL_BONE@5
            --   DRAIN KEY: retort 5 has nothing left to drain; key withdrawn.
            --
            -- Same second for the first three. The player sees the
            -- reaction finish, a key appear, and the key vanish.
            --
            -- A key that WAS here and is gone now, with the bank still
            -- reading full, is a key a job just took. That retort sits
            -- out exactly one poll and the debit lands in between.
            --
            -- had_key is written from a RE-COUNT at the end of the
            -- poll rather than inferred from #held, because a key this
            -- watcher withdrew itself must not look like one a job
            -- consumed. Inferring it delayed the next legitimate mint
            -- by a poll every time a bank ran dry and refilled, which
            -- the harness caught.
            local spent = had_key[b.id] and #held == 0 and overflow

            if overflow then
                if #held == 0 and not spent then
                    minted_id = nil
                    if mint(b, tool_sub, mat_index) then
                        if minted_id then seen[minted_id] = true end
                        log('DETAIL', ('%s holds a package of %s; key minted.')
                            :format(label(b), tostring(cur)), 'KEY')
                    end
                end
                -- Never more than one. Two keys is two drain jobs'
                -- worth of availability for one furnace's worth of
                -- liquid.
                for i = 2, #held do
                    scrap(held[i], ('%s had %d keys; extra removed.')
                        :format(label(b), #held))
                end
            else
                for _, k in ipairs(held) do
                    scrap(k, ('%s has nothing left to drain;'
                              .. ' key withdrawn.'):format(label(b)))
                end
            end

            table.insert(done, { bid = b.id, mi = mat_index })
        end
    end

    -- What is actually out there now, after everything this poll did,
    -- counted afresh from one new index rather than inferred. Deferring
    -- leaves it false, so the next poll mints rather than deferring
    -- again: exactly one poll, never two.
    local after = index_keys(tool_sub)
    for _, d in ipairs(done) do
        had_key[d.bid] = #(after[d.mi] or {}) > 0
    end

    -- ---- STRAYS ----
    -- Any key not accounted for above belongs to no retort: one left by
    -- a demolished retort, or one whose material went stale. A key a
    -- dwarf merely MOVED is accounted for above, wherever it went.
    -- Matched by SUBTYPE so a stale material is still caught. Either it
    -- would keep a drain available somewhere it should not be, or it is
    -- inert clutter, and neither is wanted.
    pcall(function()
        for _, it in ipairs(df.global.world.items.all) do
            if is_any_key(it, tool_sub) and not seen[it.id]
               and not it.flags.in_job then
                scrap(it, 'a key belonging to no retort or still was'
                          .. ' found; removed.')
            end
        end
    end)
end

-- ---------------------------------------------------------------------
-- CONTRACT
-- ---------------------------------------------------------------------
-- Every cache is dropped here. start() runs again on every data cycle,
-- after the sweep has deleted everything minted in the last one, so
-- nothing may be carried across.
function start()
    said, mat_slot, had_key = {}, {}, {}
    shown, purged, reswept, minted_id = nil, false, false, nil
    repeatUtil.scheduleEvery(FAST_KEY, FAST_FRAMES, 'frames', view)
    repeatUtil.scheduleEvery(SLOW_KEY, SLOW_FRAMES, 'frames', poll)
    log('DETAIL', 'active. One drain and one key per retort and per still, minted'
        .. ' where owed.', 'START')
end

-- Deliberately does NOT remove materials or reactions. The module
-- engine's prefix sweep owns that, and doing it here as well is a
-- double free. See the lifecycle note in the header.
function stop()
    repeatUtil.cancel(FAST_KEY)
    repeatUtil.cancel(SLOW_KEY)
    mat_slot, shown = {}, nil
    log('DETAIL', 'stopped.', 'STOP')
end

-- Started by making_fuel.lua, the same as every sibling watcher.
-- Guarded the way the coal watcher guards it, because dfhack_flags is
-- not guaranteed to exist when a script is required rather than run.
if dfhack_flags and dfhack_flags.module then return end
start()