--@ module = true
-- refinish-panel-log.lua
-- ==========================================
-- LIVE EVENT LOG PANEL
-- ==========================================
-- Displays the in-memory log buffer (_G.refinish_log). Every line is
-- in the one grammar, SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed
-- by refinish-log, and renders as a two line header plus its body.
-- Colour and the Log Detail filter both come from TYPE, the tag the
-- emitter declared, and from nothing else: see style_for for the
-- colour of each TYPE and DISPLAY FILTER for what each level shows.
--
-- A line that does not parse renders as UNTYPED, with its text as
-- the body. UNTYPED shows at every Log Detail level, because a line
-- that did not come through a log funnel is a fault in the code that
-- wrote it.
--
-- This used to colour untagged lines by their prefix, the text before
-- the first colon, from a table of every subsystem's name. Every call
-- site now states its TYPE, so the table and that renderer are gone.
--
-- SEARCH. Ctrl-F, or a click, puts the cursor in the search field
-- under the title. Every word typed must appear in a line for it to
-- show, in any case and anywhere in it: tags, time or body. So "ghost"
-- keeps the ghost's lines, "ghost error" only its errors, and a job id
-- one job's story. The list follows each keystroke. Enter keeps the
-- search and leaves the field; Esc puts back what was there before.
-- Search narrows what the Log Detail level shows; to search the debug
-- lines too, set Log Detail to Debug.
-- ==========================================

local gui = require('gui')
local widgets = require('gui.widgets')
local dialogs = require('gui.dialogs')

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
-- SUBJECT is the correlation slot: the panel action a line is
-- about. Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'LOG_VIEWER'
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


-- ==========================================
-- TEXT WRAPPING HELPER
-- ==========================================
-- Wraps a log entry to fit within max_width characters.
-- Continuation lines are indented by 4 spaces so the timestamp
-- on the first line stays visually distinct. The indent is counted
-- against max_width, so wrapped lines never grow past it.
--
-- ON THE WIDTH:
-- This list and the help panel's content list are both subviews of
-- the same centre router, so both get the same panel width P.
--   help: inset l=25, no icon, wraps to 46 -> reserves P - 71
--   log:  inset l=0, icon_width 2, was 73  -> reserved P - 75
-- The log was reserving 4 fewer columns than the help panel, which
-- is why full-length lines printed underneath the scrollbar. 69
-- gives it the identical margin the help panel already uses.
-- ==========================================
local WRAP_WIDTH = 69

local function wrap_log_entry(text, max_width)
    local lines = {}
    if not text or text == "" then return lines end

    local INDENT = "    "
    local current_line = ""

    -- Push the line in progress and start a fresh continuation line.
    local function newline()
        table.insert(lines, current_line)
        current_line = INDENT
    end

    for word in text:gmatch("%S+") do
        -- Working copy. The generic-for control variable is read-only
        -- in Lua 5.4 and later, so an oversized word has to be eaten
        -- through a local instead of by reassigning `word` itself.
        local rest = word

        -- Loop because one word may need more than one line.
        while true do
            -- No space before the first word on a line.
            local sep = (current_line == "" or current_line == INDENT) and "" or " "
            local room = max_width - #current_line - #sep

            if #rest <= room then
                current_line = current_line .. sep .. rest
                break
            end

            if current_line ~= "" and current_line ~= INDENT then
                -- Line has content, so wrap and retry on a fresh one.
                newline()
            else
                -- Already on a fresh line and it still does not fit,
                -- so the word itself is longer than a line. Take what
                -- fits and carry the rest over.
                --
                -- Without this, a single long token (a file path, a
                -- mod ID, a material list with no spaces) is emitted
                -- at full length regardless of max_width and runs
                -- under the scrollbar no matter what the width is.
                current_line = current_line .. rest:sub(1, room)
                rest = rest:sub(room + 1)
                newline()
            end
        end
    end

    if current_line ~= "" and current_line ~= INDENT then
        table.insert(lines, current_line)
    end

    return lines
end


-- ==========================================
-- PANEL CLASS
-- ==========================================
RefinishPanelLog = defclass(RefinishPanelLog, widgets.Panel)
RefinishPanelLog.ATTRS = {
    theme = DEFAULT_NIL,
}

