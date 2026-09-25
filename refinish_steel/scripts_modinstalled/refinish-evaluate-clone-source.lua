--@ module = true
-- refinish-evaluate-clone-source.lua
-- ==========================================
-- RM MODULE CLONE SOURCE EVALUATOR
-- ==========================================
-- Scans the loaded inorganic array and selects the best clone
-- donor for each material class. Runs once at the start of the
-- module pipeline, caches results in _G, and downstream injection
-- pulls from the cache.
--
-- WHY THIS IS SEPARATE:
--   Clone selection is non-trivial evaluation logic. It walks
--   the entire inorganic array, checks flag signatures, scores
--   candidates, and makes a judgment call. Burying that inside
--   the injection file would make both harder to debug and test.
--   This file runs, caches, and gets out of the way.
--
-- CACHE LOCATION:
--   _G.refinish_module_clone_cache
--   Keyed by material class name (e.g. "METAL", "STONE").
--   Each value is the inorganic_raw object to use as clone donor.
--
-- LIFECYCLE:
--   Populated: Once per module pipeline run (called from engine).
--   Consumed:  By refinish-module-inject.lua during material injection.
--   Cleared:   On shutdown alongside other module globals.
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
-- SUBJECT is the correlation slot: the material class a line is
-- about. Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'CLONE_EVAL'
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
-- SCORE A SINGLE CANDIDATE
-- ==========================================
-- Given an inorganic and a class signature from the types dict,
-- return a numeric score. Higher = better donor. Returns -1 if
-- the candidate fails a hard requirement (disqualified).
--
-- Scoring logic:
--   1. Check require_true flags. ALL must be true or candidate
--      is disqualified (-1).
--   2. Check require_false flags. ALL must be false or candidate
--      is disqualified (-1).
--   3. Base score of 1 for passing requirements.
--   4. Bonus points for each "prefer" flag that's true.
--   5. Penalty for exotic flags that suggest the candidate is
--      unusual (GENERATED, DIVINE, MYTHICAL, SPECIAL, DEEP_SPECIAL).
--      We want plain, vanilla-feeling donors - not artifacts of
--      world-gen or divine intervention.
--   6. Small bonus for having a non-empty state_name (indicates
--      the material has been properly initialized with display data).
-- ==========================================
local function score_candidate(inorganic, signature)
    local mat_flags = inorganic.material.flags

    -- Hard requirements: must have these flags set to true
    for _, flag_name in ipairs(signature.require_true) do
        if not mat_flags[flag_name] then
            return -1
        end
    end

    -- Hard requirements: must have these flags set to false
    for _, flag_name in ipairs(signature.require_false) do
        if mat_flags[flag_name] then
            return -1
        end
    end

    -- Passed requirements - start scoring
    local score = 1

    -- Soft preferences: bonus for each preferred flag
    for _, flag_name in ipairs(signature.prefer) do
        if mat_flags[flag_name] then
            score = score + 5
        end
    end

    -- Exotic penalty: deduct for unusual origin flags.
    -- These materials may carry engine-internal state that
    -- makes them poor structural donors.
    local inorg_flags = inorganic.flags
    local exotic_flags = { "GENERATED", "DIVINE", "MYTHICAL", "MYTHICAL_REMNANT", "SPECIAL", "DEEP_SPECIAL" }
    for _, flag_name in ipairs(exotic_flags) do
        if inorg_flags[flag_name] then
            score = score - 10
        end
    end

    -- Initialization bonus: material has a proper display name
    local solid_name = inorganic.material.state_name.Solid
    if solid_name and solid_name ~= "" then
        score = score + 2
    end

    return score
end


