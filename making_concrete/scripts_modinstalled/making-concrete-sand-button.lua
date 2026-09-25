--@ module = true
-- making-concrete-sand-button.lua
-- ==========================================
-- MAKING CONCRETE: COLLECT SAND BUTTON INJECTOR
-- ==========================================
-- Injects a native "Collect Sand" button into the mason
-- workshop's order list. The button creates a real CollectSand
-- job (job_type 24) identical to the glass furnace's native one.
--
-- HOW IT WORKS:
--   DF rebuilds the workshop order list every time the player
--   opens a workshop's order panel. This script runs a 1-frame
--   polling check: if the player is viewing a mason workshop and
--   the button hasn't been injected for this open session, inject
--   it into both the master (button) and display (filtered_button)
--   vectors.
--
-- GATE SEQUENCE:
--   Gate 1 — Are both button vectors populated? (skip if empty)
--   Gate 2 — Is view_sheets open? (skip if not viewing a building)
--   Gate 3 — Is the viewed building a mason? (skip if not)
--   Gate 4 — Do the buttons belong to THIS mason? (skip if stale)
--   Gate 5 — Have we already injected for this building session?
--            (skip if yes — prevents category submenu injection)
--
-- CATEGORY LEAK PREVENTION:
--   DF rebuilds both button vectors when the player navigates
--   into a category submenu. Without Gate 5, the injector would
--   see "mason is open, no collect sand, inject" and drop the
--   button into the category view. By tracking the building ID
--   we last injected for, we inject exactly once per mason open
--   session. DF handles all subsequent list rebuilds (category
--   navigation, search filtering) on its own — our injected
--   entry in the initial top-level list doesn't carry into
--   category submenus because DF rebuilds from scratch.
--
-- ORDERING:
--   DF's order list is type-segregated: category selectors first,
--   then new_jobst entries alphabetically. The injector finds the
--   correct position among new_jobst entries so "collect sand"
--   appears naturally in alphabetical order.
--
-- LIFECYCLE:
--   start() — registers the polling check
--   stop()  — cancels it
--   Called from making_concrete.lua during module boot/shutdown.
--
-- REFERENCE:
--   See RM_Native_Button_Injection.md for the full technique
--   documentation, discovery notes, and field reference.
-- ==========================================

local repeatUtil = require('repeat-util')

local REPEAT_KEY = 'making_concrete_sand_button'

-- ==========================================
-- CONSTANTS
-- ==========================================
local WORKSHOP_TYPE     = 13    -- df.building_type.Workshop
local MASON_SUBTYPE     = 2     -- df.workshop_type.Masons
local COLLECT_SAND_JOB  = 24    -- df.job_type.CollectSand
local COLLECT_SAND_ITEM = 115   -- df.item_type.TOOL (bag)
local COLLECT_SAND_STR  = "collect sand"

-- ==========================================
-- SESSION TRACKING
-- ==========================================
-- Tracks which building we last injected for. Prevents
-- re-injection when the player navigates into category
-- submenus (which rebuild the button vectors). Reset when
-- the panel closes or a different building is viewed.
-- ==========================================
local last_injected_bld_id = -1


-- ==========================================
-- CREATE BUTTON
-- ==========================================
-- Builds a new interface_button_building_new_jobst with the
-- same field values as the glass furnace's native CollectSand
-- entry. The bd pointer is set to the target mason workshop.
-- ==========================================
local function make_button(mason)
    local btn = df.interface_button_building_new_jobst:new()
    btn.bd                    = mason
    btn.filter_str            = COLLECT_SAND_STR
    btn.jobtype               = COLLECT_SAND_JOB
    btn.itemtype              = COLLECT_SAND_ITEM
    btn.subtype               = -1
    btn.material              = -1
    btn.matgloss              = -1
    btn.mstring               = ""
    btn.add_building_location = false
    btn.show_help_instead     = false
    btn.art_specifier         = -1
    btn.art_specifier_id1     = -1
    btn.art_specifier_id2     = -1
    btn.objection             = ""
    btn.info                  = ""
    return btn
end


