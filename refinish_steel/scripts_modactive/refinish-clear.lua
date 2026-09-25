-- refinish-clear.lua
-- Removes core RM materials from the inorganics array and restores the
-- powder names the scan renamed. Every line is DETAIL: the shutdown or
-- save cycle that calls this reports the outcome.

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
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'CLEAR_MATERIALS'
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

-- STATE MANAGER: Deep RAM Verification
if _G.refinish_ram_loaded == nil or _G.refinish_ram_loaded == true then
    local actually_loaded = false
    for _, mat in ipairs(df.global.world.raws.inorganics.all) do
        if string.find(mat.id, "REFINISH_STEEL_MAT_") then
            actually_loaded = true
            break
        end
    end
    if not actually_loaded then _G.refinish_ram_loaded = false end
end

-- THE FIX: Safely restore vanilla nomenclature before wiping the blueprint
if _G.refinish_blueprint and _G.refinish_blueprint.original_names then
    local names_restored = 0
    local raws = df.global.world.raws.inorganics.all
    for _, mat in ipairs(raws) do
        local original = _G.refinish_blueprint.original_names[mat.id]
        if original then
            mat.material.state_name[3] = original.name
            mat.material.state_adj[3] = original.adj
            names_restored = names_restored + 1
        end
    end
    if names_restored > 0 then
        log('DETAIL', 'Restored the original powder names of '
            .. names_restored .. ' base materials.', 'NAMES')
    end
end

-- Destroy the blueprint memory cache so the scanner is forced to read new settings
_G.refinish_blueprint = nil

if not _G.refinish_ram_loaded then
    log('DETAIL', 'Materials already cleared. Skipping.')
    return
end

-- ==========================================
-- SCRIPT LOGIC
-- ==========================================
local raws = df.global.world.raws.inorganics.all
local count = 0

-- Iterate backwards to safely remove items from the vector without shifting targets
for i = #raws - 1, 0, -1 do
    if string.find(raws[i].id, "REFINISH_STEEL_") then
        raws[i]:delete() -- This frees the physical RAM
        raws:erase(i)    -- This removes it from the list
        count = count + 1
    end
end

if count > 0 then
    log('DETAIL', 'Cleared ' .. count .. ' custom materials. RAM safely'
        .. ' compressed.')
else
    log('DETAIL', 'No custom materials found to clear. Memory is pristine.')
end

-- Toggle state manager at the absolute end of the file
_G.refinish_ram_loaded = false