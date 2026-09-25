--@ module = true
-- refinish-module-evaluate-permissions.lua
-- ==========================================
-- RM MODULE PERMISSION EVALUATOR
-- ==========================================
-- Determines which civilizations should receive permission for
-- each module reaction. This is the module system's equivalent
-- of boot Pass 3 + index-entity for RM core.
--
-- DESIGN PRINCIPLE:
--   A module reaction is only injected into a civ's workshop if:
--     1. The civ has the BUILDING CAPABILITY for that reaction's
--        workshop type (mood check or permitted_job check)
--     2. The civ KNOWS every metal that the reaction consumes
--        as reagents (same Sources A/B1/B2/B3 knowledge that
--        boot evaluates for core RM)
--     3. If the module specifies explicit entity targeting, only
--        the named entities are considered - but gates 1 and 2
--        still apply. RM does not inject broken permissions.
--
-- PERMISSION MODES (set per-reaction in the JSON):
--   "AUTO"        - (default) Evaluate all civs using the full
--                    gate logic. Same standard as RM core.
--   "ENTITY_CODE" - Only evaluate the named entity_raw codes.
--                    Gates 1 and 2 still apply. If a named civ
--                    fails, the permission is rejected and logged.
--   "NONE"        - No permits pushed to any civ. The reaction
--                    is only accessible if fortress_mode is true.
--                    Valid inorganic + valid reaction + no permits
--                    + fort mode = player-only access.
--
-- PRODUCT REGISTRATION:
--   After injecting a reaction's permissions, the evaluator
--   registers all product metals as "known" for each civ that
--   received the reaction. This feeds back into the knowledge
--   graph so that downstream consumers (like RM core's Refinish
--   reactions) can gate on module-produced metals.
--
--   For the player civ specifically, product metals are also
--   written to _G.refinish_known_metals_cache - the flat set
--   that the UI metals panel reads for display state.
--
-- DEPENDENCIES:
--   _G.refinish_module_registry - Populated by module engine
--   _G.refinish_civ_tech        - Populated by boot Pass 3
--   refinish-module-types.lua   - BUILDING_CAPABILITY_GATES,
--                                  REAGENT_TYPES dictionaries
--
-- CALLED FROM:
--   refinish-startup.lua (between reaction injection and
--   core entity injection)
--
-- PUBLIC API:
--   evaluate_and_inject() - Run the full evaluation. Returns
--                           total permission count for telemetry.
-- ==========================================

local types = reqscript('refinish-module-types')

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
-- SUBJECT is the correlation slot: the module or civ a line is about.
-- Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- Console prints only where they answer a typed command. A print only
-- appears as the direct answer to a command typed into the DFHack
-- console, and nowhere else. The one place that holds here is the
-- count at the bottom, which prints only when this file is typed as a
-- command rather than loaded as a module.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'MODULE_PERMITS'
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

-- Per-reaction and per-civ trace lines. Spam scale, so they are not
-- sent at all unless this is true; when they are, they go out as
-- DETAIL.
local VERBOSE_DEBUG = false


