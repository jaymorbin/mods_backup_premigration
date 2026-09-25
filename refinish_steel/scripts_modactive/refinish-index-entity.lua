-- refinish-index-entity.lua
-- ==========================================
-- SCRIPT LOGIC: GLOBAL ENTITY UNLOCKER
-- ==========================================
-- Grants every capable civilization permission for core RM's
-- reactions. Every log line is DETAIL: the startup that calls this
-- reports the outcome. The per-civ trace stays behind VERBOSE_DEBUG,
-- in its own file.

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
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'INDEX_ENTITY'
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

local VERBOSE_DEBUG = false
local debug_file = nil

local function dprint(msg)
    if debug_file then debug_file:write(msg .. "\n") end
end

if VERBOSE_DEBUG then
    debug_file = io.open(dfhack.getDFPath() .. "/refinish_indexer_debug.txt", "w")
    dprint("==================================================")
    dprint("REFINISH STEEL: INDEXER DEBUG LOG")
    dprint("==================================================")
end

log('DETAIL', 'Civ reaction permission unlock initiated.')

-- STATE MANAGER: Deep RAM Verification (Using player civ as a proxy check)
if _G.refinish_entity_loaded == nil or _G.refinish_entity_loaded == false then
    local player_civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    if player_civ and player_civ.entity_raw then
        local permitted = player_civ.entity_raw.workshops.permitted_reaction_id
        local reactions = df.global.world.raws.reactions.reactions
        for _, pid in ipairs(permitted) do
            if pid >= 0 and pid < #reactions then
                local rxn = reactions[pid]
                if rxn and string.find(rxn.code, "REFINISH_STEEL_RXN_") then
                    _G.refinish_entity_loaded = true
                    break
                end
            end
        end
    end
end

if _G.refinish_entity_loaded then
    dprint("ABORTED: _G.refinish_entity_loaded is already true. UI previously unlocked.")
    log('DETAIL', 'Civ permissions already unlocked. Skipping.')
    if debug_file then debug_file:close(); debug_file = nil end
    return
end

-- 1. Categorize our payload
local reactions = df.global.world.raws.reactions.reactions
local rxn_idx_to_code = {}
local rs_payloads = { FINISHES = {}, STONE_GRIND = {}, GEM_GRIND = {}, METAL_GRIND = {} }
local blueprint_rxns = _G.refinish_blueprint and _G.refinish_blueprint.reactions or {}

dprint("\n--- PHASE 1: CATEGORIZING PAYLOADS ---")
for _, rxn in ipairs(reactions) do
    rxn_idx_to_code[rxn.index] = rxn.code
    if string.find(rxn.code, "REFINISH_STEEL_RXN_LUA_GRIND_COMMON") or string.find(rxn.code, "REFINISH_STEEL_RXN_LUA_GRIND_ANY") then
        table.insert(rs_payloads.STONE_GRIND, rxn.index)
    elseif string.find(rxn.code, "REFINISH_STEEL_RXN_LUA_GRIND_GEMS") then
        table.insert(rs_payloads.GEM_GRIND, rxn.index)
    elseif string.find(rxn.code, "REFINISH_STEEL_RXN_LUA_GRIND_METAL") then
        table.insert(rs_payloads.METAL_GRIND, rxn.index)
    elseif string.find(rxn.code, "REFINISH_STEEL_RXN_") then
        local bp_data = blueprint_rxns[rxn.code]
        if bp_data and bp_data.base_metal_id then
            local b_id = bp_data.base_metal_id
            if not rs_payloads.FINISHES[b_id] then rs_payloads.FINISHES[b_id] = {} end
            table.insert(rs_payloads.FINISHES[b_id], rxn.index)
        end
    end
end

