-- refinish-shutdown.lua
-- ==========================================
-- REFINISH METAL: PIPELINE SHUTDOWN
-- ==========================================
-- Clears all injected assets from RAM. In AUTOSAVE mode, items
-- are washed to JSON first via refinish-save. In HOTSAVE mode,
-- the save step is skipped entirely; items carry their own
-- mat_index values.
--
-- Per-step timing is logged. Debug mode shows a telemetry prompt.
-- ==========================================

local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt
local THEME = reqscript('refinish-theme').get_current_theme()

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
-- SUBJECT is the correlation slot, here the step a line belongs to.
-- Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'SHUTDOWN'
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

local args = {...}
local force_silent = (args[1] == 'SILENT')

-- ---- HOW LOUD THE SUMMARY IS ----
-- Quiet is for faults and the few confirmations a player wants at a
-- glance, not every subsystem finishing. So the summary is COMPLETE
-- only when a player ran this by hand; DETAIL inside a save cycle,
-- where the cycle's own summary is the one that pops; INFO for the
-- other automatic runs (the ESC menu, a panel rebuild), which Normal
-- still shows.
local function summary_type()
    if not force_silent then return 'COMPLETE' end
    if _G.refinish_autosave_in_progress then return 'DETAIL' end
    return 'INFO'
end

local msg_setting = dfhack.persistent.getSiteData('refinish_config_msg')
if not msg_setting or msg_setting == "" then msg_setting = 'GUIDED' end

-- ==========================================
-- PROTOCOL CHECK
-- In HOTSAVE mode, refinish-save is skipped entirely.
-- Items are never washed: they carry their own mat_index.
-- The clear sequence runs regardless of protocol.
-- ==========================================
local save_protocol = dfhack.persistent.getSiteData('refinish_config_save_protocol')
if not save_protocol or save_protocol == "" then save_protocol = 'AUTOSAVE' end