-- ==========================================
-- UTILITY: COUNT TABLE
-- ==========================================
local function count_table(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end


-- ==========================================
-- GATE CHECK: BUILDING CAPABILITY
-- ==========================================
-- Given a building name (from the reaction definition) and a
-- civ's entity_raw, determines whether the civ has the workshop
-- capability required to use this reaction.
--
-- Two gate types:
--   "mood"          - Iterate permitted_job by numeric df.job_type
--                     index, checking for StrangeMood entries.
--                     This is the same pattern boot Pass 3 uses.
--   "permitted_job" - Check permitted_job by named boolean key.
--                     Direct and simple.
--   "none"          - Always passes (adventure mode / no building)
--
-- permitted_job is indexed by df.profession, NOT df.job_type. It has
-- 135 slots and df.profession has exactly 135 entries; reads by name
-- and reads by df.profession index agree on every civ tested.
--
-- The "mood" gate type resolved job names through df.job_type and so
-- read unrelated profession slots: StrangeMoodForge (55) landed on
-- LYE_MAKER, StrangeMoodMason (60) on BEEKEEPER. No gate uses it any
-- more; every entry in BUILDING_CAPABILITY_GATES is now
-- "permitted_job" or "none", and the "mood" branch below is dead.
--
-- "permitted_job" looks the name up in df.profession and reads the
-- boolean at that index. That is the correct access and the only one
-- in use.
--
-- PARAMETERS:
--   building_name - String key into BUILDING_CAPABILITY_GATES
--   entity_raw    - The civ's entity_raw object
--
-- RETURNS:
--   true if the civ passes the gate, false otherwise
-- ==========================================
local function check_building_capability(building_name, entity_raw)
    local gate = types.BUILDING_CAPABILITY_GATES[building_name]
    if not gate then
        -- Unknown building type: fail closed (reject)
        return false
    end

    -- "none" gate: always passes (adventure mode / no building)
    if gate.gate_type == "none" then
        return true
    end

    local permitted = entity_raw.jobs.permitted_job

    -- "mood" gate: resolve job name through df.job_type enum to get
    -- a numeric index into the permitted_job bool array. This works
    -- because mood job types (StrangeMoodForge, StrangeMoodMason,
    -- etc.) are entries in the df.job_type enum, and the permitted_job
    -- array is indexed by those enum values.
    if gate.gate_type == "mood" then
        for _, job_name in ipairs(gate.jobs) do
            local job_enum = df.job_type[job_name]
            if job_enum and job_enum >= 0 and job_enum < #permitted then
                if permitted[job_enum] then
                    return true
                end
            end
        end
        return false
    end

    -- "permitted_job" gate: access the struct field directly by name.
    -- The permitted_job struct has named boolean fields (MASON,
    -- GLASSMAKER, STONECRAFTER, etc.) that are NOT in the df.job_type
    -- enum - they're direct struct members. We index by string key
    -- on the struct itself rather than resolving through an enum.
    if gate.gate_type == "permitted_job" then
        for _, job_name in ipairs(gate.jobs) do
            local ok, val = pcall(function() return permitted[job_name] end)
            if ok and val then
                return true
            end
        end
        return false
    end

    -- Unknown gate type: fail closed
    return false
end


-- ==========================================
-- EXTRACT REQUIRED METALS FROM REACTION DEF
-- ==========================================
-- Reads a reaction definition's reagents array and extracts
-- every metal ID that the reaction requires as input. Only
-- metal-bearing reagent types are checked:
--
--   BAR  - mat_id is the required metal (e.g. "COPPER")
--   ORE_OF     - metal_id is the required metal (e.g. "ZINC")
--
-- Other reagent types (COAL, FLUX, BOULDER, BAG, etc.) do not
-- gate on metal knowledge - they represent universally available
-- materials or non-metal inputs.
--
-- PARAMETERS:
--   reagents - Array of reagent definition tables from the
--              module's reaction JSON
--
-- RETURNS:
--   A set (table with metal ID keys, true values) of all
--   metals this reaction requires. Empty if no metal reagents.
-- ==========================================
local function extract_required_metals(reagents)
    local required = {}
    if not reagents then return required end

    for _, rgt in ipairs(reagents) do
        local rtype = types.REAGENT_TYPES[rgt.type]
        if rtype then
            -- BAR: the mat_id field names the specific metal
            if rgt.type == "BAR" and rgt.mat_id then
                required[rgt.mat_id] = true

            -- ORE_OF: the metal_id field names the target metal
            -- that the ore smelts into
            elseif rgt.type == "ORE_OF" and rgt.metal_id then
                required[rgt.metal_id] = true
            end
        end
    end

    return required
end


-- ==========================================
-- EXTRACT PRODUCT METALS FROM REACTION DEF
-- ==========================================
-- Reads a reaction definition's products array and extracts
-- every metal ID that the reaction produces. These get
-- registered as "known" for civs that receive the reaction,
-- feeding back into the knowledge graph.
--
-- Only products with a direct mat_id referencing a module
-- material are extracted. Products using GET_MATERIAL_SAME
-- or GET_MATERIAL_PRODUCT derive their material at runtime
-- and can't be statically resolved here.
--
-- PARAMETERS:
--   products - Array of product definition tables
--   prefix   - Module's ID prefix string (to identify module
--              materials vs vanilla materials)
--
-- RETURNS:
--   A set of product metal IDs (may be empty)
-- ==========================================
local function extract_product_metals(products, prefix)
    local produced = {}
    if not products then return produced end

    for _, prod in ipairs(products) do
        if prod.mat_id then
            produced[prod.mat_id] = true
        end
    end

    return produced
