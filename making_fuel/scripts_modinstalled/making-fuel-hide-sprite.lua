--@ module = true
-- making-fuel-hide-sprite.lua
-- ==========================================
-- MAKING FUEL: HIDE SPRITE POINTER
-- ==========================================
-- Points ITEM_LIQUID at the HIDES sheet, so skin globs draw as hides.
--
-- ==========================================
-- HOW THIS WORKS, AND WHY IT IS LEGITIMATE
-- ==========================================
-- The graphics raws are an INITIALIZER, not the graphics system. At
-- load the parser resolves every TILE_GRAPHICS line to a texpos and
-- bakes it into the gps.texture_indices tables. The renderer reads
-- the tables live and never rereads the raws. So the table entry is
-- the pointer, and rewriting it re-aims the sprite with no raws, no
-- worldgen, and no item touched. Same runtime injection model as the
-- rest of this module, applied to a table nobody documents.
--
-- MEASURED 22:41: writing the entry turned a llama skin glob hide
-- shaped on screen, live, including globs that already existed.
--
-- ==========================================
-- WHAT IS ACTUALLY REDIRECTED, AND THE COLLATERAL
-- ==========================================
-- The entry is ITEM_LIQUID, the single glob shaped tile in all of
-- graphics_items.txt. Everything that is not fat falls through to it:
-- our skins, but ALSO ground liquid items such as lye. MEASURED: the
-- lye canary turned hide shaped in the same glance. Accepted because
-- liquids live in containers and are almost never drawn bare on the
-- floor, but it is a real tradeoff and it is written down here rather
-- than discovered by a confused player later. If it ever matters, the
-- fallback is a display layer overlay that repaints only our globs.
--
-- ==========================================
-- WHY A WATCHER AND NOT A ONE TIME WRITE
-- ==========================================
-- The gps tables are rebuilt whenever graphics reload, resolution
-- changes, or DF otherwise reinitializes the renderer, and a rebuilt
-- table holds the vanilla value again, possibly at a DIFFERENT index.
-- So the poll does not trust the index it wrote last time: each check
-- verifies the redirect is still standing, and on any miss it
-- re-finds the vanilla value from scratch and rewrites. Announced in
-- the log each time, never silent.
--
-- The tint comes from the material, so each species' skin colour
-- carries through on its own. Nothing here is per creature.
-- ==========================================

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
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'HIDE_SPRITE'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

-- ---- WHAT TO POINT, AND WHERE ----
-- SOURCE names the vanilla cell whose baked value identifies the
-- pointer. TARGET is the cell our skins should wear. Both are read
-- off the live page registry at apply time, never from remembered
-- numbers, because texpos numbering is per session.
local SOURCE = { page = 'ITEM_NATURE', x = 0, y = 1 }   -- ITEM_LIQUID
local TARGET = { page = 'HIDES',       x = 0, y = 3 }

-- Every gps table the pointer could live in. Found in indices7 on
-- this build, but searched everywhere because a DF update can move
-- furniture without notice.
local TABLES = { 'texture_indices1', 'texture_indices2', 'texture_indices3',
                 'texture_indices4', 'texture_indices5', 'texture_indices6',
                 'texture_indices7', 'texture_indices8', 'texture_indices9',
                 'texture_indices10', 'texture_indices11' }

local repeatUtil = require('repeat-util')
local POLL_KEY   = 'making_fuel_hide_sprite'


-- ---- BODY IDENTITY ----
-- A fresh table per execution of this file body. reqscript re-executes
-- the body and makes a new one; a world load does not.
--
-- It exists because the two obvious ways to guard start() both fail,
-- in opposite directions. A file-local running flag resets on a new
-- body, so start() proceeds and rebinds correctly, but it knows
-- nothing about the world and can run against dead state. A _G flag
-- gets the world right and then refuses to rebind, so repeatUtil keeps
-- calling the PREVIOUS body's closure and the reloaded code never runs
-- while manual commands run the new code. Tracking both distinguishes
-- "already running in this same body" from "reloaded, needs rebinding".
local BODY = {}

local POLL_TICKS = 200

-- The gate has to flip between a sheet opening and that sheet being
-- drawn, so this is frames and it is small. Each poll is one integer
-- read and a comparison on the quiet path.
local POLL_FRAMES = 2

-- ---- HOW LONG TO WAIT BEFORE THE FIRST WRITE ----
-- TICKS, AND THE UNIT IS THE ENTIRE POINT. DO NOT CHANGE IT TO FRAMES.
--
-- Ticks do not advance while the game is paused. A reloaded fort comes
-- up paused, so a tick timer cannot fire until the player unpauses,
-- and by then every liquid on screen has already had its first draw
-- with the slot at vanilla and latched there. That is what the delay
-- buys, and it is the only thing standing between a reload and a
-- barrel of ale wearing a hide for the rest of the session.
--
-- MEASURED, twice, the second time by breaking it. Switched to frames
-- to close the cosmetic seam where skins sit as liquid until unpause.
-- Autosave, exit, reload without a recycle: dwarven ale took
-- HIDES:0:3 and kept it. Frames advance during load, the fort returns
-- at dwarfmode/Default which is the first entry in SAFE_FOCUS, so the
-- gate answers HIDE and the write lands before anything has drawn.
--
-- The gate does NOT cover this. The gate decides what the slot should
-- hold for a given screen; it has no idea whether a liquid has drawn
-- yet. Only the timing does, and only ticks express it.
--
-- The seam is the price. Skins read as liquid while a reloaded fort
-- sits paused, and snap to hides on the first unpaused tick. A latched
-- liquid is permanent for the session; a skin drawn wrong while paused
-- costs nothing.
local FIRST_TICKS = 1
local FIRST_FRAMES = 1

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
-- SUBJECT is the correlation slot: APPLY and RESTORE for the redirect,
-- FLIP and TRIPWIRE for the gate's decisions, TRACE for the frame
-- trace, RESOLVE for the enum fallbacks, START and STOP. The output of
-- the typed commands (status, gate, trace and usage) prints, since it
-- answers what was typed.
--
-- The redirect only ever changes a sprite, so its failures are
-- WARNING: the skin shows vanilla's glob sprite, which is cosmetic.
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

local function try(fn, dflt)
    local ok, v = pcall(fn)
    if ok then return v end
    return dflt
end

