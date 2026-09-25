--@ module = true
-- refinish-panel-modules.lua
-- ==========================================
-- MODULE SETTINGS PAGES
-- ==========================================
-- The left pane's pages after Civs. Draws a section for every module
-- that registered settings with refinish-module-config, one row per
-- setting, from the specs alone: this file knows no module by name.
--
--   Enter or click     the next option
--   Shift-click        the previous option
--
-- ---- ONE LAYOUT FOR EVERY PAGE ----
-- Settings on the left, the tooltip column on the right. However many
-- modules share a page, they share its one tooltip column, and the
-- column has the page's whole height to itself, so a long description
-- is never boxed into a scroll area it cannot be read in.
--
-- ---- AS MANY PAGES AS THE MODULES NEED ----
-- The HUD asks build_pages() for its pages. sheets() packs the modules
-- onto pages in order, a whole section at a time: a module that does
-- not fit in what is left of a page starts the next one, so a section
-- is never split while it could have fitted on a page of its own. Only
-- a section taller than an entire page is split, across as many pages
-- as it needs, its heading repeated on each. Nothing scrolls.
--
-- ---- THE TOOLTIP COLUMN ----
-- Describes the setting under the mouse, the way the config page's
-- tooltips do, and the one under the cursor when the mouse is
-- elsewhere, so the keyboard gets the same help: the description, when
-- a change takes effect, and the default.
--
-- Values are read through refinish-module-config on every draw, so a
-- change shows at once, and a change a module refused simply leaves
-- the old value showing, with the reason in the log.
-- ==========================================

local widgets = require('gui.widgets')

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- For the one thing this page reports itself: a sheet taller than the
-- list it is drawn in (see onRenderFrame).
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'HUD_MODULES'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

local function log(typ, msg, subject)
    if not _G.refinish_log_event then return end
    local line
    if rlog then
        line = rlog.compose(LOG_SYS, LOG_SUB, subject, typ, msg)
    else
        line = string.format('%s %s %s %s | %s', LOG_SYS, LOG_SUB,
            tostring(subject or '-'), tostring(typ or 'UNTYPED'),
            tostring(msg))
    end
    _G.refinish_log_event(line)
end

RefinishPanelModules = defclass(RefinishPanelModules, widgets.Panel)
RefinishPanelModules.ATTRS = {
    theme = DEFAULT_NIL,
    -- This page's share of the modules, from sheets(). nil draws the
    -- first sheet, for anything that builds a page on its own.
    sheet = DEFAULT_NIL,
    sheet_no = 1,
    sheet_count = 1,
    -- Set when laying out the pages failed; the page shows it.
    sheet_error = DEFAULT_NIL,
}

-- ==========================================
-- LAYOUT
-- ==========================================
-- The list column holds a label and a value side by side: 2 indent +
-- 22 label (the registry's LABEL limit) + 1 space + 14 value (its
-- OPTION_LABEL limit) = 39, inside 42. The tooltip column takes the
-- rest of the pane's width and all of its height below its heading.
local LIST_W = 42

-- Rows a page spends above its list: the title, then a blank line.
local HEAD_ROWS = 2

-- The page height the HUD passes to sheets(). This is only the
-- fallback for a caller that passes none: refinish-hud works the real
-- height out from its own window, and that is the one that counts.
local DEFAULT_PAGE_ROWS = 49

-- What the page says under each kind of change. restart adds the
-- module's own note on what starts or stops. 'now' promises no more
-- than no reload: the module reads the value at its next use, which the
-- module's own description can make precise.
local WHEN = {
    now     = 'Takes effect without a reload.',
    restart = 'Takes effect on the spot.',
    reload  = 'Takes effect the next time this fort loads.',
}