-- ==========================================
-- FIND INSERTION INDEX
-- ==========================================
-- Walks the button vector to find the correct alphabetical
-- position among new_jobst entries. Category selectors are
-- skipped — they always appear at the top of the list.
-- Returns the index to insert at.
-- ==========================================
local function find_insert_idx(vec)
    for i = 0, #vec - 1 do
        local b = vec[i]
        if b._type == df.interface_button_building_new_jobst
           and b.filter_str > COLLECT_SAND_STR then
            return i
        end
    end
    return #vec
end


-- ==========================================
-- POLLING CALLBACK
-- ==========================================
-- Runs every frame. Five gates ensure we only inject once
-- when the player first opens a mason workshop's order panel.
-- Subsequent list rebuilds (category navigation, search) are
-- left to DF — our button only lives at the top level.
-- ==========================================
local function on_tick()
    local mi = df.global.game.main_interface
    local fb = mi.building.filtered_button
    local mb = mi.building.button

    -- Gate 1: Both vectors must be populated. During transitions
    -- between workshops, the master vector (button) is briefly
    -- empty while filtered_button still has stale entries. Both
    -- must be populated for the list to be fully rebuilt.
    if #fb == 0 or #mb == 0 then
        -- Panel closed or mid-transition — reset session tracking
        -- so we re-inject when a mason next opens.
        last_injected_bld_id = -1
        return
    end

    -- Gate 2: The building view panel must be open.
    local vs = mi.view_sheets
    if not vs.open then
        last_injected_bld_id = -1
        return
    end

    -- Gate 3: The viewed building must be a mason workshop.
    local bld = df.building.find(vs.viewing_bldid)
    if not bld then
        last_injected_bld_id = -1
        return
    end
    if bld:getType() ~= WORKSHOP_TYPE or bld:getSubtype() ~= MASON_SUBTYPE then
        -- Different building type — reset so we catch the next mason.
        last_injected_bld_id = -1
        return
    end

    -- Gate 4: The buttons must belong to THIS mason. When
    -- switching workshops, viewing_bldid updates before the
    -- button vectors are rebuilt. The first button's bd pointer
    -- tells us whether the list has been rebuilt for the current
    -- building yet. If it hasn't, skip this frame — DF will
    -- rebuild on a subsequent frame and we'll catch it then.
    local ok, first_bd = pcall(function() return fb[0].bd end)
    if not ok or first_bd ~= bld then return end

    -- Gate 5: Only inject once per building open session.
    -- After injecting, we record the building ID. As long as
    -- the same mason stays open, we skip. This prevents
    -- re-injection when DF rebuilds the button lists for
    -- category submenus — those rebuilds happen while the
    -- same building is still viewed, so the ID matches and
    -- we correctly skip. When the player closes the mason
    -- or switches to a different building, Gates 1-3 reset
    -- the ID, allowing fresh injection on the next mason open.
    if bld.id == last_injected_bld_id then return end

    -- ---- INJECT INTO BOTH VECTORS ----
    mb:insert(find_insert_idx(mb), make_button(bld))
    fb:insert(find_insert_idx(fb), make_button(bld))

    -- Record that we've injected for this building session
    last_injected_bld_id = bld.id
end


-- ==========================================
-- PUBLIC API
-- ==========================================

function start()
    -- 1-frame interval ensures the button appears on the very
    -- next frame after DF finishes rebuilding the order list.
    -- The gate checks make this effectively free when not
    -- viewing a mason — Gate 1 exits immediately on empty vectors.
    last_injected_bld_id = -1
    repeatUtil.scheduleEvery(REPEAT_KEY, 1, 'frames', on_tick)
end

function stop()
    repeatUtil.cancel(REPEAT_KEY)
    last_injected_bld_id = -1
end


-- ==========================================
-- NO AUTO-START
-- ==========================================
-- Lifecycle managed by making_concrete.lua:
--   start() called during module boot
--   stop() called on SC_MAP_UNLOADED
-- For manual testing, run:
--   lua reqscript('making-concrete-sand-button').start()
-- ==========================================

return _ENV