end


-- ==========================================
-- PUBLIC: EVALUATE AND INJECT PERMISSIONS
-- ==========================================
-- Main entry point. Walks every registered module's reactions,
-- evaluates each against every civilization (or targeted civs),
-- and injects permissions where both gates pass.
--
-- RETURNS:
--   total - Count of individual permission entries injected
--           (across all civs, all modules, all reactions).
--           Used by startup for telemetry.
-- ==========================================
function evaluate_and_inject()
    local registry = _G.refinish_module_registry
    if not registry or not next(registry) then
        log('DETAIL', 'No modules registered. Skipping.')
        return 0
    end

    local civ_tech = _G.refinish_civ_tech
    if not civ_tech then
        -- civ_tech should exist by the time we run (after boot).
        -- If it doesn't, something is wrong upstream. Fail loud.
        log('ERROR', '_G.refinish_civ_tech is nil, so no module permissions'
            .. ' were granted. Boot may not have run.')
        return 0
    end

    local reactions_array = df.global.world.raws.reactions.reactions
    local total_injected = 0
    local total_rejected = 0

    -- ==========================================
    -- BUILD LIVE REACTION INDEX LOOKUP
    -- ==========================================
    -- Map module reaction codes to their current array indexes.
    -- Reaction indexes can shift between data cycles (because
    -- core RM reactions are cleared and re-injected), so we
    -- must resolve them fresh each time.
    -- ==========================================
    local rxn_code_to_index = {}
    for i, rxn in ipairs(reactions_array) do
        rxn_code_to_index[rxn.code] = i
    end

    -- ==========================================
    -- BUILD ENTITY_RAW CODE -> CIV LOOKUP
    -- ==========================================
    -- For ENTITY_CODE permission mode, we need to find civs by
    -- their entity_raw.code. We also need the civ objects for
    -- permission injection. Build a lookup once.
    --
    -- Deduplicates by entity_raw pointer (multiple historical
    -- entities can share one entity_raw, and we only inject
    -- into each entity_raw once).
    -- ==========================================
    local player_civ = df.historical_entity.find(df.global.plotinfo.civ_id)

    -- Processing queue: player civ first (same pattern as boot
    -- and index-entity), then all other civs.
    local processing_queue = {}
    if player_civ then table.insert(processing_queue, player_civ) end
    for _, civ in ipairs(df.global.world.entities.all) do
        if not player_civ or civ.id ~= player_civ.id then
            table.insert(processing_queue, civ)
        end
    end

    -- ==========================================
    -- ENTITY CODE COLLISION CHECK
    -- ==========================================
    -- The per-reaction dedup further down keys on entity_raw.code,
    -- because the code is the only usable key: DFHack returns a fresh
    -- Lua wrapper on every access to civ.entity_raw, so the object
    -- itself cannot be used as a table key.
    --
    -- The consequence is that two DISTINCT entity raws sharing one
    -- code would collapse into a single entry, and only the first
    -- would ever be considered for permits. DF permits duplicate
    -- [ENTITY:...] ids across files, so a bad load order can produce
    -- exactly that.
    --
    -- Resolving someone else's load order is not RM's business, but
    -- swallowing the problem in silence is not acceptable either. The
    -- collision IS detectable: comparison with == works correctly on
    -- these wrappers even though hashing does not, so "same code but
    -- a different raw" is a reliable signal.
    --
    -- Reported once per colliding code, and reported here rather than
    -- inside the reaction loop, which would repeat it for every one of
    -- the module's reactions.
    -- ==========================================
    local first_raw_for_code  = {}
    local reported_collision  = {}

    for _, civ in ipairs(processing_queue) do
        if civ.type == df.historical_entity_type.Civilization and civ.entity_raw then
            local code = civ.entity_raw.code
            local seen = first_raw_for_code[code]

            if seen == nil then
                first_raw_for_code[code] = civ.entity_raw
            elseif seen ~= civ.entity_raw and not reported_collision[code] then
                reported_collision[code] = true
                log('WARNING', string.format('Entity code declared by more than'
                    .. ' one entity raw. Only the first is permitted; the'
                    .. ' others are skipped. Check your raws for a duplicate'
                    .. ' [ENTITY:%s].', code), code)
            end
        end
    end

    -- Per-civ set of already-permitted reaction indexes.
    --
    -- The injection site below used to linear-scan
    -- permitted_reaction_id on every single injection to check for a
    -- duplicate. That list starts large and grows as we inject, so the
    -- cost is quadratic: by the thousandth permit each check walks a
    -- thousand entries.
    --
    -- Built once per entity raw, on first use, then kept in step as we
    -- insert. Nothing else mutates that vector during this pass, so it
    -- cannot go stale here.
    --
    -- Keyed by raw code to match the dedup above, and shared across
    -- modules deliberately, since they inject into the same raws.
    local permitted_sets = {}

    -- ==========================================
    -- PER-MODULE EVALUATION
    -- ==========================================
    -- Uses the order the engine resolved at injection time, so this
    -- pass walks modules in exactly the sequence they were injected.
    -- Falls back to alphabetical if the engine has not published one,
    -- which only happens if this runs without the pipeline.
    --
    -- Modules the engine dropped for unmet dependencies are absent
    -- from that order, which is correct: nothing of theirs was
    -- injected, so there is nothing to permit.
    -- ==========================================
    local sorted_prefixes = _G.refinish_module_order
    if not sorted_prefixes then
        sorted_prefixes = {}
        for prefix, _ in pairs(registry) do
            table.insert(sorted_prefixes, prefix)
        end
        table.sort(sorted_prefixes)
    end

    for _, prefix in ipairs(sorted_prefixes) do
        local module = registry[prefix]
        if not module.reactions or #module.reactions == 0 then
            goto next_module
        end

        local mod_injected = 0
        local mod_rejected = 0

        for _, def in ipairs(module.reactions) do
            local full_code = prefix .. "RXN_" .. def.key
            local rxn_index = rxn_code_to_index[full_code]

            -- If the reaction wasn't found in the live array, it
            -- failed injection earlier. Skip silently.
            if not rxn_index then goto next_reaction end

            -- ---- EXTRACT GATES ----
            local building_name = def.building or "NONE"
            local required_metals = extract_required_metals(def.reagents)
            local product_metals = extract_product_metals(def.products, prefix)

            -- ---- DETERMINE PERMISSION MODE ----
            local perm_mode = "AUTO"
            local target_entities = nil
            if def.permissions then
                perm_mode = def.permissions.mode or "AUTO"
                target_entities = def.permissions.entities
            end

            -- ---- NONE MODE: NO PERMITS ----
            -- Skip evaluation entirely. No civ gets this reaction
            -- through permits. Only accessible if fortress_mode is
            -- true on the reaction (the purple-gold pattern).
            if perm_mode == "NONE" then
                if VERBOSE_DEBUG then
                    log('DETAIL', string.format('NONE mode [%s]: no permits'
                        .. ' pushed.', full_code), 'NONE_MODE')
                end
                goto next_reaction
            end

            -- ---- BUILD TARGET ENTITY SET (for ENTITY_CODE mode) ----
            local entity_code_filter = nil
            if perm_mode == "ENTITY_CODE" and target_entities then
                entity_code_filter = {}
                for _, code in ipairs(target_entities) do
                    entity_code_filter[code] = true
                end
            end

            -- ---- EVALUATE EACH CIVILIZATION ----
            -- Dedup by entity_raw CODE, not by the entity_raw object.
            --
            -- Keying on the object does not work. DFHack returns a
            -- fresh Lua wrapper on every access to civ.entity_raw, so
            -- two wrappers around the same underlying pointer compare
            -- equal under == but hash to different table slots.
            -- Measured in a live world: 237 civilizations resolved to
            -- 237 "unique" objects but only 6 unique codes.
            --
            -- The effect was that every gate below ran once per
            -- civilization rather than once per raw, roughly 39 times
            -- over, and each rejection was logged and counted once per
            -- civ sharing that raw. 130 real rejections were reported
            -- as 780. Injection itself stayed correct only because the
            -- "already permitted" check further down caught the
            -- repeats.
            --
            -- boot.lua Pass 3 already dedupes by code and reports 6
            -- unique raws, so this brings the two into agreement.
            local scanned_raws = {}

            for _, civ in ipairs(processing_queue) do
                if civ.type ~= df.historical_entity_type.Civilization then goto next_civ end
                if not civ.entity_raw then goto next_civ end

                local raw_code = civ.entity_raw.code

                if scanned_raws[raw_code] then goto next_civ end
                scanned_raws[raw_code] = true

                -- ENTITY_CODE filter: skip civs not in the target list
                if entity_code_filter and not entity_code_filter[raw_code] then
                    goto next_civ
                end

                -- ---- GATE 1: BUILDING CAPABILITY ----
                local has_capability = check_building_capability(building_name, civ.entity_raw)
                if not has_capability then
                    if entity_code_filter then
                        -- Explicit target failed: log the rejection
                        mod_rejected = mod_rejected + 1
                        log('WARNING', string.format('Rejected [%s]: lacks %s'
                            .. ' capability.', full_code, building_name),
                            raw_code)
                    end
                    goto next_civ
                end

                -- ---- GATE 2: REAGENT METAL KNOWLEDGE ----
                -- Check that the civ knows every metal this reaction
                -- requires as input. Uses the civ_tech cache built by
                -- boot Pass 3 (Sources A/B1/B2/B3).
                local tech = civ_tech[raw_code]
                local knows_all_metals = true
                local missing_metal = nil

                if next(required_metals) then
                    if not tech or not tech.known_metals then
                        knows_all_metals = false
                        missing_metal = "(no tech data)"
                    else
                        for metal_id, _ in pairs(required_metals) do
                            if not tech.known_metals[metal_id] then
                                knows_all_metals = false
                                missing_metal = metal_id
                                break
                            end
                        end
                    end
                end

                if not knows_all_metals then
                    if entity_code_filter then
                        -- Explicit target failed: log the rejection
                        mod_rejected = mod_rejected + 1
                        log('WARNING', string.format('Rejected [%s]: does not'
                            .. ' know metal [%s].', full_code,
                            tostring(missing_metal)), raw_code)
                    end
                    goto next_civ
                end

                -- ---- BOTH GATES PASSED: INJECT PERMISSION ----
                local permitted = civ.entity_raw.workshops.permitted_reaction_id

                -- Dedup: check if already permitted (shouldn't be on
                -- a clean cycle, but safety against double-fire).
                -- O(1) against the per-civ set built above.
                local pset = permitted_sets[raw_code]
                if not pset then
                    pset = {}
                    for _, pid in ipairs(permitted) do
                        pset[pid] = true
                    end
                    permitted_sets[raw_code] = pset
                end

                if not pset[rxn_index] then
                    permitted:insert('#', rxn_index)
                    pset[rxn_index] = true
                    mod_injected = mod_injected + 1

                    -- ---- REGISTER PRODUCT METALS AS KNOWN ----
                    -- Feed product metals back into civ_tech so
                    -- downstream consumers (RM core's Refinish
                    -- reactions) can see them as known metals.
                    -- Also update known_metals_cache for the player
                    -- civ - this is the flat set the UI panel reads
                    -- to determine metal availability display state.

                    local is_player = player_civ and civ.id == player_civ.id

                    if VERBOSE_DEBUG then
                        log('DETAIL', string.format('[%s] products=%d, tech=%s,'
                            .. ' is_player=%s, cache=%s', full_code,
                            count_table(product_metals), tostring(tech ~= nil),
                            tostring(is_player),
                            tostring(_G.refinish_known_metals_cache ~= nil)),
                            raw_code)
                    end

                    if tech and next(product_metals) then
                        for metal_id, _ in pairs(product_metals) do
                            tech.known_metals[metal_id] = true
                        end

                        -- Player civ: also update the UI-facing cache
                        if is_player and _G.refinish_known_metals_cache then
                            for metal_id, _ in pairs(product_metals) do
                                _G.refinish_known_metals_cache[metal_id] = true
                            end
                        end
                    end
                end

                ::next_civ::
            end

            ::next_reaction::
        end

        total_injected = total_injected + mod_injected
        total_rejected = total_rejected + mod_rejected

        log('DETAIL', string.format('%d permissions injected, %d rejected.',
            mod_injected, mod_rejected), module.name)

        ::next_module::
    end

    -- ==========================================
    -- CUSTOM BUILDING PERMISSIONS
    -- ==========================================
    -- A custom workshop that parses cleanly still never appears in
    -- the build menu unless the civ lists it in
    -- entity_raw.workshops.permitted_building_id. That is the exact
    -- counterpart of permitted_reaction_id above, and nothing was
    -- granting it, so module buildings loaded and stayed invisible.
    --
    -- Ownership is decided by prefix, the same vocabulary
    -- clear_module_assets sweeps with. A workshop whose code begins
    -- with a registered module prefix belongs to that module. No new
    -- schema: a module that ships a building simply names it with its
    -- own prefix, which it has to do anyway.
    --
    -- WHY THIS NEEDS NO CLEAR PASS
    --
    -- Reaction permissions must be cleared before a save because they
    -- hold indexes into the reactions array, and that array is torn
    -- down every data cycle. Building permissions hold building def
    -- IDS, not vector positions (measured: a placed building's
    -- custom_type resolves against def.id). Raws ids are frozen by
    -- the save's cached parse; injected ids are pinned per code by
    -- the reservation ledger in refinish-module-inject-building. A
    -- grant therefore re-resolves to the same building every session
    -- and can never dangle.
    --
    -- entity_raw is rebuilt from the raw files on load in any case,
    -- so nothing written here persists into the save.
    -- ==========================================
    local bld_injected = 0

    do
        -- Resolve each module prefix to the workshops it owns. Walking
        -- the live raws rather than trusting a stored index, because
        -- raw load order shifts when any other mod adds a workshop.
        local owned = {}
        for _, vec in ipairs({ df.global.world.raws.buildings.workshops,
                               df.global.world.raws.buildings.furnaces }) do
            for _, ws in ipairs(vec) do
                for prefix, module in pairs(registry) do
                    if string.sub(ws.code, 1, #prefix) == prefix then
                        table.insert(owned, { ws = ws, module = module })
                        break
                    end
                end
            end
        end

        if #owned > 0 then
            for code, entity_raw in pairs(first_raw_for_code) do
                local ok = pcall(function()
                    local permitted = entity_raw.workshops.permitted_building_id

                    -- Existing grants, so a re-run does not duplicate.
                    -- Rebuilt per entity rather than kept across them,
                    -- since each raw has its own list.
                    local have = {}
                    for _, bid in ipairs(permitted) do have[bid] = true end

                    for _, entry in ipairs(owned) do
                        if not have[entry.ws.id] then
                            permitted:insert('#', entry.ws.id)
                            have[entry.ws.id] = true
                            bld_injected = bld_injected + 1
                        end
                    end
                end)

                if not ok then
                    log('WARNING', 'Could not grant module buildings.', code)
                end
            end

            local names = {}
            for _, entry in ipairs(owned) do table.insert(names, entry.ws.code) end
            table.sort(names)
            log('DETAIL', string.format('%d building grant(s) across %d civ(s):'
                .. ' %s', bld_injected, count_table(first_raw_for_code),
                table.concat(names, ', ')), 'BUILDINGS')
        end
    end

    -- ==========================================
    -- CUSTOM TOOL PERMISSIONS
    -- ==========================================
    -- A module tool made by a custom reaction needs no permission: the
    -- reaction is the permission. A module tool meant to be made by DF's
    -- OWN job, listed under each metal at the forge the way a ladle is,
    -- only appears if the fort's civ lists it in
    -- historical_entity.resources.tool_type. Measured: granting the fuel
    -- tank's subtype there from the console made the forge offer it
    -- under every metal, with the metal chosen by the menu and the bar
    -- count taken from MATERIAL_SIZE.
    --
    -- No new schema, the same spirit as the building grant above. A
    -- module tool that does NOT carry no_default_job is asking for DF's
    -- native job, so it is granted; a tool that carries it is made by
    -- a reaction and is left alone. Ownership is by prefix again.
    --
    -- Granted to the fort's civ only, because that is the entity the
    -- forge reads. Other civs are not granted, so no caravan starts
    -- carrying module tools.
    --
    -- THIS ONE NEEDS A CLEAR PASS, unlike buildings. resources.tool_type
    -- is SAVED game state, and it holds a tool's subtype, which is a
    -- POSITION in itemdefs.tools, not an id: clear_tools reindexes the
    -- survivors, and tools are injected sorted by key, so adding a tool
    -- shifts every position after it. The same reason reaction
    -- permissions are cleared before a save. The withdrawal lives inside
    -- clear_tools in refinish-module-inject-tool.lua, so it happens on
    -- every path that removes a module tool, while the number still
    -- means the tool; this evaluator re-grants after every inject.
    -- ==========================================
    local tool_granted = 0

    do
        local civ = nil
        pcall(function() civ = df.historical_entity.find(df.global.plotinfo.civ_id) end)

        -- Read off the live tools array, after inject, so every subtype
        -- is the position the tool holds this session.
        local want, names = {}, {}
        for _, td in ipairs(df.global.world.raws.itemdefs.tools) do
            local id, nodef, sub = nil, true, nil
            pcall(function()
                id    = td.id
                nodef = td.flags.NO_DEFAULT_JOB
                sub   = td.subtype
            end)
            if id and sub and not nodef then
                for prefix in pairs(registry) do
                    if string.sub(id, 1, #prefix) == prefix then
                        table.insert(want, sub)
                        table.insert(names, id)
                        break
                    end
                end
            end
        end

        if civ and #want > 0 then
            local ok = pcall(function()
                local v = civ.resources.tool_type
                local have = {}
                for _, s in ipairs(v) do have[s] = true end
                for _, s in ipairs(want) do
                    if not have[s] then
                        v:insert('#', s)
                        have[s] = true
                        tool_granted = tool_granted + 1
                    end
                end
            end)

            table.sort(names)
            if ok then
                log('DETAIL', string.format('%d tool grant(s) to civ %d: %s',
                    tool_granted, civ.id, table.concat(names, ', ')), 'TOOLS')
            else
                log('WARNING', "Could not grant tools to the fort's civ.",
                    'TOOLS')
            end
        end
    end

    log('DETAIL', string.format('Evaluation complete. %d total permissions'
        .. ' injected, %d rejected.', total_injected, total_rejected),
        'EVALUATION')

    return total_injected
end


-- ==========================================
-- CONSOLE DIAGNOSTIC
-- ==========================================
-- Run this script directly (not as module) to see a dry-run
-- of what the evaluator would do with current state.
-- ==========================================
if dfhack_flags and dfhack_flags.module then
    return _ENV
end

-- Direct execution: run and report. This print stays: it only runs
-- when this file is typed as a command, so it is the direct answer.
local count = evaluate_and_inject()
print(string.format("Module Permission Evaluator: %d permissions injected.", count))
return _ENV