-- State in _G because DFHack re-executes this file body on every
-- invocation, and a file local would forget the redirect it made.
--   { tbl, idx, old, new }  while standing, nil while not.
_G.making_fuel_hide_sprite = _G.making_fuel_hide_sprite or nil

-- The pending first write timer id. Also in _G, because stop() can run
-- from a different execution of this file body than start() did, and a
-- file local would not be the same variable by then.
_G.making_fuel_hide_sprite_timer = _G.making_fuel_hide_sprite_timer or nil

-- ==========================================
-- WHY running IS IN _G, THE HARD WAY
-- ==========================================
-- This was `local running = false`, and the comment right above it
-- explained why that is wrong without anyone noticing the same
-- argument applied. The file body RE-EXECUTES on every reqscript, so a
-- file local resets to false on the first reqscript of a new world.
-- The state global beside it does NOT reset: it still holds the
-- PREVIOUS world's slot record, with that world's texpos numbers.
--
-- The consequence was the two day sprite bug. On a main menu reload or
-- a recycle, DF keeps the Lua environment. `running` reset to false so
-- start() proceeded, but _G.making_fuel_hide_sprite still described a
-- dead world, and apply()/restore() acted on indices that now point at
-- whatever the new world's rebuilt gps tables happened to put there.
-- Sometimes harmless, sometimes the ale. A cold launch never hit it
-- because the environment starts empty.
--
-- In _G, running resets exactly when the state it guards resets, which
-- is never on its own and only when stop() clears both.
_G.making_fuel_hide_sprite_running = _G.making_fuel_hide_sprite_running or false

-- ==========================================
-- RESOLUTION
-- ==========================================
local function page_cell(spec)
    local v = nil
    try(function()
        for _, p in ipairs(df.global.texture.page) do
            if tostring(p.token) == spec.page then
                v = p.texpos[spec.y * p.page_dim_x + spec.x]
                return
            end
        end
    end)
    return v
end

-- Which table and index currently hold a given texpos. First hit
-- wins, which matched the renderer's behaviour when measured.
local function find_holder(texpos)
    for _, name in ipairs(TABLES) do
        local hit = nil
        try(function()
            local t = df.global.gps[name]
            for i = 0, #t - 1 do
                if t[i] == texpos then hit = i return end
            end
        end)
        if hit then return name, hit end
    end
    return nil
end

-- ==========================================
-- APPLY AND RESTORE
-- ==========================================
-- apply() is idempotent and self healing. It is the whole watcher:
-- called at start and from every poll, and it works out for itself
-- whether there is anything to do.
-- ==========================================
-- ==========================================
-- WHICH VALUE THE SLOT SHOULD HOLD RIGHT NOW
-- ==========================================
-- MEASURED. Globs read this slot LIVE, every frame. Liquids resolve
-- it ONCE, on first draw, and keep that answer for the session. And
-- every latch on record happened while an item viewsheet was open.
--
-- So the slot does not have to stand at the hide. It has to be
-- vanilla in the frames where a liquid could resolve, and the hide
-- everywhere else. Skins on the map, in stockpiles and in workshop
-- lists all draw live off whatever is standing at that moment.
--
-- Vanilla while an item sheet is open on anything that is not ours,
-- the hide otherwise. Anything unreadable yields VANILLA, because a
-- liquid latched wrong is permanent and a skin drawn wrong is one
-- frame.
-- ==========================================
local OUR_PREFIX = 'MAKING_FUEL_HIDE'

-- The only sheet kind that can draw a liquid's sprite. Resolved by
-- name, falling back to the measured numeric value so a renamed enum
-- member degrades to something that still works and says so out loud
-- rather than quietly gating on nil.
local ITEM_SHEET = nil
do
    local ok = pcall(function() ITEM_SHEET = df.view_sheet_type.ITEM end)
    if not ok or ITEM_SHEET == nil then
        ITEM_SHEET = 1
        log('WARNING', 'df.view_sheet_type.ITEM did not resolve; using measured 1.', 'RESOLVE')
    end
end

-- ==========================================
-- IS THE OPEN SHEET SHOWING A LIQUID
-- ==========================================
-- MEASURED, twice, the hard way. Liquid sprites get resolved by any
-- sheet that lists the contents of something: an item sheet on a
-- barrel, a workshop's Items list, a unit's inventory. Gating on the
-- sheet KIND failed both times, so this asks about contents instead.
--
-- LIQUID_MISC and DRINK are the classes that fall through to the
-- shared pointer. Our own globs do not count, because the hide is
-- the correct answer for them.
--
-- Every unreadable case returns TRUE, meaning vanilla, because a
-- liquid latched wrong is permanent and a skin drawn wrong is a
-- frame.
-- ==========================================
local LIQUID_CLASS = { LIQUID_MISC = true, DRINK = true }

local function is_liquid_item(it)
    if not it then return false end
    local ty = try(function() return tostring(df.item_type[it:getType()]) end)
    if not ty or not LIQUID_CLASS[ty] then return false end
    local mi = try(function() return dfhack.matinfo.decode(it) end)
    local tok = mi and try(function() return mi:getToken() end)
    if tok and tostring(tok):find(OUR_PREFIX, 1, true) then return false end
    return true
end

-- The item itself plus one level down, which is as deep as a sheet
-- lists: a barrel shows its water, not the water's contents.
local function holds_liquid(it)
    if is_liquid_item(it) then return true end
    local hit = false
    try(function()
        for _, c in ipairs(dfhack.items.getContainedItems(it) or {}) do
            if is_liquid_item(c) then hit = true return end
        end
    end)
    return hit
end

local function sheet_shows_liquid(vs)
    local kind = try(function() return vs.active_sheet end)
    local id   = try(function() return vs.active_id end)
    if not id then return true end

    if kind == ITEM_SHEET then
        local it = df.item.find(id)
        if not it then return true end
        return holds_liquid(it)
    end

    -- Not an item sheet, so the id is a building or a unit. Both
    -- lookups are tried and OR'd rather than guessing which: an id
    -- landing in the wrong table can only push the answer toward
    -- vanilla, which is the safe direction.
    local hit = false
    local b = df.building.find(id)
    if b then
        try(function()
            for _, ci in ipairs(b.contained_items) do
                if holds_liquid(ci.item) then hit = true return end
            end
        end)
    end
    if hit then return true end

    local u = df.unit.find(id)
    if u then
        try(function()
            for _, inv in ipairs(u.inventory) do
                if holds_liquid(inv.item) then hit = true return end
            end
        end)
    end
    if hit then return true end

    return (b == nil and u == nil)
