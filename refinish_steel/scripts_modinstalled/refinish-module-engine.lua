--@ module = true
-- refinish-module-engine.lua
-- ==========================================
-- RM MODULE ENGINE (ORCHESTRATOR)
-- ==========================================
-- The outer shell of the module system. Handles:
--   1. Listener registration (public API for module Lua files)
--   2. Token call broadcast (discover registered modules)
--   3. JSON loading and validation
--   4. Pipeline sequencing (clone eval -> inject materials ->
--      inject categories -> inject reactions)
--   5. Cleanup (LIFO sweep of all module assets on shutdown)
--
-- NOTE: Permissions are NOT handled here. They require civ_tech
-- data from boot Pass 3, which hasn't run yet when the module
-- pipeline fires. Permission evaluation is deferred to:
--   refinish-module-evaluate-permissions.lua
-- which runs during startup Step 5.5 (after boot, before
-- core entity injection).
--
-- This file is intentionally thin. The heavy lifting lives in:
--   refinish-module-types.lua       - Type dictionaries
--   refinish-module-validate.lua    - Schema validation
--   refinish-evaluate-clone-source.lua - Clone donor selection
--   refinish-module-inject.lua      - Material injection
--   refinish-module-react.lua       - Reaction/category injection
--   refinish-module-evaluate-permissions.lua - Permission evaluation
--
-- CALLED FROM:
--   refinish_steel.lua (boot step 1)
--   refinish-startup.lua (pipeline step 2)
--   refinish-shutdown.lua (cleanup)
--
-- PUBLIC API:
--   register_listener(name, callback) - Called by module Lua files
--   run_module_pipeline()             - Called by startup
--   clear_module_assets()             - Called by shutdown
-- ==========================================

local json = require('json')
local validator = reqscript('refinish-module-validate')
local clone_eval = reqscript('refinish-evaluate-clone-source')
local injector = reqscript('refinish-module-inject')
local reactor = reqscript('refinish-module-react')

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body. The
-- panel filters on TYPE and nothing else, so each call site states
-- its own:
--   DETAIL   debugging material, shown in Debug only
--   INFO     what a player might check during play, Normal and up
--   faults, and the few confirmations a player wants at a glance
--   (COMPLETE, SYSTEM, ONLINE and the like), show in Quiet as well
-- TYPE comes first so no call site can drop it unnoticed: a nil TYPE
-- still renders, as UNTYPED, which shows at every Log Detail level
-- instead of being guessed at.
--
-- SUBJECT is the correlation slot: the module a line is about, or
-- the pipeline step when no single module is. Nil renders as a dash.
--
-- A module that does not load is an ERROR whatever the reason:
-- the player will see it broken in game, so it has to be as loud as
-- anything else that breaks.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'MODULE_ENGINE'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

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
-- MODULE REGISTRY (lives for the session)
-- ==========================================
-- Each entry is keyed by prefix string and contains the module's
-- validated payload (materials, reactions, categories, identity).
-- Populated during the token call, consumed during injection,
-- referenced during cleanup.
-- ==========================================
_G.refinish_module_registry = _G.refinish_module_registry or {}


