-- refinish-hard-shutdown.lua
-- ==========================================
-- HARD SHUTDOWN: Terminates jobs before wiping RAM
-- Use this ONLY when disabling the mod during active gameplay.
-- ==========================================
local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt
local THEME = reqscript('refinish-theme').get_current_theme()
local utils = require('utils')

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
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'HARD_SHUTDOWN'
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

local msg_setting = dfhack.persistent.getSiteData('refinish_config_msg')
if not msg_setting or msg_setting == "" then msg_setting = 'GUIDED' end

if not _G.refinish_active then 
    log('INFO', 'Aborted: the system is already inactive.')
    return 
end

local function execute_hard_shutdown()
    log('DETAIL', 'Sequence initiated (silent: ' .. tostring(force_silent)
        .. ').', 'SEQUENCE')

    local jobs_canceled = 0

    -- 1. Sweep and terminate orphaned jobs so the engine doesn't ghost them
    for _, job in utils.listpairs(df.global.world.jobs.list) do
        if job.job_type == df.job_type.CustomReaction and job.reaction_name then
            if string.find(job.reaction_name, "REFINISH_STEEL_RXN_") then
                dfhack.job.removeJob(job)
                jobs_canceled = jobs_canceled + 1
            end
        end
    end

    if jobs_canceled > 0 then
        log('WARNING', 'Canceled ' .. jobs_canceled
            .. ' active jobs to prevent ghosting.', 'JOB_SWEEP')
    end
    
    -- Export the count so the config UI can read it for its own debug prompt
    _G.refinish_last_jobs_canceled = jobs_canceled

    -- 2. Execute the standard RAM wipe, passing SILENT so we don't double-prompt the user
    log('DETAIL', 'Job sweep complete. Handing off to the standard'
        .. ' shutdown script.', 'JOB_SWEEP')
    dfhack.run_script('refinish-shutdown', 'SILENT')

    -- ---- THE SUMMARY ----
    -- Pops only when a player ran this by hand. The panels run it
    -- SILENT as the first half of a rebuild, and the startup that
    -- follows reports how that ended, so there it stays DETAIL.
    log(force_silent and 'DETAIL' or 'COMPLETE',
        'Hard shutdown complete; mod is dormant.', 'SEQUENCE')

    if force_silent then return end

    if msg_setting == 'PASSIVE' then
        dfhack.gui.showAnnouncement('Refinish Metal: Hard shutdown complete.', THEME.PRI, true)
    elseif msg_setting == 'GUIDED' or msg_setting == 'DEBUG' then
        local debug_txt = ""
        local h = 12
        if msg_setting == 'DEBUG' then
            debug_txt = "\n\n[DEBUG: " .. jobs_canceled .. " orphaned jobs intercepted and canceled.]"
            h = 16
        end
        RefinishPrompt{
            frame_h = h,
            text = "Hard shutdown sequence complete." .. debug_txt,
            -- text_pen defaults to THEME.PRI via prompt
            on_ok = function() end
        }:show()
    end
end

-- If forced silent, or user wants silence, skip the Yes/No warning
if force_silent or msg_setting == 'PASSIVE' or msg_setting == 'SILENT' then
    execute_hard_shutdown()
else
    RefinishPrompt{
        text = "WARNING!\n\nThis routine will cancel all Refinish Metal jobs before initiating shutdown.\n\nAre you sure you want to proceed?",
        text_pen = THEME.RISK_L,
        on_yes = function() execute_hard_shutdown() end,
        on_no = function() 
            log('INFO', 'User canceled the manual prompt.', 'PROMPT')
        end
    }:show()
end