-- ==========================================
-- SHEETS: WHICH MODULES GO ON WHICH PAGE
-- ==========================================
-- Returns a list of sheets, one per page. A sheet is a list of
-- sections, each { block, from, to, cont }: the module (block), the
-- range of its settings on this page, and whether this part continues
-- a section begun on an earlier page. Never empty: with no modules
-- there is one empty sheet, so the page can say so.
--
-- page_rows is the height of a page. Every section costs its heading
-- plus its settings, and a blank line before it when it is not the
-- first on its page. A refused module costs its heading and one line
-- saying so. Refused modules come first, so a broken spec is the first
-- thing seen, then the modules in title order.
function sheets(page_rows)
    local rows = (page_rows or DEFAULT_PAGE_ROWS) - HEAD_ROWS
    -- A page too short to hold a heading and one setting still gets
    -- that much, so a mistake in the height cannot loop forever.
    if rows < 2 then rows = 2 end

    local ok, cfg = pcall(reqscript, 'refinish-module-config')
    local blocks = {}
    if ok and cfg then
        for _, r in ipairs(cfg.refused()) do
            blocks[#blocks + 1] = { refused = r, n = 1 }
        end
        for _, spec in ipairs(cfg.list()) do
            blocks[#blocks + 1] = { spec = spec, n = #spec.settings }
        end
    end

    local out, cur, used = {}, {}, 0
    local function close()
        if #cur > 0 then out[#out + 1] = cur end
        cur, used = {}, 0
    end
    for _, b in ipairs(blocks) do
        local need = 1 + b.n
        local gap = (#cur > 0) and 1 or 0
        if used + gap + need <= rows then
            -- Fits in what is left of this page.
            cur[#cur + 1] = { block = b, from = 1, to = b.n }
            used = used + gap + need
        elseif need <= rows then
            -- Fits on a page of its own: start the next page with it
            -- rather than split it.
            close()
            cur[1] = { block = b, from = 1, to = b.n }
            used = need
        else
            -- Taller than a whole page. Split it, starting on a fresh
            -- page, a heading and as many settings as fit on each. The
            -- last part stays open, so the modules after it can fill
            -- the rest of its page.
            close()
            local i = 1
            while i <= b.n do
                local take = math.min(rows - 1, b.n - i + 1)
                cur = { { block = b, from = i, to = i + take - 1, cont = i > 1 } }
                used = 1 + take
                i = i + take
                if i <= b.n then close() end
            end
        end
    end
    close()
    if #out == 0 then out[1] = {} end
    return out
end

-- The pages the HUD shows, one per sheet, in order. page_rows is the
-- height of a left pane page, which the HUD works out from its window.
-- Laying out failing still gives one page, saying why.
function build_pages(theme, page_rows)
    local ok, list = pcall(sheets, page_rows)
    if not ok then
        log('ERROR', 'Could not lay out the module settings pages: '
            .. tostring(list), 'SHEETS')
        return { RefinishPanelModules{ theme = theme, sheet = {},
                                       sheet_error = tostring(list) } }
    end
    local pages = {}
    for i, sheet in ipairs(list) do
        pages[i] = RefinishPanelModules{ theme = theme, sheet = sheet,
                                         sheet_no = i, sheet_count = #list }
    end
    return pages
end

-- ==========================================
-- THE PAGE
-- ==========================================
function RefinishPanelModules:init()
    self.theme = self.theme or reqscript('refinish-theme').get_current_theme()

    -- Guarded: a registry that fails to load leaves this page saying
    -- so, rather than taking the whole HUD down with it.
    local ok, cfg = pcall(reqscript, 'refinish-module-config')
    self.cfg = ok and cfg or nil
    if self.sheet == nil then
        local ok_s, list = pcall(sheets, nil)
        self.sheet = ok_s and list[1] or {}
    end

    self.list_widget = widgets.List{
        frame = {t = HEAD_ROWS, l = 0, w = LIST_W, b = 0},
        choices = self:build_rows(),
        cursor_pen = self.theme.PRI,
        on_submit  = function(_, choice) self:step(choice, 1) end,
        on_submit2 = function(_, choice) self:step(choice, -1) end,
    }

    -- ---- THE TOOLTIP COLUMN, FULL HEIGHT ----
    -- Pinned to the bottom of the pane with auto_height off, so the
    -- column is the page's whole height below its heading whatever the
    -- text. With auto_height on, a Label sizes itself to the text it
    -- holds when the layout pass begins, and WrappedLabel only rewraps
    -- the new text after that, so each tooltip was drawn in the height
    -- of the one before it: a long one after a short one got a small
    -- box and a scroll bar, which cannot be used, because moving the
    -- mouse onto the bar moves it off the setting and the tooltip goes.
    self.info = widgets.WrappedLabel{
        frame = {t = HEAD_ROWS, l = 0, r = 0, b = 0},
        auto_height = false,
        text_to_wrap = function() return self:info_text() end,
        text_pen = self.theme.SEC,
    }

    -- One of several pages says which.
    local title = "MODULE SETTINGS"
    if (self.sheet_count or 1) > 1 then
        title = string.format("%s  %d/%d", title, self.sheet_no, self.sheet_count)
    end

    self:addviews{
        widgets.Label{ frame = {t = 0, l = 0}, text = title,
            text_pen = self.theme.PRI },
        self.list_widget,
        widgets.Panel{
            frame = {t = 0, l = LIST_W + 2, r = 0, b = 0},
            subviews = {
                widgets.Label{ frame = {t = 0, l = 0}, text = "INFORMATION",
                    text_pen = self.theme.PRI },
                self.info,
            },
        },
    }
end

-- ==========================================
-- ROWS
-- ==========================================
-- This page's sections, each a heading then its settings in the order
-- the module declared them. Each setting row carries its module and
-- setting, so Enter knows what to change; a heading carries its module
-- only.
function RefinishPanelModules:build_rows()
    local rows = {}
    if self.sheet_error then
        rows[1] = { text = {{ text = "  The settings pages could not be laid out.",
            pen = self.theme.RISK_M }} }
        return rows
    end
    if #self.sheet == 0 then
        rows[1] = { text = {{ text = "  No module has asked for settings.",
            pen = self.theme.SEC }} }
        return rows
    end
    local cfg = self.cfg
    for _, sec in ipairs(self.sheet) do
        if #rows > 0 then rows[#rows + 1] = { text = "" } end
        local b = sec.block
        if b.refused then
            -- A module whose spec RM refused gets its heading and the
            -- reason, in the warning colour, so a missing section is
            -- never a mystery.
            rows[#rows + 1] = { text = {{ text = string.upper(b.refused.title),
                pen = self.theme.NEUTRAL_B }}, refused = b.refused }
            rows[#rows + 1] = { text = {{ text = "  Settings refused. See information.",
                pen = self.theme.RISK_M }}, refused = b.refused }
        else
            local spec = b.spec
            local heading = string.upper(spec.title)
            if sec.cont then heading = heading .. " (CONTINUED)" end
            rows[#rows + 1] = { text = {{ text = heading,
                pen = self.theme.NEUTRAL_B }}, spec = spec }
            for i = sec.from, sec.to do
                local s = spec.settings[i]
                rows[#rows + 1] = {
                    text = {
                        { text = string.format("  %-22s ", s.label), pen = self.theme.SEC },
                        -- Read on every draw, so the row shows the value
                        -- in force the moment it changes.
                        { text = function()
                              return cfg and cfg.label_of(spec.id, s.key) or '?'
                          end,
                          pen = self.theme.PRI },
                    },
                    spec = spec, setting = s,
                }
            end
        end
    end
    return rows