-- ==========================================
-- UTILITY
-- ==========================================
local function count_table(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- ==========================================
-- PREFIX MATCHING
-- ==========================================
-- Anchored, plain-text prefix test.
--
-- The obvious version, string.find(str, prefix), is wrong twice over.
-- It is unanchored, so "ARGMOD_" matches "ARGMYTH_ARGMOD_..." anywhere
-- in the string and, worse, matches any longer prefix built on the same
-- stem. And its second argument is a Lua pattern, not a literal, so a
-- prefix containing - or % or . would behave unpredictably.
--
-- string.sub avoids both. It compares literal characters and only ever
-- looks at the start of the string.
-- ==========================================
local function has_prefix(str, prefix)
    return string.sub(str, 1, #prefix) == prefix
end

-- ==========================================
-- STEP 1: LISTENER REGISTRATION
-- ==========================================
-- External modules call this at load time to register their
-- callback for the token call. The callback should return a
-- table with two keys:
--   materials_json - path to the materials JSON file, or nil
--   reactions_json - path to the reactions JSON file, or nil
--   tools_json     - path to the tools JSON file, or nil
--   buildings_json - path to the buildings JSON file, or nil
--
-- Or it can return pre-built payload tables directly (for
-- power users who build payloads in Lua, like Making Metal).
--
-- Usage from a module's Lua file:
--   local engine = dfhack.script_environment('refinish-module-engine')
--   engine.register_listener("my_mod", function()
--       return {
--           materials_json = "path/to/my_mod_materials.json",
--           reactions_json = "path/to/my_mod_reactions.json",
--       }
--   end)
-- ==========================================
-- mod_id is optional and should be the [ID:...] string from the
-- module's info.txt. When supplied, broadcast_token_call checks it
-- against get_active_mods and skips the module in worlds where it
-- is not installed. Omitting it means the module is always broadcast
-- to, which is correct for Lua-only modules with no mod folder.
function register_listener(module_name, callback, mod_id)
    _G.refinish_module_listeners = _G.refinish_module_listeners or {}
    _G.refinish_module_listeners[module_name] = {
        callback = callback,
        mod_id   = mod_id,
    }
    log('DETAIL', 'Listener registered.', module_name)
end


-- ==========================================
-- JSON FILE LOADER
-- ==========================================
-- Reads and parses a JSON file from disk. Returns the parsed
-- table on success, nil + error on failure.
-- ==========================================
local function load_json_file(path)
    local file = io.open(path, "r")
    if not file then
        return nil, "Cannot open file: " .. path
    end

    local content = file:read("*all")
    file:close()

    if not content or content == "" then
        return nil, "File is empty: " .. path
    end

    local ok, parsed = pcall(json.decode, content)
    if not ok then
        return nil, "JSON parse error in " .. path .. ": " .. tostring(parsed)
    end

    return parsed
end


-- ==========================================
-- STEP 2: TOKEN CALL BROADCAST
-- ==========================================
-- Broadcasts to all registered listeners. Each listener returns
-- either JSON file paths or pre-built payload tables. We load,
-- validate, and register each module.
-- ==========================================
-- Mod ids active in the CURRENT world, keyed for lookup. Nil when the
-- API is unavailable, which means "cannot tell" and must not be read
-- as "nothing is active".
local function active_mod_ids()
    local ok, sm = pcall(require, 'script-manager')
    if not ok or not sm or not sm.get_active_mods then return nil end
    local ok2, mods = pcall(sm.get_active_mods)
    if not ok2 or type(mods) ~= 'table' then return nil end
    local ids = {}
    for _, m in ipairs(mods) do
        if m.id then ids[m.id] = true end
    end
    return ids
end

local function broadcast_token_call()
    _G.refinish_module_registry = {}
    local accepted = 0
    local rejected = 0

    -- Listeners are _G globals and the DFHack Lua state outlives the
    -- world, so a module registered under one save is still sitting
    -- here when a different save loads. Modules guard themselves with
    -- getModSourcePath, but that resolves against installed_mods
    -- globally rather than the loaded world, so it answers for a mod
    -- this save never had.
    --
    -- Reproduced live: load a save with ArgMOD, switch to a save
    -- without it, and ArgMOD injects anyway. Because it injects first,
    -- every module after it shifts index and already-built workshops
    -- render as the wrong material.
    --
    -- get_active_mods is world-scoped, so it is the correct gate.
    -- Listeners are matched by mod_id when the module supplies one.
    -- A module that supplies none is always broadcast to, which keeps
    -- Lua-only modules and the older registration signature working.
    -- Absence from get_active_mods has two causes and only one of them
    -- means "skip". getModSourcePath resolves against every installed
    -- mod, not just the loaded world (Lua_API: returns nil only if the
    -- mod cannot be found at all, and returns the newest version's path
    -- when the world simply has not loaded it). So a nil path means the
    -- mod_id matches nothing on disk, which is a bad id rather than an
    -- inactive world.
    --
    -- That distinction matters because dropping a module shrinks the
    -- injected material band and shifts every index after it. Skipping
    -- on a typo would cause the exact corruption this gate exists to
    -- prevent. An unresolvable id therefore fails open and says so,
    -- which matches how a listener with no mod_id at all is treated.
    local function mod_id_resolves(mod_id)
        local ok, sm = pcall(require, 'script-manager')
        if not ok or not sm or not sm.getModSourcePath then return true end
        local ok2, path = pcall(sm.getModSourcePath, mod_id)
        if not ok2 then return true end
        return path ~= nil
    end

    local active = active_mod_ids()

    -- DIAGNOSTIC: record exactly what the world reported before any
    -- gating decision is made, so a dropped module can be attributed
    -- rather than guessed at. If a module's id is absent from this
    -- list while its mod is installed in the world, the fault is in
    -- get_active_mods at this call site, not in the comparison below.
    -- This only logs. No behaviour changes.
    if not active then
        log('WARNING', 'get_active_mods unavailable, so no listener was gated'
            .. ' for this world.', 'BROADCAST')
    else
        local ids = {}
        for id, _ in pairs(active) do table.insert(ids, id) end
        table.sort(ids)
        log('DETAIL', string.format('World reports %d active mod(s): %s',
            #ids, table.concat(ids, ', ')), 'BROADCAST')
    end

    local listeners = {}
    local skipped = 0
    for name, entry in pairs(_G.refinish_module_listeners or {}) do
        local callback, mod_id = entry, nil
        if type(entry) == 'table' then
            callback, mod_id = entry.callback, entry.mod_id
        end
        if active and mod_id and not active[mod_id] then
            if mod_id_resolves(mod_id) then
                -- Installed somewhere, just not in this world. Correct skip.
                skipped = skipped + 1
                log('DETAIL', 'Not active in this world. Skipped.', name)
            else
                -- Matches no installed mod. Treat as unknown, not absent.
                listeners[name] = callback
                log('WARNING', string.format('Declares mod_id [%s], which matches'
                    .. ' no installed mod. Broadcasting anyway. Correct the id'
                    .. ' to match info.txt.', tostring(mod_id)), name)
            end
        else
            listeners[name] = callback
        end
    end
    if skipped > 0 then
        log('DETAIL', string.format('%d listener(s) skipped as inactive in'
            .. ' this world.', skipped), 'BROADCAST')
    end

    -- DETAIL: the roster of accepted modules further down is what a
    -- player reads; this count is the step beneath it.
    log('DETAIL', string.format('Token call broadcast, %d listener(s)'
        .. ' registered.', count_table(listeners)), 'BROADCAST')

    for module_name, callback in pairs(listeners) do
        -- Call the listener to get its payload or file paths
        local ok, response = pcall(callback)
        if not ok then
            rejected = rejected + 1
            log('ERROR', 'Rejected: crashed during its token call: '
                .. tostring(response), tostring(module_name))
            goto continue
        end

        if not response then
            rejected = rejected + 1
            log('ERROR', "Rejected: its token call returned nothing. The usual"
                .. " cause is a MODULE_ID that does not match the mod's"
                .. ' info.txt, which leaves the module unable to locate its'
                .. ' own data folder.', tostring(module_name))
            goto continue
        end

        -- ---- RESOLVE MATERIALS ----
        local materials_payload = nil
        if response.materials_json then
            -- JSON file path mode
            local parsed, err = load_json_file(response.materials_json)
            if not parsed then
                rejected = rejected + 1
                log('ERROR', 'Rejected: materials file error: '
                    .. tostring(err), tostring(module_name))
                goto continue
            end
            materials_payload = parsed
        elseif response.materials then
            -- Pre-built payload mode (Lua power users)
            materials_payload = response
        end

        -- ---- RESOLVE REACTIONS ----
        local reactions_payload = nil
        if response.reactions_json then
            local parsed, err = load_json_file(response.reactions_json)
            if not parsed then
                rejected = rejected + 1
                log('ERROR', 'Rejected: reactions file error: '
                    .. tostring(err), tostring(module_name))
                goto continue
            end
            reactions_payload = parsed
        elseif response.reactions then
            -- Pre-built payload mode
            reactions_payload = response
        end

        -- ---- RESOLVE TOOLS ----
        -- Optional third data file. A module with no tools omits it and
        -- nothing below fires. Same two modes as materials and
        -- reactions: a JSON path, or a pre-built table for Lua modules.
        --
        -- Not validated here yet. The validator has no validate_tools,
        -- so a malformed tools file reaches the injector, where every
        -- field write is pcall guarded and logs the field that failed.
        -- That degrades rather than crashes, but it is weaker than the
        -- materials path and validate_tools should close it.
        local tools_payload = nil
        if response.tools_json then
            local parsed, err = load_json_file(response.tools_json)
            if not parsed then
                rejected = rejected + 1
                log('ERROR', 'Rejected: tools file error: '
                    .. tostring(err), tostring(module_name))
                goto continue
            end
            tools_payload = parsed
        elseif response.tools then
            tools_payload = response
        end

        -- ---- RESOLVE BUILDINGS ----
        -- Optional fourth data file, the tools pattern exactly:
        -- a JSON path or a pre built table, absent means nothing
        -- below fires. buildings_dir is the JSON's own directory,
        -- carried into the registry so image paths in the schema
        -- resolve relative to the module that shipped them.
        --
        -- Not validated here yet, the same standing gap as tools;
        -- the injector pcall guards every definition and logs.
        local buildings_payload = nil
        local buildings_dir = nil
        if response.buildings_json then
            local parsed, err = load_json_file(response.buildings_json)
            if not parsed then
                rejected = rejected + 1
                log('ERROR', 'Rejected: buildings file error: '
                    .. tostring(err), tostring(module_name))
                goto continue
            end
            buildings_payload = parsed
            buildings_dir = response.buildings_json:match('^(.*)[/\\]')
        elseif response.buildings then
            buildings_payload = response
            buildings_dir = response.buildings_dir
        end

        -- ---- RESOLVE PLANTS ----
        -- The tools and buildings pattern exactly: a JSON path or a
        -- pre built table, absent means nothing downstream fires.
        --
        -- Not validated, the same standing gap as tools and
        -- buildings; the injector pcall guards every definition and
        -- logs. A plant host is inert by construction, since the
        -- neutral reset strips its flags, biomes and spawn rates, so
        -- a malformed one costs its own materials and nothing else.
        local plants_payload = nil
        if response.plants_json then
            local parsed, err = load_json_file(response.plants_json)
            if not parsed then
                rejected = rejected + 1
                log('ERROR', 'Rejected: plants file error: '
                    .. tostring(err), tostring(module_name))
                goto continue
            end
            plants_payload = parsed
        elseif response.plants then
            plants_payload = response
        end

        -- ---- VALIDATE ----
        local prefix = nil

        if materials_payload then
            local ok_v, valid, reason = pcall(validator.validate_materials, materials_payload)
            if not ok_v then
                valid, reason = false, "validator error: " .. tostring(valid)
            end
            if not valid then
                rejected = rejected + 1
                log('ERROR', 'Rejected: materials validation failed: '
                    .. tostring(reason), tostring(module_name))
                goto continue
            end
            prefix = materials_payload.module.prefix
        end

        if reactions_payload then
            local ok_v, valid, reason = pcall(validator.validate_reactions, reactions_payload)
            if not ok_v then
                valid, reason = false, "validator error: " .. tostring(valid)
            end
            if not valid then
                rejected = rejected + 1
                log('ERROR', 'Rejected: reactions validation failed: '
                    .. tostring(reason), tostring(module_name))
                goto continue
            end
            -- Cross-check: if both payloads exist, prefixes must match
            if prefix and reactions_payload.module.prefix ~= prefix then
                rejected = rejected + 1
                log('ERROR', string.format("Rejected: prefix mismatch, materials"
                    .. " '%s' against reactions '%s'.", prefix,
                    tostring(reactions_payload.module.prefix)),
                    tostring(module_name))
                goto continue
            end
            prefix = prefix or reactions_payload.module.prefix
        end

        -- ---- PREFIX FROM TOOLS ----
        -- Third fallback. Materials and reactions are checked above;
        -- without this a tools-only module is rejected for having no
        -- prefix even though it supplied one, which is why the
        -- containers needed a dummy material entry to inject at all.
        if not prefix and tools_payload and tools_payload.module then
            prefix = tools_payload.module.prefix
        end

        -- Fourth fallback, for a buildings only module: a pure
        -- furniture module ships nothing else.
        if not prefix and buildings_payload and buildings_payload.module then
            prefix = buildings_payload.module.prefix
        end

        -- ---- PREFIX COLLISION CHECK ----
        if not prefix then
            rejected = rejected + 1
            log('ERROR', 'Rejected: no payload carried a prefix.',
                tostring(module_name))
            goto continue
        end

        -- Two prefixes collide when either is a stem of the other, not
        -- only when they are equal. Every sweep in this engine selects
        -- assets by prefix, so "ARGMOD_" also selects
        -- "ARGMOD_MYTH_ORICHALCUM", and ArgMOD's shutdown would clear
        -- another module's materials. Anchoring the comparison does not
        -- help: a stem really is at the start of the string. Refusing
        -- the overlap here is the only fix.
        --
        -- has_prefix(x, x) is true, so this also catches the exact
        -- duplicate registration the old check was looking for.
        local clash = nil
        if has_prefix(prefix, "REFINISH_STEEL_") or has_prefix("REFINISH_STEEL_", prefix) then
            clash = "REFINISH_STEEL_ (RM core)"
        else
            for other, _ in pairs(_G.refinish_module_registry) do
                if has_prefix(prefix, other) or has_prefix(other, prefix) then
                    clash = other
                    break
                end
            end
        end

        if clash then
            rejected = rejected + 1
            log('ERROR', string.format('Rejected: prefix [%s] overlaps [%s]. One'
                .. ' is a stem of the other, so their assets cannot be told'
                .. " apart. Choose a prefix that is not built on another"
                .. " module's.", prefix, clash), tostring(module_name))
            goto continue
        end

        -- ---- DATA DIRECTORY ----
        -- The folder the module's own JSON came from, which is where
        -- its images/ live. Buildings already derive this for
        -- themselves; materials need it too, because a materials file
        -- can name a FILE sprite source and a relative path has to
        -- resolve against the module that shipped it rather than
        -- against whatever the working directory happens to be.
        --
        -- Materials file first, since that is the one that names
        -- sprites; buildings_dir as a fallback so a module shipping
        -- only buildings still gets a root.
        local data_dir = nil
        if response.materials_json then
            data_dir = response.materials_json:match('^(.*)[/\\]')
        end
        data_dir = data_dir or buildings_dir

        -- ---- REGISTER ----
        local mod_name = "unknown"
        local depends_on = {}
        if materials_payload and materials_payload.module then
            mod_name = materials_payload.module.name
            depends_on = materials_payload.module.depends_on or {}
        elseif reactions_payload and reactions_payload.module then
            mod_name = reactions_payload.module.name
            depends_on = reactions_payload.module.depends_on or {}
        end

        -- If only the reactions file declares dependencies, honour them.
        -- Modules are free to put depends_on in either file or both, the
        -- same way they may declare the prefix in either.
        if #depends_on == 0 and reactions_payload and reactions_payload.module then
            depends_on = reactions_payload.module.depends_on or {}
        end

        _G.refinish_module_registry[prefix] = {
            name       = mod_name,
            prefix     = prefix,
            depends_on = depends_on,
            materials  = materials_payload and materials_payload.materials or {},
            reactions  = reactions_payload and reactions_payload.reactions or {},
            categories = reactions_payload and reactions_payload.categories or {},
            tools      = tools_payload and tools_payload.tools or {},
            buildings  = buildings_payload and buildings_payload.buildings or {},
            buildings_dir = buildings_dir,
            data_dir      = data_dir,
            -- Plants must be listed here explicitly. This table is
            -- the ONLY thing the injection pass sees: a field the
            -- token call returns but this record omits is silently
            -- dropped, with no error anywhere, which is exactly how
            -- the plant host injected nothing while every other
            -- piece of the pipeline was correctly wired.
            plants     = plants_payload and plants_payload.plants or {},

            -- ==========================================
            -- POST MATERIAL CALLBACK
            -- ==========================================
            -- An optional function the module returns, run once its
            -- materials are in the array. Absent means no call, so
            -- every module written before this field is untouched.
            --
            -- It exists because the token call happens BEFORE
            -- injection. A module that mints materials at runtime has
            -- no other moment to finish them: anything it does during
            -- the token call runs against materials that do not exist
            -- yet, and a state change hook of its own has no
            -- guaranteed order against this pipeline.
            -- ==========================================
            on_materials_injected = response.on_materials_injected,
        }

        accepted = accepted + 1
        local mat_count = materials_payload and #materials_payload.materials or 0
        local rxn_count = reactions_payload and #reactions_payload.reactions or 0

        -- ---- A MODULE CAME UP ----
        -- SUBJECT is the module name, so the column answers WHICH
        -- module without reading the body and a run of these reads as
        -- a roster. INFO: Normal shows which modules are running, and
        -- Quiet only hears about a module when one is rejected.
        log('INFO', string.format('Accepted: prefix [%s], %d materials, %d'
            .. ' reactions.', prefix, mat_count, rxn_count), tostring(mod_name))

        ::continue::
    end

    log('DETAIL', string.format('Token call complete. %d accepted, %d'
        .. ' rejected.', accepted, rejected), 'TOKEN_CALL')

    return accepted
end

-- ==========================================
-- INJECTION ORDER RESOLUTION
-- ==========================================
-- Decides which order modules are injected in.
--
-- WHY THIS EXISTS:
-- The engine injects one whole module at a time (materials, then
-- categories, then reactions). Reaction building resolves mat_id
-- references against the live inorganic array as it stands at that
-- moment, so a module can only name materials from raws, from itself,
-- or from a module already injected. Get the order wrong and the
-- references resolve to -1, which DF renders as magma.
--
-- Modules declare what they need via module.depends_on. This turns
-- that into a concrete order.
--
-- HOW:
-- Kahn's algorithm. Repeatedly take a module with no unplaced
-- dependencies and append it. Ready modules are taken in alphabetical
-- order rather than whatever order pairs() happens to produce, so the
-- result is identical on every data cycle. That matters: injected
-- material positions have to be stable across a hotsave.
--
-- Modules whose dependencies are not installed are dropped, and so is
-- anything depending on those, transitively. See the note in the
-- change document about why dropping beats loading broken.
--
-- Returns: an ordered array of prefixes to inject.
-- ==========================================
local function resolve_injection_order(registry)
    -- Alphabetical baseline. Everything below preserves this order
    -- among modules that the dependency graph leaves interchangeable.
    local prefixes = {}
    for prefix, _ in pairs(registry) do
        table.insert(prefixes, prefix)
    end
    table.sort(prefixes)

    local present = {}
    for _, p in ipairs(prefixes) do
        present[p] = true
    end

    -- ---- STEP 1: DROP MODULES WITH MISSING DEPENDENCIES ----
    -- Loops until nothing changes, so a module depending on a dropped
    -- module is dropped too, however long the chain is.
    local dropped = {}
    local changed = true
    while changed do
        changed = false
        for _, p in ipairs(prefixes) do
            if not dropped[p] then
                for _, dep in ipairs(registry[p].depends_on or {}) do
                    if not present[dep] or dropped[dep] then
                        dropped[p] = dep
                        changed = true
                        break
                    end
                end
            end
        end
    end

    for _, p in ipairs(prefixes) do
        if dropped[p] then
            log('ERROR', string.format('Skipped: requires module [%s], which'
                .. ' is not loaded.', tostring(dropped[p])),
                tostring(registry[p].name))
        end
    end

    -- ---- STEP 2: BUILD THE GRAPH ----
    -- unmet[p]      = how many of p's dependencies are not yet placed
    -- dependents[p] = modules waiting on p
    local unmet, dependents = {}, {}
    for _, p in ipairs(prefixes) do
        if not dropped[p] then
            unmet[p] = 0
            dependents[p] = dependents[p] or {}
        end
    end
    for _, p in ipairs(prefixes) do
        if not dropped[p] then
            for _, dep in ipairs(registry[p].depends_on or {}) do
                unmet[p] = unmet[p] + 1
                dependents[dep] = dependents[dep] or {}
                table.insert(dependents[dep], p)
            end
        end
    end

    -- ---- STEP 3: PLACE THEM ----
    local order, placed = {}, {}
    local remaining = 0
    for _ in pairs(unmet) do
        remaining = remaining + 1
    end

    while remaining > 0 do
        -- First unplaced module with nothing left to wait for.
        -- prefixes is sorted, so this is the alphabetical tie-break.
        local pick = nil
        for _, p in ipairs(prefixes) do
            if unmet[p] == 0 and not placed[p] then
                pick = p
                break
            end
        end

        -- Nothing is ready, so the remainder form a dependency cycle.
        -- Break it alphabetically and say so. One of the modules in
        -- the cycle will inject before something it declared it needs,
        -- so its references may not resolve.
        if not pick then
            for _, p in ipairs(prefixes) do
                if unmet[p] and not placed[p] then
                    pick = p
                    break
                end
            end
            log('WARNING', string.format('Dependency cycle detected; broken at'
                .. ' [%s].', tostring(pick)), 'ORDER')
        end

        table.insert(order, pick)
        placed[pick] = true
        remaining = remaining - 1

        for _, waiting in ipairs(dependents[pick] or {}) do
            if unmet[waiting] then
                unmet[waiting] = unmet[waiting] - 1
            end
        end
    end

    return order
end

-- ==========================================
-- JOB FILTERS FOLLOW THEIR REACTION
-- ==========================================
-- A job names its reaction by CODE, in job.reaction_name, but each of
-- its filters (job.job_items.elements[i]) names it by POSITION in
-- world.raws.reactions.reactions, in reaction_id, and DF checks a
-- filter's rules, its contents rule included, against the reaction at
-- that position. DF writes that position once, when it makes the job.
--
-- Runtime reactions do not keep their positions. Module reactions move
-- whenever a module's reaction list changes, and runtime clones are
-- swept at every data cycle and re-cut in whatever order they are next
-- needed. A job saved in one session then points its filters at
-- whatever sits at the old position, or at nothing.
--
-- MEASURED: repeating fill job 8631 at a kiln held reaction_id 1740
-- while its clone had been re-cut at 1730, in an array of 1735. With no
-- reaction at 1740 to test against, DF accepted an EMPTY jug as a
-- container of fuel, and the job completed empty every cycle across
-- three reloads. Completion still worked, because completion goes by
-- code; only the filters were lost.
--
-- So every job on a runtime reaction is pointed back at where its
-- reaction is NOW:
--   * the target is the job's own reaction, where DF points every
--     filter when it makes a job;
--   * except a job the fuel module's ghost has moved onto a per-job
--     clone, coded <base>_GHOST_..._J<job id>, whose filters were made
--     for the base and are meant to stay on it: its target is the base;
--   * a filter at -1 names no reaction and is left as it is;
--   * a job whose reaction does not exist yet, a clone its owner has
--     not cut this session, is left alone. The owner calls this again
--     after cutting, through _G.refinish_repoint_jobs.
-- A vanilla job already points at its own reaction and is untouched.
-- Returns the number of jobs and of filters it moved.
function repoint_job_filters()
    local at = {}
    for i, r in ipairs(df.global.world.raws.reactions.reactions) do
        local c = nil
        pcall(function() c = r.code end)
        if c then at[c] = i end
    end
    local jobs, filters = 0, 0
    local l = df.global.world.jobs.list.next
    while l do
        local j = l.item
        if j then
            pcall(function()
                if j.job_type ~= df.job_type.CustomReaction then return end
                local code = tostring(j.reaction_name or '')
                local want = at[code:match('^(.-)_GHOST_') or code]
                if not want then return end
                local moved = 0
                for _, e in ipairs(j.job_items.elements) do
                    if e.reaction_id >= 0 and e.reaction_id ~= want then
                        e.reaction_id = want
                        moved = moved + 1
                    end
                end
                if moved > 0 then
                    jobs, filters = jobs + 1, filters + moved
                end
            end)
        end
        l = l.next
    end
    return jobs, filters
end

-- ==========================================
-- STEP 3: PIPELINE EXECUTION
-- ==========================================
-- Runs the module pipeline in order:
--   1. Token call (discover and validate modules)
--   2. Clone source evaluation (pick donors per class)
--   3. Material injection (per module)
--   4. Category injection (per module)
--   5. Reaction injection (per module)
--
-- Permission injection is NOT part of this pipeline.
-- It runs later via refinish-module-evaluate-permissions.lua
-- (startup Step 5.5), after boot has built civ_tech.
--
-- Guard: _G.refinish_modules_injected prevents double-firing
-- during boot. Cleared on shutdown so re-firing works after
-- a data cycle wipe.
-- ==========================================
function run_module_pipeline()
    if _G.refinish_modules_injected then return end

    -- ---- STEP 1: TOKEN CALL ----
    local module_count = broadcast_token_call()
    if module_count == 0 then
        log('INFO', 'No modules responded. Pipeline skipped.', 'PIPELINE')
        return
    end

    -- ---- STEP 2: CLONE SOURCE EVALUATION ----
    -- Collect which material classes are actually needed across
    -- all registered modules, so the evaluator only scans for
    -- classes that will be used.
    local classes_needed = {}
    local class_set = {}
    for _, module in pairs(_G.refinish_module_registry) do
        for _, mat in ipairs(module.materials) do
            if mat.material_class and not class_set[mat.material_class] then
                table.insert(classes_needed, mat.material_class)
                class_set[mat.material_class] = true
            end
        end
    end
    clone_eval.evaluate(classes_needed)

    -- Log the clone selections for visibility
    -- Both DETAIL. A class with no donor is already a WARNING from the
    -- clone evaluator, so this does not report the same fault twice.
    if _G.refinish_module_clone_cache then
        for _, class_name in ipairs(classes_needed) do
            local donor = _G.refinish_module_clone_cache[class_name]
            if donor then
                log('DETAIL', string.format('Clone selection: [%s].', donor.id),
                    class_name)
            else
                log('DETAIL', 'Clone selection: no donor found.', class_name)
            end
        end
    end

    -- ---- STEPS 3-5: PER-MODULE INJECTION ----
    -- Order comes from resolve_injection_order, which honours declared
    -- dependencies and falls back to alphabetical wherever the graph
    -- does not care. Deterministic across cycles either way.
    --
    -- NOTE: Permissions are NOT injected here. They require
    -- civ_tech data from boot Pass 3 (which metals each civ
    -- knows), and boot hasn't run yet at this point in the
    -- pipeline. Permission injection is handled by the dedicated
    -- evaluator (refinish-module-evaluate-permissions.lua) which
    -- runs after boot, during startup Step 5.5.
    local injection_order = resolve_injection_order(_G.refinish_module_registry)

    -- Published so the permission evaluator uses the same order.
    -- Cleared by clear_module_assets on shutdown.
    _G.refinish_module_order = injection_order

    local total_mats = 0
    local total_cats = 0
    local total_rxns = 0
    local total_blds = 0

    -- Reports a failed injection step and returns 0 so the running
    -- totals stay valid.
    --
    -- Lua puts "file:line:" at the front of every runtime error, so the
    -- message alone identifies where it happened. No traceback needed,
    -- and nothing here uses a facility this codebase has not already
    -- proven works.
    local function report_failure(label, prefix, err)
        -- ERROR: a step that fails leaves that module's content missing
        -- in play, which a player will notice.
        log('ERROR', string.format('%s failed: %s', label, tostring(err)),
            prefix)
        return 0
    end

    for _, prefix in ipairs(injection_order) do
        local module = _G.refinish_module_registry[prefix]

        -- Each step is wrapped on its own. A fault anywhere in the
        -- injection path used to unwind the whole pipeline with nothing
        -- in the log to say which module or which step, which cost
        -- every remaining module too. Now one step failing costs one
        -- step, and says so.
        --
        -- Explicit closures rather than a varargs wrapper: no unpack,
        -- so there is no Lua version question to get wrong.

        -- The sprite root, set before ANY of this module's assets
        -- inject. It sat after the tools block, which made the comment
        -- a lie: tools inject first, so a tool naming a FILE sprite
        -- resolved against an empty root and failed with both
        -- candidate paths printed identically, while materials a few
        -- steps later loaded from the same folder fine.
        pcall(function()
            local sprites = dfhack.script_environment('refinish-sprite-engine')
            if sprites and sprites.set_file_root then
                sprites.set_file_root(module.data_dir)
            end
        end)

        -- Tools
        --
        -- Ahead of materials and reactions both. Reactions resolve tool
        -- subtypes at build time, so a reagent naming an injected tool
        -- needs that tool already in world.raws.itemdefs.tools or it
        -- silently resolves to -1 and matches any tool at all.
        --
        -- Its own pcall like every other step, so a bad tools file
        -- costs the tools and nothing else.
        if module.tools and #module.tools > 0 then
            local ok, res = pcall(function()
                local tool_injector = dfhack.script_environment('refinish-module-inject-tool')
                return tool_injector.inject_tools(module.tools, prefix, module.name)
            end)
            if not ok then
                report_failure("TOOL INJECTION", prefix, res)
            end

            -- ---- RESTORE WASHED ITEMS ----
            -- Immediately after injection, while nothing else has had a
            -- chance to read a subtype. Every item washed onto the
            -- fallback before the last save gets pointed back at the
            -- tool it came from.
            --
            -- Skipping this is what turns casks into cauldrons: a saved
            -- subtype of 321 resolves against a raws-only array of 321
            -- entries, falls out of range, and DF defaults to 0, which
            -- is ITEM_TOOL_CAULDRON.
            local ok_r, err_r = pcall(function()
                dfhack.script_environment('refinish-tool-wash').restore()
            end)
            if not ok_r then
                report_failure("TOOL RESTORE", prefix, err_r)
            end

            -- ---- SPRITES ----
            -- Injection builds a fresh itemdef every session with every
            -- texpos field at zero, because texpos values are resolved
            -- from the graphics raws at raw load and an injected tool
            -- never goes through it. Copying them from a vanilla donor
            -- has to happen on every injection, not once.
            --
            -- Its own pcall: no sprite is a cosmetic failure and must
            -- never take the pipeline down with it.
            local ok_g, err_g = pcall(function()
                dfhack.run_script('refinish-tool-graphics', 'copyall', prefix)
            end)
            if not ok_g then
                report_failure("TOOL GRAPHICS", prefix, err_g)
            end
        end

        -- Plants
        --
        -- Before materials, and before everything that resolves a
        -- material token. A plant is a HOST: its own materials are
        -- what a module addresses as PLANT_MAT:<PLANT ID>:<KEY>, and
        -- a plant material is the only way to get a bar that does not
        -- read "bars", because the suffix belongs to the inorganic
        -- branch of DF's item description code. Measured, not
        -- assumed: the same bar reads "iron bars" as an inorganic and
        -- bare as a plant material.
        --
        -- Injection APPENDS to world.raws.plants.all, so existing
        -- plant indices never move and mat_type 419 plus index stays
        -- valid for every item already in the world.
        --
        -- Own pcall like every other step: a bad plants file costs
        -- the plants and nothing else.
        if module.plants and #module.plants > 0 then
            local ok, res = pcall(function()
                local plant_injector = dfhack.script_environment('refinish-module-inject-plant')
                return plant_injector.inject_plants(module.plants, prefix, module.name)
            end)
            if not ok then
                report_failure("PLANT INJECTION", prefix, res)
            end
        end

        -- Materials
        if #module.materials > 0 then
            local ok, res = pcall(function()
                return injector.inject(module.materials, prefix, module.name)
            end)
            if ok then
                total_mats = total_mats + (res or 0)
            else
                report_failure("MATERIAL INJECTION", prefix, res)
            end
        end

        -- ---- POST MATERIAL CALLBACK ----
        -- The moment this module's materials are in the array, and
        -- before anything else touches them. A module that mints
        -- materials at runtime finishes them here: fields the JSON
        -- schema cannot express, copied per material off a live
        -- source.
        --
        -- Own pcall, and loud on failure. Materials that injected but
        -- were never finished are the worst case in this whole path,
        -- because they resolve by token and look present while
        -- carrying whatever the clone donor happened to hold.
        if type(module.on_materials_injected) == 'function' then
            local ok_pm, err_pm = pcall(module.on_materials_injected)
            if not ok_pm then
                report_failure("POST MATERIAL CALLBACK", prefix, err_pm)
            end
        end

        -- Root cleared the moment this module's sprite-bearing assets
        -- are done. Buildings below carry their own directory and do
        -- not read it, so nothing after this point needs it, and a
        -- module that injects a sprite outside its own steps cannot
        -- silently resolve inside this module's folder.
        pcall(function()
            local sprites = dfhack.script_environment('refinish-sprite-engine')
            if sprites and sprites.set_file_root then
                sprites.set_file_root(nil)
            end
        end)

        -- Buildings
        --
        -- After materials, before categories and reactions: the
        -- reaction resolver matches a reaction's building code
        -- against the live vectors at build time, so an injected
        -- building must already be registered when its reactions
        -- build. Own pcall like every other step.
        if module.buildings and #module.buildings > 0 then
            local ok, res = pcall(function()
                local bld_injector = dfhack.script_environment('refinish-module-inject-building')
                return bld_injector.inject_buildings(
                    module.buildings, prefix, module.name, module.buildings_dir)
            end)
            if ok then
                total_blds = total_blds + (res or 0)
            else
                report_failure("BUILDING INJECTION", prefix, res)
            end
        end

        -- Categories (before reactions, so category IDs exist when
        -- reactions reference them)
        if module.categories and #module.categories > 0 then
            local ok, res = pcall(function()
                return reactor.inject_categories(module.categories, prefix)
            end)
            if ok then
                total_cats = total_cats + (res or 0)
            else
                report_failure("CATEGORY INJECTION", prefix, res)
            end
        end

        -- Reactions
        if #module.reactions > 0 then
            local ok, res = pcall(function()
                return reactor.inject_reactions(
                    module.reactions, prefix, module.name,
                    _G.refinish_module_registry
                )
            end)
            if ok then
                total_rxns = total_rxns + (res or 0)
            else
                report_failure("REACTION INJECTION", prefix, res)
            end
        end
    end

    -- ---- FINAL PASS: CROSS-MODULE REACTION PRODUCTS ----
    -- Runs after every module's materials exist, so a reaction_product
    -- pointing at another module resolves regardless of which order the
    -- two injected in. See resolve_deferred_products() for why ordering
    -- alone cannot solve this.
    local resolved = injector.resolve_deferred_products()
    if resolved > 0 then
        log('DETAIL', string.format('Resolved %d deferred reaction_product'
            .. ' definitions across all modules.', resolved), 'DEFERRED')
    end

    _G.refinish_modules_injected = true

    -- ---- SAVED JOBS FOLLOW THEIR REACTIONS ----
    -- Every module reaction now sits at its position for this session,
    -- so jobs saved against old positions are pointed back at their own
    -- reactions (see JOB FILTERS FOLLOW THEIR REACTION). Published for
    -- the scripts that cut clones later, which call it after each cut.
    _G.refinish_repoint_jobs = repoint_job_filters
    local ok_rp, n_jobs, n_filters = pcall(repoint_job_filters)
    -- ERROR on failure: a saved job left pointing at another reaction's
    -- position tests its items against the wrong recipe.
    if not ok_rp then
        log('ERROR', 'Job filter repoint failed: ' .. tostring(n_jobs),
            'REPOINT')
    elseif n_jobs > 0 then
        log('DETAIL', string.format("Re-pointed %d filter(s) on %d saved"
            .. " job(s) to their reactions' current positions.", n_filters,
            n_jobs), 'REPOINT')
    end

    log('DETAIL', string.format('Pipeline complete: %d modules, %d materials,'
        .. ' %d categories, %d reactions, %d buildings. Permissions deferred'
        .. ' to the evaluator.', module_count, total_mats, total_cats,
        total_rxns, total_blds), 'PIPELINE')
end


-- ==========================================
-- CLEANUP: CLEAR ALL MODULE ASSETS
-- ==========================================
-- Sweeps all materials, reactions, and categories for each
-- registered module prefix. Called during RM's shutdown
-- sequence alongside the REFINISH_STEEL_ sweep.
--
-- Order matters:
--   1. Entity permissions (remove reaction indexes from civs)
--   2. Reactions (LIFO sweep)
--   3. Categories (LIFO sweep)
--   3.5 Buildings (unlink, refinish-module-inject-building)
--   4. Materials (LIFO sweep)
--   5. Plants (LIFO sweep, refinish-module-inject-plant)
--
-- Buildings after reactions because reactions resolve their
-- building at inject time; once reactions are gone, nothing
-- references a building def. Before materials for the day a
-- build item gates on a module material.
-- Permissions first because they reference reaction indexes.
-- Reactions before materials because reactions may reference
-- material indexes. LIFO (end-to-start) preserves earlier
-- indexes during deletion.
-- ==========================================
function clear_module_assets()
    local total_cleared = 0

    -- ---- CACHE HANDSHAKE, RAISED FIRST ----
    -- Before anything is removed, not after, so a lookup that lands
    -- part way through this sweep rebuilds rather than answering
    -- from a table describing the vector as it was. Both caches go:
    -- this clears materials and tools together.
    _G.refinish_material_cache_dirty = true
    _G.refinish_itemdef_cache_dirty = true

    -- ---- COLLECT ALL REACTION INDEXES TO REMOVE ----
    local reactions = df.global.world.raws.reactions.reactions
    local rxn_ids_to_remove = {}
    for prefix, _ in pairs(_G.refinish_module_registry) do
        for i, rxn in ipairs(reactions) do
            if has_prefix(rxn.code, prefix) then
                rxn_ids_to_remove[rxn.index] = true
            end
        end
    end

    -- ---- STEP 1: SWEEP ENTITY PERMISSIONS ----
    -- Remove module reaction indexes from all civ permission lists.
    -- Must happen before reactions are deleted to avoid dangling refs.
    for _, civ in ipairs(df.global.world.entities.all) do
        if civ.type == df.historical_entity_type.Civilization and civ.entity_raw then
            local permitted = civ.entity_raw.workshops.permitted_reaction_id
            for i = #permitted - 1, 0, -1 do
                if rxn_ids_to_remove[permitted[i]] then
                    permitted:erase(i)
                end
            end
        end
    end

    -- ---- PER-PREFIX CLEANUP ----
    for prefix, module in pairs(_G.refinish_module_registry) do
        local mat_cleared = 0
        local rxn_cleared = 0
        local cat_cleared = 0
        local bld_cleared = 0

        -- ---- STEP 0: SWEEP TOOLS ----
        -- Before reactions, because a reagent holds a resolved tool
        -- subtype and deleting the reaction first leaves nothing to
        -- care about, while deleting the tool first would leave a live
        -- reaction pointing at a position that has moved.
        --
        -- CALLER OBLIGATION, unchanged by this being wired up: any item
        -- carrying an owned tool subtype has to be in the payload before
        -- this runs. Call census() on the tool ledger to find out. A
        -- save taken with owned tools live in the arrays is the same
        -- class of corruption as one taken with module materials live.
        -- Wash and clear are SEPARATE pcalls, deliberately.
        --
        -- Sharing one means a wash failure takes the clear down with
        -- it, silently, and the save then writes with injected tools
        -- still in the array. That produces "Missing Item Definition"
        -- on the next load and a failed load, which is strictly worse
        -- than an unwashed save.
        --
        -- Clearing must happen even when washing could not.
        -- Logged inline rather than through report_failure, which is a
        -- local inside run_module_pipeline and is not in scope here.
        -- Calling it from this function throws, kills the sweep partway
        -- through the pairs() loop, and leaves every module after this
        -- one in hash order completely uncleared.
        local ok_w, err_w = pcall(function()
            dfhack.script_environment('refinish-tool-wash').wash(prefix)
        end)
        if not ok_w then
            log('ERROR', 'Tool wash failed: ' .. tostring(err_w),
                tostring(prefix))
        end

        local ok_c, err_c = pcall(function()
            local tool_injector = dfhack.script_environment('refinish-module-inject-tool')
            tool_injector.clear_tools(prefix)
        end)
        if not ok_c then
            log('ERROR', 'Tool clear failed: ' .. tostring(err_c),
                tostring(prefix))
        end

        -- ---- STEP 2: SWEEP REACTIONS (LIFO) ----
        for i = #reactions - 1, 0, -1 do
            if has_prefix(reactions[i].code, prefix) then
                reactions[i]:delete()
                reactions:erase(i)
                rxn_cleared = rxn_cleared + 1
            end
        end

        -- ---- STEP 3: SWEEP CATEGORIES (LIFO) ----
        local cats = df.global.world.raws.reactions.reaction_categories
        for i = #cats - 1, 0, -1 do
            if has_prefix(cats[i].id, prefix) then
                cats[i]:delete()
                cats:erase(i)
                cat_cleared = cat_cleared + 1
            end
        end

        -- ---- STEP 3.5: SWEEP BUILDINGS (UNLINK) ----
        -- Unlink, not delete, and prefix owned defs only. The
        -- injector carries the full rationale, including why
        -- placed buildings deliberately keep their custom_type:
        -- measured safe across save and reload, and the id
        -- reservation ledger resolves them again on next inject.
        local ok_b, res_b = pcall(function()
            local bld_injector = dfhack.script_environment('refinish-module-inject-building')
            return bld_injector.clear_buildings(prefix)
        end)
        if ok_b then
            bld_cleared = res_b or 0
        else
            log('ERROR', 'Building clear failed: ' .. tostring(res_b),
                tostring(prefix))
        end

        -- ---- STEP 4: SWEEP MATERIALS (LIFO) ----
        local raws = df.global.world.raws.inorganics.all
        for i = #raws - 1, 0, -1 do
            if has_prefix(raws[i].id, prefix) then
                raws[i]:delete()
                raws:erase(i)
                mat_cleared = mat_cleared + 1
            end
        end

        -- ---- STEP 5: SWEEP PLANTS (LIFO) ----
        -- Last, because a plant OWNS the materials hanging off it and
        -- everything above may still be reading one. Deleting the
        -- plant deletes those materials with it, which is correct:
        -- the injector built them fresh per session and nothing else
        -- points at them. The donor's own materials were never held,
        -- only used as a template, so no vanilla plant is touched.
        --
        -- Erase then delete, LIFO, the same shape as the material and
        -- reaction sweeps above.
        local plt_cleared = 0
        local ok_p, res_p = pcall(function()
            local plant_injector = dfhack.script_environment('refinish-module-inject-plant')
            return plant_injector.clear_plants(prefix)
        end)
        if ok_p then
            plt_cleared = res_p or 0
        else
            log('ERROR', 'Plant clear failed: ' .. tostring(res_p),
                tostring(prefix))
        end

        total_cleared = total_cleared + plt_cleared
        total_cleared = total_cleared + mat_cleared + rxn_cleared + cat_cleared + bld_cleared
        log('DETAIL', string.format('Cleared %d materials, %d reactions, %d'
            .. ' categories, %d buildings, %d plants.', mat_cleared,
            rxn_cleared, cat_cleared, bld_cleared, plt_cleared),
            tostring(prefix))
    end

    _G.refinish_modules_injected = false
    _G.refinish_module_order = nil
    _G.refinish_module_deferred_products = nil
    return total_cleared
end


return _ENV