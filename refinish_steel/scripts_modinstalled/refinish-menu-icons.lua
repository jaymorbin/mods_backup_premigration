--@ module = true
-- refinish-menu-icons.lua
-- ==========================================
-- RM BUILD MENU ICON STAMPER
-- ==========================================
-- DF stores the build menu's icons per button at
--   main_interface.construction.page[P].bb_button[B].texpos
-- and rebuilds those pages when the menu opens or the player
-- navigates categories, which reverts any one-shot write. So this
-- is a poller in the sand button's mold: whenever the structure
-- is populated, every configured building's buttons are checked
-- and restamped if DF's rebuild wiped them.
--
-- ICON SOURCES, two kinds:
--   1. AUTO: every def in world.raws.buildings.all whose code
--      begins with a registered module prefix and whose
--      list_icon_texpos is nonzero gets that same icon in the
--      menu. Injected buildings are covered with zero config:
--      declare icon_image in the module schema and both surfaces
--      follow. Reserved range texpos render fine in the menu
--      (proven live on the retort).
--   2. CONFIG: name -> BUILDING_ICONS cell, for adopting vanilla
--      or raws buildings (soap maker, screw press) whose parse
--      assigned them the generic tile.
--
-- Buttons are matched by name: case insensitive comparison of the
-- configured name against every string field on the button, since
-- the button does not carry the def. All matching buttons across
-- all pages are stamped (a building can appear in more than one
-- category page).
--
-- COMMANDS
--   refinish-menu-icons start | stop | status
--   refinish-menu-icons list      dump every button (open menu first)
--   refinish-menu-icons stamp     one manual pass, with logging
-- ==========================================

local POLL_FRAMES = 1


-- ==========================================
-- CONFIG: ADOPTED BUILDINGS
-- ==========================================
-- name  : matched against button strings, case insensitive
-- cell  : {col, row} on the page named by page (8 wide, 16 tall
--         for BUILDING_ICONS, zero indexed)
-- Pick the cells off the png; the two below are PLACEHOLDERS on
-- the generic tile so a wrong guess of mine cannot mislabel
-- anything. Set them and restart the stamper.
-- ==========================================
local ADOPTED = {
    { name = "Soap Maker",  page = "BUILDING_ICONS", cell = { 2, 12 } },
    { name = "Screw Press", page = "BUILDING_ICONS", cell = { 1, 12 } },
}


-- ==========================================
-- SESSION STATE
-- ==========================================
_G.refinish_menu_icons_running = _G.refinish_menu_icons_running or false
-- Session stamp so a stale timeout closure from before a map
-- unload can never fire into a fresh session (house pattern).
_G.refinish_menu_icons_session = (_G.refinish_menu_icons_session or 0)

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- RM's own, and peripheral rather than pipeline. Every log line this
-- file writes goes through log(), in the one grammar the log panel
-- reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body.
--
-- The panel filters on TYPE and nothing else, so each call site states
-- its own:
--   DETAIL   debugging material, shown in Debug only
--   INFO     what a player might check during play, Normal and up
--   faults, and the few confirmations a player wants at a glance
--   (COMPLETE, SYSTEM, ONLINE and the like), show in Quiet as well
-- TYPE comes first so no call site can drop it unnoticed: a nil TYPE
-- still renders, as UNTYPED, which shows at every Log Detail level
-- instead of being guessed at.
--
-- SUBJECT is the correlation slot: STAMP for a restamped button,
-- START and STOP for the poller.
--
-- This replaces a log() that took the subsystem as an argument and
-- let refinish-log guess TYPE from the words (read_type).
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here. The prints in COMMANDS at
-- the bottom answer commands typed at the console, as does the one in
-- stamp_pass, which only prints for the typed stamp command.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'MENU_ICONS'
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
-- TARGET TABLE
-- ==========================================
-- Rebuilt on every pass, cheap at this scale, so a def injected
-- or cleared mid session is always reflected. name_lower -> texpos.
-- ==========================================

local function resolve_page_cell(token, c, r)
    for _, p in ipairs(df.global.texture.page) do
        if tostring(p.token) == token then
            if c < p.page_dim_x and r < p.page_dim_y then
                return p.texpos[r * p.page_dim_x + c]
            end
            return nil
        end
    end
    return nil
end

