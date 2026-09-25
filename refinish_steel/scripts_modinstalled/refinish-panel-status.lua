--@ module = true
-- refinish-panel-status.lua
-- ==========================================
-- SYSTEM TELEMETRY PANEL
-- ==========================================
-- All value tokens use FUNCTIONS instead of static strings.
-- The List widget calls these on every render frame, so the
-- display is always current without ever calling setChoices().
-- No polling loop needed. No scroll disturbance. No scrollbar
-- jumps.
--
-- SECTION ORDER (state first, benchmarks last):
--   1. SYSTEM          - Version, protocol
--   2. PIPELINE STATE  - Live state flags
--   3. MONITORS        - Background loop heartbeats, autosave timer
--   4. SESSION         - Log buffer, config mode
--   5. BASELINE        - Vanilla game state counts
--   6. BLUEPRINT       - Scanner output counts
--   7. INJECTED        - Live RAM injection counts
--   8. BOOT TIMING     - Map-load cache building breakdown
--   9. STARTUP TIMING  - Last pipeline rebuild breakdown
--  10. LAST SAVE CYCLE - Most recent autosave cycle breakdown
--  11. LOOP COST       - Live cost of each scheduled loop, from
--                        refinish-tool-profiler's live mode
-- ==========================================

local gui = require('gui')
local widgets = require('gui.widgets')

-- ---- LOOP COST LAYOUT ----
-- A table under column headings. The name column fills the pane: 2
-- indent + 37 name, then three figures 9 wide with a space before each,
-- is 69, the width the log panel beside it wraps to, clear of the
-- scrollbar. Longer names end in a tilde.
local LOOP_KEY_W = 37
local LOOP_ROW_FMT = "  %-" .. LOOP_KEY_W .. "s %9s %9s %9s"
-- Pen thresholds, in ms per second: warm from 2 percent of the
-- machine's time, hot from 10 percent.
local WARM_MS_S, HOT_MS_S = 20, 100

RefinishPanelStatus = defclass(RefinishPanelStatus, widgets.Panel)
RefinishPanelStatus.ATTRS = {
    theme = DEFAULT_NIL,
}

function RefinishPanelStatus:init()
    self.theme = self.theme or reqscript('refinish-theme').get_current_theme()

    -- Build choices ONCE. Values are function tokens that the
    -- List widget evaluates fresh on every render frame. The one
    -- exception is the loop rows at the end, whose number follows the
    -- profiler; onRenderFrame rebuilds when it changes.
    self.loop_rows = 0
    local choices = self:build_status_lines()

    self.list_widget = widgets.List{
        frame = {t = 2, l = 0, r = 0, b = 0},
        choices = choices,
        cursor_pen = self.theme.PRI,
    }

    self:addviews{
        widgets.Label{ frame = {t = 0, l = 0}, text = "SYSTEM TELEMETRY", text_pen = self.theme.PRI },
        self.list_widget,
    }
end