local function execute_shutdown()
    log('DETAIL', 'Sequence initiated (silent: ' .. tostring(force_silent)
        .. ', protocol: ' .. save_protocol .. ').', 'SEQUENCE')

    local shutdown_clock = os.clock()
    local t = shutdown_clock

    -- ==========================================
    -- STEP 0: LEDGER SNAPSHOT
    -- ==========================================
    -- Records id to index for the array as it stands RIGHT NOW, which
    -- is the layout every object being saved is expressed in. Startup
    -- reads it back after the rebuild and moves each object by name.
    --
    -- FIRST, ahead of refinish-save, because the wash below rewrites
    -- objects and the clear below that dismantles the array. A
    -- snapshot taken after either one describes something no object is
    -- carrying. Measured the hard way in the hotsave branch: written
    -- between the two clears it recorded 63 materials instead of 441.
    --
    -- It belongs here rather than in the autosave script because both
    -- the autosave cycle and a plain quit reach the clear through this
    -- file. Hotsave is the exception, bypassing shutdown entirely, and
    -- carries its own copy of this at the top of its branch.
    --
    -- Why it cannot be left to startup's write alone: that one runs
    -- once per load, and the array changes after it. A just in time
    -- injection appends to it, and a hotsave cycle rebuilds it in a
    -- different order. Either one leaves startup's snapshot describing
    -- a layout nothing is using.
    -- ==========================================
    pcall(function()
        dfhack.script_environment('refinish-ledger').write()
    end)

    -- ==========================================
    -- STEP 1: SAVE PAYLOAD (Autosave protocol only)
    -- ==========================================
    local t_save = 0
    if save_protocol == 'AUTOSAVE' then
        dfhack.run_script('refinish-save')
        t_save = os.clock() - t
        log('DETAIL', string.format('Save payload complete (%.3fs).', t_save),
            'SAVE_PAYLOAD')
    else
        log('DETAIL', 'Hotsave mode; skipping refinish-save.', 'SAVE_PAYLOAD')
    end
    t = os.clock()

    -- ==========================================
    -- STEP 2: CLEAR ENTITY PERMISSIONS
    -- ==========================================
    dfhack.run_script('refinish-clear-entity')
    local t_clr_ent = os.clock() - t
    log('DETAIL', string.format('Entity permissions cleared (%.3fs).',
        t_clr_ent), 'CLEAR_ENTITY')
    t = os.clock()

    -- ==========================================
    -- STEP 3: CLEAR REACTIONS
    -- ==========================================
    dfhack.run_script('refinish-clear-reaction')
    local t_clr_rxn = os.clock() - t
    log('DETAIL', string.format('Reactions cleared (%.3fs).', t_clr_rxn),
        'CLEAR_REACTIONS')
    t = os.clock()

    -- ==========================================
    -- STEP 4: CLEAR MATERIALS
    -- ==========================================
    dfhack.run_script('refinish-clear')
    local t_clr_mat = os.clock() - t
    log('DETAIL', string.format('Materials cleared (%.3fs).', t_clr_mat),
        'CLEAR_MATERIALS')

    -- ==========================================
    -- STEP 5: CLEAR MODULE ASSETS
    -- ==========================================
    pcall(function()
        local mod_engine = dfhack.script_environment('refinish-module-engine')
        if mod_engine and mod_engine.clear_module_assets then
            mod_engine.clear_module_assets()
        end
    end)

    -- ==========================================
    -- FINALIZE SHUTDOWN TELEMETRY
    -- ==========================================
    local t_total = os.clock() - shutdown_clock

    -- Write to the autosave telemetry sub-table if it exists.
    -- During an autosave cycle, refinish-autosave calls us with
    -- 'SILENT' and reads these values back afterward.
    if _G.refinish_telemetry and _G.refinish_telemetry.last_save then
        _G.refinish_telemetry.last_save.t_save = t_save
        _G.refinish_telemetry.last_save.t_clr_ent = t_clr_ent
        _G.refinish_telemetry.last_save.t_clr_rxn = t_clr_rxn
        _G.refinish_telemetry.last_save.t_clr_mat = t_clr_mat
    end

    -- The summary carries every step's timing, so the steps above are
    -- DETAIL. How loud it is depends on who asked: see summary_type.
    log(summary_type(), string.format(
        'Shutdown complete (%.3fs); mod is dormant. Save:%.3f | Ent:%.3f | Rxn:%.3f | Mat:%.3f',
        t_total, t_save, t_clr_ent, t_clr_rxn, t_clr_mat), 'SEQUENCE')

    if force_silent then return end

    -- ==========================================
    -- USER-FACING PROMPTS
    -- ==========================================
    if msg_setting == 'PASSIVE' then
        dfhack.gui.showAnnouncement('Refinish Metal: Shutdown complete. Memory clear.', THEME.PRI, true)
    elseif msg_setting == 'DEBUG' then
        local report = string.format(
            "Shutdown Complete (%.3fs)\n\n" ..
            "--- CLEAR TIMING ---\n" ..
            "Save Payload:     %.3fs\n" ..
            "Clear Entities:   %.3fs\n" ..
            "Clear Reactions:  %.3fs\n" ..
            "Clear Materials:  %.3fs\n\n" ..
            "Protocol: %s\n" ..
            "It is now safe to manually save.",
            t_total, t_save, t_clr_ent, t_clr_rxn, t_clr_mat, save_protocol
        )
        RefinishPrompt{
            frame_h = 18,
            frame_w = 55,
            text = report,
            on_ok = function() end
        }:show()
    elseif msg_setting == 'GUIDED' then
        RefinishPrompt{
            frame_h = 10,
            text = "Shutdown sequence complete. It is now safe to manually save.",
            on_ok = function() end
        }:show()
    end
end

-- ==========================================
-- EXECUTION GATE
-- ==========================================
if force_silent or msg_setting == 'PASSIVE' or msg_setting == 'SILENT' then
    execute_shutdown()
else
    RefinishPrompt{
        text = "Preparing to initiate shutdown sequence. Proceed?",
        text_pen = THEME.PRI,
        on_yes = function() execute_shutdown() end,
        on_no = function()
            log('INFO', 'User canceled the manual shutdown prompt.', 'PROMPT')
        end
    }:show()
end