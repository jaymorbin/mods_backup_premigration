--@ module = true
-- making-fuel-menu-shaper.lua
-- ==========================================
-- HARDCODED FURNACE JOBS, FILED INTO THEIR HOME FOLDERS
-- ==========================================
-- MEASURED (menu probe, this session): the wood furnace task menu
-- is rebuilt per view into game.main_interface.building, and the
-- builder prepends MakeCharcoal and MakeAsh unconditionally - top
-- level and inside every category folder alike. The hardcoded path
-- reads no category data, so it cannot be taught; the list can only
-- be shaped after DF builds it.
--
-- POLICY: each hardcoded job is assigned a home folder below and
-- appears there and nowhere else. Vanilla capability is moved, not
-- lost: plain Make Charcoal still queues, from inside Make charcoal,
-- next to the module's own reactions.
--
-- THE NAME: each home job also gets module diction, written onto
-- the button's filter_str and info every frame (the rebuild wipes
-- them per view, same as the removals). filter_str is the search
-- text, so typing the new name finds the row regardless; whether
-- the DRAWN caption follows is exactly what this measures, because
-- the row is painted by a virtual text() method that may ignore
-- both strings. mstring is deliberately not written: on reaction
-- buttons it carries the reaction code, and feeding a nonempty one
-- to a hardcoded job's queue path is an unmeasured risk with no
-- payoff while the other two strings are on the table.
--
-- MECHANISM: interface_button_flag has no hide bit (checked in the
-- structures: LEFT and RIGHT only), so hiding means removal. The
-- button pointer is erased from all three vectors and deleted ONCE,
-- which is the engine's own cleanup done early, so nothing leaks
-- however often the menu rebuilds. The selection index is clamped
-- afterward so a highlight can never sit past the end of the list.
--
-- SAFETY GATE: the shaper acts only when the open menu visibly
-- belongs to this module (a MAKING_FUEL category folder or reaction
-- is present in the list). A bare vanilla furnace in a fort without
-- the module keeps its jobs at top level, untouched.
--
-- USAGE:
--   making-fuel-menu-shaper start | stop | status
-- Wire into making_fuel.lua next to the other watchers once the
-- behavior is confirmed in play.
-- ==========================================

local repeatUtil = require('repeat-util')

local REPEAT_KEY  = 'making_fuel_menu_shaper'
local POLL_FRAMES = 1   -- the menu rebuilds per view; shaping must ride it

-- Where each hardcoded job lives now. Edit here to re-home them.
-- 'NOWHERE' is a sentinel no folder token can ever equal, so these
-- jobs are removed from every view. They are not renamed but
-- REPLACED: CHAR_LOG and ASH_LOG are real module reactions carrying
-- the wanted names, descriptions, and adaptive yield. Measured on
-- the way here, for future use on other hardcoded jobs: the drawn
-- caption is built by the button's virtual text() method and
-- follows no writable string; info paints a cyan subtitle line
-- under the row; filter_str is the search text.
--
-- HOME doubles as the manager kill list: any job carried here is
-- also pruned from the New Work Order screen's template vectors,
-- so the replacement is total across both surfaces. Orders that
-- already exist keep dispatching, and the hijacker pays them; what
-- ends is the ability to create NEW vanilla ones.
local HOME = {
    [df.job_type.MakeCharcoal] = 'NOWHERE',
    [df.job_type.MakeAsh]      = 'NOWHERE',
}

-- Log once per state change, not once per frame.
local last_logged = nil

-- Manager-surface state: the stamp skips the template walk until the
-- engine rebuilds the list, and the latch keeps the log to one line.
local last_cwo_stamp = nil
local mgr_logged = false

-- ---- LOG IDENTITY, DECLARED HERE ----
-- RM core does not know this module exists and must never have to.
-- The onus is on the module to hand RM correct information, so the
-- system and subsystem are stated here rather than inferred anywhere
-- else.
--
-- Guarded reqscript: a bare top level one is a hard load time
-- dependency and has taken a module down before. Without it the log
-- falls back to the same grammar, unsanitised, and the script still
-- loads.
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'MENU_SHAPER'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed
-- by refinish-log. The identity is declared by the module, not
-- inferred anywhere: RM core does not know this module exists.
--
-- The panel filters on TYPE and nothing else, so each call site states
-- its own:
--   DETAIL   debugging material, shown in Debug only
--   INFO     what a player might check during play, Normal and up
--   YIELD    the module made something, Normal and up
--   faults, and the few confirmations a player wants at a glance
--   (COMPLETE, SYSTEM, ONLINE and the like), show in Quiet as well
-- TYPE comes first so no call site can drop it unnoticed: a nil TYPE
-- still renders, as UNTYPED, which shows at every Log Detail level
-- instead of being guessed at.
--
-- SUBJECT is the correlation slot: VIEW for a menu the player opened,
-- MANAGER for the work order list, POLL, START and STOP. The print at
-- the bottom answers the typed status command.
--
-- This replaces a log() that let refinish-log guess TYPE from the
-- words (read_type) unless a call site said otherwise, and printed to
-- the console when RM was not loaded.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else.
-- ==========================================
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

