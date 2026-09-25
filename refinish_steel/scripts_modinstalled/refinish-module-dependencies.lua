--@ module = true
-- refinish-module-dependencies.lua
-- ==========================================
-- RM MODULE DEPENDENCY JIT CACHE
-- ==========================================
-- Provides O(1) lookups for DF arrays. Walks an array only
-- when explicitly requested by a module, then caches the
-- result in _G for the duration of the session.

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
-- SUBJECT is the correlation slot: the cache category a line is
-- about. Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'DEPENDENCIES'
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

local CACHE_BUILDERS = {
    inorganic = function()
        local map = {}
        for _, mat in ipairs(df.global.world.raws.inorganics.all) do
            map[mat.id] = true
        end
        return map
    end,
    
    color = function()
        local map = {}
        for _, c in ipairs(df.global.world.raws.descriptors.colors) do
            map[c.id] = true
        end
        return map
    end,
    
    workshop = function()
        local map = {}
        for _, ws in ipairs(df.global.world.raws.buildings.workshops) do
            map[ws.code] = true
        end
        return map
    end
}

-- ==========================================
-- PUBLIC API: CHECK DEPENDENCY
-- ==========================================
function check(category, id)
    -- Ensure the global cache container exists
    _G.refinish_dependency_cache = _G.refinish_dependency_cache or {}
    local cache = _G.refinish_dependency_cache
    
    -- JIT GATE: Build the map if it hasn't been built yet
    if not cache[category] then
        if CACHE_BUILDERS[category] then
            cache[category] = CACHE_BUILDERS[category]()
        else
            -- Unknown category requested: fail safe and log
            -- ERROR: a module asked for a category this cache cannot
            -- build, so its dependency reads as unmet.
            log('ERROR', 'Unknown category requested.', tostring(category))
            return false 
        end
    end
    
    -- O(1) Instant Lookup
    return cache[category][id] == true
end

return _ENV