end

-- ==========================================
-- WHICH SCREENS MAY WEAR THE HIDE
-- ==========================================
-- The gate began as a blacklist and got caught twice, because there
-- is no bounded list of things that draw a liquid sprite. Stocks,
-- trade, work order material pickers, stockpile settings and
-- whatever the next DF version adds all draw item sprites, and none
-- of them is a view sheet.
--
-- So this is a WHITELIST. The hide is permitted only on screens known
-- to be incapable of drawing a contained liquid. Anything
-- unrecognised, now or in a future build, yields vanilla, and the
-- cost of that is our skins drawing as liquid on that one screen.
--
-- dwarfmode/Default is the plain map, where a barrel draws as a
-- barrel and its contents are never rendered. dfhack screens sit over
-- the map with the map still drawn beneath, so they follow the same
-- rule. ViewSheets pass through to the contents test, which is the
-- part already measured working.
--
-- Every focus string has to be safe, not just the first. A workshop
-- reports two at once.
--
-- STILL UNTESTED: a liquid item loose on the ground IS drawn on the
-- plain map, and whether a map draw latches has never been measured.
-- That is the barrel test, and it is now the only hole left that we
-- know about and have not closed.
-- ==========================================
-- ---- STOCKS ----
-- MEASURED. Stocks draws only the category you are on, and
-- current_type_i_list is literally that list, so the category id
-- never has to be interpreted.
--
-- In the dump that settled this, current_type was 73 (LIQUID_MISC)
-- and current_type_i_list held three item_liquid_miscst. The Glob
-- category is 75 and holds our skins, which are not liquid class, so
-- it resolves to HIDE on its own.
--
-- An empty list is safe. Anything unreadable returns true, meaning
-- vanilla, on the usual grounds: a latched liquid is permanent and a
-- skin drawn wrong is cosmetic.
local function stocks_shows_liquid()
    local st = try(function()
        return df.global.game.main_interface.stocks end)
    if not st then return true end
    if not try(function() return st.open end) then return true end

    local list = try(function() return st.current_type_i_list end)
    if not list then return true end

    local hit, seen = false, false
    local ok = pcall(function()
        for _, it in ipairs(list) do
            seen = true
            -- holds_liquid, not is_liquid_item. MEASURED: the trace
            -- caught the slot at HIDE for 97 straight frames on
            -- dwarfmode/Stocks. A barrel of ale is neither LIQUID_MISC
            -- nor DRINK, so the top level test answered false for
            -- every row while the screen drew the contents. The view
            -- sheet path has always used holds_liquid for exactly this
            -- reason; stocks was the one caller still testing only the
            -- outer item.
            if holds_liquid(it) then hit = true return end
        end
    end)
    if not ok then return true end

    -- An empty list is NOT "no liquids in this category". Stocks is
    -- open for at least one frame before it has built its lists, so an
    -- empty read means NOT BUILT YET, and answering safe there stands
    -- the slot at HIDE across the frames the screen first draws.
    --
    -- Empty now means VANILLA, the same as every other unreadable case
    -- in this file and on the same grounds: a latched liquid is
    -- permanent for the session and a skin drawn wrong is cosmetic.
    -- The cost is our skins drawing as liquid on a genuinely empty
    -- stocks category, which is the correct side to be wrong on.
    if not seen then return true end
    return hit
end

-- ---- THE WHITELIST ----
-- Each entry is a focus prefix, optionally with a test. No test means
-- the screen can never draw a contained liquid. A test means it
-- sometimes can, and has to return false for that screen to count as
-- safe on this frame.
--
-- ViewSheets carries no test here because want_target already runs
-- the contents check on it further down.
-- ---- dwarfmode/Default IS NOT SAFE ON ARRIVAL ----
-- The gate is reactive: it reads the focus and corrects the slot after
-- the fact. That is fine for every transition except the first, where
-- the slot is written to HIDE on the map before the player has done
-- anything, and whatever DF draws between then and the first screen
-- change resolves against it. A liquid that resolves is latched for
-- the session and no later write moves it.
--
-- So the map is permitted only once the player has been somewhere the
-- gate has already evaluated. Until then this answers vanilla, which
-- costs skins on the map looking like liquid for the first few seconds
-- of a load and costs nothing else.
-- ==========================================
-- STOCKS: THE GLOB CATEGORY, AND ONLY IT
-- ==========================================
-- Stocks was taken off the whitelist entirely to kill the latch, which
-- worked, and cost our skins their sprite on the one stocks list that
-- shows them. This buys it back on terms the liquid version could
-- never meet.
--
-- The difference is which way being late hurts. A drink resolves once
-- and keeps that answer, so a single wrong frame is permanent. A skin
-- is solid by construction (O7) and reads the slot live every frame
-- (O3), so a wrong frame on the Glob category corrects itself on the
-- next poll and costs nothing but a flicker.
--
-- So: HIDE on stocks only when the category on screen IS the glob
-- category and that list holds nothing liquid. Every other category,
-- an unreadable read, and the category list itself all answer vanilla.
-- ==========================================
local GLOB_TYPE = nil
do
    local ok = pcall(function() GLOB_TYPE = df.item_type.GLOB end)
    if not ok or GLOB_TYPE == nil then
        GLOB_TYPE = 75
        log('WARNING', 'df.item_type.GLOB did not resolve; using measured 75.', 'RESOLVE')
    end
end

-- Returns TRUE when the gate must force vanilla, matching the sense of
-- every other SAFE_FOCUS test.
local function stocks_needs_vanilla()
    local stk = try(function()
        return df.global.game.main_interface.stocks end)
    if not stk then return true end
    if not try(function() return stk.open end) then return true end

    -- current_type is a df.item_type. Anything that is not the glob
    -- category is either a liquid list or a list we have not reasoned
    -- about, and both get vanilla.
    if try(function() return stk.current_type end) ~= GLOB_TYPE then
        return true
    end

    -- Belt and braces. The category says globs, so this should never
    -- fire, and if it ever does the assumption above was wrong and the
    -- safe answer is still vanilla.
    local list = try(function() return stk.current_type_i_list end)
    if not list then return true end
    local bad = false
    local ok = pcall(function()
        for _, it in ipairs(list) do
            if holds_liquid(it) then bad = true return end
        end
    end)
    if not ok then return true end
    return bad
