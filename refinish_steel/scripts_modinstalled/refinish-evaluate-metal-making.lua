--@ module = true
-- refinish-evaluate-metal-making.lua
-- ==========================================
-- REFINISH STEEL: METAL-MAKING REACTION EVALUATOR
-- ==========================================
-- Scores all loaded reactions to identify metal-making candidates.
-- Each reaction is evaluated on structural criteria: does it produce
-- inorganic bars, use a smelter, require fuel, etc. Higher scores
-- indicate better template candidates for cloning.
--
-- This is a boot-time utility. Results are cached after first call
-- and consumed by downstream scripts (boot, scan, index-reaction)
-- via dfhack.script_environment('refinish-evaluate-metal-making').
-- ==========================================

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
-- SUBJECT is the correlation slot: the step or thing a line is
-- about. Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'EVAL_METAL'
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

local cached_evaluations = nil

local VERBOSE_DEBUG = false -- Set to false later to quiet the console

local debug_file = nil
local function dprint(msg)
    if debug_file then 
        debug_file:write(msg .. "\n") 
    end
end

local function evaluate_reaction(reaction)
    if VERBOSE_DEBUG then dprint(string.format("\n[DEBUG] Evaluating: %s", reaction.code)) end
    
    local score = 0
    local target_mat_index = -1

    -- PHASE 1: THE RELAXED GUILLOTINE
    if not reaction.products or #reaction.products == 0 then 
        if VERBOSE_DEBUG then dprint("  -> Failed: No products") end
        return 0, nil 
    end

    if reaction.skill == 24 then 
        score = score + 10 
        if VERBOSE_DEBUG then dprint("  -> Score +10: Uses SMELT skill") end
    end

    if reaction.building and reaction.building.type then
        for _, b_type in ipairs(reaction.building.type) do
            if b_type == 5 or b_type == 4 then 
                score = score + 10 
                if VERBOSE_DEBUG then dprint("  -> Score +10: Uses valid Furnace (type 4 or 5)") end
                break 
            end
        end
    end

    -- PHASE 2: THE SCORING MATRIX
    local found_bar = false
    if VERBOSE_DEBUG then dprint("  -> Checking Products...") end
    for i, product in ipairs(reaction.products) do
        -- THE FIX: Check if it's an item before asking for item_type
        if df.reaction_product_itemst:is_instance(product) then
            if VERBOSE_DEBUG then dprint(string.format("    -> Product %d is itemst. item_type: %s, mat_type: %s", i, tostring(product.item_type), tostring(product.mat_type))) end
            
            if product.item_type == 0 and product.mat_type == 0 then
                if not found_bar then
                    score = score + 20
                    if VERBOSE_DEBUG then dprint("  -> Score +20: Produces Inorganic Bar") end
                    if product.product_dimension == 150 then
                        score = score + 20
                        if VERBOSE_DEBUG then dprint("  -> Score +20: Standard dimension (150)") end
                    end
                    found_bar = true
                end
                
                if product.mat_index >= 0 then
                    local temp_inorg = df.global.world.raws.inorganics.all[product.mat_index]
                    if temp_inorg then
                        if VERBOSE_DEBUG then dprint("    -> Matched Inorganic ID: " .. temp_inorg.id) end
                        if string.find(reaction.code, temp_inorg.id) then
                            target_mat_index = product.mat_index
                            break 
                        elseif not string.find(temp_inorg.id, "SLAG") then
                            target_mat_index = product.mat_index
                        elseif target_mat_index < 0 then
                            target_mat_index = product.mat_index
                        end
                    end
                end
            end
        else
            if VERBOSE_DEBUG then dprint(string.format("    -> Product %d is NOT an itemst (Skipping to avoid crash)", i)) end
        end
    end

    -- Evaluate Reagents
    if VERBOSE_DEBUG then dprint("  -> Checking Reagents...") end
    if reaction.reagents and #reaction.reagents > 0 then
        for i, reagent in ipairs(reaction.reagents) do
            -- THE FIX: Check if it's an item before asking for item_type
            if df.reaction_reagent_itemst:is_instance(reagent) then
                if VERBOSE_DEBUG then dprint(string.format("    -> Reagent %d is itemst. item_type: %s", i, tostring(reagent.item_type))) end
                
                if reagent.item_type == 4 then
                    if reagent.metal_ore and reagent.metal_ore >= 0 then
                        score = score + 30
                        if VERBOSE_DEBUG then dprint("  -> Score +30: Uses Metal Ore") end
                        if target_mat_index < 0 then target_mat_index = reagent.metal_ore end
                        break
                    end
                elseif reagent.mat_type == 0 and reagent.mat_index >= 0 then
                    if reagent.item_type == 0 then 
                        score = score + 15 
                        if VERBOSE_DEBUG then dprint("  -> Score +15: Uses Inorganic Bar Reagent") end
                    end
                    if target_mat_index < 0 then target_mat_index = reagent.mat_index end
                end
            else
                if VERBOSE_DEBUG then dprint(string.format("    -> Reagent %d is NOT an itemst (Skipping)", i)) end
            end
        end
    end

    -- Evaluate Environment specifics
    if reaction.building and reaction.building.subtype then
        for _, b_subtype in ipairs(reaction.building.subtype) do
            if b_subtype == 1 or b_subtype == 4 then 
                score = score + 10
                if VERBOSE_DEBUG then dprint("  -> Score +10: Uses specific Smelter subtype") end
                break
            end
        end
    end

    if reaction.flags.FUEL then
        score = score + 10
        if VERBOSE_DEBUG then dprint("  -> Score +10: Requires FUEL flag") end
    end

    -- PHASE 3: RAW STRING CONTINGENCY
    if reaction.raw_strings then
        for _, raw_str_obj in ipairs(reaction.raw_strings) do
            local str_val = raw_str_obj.value
            if str_val then
                if string.find(str_val, "%[PRODUCT:.*:.*:BAR:.*:METAL:.*%]") then
                    score = score + 10
                    if VERBOSE_DEBUG then dprint("  -> Score +10: Raw String Contingency matched") end
                end
                if target_mat_index < 0 then
                    local mat_id = string.match(str_val, "%[PRODUCT:.*:.*:BAR:.*:METAL:([^%]]+)%]")
                    if mat_id then
                        for idx, inorg in ipairs(df.global.world.raws.inorganics.all) do
                            if inorg.id == mat_id then
                                target_mat_index = idx
                                if VERBOSE_DEBUG then dprint("    -> Target Mat Index rescued from Raw String: " .. mat_id) end
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- THE FIX: Explicit Verdict Logging
    if target_mat_index < 0 then 
        if VERBOSE_DEBUG then dprint(string.format("  -> [REJECTED]: Score reached %d, but failed to identify a target Inorganic Mat Index.", score)) end
        return 0, nil 
    end
    
    if score == 0 then
        if VERBOSE_DEBUG then dprint("  -> [REJECTED]: Failed all scoring criteria (Final Score: 0).") end
        return 0, nil
    end

    if VERBOSE_DEBUG then dprint(string.format("  -> [ACCEPTED]: Final Score: %d | Target Mat Index: %d", score, target_mat_index)) end
    return score, target_mat_index
