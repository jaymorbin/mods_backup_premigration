--@ module = true
-- ==========================================
-- REFINISH STEEL: VALID BASE METAL EVALUATOR (WRAPPER)
-- Purpose: Legacy wrapper to maintain compatibility with other scripts.
-- Forwards the request to the new unified boot scanner.
-- ==========================================

-- The auto-scan below is a convenience for callers that arrive
-- before the cache is warm (refinish-panel-metals:130,
-- refinish-panel-civs:238 and :495, refinish-scan:107).
--
-- It is only safe once the module pipeline has run, because
-- run_unified_scan reads world.raws.inorganics.all. Scanning before
-- module injection produces valid_bases, known_metals and civ_tech
-- with no module content, caches them, and every later consumer
-- silently inherits the short version for the rest of the session.
-- The panels are reachable before unpause, so this is a real path.
--
-- "The pipeline has run" is true in either of two ways: it injected
-- and set the flag (refinish-module-engine:772), or it returned
-- early at :627 because no module responded, leaving the registry
-- empty. Testing only the flag would permanently block the scan for
-- anyone with no modules installed.
local function pipeline_has_run()
    if _G.refinish_modules_injected then return true end
    local reg = _G.refinish_module_registry
    return reg ~= nil and next(reg) == nil
end

function get_valid_bases(allow_divine, allow_mythical, force_recalc)
    if (not _G.refinish_valid_bases or force_recalc) and pipeline_has_run() then
        reqscript('refinish-boot').run_unified_scan(allow_divine, allow_mythical)
    end
    return _G.refinish_valid_bases
end

return _ENV