-- The jobtype field exists only on new_jobst buttons (the color
-- selector's field is named 'job', the categories carry none), so a
-- successful read identifies the class as well as the job.
local function hardcoded_job(btn)
    local ok, jt = pcall(function() return btn.jobtype end)
    if not ok then return nil end
    if HOME[jt] then return jt end
    return nil
end

-- True when the open menu belongs to this module: any RM category
-- folder or RM reaction in the list. This is the gate that keeps
-- the shaper's hands off a vanilla-only furnace.
local function ours(bi)
    for i = 0, #bi.button - 1 do
        local btn = bi.button[i]
        local ok, tok = pcall(function()
            return btn.custom_category_token
        end)
        if ok and tok and tostring(tok):find('MAKING_FUEL_CAT_', 1, true) == 1 then
            return true
        end
        local ok2, ms = pcall(function() return btn.mstring end)
        if ok2 and ms and tostring(ms):find('MAKING_FUEL_RXN_', 1, true) == 1 then
            return true
        end
    end
    return false
end

local function shape()
    if not dfhack.isMapLoaded() then return end
    if not _G.refinish_active then return end
    local ok, err = pcall(function()
        local bi = df.global.game.main_interface.building
        if #bi.button == 0 then return end
        if not ours(bi) then return end

        local token = tostring(bi.current_custom_category_token or '')

        -- Collect and erase in one pass per vector, back to front so
        -- surviving indices never shift underneath the walk. The same
        -- pointer sits in up to three vectors; the doomed set keys on
        -- the pointer's own identity string so it is deleted once.
        local doomed = {}
        local removed = 0
        for _, vec_name in ipairs({ 'button', 'filtered_button',
                                    'press_button' }) do
            local vec = bi[vec_name]
            for i = #vec - 1, 0, -1 do
                local btn = vec[i]
                local jt = hardcoded_job(btn)
                if jt and token ~= HOME[jt] then
                    doomed[tostring(btn)] = btn
                    vec:erase(i)
                    removed = removed + 1
                end
            end
        end
        for _, btn in pairs(doomed) do
            pcall(df.delete, btn)
        end

        -- A highlight past the end of a shortened list is a crash
        -- waiting on a keypress.
        if removed > 0 and bi.selected >= #bi.filtered_button then
            bi.selected = math.max(0, #bi.filtered_button - 1)
        end

        -- One line per place the player looks, not one per frame.
        if removed > 0 and last_logged ~= token then
            last_logged = token
            log('DETAIL', ('hardcoded furnace jobs hidden here (view %q); each'
                .. ' lives in its home folder now.'):format(token), 'VIEW')
        end
        -- ---- THE MANAGER'S CREATE SCREEN ----
        -- Same policy, second surface. The New Work Order list keeps
        -- its own template vectors (measured: 108,302 in the master,
        -- each builtin once, plus per-building slices), so the poof
        -- must reach here too. The stamp makes an idle open screen
        -- cost one string compare per frame: the walk runs only when
        -- the engine has rebuilt the list. The walk is full-length
        -- on rebuild, because absence can only be proven by looking
        -- everywhere; if this screen ever stutters while open, the
        -- stamp line below is the suspect and pruning on the open
        -- edge alone is the fallback.
        local cwo = df.global.game.main_interface.create_work_order
        if cwo.open then
            local stamp = tostring(#cwo.jminfo_master) .. '/'
                .. (#cwo.jminfo_master > 0
                    and tostring(cwo.jminfo_master[0]) or '-')
            if stamp ~= last_cwo_stamp then
                last_cwo_stamp = stamp
                local doomed, hits = {}, 0
                local function prune(vec)
                    for i = #vec - 1, 0, -1 do
                        local t = vec[i]
                        if HOME[t.job_type] then
                            doomed[tostring(t)] = t
                            vec:erase(i)
                            hits = hits + 1
                        end
                    end
                end
                prune(cwo.jminfo_master)
                for b = 0, #cwo.building - 1 do
                    prune(cwo.building[b].jminfo)
                end
                for _, t in pairs(doomed) do pcall(df.delete, t) end
                if hits > 0 and not mgr_logged then
                    mgr_logged = true
                    log('DETAIL', ('builtin furnace jobs pruned from the manager'
                        .. ' list (%d template entries).'):format(hits), 'MANAGER')
                end
            end
        end
    end)
    if not ok then
        log('ERROR', 'POLL ERROR: ' .. tostring(err), 'POLL')
        repeatUtil.cancel(REPEAT_KEY)
        -- WARNING: the shaper is off until the next start, so the
        -- hardcoded furnace jobs come back.
        log('WARNING', 'stopped after the error above so it is seen once, not'
            .. ' sixty times a second.', 'POLL')
    end
end

-- ==========================================
-- PUBLIC API
-- ==========================================
function start()
    last_logged = nil
    repeatUtil.scheduleEvery(REPEAT_KEY, POLL_FRAMES, 'frames', shape)
    log('DETAIL', 'active. Make Charcoal lives in Make charcoal; Make Ash in'
        .. ' Make ash; neither appears anywhere else.', 'START')
end

function stop()
    repeatUtil.cancel(REPEAT_KEY)
    log('DETAIL', 'stopped. DF rebuilds the menu on the next view change and'
        .. ' the hardcoded jobs return with it.', 'STOP')
end

-- ==========================================
-- STANDALONE DISPATCH (for the quick test, pre-wiring)
-- ==========================================
local args = {...}
if args[1] == 'start' then
    start()
elseif args[1] == 'stop' then
    stop()
elseif args[1] == 'status' then
    print('menu shaper: edit HOME at the top to re-home a job;'
        .. ' start/stop to toggle.')
end

return _ENV