-- ==========================================
-- EVALUATE ONE CLASS
-- ==========================================
-- Walks the full inorganic array and returns the best candidate
-- for a given class signature. Returns nil if no candidate passes
-- the hard requirements.
-- ==========================================
local function evaluate_class(class_name, signature)
    local inorganics = df.global.world.raws.inorganics.all
    local best = nil
    local best_score = -1

    for _, inorganic in ipairs(inorganics) do
        -- Skip any RM-injected or module-injected materials.
        -- We only want vanilla or raws-loaded materials as donors.
        if not string.find(inorganic.id, "REFINISH_STEEL_") then
            local dominated_by_module = false
            if _G.refinish_module_registry then
                for prefix, _ in pairs(_G.refinish_module_registry) do
                    if string.find(inorganic.id, prefix) then
                        dominated_by_module = true
                        break
                    end
                end
            end

            if not dominated_by_module then
                local score = score_candidate(inorganic, signature)
                if score > best_score then
                    best_score = score
                    best = inorganic
                end
            end
        end
    end

    return best, best_score
end


-- ==========================================
-- PUBLIC: RUN EVALUATION
-- ==========================================
-- Evaluates clone donors for every material class that has a
-- signature defined in the types dictionary. Caches results
-- in _G.refinish_module_clone_cache.
--
-- Called once from the module engine before injection runs.
-- Returns the cache table (also accessible via _G).
--
-- The classes_needed parameter is optional. If provided, only
-- those classes are evaluated (saves time when a module only
-- uses METAL, for example). If nil, all classes are evaluated.
-- ==========================================
function evaluate(classes_needed)
    _G.refinish_module_clone_cache = {}
    local cache = _G.refinish_module_clone_cache

    -- Determine which classes to evaluate
    local classes_to_eval = {}
    if classes_needed then
        -- Only evaluate what's actually requested
        for _, class_name in ipairs(classes_needed) do
            if types.CLONE_SIGNATURES[class_name] then
                classes_to_eval[class_name] = types.CLONE_SIGNATURES[class_name]
            end
        end
    else
        -- Evaluate all defined classes
        classes_to_eval = types.CLONE_SIGNATURES
    end

    for class_name, signature in pairs(classes_to_eval) do
        -- RAW class has no signature - it falls back to STONE
        -- as the most structurally neutral inorganic type
        local eval_sig = signature
        if class_name == "RAW" and #signature.require_true == 0 then
            eval_sig = types.CLONE_SIGNATURES["STONE"]
            if not eval_sig then
                -- No stone signature either - skip RAW
                log('WARNING', 'RAW class has no fallback signature. Skipped.',
                    'RAW')
                goto continue
            end
        end

        local best, score = evaluate_class(class_name, eval_sig)

        -- GLASS fallback: vanilla worlds have no IS_GLASS inorganics.
        -- Fall back to CERAMIC donor - structurally closest match
        -- (both are IS_X + ITEMS_HARD, non-metal, non-weapon).
        -- The GLASS preset will flip IS_CERAMIC→false, IS_GLASS→true.
        if not best and class_name == "GLASS" then
            local ceramic_sig = types.CLONE_SIGNATURES["CERAMIC"]
            if ceramic_sig then
                best, score = evaluate_class("GLASS(->CERAMIC)", ceramic_sig)
                if best then
                    log('DETAIL', string.format('No native donor. Falling back to'
                        .. ' CERAMIC donor [%s] (score %d).', best.id, score),
                        'GLASS')
                end
            end
        end

        if best then
            cache[class_name] = best
            log('DETAIL', string.format('Donor [%s] (score %d).', best.id,
                score), class_name)
        else
            -- No candidate found for this class. This is not fatal -
            -- it just means any module materials of this class will
            -- fail at injection time with a clear error.
            log('WARNING', 'No valid donor found for this class.', class_name)
        end

        ::continue::
    end

    local count = 0
    for _ in pairs(cache) do count = count + 1 end

    log('DETAIL', string.format('Complete. %d classes resolved.', count))

    return cache
end


-- ==========================================
-- PUBLIC: GET DONOR FOR CLASS
-- ==========================================
-- Convenience accessor. Returns the cached donor for a class,
-- or nil if none was found. Safe to call at any time - returns
-- nil if the evaluator hasn't run yet.
-- ==========================================
function get_donor(class_name)
    if not _G.refinish_module_clone_cache then return nil end
    return _G.refinish_module_clone_cache[class_name]
end


return _ENV