local function build_targets()
    local targets = {}

    -- ---- AUTO: owned defs with a panel icon ----
    local registry = _G.refinish_module_registry or {}
    for _, d in ipairs(df.global.world.raws.buildings.all) do
        if d.list_icon_texpos and d.list_icon_texpos ~= 0 then
            for prefix, _ in pairs(registry) do
                if string.sub(d.code, 1, #prefix) == prefix then
                    targets[string.lower(d.name)] = d.list_icon_texpos
                    break
                end
            end
        end
    end

    -- ---- CONFIG: adopted vanilla and raws buildings ----
    for _, a in ipairs(ADOPTED) do
        local v = resolve_page_cell(a.page, a.cell[1], a.cell[2])
        if v and v ~= 0 then
            targets[string.lower(a.name)] = v
        end
    end

    return targets
end


-- ==========================================
-- STAMP PASS
-- ==========================================
-- Walks every button on every page. For each, gathers its string
-- fields once and checks them against every target name. Writes
-- only when the stored texpos differs, so a settled menu costs
-- comparisons and no writes, and each actual write logs once.
-- ==========================================

local function stamp_pass(verbose)
    local ok, con = pcall(function()
        return df.global.game.main_interface.construction
    end)
    if not ok or not con or not con.page or #con.page == 0 then
        return 0
    end

    local targets = build_targets()
    local wrote = 0

    for p = 0, #con.page - 1 do
        local pg = con.page[p]
        local n = 0
        pcall(function() n = #pg.bb_button end)

        for b = 0, n - 1 do
            local ok2 = pcall(function()
                local btn = pg.bb_button[b]

                local strs = {}
                for k, v in pairs(btn) do
                    if type(v) == 'string' and v ~= '' then
                        table.insert(strs, string.lower(v))
                    end
                end

                for name, tex in pairs(targets) do
                    for _, s in ipairs(strs) do
                        if s == name or s:find(name, 1, true) then
                            if btn.texpos ~= tex then
                                local before = btn.texpos
                                btn.texpos = tex
                                wrote = wrote + 1
                                -- DETAIL: DF rebuilds these pages whenever the menu opens or
                                -- changes category, so this fires on every visit.
                                log('DETAIL', string.format(
                                    "[%s] page %d button %d: %d -> %d.",
                                    name, p, b, before, tex), 'STAMP')
                            end
                            break
                        end
                    end
                end
            end)
            if not ok2 and verbose then
                print(string.format("button [%d][%d] unreadable", p, b))
            end
        end
    end

    return wrote
end


-- ==========================================
-- POLL LOOP
-- ==========================================

local function schedule()
    local my_session = _G.refinish_menu_icons_session
    dfhack.timeout(POLL_FRAMES, 'frames', function()
        -- A closure from a dead session or a stopped stamper does
        -- nothing and does not reschedule.
        if not _G.refinish_menu_icons_running then return end
        if my_session ~= _G.refinish_menu_icons_session then return end
        pcall(stamp_pass, false)
        schedule()
    end)
end


-- ==========================================
-- MODULE EXPORTS
-- ==========================================
-- The core starts and stops the stamper through these; the
-- command dispatch below calls the same functions, so console and
-- lifecycle can never disagree about state.
-- ==========================================

function start_stamper()
    if _G.refinish_menu_icons_running then return false end
    _G.refinish_menu_icons_running = true
    _G.refinish_menu_icons_session = _G.refinish_menu_icons_session + 1
    schedule()
    log('DETAIL', "Stamper started.", 'START')
    return true
end

function stop_stamper()
    if _G.refinish_menu_icons_running then
        _G.refinish_menu_icons_running = false
        log('DETAIL', "Stamper stopped.", 'STOP')
    end
end

-- Loaded as a module by the core: expose the functions and skip
-- command dispatch silently.
if dfhack_flags and dfhack_flags.module then
    return _ENV
end


-- ==========================================
-- COMMANDS
-- ==========================================

local args = {...}
local cmd = args[1]

if cmd == 'start' then
    if start_stamper() then
        print("Menu icon stamper started.")
    else
        print("Menu icon stamper already running.")
    end

elseif cmd == 'stop' then
    stop_stamper()
    print("Menu icon stamper stopped.")

elseif cmd == 'status' then
    print(string.format("running: %s", tostring(_G.refinish_menu_icons_running)))
    local t = build_targets()
    for name, tex in pairs(t) do
        print(string.format("  target [%s] -> texpos %d", name, tex))
    end

elseif cmd == 'list' then
    local ok, con = pcall(function()
        return df.global.game.main_interface.construction
    end)
    if not ok or not con or #con.page == 0 then
        print("construction.page empty. Open the build menu, then rerun.")
        return
    end
    for p = 0, #con.page - 1 do
        local pg = con.page[p]
        local n = 0
        pcall(function() n = #pg.bb_button end)
        print(string.format("---- page %d: %d button(s) ----", p, n))
        for b = 0, n - 1 do
            pcall(function()
                local btn = pg.bb_button[b]
                local strs = {}
                for k, v in pairs(btn) do
                    if type(v) == 'string' and v ~= '' then
                        table.insert(strs, k .. '=' .. v)
                    end
                end
                print(string.format("  [%d][%2d] texpos=%-8d %s",
                    p, b, btn.texpos, table.concat(strs, '  ')))
            end)
        end
    end

elseif cmd == 'stamp' then
    local n = stamp_pass(true)
    print(string.format("stamped %d button(s).", n))

else
    print("refinish-menu-icons start | stop | status | list | stamp")
end