end

-- ==========================================
-- CALLABLE MODULE FUNCTION
-- ==========================================
function get_metal_making_reactions(force_recalculate)
    if cached_evaluations and not force_recalculate then
        return cached_evaluations
    end

    local opened_here = false
    if VERBOSE_DEBUG and not debug_file then
        debug_file = io.open(dfhack.getDFPath() .. "/refinish_debug_reaction_evaluator.txt", "w")
        opened_here = true
    end

    local evaluated_dict = {}

    for i, reaction in ipairs(df.global.world.raws.reactions.reactions) do
        -- Skip RM core reactions (our own injected payload)
        if not string.find(reaction.code, "REFINISH_STEEL_") then
            -- Skip module-injected reactions. These are transient -
            -- they get cleared and re-injected every data cycle, so
            -- they can't be relied on as stable template donors.
            -- Same filter pattern as refinish-module-react.lua's
            -- find_template uses for structural donors.
            local is_module = false
            if _G.refinish_module_registry then
                for prefix, _ in pairs(_G.refinish_module_registry) do
                    if string.find(reaction.code, prefix) then
                        is_module = true
                        break
                    end
                end
            end

            if not is_module then
                local r_score, mat_idx = evaluate_reaction(reaction)
                if r_score > 0 and mat_idx then
                    evaluated_dict[i] = {
                        code = reaction.code,
                        score = r_score,
                        mat_index = mat_idx
                    }
                end
            end
        end
    end

    cached_evaluations = evaluated_dict

    if opened_here and debug_file then
        debug_file:close()
        debug_file = nil
    end

    return cached_evaluations
end