-- ==========================================
-- DATA BUILDER
-- ==========================================
-- Builds the choices array ONCE. Static labels are plain strings.
-- Dynamic values are wrapped in functions so the List re-evaluates
-- them on every draw call. This gives us live updates with zero
-- polling overhead and zero scroll disturbance.
-- ==========================================
function RefinishPanelStatus:build_status_lines()
    local choices = {}
    local PRI = self.theme.PRI
    local SEC = self.theme.SEC
    local HDR = self.theme.NEUTRAL_B

    -- ==========================================
    -- DISPLAY HELPERS
    -- ==========================================
    -- Each helper inserts one choice into the array.
    -- Value tokens use functions for live data.
    -- ==========================================

    -- Section header
    local function hdr(txt)
        table.insert(choices, { text = {{ text = txt, pen = HDR }} })
    end

    -- Single value row: static label, dynamic value
    local function row(label, value_fn)
        local lbl_str = string.format("  %-18s", label)
        table.insert(choices, { text = {
            { text = lbl_str, pen = SEC },
            { text = value_fn, pen = PRI }
        }})
    end

    -- Two-column row: static labels, dynamic values
    local function pair(lbl_a, val_fn_a, lbl_b, val_fn_b)
        local la = string.format("  %-18s", lbl_a)
        local lb = string.format("%-18s", lbl_b)
        table.insert(choices, { text = {
            { text = la, pen = SEC },
            { text = function() return string.format("%-14s", val_fn_a()) end, pen = PRI },
            { text = lb, pen = SEC },
            { text = val_fn_b, pen = PRI }
        }})
    end

    -- Timing row: shows seconds or "-" for zero
    local function trow(label, time_fn)
        local lbl_str = string.format("  %-18s", label)
        table.insert(choices, { text = {
            { text = lbl_str, pen = SEC },
            { text = function()
                local s = time_fn()
                if not s or s == 0 then return "-" end
                return string.format("%.3fs", s)
            end, pen = function()
                local s = time_fn()
                return (s and s > 0) and PRI or SEC
            end }
        }})
    end

    -- Timing pair: two timing values side by side
    local function tpair(lbl_a, time_fn_a, lbl_b, time_fn_b)
        local la = string.format("  %-18s", lbl_a)
        local lb = string.format("%-18s", lbl_b)
        local function tfmt(fn)
            local s = fn()
            if not s or s == 0 then return "-" end
            return string.format("%.3fs", s)
        end
        local function tpen(fn)
            local s = fn()
            return (s and s > 0) and PRI or SEC
        end
        table.insert(choices, { text = {
            { text = la, pen = SEC },
            { text = function() return string.format("%-14s", tfmt(time_fn_a)) end, pen = function() return tpen(time_fn_a) end },
            { text = lb, pen = SEC },
            { text = function() return tfmt(time_fn_b) end, pen = function() return tpen(time_fn_b) end }
        }})
    end

    local function gap()
        table.insert(choices, { text = "" })
    end

    -- Formatters that return functions
    local function bfmt(getter)
        return function()
            local val = getter()
            if val == true then return "Yes"
            elseif val == false then return "No"
            else return "-" end
        end
    end

    -- Safe telemetry sub-table accessors
    local function tel()     return _G.refinish_telemetry or {} end
    local function boot()    return tel().boot or {} end
    local function startup() return tel().startup or {} end
    local function lsave()   return tel().last_save or {} end
    local function counts()  return tel().counts or {} end


    -- ==========================================
    -- 1. SYSTEM
    -- ==========================================
    hdr("SYSTEM")
    pair("Refinish Metal:", function() return _G.refinish_version or "?" end,
         "DFHack:",         function() return dfhack.getDFHackVersion() end)
    row("Dwarf Fortress:", function() return dfhack.getDFVersion() end)
    row("Save Protocol:", function()
        local p = "AUTOSAVE"
        pcall(function()
            local v = dfhack.persistent.getSiteData('refinish_config_save_protocol')
            if v and v ~= "" then p = v end
        end)
        return p
    end)
    gap()

    -- ==========================================
    -- 2. PIPELINE STATE
    -- ==========================================
    hdr("PIPELINE STATE")
    pair("Active:",      bfmt(function() return _G.refinish_active end),
         "Menu Lock:",   bfmt(function() return _G.refinish_menu_locked end))
    pair("Materials:",   bfmt(function() return _G.refinish_ram_loaded end),
         "Reactions:",   bfmt(function() return _G.refinish_reactions_loaded end))
    pair("Permissions:", bfmt(function() return _G.refinish_entity_loaded end),
         "Payload:",     bfmt(function() return _G.refinish_data_loaded end))
    gap()

    -- ==========================================
    -- 3. MONITORS
    -- ==========================================
    hdr("MONITORS")
    row("UI Tripwire:", function() return _G.refinish_last_ui_ping or "Inactive" end)
    row("Calendar Loop:", function() return _G.refinish_last_cal_ping or "Inactive" end)
    row("JIT Watcher:", function() return _G.refinish_last_watch_ping or "Inactive" end)
    pair("Autosave In:", bfmt(function() return _G.refinish_autosave_in_progress end),
         "Interval:", function()
            local v = "SEASONAL"
            pcall(function()
                local s = dfhack.persistent.getSiteData('refinish_config_interval')
                if s and s ~= "" then v = s end
            end)
            return v
         end)
    row("Last Save:", function()
        if not _G.refinish_last_real_save then return "N/A" end
        local elapsed = os.time() - _G.refinish_last_real_save
        if elapsed < 60 then return elapsed .. "s ago"
        elseif elapsed < 3600 then return math.floor(elapsed / 60) .. "m ago"
        else return math.floor(elapsed / 3600) .. "h " .. math.floor((elapsed % 3600) / 60) .. "m ago" end
    end)
    gap()

    -- ==========================================
    -- 4. SESSION
    -- ==========================================
    hdr("SESSION")
    row("Log Buffer:", function()
        local n = _G.refinish_log and #_G.refinish_log or 0
        -- The cap refinish_steel trims the buffer to.
        return n .. " / 15000"
    end)
    pair("Verbosity:", function()
        local v = "GUIDED"
        pcall(function()
            local s = dfhack.persistent.getSiteData('refinish_config_msg')
            if s and s ~= "" then v = s end
        end)
        return v
    end, "Finishes:", function()
        local v = "ON"
        pcall(function()
            local s = dfhack.persistent.getSiteData('refinish_config_perf')
            if s and s ~= "" then v = s end
        end)
        return v
    end)
    gap()

    -- ==========================================
    -- 5. BASELINE
    -- ==========================================
    hdr("BASELINE")
    pair("Inorganics:", function() return counts().base_inorganics or 0 end,
         "Reactions:",  function() return counts().base_reactions or 0 end)
    pair("Valid Metals:", function() return counts().valid_metals or 0 end,
         "Known Metals:", function() return counts().known_metals or 0 end)
    pair("Rxn Traits:", function() return counts().reaction_traits or 0 end,
         "Civ Techs:",  function() return counts().civ_techs or 0 end)
    gap()

    -- ==========================================
    -- 6. BLUEPRINT
    -- ==========================================
    hdr("BLUEPRINT")
    pair("Active Bases:", function() return counts().active_bases or 0 end,
         "Materials:",    function() return counts().bp_materials or 0 end)
    pair("Reactions:",    function() return counts().bp_reactions or 0 end,
         "Categories:",   function() return counts().bp_categories or 0 end)
    gap()

    -- ==========================================
    -- 7. INJECTED
    -- ==========================================
    hdr("INJECTED")
    pair("Materials:",   function() return counts().inj_materials or 0 end,
         "Reactions:",   function() return counts().inj_reactions or 0 end)
    pair("Categories:",  function() return counts().inj_categories or 0 end,
         "Permissions:", function() return counts().inj_permissions or 0 end)
    row("Civs Permitted:", function() return counts().civs_unlocked or 0 end)
    gap()

    -- ==========================================
    -- 8. BOOT TIMING
    -- ==========================================
    hdr("BOOT TIMING")
    trow("Total:", function() return boot().t_total end)
    tpair("Modules:",   function() return boot().t_modules end,
          "Evaluators:", function() return boot().t_eval end)
    tpair("Boot Scan:", function() return boot().t_boot_scan end,
          "State Check:", function() return boot().t_state end)
    gap()

    -- ==========================================
    -- 9. STARTUP TIMING
    -- ==========================================
    hdr("STARTUP TIMING")
    trow("Total:", function() return startup().t_total end)
    tpair("Ghost Sweep:", function() return startup().t_sweep end,
          "Modules:",     function() return startup().t_modules end)
    tpair("Scan:",        function() return startup().t_scan end,
          "Index Mats:",  function() return startup().t_idx_mat end)
    tpair("Index Rxns:",  function() return startup().t_idx_rxn end,
          "Index Ents:",  function() return startup().t_idx_ent end)
    trow("Payload Load:", function() return startup().t_load end)
    gap()

    -- ==========================================
    -- 10. LAST SAVE CYCLE
    -- ==========================================
    hdr("LAST SAVE CYCLE")
    pair("Protocol:", function() return lsave().protocol or "N/A" end,
         "Timestamp:", function() return lsave().timestamp or "N/A" end)
    trow("Active Time:", function() return lsave().t_active end)
    tpair("Clear Ents:", function() return lsave().t_clr_ent end,
          "Clear Rxns:", function() return lsave().t_clr_rxn end)
    tpair("Clear Mats:", function() return lsave().t_clr_mat end,
          "Save JSON:",  function() return lsave().t_save end)
    tpair("Engine Save:", function() return lsave().t_engine end,
          "Restore:",     function() return lsave().t_restore end)
    pair("Items:", function() return lsave().items or 0 end,
         "Buildings:", function() return lsave().buildings or 0 end)
    row("Constructions:", function() return lsave().constructions or 0 end)
    gap()

    -- ==========================================
    -- 11. LOOP COST
    -- ==========================================
    -- What each scheduled loop costs, from refinish-tool-profiler's
    -- live mode, which refinish_steel starts at map load. Milliseconds
    -- per second of wall time over the last minute, so 10 ms/s is one
    -- percent of the machine's time spent in that loop.
    --
    -- Every scheduled loop in the session is here, RM's, its modules'
    -- and any other mod's, so a slow game shows whose loop it is. A
    -- repeat-util loop is named by its key, any other by the file and
    -- line that defined it (t:file:line). The Timing row says
    -- "repeat-util loops" instead only if the interception that finds
    -- the others could not be installed.
    --
    -- ONE ROW PER LOOP, as many as ran in the window, costliest first.
    -- self.loop_rows says how many to build; onRenderFrame below keeps
    -- it matched to the profiler and rebuilds the list when it changes.
    -- Every row reads the same answer, asked for at most once a second
    -- (see loop_view below).
    local panel = self
    local function heat(ms_s)
        if ms_s >= HOT_MS_S then return panel.theme.RISK_M end
        if ms_s >= WARM_MS_S then return panel.theme.RISK_L end
        return PRI
    end

    hdr("LOOP COST")
    row("Timing:", function()
        local v = panel:loop_view()
        if not v then return "Off" end
        if v.window_s <= 0 then return "Starting" end
        return string.format("%s, last %ds",
            v.all and "every loop" or "repeat-util loops",
            math.floor(v.window_s + 0.5))
    end)
    table.insert(choices, { text = {
        { text = string.format("  %-18s", "Total:"), pen = SEC },
        { text = function()
            local v = panel:loop_view()
            if not v or v.window_s <= 0 then return "-" end
            -- 1000 ms of wall time a second, so ms/sec over ten is the
            -- percentage of the machine's time these loops take.
            return string.format("%.1f ms/sec, %.1f%% of the time, %d loop(s)",
                v.total_ms_s, v.total_ms_s / 10, #v.rows)
        end, pen = function()
            local v = panel:loop_view()
            return (v and v.window_s > 0) and heat(v.total_ms_s) or SEC
        end },
    }})
    -- ---- COLUMN HEADINGS ----
    -- What each figure is, over the columns it heads. Shown only while
    -- there are rows under it.
    --   ms/sec     milliseconds of wall time the loop took per second
    --   calls/sec  how often it ran
    --   ms/call    what one run cost, on average
    -- A loop is named by its repeat-util key, or by the file and line
    -- that defined it (t:file:line).
    if (self.loop_rows or 0) > 0 then
        table.insert(choices, { text = {
            { text = string.format(LOOP_ROW_FMT, "Loop", "ms/sec", "calls/sec",
                "ms/call"), pen = HDR },
        }})
    end
    for i = 1, self.loop_rows or 0 do
        local function r_at()
            local v = panel:loop_view()
            return v and v.rows[i]
        end
        table.insert(choices, { text = {
            { text = function()
                local r = r_at()
                if not r then return "" end
                local k = tostring(r.key)
                if #k > LOOP_KEY_W then k = k:sub(1, LOOP_KEY_W - 1) .. "~" end
                -- The name and the figures are two tokens so they can
                -- take different pens, cut from one format so they stay
                -- under their headings: the name is its first 40
                -- characters, the figures the rest.
                return string.format(LOOP_ROW_FMT, k, "", "", ""):sub(1, LOOP_KEY_W + 3)
            end, pen = SEC },
            { text = function()
                local r = r_at()
                if not r then return "" end
                return string.format(LOOP_ROW_FMT, "",
                    string.format("%.1f", r.ms_s),
                    string.format("%.1f", r.calls_s),
                    string.format("%.2f", r.avg_ms)):sub(LOOP_KEY_W + 4)
            end, pen = function()
                local r = r_at()
                return r and heat(r.ms_s) or SEC
            end },
        }})
    end

    return choices
end

-- ==========================================
-- LOOP COST: THE PROFILER'S WINDOW, ONCE A SECOND
-- ==========================================
-- The List redraws every frame and every loop row asks for the view,
-- so the answer is held for a second and shared. reqscript is guarded:
-- a profiler that fails to load leaves the section reading Off.
function RefinishPanelStatus:loop_view()
    local now = dfhack.getTickCount()
    if self.loop_at and now - self.loop_at < 1000 then
        return self.loop_cache
    end
    self.loop_at = now
    self.loop_cache = nil
    if self.prof == nil then
        local ok, m = pcall(reqscript, 'refinish-tool-profiler')
        self.prof = ok and m or false
    end
    if self.prof and self.prof.live_view then
        local ok, v = pcall(self.prof.live_view)
        if ok then self.loop_cache = v end
    end
    return self.loop_cache
end

-- ==========================================
-- ONE ROW PER LOOP, HOWEVER MANY THERE ARE
-- ==========================================
-- Every other row is built once and reads live values through its
-- function tokens. The loop rows cannot all be built in advance,
-- because how many there are changes as loops start and stop. So each
-- frame compares the profiler's count, which loop_view holds for a
-- second, with the rows built, and rebuilds the list when they differ.
-- The cursor and the scroll position are put back where they were:
-- the loop rows are the last section, so nothing above them moves.
function RefinishPanelStatus:onRenderFrame(dc, rect)
    local v = self:loop_view()
    local n = v and #v.rows or 0
    if n ~= self.loop_rows then
        self.loop_rows = n
        local sel = self.list_widget:getSelected()
        local top = self.list_widget.page_top
        self.list_widget:setChoices(self:build_status_lines())
        local count = #self.list_widget:getChoices()
        if sel and sel >= 1 and sel <= count then
            self.list_widget:setSelected(sel)
        end
        if top and top >= 1 and top <= count then
            self.list_widget.page_top = top
        end
    end
    RefinishPanelStatus.super.onRenderFrame(self, dc, rect)
end

return _ENV