end

-- ---- AND IT LIVES IN _G, FOR THE REASON running DOES ----
-- MEASURED. As a file local this survived a world unload and killed
-- the guard on every main menu reload. DFHack keeps the Lua
-- environment across a reload and does not re-execute an unchanged
-- file body, so the flag stayed true from the PREVIOUS world and the
-- new one came up with the map already treated as safe. The first
-- write of the load then landed on HIDE and the first liquid drawn
-- anywhere latched.
--
-- The frame counter in the trace is what proved it. A cold launch
-- logs the first write at f1 and puts VANILLA. A reload in the same
-- process logs it at f6256 and puts HIDE. Same save, same code, same
-- screen, opposite answer, and the only difference is whether DF was
-- restarted.
--
-- In _G it is explicit, and start() clears it below so it resets
-- exactly once per world load whether or not the body re-executed.
_G.making_fuel_hide_sprite_seen = _G.making_fuel_hide_sprite_seen or false

-- ---- THE MAP GUARD ----
-- OFF, to test whether it is needed at all.
--
-- With it on, the plain map answers vanilla until the player has
-- opened some DF screen the gate has already evaluated, so skins wear
-- liquid art for the first few seconds of every load. It exists
-- because the gate is reactive: without it the slot goes to HIDE on
-- the map before the player has done anything, and whatever DF draws
-- next resolves against it.
--
-- The whole guard rests on one thing nobody has measured: whether a
-- liquid item drawn on the plain map resolves at all. Loose barrels
-- and globs are drawn there, and if map presence does not resolve
-- them, the guard is protecting against nothing and costs a visible
-- wrong sprite on every load.
--
-- true restores it. The _G.making_fuel_hide_sprite_seen machinery
-- below is left intact so that is a one line revert.
local MAP_GUARD = false

local SAFE_FOCUS = {
    { prefix = 'dwarfmode/Default', test = function()
        -- A test returning true forces vanilla. With the guard off the
        -- map is unconditionally safe, so the slot stands at HIDE from
        -- the first write of the load.
        if not MAP_GUARD then return false end
        return not _G.making_fuel_hide_sprite_seen end },
    { prefix = 'dwarfmode/ViewSheets' },
    -- ---- THE STOCKPILE CONFIG SCREEN ----
    -- dwarfmode/Stockpile/Paint, /Some/Default and /Some/Customize,
    -- all sharing this prefix. It lists material NAMES, not item
    -- sprites, and the only thing drawing items while it is up is the
    -- map behind it, which is the same map dwarfmode/Default already
    -- covers. Without this the gate fell through to vanilla and every
    -- skin in view washed to liquid art for as long as the menu was
    -- open.
    --
    -- Distinct from dwarfmode/Stocks, which does draw items and keeps
    -- its glob-only predicate.
    { prefix = 'dwarfmode/Stockpile' },
    -- ---- NO 'dwarfmode/Stocks' ENTRY ----
    -- Stocks is deliberately not whitelisted, so it always resolves to
    -- vanilla. stocks_shows_liquid was correct and could still never
    -- work, because the gate is reactive and the list is built and
    -- drawn on the frame the player crosses into the category. The
    -- trace caught it directly:
    --
    --   f6401  HIDE | Stocks type=69 n=7      list exists, HIDE standing
    --   f6401  HIDE -> VANILLA                correction, same frame, too late
    --
    -- and on the cold launch the same two events landed the other way
    -- round, which is why the ale changed answer between runs that
    -- were otherwise identical. No predicate wins a frame it only
    -- learns about afterwards.
    --
    -- The cost is that our skin globs draw as liquid art in the stocks
    -- Glob category. One screen, cosmetic, and it buys the permanent
    -- removal of the only remaining way a contained drink can latch.
    -- stocks_shows_liquid is kept because `gate` still reports it.
    --
    -- REINSTATED, narrowly. See the STOCKS block above: the entry is
    -- back, but its test only answers safe on the glob category, and
    -- the category change tripwire below closes the crossing frame
    -- that made the old broad version unsafe.
    { prefix = 'dwarfmode/Stocks', test = stocks_needs_vanilla },
    -- ---- NO 'dfhack/' ENTRY ----
    -- Removed, and this was the hole. A DFHack screen is not a screen
    -- in its own right for this purpose; it is a pane pushed over a DF
    -- screen that keeps drawing underneath it. focus_is_safe now reads
    -- the DF screen directly, so there is nothing left here for a
    -- dfhack focus string to match and nothing that needs to be.
}

local function focus_is_safe()
    -- ==========================================
    -- READ THE DF SCREEN, NOT THE TOP SCREEN
    -- ==========================================
    -- getCurFocus reports the focus of the TOPMOST viewscreen and
    -- nothing below it. Lua_API.txt:1101 says so outright: it is
    -- getFocusStrings(getCurViewscreen()), one screen, no stack.
    --
    -- A DFHack screen is a viewscreen pushed on top of whatever was
    -- current, and it renders the screen beneath it every frame. So
    -- with the launcher open over the drinks stock list, getCurFocus
    -- answered 'dfhack/lua/launcher', the old whitelist matched that
    -- with no test, the gate said HIDE, and the ale still drawing
    -- underneath took the hide and latched.
    --
    -- MEASURED, in the recorder timeline that was read as a race:
    --   19:08:49  FOCUS dwarfmode/Stocks
    --   19:08:53  SLOT  68813 -> 42249    drinks category, gate correct
    --   19:08:56  SLOT  42249 -> 68813    back to HIDE
    --   19:08:56  FOCUS dfhack/lua/launcher
    -- The slot returned to HIDE in the same sample the launcher opened,
    -- with the liquid list still on screen. Not a race, not a timing
    -- window: a sustained wrong answer for as long as the console is
    -- up, and every diagnostic run in this investigation was typed
    -- into that console with a liquid on screen behind it.
    --
    -- getDFViewscreen returns the topmost viewscreen NOT owned by
    -- DFHack, so a DFHack screen now inherits the verdict of the DF
    -- screen it is covering, which is the screen actually drawing.
    -- ==========================================
    local f = try(function()
        local dfs = dfhack.gui.getDFViewscreen(true)
        return dfs and dfhack.gui.getFocusStrings(dfs) or nil
    end)
    if type(f) ~= 'table' or not f[1] then return false end

    -- Any focus that is not the bare map means the player has moved
    -- and the gate has had a turn. From here the map is treated as
    -- safe for the rest of the session.
    for _, cur in ipairs(f) do
        if tostring(cur):find('dwarfmode/Default', 1, true) ~= 1 then
            _G.making_fuel_hide_sprite_seen = true
        end
    end
    for _, cur in ipairs(f) do
        local ok = false
        for _, e in ipairs(SAFE_FOCUS) do
            if tostring(cur):find(e.prefix, 1, true) == 1 then
                -- Matched. Safe unless this entry has a test saying a
                -- liquid is on screen this frame.
                ok = not (e.test and e.test())
                break
            end
        end
        if not ok then return false end
    end
    return true
