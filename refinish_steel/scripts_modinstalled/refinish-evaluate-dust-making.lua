--@ module = true
-- refinish-evaluate-dust-making.lua
-- ==========================================
-- REFINISH STEEL: DUST-MAKING REACTION EVALUATOR
-- ==========================================
-- Scores all loaded reactions to identify dust/powder-making candidates.
-- A good dust template must have:
--   - A bag reagent with PRESERVE_REAGENT and empty flags
--   - A POWDER_MISC product that routes into a container
--   - Ideally an inorganic input (boulder or bar)
--   - A smelter/kiln building type
--
-- The ideal vanilla candidate is MAKE_PLASTER_POWDER, which has all
-- of these properties. This evaluator ensures we always pick the best
-- available match even in heavily modded worlds where MAKE_PLASTER_POWDER
-- may have been modified or removed.
--
-- This is a boot-time utility. Results are cached after first call
-- and consumed by boot's template caching system.
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
-- Console prints only where they answer a typed command. A print only
-- appears as the direct answer to a command typed into the DFHack
-- console, and nowhere else. The one place that holds here is the
-- diagnostic at the bottom, which runs only when this file is typed
-- as a command rather than loaded as a module.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'EVAL_DUST'
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

local cached_result = nil


-- ==========================================
-- SINGLE REACTION SCORER
-- ==========================================
-- Examines one reaction and returns a score indicating how well it
-- matches the ideal dust-making template shape. Higher = better.
--
-- SCORING CRITERIA (from make_plaster_powder_reaction_map.txt):
--   +30  Has a bag reagent with PRESERVE_REAGENT flag
--   +20  That bag reagent also has flags1.empty = true
--   +30  Has a POWDER_MISC product (item_type 70)
--   +20  That product has product_to_container set (routes into bag)
--   +10  Product uses mat_type 0 (INORGANIC output)
--   +10  Uses SMELT skill (skill index 24)
--   +10  Uses a smelter/kiln building (type 5, subtype 1/3/4/6)
--   +10  Requires FUEL flag
--
-- RETURNS:
--   score     - integer, 0 if the reaction isn't a dust-making candidate
--   bag_idx   - index of the bag reagent in the reaction's reagents array
--   prod_idx  - index of the powder product in the reaction's products array
--   nil, nil  - if score is 0 (not a valid candidate)
-- ==========================================
local function evaluate_reaction(rxn)
    local score = 0
    local bag_idx = -1
    local prod_idx = -1

    -- PHASE 1: FIND THE BAG REAGENT
    -- A dust-making reaction needs a bag that gets preserved (not consumed)
    -- and is required to be empty (so the powder product fills it).
    -- Path reference: reagents[1].item_type = 31 (BAG)
    --                 reagents[1].flags.PRESERVE_REAGENT = true
    --                 reagents[1].flags1.empty = true
    if rxn.reagents then
        for i, rgt in ipairs(rxn.reagents) do
            if df.reaction_reagent_itemst:is_instance(rgt) then
                -- item_type 31 = BAG
                if rgt.item_type == 31 then
                    if rgt.flags.PRESERVE_REAGENT then
                        score = score + 30
                        bag_idx = i
                        -- Bonus: bag is required to be empty
                        if rgt.flags1.empty then
                            score = score + 20
                        end
                    end
                    break  -- Only care about the first bag reagent
                end
            end
        end
    end

    -- No bag reagent = not a dust-making reaction. Early exit.
    if bag_idx < 0 then return 0, nil, nil end

    -- PHASE 2: FIND THE POWDER PRODUCT
    -- The product must be POWDER_MISC (item_type 70) and route into
    -- the bag via product_to_container.
    -- Path reference: products[0].item_type = 70 (POWDER_MISC)
    --                 products[0].product_to_container = "B" (bag code)
    if rxn.products then
        for i, prod in ipairs(rxn.products) do
            if df.reaction_product_itemst:is_instance(prod) then
                -- item_type 70 = POWDER_MISC
                if prod.item_type == 70 then
                    score = score + 30
                    prod_idx = i

                    -- Bonus: product routes into a container
                    if prod.product_to_container and prod.product_to_container ~= "" then
                        score = score + 20
                    end

                    -- Bonus: product is inorganic
                    if prod.mat_type == 0 then
                        score = score + 10
                    end
                    break  -- Only care about the first powder product
                end
            end
        end
    end

    -- No powder product = not useful as a template. Early exit.
    if prod_idx < 0 then return 0, nil, nil end

    -- PHASE 3: ENVIRONMENT SCORING
    -- These are nice-to-have properties that indicate a cleaner template.

    -- Uses SMELT skill (skill index 24)
    if rxn.skill == 24 then
        score = score + 10
    end

    -- Uses a smelter/kiln building type
    if rxn.building and rxn.building.type then
        for _, b_type in ipairs(rxn.building.type) do
            -- building_type 5 = Furnace (smelter/kiln/magma variants)
            if b_type == 5 then
                score = score + 10
                break
            end
        end
    end

    -- Requires fuel
    if rxn.flags.FUEL then
        score = score + 10
    end

    return score, bag_idx, prod_idx