function RefinishPanelLog:init()
    self.theme = self.theme or reqscript('refinish-theme').get_current_theme()

    -- The search, as typed. Empty shows everything the level shows.
    self.search = ''
    self.search_hits = 0

    -- Build initial log display
    self.log_lines = self:build_log_lines()
    self.last_log_count = _G.refinish_log and #_G.refinish_log or 0

    self.list_widget = widgets.List{
        frame = {t = 2, l = 0, r = 0, b = 4},
        choices = self.log_lines,
        selected = #self.log_lines,  -- Start at the bottom (newest entries)
        text_pen = self.theme.SEC,
        cursor_pen = self.theme.SEC,  -- Not visible on text (tokens override), but required
        icon_width = 2,               -- Reserve 2 chars left of text for the cursor marker
    }

    -- Block STRING_A key events from reaching the list's scroll
    -- handler. Theme colour pickers on the config panel use
    -- shifted number keys (STRING_A symbols like @ and *), which
    -- collide with DF's secondary scroll bindings. Since the log
    -- list has no text input, it should never process STRING_A keys.
    local orig_onInput = self.list_widget.onInput
    self.list_widget.onInput = function(list_self, keys)
        if keys._STRING then return false end
        return orig_onInput(list_self, keys)
    end

    self.tick_counter = 0

    -- ==========================================
    -- THEMED KEY DISPLAY HELPER
    -- ==========================================
    local function make_key_label(key_token, label_text, pen_label)
        local key_str = dfhack.screen.getKeyDisplay(df.interface_key[key_token])
        return {
            {text = key_str, pen = self.theme.PRI},
            {text = ": " .. label_text, pen = pen_label}
        }
    end

    -- Store action callbacks so onInput can reference them
    self.actions = {
        CUSTOM_CTRL_C = function()
            _G.refinish_log = {}
            -- INFO: the first line of the fresh log, saying why
            -- everything before it is gone.
            log('INFO', 'Live log cleared by the user.', 'CLEAR')
            self:refresh_list()
        end,
        CUSTOM_CTRL_L = function()
            self:export_permanent_dump()
        end,
        CUSTOM_CTRL_D = function()
            reqscript('refinish-dump').execute()
        end
    }

    -- ---- THE SEARCH FIELD ----
    -- An activation key makes the field manage its own focus: it starts
    -- unfocused, so the HUD's pane keys work as usual, and takes the
    -- keyboard on Ctrl-F or a click. While it has focus the HUD sends it
    -- every key first (see refinish-hud), so letters that are also pane
    -- keys go into the search. Enter keeps the search and hands the
    -- keyboard back; Esc does too, restoring the text from before.
    self.search_field = widgets.EditField{
        frame = {t = 1, l = 0, r = 0},
        key = 'CUSTOM_CTRL_F',
        label_text = 'Search: ',
        text_pen = self.theme.PRI,
        on_change = function(text) self:apply_search(text) end,
        -- Enter hands the keyboard back; the search already applied as
        -- it was typed, so this only makes sure it stands.
        on_submit = function(text) self:apply_search(text) end,
    }

    self:addviews{
        widgets.Label{ frame = {t = 0, l = 0}, text = {
            { text = "LIVE EVENT LOG", pen = self.theme.PRI },
            -- How many lines a search keeps, while one is set.
            { text = function()
                if self.search == '' then return '' end
                return string.format('   %d line(s) match', self.search_hits)
            end, pen = self.theme.SEC },
        }},
        self.search_field,
        self.list_widget,

        -- BOTTOM CONTROL BAR
        widgets.Panel{
            frame = {b = 0, l = 0, r = 0, h = 3},
            subviews = {
                widgets.Label{
                    frame = {t = 0, l = 0, w = 22},
                    text = make_key_label('CUSTOM_CTRL_C', 'Clear Live Log', self.theme.SEC),
                    on_click = self.actions.CUSTOM_CTRL_C,
                },
                -- Each label shows the key that runs its action. These
                -- showed Ctrl-D beside the log export, which Ctrl-L
                -- runs, and D beside the debug dump, which Ctrl-D runs.
                widgets.Label{
                    frame = {t = 1, l = 0, w = 23},
                    text = make_key_label('CUSTOM_CTRL_L', 'Export Log Dump', self.theme.SEC),
                    on_click = self.actions.CUSTOM_CTRL_L,
                },
                widgets.Label{
                    frame = {t = 2, l = 0, w = 25},
                    text = make_key_label('CUSTOM_CTRL_D', 'Export Debug Dump', self.theme.SEC),
                    on_click = self.actions.CUSTOM_CTRL_D,
                }
            }
        }
    }