end

-- ==========================================
-- WHICH SCREEN PERMITTED THIS
-- ==========================================
-- Built for the transition log below, and it exists because the log
-- was the thing that was broken. A session log could show the first
-- write landing at VANILLA and still contain no record of the slot
-- standing at HIDE six minutes later with a barrel on screen, which
-- is the only event that can latch a liquid. No screen named, no
-- window bracketed, nothing attributable after the fact.
--
-- Reports the DF focus, which is what the gate reads, plus the stocks
-- category when stocks is open, because "dwarfmode/Stocks" alone does
-- not say which list was being drawn.
-- ==========================================
local function focus_sig()
    local s = try(function()
        local dfs = dfhack.gui.getDFViewscreen(true)
        local f = dfs and dfhack.gui.getFocusStrings(dfs)
        return (type(f) == 'table') and table.concat(f, ' ') or nil
    end) or '?'
    local ct = try(function()
        local stk = df.global.game.main_interface.stocks
        if stk and stk.open then return stk.current_type end
    end)
    if ct then s = s .. '  stocks type=' .. tostring(ct) end
    return s
end

-- Forward declaration. The tripwire below runs at one frame and needs
-- the gate's verdict, but the gate is defined further down because it
-- depends on the whitelist. Declared here so the assignment later
-- binds to this local rather than creating a global.
local want_target

-- ==========================================
-- FRAME TRACE
-- ==========================================
-- Everything above logs DECISIONS. This logs STATE, once per frame,
-- and it exists because a decision log cannot answer an ordering
-- question. The session log could say the slot rose to HIDE on stocks
-- category 39 and fell on category 69 three seconds later, and still
-- not say whether the crossing into 69 happened before or after the
-- fall. One second of wall clock is sixty frames. The latch lives in
-- one of them.
--
-- So this samples the whole decision surface every frame and prints a
-- line ONLY when something in it changes. Standing still prints
-- nothing. Walking the map prints nothing. Changing screen, changing
-- stocks category, opening a sheet, or the slot moving each print one
-- line, stamped with a frame number so they can be ordered against
-- each other.
--
-- The frame number is ours, not DF's. world.frame_counter is game
-- time and does not advance while paused, and sheets get opened while
-- paused, which is precisely when this has to work.
--
-- WHAT THIS CANNOT PRINT, so it is not looked for again: the texpos an
-- item actually drew with. Section 5 of the redirect doc searched the
-- item struct, the material struct, view_sheets and all eleven gps
-- tables and found no per item render result anywhere. It is in the
-- renderer's own memory. What CAN be printed is every input that
-- decides it, which is what is below.
-- ==========================================
local TRACE_KEY    = 'making_fuel_hide_sprite_trace'
local TRACE_FRAMES = 1

_G.making_fuel_hide_sprite_tracing = _G.making_fuel_hide_sprite_tracing
if _G.making_fuel_hide_sprite_tracing == nil then
    _G.making_fuel_hide_sprite_tracing = true
end
_G.making_fuel_hide_sprite_frame   = _G.making_fuel_hide_sprite_frame or 0
_G.making_fuel_hide_sprite_lastsig = _G.making_fuel_hide_sprite_lastsig or nil
_G.making_fuel_hide_sprite_lasttype = _G.making_fuel_hide_sprite_lasttype or -1

-- One string holding everything that can affect the answer. Cheap:
-- one array read, one focus lookup, four field reads. No call to
-- want_target, because that walks the stocks list and this runs every
-- frame; the gate's own verdict is already logged where it changes.
local function trace_sample()
    local st = _G.making_fuel_hide_sprite

    -- The slot, named rather than numbered. OTHER means something
    -- neither we nor vanilla put there, which would mean the table was
    -- rebuilt under us.
    local name = 'UNCLAIMED'
    if st then
        local slot = try(function()
            return df.global.gps[st.tbl][st.idx] end)
        if slot == st.new then name = 'HIDE'
        elseif slot == st.old then name = 'VANILLA'
        else name = 'OTHER(' .. tostring(slot) .. ')' end
    end

    local focus = '?'
    try(function()
        local dfs = dfhack.gui.getDFViewscreen(true)
        local f = dfs and dfhack.gui.getFocusStrings(dfs)
        if type(f) == 'table' then focus = table.concat(f, ' ') end
    end)

    -- Stocks category AND list length. The length is what says whether
    -- the list has been built yet, which the predicate has to guess at
    -- and has been wrong about before.
    local stype, slen = -1, -1
    try(function()
        local stk = df.global.game.main_interface.stocks
        if stk and stk.open then
            stype = stk.current_type
            slen  = #stk.current_type_i_list
        end
    end)

    local sheet = 'closed'
    try(function()
        local vs = df.global.game.main_interface.view_sheets
        if vs and vs.open then
            sheet = string.format('kind=%s id=%s',
                tostring(vs.active_sheet), tostring(vs.active_id))
        end
    end)

    return string.format('%-9s | %-46s | stocks type=%-3d n=%-3d | sheet %s',
        name, focus, stype, slen, sheet)
end