end

-- Enter or click on a setting row steps it; on a heading or a blank
-- row it does nothing. A refusal needs nothing here: the value simply
-- does not move, and the registry has logged why.
function RefinishPanelModules:step(choice, dir)
    if not (self.cfg and choice and choice.setting) then return end
    self.cfg.cycle(choice.spec.id, choice.setting.key, dir)
    if self.info then self.info:updateLayout() end
end

-- ==========================================
-- TOOLTIP TEXT
-- ==========================================
function RefinishPanelModules:info_text()
    if self.sheet_error then
        return "The settings pages could not be laid out:\n\n" .. self.sheet_error
    end
    if not self.cfg then
        return "The module settings registry did not load. See the log for the error."
    end
    local choice = self.list_widget:getChoices()[self.info_idx or 1]
    if choice and choice.refused then
        return choice.refused.title .. "\n\nRM refused this module's settings: "
            .. tostring(choice.refused.reason) .. ".\n\nThe module runs on its own"
            .. " defaults. The fix belongs in the module's settings spec."
    end
    if not choice or not choice.spec then
        return "Modules list their settings here. Select one and press Enter,"
            .. " or click it, to change it; shift-click steps back.\n\n"
            .. "Settings belong to this fort."
    end
    local s = choice.setting
    if not s then
        return choice.spec.title .. "\n\nSelect a setting and press Enter, or click"
            .. " it, to change it; shift-click steps back.\n\nSettings belong to"
            .. " this fort."
    end
    local when = WHEN[s.applies] or ''
    if s.applies == 'restart' and s.restart_note then
        when = when .. ' ' .. s.restart_note
    end
    local default_label = '?'
    for _, o in ipairs(s.options) do
        if o.value == s.default then default_label = o.label break end
    end
    return s.label .. "\n\n" .. s.description .. "\n\n" .. when
        .. "\n\nDefault: " .. default_label
end

-- ==========================================
-- WHICH ROW THE COLUMN DESCRIBES
-- ==========================================
-- The row under the mouse, if it has anything to say: a setting, a
-- heading or a refused module. Otherwise the cursor's row, so moving
-- the mouse onto a blank line or off the list falls back to the
-- keyboard's choice instead of blanking the column.
function RefinishPanelModules:info_row()
    local choices = self.list_widget:getChoices() or {}
    local hover = self.list_widget:getIdxUnderMouse()
    local c = hover and choices[hover]
    if c and (c.setting or c.spec or c.refused) then return hover end
    return (self.list_widget:getSelected())
end

-- Checked every frame, rewrapped only on a change of row. WrappedLabel
-- rewraps its text only on a layout pass, so a new row asks for one;
-- this runs before the column draws, so the new text shows the same
-- frame the mouse arrives.
--
-- Also the check on the sheets' arithmetic: a sheet with more rows than
-- the list is tall means the page height refinish-hud passed was wrong,
-- and the list would scroll. Said once per page, as a WARNING.
function RefinishPanelModules:onRenderFrame(dc, rect)
    local idx = self:info_row()
    if idx ~= self.info_idx then
        self.info_idx = idx
        if self.info then self.info:updateLayout() end
    end
    if not self.fit_checked then
        local body = self.list_widget.frame_body
        if body then
            self.fit_checked = true
            local n = #(self.list_widget:getChoices() or {})
            if n > body.height then
                log('WARNING', string.format('Module settings page %d holds %d rows'
                    .. ' but its list is %d tall, so it scrolls. The page height'
                    .. ' refinish-hud passes is out of step with its window.',
                    self.sheet_no or 1, n, body.height), 'SHEETS')
            end
        end
    end
    RefinishPanelModules.super.onRenderFrame(self, dc, rect)
end

return _ENV