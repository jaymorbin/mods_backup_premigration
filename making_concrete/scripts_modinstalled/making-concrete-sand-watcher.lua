--@ module = true
-- making-concrete-sand-watcher.lua
-- ==========================================
-- MAKING CONCRETE: GHOST REACTION SWAP WATCHER
-- ==========================================
-- Watches generic grind jobs and redirects them to a material
-- specific ghost reaction based on what the dwarf actually
-- picked up.
--
-- THE PROBLEM:
--   DF resolves a reaction's product material when the reaction
--   is built, not when the job runs. One reaction therefore has
--   one output material, no matter what went in. The only engine
--   level escape is get_material_product, and that requires the
--   INPUT material to declare the product, which vanilla obsidian
--   does not (its reaction_product vector is empty).
--
-- THE TECHNIQUE:
--   Same bait and switch RM uses for its grinders. The player
--   orders one generic reaction. Before the job completes, this
--   watcher reads the item actually attached, and if it matches a
--   rule, rewrites job.reaction_name to point at a ghost reaction
--   whose product is the one we want.
--
--   The ghost is a normal module reaction declared in the module
--   JSON with permissions NONE and no category, so it is injected,
--   validated and purged like everything else but never appears in
--   a workshop menu. job.reaction_name is a string lookup, so the
--   job reaches it regardless of permissions.
--
-- WHY RM'S OWN GHOSTS ARE DIFFERENT:
--   RM's grinder ghosts are cosmetic. Its base grinder product is
--   already GET_MATERIAL_SAME against the input reagent, so the
--   dust material is correct without any swap. The ghost only
--   renames the job.
--
--   Ours does real work. Volcanic sand is not the input material,
--   so GET_MATERIAL_SAME cannot reach it and the ghost carries an
--   explicit material. A missed swap gives the wrong material
--   rather than an ugly name, so the structural rules below are
--   requirements, not style.
--
-- STRUCTURAL REQUIREMENT:
--   A ghost's reagent list must be identical to its base: same
--   count, same order, same codes, same quantities. Items are
--   attached and matched against the BASE reaction, then products
--   are resolved against the GHOST. If the reagent lists differ,
--   product_to_container points into a slot list that no longer
--   lines up.
--
-- LIFECYCLE:
--   start()  registers the poll and sweeps stale ghost names
--   stop()   cancels the poll
--   Called from making_concrete.lua during module boot/shutdown.
-- ==========================================

local repeatUtil = require('repeat-util')
local utils      = require('utils')

local REPEAT_KEY = 'making_concrete_sand_watcher'
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
local LOG_SYS, LOG_SUB = 'MAKING_CONCRETE', 'SAND_WATCHER'
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
-- SUBJECT is the correlation slot: the part of the watcher a line is
-- about (POLL, JOB, SWAP, GHOST, REFUSED, ORPHANS, START, STOP).
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else.
-- This replaces a log() that let refinish-log guess TYPE from the
-- words (read_type) and printed to the console when RM was not loaded.
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

-- One-shot log keys, cleared in start(). A poll running every ten
-- frames cannot log its reasoning every pass without burying the
-- log, but it CAN log each distinct thing the first time it
-- happens. That turns a silent failure into a trace showing exactly
-- which stage it reached.
local seen = {}

local function log_once(key, typ, msg, subject)
    if seen[key] then return end
    seen[key] = true
    log(typ, msg, subject)
end

-- Frames between polls. RM's watcher runs at 10 on its FAST
-- setting. Grinding is not instant, so this has room, but it must
-- stay well under the shortest job duration or a swap can miss.
local POLL_FRAMES = 10

-- Any material whose ID starts with this is something this module
-- produced. Grinding it back down is always a mistake, so the
-- watcher cancels the job rather than letting it run. Prefix based
-- so it covers materials added later without another edit here.
local PROTECT_PREFIX = 'MAKING_CONCRETE_'


-- ==========================================
-- SWAP RULES
-- ==========================================
-- Keyed by the BASE reaction code (full prefixed ID). Each rule
-- names the reagent slot carrying the material to inspect, and an
-- ordered list of matches. First match wins; no match leaves the
-- job alone and the base reaction's own product stands.
--
-- A match may test either:
--   mat_id  an exact inorganic ID
--   flag    an inorganic_raw.flags name, which catches modded
--           stones of the same kind without naming them
--
-- Adding a rock-coloured sand set later means adding entries here
-- and declaring the matching ghosts in the JSON. Nothing in the
-- loop below needs to change.
-- ==========================================
-- Reaction codes are built by the engine as
--     prefix .. "RXN_" .. key
-- (see refinish-module-evaluate-permissions.lua). The RXN_ is easy to
-- miss and a wrong code fails completely silently: no job ever
-- matches, and the watcher looks dead. Build the codes here rather
-- than writing them out, so the table can only ever hold keys.
local MODULE_PREFIX = 'MAKING_CONCRETE_'