-- ==========================================
-- CATEGORY CHANGE TRIPWIRE
-- ==========================================
-- The gate polls every two frames. Stocks builds and draws a category
-- list on the frame the player crosses into it, so a crossing from the
-- glob category straight into drinks used to expose the drinks list to
-- a standing HIDE before any poll could answer. This runs at ONE frame
-- and does nothing but slam the slot back to vanilla the instant the
-- category number moves, ahead of the gate deciding anything.
--
-- It is load bearing, not diagnostic, so it runs even with the trace
-- switched off. It logs only when it actually had to move the slot,
-- which makes every near miss visible without printing on the ones
-- that were already safe.
-- ==========================================
local function category_tripwire(n)
    local ct = try(function()
        local stk = df.global.game.main_interface.stocks
        if stk and stk.open then return stk.current_type end
    end) or -1
    if ct == _G.making_fuel_hide_sprite_lasttype then return end
    _G.making_fuel_hide_sprite_lasttype = ct

    local st = _G.making_fuel_hide_sprite
    if not st then return end
    local cur = try(function() return df.global.gps[st.tbl][st.idx] end)
    if cur ~= st.old and cur ~= st.new then return end

    -- ---- THE REAL ANSWER, NOT A BLANKET VANILLA ----
    -- This used to write vanilla unconditionally, which was safe and
    -- slow: entering the glob category cost a drop to vanilla plus up
    -- to two more frames before apply() came round and raised the
    -- hide, and that gap was visible.
    --
    -- Asking the gate here costs one focus lookup and one list walk on
    -- category change frames only, which are user driven and rare. The
    -- safety is unchanged because the gate's answer for any category
    -- that is not the glob list IS vanilla; this only stops us writing
    -- vanilla and then immediately writing hide over it.
    local want = want_target(st.old, st.new)
    if cur == want then return end
    local ok = pcall(function() df.global.gps[st.tbl][st.idx] = want end)

    -- Logged only on the safety critical direction. A raise to hide is
    -- cosmetic and the trace line already records it; a drop off a
    -- standing hide is the near miss worth seeing every time.
    if want == st.old then
        -- INFO: the near miss the author wanted seen every time, and user
        -- driven, so rare. WARNING when the write back to vanilla failed.
        log(ok and 'INFO' or 'WARNING', string.format('f%-7d stocks category -> %d with HIDE'
            .. ' standing; forced VANILLA ahead of the poll. %s',
            n, ct, ok and '' or 'WRITE FAILED.'), 'TRIPWIRE')
    elseif not ok then
        log('WARNING', string.format('f%-7d stocks category -> %d; HIDE write'
            .. ' FAILED.', n, ct), 'TRIPWIRE')
    end
end

local function frame_tick()
    local n = (_G.making_fuel_hide_sprite_frame or 0) + 1
    _G.making_fuel_hide_sprite_frame = n
    category_tripwire(n)
    if not _G.making_fuel_hide_sprite_tracing then return end
    local sig = trace_sample()
    if sig ~= _G.making_fuel_hide_sprite_lastsig then
        _G.making_fuel_hide_sprite_lastsig = sig
        log('DETAIL', string.format('f%-7d %s', n, sig), 'TRACE')
    end
end

function want_target(src, dst)
    -- Whitelist first. An unrecognised screen can draw anything, so it
    -- gets vanilla before any sheet logic runs. This is also what
    -- catches Stocks, which is not a sheet and would otherwise fall
    -- straight through to HIDE.
    if not focus_is_safe() then return src end
    local vs = try(function()
        return df.global.game.main_interface.view_sheets end)
    if not vs then return dst end
    if not try(function() return vs.open end) then return dst end

    -- MEASURED 11:39, and this was the bug. vs.open is true for UNIT
    -- and BUILDING sheets as well. A workshop's Items list is a
    -- BUILDING sheet whose active_id is a BUILDING id, so
    -- df.item.find below either missed or landed on an unrelated
    -- item, and the gate held VANILLA for the entire time a skin was
    -- being inspected in the butcher's.
    if sheet_shows_liquid(vs) then return src end
    return dst
end

-- Superseded by sheet_shows_liquid. Kept on file rather than deleted
-- so the two failed gating attempts are readable: first "any sheet
-- open", then "any sheet that is not an ITEM sheet". Nothing calls
-- this.
local function want_target_by_kind(src, dst)
    local vs = try(function()
        return df.global.game.main_interface.view_sheets end)
    if not vs then return dst end
    if not try(function() return vs.open end) then return dst end
    if try(function() return vs.active_sheet end) ~= ITEM_SHEET then
        return dst
    end

    -- A sheet is up. If it is one of ours, the hide is correct and no
    -- liquid is being drawn by it.
    local id = try(function() return vs.active_id end)
    local it = id and df.item.find(id)
    if not it then return src end
    local mi = try(function() return dfhack.matinfo.decode(it) end)
    local tok = mi and try(function() return mi:getToken() end)
    if tok and tostring(tok):find(OUR_PREFIX, 1, true) then return dst end
    return src
end

