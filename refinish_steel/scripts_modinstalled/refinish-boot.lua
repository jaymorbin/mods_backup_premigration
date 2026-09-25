--@ module = true
-- refinish-boot.lua
-- ==========================================
-- REFINISH STEEL: UNIFIED BOOT SCANNER
-- ==========================================
-- Purpose: Safely parse C++ arrays to build the global caches that
-- every downstream script consumes. This is the FIRST script to run
-- after the evaluators, and its output lives in _G for the rest of
-- the session.
--
-- OPTIMIZATION NOTES (v3.2.1):
-- The original implementation used 6+ separate walks over the C++
-- arrays (reactions, inorganics, reactions again for B3, inorganics
-- again per-civ for Source A, etc). This revision consolidates down
-- to 3 passes:
--
--   Pass 1; REACTIONS: Single walk of global_rxns.
--            Builds reaction_traits, valid_metals_map, and a
--            fortress_traits subset (pre-filtered for B3 consumers).
--
--   Pass 2; INORGANICS: Single walk of inorganics.
--            Folds in the ore/thread_metal fix (valid_metals_map),
--            builds valid_metals (the UI cache), builds
--            known_metals_cache from ore paths, AND pre-caches
--            ore_metals (the universal physics set) so Pass 3
--            never needs to re-walk inorganics.
--
--   Pass 3; PERMISSIONS + CIVS: Single walk of civilizations.
--            Player civ permissions consume reaction_traits directly.
--            Civ tech evaluation uses ore_metals (Source A),
--            reaction_traits.extracted_ids (Sources B1/B2), and
--            fortress_traits (Source B3); all pre-cached, zero
--            re-extraction.
-- ==========================================


-- ==========================================
-- SHARED UTILITY: METAL ID EXTRACTOR
-- ==========================================
-- Given a reaction, extracts the IDs of all inorganic metals it
-- touches; through products, reagents, ore references, raw strings,
-- and naming conventions. Returns a set (table with ID keys, true values).
--
-- This is the SINGLE authoritative copy of this logic. It lives here
-- because boot runs first and every downstream script that needs it
-- can call it via:
--   local boot = dfhack.script_environment('refinish-boot')
--   local ids = boot.extract_metal_ids_safely(rxn, inorganics, inorg_count)
--
-- PARAMETERS:
--   rxn          - a df.reaction object to evaluate
--   inorganics   - df.global.world.raws.inorganics.all (passed in so the
--                   caller controls which snapshot of the array is used)
--   inorg_count  - #inorganics (passed in to avoid recounting per call)
--
-- RETURNS:
--   A table where keys are inorganic IDs (strings) and values are true.
--   Empty table if the reaction doesn't touch any identifiable metals.
-- ==========================================
function extract_metal_ids_safely(rxn, inorganics, inorg_count)
    local found = {}

    -- CHECK PRODUCTS: Any product that outputs an inorganic bar tells
    -- us which metal this reaction creates.
    if rxn.products then
        for _, prod in ipairs(rxn.products) do
            if df.reaction_product_itemst:is_instance(prod) then
                -- item_type 0 = BAR, mat_type 0 = INORGANIC
                if prod.item_type == 0 and prod.mat_type == 0 and prod.mat_index >= 0 and prod.mat_index < inorg_count then
                    local inorg = inorganics[prod.mat_index]
                    if inorg then found[inorg.id] = true end
                end
            end
        end
    end

    -- CHECK REAGENTS: Ore boulders (item_type 4) reference their target
    -- metal via metal_ore. Inorganic bar reagents (item_type 0, mat_type 0)
    -- tell us which metals are consumed.
    if rxn.reagents then
        for _, reag in ipairs(rxn.reagents) do
            if df.reaction_reagent_itemst:is_instance(reag) then
                if reag.item_type == 4 and reag.metal_ore >= 0 and reag.metal_ore < inorg_count then
                    local inorg = inorganics[reag.metal_ore]
                    if inorg then found[inorg.id] = true end
                elseif reag.item_type == 0 and reag.mat_type == 0 and reag.mat_index >= 0 and reag.mat_index < inorg_count then
                    local inorg = inorganics[reag.mat_index]
                    if inorg then found[inorg.id] = true end
                end
            end
        end
    end

    -- CHECK RAW STRINGS: Fallback for reactions where the struct fields
    -- don't capture the metal ID (some modded reactions). Parses the
    -- human-readable raw string tokens for PRODUCT lines referencing
    -- INORGANIC or METAL bar outputs.
    if rxn.raw_strings then
        for _, raw_str_obj in ipairs(rxn.raw_strings) do
            local str = raw_str_obj.value
            if str then
                local mat_id = string.match(str, "%[PRODUCT:.-:BAR:.-:INORGANIC:([^%]]+)%]")
                if not mat_id then mat_id = string.match(str, "%[PRODUCT:.-:BAR:.-:METAL:([^%]]+)%]") end
                if mat_id then found[mat_id] = true end
            end
        end
    end

    -- CHECK NAMING CONVENTIONS: Many vanilla reactions follow the pattern
    -- METAL_MAKING (e.g. STEEL_MAKING, BRONZE_MAKING). Extract the metal
    -- name from the reaction code. Special case for IRON_BLOOM_PROCESS
    -- which doesn't follow the pattern but produces iron.
    local code_match = string.match(rxn.code, "^([A-Z0-9_]+)_MAKING")
    if code_match then found[code_match] = true end
    if rxn.code == "IRON_BLOOM_PROCESS" then found["IRON"] = true end

    return found