local function rxn_code(key)
    return MODULE_PREFIX .. 'RXN_' .. key
end

local SWAP_RULES = {
    ["GRIND_SAND"] = {
        -- Which item type carries the material we inspect. This is
        -- how RM's own watcher picks the input out of job.items
        -- (JIT_CONFIG.itype), and it is enough to tell the stone
        -- apart from the bag without needing a reagent index.
        item_type = df.item_type.BOULDER,

        -- YIELD TIERS. First match wins, so order is significant:
        -- specific materials first, the flag catch-all last.
        --
        -- Every tier fills all four bags. Only the RATIO of volcanic
        -- sand to ordinary sand changes, so nothing is wasted and no
        -- tier leaves a partial bag the mixer cannot use.
        --
        -- The ordering is pozzolanic reactivity, which tracks
        -- amorphous silica content, which in turn tracks how felsic
        -- and how glassy the rock is. That is why obsidian sits at
        -- the top: it is volcanic glass, effectively pure amorphous
        -- silica.
        --
        -- Anything not listed and not extrusive never reaches a ghost
        -- at all. It stays on the base reaction and yields four
        -- ordinary sand.
        matches = {
            -- 4 volcanic. Volcanic glass. Named explicitly so it
            -- still wins if a mod clears its igneous flag.
            { mat_id = "OBSIDIAN",
              ghost  = "GRIND_VOLCANIC_SAND" },

            -- 3 volcanic, 1 sand. Felsic extrusives: high silica,
            -- commonly glassy.
            { mat_id = "RHYOLITE",
              ghost  = "GRIND_VOLCANIC_SAND_FELSIC" },

            -- 2 volcanic, 2 sand. Intermediate extrusive.
            { mat_id = "ANDESITE",
              ghost  = "GRIND_VOLCANIC_SAND_INTERMEDIATE" },
            { mat_id = "DACITE",
              ghost  = "GRIND_VOLCANIC_SAND_INTERMEDIATE" },

            -- 1 volcanic, 3 sand. The floor for volcanic rock:
            -- basalt in vanilla, plus any modded extrusive stone
            -- this table has never heard of. Mafic and largely
            -- crystalline, so weak pozzolanic activity, and the
            -- right conservative default for an unknown.
            --
            -- Anything that should beat this ratio gets named above.
            { flag  = "IGNEOUS_EXTRUSIVE",
              ghost = "GRIND_VOLCANIC_SAND_MAFIC" },
        },
    },
    ["GRIND_COMMON_SAND"] = {
        -- Which item type carries the material we inspect. This is
        -- how RM's own watcher picks the input out of job.items
        -- (JIT_CONFIG.itype), and it is enough to tell the stone
        -- apart from the bag without needing a reagent index.
        item_type = df.item_type.BOULDER,

        -- YIELD TIERS. First match wins, so order is significant:
        -- specific materials first, the flag catch-all last.
        --
        -- Every tier fills all four bags. Only the RATIO of volcanic
        -- sand to ordinary sand changes, so nothing is wasted and no
        -- tier leaves a partial bag the mixer cannot use.
        --
        -- The ordering is pozzolanic reactivity, which tracks
        -- amorphous silica content, which in turn tracks how felsic
        -- and how glassy the rock is. That is why obsidian sits at
        -- the top: it is volcanic glass, effectively pure amorphous
        -- silica.
        --
        -- Anything not listed and not extrusive never reaches a ghost
        -- at all. It stays on the base reaction and yields four
        -- ordinary sand.
        matches = {
            -- 4 volcanic. Volcanic glass. Named explicitly so it
            -- still wins if a mod clears its igneous flag.
            { mat_id = "OBSIDIAN",
              ghost  = "GRIND_VOLCANIC_SAND" },

            -- 3 volcanic, 1 sand. Felsic extrusives: high silica,
            -- commonly glassy.
            { mat_id = "RHYOLITE",
              ghost  = "GRIND_VOLCANIC_SAND_FELSIC" },

            -- 2 volcanic, 2 sand. Intermediate extrusive.
            { mat_id = "ANDESITE",
              ghost  = "GRIND_VOLCANIC_SAND_INTERMEDIATE" },
            { mat_id = "DACITE",
              ghost  = "GRIND_VOLCANIC_SAND_INTERMEDIATE" },

            -- 1 volcanic, 3 sand. The floor for volcanic rock:
            -- basalt in vanilla, plus any modded extrusive stone
            -- this table has never heard of. Mafic and largely
            -- crystalline, so weak pozzolanic activity, and the
            -- right conservative default for an unknown.
            --
            -- Anything that should beat this ratio gets named above.
            { flag  = "IGNEOUS_EXTRUSIVE",
              ghost = "GRIND_VOLCANIC_SAND_MAFIC" },
        },
    },
}


