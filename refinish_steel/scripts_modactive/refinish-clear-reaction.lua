-- refinish-clear-reaction.lua
-- Removes dynamically generated reactions from global memory. Every
-- line is DETAIL: the shutdown or save cycle that calls this reports
-- the outcome.

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
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'CLEAR_REACTIONS'
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
if _G.refinish_reactions_loaded == nil or _G.refinish_reactions_loaded == true then
    local actually_loaded = false
    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        if string.find(rxn.code, "REFINISH_STEEL_RXN_") then
            actually_loaded = true
            break
        end
    end
    if not actually_loaded then _G.refinish_reactions_loaded = false end
end

if not _G.refinish_reactions_loaded then
    log('DETAIL', 'Reactions already cleared. Skipping.')
    return
end

local reactions_array = df.global.world.raws.reactions.reactions
local scrubbed_rxns = 0

-- LIFO loop prevents array index shifting
for i = #reactions_array - 1, 0, -1 do
    local rxn = reactions_array[i]
    if string.find(rxn.code, "REFINISH_STEEL_") then
        rxn:delete() -- Free the C++ memory allocation
        reactions_array:erase(i) -- Remove the pointer from the global vector
        scrubbed_rxns = scrubbed_rxns + 1
    end
end

if scrubbed_rxns > 0 then
    log('DETAIL', 'Excised ' .. scrubbed_rxns .. ' injected reactions from RAM.')
else
    log('DETAIL', 'No injected reactions found in RAM.')
end

-- Add this to the bottom of refinish-clear-reaction.lua
local cat_array = df.global.world.raws.reactions.reaction_categories
local scrubbed_cats = 0

for i = #cat_array - 1, 0, -1 do
    local cat = cat_array[i]
    if string.find(cat.id, "REFINISH_STEEL_CAT_") then
        cat:delete()
        cat_array:erase(i)
        scrubbed_cats = scrubbed_cats + 1
    end
end

if scrubbed_cats > 0 then
    log('DETAIL', 'Excised ' .. scrubbed_cats .. ' UI categories.')
end

_G.refinish_reactions_loaded = false