-- ==========================================
-- BEST TEMPLATE SELECTOR
-- ==========================================
-- Returns the single highest-scoring metal-making reaction along
-- with the reagent and product indexes needed for template cloning.
-- This is what index-reaction consumes to pick its metal template.
--
-- RETURNS a table:
--   {
--       reaction  = <df.reaction>,    -- the template reaction object
--       code      = "STEEL_MAKING",   -- its code string
--       score     = 100,              -- its evaluation score
--       rgt_idx   = 0,                -- index of the best bar reagent
--       prod_idx  = 0,                -- index of the best bar product
--   }
--   or nil if no valid candidate was found.
-- ==========================================
local cached_best_template = nil

function get_best_metal_template(force_recalculate)
    if cached_best_template and not force_recalculate then
        return cached_best_template
    end

    local dict = get_metal_making_reactions(force_recalculate)
    local reactions = df.global.world.raws.reactions.reactions
    local inorganics = df.global.world.raws.inorganics.all

    local best = nil

    for idx, data in pairs(dict) do
        if not best or data.score > best.score then
            -- Verify we can extract the reagent and product indexes
            -- that index-reaction needs for cloning. This mirrors the
            -- structural checks that index-reaction's old first-match
            -- hunt did, but applied only to the top-scored candidate.
            local rxn = reactions[idx]
            if rxn then
                local rgt_idx = -1
                local prod_idx = -1

                -- Find the best inorganic bar reagent
                for i, rgt in ipairs(rxn.reagents) do
                    if df.reaction_reagent_itemst:is_instance(rgt)
                        and rgt.item_type == df.item_type.BAR
                        and rgt.mat_type == 0 then
                        rgt_idx = i
                        break
                    end
                end

                -- Find the best inorganic metal bar product
                for i, prod in ipairs(rxn.products) do
                    if df.reaction_product_itemst:is_instance(prod)
                        and prod.item_type == df.item_type.BAR
                        and prod.mat_type == 0 then
                        local inorg = inorganics[prod.mat_index]
                        if inorg and inorg.material.flags.IS_METAL then
                            prod_idx = i
                            break
                        end
                    end
                end

                -- Only accept if we found both required indexes
                if rgt_idx >= 0 and prod_idx >= 0 then
                    best = {
                        reaction = rxn,
                        code     = data.code,
                        score    = data.score,
                        rgt_idx  = rgt_idx,
                        prod_idx = prod_idx,
                    }
                end
            end
        end
    end

    cached_best_template = best

    -- WARNING, not ERROR: this is the cause, and the reaction injector
    -- reports the consequence as an ERROR when it finds no template.
    if best then
        log('DETAIL', string.format('Best template: [%s] score=%d rgt_idx=%d'
            .. ' prod_idx=%d', best.code, best.score, best.rgt_idx,
            best.prod_idx), 'TEMPLATE')
    else
        log('WARNING', 'No valid metal-making template found.', 'TEMPLATE')
    end

    return cached_best_template
end

-- ==========================================
-- CONSOLE DIAGNOSTIC OUTPUT
-- ==========================================
local function run_evaluation()
    if VERBOSE_DEBUG and not debug_file then
        debug_file = io.open(dfhack.getDFPath() .. "/refinish_debug_reaction_evaluator.txt", "w")
    end

    dprint("\n==========================================")
    dprint("REFINISH STEEL: REACTION EVALUATION START")
    dprint("==========================================\n")

    local dict = get_metal_making_reactions(true)
    local sorted_list = {}
    
    for idx, data in pairs(dict) do
        table.insert(sorted_list, {index = idx, code = data.code, score = data.score, mat_index = data.mat_index})
    end
    
    table.sort(sorted_list, function(a, b) return a.score > b.score end)

    dprint(string.format("Evaluation complete. Found %d valid metal-making reactions.\n", #sorted_list))
    dprint("TOP SCORING REACTIONS:")
    dprint("------------------------------------------")
    
    for _, data in ipairs(sorted_list) do
        local metal_name = "UNKNOWN"
        local inorg = df.global.world.raws.inorganics.all[data.mat_index]
        if inorg then metal_name = inorg.id end
        
        dprint(string.format("Score: %3d | Index: %4d | Mat: %-18s | Code: %s", data.score, data.index, metal_name, data.code))
    end
    
    dprint("\n==========================================")
    dprint("REFINISH STEEL: REACTION EVALUATION END")
    dprint("==========================================\n")

    if debug_file then
        debug_file:close()
        debug_file = nil
    end
end

if dfhack_flags and dfhack_flags.module then
    return _ENV
end

run_evaluation()
return _ENV