-- ==========================================
-- READ THE ATTACHED MATERIAL
-- ==========================================
-- Returns the inorganic ID string and its raw object for the first
-- attached item of the given type, or nil if nothing is attached
-- yet. An early poll will legitimately return nil: the dwarf has
-- taken the job but has not carried the stone in.
--
-- Item type selects the slot, exactly as RM's watcher does with
-- JIT_CONFIG.itype. The bag is a different item type from the
-- stone, so no reagent index is needed.
--
-- matinfo.decode is the documented API and the one RM already uses
-- here. mat_info.inorganic is the inorganic_raw, so the caller can
-- read .id and .flags straight off it.
-- ==========================================
local function read_input_material(job, want_type)
    for _, iref in ipairs(job.items) do
        local item = iref.item
        if item then
            local ok, itype = pcall(function() return tonumber(item:getType()) end)
            if ok and itype == want_type then
                local mat_info = dfhack.matinfo.decode(item)
                if mat_info and mat_info.inorganic then
                    return mat_info.inorganic.id, mat_info.inorganic
                end
                -- Right slot, non inorganic material. Nothing to
                -- match on, so leave the job alone.
                return nil
            end
        end
    end
    return nil
end


-- ==========================================
-- PROTECT THIS MODULE'S OWN MATERIALS
-- ==========================================
-- Mirrors RM's trap door, which refuses to let a dwarf grind a
-- finished bar or a protected base metal.
--
-- Only CLINKER is currently exposed (it is the module's one BOULDER
-- product, and a BOULDER_ANY reagent will happily take it), but the
-- check is on the prefix rather than a material list so anything
-- added later is covered without touching this file.
-- ==========================================
local function is_protected(mat_id)
    return string.sub(mat_id, 1, #PROTECT_PREFIX) == PROTECT_PREFIX
end

-- Cancels the job and tells the player why. Uses RM's theme colour
-- when it is reachable so the announcement matches the rest of the
-- mod, and falls back to a plain warning colour if it is not.
local function cancel_protected(job, mat_id, mat_raw)
    local nice = mat_id
    pcall(function()
        local n = mat_raw.material.state_name[0]
        if n and n ~= '' then nice = n end
    end)

    local msg = 'A dwarf realized they were about to grind ' .. nice
                .. ' back into sand and canceled the job.'

    local color = COLOR_YELLOW
    pcall(function()
        color = reqscript('refinish-theme').get_current_theme().RISK_L
    end)

    pcall(function() dfhack.gui.showAnnouncement(msg, color, true) end)
    -- WARNING, matching the yellow announcement above.
    log('WARNING', 'Canceled job. Refused to grind protected material '
        .. mat_id .. '.', 'REFUSED')
end


-- ==========================================
-- RESOLVE A RULE
-- ==========================================
-- Walks a rule's matches in order and returns the ghost code for
-- the first one that fits, or nil.
-- ==========================================
local function resolve_ghost(rule, mat_id, mat_raw)
    for _, m in ipairs(rule.matches) do
        if m.mat_id and m.mat_id == mat_id then
            return m.ghost_code
        end
        if m.flag then
            local ok, val = pcall(function() return mat_raw.flags[m.flag] end)
            if ok and val then return m.ghost_code end
        end
    end
    return nil
end


-- ==========================================
-- DORMANT GHOSTS
-- ==========================================
-- A ghost must not be orderable. If it were, the workshop would
-- carry a second sand entry permanently, which is the exact menu
-- clutter this whole approach exists to avoid.
--
-- RM gets that for free: its ghosts do not exist until the watcher
-- compiles them. A module cannot do that, because the engine
-- injects everything declared in the JSON at boot. So the module
-- ghost is declared DORMANT instead:
--
--   permissions    NONE   no civilization is granted it
--   fortress_mode  false  the player cannot order it either
--
-- It sits in the reactions array reachable by name and invisible in
-- every menu. The watcher flips FORTRESS_MODE_ENABLED true at the
-- moment it points a job at the ghost, and back to false once no
-- job references it. Enabled exactly as long as it is needed.
-- ==========================================

-- Every ghost code the rules can produce, derived from the table so
-- it cannot drift.
-- Resolved once at load: bare keys in, full engine codes out.
local BASE_CODES  = {}   -- full base code  -> rule
local GHOST_CODES = {}   -- full ghost code -> true

for key, rule in pairs(SWAP_RULES) do
    BASE_CODES[rxn_code(key)] = rule
    for _, m in ipairs(rule.matches) do
        m.ghost_code = rxn_code(m.ghost)
        GHOST_CODES[m.ghost_code] = true
    end
end

-- Reaction objects are rebuilt every data cycle, so this cache must
-- be dropped at every cycle boundary. Without it the poll rescans
-- the whole reactions array, which is cheap with nine reactions
-- loaded and much less so with a thousand.
--
-- Clearing it in start() alone was not enough. start() runs from the
-- module listener at injection time, but a save cycle tears the
-- reactions array down and rebuilds it without ever calling start(),
-- which left every entry here pointing at a freed reaction object.
local ghost_cache = {}

-- Last observed value of _G.refinish_ram_loaded, used by poll() to
-- notice a cycle boundary. A plain boolean compare on purpose: the
-- obvious alternative, revalidating a cached entry by reading its
-- .code, would dereference the freed object and is the very fault
-- this guards against.
local last_ram_loaded = nil

--
-- A MISS IS NEVER CACHED. start() is called from inside the module
-- listener, which RM runs BEFORE it injects anything, so the first
-- lookup of a session always misses. Caching that miss poisons the
-- entry for the rest of the session and the watcher silently never
-- swaps again. Only successful lookups are worth remembering.
local function find_ghost(ghost_code)
    local cached = ghost_cache[ghost_code]
    if cached then return cached end

    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        if rxn.code == ghost_code then
            ghost_cache[ghost_code] = rxn
            return rxn
        end
    end

    -- Not injected yet. Rescan next poll rather than remembering
    -- the absence.
    return nil
end

local function set_ghost_enabled(rxn, on)
    pcall(function() rxn.flags.FORTRESS_MODE_ENABLED = on end)
end


-- ==========================================
-- THE POLL
-- ==========================================
-- One pass over the job list. Everything is wrapped in pcall so a
-- malformed job cannot take the module down, and errors are
-- reported once rather than every frame.
-- ==========================================
local err_reported = false

-- Defined below, used by poll above it.
local sweep_orphans

-- sweep_orphans has to run AFTER injection, and start() runs before
-- it. repeat-util also fires the callback synchronously on schedule,
-- so the very first poll happens inside the listener with an empty
-- reactions array. A one-shot flag gets consumed by that poll and the
-- inventory report is then permanently wrong.
--
-- So: retry every poll until the ghosts actually resolve, and give up
-- reporting only after a budget, at which point they are genuinely
-- missing rather than merely not injected yet.
local needs_sweep   = false
local sweep_tries   = 0
local SWEEP_RETRIES = 40

local function poll()
    if not dfhack.isMapLoaded() then return end

    -- refinish_active only means a map is loaded. It is assigned in
    -- exactly three places, all in refinish_steel.lua (149 on
    -- SC_MAP_LOADED, 796 on SC_MAP_UNLOADED, 860 on teardown) and by
    -- no clear or save script at all, so it stays true for the whole
    -- save cycle. It cannot gate a wash and never could.
    if not _G.refinish_active then return end

    -- This is the flag that does track the wash: refinish-clear.lua:65
    -- sets it false, refinish-index.lua:122 sets it true. Any change
    -- means the reactions array was torn down and rebuilt, so every
    -- pointer in ghost_cache is stale and must go.
    local ram_loaded = _G.refinish_ram_loaded
    if ram_loaded ~= last_ram_loaded then
        ghost_cache = {}
        last_ram_loaded = ram_loaded
    end

    -- With RM's data washed out, none of this module's reactions
    -- exist and the objects the cache pointed at have been freed.
    -- Reading or writing one here is a use-after-free, and this poll
    -- runs on FRAMES, which keep advancing while the save meter is on
    -- screen. Do nothing at all until the rebuild finishes.
    if not ram_loaded then return end

    log_once('live', 'DETAIL', 'First poll executed. Watcher is running.',
        'POLL')

    -- Deferred sweep and inventory. Waits for injection rather than
    -- assuming the first poll is late enough.
    if needs_sweep then
        local missing = {}
        for code in pairs(GHOST_CODES) do
            if not find_ghost(code) then
                table.insert(missing, code)
            end
        end

        sweep_tries = sweep_tries + 1

        if #missing == 0 then
            -- Everything is injected. Safe to sweep and report.
            needs_sweep = false
            sweep_orphans()
            for code in pairs(GHOST_CODES) do
                log('DETAIL', 'Ghost reaction present and dormant: ' .. code,
                    'GHOST')
            end
            log('DETAIL', 'Ready. Base reactions being watched: ' ..
                table.concat((function()
                    local t = {}
                    for c in pairs(BASE_CODES) do table.insert(t, c) end
                    table.sort(t)
                    return t
                end)(), ', '), 'START')

        elseif sweep_tries >= SWEEP_RETRIES then
            -- Waited long enough. These are actually absent.
            needs_sweep = false
            sweep_orphans()
            for _, code in ipairs(missing) do
                -- ERROR: the swap this ghost exists for cannot happen
                -- until the reactions JSON is fixed.
                log('ERROR', 'Ghost reaction NOT FOUND after '
                    .. sweep_tries .. ' polls: ' .. code
                    .. '. Swaps to it cannot happen. Check that it is '
                    .. 'declared in the reactions JSON and that its '
                    .. 'code is prefix .. "RXN_" .. key.', 'GHOST')
            end
        end
        -- Otherwise: injection has not finished. Try again next poll.
    end

    -- Jobs to cancel are collected here and removed AFTER the walk
    -- finishes. RM removes in place and breaks, which works, but
    -- mutating a linked list while iterating it is a hazard worth
    -- not taking when deferring costs nothing.
    local doomed = {}

    -- Ghost codes some job is currently pointing at. Anything not in
    -- here goes dormant again at the end of the pass.
    local referenced = {}

    local ok, err = pcall(function()
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            if job.job_type == df.job_type.CustomReaction then
                local rname = tostring(job.reaction_name)

                -- A job already swapped keeps its ghost enabled.
                if GHOST_CODES[rname] then
                    referenced[rname] = true
                end

                local rule = BASE_CODES[rname]

                -- Only base reactions match. Once swapped, the job
                -- holds the ghost name and falls through here, so
                -- the pass is naturally idempotent.
                if rule then
                    log_once('job:' .. rname, 'DETAIL',
                             'Observing base reaction job: ' .. rname .. '.',
                             'JOB')

                    local mat_id, mat_raw = read_input_material(job, rule.item_type)

                    if not mat_id then
                        -- Normal early in a job's life: the dwarf has
                        -- taken the order but not carried the stone in.
                        -- Logged once so a job that NEVER gets an item
                        -- is distinguishable from one that just has not
                        -- yet.
                        log_once('noitem:' .. rname, 'DETAIL',
                                 'Job ' .. rname .. ' has no item of the '
                                 .. 'expected type attached yet.', 'JOB')
                    end

                    if mat_id then
                        log_once('mat:' .. mat_id, 'DETAIL',
                                 'Job ' .. rname .. ' carrying ' .. mat_id .. '.',
                                 'JOB')

                        if is_protected(mat_id) then
                            -- This module made it. Do not grind it.
                            table.insert(doomed, { job = job,
                                                   mat_id = mat_id,
                                                   mat_raw = mat_raw })
                        else
                            local ghost = resolve_ghost(rule, mat_id, mat_raw)

                            if not ghost then
                                log_once('norule:' .. mat_id, 'DETAIL',
                                         mat_id .. ' matches no swap rule. '
                                         .. 'Leaving the job on its base reaction.',
                                         'SWAP')
                            end

                            local rxn = ghost and find_ghost(ghost)

                            if ghost and not rxn then
                                -- WARNING: the missing ghost itself is the
                                -- ERROR above; this is one job it cost.
                                log_once('noghost:' .. ghost, 'WARNING',
                                         'Rule matched ' .. mat_id .. ' but ghost '
                                         .. ghost .. ' is not in the reactions '
                                         .. 'array. No swap performed.', 'SWAP')
                            end

                            if rxn then
                                -- Wake the ghost first, then point the
                                -- job at it. Never the other way round:
                                -- a job aimed at a dormant reaction is
                                -- a job nobody is permitted to finish.
                                set_ghost_enabled(rxn, true)
                                job.reaction_name = ghost
                                referenced[ghost] = true
                                log('DETAIL', 'Ghost swap: ' .. mat_id .. ' -> '
                                    .. ghost .. '.', 'SWAP')
                            end
                        end

                    end
                end
            end
        end
    end)

    -- Assert every ghost's state, rather than only putting unused ones
    -- back to sleep. A referenced ghost that somehow lost its flag
    -- (a job restored onto it, a cycle boundary) is re-enabled here
    -- instead of sitting referenced but unrunnable.
    --
    -- Wrapped because the pcall around the job loop above closes
    -- before this point, leaving this loop the one unguarded write
    -- site in the poll. This catches Lua level faults only; a write
    -- into freed memory is not catchable, which is why the guard at
    -- the top of poll() is the actual fix and this is a backstop.
    pcall(function()
        for code in pairs(GHOST_CODES) do
            local rxn = find_ghost(code)
            if rxn then
                set_ghost_enabled(rxn, referenced[code] == true)
            end
        end
    end)

    for _, d in ipairs(doomed) do
        cancel_protected(d.job, d.mat_id, d.mat_raw)
        pcall(function() dfhack.job.removeJob(d.job) end)
    end

    if not ok then
        if not err_reported then
            err_reported = true
            log('ERROR', 'Poll failed: ' .. tostring(err), 'POLL')
        end
    else
        if err_reported then
            log('INFO', 'Poll recovered after the previous error.', 'POLL')
        end
        err_reported = false
    end
end


-- ==========================================
-- ORPHAN SWEEP
-- ==========================================
-- Points any job still holding a ghost name back at its base.
--
-- THIS IS NOT OPTIONAL. Module content is purged before every
-- save, so a job saved mid-grind carries a reaction_name that
-- resolves to nothing in the washed file. RM has the same problem
-- with its own ghosts and solves it in refinish-startup STEP 1;
-- this is the module side equivalent, run from start().
--
-- Reverting to the base is safe because the base reaction is
-- always loaded and the watcher re-resolves on the next poll.
-- ==========================================
function sweep_orphans()
    local reverted = 0

    -- Build ghost -> base from the rules, so the sweep stays in
    -- step with the table above automatically.
    local ghost_to_base = {}
    for base_code, rule in pairs(BASE_CODES) do
        for _, m in ipairs(rule.matches) do
            ghost_to_base[m.ghost_code] = base_code
        end
    end

    local ok = pcall(function()
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            if job.job_type == df.job_type.CustomReaction then
                local base = ghost_to_base[tostring(job.reaction_name)]
                if base then
                    job.reaction_name = base
                    reverted = reverted + 1
                end
            end
        end
    end)

    -- Nothing references a ghost immediately after a sweep, so make
    -- sure they all start the session dormant regardless of what
    -- state the reactions array was injected in.
    for code in pairs(GHOST_CODES) do
        local rxn = find_ghost(code)
        if rxn then set_ghost_enabled(rxn, false) end
    end

    if ok and reverted > 0 then
        log('DETAIL', 'Reverted ' .. reverted .. ' orphaned ghost job(s) to'
            .. ' their base reaction.', 'ORPHANS')
    end
end


-- ==========================================
-- LIFECYCLE
-- ==========================================
function start()
    err_reported = false
    seen = {}

    local rule_count, ghost_count = 0, 0
    for _ in pairs(BASE_CODES)  do rule_count  = rule_count  + 1 end
    for _ in pairs(GHOST_CODES) do ghost_count = ghost_count + 1 end

    -- The reactions array is rebuilt every data cycle, so last
    -- session's reaction pointers are stale.
    ghost_cache = {}

    -- Do NOT sweep here. start() is called from the module listener,
    -- which RM runs before injection, so nothing this module declares
    -- exists yet. The first poll does it instead.
    needs_sweep = true
    sweep_tries = 0

    repeatUtil.scheduleEvery(REPEAT_KEY, POLL_FRAMES, 'frames', poll)

    log('DETAIL', 'Started. Polling every ' .. POLL_FRAMES .. ' frames.'
        .. ' Watching ' .. rule_count .. ' base reaction(s), ' .. ghost_count
        .. ' ghost(s).', 'START')
end

function stop()
    repeatUtil.cancel(REPEAT_KEY)
    log('DETAIL', 'Stopped.', 'STOP')
end