local function apply()
    local st = _G.making_fuel_hide_sprite

    -- Still standing exactly as written: nothing to do. This is the
    -- path every poll takes when the world is quiet.
    if st then
        local cur = try(function() return df.global.gps[st.tbl][st.idx] end)
        local want = want_target(st.old, st.new)
        if cur == want then return end
        if cur == st.old or cur == st.new then
            -- ---- EVERY TRANSITION IS ANNOUNCED ----
            -- This flip was silent on the grounds that it happens
            -- constantly. That is exactly why it had to be logged: the
            -- rise to HIDE is the only event that can latch a liquid,
            -- and nothing anywhere recorded when it happened or what
            -- was on screen while it did.
            --
            -- Volume is low because this branch only runs when the slot
            -- is not already where the gate wants it. Once it flips,
            -- every later poll takes the cur == want early return above
            -- and says nothing, so a HIDE window is one line no matter
            -- how long it lasts.
            log('DETAIL', string.format('f%-7d %s -> %s on %s',
                _G.making_fuel_hide_sprite_frame or -1,
                cur == st.new and 'HIDE' or 'VANILLA',
                want == st.new and 'HIDE' or 'VANILLA',
                focus_sig()), 'FLIP')
            -- Ours, on the other setting. Flip it with no search and
            -- no log line: this happens every time a sheet opens or
            -- closes, which is constantly.
            pcall(function() df.global.gps[st.tbl][st.idx] = want end)
            return
        end
        -- The table moved under us. Say so and rebuild from scratch,
        -- because the index may have shifted along with the value.
        log('DETAIL', string.format('%s[%d] no longer holds the redirect'
            .. ' (reads %s). Table rebuilt; re-aiming.',
            st.tbl, st.idx, tostring(cur)), 'APPLY')
        _G.making_fuel_hide_sprite = nil
    end

    local src = page_cell(SOURCE)
    local dst = page_cell(TARGET)
    if not src or not dst then
        log('WARNING', string.format('page missing: %s=%s %s=%s. Nothing written.',
            SOURCE.page, tostring(src), TARGET.page, tostring(dst)), 'APPLY')
        return
    end

    local tbl, idx = find_holder(src)
    if not tbl then
        -- Not holding the vanilla value and not holding ours: either
        -- the redirect survived under a shifted index, or the pointer
        -- moved somewhere new. Check for ours before complaining.
        -- ---- NO find_holder(dst) FALLBACK ----
        -- Deleted, again. The redirect doc's failure history already
        -- records this being removed once and it was still here.
        --
        -- Searching for the TARGET value always succeeds, because the
        -- HIDES page registers its own cells: the probe shows
        -- texture_indices8[43] holding the same texpos our redirect
        -- writes. So this branch adopts a page registration slot as
        -- though it were the pointer, and every later vanilla write
        -- from the gate lands in the HIDES page instead.
        --
        -- If nothing holds the vanilla value, the honest answer is that
        -- the pointer is not where we can see it, and the sprite stays
        -- vanilla. apply() only ever claims a slot that held the
        -- vanilla value.
        log('WARNING', 'ITEM_LIQUID value not found in any gps table. Pointer has'
            .. ' moved on this build; sprite left vanilla.', 'APPLY')
        return
    end

    _G.making_fuel_hide_sprite = { tbl = tbl, idx = idx, old = src, new = dst }
    local wrote = want_target(src, dst)
    local ok = pcall(function()
        df.global.gps[tbl][idx] = wrote
    end)
    if not ok then
        log('WARNING', string.format('%s[%d] write THREW. Sprite left vanilla.',
            tbl, idx), 'APPLY')
        return
    end
    _G.making_fuel_hide_sprite = { tbl = tbl, idx = idx, old = src, new = dst }
    -- Reports what was ACTUALLY written. The old line printed src and
    -- dst and the words "now wear HIDES" whatever the gate decided, so
    -- three sessions of logs could not answer whether the first write
    -- of a load landed on the hide or on vanilla.
    log('DETAIL', string.format('%s[%d] claimed (vanilla %d, hide %d). First write'
        .. ' put %d = %s on %s.', tbl, idx, src, dst, wrote,
        wrote == dst and 'HIDE' or 'VANILLA', focus_sig()), 'APPLY')
end

local function restore()
    local st = _G.making_fuel_hide_sprite
    if not st then return end
    -- Only put the old value back if the redirect is still what is
    -- standing there. A rebuilt table already holds vanilla, and
    -- blindly writing an old texpos into a reshuffled table would be
    -- exactly the kind of silent damage this module exists to avoid.
    local cur = try(function() return df.global.gps[st.tbl][st.idx] end)
    if cur == st.new or cur == st.old then
        local ok = pcall(function() df.global.gps[st.tbl][st.idx] = st.old end)
        log(ok and 'DETAIL' or 'WARNING', ok and string.format('%s[%d] restored to vanilla.', st.tbl, st.idx)
            or string.format('%s[%d] could not be restored.', st.tbl, st.idx), 'RESTORE')
    else
        log('DETAIL', string.format('%s[%d] already vanilla (table rebuilt);'
            .. ' nothing to restore.', st.tbl, st.idx), 'RESTORE')
    end
    _G.making_fuel_hide_sprite = nil
end

-- ==========================================
-- LIFECYCLE
-- ==========================================
function start()
    log('DETAIL', string.format('start() called. running=%s state=%s focus=%s',
        tostring(_G.making_fuel_hide_sprite_running),
        _G.making_fuel_hide_sprite and 'STANDING' or 'none',
        tostring((try(function()
            return dfhack.gui.getCurFocus(true)[1] end)))), 'START')
    if _G.making_fuel_hide_sprite_running then
        if _G.making_fuel_hide_sprite_body == BODY then
            log('DETAIL', 'already running.', 'START') return
        end
        -- Reloaded mid world. Rebind both loops to this body's copies
        -- and leave the claimed slot alone: the claim record lives in
        -- _G and apply() owns it, so re-running the claim here would
        -- adopt a second slot.
        _G.making_fuel_hide_sprite_body = BODY
        repeatUtil.scheduleEvery(POLL_KEY, POLL_FRAMES, 'frames', apply)
        repeatUtil.scheduleEvery(TRACE_KEY, TRACE_FRAMES, 'frames',
            frame_tick)
        log('DETAIL', 'reloaded: poll and trace rebound to the new body.', 'START')
        return
    end
    _G.making_fuel_hide_sprite_body = BODY
    _G.making_fuel_hide_sprite_running = true

    -- ---- REARM THE MAP GUARD, ONCE PER WORLD ----
    -- start() is the one thing guaranteed to run on every world load,
    -- so the flag is cleared here rather than trusted to reset itself.
    -- See the block beside its declaration for what happens when it
    -- carries over: the whole reload versus cold launch split.
    _G.making_fuel_hide_sprite_seen = false

    -- ---- NOTHING IS WRITTEN HERE ----
    -- The first write is handed to a timer so it lands after the world
    -- is up. See FIRST_TICKS at the top of the file for what happens
    -- when it lands during load instead. The poll only begins once
    -- that first write has happened.
    _G.making_fuel_hide_sprite_timer = dfhack.timeout(FIRST_FRAMES, 'frames',
        function()
            _G.making_fuel_hide_sprite_timer = nil
            apply()
            repeatUtil.scheduleEvery(POLL_KEY, POLL_FRAMES, 'frames', apply)
            -- The trace runs at ONE frame while the gate runs at two,
            -- deliberately. That is what makes the gate's own lag
            -- visible: a category change and the correction that
            -- follows it land on different trace lines with different
            -- frame numbers, and the gap between them is the window a
            -- liquid can latch in.
            repeatUtil.scheduleEvery(TRACE_KEY, TRACE_FRAMES, 'frames',
                frame_tick)
        end)
    if not _G.making_fuel_hide_sprite_timer then
        log('WARNING', 'could not schedule the first write, world not loaded.'
            .. ' Sprite left vanilla.', 'START')
    end
end

local function dead_start()
    apply()
    repeatUtil.scheduleEvery(POLL_KEY, POLL_TICKS, 'ticks', apply)
end