end


-- ==========================================
-- CALLABLE MODULE FUNCTION
-- ==========================================
-- Returns the single best dust-making template reaction, along with
-- the indexes of its bag reagent and powder product. These indexes
-- are needed by index-reaction when cloning the template.
--
-- RETURNS a table:
--   {
--       reaction  = <df.reaction>,   -- the template reaction object
--       code      = "MAKE_PLASTER_POWDER",  -- its code string
--       score     = 140,              -- its evaluation score
--       bag_idx   = 1,                -- index of the bag reagent
--       prod_idx  = 0,                -- index of the powder product
--   }
--   or nil if no valid candidate was found.
-- ==========================================
function get_best_dust_template(force_recalculate)
    if cached_result and not force_recalculate then
        return cached_result
    end

    local best = nil

    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        -- Skip RM core and module-injected reactions (transient,
        -- can't be relied on as stable template donors across cycles)
        if not string.find(rxn.code, "REFINISH_STEEL_") then
            local is_module = false
            if _G.refinish_module_registry then
                for prefix, _ in pairs(_G.refinish_module_registry) do
                    if string.find(rxn.code, prefix) then
                        is_module = true
                        break
                    end
                end
            end

            if not is_module then
                local score, bag_idx, prod_idx = evaluate_reaction(rxn)
                if score > 0 then
                    if not best or score > best.score then
                        best = {
                            reaction = rxn,
                            code     = rxn.code,
                            score    = score,
                            bag_idx  = bag_idx,
                            prod_idx = prod_idx,
                        }
                    end
                end
            end
        end
    end

    cached_result = best

    -- WARNING, not ERROR: this is the cause, and the reaction injector
    -- reports the consequence as an ERROR when it finds no template.
    if best then
        log('DETAIL', string.format('Best template: [%s] score=%d bag_idx=%d'
            .. ' prod_idx=%d', best.code, best.score, best.bag_idx,
            best.prod_idx), 'TEMPLATE')
    else
        log('WARNING', 'No valid dust-making template found.', 'TEMPLATE')
    end

    return cached_result
end


-- ==========================================
-- CONSOLE DIAGNOSTIC OUTPUT
-- ==========================================
-- Run this script directly (not as module) to see all scored candidates.
-- These prints stay: they only run when this file is typed as a
-- command, so they are the direct answer to it.
local function run_diagnostic()
    print("==================================================")
    print("REFINISH STEEL: DUST-MAKING REACTION EVALUATION")
    print("==================================================")

    local candidates = {}
    for i, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        if not string.find(rxn.code, "REFINISH_STEEL_") then
            local is_module = false
            if _G.refinish_module_registry then
                for prefix, _ in pairs(_G.refinish_module_registry) do
                    if string.find(rxn.code, prefix) then
                        is_module = true
                        break
                    end
                end
            end

            if not is_module then
                local score, bag_idx, prod_idx = evaluate_reaction(rxn)
                if score > 0 then
                    table.insert(candidates, {
                        index = i, code = rxn.code, score = score,
                        bag_idx = bag_idx, prod_idx = prod_idx
                    })
                end
            end
        end
    end

    table.sort(candidates, function(a, b) return a.score > b.score end)

    print(string.format("Found %d dust-making candidates.\n", #candidates))
    for _, c in ipairs(candidates) do
        print(string.format("  Score: %3d | Index: %4d | Bag: %d | Prod: %d | Code: %s",
            c.score, c.index, c.bag_idx, c.prod_idx, c.code))
    end
    print("==================================================")
end

if dfhack_flags and dfhack_flags.module then
    return _ENV
end

run_diagnostic()
return _ENV