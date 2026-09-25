--@ module = true
-- refinish-debug.lua
-- ==========================================
-- REFINISH METAL: STANDARDIZED DEBUG TRACE
-- ==========================================
-- Provides a shared dprint() function that any pipeline file can
-- import to write detailed trace output to a debug file. This
-- replaces the per-file VERBOSE_DEBUG boolean + debug_file handle
-- pattern that was copy-pasted into a few files.
--
-- USAGE (in any pipeline script):
--
--   local dbg = reqscript('refinish-debug')
--   local dprint = dbg.get_trace('INDEX_ENTITY')
--
--   dprint("Evaluating civ: " .. civ_name)
--   dprint("  Forge mood: " .. tostring(has_forge))
--
--   -- At the end of the script (optional, flushes immediately):
--   dbg.flush()
--
-- ACTIVATION:
--   Debug tracing is active when the user's invasiveness setting
--   is 'DEBUG' (refinish_config_msg). When not in debug mode,
--   dprint() is a no-op with zero overhead.
--
-- OUTPUT:
--   All trace output from all scripts goes to a single file:
--     refinish_trace_YYYYMMDD_HHMMSS.txt
--
--   The file is created on first dprint() call per session and
--   stays open until flush() is called or the session ends.
--   Each line is prefixed with the source tag so you can grep
--   for a specific script's output:
--
--     [INDEX_ENTITY] Evaluating civ: The Helpful Spears
--     [INDEX_ENTITY]   Forge mood: true
--     [BOOT] Pass 1; 47 reaction traits
--     [SCANNER] Mapped 261 reagents across 24 bases
--
-- DUMP INTEGRATION:
--   The dump system uses get_writer() for its own file handle
--   rather than sharing the trace file. This keeps trace output
--   (developer debugging) separate from dump output (user-facing
--   diagnostic). Both use the same naming convention.
-- ==========================================

-- ==========================================
-- FILE NAMING CONVENTION
-- ==========================================
-- All Refinish Metal output files follow this pattern:
--   refinish_<type>_<timestamp>.txt
--
-- Types:
--   trace    - Developer debug trace (dprint output)
--   dump     - Full diagnostic dump (user-facing)
--   log      - Event log export (from log panel)
--
-- Timestamp format: YYYYMMDD_HHMMSS
-- ==========================================

-- The active trace file handle (nil when tracing is off)
local trace_file = nil
local trace_active = nil  -- Cached result of the debug check

-- ==========================================
-- ACTIVATION CHECK
-- ==========================================
-- Returns true if debug tracing should be active.
-- Caches the result so we don't hit persistent storage
-- on every dprint() call.
-- ==========================================
local function is_trace_active()
    if trace_active ~= nil then return trace_active end
    local msg = dfhack.persistent.getSiteData('refinish_config_msg')
    trace_active = (msg == 'DEBUG')
    return trace_active
end

-- ==========================================
-- FILE MANAGEMENT
-- ==========================================
-- Opens the trace file on first use. All scripts share one file
-- per session. The file stays open until flush() is called.
-- ==========================================
local function ensure_file()
    if trace_file then return true end
    if not is_trace_active() then return false end

    local timestamp = os.date("%Y%m%d_%H%M%S")
    local path = string.format("refinish_trace_%s.txt", timestamp)
    trace_file = io.open(path, "w")
    if not trace_file then return false end

    trace_file:write("==================================================\n")
    trace_file:write("REFINISH METAL: DEBUG TRACE\n")
    trace_file:write(string.format("TIMESTAMP: %s\n", os.date("%Y-%m-%d %H:%M:%S")))
    trace_file:write(string.format("DF: %s  |  DFHack: %s  |  RM: %s\n",
        dfhack.getDFVersion(), dfhack.getDFHackVersion(), _G.refinish_version or "?"))
    trace_file:write("==================================================\n\n")
    return true
end


-- ==========================================
-- PUBLIC API
-- ==========================================

-- get_trace(tag)
-- Returns a dprint function bound to the given source tag.
-- If tracing is off, returns a no-op function (zero overhead).
--
-- Example:
--   local dprint = dbg.get_trace('INDEX_ENTITY')
--   dprint("Hello from index-entity")
--   -- Output: [INDEX_ENTITY] Hello from index-entity
function get_trace(tag)
    if not is_trace_active() then
        -- Return a no-op: zero overhead when debug is off.
        return function() end
    end

    return function(msg)
        if ensure_file() then
            trace_file:write(string.format("[%s] %s\n", tag, msg))
            trace_file:flush()
        end
    end
end

-- flush()
-- Closes the trace file handle. Call this at the end of a
-- pipeline cycle, or let it close naturally when DF exits.
function flush()
    if trace_file then
        trace_file:write("\n==================================================\n")
        trace_file:write("TRACE ENDED: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
        trace_file:close()
        trace_file = nil
    end
end

-- reset_cache()
-- Clears the cached activation state. Call this if the user
-- changes the msg_setting mid-session (e.g. from config panel).
function reset_cache()
    trace_active = nil
end

-- make_filename(dump_type)
-- Generates a consistent filename for any Refinish Metal output.
-- Uses the standard naming convention: refinish_<type>_<timestamp>.txt
function make_filename(dump_type)
    return string.format("refinish_%s_%s.txt", dump_type, os.date("%Y%m%d_%H%M%S"))
end

return _ENV