end


-- ==========================================
-- POLLING LOOP
-- ==========================================
-- Checks every 60 render ticks for new log entries. If the log
-- buffer has grown since last check, rebuild the display and
-- use setChoices to update. Scroll position is preserved: if the
-- user was at the bottom (watching live), we pin to the new
-- bottom. If they scrolled up to read something, we hold position.
-- ==========================================
function RefinishPanelLog:onRenderFrame(dc, rect)
    self.tick_counter = self.tick_counter + 1
    if self.tick_counter >= 60 then
        self.tick_counter = 0
        local current_count = _G.refinish_log and #_G.refinish_log or 0

        -- ---- A SETTING CHANGE IS ALSO A REASON TO REBUILD ----
        -- The rebuild was gated on the entry COUNT alone, so changing
        -- Log Detail changed nothing on screen until the count moved
        -- or the HUD was reloaded. The filter was working; the panel
        -- simply never asked it again.
        --
        -- A generation counter rather than re-reading the setting
        -- every frame: the config panel bumps it on change, so this
        -- costs one table read per render instead of a persistent
        -- lookup.
        local gen = _G.refinish_log_filter_gen or 0
        if current_count ~= self.last_log_count or gen ~= self.last_log_gen then
            self.last_log_count = current_count
            self.last_log_gen = gen

            -- Capture scroll state BEFORE rebuilding
            local old_choices = self.list_widget:getChoices()
            local old_sel = self.list_widget:getSelected() or 0
            local old_page_top = self.list_widget.page_top or 1
            local was_at_bottom = (old_sel >= #old_choices - 2)

            -- Full rebuild (row count changes with new entries)
            self.log_lines = self:build_log_lines()
            self.list_widget:setChoices(self.log_lines)

            local new_count = #self.log_lines

            if was_at_bottom or #old_choices == 0 then
                -- Pin hard to the bottom: move cursor to last entry,
                -- then force page_top so the viewport's last visible
                -- row IS the last entry. This keeps new entries flush
                -- at the bottom of the visible area.
                self.list_widget:setSelected(new_count)

                -- Calculate page_top: the list shows (frame height)
                -- rows at a time. We want the last row at the bottom
                -- of the visible area, so page_top = total - visible + 1.
                local visible = self.list_widget.frame_body and self.list_widget.frame_body.height or 20
                local target_top = new_count - visible + 1
                if target_top < 1 then target_top = 1 end
                self.list_widget.page_top = target_top
            else
                -- User scrolled up - hold their reading position.
                -- Restore both cursor and scroll offset.
                if old_sel > 0 and old_sel <= new_count then
                    self.list_widget:setSelected(old_sel)
                end
                self.list_widget.page_top = old_page_top
            end
        end
    end
    RefinishPanelLog.super.onRenderFrame(self, dc, rect)
end
-- Shared between init() and refresh_list(). Reads the global
-- log buffer in reverse order (buffer stores newest-first, so we
-- iterate backwards to produce chronological display: oldest at
-- top, newest at bottom).
-- ==========================================
-- ==========================================
-- THE TAGGED LINE
-- ==========================================
--   SYSTEM SUBSYSTEM SUBJECT TYPE | body
--
-- Four tags, general to specific, then a pipe, then prose. The PIPE
-- is the whole test: a line without one is not tagged and falls
-- through to the renderer below exactly as before, so nothing has to
-- be converted before this is useful.
--
-- Tags never contain spaces. Underscores inside a tag instead, which
-- is what keeps the columns fixed and therefore scannable: every
-- HIJACKER sits at the same x, so the eye runs down one column
-- rather than reading across lines.
-- ==========================================
-- Measured against the real tags, not guessed. MAKING_CONCRETE and
-- CREMATE_WATCHER are both exactly 15, so a 15 wide column with no
-- separator produced MAKING_CONCRETESAND_WATCHER. pad() now owns the
-- separator so that cannot recur at any length.
--
-- 4 glyph + 9 time + 16 + 16 + 13 + 8 = 66, inside the 69 wrap.
-- Budget is WRAP_WIDTH (69) minus the list's 2 column icon.
--
-- 4 glyph + 9 time + 16 owner + 18 subsystem + 14 subject + 8 type
-- = 69 exactly. SUBSYSTEM went to 17 because BUILDING_GRAPHICS is
-- 17 and was being truncated; SUBJECT to 13 with what was left.
--
-- The repeat marker used to ride on the header and pushed a folded
-- line one column under the scrollbar. It sits on the body now,
-- where there is room and where the text wraps anyway.
-- ---- TWO LINES, SIX SLOTS ----
-- Line one is identity and verdict, line two is the specifics.
--
--   line 1   glyph 4 + time 9 + OWNER 16 + SUBSYSTEM 18 + TYPE
--   line 2   indent 13 + SUBJECT 25 + slot5 16 + slot6 14 = 68
--
-- One line was arithmetically impossible, not merely cramped: the
-- real values are OWNER 15, SUBSYSTEM up to 23 once reaction codes
-- land there, and SUBJECT 24 for the longest tool key. That is 62
-- before the glyph and the timestamp, against a budget of 69.
--
-- Slots five and six are reserved and render blank. A column of
-- dashes would be noise that says nothing; a gap says there is room.
local TAG_W  = { 15, 17 }     -- line one: owner, subsystem
local TAG_W2 = { 24, 15, 14 } -- line two: subject, reserved, reserved

local function parse_tagged(text)
    local stamp, rest = string.match(text, "^(%[%d+:%d+:%d+%])%s*(.*)$")
    if not stamp then stamp, rest = "", text end

    local head, body = string.match(rest, "^(.-)%s*|%s*(.*)$")
    if not head then return nil end

    local t = {}
    for word in head:gmatch("%S+") do t[#t + 1] = word end
    if #t ~= 4 then return nil end

    return { stamp = stamp, sys = t[1], sub = t[2],
             subj = t[3], typ = t[4], body = body }
end

-- A line parse_tagged cannot read, as the record it would have
-- returned: UNKNOWN owner and subsystem and UNTYPED, the same tags
-- refinish-log's compose() gives a line whose emitter omitted them, so
-- both kinds of nonconforming line read alike. The timestamp is kept.
local function untyped(text)
    local stamp, rest = string.match(text, "^(%[%d+:%d+:%d+%])%s*(.*)$")
    if not stamp then stamp, rest = "", text end
    return { stamp = stamp, sys = 'UNKNOWN', sub = 'UNKNOWN',
             subj = '-', typ = 'UNTYPED', body = rest }
end

-- ---- SEVERITY: WEIGHT, NOT ONLY HUE ----
-- One character cannot carry a serious fault, so the glyph block is
-- three cells and fills in as severity rises. A solid block in a
-- fixed left column is visible at any scroll speed and in peripheral
-- vision, whatever else the log is doing.
--
-- SUSPECT is not on the degradation ladder. It means nothing failed
-- and something is nevertheless wrong: a cache answering after it
-- should have been dropped, a predicate that threw and was read as a
-- no. Hot pink because it must be as visible as a fault while not
-- claiming to be one.
local TYPE_STYLE = {
    FATAL   = { glyph = '\17\17\17', hot = COLOR_RED },
    ERROR   = { glyph = '\254\254\254', hot = COLOR_LIGHTRED },
    WARNING = { glyph = '!!!',      hot = COLOR_YELLOW },
    SUSPECT = { glyph = '???',      hot = COLOR_LIGHTMAGENTA },
}

-- ---- EVERY VERDICT HAS ITS OWN COLOUR ----
-- No two TYPEs share a colour, so the TYPE column reads by colour
-- alone:
--   FATAL     red             the four colours reserved for faults,
--   ERROR     light red       in TYPE_STYLE above
--   WARNING   yellow
--   SUSPECT   light magenta
--   UNTYPED   magenta         faults in the CODE: a call site that
--   UNKNOWN   brown           declared no TYPE, or a TYPE nothing
--                             knows. Magenta and brown resemble the
--                             reserved colours, which only a fault may
--                             wear, and these are faults.
--   COMPLETE  PRI (green)
--   YIELD     dark green
--   READY     blue
--   SYSTEM    white
--   ONLINE    light cyan
--   OFFLINE   grey
--   INFO      SEC (light blue)
--   DETAIL    TER (cyan)
-- PRI, SEC and TER follow the theme, so a player who themes one of
-- them to a colour in this list makes two verdicts match again.
local function style_for(typ, theme)
    local hot = TYPE_STYLE[typ]
    if hot then return hot.glyph, hot.hot, true end

    if typ == 'COMPLETE' then return ' \7 ',   theme.PRI,       false end
    if typ == 'YIELD'    then return ' \7 ',   COLOR_GREEN,     false end
    if typ == 'READY'    then return ' \7 ',   COLOR_BLUE,      false end
    if typ == 'SYSTEM'   then return ' \4 ',   COLOR_WHITE,     false end
    if typ == 'ONLINE'   then return ' \4 ',   COLOR_LIGHTCYAN, false end
    if typ == 'OFFLINE'  then return ' \4 ',   COLOR_GREY,      false end
    if typ == 'INFO'     then return ' \250 ', theme.SEC,       false end
    if typ == 'DETAIL' then
        -- No glyph at all. Debug output should not have a mark in the
        -- left column competing with lines that mean something. The
        -- theme's Tertiary colour, cyan by default, so a player can
        -- move debug output's colour without moving a verdict.
        return '   ', theme.TER, false
    end
    if typ == 'UNTYPED' then return ' \250 ', COLOR_MAGENTA, false end
    -- UNKNOWN, and any TYPE a module invents. It still renders, in a
    -- colour no other verdict uses, so the nonconforming TYPE is seen.
    return ' \250 ', COLOR_BROWN, false
end

local function pad(s, w)
    s = tostring(s or '')
    if #s > w then s = s:sub(1, w) end
    -- The trailing space is part of the column, not the caller's
    -- problem. A tag that exactly fills its width used to touch the
    -- next one, which is how MAKING_CONCRETE and SAND_WATCHER became
    -- one word.
    return s .. string.rep(' ', w - #s) .. ' '
end

-- ---- REPEAT COLLAPSING ----
-- The single largest readability gain available, and it needs no
-- emitter change. HIDE SPRITE emitted 191 of 905 lines, and one
-- feedstock warning repeated five times for the same job.
--
-- Two entries fold when they are identical once every run of digits
-- is blanked, so texture_indices7[137] and [138] are the same line
-- and two different subsystems never are. The count rides on the
-- header, so a folded line still says how many.
local FOLD_WINDOW = 30

local function fold_key(text)
    return (text:gsub("%d+", "#"))
end

function RefinishPanelLog:build_log_lines()
    local lines = {}
    -- Capture self for use in icon callbacks. Unlike the local
    -- list_ref approach, self.list_widget is always the live
    -- widget - even on the first call from init() when it gets
    -- assigned immediately after build_log_lines returns.
    local panel = self

    if _G.refinish_log and #_G.refinish_log > 0 then
        -- Walk oldest to newest so a run collapses onto the FIRST of
        -- it, then reverse for display. Folding onto the last would
        -- move the timestamp forward and lose when the run started.
        --
        -- ---- A WINDOW, NOT JUST ADJACENCY ----
        -- Consecutive-only folding was measured at 1% on a real log:
        -- the repeats are interleaved, not adjacent. A window of 30
        -- gets 21% and collapses the genuine repeaters (one HIDE
        -- SPRITE line 26 times, an air dry poll 7 times) without
        -- reordering anything. Folding across the WHOLE log gets 65%
        -- and is wrong: it would hoist a line from ten minutes ago
        -- into a current run and destroy the ordering that makes the
        -- log readable as a sequence.
        -- ---- DISPLAY FILTER ----
        -- Reads the TYPE tag the emitter declared, and nothing else.
        -- Three levels, landing on the bands the colours already
        -- use: QUIET is the POP band, NORMAL adds the ordinary INFO
        -- stream, DEBUG adds per-item DETAIL.
        --
        -- UNTYPED and UNKNOWN show at every level. A line whose
        -- emitter has not declared itself is a fault in the code, not
        -- a message, and hiding it would let non-compliance sit
        -- unnoticed.
        -- YIELD sits with INFO rather than in QUIET, even though its
        -- colour pops: yields arrive all through play, and Quiet is
        -- for faults and the few confirmations a player wants at a
        -- glance, so every fault stays easy to find without scrolling.
        local SHOW = {
            QUIET  = { FATAL=1, ERROR=1, WARNING=1, SUSPECT=1,
                       COMPLETE=1, SYSTEM=1, ONLINE=1, OFFLINE=1,
                       READY=1, UNTYPED=1, UNKNOWN=1 },
            NORMAL = false,  -- everything except DETAIL
            DEBUG  = true,   -- everything
        }
        local lvl = 'NORMAL'
        pcall(function()
            lvl = dfhack.persistent.getSiteData('refinish_config_log')
                  or 'NORMAL'
        end)
        local allow = SHOW[lvl]

        -- ---- A LINE THAT DOES NOT PARSE IS UNTYPED ----
        -- It used to count as INFO, while unconverted emitters were
        -- still writing untagged lines. Every emitter declares its
        -- TYPE now, so a line with none came from outside a log funnel
        -- and shows at every level, the same as a declared UNTYPED.
        local function visible(typ)
            if allow == true then return true end
            typ = typ or 'UNTYPED'
            if allow == false then return typ ~= 'DETAIL' end
            return allow[typ] == 1
        end

        -- ---- SEARCH ----
        -- Every word typed must appear somewhere in the line, in any
        -- case. Found as plain text, never as a pattern, so a search
        -- can hold brackets, dots or percent signs. After the level
        -- filter, so it narrows what the level already shows.
        local terms = {}
        for w in string.lower(self.search or ''):gmatch('%S+') do
            terms[#terms + 1] = w
        end
        local function matches(raw)
            if #terms == 0 then return true end
            local low = string.lower(raw)
            for _, w in ipairs(terms) do
                if not string.find(low, w, 1, true) then return false end
            end
            return true
        end
        local hits = 0

        local folded, seen_at = {}, {}
        for i = 1, #_G.refinish_log do
            local raw = _G.refinish_log[i]
            local ftyp = string.match(raw,
                '^%[%d+:%d+:%d+%]%s*%S+%s+%S+%s+%S+%s+(%S+)%s+|')
            if not visible(ftyp) or not matches(raw) then goto skip end
            hits = hits + 1
            local key = fold_key(raw)
            local at  = seen_at[key]
            if at and (#folded - at) <= FOLD_WINDOW then
                folded[at].n = folded[at].n + 1
            else
                folded[#folded + 1] = { key = key, text = raw, n = 1 }
                seen_at[key] = #folded
            end
            ::skip::
        end
        self.search_hits = hits

        for i = #folded, 1, -1 do
            local raw_text = folded[i].text
            local repeats  = folded[i].n

            -- ---- EVERY LINE RENDERS AS HEADER PLUS BODY ----
            -- One that does not parse is rendered as UNTYPED from an
            -- UNKNOWN owner, the tags refinish-log gives a line whose
            -- emitter omitted them, with its whole text as the body.
            local tg = parse_tagged(raw_text) or untyped(raw_text)
            local glyph, verdict, hot = style_for(tg.typ, self.theme)
            local idx = #lines + 1

            -- A hot line is hot end to end. No hunting for which
            -- word went yellow.
            local tag_pen  = hot and verdict or COLOR_CYAN
            local subj_pen = hot and verdict or self.theme.GREY

            -- ---- ONE PEN PER COLUMN ----
            -- Every tag shared a pen before, so the four columns
            -- rendered as one block and the segmentation the
            -- scheme depends on never appeared.
            --
            -- OWNER is neutral: you generally know whose line it
            -- is. SYSTEM pops, because it is what you scan for.
            -- SUBJECT pops WHEN STATED and recedes when it is a
            -- dash, so a line worth correlating looks better once
            -- someone has said what it is about. TYPE carries its
            -- verdict.
            --
            -- A fault overrides all of it and colours the header
            -- end to end, so there is never any hunting for which
            -- word went yellow.
            local stamp = (tg.stamp or ''):gsub('[%[%]]', '')

            -- ---- CORE'S OWN STREAM LINES STAY RECOGNISABLE ----
            -- A module's OWNER is neutral because you generally
            -- know whose line it is and it should not compete
            -- with the subsystem beside it.
            --
            -- RM's own peripheral subsystems take a brand colour
            -- instead, so TOOL_SPRITES and GRAPHICS read as RM at
            -- a glance even though they use the module format.
            -- SEC rather than PRI: it identifies, it does not
            -- need to pull the eye, and PRI stays reserved for a
            -- verdict.
            --
            -- Core naming itself is not the inversion that was
            -- wrong before. Core must not know which MODULES
            -- exist; knowing its own name is unavoidable and
            -- harmless.
            local own = (tg.sys == 'REFINISH_METAL')
            local owner_pen = hot and verdict
                              or (own and self.theme.SEC
                                      or self.theme.GREY)
            -- ---- RM'S OWN HEADERS OPEN WITH THE BRAND ----
            -- A module's subsystem is lightcyan: cold, pops, and
            -- distinct from everything around it.
            --
            -- RM's own takes PRI instead, so a core header reads
            -- brand purple then brand green before anything else
            -- on the line. Position keeps it unambiguous: green
            -- in column two is identity, green in column four is
            -- a verdict, and the two never occupy the same slot.
            local sys_pen   = hot and verdict
                              or (own and self.theme.PRI
                                      or COLOR_LIGHTCYAN)
            local subj_pen2 = hot and verdict
                              or (tg.subj == '-' and self.theme.GREY
                                                 or COLOR_WHITE)

            -- ---- LINE ONE: WHO, AND HOW IT WENT ----
            -- TYPE rides up here so the verdict is readable
            -- without dropping to the second line.
            local head = {
                { text = glyph .. ' ', pen = verdict },
                -- Restored. parse_tagged was capturing the stamp
                -- and the header was dropping it on the floor.
                { text = stamp .. ' ', pen = self.theme.GREY },
                { text = pad(tg.sys,  TAG_W[1]), pen = owner_pen },
                { text = pad(tg.sub,  TAG_W[2]), pen = sys_pen },
                { text = tg.typ, pen = verdict },
            }

            -- ---- LINE TWO: WHICH THING ----
            -- Indented to the width of the glyph and timestamp so
            -- it reads as a continuation rather than a new entry,
            -- and so SUBJECT starts at a fixed column that can be
            -- scanned straight down.
            --
            -- Slots five and six are reserved. They render as
            -- blank rather than as dashes: a dash column is noise
            -- that says nothing, a gap says there is room.
            local head2 = {
                { text = string.rep(' ', 13), pen = self.theme.GREY },
                { text = pad(tg.subj, TAG_W2[1]), pen = subj_pen2 },
            }
            -- Repeat marker deliberately NOT on the header: at
            -- three digits it pushed the line past the wrap and
            -- under the scrollbar. The body has room and wraps.
            local body_txt = tg.body
            if repeats > 1 then
                body_txt = body_txt .. '   (x' .. repeats .. ')'
            end
            -- ---- EVERY LINE CARRIES THE MARKER ----
            -- The original renderer gave the icon callback to
            -- every wrapped line, so the cursor was visible
            -- wherever it sat. Giving it to the header alone made
            -- it vanish on two lines in three and flicker back as
            -- it passed each header.
            --
            -- A helper rather than a third copy of the closure:
            -- three hand-written copies is three chances to drift.
            local function marker(at)
                return function()
                    if panel.list_widget then
                        local sel = panel.list_widget:getSelected()
                        if sel == at then return string.char(16) end
                    end
                    return " "
                end
            end

            table.insert(lines, {
                text = head,
                icon = marker(idx),
                icon_pen = self.theme.NEUTRAL_B,
            })

            local idx2 = #lines + 1
            table.insert(lines, {
                text = head2,
                icon = marker(idx2),
                icon_pen = self.theme.NEUTRAL_B,
            })

            -- Bulk beneath, indented, in the header's verdict
            -- colour. One entry carries one verdict end to end, so
            -- a fault's detail reads as a fault and a COMPLETE's
            -- reads as done. Every body takes its TYPE's pen, so
            -- each verdict keeps its own colour (see style_for).
            -- ---- INDENT ONCE, AND BUDGET FOR IT ----
            -- This wrapped the body with the indent already
            -- attached and then indented the result again, so
            -- every line ran four columns past the wrap and
            -- printed under the scrollbar.
            --
            -- The wrap has to be told how much room the indent
            -- costs rather than being handed a string that
            -- already spent it.
            local BODY_INDENT = '    '
            local body_room = WRAP_WIDTH - #BODY_INDENT
            for _, bl in ipairs(wrap_log_entry(body_txt,
                                               body_room)) do
                local bidx = #lines + 1
                table.insert(lines, {
                    text = {{ text = BODY_INDENT .. bl,
                              pen = verdict }},
                    icon = marker(bidx),
                    icon_pen = self.theme.NEUTRAL_B,
                })
            end
        end
    else
        table.insert(lines, { text = {{ text = "  (Log is empty)", pen = self.theme.SEC }} })
    end

    -- ---- NOTHING LEFT TO SHOW ----
    -- Said rather than left blank, so an empty list reads as the search
    -- or the level hiding everything, not as the log being broken.
    if #lines == 0 then
        local why = (self.search ~= '') and "  (No lines match the search)"
                    or "  (No lines at this Log Detail level)"
        table.insert(lines, { text = {{ text = why, pen = self.theme.SEC }} })
    end

    return lines
end


-- ==========================================
-- KEY INPUT HANDLER
-- ==========================================
function RefinishPanelLog:onInput(keys)
    -- While the search field has the keyboard every key is its: Ctrl-C
    -- there copies the search, and must not reach the action below that
    -- clears the live log.
    if self.search_field and self.search_field.focus then
        return RefinishPanelLog.super.onInput(self, keys)
    end
    for key_name, action in pairs(self.actions) do
        if keys[key_name] then
            action()
            return true
        end
    end
    return RefinishPanelLog.super.onInput(self, keys)
end


-- ==========================================
-- IN-PLACE LIST REFRESH
-- ==========================================
function RefinishPanelLog:refresh_list()
    self.log_lines = self:build_log_lines()
    self.list_widget:setChoices(self.log_lines)
end

-- ==========================================
-- APPLYING A SEARCH
-- ==========================================
-- Called by the search field on every change. Rebuilds the list with
-- the new search and puts the cursor on the newest match, at the
-- bottom, where the log's newest line always sits. The periodic
-- rebuild in onRenderFrame reads self.search too, so new lines that
-- match keep arriving while a search is set.
function RefinishPanelLog:apply_search(text)
    self.search = text or ''
    self.log_lines = self:build_log_lines()
    self.list_widget:setChoices(self.log_lines)
    local n = #self.log_lines
    self.list_widget:setSelected(n)
    local visible = self.list_widget.frame_body
                    and self.list_widget.frame_body.height or 20
    local top = n - visible + 1
    self.list_widget.page_top = (top < 1) and 1 or top
end


-- ==========================================
-- PERMANENT DUMP GENERATOR
-- ==========================================
function RefinishPanelLog:export_permanent_dump()
    local dump_name = reqscript('refinish-debug').make_filename("log")

    local ok, err = pcall(function()
        -- ---- AN UNOPENED FILE IS A FAILED EXPORT ----
        -- io.open does not raise. It returns nil and the reason, so an
        -- unchecked nil wrote nothing and still reported success. The
        -- else below raises instead, which sends it down the failure
        -- path with the reason. Level 0 keeps a file and line prefix
        -- off the message the player reads.
        local file, open_err = io.open(dump_name, "w")
        if file then
            file:write("==================================================\n")
            file:write("REFINISH STEEL: PERMANENT EVENT LOG DUMP\n")
            file:write("TIMESTAMP: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
            file:write("==================================================\n\n")

            if _G.refinish_log and #_G.refinish_log > 0 then
                for i = #_G.refinish_log, 1, -1 do
                    file:write(_G.refinish_log[i] .. "\n")
                end
            else
                file:write("(No events logged.)\n")
            end
            file:close()
        else
            error(tostring(open_err or ('could not open ' .. tostring(dump_name))), 0)
        end
    end)

    if ok then
        log('INFO', 'Permanent log dump exported to '
            .. tostring(dump_name) .. '.', 'EXPORT')
        dialogs.showMessage(
            "Export Successful",
            "The permanent log has been saved to your main Dwarf Fortress folder as:\n\n" .. dump_name,
            self.theme.PRI
        )
        self:refresh_list()
    else
        log('ERROR', 'Export failed: ' .. tostring(err), 'EXPORT')
        dialogs.showMessage(
            "Export Failed",
            "An error occurred while trying to save the log file:\n\n" .. tostring(err),
            self.theme.RISK_H or COLOR_RED
        )
        self:refresh_list()
    end
end

return _ENV