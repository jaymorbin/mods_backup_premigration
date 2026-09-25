-- refinish-clear-entity.lua
-- Removes dynamically injected reactions from all civilization UIs
-- globally. Every log line is DETAIL: the shutdown or save cycle that
-- calls this reports the outcome. The per-civ trace stays behind
-- VERBOSE_DEBUG, in its own file.

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
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'CLEAR_ENTITY'
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
    debug_file = io.open(dfhack.getDFPath() .. "/refinish_clear_entity_debug.txt", "w")
    dprint("==================================================")
    dprint("REFINISH STEEL: CLEAR ENTITY DEBUG LOG")
    dprint("==================================================")
end

-- STATE MANAGER: Deep RAM Verification (Using player civ as a proxy check)
if _G.refinish_entity_loaded == nil or _G.refinish_entity_loaded == true then
    local actually_loaded = false
    local player_civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    if player_civ and player_civ.entity_raw then
        local permitted = player_civ.entity_raw.workshops.permitted_reaction_id
        local reactions = df.global.world.raws.reactions.reactions
        for _, pid in ipairs(permitted) do
            if pid >= 0 and pid < #reactions then
                local rxn = reactions[pid]
                if rxn and string.find(rxn.code, "REFINISH_STEEL_RXN_") then
                    actually_loaded = true
                    break
                end
            end
        end
    end
    if not actually_loaded then _G.refinish_entity_loaded = false end
end

if not _G.refinish_entity_loaded then
    log('DETAIL', 'Civ permissions already cleared. Skipping.')
    return
end

local rxn_ids_to_remove = {}
local reactions_array = df.global.world.raws.reactions.reactions

-- First, map out the integer IDs of our injected reactions
for i = #reactions_array - 1, 0, -1 do
    local rxn = reactions_array[i]
    if string.find(rxn.code, "REFINISH_STEEL_") then
        rxn_ids_to_remove[rxn.index] = true
    end
end

local processed_raws = {}
local removed_count = 0
local entities_scrubbed = 0

-- Sweep Global Entities and Erase
for _, civ in ipairs(df.global.world.entities.all) do
    if civ.type == df.historical_entity_type.Civilization and civ.entity_raw then
        
        -- Pointer Safety: Only scrub each raw table once
        if not processed_raws[civ.entity_raw] then
            processed_raws[civ.entity_raw] = true
            
            local permitted = civ.entity_raw.workshops.permitted_reaction_id
            local cleared_from_this_entity = 0
            
-- LIFO loop to safely erase from the vector
            for i = #permitted - 1, 0, -1 do
                if rxn_ids_to_remove[permitted[i]] then
                    dprint(string.format("  [-] Erasing Reaction ID %d from Class %s", permitted[i], civ.entity_raw.code))
                    permitted:erase(i)
                    cleared_from_this_entity = cleared_from_this_entity + 1
                    removed_count = removed_count + 1
                end
            end
            
            if cleared_from_this_entity > 0 then
                entities_scrubbed = entities_scrubbed + 1
            end
        end
    end
end

if removed_count > 0 then
    log('DETAIL', string.format('Excised %d reaction permissions from %d'
        .. ' civilizations.', removed_count, entities_scrubbed))
else
    log('DETAIL', 'No reaction permissions found to clear.')
end

if debug_file then
    debug_file:close()
    debug_file = nil
end

_G.refinish_entity_loaded = false