end


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
-- SUBJECT is the correlation slot: the pass a line belongs to. Every
-- line here is DETAIL: the startup that runs this scan reports the
-- outcome.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- Console prints only where they answer a typed command. A print only
-- appears as the direct answer to a command typed into the DFHack
-- console, and nowhere else. The one place that holds here is the
-- diagnostic readout at the end of run_unified_scan, which prints
-- only when this file is run by hand as a command.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'BOOT_SCAN'
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
-- SHARED UTILITY: RM PREFIX CHECK
-- ==========================================
-- Faster than string.find(id, "REFINISH_STEEL_") for hot loops.
-- string.sub extracts a fixed-length prefix and compares it as a
-- plain string; no pattern engine overhead. We use this inside
-- the tight Pass 1 and Pass 2 loops where every reaction/inorganic
-- gets checked.
-- ==========================================
local RM_PREFIX = "REFINISH_STEEL_"
local RM_PREFIX_LEN = #RM_PREFIX

local function is_rm_asset(id)
    return string.sub(id, 1, RM_PREFIX_LEN) == RM_PREFIX
end


-- ==========================================
-- UNIFIED BOOT SCAN
-- ==========================================
function run_unified_scan(allow_divine, allow_mythical)
    allow_divine = allow_divine or false
    allow_mythical = allow_mythical or false

    local inorganics = df.global.world.raws.inorganics.all
    local inorg_count = #inorganics
    local global_rxns = df.global.world.raws.reactions.reactions

    -- These are the four output caches that get written to _G at the end.
    local valid_metals = {}       -- Array: one entry per physically valid metal, sorted by name
    local valid_metals_map = {}   -- Set: every metal ID that has a known crafting/smelting path
    local known_metals_cache = {} -- Set: metals the player civ can actually access
    local reaction_traits = {}    -- Dict keyed by reaction index: extracted_ids + building/fortress metadata


    -- ==========================================
    -- PASS 1: REACTIONS (Single walk of global_rxns)
    -- ==========================================
    -- For each non-RM reaction, extract which metals it touches and
    -- score its building/fortress permissions. Two outputs:
    --
    --   reaction_traits[pid] - full trait record (used by Pass 3 for
    --                          player civ permissions and civ tech B1/B2)
    --
    --   fortress_traits[pid] - subset: only FORTRESS_MODE_ENABLED reactions,
    --                          pre-filtered and pre-scored for building access.
    --                          This replaces the old standalone B3 block and
    --                          the per-civ B3 re-walk. Pass 3 consumes it
    --                          directly with zero re-extraction.
    -- ==========================================
    local fortress_traits = {}  -- Pre-filtered subset for Source B3 consumers

    log('DETAIL', 'Evaluating reaction traits (' .. #global_rxns
        .. ' reactions, ' .. inorg_count .. ' inorganics).', 'PASS_1')

    for pid, rxn in ipairs(global_rxns) do
        if not is_rm_asset(rxn.code) then
            local extracted_ids = extract_metal_ids_safely(rxn, inorganics, inorg_count)

            -- Only save traits if the reaction actually touches a valid metal
            if next(extracted_ids) then
                for id, _ in pairs(extracted_ids) do
                    valid_metals_map[id] = true
                end

                -- Score building requirements once, reuse everywhere
                local building_ok = true
                local has_custom_bld_req = false
                local bld_custom_ids = {}

                if rxn.building and rxn.building.type then
                    building_ok = false
                    for i, b_type in ipairs(rxn.building.type) do
                        local b_custom = rxn.building.custom[i]
                        if b_custom == -1 then
                            building_ok = true
                        elseif b_custom then
                            has_custom_bld_req = true
                            table.insert(bld_custom_ids, b_custom)
                        end
                    end
                end

                local trait = {
                    extracted_ids = extracted_ids,
                    fortress_enabled = rxn.flags.FORTRESS_MODE_ENABLED,
                    building_ok = building_ok,
                    has_custom_bld_req = has_custom_bld_req,
                    bld_custom_ids = bld_custom_ids
                }
                reaction_traits[pid] = trait

                -- Pre-filter fortress-mode reactions for B3 consumers.
                -- We also pre-score whether the reaction's building
                -- requirements can be met with just a standard workshop
                -- (b_custom == -1 or no building requirement at all).
                -- The per-civ building lookup gets applied in Pass 3.
                if rxn.flags.FORTRESS_MODE_ENABLED then
                    fortress_traits[pid] = trait
                end
            end
        end
    end

    local rxn_trait_count = 0
    for _ in pairs(reaction_traits) do rxn_trait_count = rxn_trait_count + 1 end


    -- ==========================================
    -- PASS 2: INORGANICS (Single walk)
    -- ==========================================
    -- This pass does THREE things in one loop over inorganics:
    --
    --   1. ORE FIX (formerly "Platinum/Aluminum/Adamantine Fix"):
    --      Expands valid_metals_map with metals reachable via
    --      metal_ore and thread_metal; metals that exist as
    --      smelting targets but don't have their own _MAKING
    --      reaction.
    --
    --   2. VALID METALS CACHE: For each inorganic that passes the
    --      IS_METAL + divine/mythical/stability/usability filter,
    --      build the full UI cache entry (physics, flags, color).
    --
    --   3. ORE_METALS + KNOWN_METALS_CACHE: Pre-cache the set of
    --      metals reachable through ore smelting (universal physics).
    --      ore_metals becomes Source A for every forge-capable civ
    --      in Pass 3; eliminating the per-civ inorganics re-walk.
    --      known_metals_cache also gets seeded here.
    --
    -- IMPORTANT ORDERING: The ore fix (step 1) must populate
    -- valid_metals_map BEFORE the valid metals filter (step 2)
    -- checks has_crafting_path. We handle this by doing the ore
    -- fix in a FIRST sub-pass over the array, then the full
    -- evaluation in a SECOND sub-pass. This is still one logical
    -- "Pass 2" - two sub-passes over the same array is cheaper
    -- than the old design which had a full standalone ore fix pass
    -- PLUS a full evaluation pass as completely separate stages.
    -- ==========================================
    log('DETAIL', 'Evaluating inorganics (' .. inorg_count .. ' entries).',
        'PASS_2')

    -- ore_metals: the set of metal IDs reachable by smelting any ore.
    -- This is "Source A: Universal Physics" - any civ with forge mood
    -- can produce these metals. Cached here so Pass 3 doesn't need to
    -- re-walk inorganics for each civ.
    local ore_metals = {}

    -- SUB-PASS 2a: ORE FIX + ORE_METALS
    -- Walk every inorganic to find metal_ore and thread_metal targets.
    -- This expands valid_metals_map (so step 2b can check has_crafting_path)
    -- and simultaneously builds ore_metals (so Pass 3 Source A is free).
    for _, mat in ipairs(inorganics) do
        if mat.metal_ore and mat.metal_ore.mat_index then
            for _, m_idx in ipairs(mat.metal_ore.mat_index) do
                if m_idx >= 0 and m_idx < inorg_count then
                    local target_mat = inorganics[m_idx]
                    if target_mat then
                        valid_metals_map[target_mat.id] = true
                        ore_metals[target_mat.id] = true
                    end
                end
            end
        end
        -- THREAD_METAL FIX: thread_metal targets (e.g. adamantine from
        -- RAW_ADAMANTINE) are NOT universally smeltable like metal_ore
        -- targets. They require a specific reaction (ADAMANTINE_WAFERS),
        -- which is permission-gated per civ. So we mark them as having
        -- a valid crafting path (valid_metals_map) but do NOT add them
        -- to ore_metals. This ensures they only reach civs that actually
        -- have the reaction permission (Sources B1/B2/B3 in Pass 3),
        -- rather than being blindly granted to every forge-capable civ
        -- via Source A.
        if mat.thread_metal and mat.thread_metal.mat_index then
            for _, m_idx in ipairs(mat.thread_metal.mat_index) do
                if m_idx >= 0 and m_idx < inorg_count then
                    local target_mat = inorganics[m_idx]
                    if target_mat then
                        valid_metals_map[target_mat.id] = true
                    end
                end
            end
        end
    end

    -- SUB-PASS 2b: VALID METALS + KNOWN_METALS_CACHE SEEDING
    -- Now that valid_metals_map is fully populated (reactions + ores),
    -- we can safely check has_crafting_path for each metal.
    for i, mat in ipairs(inorganics) do
        local id = mat.id
        if not is_rm_asset(id) and mat.flags and mat.material and mat.material.flags and mat.material.heat then
            local m_flags = mat.material.flags
            local o_flags = mat.flags
            local heat = mat.material.heat

            local is_metal = m_flags.IS_METAL

            local is_permitted_divine = true
            if o_flags.DIVINE and not allow_divine then
                is_permitted_divine = false
            end

            local is_permitted_mythical = true
            local is_mythical_flagged = (o_flags.MYTHICAL or o_flags.MYTHICAL_REMNANT or o_flags.MYTHICAL_SUBSTANCE)
            if is_mythical_flagged and not allow_mythical then
                is_permitted_mythical = false
            end

            local melt_point = heat.melting_point
            local is_stable = (melt_point == 0 or melt_point > 10015)
            local is_valuable = (mat.material.material_value >= 0)

            -- Full usability check: can this metal be used to make items?
            local is_usable = (
                m_flags.ITEMS_METAL or
                m_flags.ITEMS_HARD or
                m_flags.ITEMS_WEAPON or
                m_flags.ITEMS_WEAPON_RANGED or
                m_flags.ITEMS_AMMO or
                m_flags.ITEMS_DIGGER or
                m_flags.ITEMS_ARMOR or
                m_flags.ITEMS_ANVIL or
                m_flags.ITEMS_BARRED or
                m_flags.ITEMS_SCALED or
                m_flags.ITEMS_SIEGE_ENGINE
            )

            if is_metal and is_permitted_divine and is_permitted_mythical and is_stable and is_valuable and is_usable then
                local name = id
                if mat.material.state_name and mat.material.state_name.Solid and mat.material.state_name.Solid ~= "" then
                    name = mat.material.state_name.Solid
                end

                -- Apply Title Case to every word, not just the very first letter
                name = name:gsub("(%a)([%w_']*)", function(first, rest)
                    return first:upper() .. rest:lower()
                end)

                local has_crafting_path = valid_metals_map[id] or false

                -- CACHE FLAG STRING
                local flag_list = {}
                for k, v in pairs(o_flags) do if v then table.insert(flag_list, k) end end
                for k, v in pairs(m_flags) do if v then table.insert(flag_list, k) end end
                table.sort(flag_list)

                -- PRE-WRAP FLAG LINES INTO A TABLE (Prevents CP437 ASCII 10 'googly eyes')
                local flags_lines = {}
                if #flag_list > 0 then
                    local raw_flags = table.concat(flag_list, ", ")
                    local line = ""
                    for word in raw_flags:gmatch("[^%s]+") do
                        if #line + #word > 50 then
                            table.insert(flags_lines, line)
                            line = word .. " "
                        else
                            line = line .. word .. " "
                        end
                    end
                    table.insert(flags_lines, line)
                else
                    table.insert(flags_lines, "NONE")
                end

                -- CACHE PROPER COLOR NAME
                -- state_color[0] holds the PATTERN index, not the COLOR index.
                local pattern_idx = mat.material.state_color[0]
                local color_name = "Unknown"

                if pattern_idx and pattern_idx >= 0 then
                    local pattern = df.global.world.raws.descriptors.patterns[pattern_idx]

                    -- Extract the actual color index from the pattern's sub-vector
                    if pattern and pattern.colors and #pattern.colors > 0 then
                        local true_c_idx = pattern.colors[0]

                        -- Now we can safely query the 215-length colors vector
                        if true_c_idx and true_c_idx >= 0 and true_c_idx < #df.global.world.raws.descriptors.colors then
                            local color_obj = df.global.world.raws.descriptors.colors[true_c_idx]
                            if color_obj and color_obj.name and color_obj.name ~= "" then
                                color_name = color_obj.name
                            end
                        end
                    end
                end

                color_name = color_name:gsub("(%a)([%w_']*)", function(first, rest)
                    return first:upper() .. rest:lower()
                end)

                -- PRE-CACHE ALL PHYSICS DATA FOR UI
                -- Stringifying here completely decouples the UI from live C++ reads
                local h = mat.material.heat
                local y = mat.material.strength.yield
                local f = mat.material.strength.fracture
                local s = mat.material.strength.strain_at_yield

                table.insert(valid_metals, {
                    id = id, index = i, name = name, value = tostring(mat.material.material_value),
                    is_divine = o_flags.DIVINE, is_mythical = is_mythical_flagged,
                    has_reaction = has_crafting_path, flags_lines = flags_lines,
                    color_name = color_name,
                    -- Core Stats
                    solid_dens = tostring(mat.material.solid_density),
                    liq_dens = tostring(mat.material.liquid_density),
                    molar_mass = tostring(mat.material.molar_mass),
                    max_edge = tostring(mat.material.strength.max_edge),
                    -- Heat
                    heat = {
                        spec = tostring(h.spec_heat), ignite = tostring(h.ignite_point),
                        melt = tostring(h.melting_point), boil = tostring(h.boiling_point),
                        h_dam = tostring(h.heatdam_point), c_dam = tostring(h.colddam_point),
                        fixed = tostring(h.mat_fixed_temp)
                    },
                    -- Yield
                    yield = {
                        imp = tostring(y.IMPACT), comp = tostring(y.COMPRESSIVE),
                        tens = tostring(y.TENSILE), tors = tostring(y.TORSION),
                        shear = tostring(y.SHEAR), bend = tostring(y.BENDING)
                    },
                    -- Fracture
                    fracture = {
                        imp = tostring(f.IMPACT), comp = tostring(f.COMPRESSIVE),
                        tens = tostring(f.TENSILE), tors = tostring(f.TORSION),
                        shear = tostring(f.SHEAR), bend = tostring(f.BENDING)
                    },
                    -- Strain
                    strain = {
                        imp = tostring(s.IMPACT), comp = tostring(s.COMPRESSIVE),
                        tens = tostring(s.TENSILE), tors = tostring(s.TORSION),
                        shear = tostring(s.SHEAR), bend = tostring(s.BENDING)
                    }
                })
            end

            -- Seed known_metals_cache from ore relationships.
            -- This was formerly the "Universal Physics (METAL_ORE)" block
            -- at the bottom of old Pass 2. We only mark a metal as "known"
            -- if it's reachable via ore AND already in valid_metals_map
            -- (i.e., it has a crafting path).
            if mat.metal_ore and mat.metal_ore.mat_index then
                for _, target_idx in ipairs(mat.metal_ore.mat_index) do
                    local target_mat = inorganics[target_idx]
                    if target_mat and valid_metals_map[target_mat.id] then
                        known_metals_cache[target_mat.id] = true
                    end
                end
            end
        end
    end
    table.sort(valid_metals, function(a, b) return a.name < b.name end)

    local valid_map_count = 0
    for _ in pairs(valid_metals_map) do valid_map_count = valid_map_count + 1 end
    log('DETAIL', string.format('Passes 1 and 2 complete; %d reaction'
        .. ' traits, %d valid metals, %d in valid_metals_map.',
        rxn_trait_count, #valid_metals, valid_map_count), 'PASS_1_2')


    -- ==========================================
    -- PASS 3: PERMISSIONS + CIVILIZATION TECH
    -- ==========================================
    -- This pass does TWO things that the old code did separately:
    --
    --   A. PLAYER CIV PERMISSIONS (old Pass 3 + standalone B3):
    --      Walk reaction_traits to determine which metals the player
    --      civ can access. The old standalone "RESTORED 2AM LOGIC"
    --      B3 block is eliminated; its work is folded into the
    --      fortress_traits consumption below.
    --
    --   B. CIVILIZATION TECH EVALUATION (old Pass 4):
    --      Walk every civ and determine what metals each one knows.
    --      Source A uses ore_metals (pre-cached in Pass 2).
    --      Sources B1/B2 use reaction_traits.extracted_ids (pre-cached
    --      in Pass 1). Source B3 uses fortress_traits (pre-cached in
    --      Pass 1). Zero calls to extract_metal_ids_safely here.
    -- ==========================================
    log('DETAIL', 'Evaluating player civ permissions and civilization tech.',
        'PASS_3')

    -- -------------------------------------------------------
    -- STEP 3A: PLAYER CIV PERMISSIONS
    -- -------------------------------------------------------
    -- Populates known_metals_cache with every metal the player
    -- civ can reach through reactions (explicit, fortress-mode,
    -- or building-permitted).
    -- -------------------------------------------------------
    local player_civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    local player_civ_id = player_civ and player_civ.id or -1

    if player_civ and player_civ.entity_raw then
        -- Build permission lookups for the player civ (used here AND
        -- reused below in Step 3B when processing the player civ entry)
        local player_rxn_lookup = {}
        for _, pid in ipairs(player_civ.entity_raw.workshops.permitted_reaction_id) do
            player_rxn_lookup[pid] = true
        end

        local player_bld_lookup = {}
        if player_civ.entity_raw.workshops.permitted_building_id then
            for _, bid in ipairs(player_civ.entity_raw.workshops.permitted_building_id) do
                player_bld_lookup[bid] = true
            end
        end

        -- Walk reaction_traits (NOT the raw C++ array) to check permissions
        for pid, trait in pairs(reaction_traits) do
            local is_permitted = false

            -- Rule 1: Explicitly permitted by player civ
            if player_rxn_lookup[pid] then
                is_permitted = true
            else
                -- Rule 2: Check building requirements
                local bld_passed = trait.building_ok
                if trait.has_custom_bld_req then
                    for _, req_id in ipairs(trait.bld_custom_ids) do
                        if player_bld_lookup[req_id] then bld_passed = true; break end
                    end
                end

                if trait.fortress_enabled and bld_passed then
                    is_permitted = true
                elseif trait.has_custom_bld_req and bld_passed then
                    is_permitted = true
                end
            end

            -- If the civ has the reaction, they know ALL the metals it touches
            if is_permitted then
                for id, _ in pairs(trait.extracted_ids) do
                    known_metals_cache[id] = true
                end
            end
        end

        -- FORTRESS MODE BYPASS (replaces old standalone B3 block)
        -- Walk fortress_traits (pre-filtered in Pass 1) instead of
        -- re-walking the entire global_rxns array. We check building
        -- permissions against the player civ's buildings.
        for pid, trait in pairs(fortress_traits) do
            local allowed_by_building = trait.building_ok
            if not allowed_by_building and trait.has_custom_bld_req then
                for _, req_id in ipairs(trait.bld_custom_ids) do
                    if player_bld_lookup[req_id] then allowed_by_building = true; break end
                end
            end

            if allowed_by_building then
                for id, _ in pairs(trait.extracted_ids) do
                    known_metals_cache[id] = true
                end
            end
        end
    end

    -- -------------------------------------------------------
    -- STEP 3B: CIVILIZATION TECH EVALUATION
    -- -------------------------------------------------------
    -- Walks every civilization in the world and determines what
    -- metals each one knows how to work with. Derived entirely
    -- from static raws data: entity_raw jobs, permitted reactions,
    -- permitted buildings, and the ore_metals set from Pass 2.
    --
    -- For each unique entity_raw (deduplicated by code), we check:
    --   - Mood capabilities (forge, mason, gem)
    --   - Source A: Universal physics (ore_metals, pre-cached)
    --   - Source B1: Explicitly permitted reactions (via reaction_traits)
    --   - Source B2: Implicitly permitted via custom buildings (via reaction_traits)
    --   - Source B3: Global fortress-mode reactions (player civ only, via fortress_traits)
    --
    -- Output: civ_tech; a dict keyed by entity_raw.code, each entry
    -- containing mood flags, known_metals set, tech booleans, and
    -- race adjective. Scan copies this into the blueprint later.
    -- -------------------------------------------------------
    local civ_tech = {}
    local evaluated_rxns = _G.refinish_evaluated_reactions
    local scanned_raws = {}

    -- Build the processing queue with player civ first
    -- (sets cache for shared entity_raw)
    local processing_queue = {}
    if player_civ then table.insert(processing_queue, player_civ) end

    for _, civ in ipairs(df.global.world.entities.all) do
        if not player_civ or civ.id ~= player_civ.id then
            table.insert(processing_queue, civ)
        end
    end

    for _, civ in ipairs(processing_queue) do
        if civ.type == df.historical_entity_type.Civilization and civ.entity_raw then
            local raw_code = civ.entity_raw.code

            -- Only process each entity_raw once (multiple civs can share one)
            if not scanned_raws[raw_code] then
                scanned_raws[raw_code] = true

                -- ---- CIV CAPABILITY CHECK ----
                --
                -- entity_raw.jobs.permitted_job is indexed by
                -- df.profession, NOT df.job_type. Verified: the live
                -- array is 135 slots and df.profession has exactly 135
                -- entries, and reads by name agree with reads by
                -- df.profession index on every civ tested.
                --
                -- This previously indexed it with df.job_type values,
                -- which landed on unrelated professions:
                --
                --   StrangeMoodForge      = 55 -> LYE_MAKER
                --   StrangeMoodMagmaForge = 56 -> WOOD_BURNER
                --   StrangeMoodMason      = 60 -> BEEKEEPER
                --   StrangeMoodJeweller   = 54 -> POTASH_MAKER
                --
                -- So metal capability was decided by whether a civ made
                -- lye or burned wood, and stoneworking by beekeeping.
                -- It looked plausible because civs with broad profession
                -- lists tend to have those slots set too.
                --
                -- The four capabilities this evaluation needs:
                --
                --   has_smelter  FURNACE_OPERATOR. The smelter is the
                --                only building that produces metal bars,
                --                whether from ore or by alloying. No
                --                smelter means no bars by any route, so
                --                this gates the entire known_metals
                --                build below, alloy permissions and all.
                --
                --   has_forge    The smith professions. Governs grinding
                --                existing bars to dust. It has nothing
                --                to do with producing bars, which is why
                --                it no longer opens the gate.
                --
                --   has_mason    MASON. Grinding stone to dust.
                --
                --   has_gem      The gem professions. Grinding gems.
                local permitted = civ.entity_raw.jobs.permitted_job

                -- Read one profession slot by name. Returns a real
                -- boolean rather than nil so callers can use it
                -- directly, and pcall-guarded so an unknown name can
                -- never throw mid-scan.
                local function has_prof(name)
                    local idx = df.profession and df.profession[name]
                    if type(idx) ~= "number" then return false end
                    local ok, v = pcall(function() return permitted[idx] end)
                    return (ok and v) and true or false
                end

                -- True if the civ has any one of these professions.
                local function has_any(names)
                    for _, nm in ipairs(names) do
                        if has_prof(nm) then return true end
                    end
                    return false
                end

                local has_smelter = has_prof("FURNACE_OPERATOR")
                local has_forge   = has_any({ "METALSMITH", "WEAPONSMITH",
                                              "ARMORER", "BLACKSMITH",
                                              "METALCRAFTER" })
                local has_mason   = has_prof("MASON")
                local has_gem     = has_any({ "JEWELER", "GEM_CUTTER",
                                              "GEM_SETTER" })

                local known_metals = {}
                local metal_tech = false

                -- Gated on the smelter, and deliberately wrapping every
                -- source below. Sources B1/B2/B3 grant alloy and
                -- refinishing access from explicit permissions, but a
                -- civ with no smelter cannot act on any of them.
                if has_smelter then
                    -- Source A: Universal Physics (METAL_ORE)
                    -- Instead of re-walking the entire inorganics array,
                    -- we copy from the ore_metals set built in Pass 2.
                    -- Any civ with forge capability can smelt these.
                    for id, _ in pairs(ore_metals) do
                        known_metals[id] = true
                    end

                    -- Build permission lookups for this civ
                    local permitted_rxn_lookup = {}
                    local permitted_rxns = civ.entity_raw.workshops.permitted_reaction_id
                    for _, pid in ipairs(permitted_rxns) do permitted_rxn_lookup[pid] = true end

                    local permitted_bld_lookup = {}
                    if civ.entity_raw.workshops.permitted_building_id then
                        for _, bid in ipairs(civ.entity_raw.workshops.permitted_building_id) do
                            permitted_bld_lookup[bid] = true
                        end
                    end

                    -- Source B1: Explicitly Permitted Reactions
                    -- Uses reaction_traits.extracted_ids instead of calling
                    -- extract_metal_ids_safely again. The trait already has
                    -- the full set of metal IDs this reaction touches.
                    for _, pid in ipairs(permitted_rxns) do
                        local trait = reaction_traits[pid]
                        if trait then
                            for id, _ in pairs(trait.extracted_ids) do
                                known_metals[id] = true
                            end
                        end
                    end

                    -- Source B2: Implicitly Permitted Reactions (Via Custom Buildings)
                    -- Same optimization: consume reaction_traits instead of re-extracting.
                    if evaluated_rxns then
                        for pid, _ in pairs(evaluated_rxns) do
                            if not permitted_rxn_lookup[pid] then
                                local trait = reaction_traits[pid]
                                if trait and trait.has_custom_bld_req then
                                    local allowed_by_building = false
                                    for _, req_id in ipairs(trait.bld_custom_ids) do
                                        if permitted_bld_lookup[req_id] then allowed_by_building = true; break end
                                    end
                                    if allowed_by_building then
                                        for id, _ in pairs(trait.extracted_ids) do
                                            known_metals[id] = true
                                        end
                                    end
                                end
                            end
                        end
                    end

                    -- Source B3: Global Fortress Mode Reactions (player civ only)
                    -- Uses fortress_traits (pre-filtered in Pass 1) instead of
                    -- re-walking the entire global_rxns array.
                    if civ.id == player_civ_id then
                        for pid, trait in pairs(fortress_traits) do
                            local allowed_by_building = trait.building_ok
                            if not allowed_by_building and trait.has_custom_bld_req then
                                for _, req_id in ipairs(trait.bld_custom_ids) do
                                    if permitted_bld_lookup[req_id] then allowed_by_building = true; break end
                                end
                            end
                            if allowed_by_building then
                                for id, _ in pairs(trait.extracted_ids) do
                                    known_metals[id] = true
                                end
                            end
                        end
                    end

                    if next(known_metals) then metal_tech = true end
                end

                -- Extract creature adjective for UI display
                local race_adj = "Unknown"
                if civ.race and civ.race >= 0 and civ.race < #df.global.world.raws.creatures.all then
                    local c_raw = df.global.world.raws.creatures.all[civ.race]
                    if c_raw and c_raw.name and c_raw.name[2] then
                        race_adj = c_raw.name[2]:gsub("^%l", string.upper)
                    end
                end

                -- Store by entity_raw code (deduplicates shared raws)
                civ_tech[raw_code] = {
                    has_smelter  = has_smelter,
                    has_forge    = has_forge,
                    has_mason    = has_mason,
                    has_gem      = has_gem,
                    known_metals = known_metals,
                    stone_tech   = has_mason,
                    gem_tech     = has_gem,
                    metal_tech   = metal_tech,
                    race_adj     = race_adj,
                }
            end
        end
    end

    local civ_count = 0
    for _ in pairs(civ_tech) do civ_count = civ_count + 1 end
    log('DETAIL', string.format('Pass 3 complete; %d unique civilization'
        .. ' raws evaluated.', civ_count), 'PASS_3')


    -- ==========================================
    -- CACHE ALL RESULTS TO _G
    -- ==========================================
    _G.refinish_valid_bases = valid_metals
    _G.refinish_known_metals_cache = known_metals_cache
    _G.refinish_reaction_traits = reaction_traits
    _G.refinish_civ_tech = civ_tech

    local final_known_count = 0
    for _ in pairs(known_metals_cache) do final_known_count = final_known_count + 1 end
    log('DETAIL', string.format('Unified scan complete; %d valid bases, %d'
        .. ' known metals, %d reaction traits, %d civ techs cached.',
        #valid_metals, final_known_count, rxn_trait_count, civ_count),
        'UNIFIED_SCAN')

    -- Diagnostic readout for console verification. These prints stay:
    -- they only run when this file is typed as a command, so they are
    -- the direct answer to it.
    if dfhack_flags and dfhack_flags.module == false then
        print(string.format("Refinish Boot Diagnostic:"))
        print(string.format(" -> Found %d physically valid metals.", #valid_metals))

        local rxn_count = 0
        for _ in pairs(reaction_traits) do rxn_count = rxn_count + 1 end
        print(string.format(" -> Found %d metal-making reaction traits.", rxn_count))

        local known_count = 0
        for _ in pairs(known_metals_cache) do known_count = known_count + 1 end
        print(string.format(" -> Found %d natively known metals.", known_count))
    end
end

-- Allow manual console execution to print diagnostics
if dfhack_flags and dfhack_flags.module then
    return _ENV
else
    run_unified_scan()
end