function stop()
    log('DETAIL', string.format('stop() called. running=%s state=%s',
        tostring(_G.making_fuel_hide_sprite_running),
        _G.making_fuel_hide_sprite and 'STANDING' or 'none'), 'STOP')
    _G.making_fuel_hide_sprite_running = false

    -- ==========================================
    -- DROP THE STATE BEFORE RESTORE CAN TRUST IT
    -- ==========================================
    -- On a world unload the texpos numbers in the slot record are about
    -- to become meaningless: the next world rebuilds the gps tables with
    -- its own numbering. restore() below reads those indices, and if it
    -- runs against a new world's tables it writes into whatever now sits
    -- at the old index. So restore is given exactly one chance to act on
    -- a still valid record, and the record is cleared here so no later
    -- start() in a fresh world can inherit it.
    --
    -- This is the reset that `local running` was silently skipping.
    -- ==========================================
    -- Cancel the pending first write as well, or stopping during the
    -- wait leaves a timer that fires into a stopped module and paints
    -- the sprite after you asked for it to be off.
    if _G.making_fuel_hide_sprite_timer then
        pcall(function()
            dfhack.timeout_active(_G.making_fuel_hide_sprite_timer, nil)
        end)
        _G.making_fuel_hide_sprite_timer = nil
    end
    pcall(function() repeatUtil.cancel(POLL_KEY) end)
    pcall(function() repeatUtil.cancel(TRACE_KEY) end)
    _G.making_fuel_hide_sprite_lastsig = nil
    restore()
end

function status()
    local st = _G.making_fuel_hide_sprite
    if not st then print('not standing.') return end
    local cur = try(function() return df.global.gps[st.tbl][st.idx] end)
    print(string.format('%s[%d] holds %s (redirect wrote %d, vanilla %d).',
        st.tbl, st.idx, tostring(cur), st.new, st.old))
end

-- ==========================================
-- COMMAND: gate
-- ==========================================
-- What the gate decides right now, and why. Run it with a sheet open
-- and again with it closed. This exists because the gate failing
-- silently cost a whole test run: the slot read vanilla and there was
-- nothing anywhere saying which branch had put it there.
-- ==========================================
function gate()
    -- ---- BOTH FOCUS STACKS ----
    -- The top viewscreen and the top DF viewscreen differ whenever a
    -- DFHack screen is open, which is always when this command is being
    -- typed. The gate reads the second one. Printing both makes the
    -- difference visible instead of leaving it to be inferred, which is
    -- what cost two sessions.
    local top = try(function()
        return table.concat(dfhack.gui.getCurFocus(true), ' ') end)
    local dfv = try(function()
        local s = dfhack.gui.getDFViewscreen(true)
        return s and table.concat(dfhack.gui.getFocusStrings(s), ' ') end)
    print(string.format('focus top = %s', tostring(top)))
    print(string.format('focus DF  = %s   <- the gate reads this one',
        tostring(dfv)))

    local st  = _G.making_fuel_hide_sprite
    local src = page_cell(SOURCE)
    local dst = page_cell(TARGET)
    local vs  = try(function()
        return df.global.game.main_interface.view_sheets end)
    local open = vs and try(function() return vs.open end)
    local kind = vs and try(function() return vs.active_sheet end)
    local id   = vs and try(function() return vs.active_id end)
    local it   = id and df.item.find(id)
    local mi   = it and try(function() return dfhack.matinfo.decode(it) end)
    local tok  = mi and try(function() return mi:getToken() end)
    local want = want_target(src, dst)

    print(string.format('sheet open=%s kind=%s (ITEM kind is %s) id=%s',
        tostring(open), tostring(kind), tostring(ITEM_SHEET), tostring(id)))
    print(string.format('that id as an item: %s',
        it and tostring(tok) or 'not an item'))
    print(string.format('gate wants %s = %s.  vanilla=%s hide=%s',
        tostring(want), want == dst and 'HIDE' or 'VANILLA',
        tostring(src), tostring(dst)))
    -- ---- STOCKS ----
    -- The predicate meant to hold the slot vanilla while a liquid
    -- category is on screen. Reported in full because the recorder
    -- showed the slot standing at HIDE for an entire stocks visit and
    -- nothing anywhere said which branch permitted it.
    local stk = try(function()
        return df.global.game.main_interface.stocks end)
    if not stk then
        print('stocks: struct unreadable.')
    else
        local open  = try(function() return stk.open end)
        local ctype = try(function() return stk.current_type end)
        local list  = try(function() return stk.current_type_i_list end)
        local n     = list and try(function() return #list end) or nil
        print(string.format('stocks: open=%s current_type=%s list_len=%s',
            tostring(open), tostring(ctype), tostring(n)))
        if list and n and n > 0 then
            local shown = 0
            try(function()
                for _, it in ipairs(list) do
                    if shown >= 6 then return end
                    shown = shown + 1
                    local ty = try(function()
                        return tostring(df.item_type[it:getType()]) end)
                    local mi = try(function()
                        return dfhack.matinfo.decode(it) end)
                    print(string.format('   [%d] %-14s %-28s liquid=%s',
                        shown, tostring(ty),
                        mi and tostring(try(function()
                            return mi:getToken() end)) or '?',
                        tostring(is_liquid_item(it))))
                end
            end)
        end
        print(string.format('stocks_shows_liquid() = %s   (true means the'
            .. ' gate must force VANILLA)',
            tostring(stocks_shows_liquid())))
    end

    if st then
        print(string.format('%s[%d] currently holds %s', st.tbl, st.idx,
            tostring(try(function()
                return df.global.gps[st.tbl][st.idx] end))))
    else
        print('watcher not standing.')
    end
end

-- ==========================================
-- CLI
-- ==========================================
-- The guard is not optional. `--@ module = true` only makes the file
-- reqscript-able; it does NOT stop the body running.
-- ==========================================
if dfhack_flags and dfhack_flags.module then return end

local cmd = ...
local arg2 = select(2, ...)
if cmd == 'trace' then
    if arg2 == 'off' then
        _G.making_fuel_hide_sprite_tracing = false
        print('frame trace OFF.')
    else
        _G.making_fuel_hide_sprite_tracing = true
        _G.making_fuel_hide_sprite_lastsig = nil
        print('frame trace ON. One line per change, stamped with a frame'
            .. ' number.')
    end
elseif cmd == 'gate' then gate()
elseif cmd == 'on' then start()
elseif cmd == 'off' then stop()
elseif cmd == 'status' then status()
else print('usage: making-fuel-hide-sprite on | off | status | gate'
        .. ' | trace [off]') end