dprint("Payloads Built:")
dprint("  Stone Grind Rxns: " .. #rs_payloads.STONE_GRIND)
dprint("  Gem Grind Rxns: " .. #rs_payloads.GEM_GRIND)
dprint("  Metal Grind Rxns: " .. #rs_payloads.METAL_GRIND)
local finish_metal_count = 0
for k, v in pairs(rs_payloads.FINISHES) do finish_metal_count = finish_metal_count + 1 end
dprint("  Finishes mapped for " .. finish_metal_count .. " distinct base metals.")

local processed_raws = {}
local entities_updated = 0
local count = 0

dprint("\n--- SWEEPING ENTITIES (VIA CACHE) ---")

-- THE FIX: Front-load the Player Civ so it permanently sets the tech cache for its shared entity_raw
local processing_queue = {}
local p_civ = df.historical_entity.find(df.global.plotinfo.civ_id)
if p_civ then table.insert(processing_queue, p_civ) end

for _, civ in ipairs(df.global.world.entities.all) do
    if not p_civ or civ.id ~= p_civ.id then
        table.insert(processing_queue, civ)
    end
end

-- 2. Sweep Global Entities & Inject
for civ_idx, civ in ipairs(processing_queue) do
    if civ.type == df.historical_entity_type.Civilization and civ.entity_raw then
        
        if not processed_raws[civ.entity_raw] then
            processed_raws[civ.entity_raw] = true
            dprint("\nEvaluating Entity Code: " .. tostring(civ.entity_raw.code) .. " (Queue Index: " .. civ_idx .. ")")
            
            -- FETCH EXACT PRE-CALCULATED LOGIC FROM CACHE
            local civ_cache = nil
            if _G.refinish_blueprint and _G.refinish_blueprint.civ_tech then
                civ_cache = _G.refinish_blueprint.civ_tech[civ.entity_raw.code]
            end
            
            if civ_cache then
                dprint("  Moods -> Forge: " .. tostring(civ_cache.has_forge) .. ", Mason: " .. tostring(civ_cache.has_mason) .. ", Gem: " .. tostring(civ_cache.has_gem))

                local permitted_rxns = civ.entity_raw.workshops.permitted_reaction_id
                local known_metals = civ_cache.known_metals or {}
                local metal_tech = civ_cache.metal_tech
                local stone_tech = civ_cache.stone_tech
                local gem_tech   = civ_cache.gem_tech

                -- Phase 3: The Cross-Reference & Injection
                if stone_tech or gem_tech or metal_tech then
                    local already_permitted = {}
                    for _, pid in ipairs(permitted_rxns) do already_permitted[pid] = true end
                    
                    local injected_count = 0
                    local valid_injections = {} 

                    local function queue_payload(payload_table, label)
                        local added = 0
                        for _, target_idx in ipairs(payload_table) do
                            if not already_permitted[target_idx] then
                                table.insert(valid_injections, target_idx)
                                added = added + 1
                            end
                        end
                        
                        -- THE FIX: Explicitly log successes and skips for every single payload
                        if added > 0 then
                            dprint("    [+] Queued " .. added .. " reactions for payload: " .. label)
                        else
                            dprint("    [-] Skipped payload: " .. label .. " (0 new reactions needed, or empty)")
                        end
                    end

                    if stone_tech then queue_payload(rs_payloads.STONE_GRIND, "STONE_GRIND") end
                    if gem_tech   then queue_payload(rs_payloads.GEM_GRIND, "GEM_GRIND") end
                    
                    if metal_tech then 
                        queue_payload(rs_payloads.METAL_GRIND, "METAL_GRIND")
                        
                        for base_metal_id, payload_array in pairs(rs_payloads.FINISHES) do
                            if known_metals[base_metal_id] then
                                queue_payload(payload_array, "FINISHES for " .. base_metal_id)
                            end
                        end
                    end
                    
                    table.sort(valid_injections)

                    for _, target_idx in ipairs(valid_injections) do
                        permitted_rxns:insert('#', target_idx)
                        injected_count = injected_count + 1
                    end
                    
                    if injected_count > 0 then
                        entities_updated = entities_updated + 1
                        count = count + injected_count
                        dprint("  [SUCCESS] Injected " .. injected_count .. " custom reactions into " .. tostring(civ.entity_raw.code))
                    else
                        dprint("  [SKIP] 0 reactions injected (Already has them or no matching tech).")
                    end
                else
                    dprint("  [FAIL] Entity lacks required mood tech (Forge/Mason/Gem).")
                end
            else
                dprint("  [FAIL] Entity lacked a valid blueprint cache.")
            end
        end
    end
end

_G.refinish_entity_loaded = true

dprint("\n==================================================")
dprint(string.format("Global UI Unlock Complete: %d custom reactions injected across %d capable civilizations.", count, entities_updated))
dprint("==================================================")

if debug_file then
    debug_file:close()
    debug_file = nil
end

log('DETAIL', string.format('Civ permission unlock complete: %d reactions'
    .. ' granted across %d civilizations.', count, entities_updated))