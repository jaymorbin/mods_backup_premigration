--@ module = true
-- making_fuel.lua
-- ==========================================
-- RM MODULE TEMPLATE (ADVANCED TABLES)
-- ==========================================
-- Universal Lua shell for RM (Refinish Metal) modules that need
-- runtime logic beyond what JSON alone can express. Provides:
--
--   1. JSON loading from your mod's data/ folder
--   2. Weighted material value calculation (auto-compute from
--      a reaction's BAR reagents when value is null)
--   3. Registration with RM's module engine
--
-- HOW VALUE CALCULATION WORKS:
--   If a material in your JSON has "value": null, this template
--   will compute its value from a linked reaction's metal bar
--   reagents. The link is specified on the material itself:
--
--     { "key": "ALLOY_SHAKUDO", "value": null,
--       "value_from_reaction": "FORGE_SHAKUDO", ... }
--
--   The template finds that reaction by key, reads its BAR
--   reagents, and computes a weighted average of their material
--   values (weighted by quantity). This lets alloy values reflect
--   their component metals' values, which vary by world.
--
--   If you don't need computed values, just set explicit numeric
--   values on all your materials and the calculator never fires.
--
-- SETUP:
--   1. Copy this file into your mod's scripts folder.
--   2. Rename it to match your mod (e.g., making_fuel.lua).
--   3. Edit the CONFIGURATION section below.
--   4. Place your JSON data files in your mod's data/ folder.
--
-- REQUIREMENTS:
--   - Refinish Metal must be installed and active.
-- ==========================================

local json = require('json')
local scriptmanager = require('script-manager')


-- ==========================================
-- CONFIGURATION: edit these to match your mod
-- ==========================================

-- Must match the [ID:...] in your mod's info.txt
local MODULE_ID = "making_fuel"

-- Friendly name for RM's log output
local MODULE_NAME = "Making Fuel"

-- ---- LOG IDENTITY, DECLARED HERE ----
-- RM core does not know this module exists and must never have to,
-- so the module states its own identity rather than leaving core to
-- infer it from a prefix string.
--
-- SUBSYSTEM is MODULE because this file IS the module: it registers
-- with RM and starts and stops the background scripts. SUBJECT is
-- which background script a line is about, which is the first real
-- use of the correlation column: GHOST, HIJACKER, AIR_DRY. Scanning
-- that column tells you at a glance which parts came up and which
-- did not.
--
-- Guarded reqscript: a bare top level one is a hard load time
-- dependency and has taken a module down before. Without it the log
-- falls back to the same grammar, unsanitised, and the module still
-- loads.
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'MODULE'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

-- ---- TINT ART, REGISTERED AT LOAD ----
-- Must run BEFORE the engine injects anything, because a TINT: source
-- is resolved during the inject and a missing registration fails there,
-- leaving the slot at zero. Zero is "use DF's default item sprite",
-- which DF tints, so the whole system failing renders as correctly
-- coloured vanilla shapes and reads as working.
--
-- Here rather than in start_background_scripts for exactly that reason:
-- the background scripts start after the injects, which is too late.
-- Registering is pure data, it touches nothing in DF, so load time is
-- safe.
--
-- Guarded like the log reqscript above: art missing should cost the
-- sprites, never the module.
pcall(function() reqscript('refinish-sprite-art-vanilla') end)
pcall(function() reqscript('refinish-sprite-art-boulders') end)
pcall(function() reqscript('refinish-sprite-art-skins') end)
pcall(function() reqscript('refinish-sprite-art-construction') end)
pcall(function() reqscript('making-fuel-sprite-art') end)
pcall(function() reqscript('making-fuel-sprite-art-tools') end)

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
-- SUBJECT is the correlation slot: REGISTER while the data files load,
-- then the name of each background script as it starts (GHOST,
-- HIJACKER, AIR_DRY and the rest). A script that fails to start is an
-- ERROR. One that starts is DETAIL: the module engine's roster already
-- says the module came up, and Quiet and Normal only need to hear
-- about the one that did not.
--
-- This replaces a log() that printed every line to the console as
-- well as logging it, at every load, and fell back on refinish-log's
-- guess (read_type) for the lines that gave no TYPE.
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

-- JSON file names (relative to your mod's data/ folder)
local MATERIALS_FILE = "making_fuel_materials.json"
-- The reaction set is split by menu family, loaded in THIS order and
-- concatenated. Category array order is menu tab order, so the list
-- below is load-bearing: this sequence rebuilds the original
-- category list element for element. A reaction moves between
-- families by moving its block; the loader only cares that no key
-- appears twice.
local REACTIONS_FILES = {
    "making_fuel_reactions_ash.json",
    "making_fuel_reactions_boil.json",
    "making_fuel_reactions_char.json",
    "making_fuel_reactions_coke.json",
    "making_fuel_reactions_distil.json",
    "making_fuel_reactions_hide.json",
    "making_fuel_reactions_other.json",
    "making_fuel_reactions_retort.json",
    "making_fuel_reactions_split.json",
}
local TOOLS_FILE = "making_fuel_tools.json"
local BUILDINGS_FILE = "making_fuel_buildings.json"

-- The plant host that carries the coal materials, and the undo
-- switch for the whole plant path. Set to nil and nothing is
-- injected, the engine skips its plants step, and the inorganic
-- coals in the materials file carry on exactly as before. One word,
-- because this path exists only to drop the "bars" suffix and is
-- not worth a broken fort.
local PLANTS_FILE = "making_fuel_plants.json"

-- Set to nil if your mod only has materials or only reactions
-- local MATERIALS_FILE = nil   -- uncomment if no materials
-- local REACTIONS_FILE = nil   -- uncomment if no reactions


-- ==========================================
-- DO NOT EDIT BELOW THIS LINE
-- ==========================================


-- ==========================================
-- JSON LOADER
-- ==========================================
-- Reads and parses a JSON file from disk.
-- Returns the parsed Lua table, or nil on failure.
-- ==========================================
local function load_json(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*all")
    file:close()
    if not content or content == "" then return nil end
    local ok, parsed = pcall(json.decode, content)
    if not ok then return nil end
    return parsed
end


-- ==========================================
-- VALUE CALCULATOR
-- ==========================================
-- Computes a weighted average material value from a reaction's
-- BAR reagents. Weights are proportional to bar quantity.
--
-- Only BAR reagents contribute; non-metal inputs like
-- flux, coal, boulders, and powders don't have meaningful
-- material values for pricing purposes.
--
-- This reads live material values from the loaded world at
-- token-call time, so alloy values correctly reflect the
-- current world's metal economy.
--
-- Returns: integer value (minimum 1)
-- ==========================================
local function calculate_weighted_value(reagents)
    local inorganics = df.global.world.raws.inorganics.all

    -- Build a value lookup from every loaded inorganic
    local value_lookup = {}
    for _, mat in ipairs(inorganics) do
        value_lookup[mat.id] = mat.material.material_value
    end

    local total_quantity = 0
    local weighted_sum = 0

    for _, rgt in ipairs(reagents) do
        -- Only count metal bar reagents: they carry the
        -- meaningful value signal for alloy pricing
        if rgt.type == "BAR" and rgt.mat_id then
            local base_val = value_lookup[rgt.mat_id] or 1
            local qty = rgt.quantity or 150
            weighted_sum = weighted_sum + (base_val * qty)
            total_quantity = total_quantity + qty
        end
    end

    if total_quantity > 0 then
        return math.floor(weighted_sum / total_quantity)
    end
    return 1
end


-- ==========================================
-- BACKGROUND SCRIPT MANAGEMENT
-- ==========================================
local function start_background_scripts(reactions)
    -- ---- PLAYER SETTINGS FIRST ----
    -- This fort's choices from the RM HUD go into making-fuel-tuning's T
    -- before anything below starts or pays, so no script ever polls on
    -- the previous fort's values. If the settings file will not load,
    -- the module runs on T's shipped defaults and says so.
    local ok_set, set = pcall(reqscript, 'making-fuel-settings')
    if ok_set and set and set.apply_all then
        local ok_a, err_a = pcall(set.apply_all)
        if not ok_a then
            log('ERROR', "Settings FAILED to apply: " .. tostring(err_a)
                .. ". Running on tuning defaults.", 'SETTINGS')
        end
    elseif not ok_set then
        log('ERROR', "COULD NOT LOAD making-fuel-settings: " .. tostring(set)
            .. ". Running on tuning defaults.", 'SETTINGS')
    end
    -- A subsystem a player can switch off starts only when on. With no
    -- settings file everything counts as on, as it always has.
    local function on(key)
        if not (ok_set and set and set.is_on) then return true end
        return set.is_on(key)
    end

    -- Start the JIT Watcher
        -- start() is pcall wrapped, not just reqscript. An error thrown
    -- inside a background script's start used to propagate into the
    -- module's token call, so the ENGINE reported the module as
    -- crashed and it failed to call at all. One bad line in the
    -- watcher took down every reaction, every material and every tool
    -- in the module, and named none of them.
    local ok_watcher, watcher = pcall(reqscript, 'making-fuel-ghost')
    if ok_watcher and watcher and watcher.start then
        local ok_start, err_start = pcall(watcher.start, reactions)
        if ok_start then
            log('DETAIL', "Ghost ONLINE.", 'GHOST')
        else
            log('ERROR', "Ghost FAILED TO START: " .. tostring(err_start), 'GHOST')
        end
    elseif not ok_watcher then
        log('ERROR', "COULD NOT LOAD making-fuel-ghost: " .. tostring(watcher), 'GHOST')
    end

    -- ---- THE SWITCHABLE THREE ----
    -- The branch spawner, the pooper and air drying are player settings
    -- (see making-fuel-settings). Switched off, each is stopped rather
    -- than merely not started: this runs at every token call, and one
    -- switched off since the last may still be running. stop() on a
    -- stopped script is harmless.

    -- Start the Kindling Spawner
    local ok_spawner, spawner = pcall(reqscript, 'making-fuel-branch-spawner')
    if ok_spawner and spawner and spawner.start then
        if on('BRANCH_SPAWNER_ENABLED') then
            spawner.start()
            log('DETAIL', "Branch Spawner started.", 'BRANCH_SPAWNER')
        else
            pcall(spawner.stop)
            log('DETAIL', "Branch Spawner off in settings.", 'BRANCH_SPAWNER')
        end
    end

    -- Start the Dung Spawner
    local ok_pooper, pooper = pcall(reqscript, 'making-fuel-pooper')
    if ok_pooper and pooper and pooper.start then
        if on('POOPER_ENABLED') then
            pooper.start()
            log('DETAIL', "Pooper started.", 'POOPER')
        else
            pcall(pooper.stop)
            log('DETAIL', "Pooper off in settings.", 'POOPER')
        end
    end

    -- Start Air Drying. Wet fuel converts to dried with time.
    local ok_airdry, airdry = pcall(reqscript, 'making-fuel-air-dry')
    if ok_airdry and airdry and airdry.start then
        if on('AIR_DRY_ENABLED') then
            pcall(airdry.start)
            log('DETAIL', "Air Dryer started.", 'AIR_DRY')
        else
            pcall(airdry.stop)
            log('DETAIL', "Air Dryer off in settings.", 'AIR_DRY')
        end
    end

    -- Start the Rot Watcher: fills queued CHAR_ROT jobs with
    -- rotten items so the native reaction targets rot.
    local ok_rotw, rotw = pcall(reqscript, 'making-fuel-rot-watcher')
    if ok_rotw and rotw and rotw.start then
        pcall(rotw.start)
    end

    -- Start the Cremation Watcher: holds one key per kind at each
    -- pyre that can reach that kind of remains, and picks the corpse
    -- itself, because nothing on a corpse ITEM separates a citizen
    -- from an invader.
    local ok_crem, crem = pcall(reqscript, 'making-fuel-cremate-watcher')
    if ok_crem and crem and crem.start then
        pcall(crem.start)
    end

    -- Start the Drain Key Watcher: holds one drain key inside each
    -- retort whose banks carry a whole package of a liquid, and none
    -- anywhere else, so RETORT_DRAIN reads available exactly at the
    -- furnaces that have something to pour.
    local ok_dkey, dkey = pcall(reqscript, 'making-fuel-drain-key')
    if ok_dkey and dkey and dkey.start then
        pcall(dkey.start)
    end

    -- Start the Liquid Fuel Tanks directly after the drain key,
    -- because it is the same kind of script: per building reaction
    -- clones, adopted by the ghost through register_alias, shown only
    -- at the building the player has open. Both need the ghost live
    -- first, and it is by this point.
    --
    -- The fuel WAIVER does not depend on this start. It lives in
    -- making-fuel-access.lua and only reads the tank table. What needs
    -- start() is the FILL: without the fast poll no clone is ever cut
    -- and "fill fuel tank" appears in no furnace's task list.
    local ok_tank, tank = pcall(reqscript, 'making-fuel-tank-fuel')
    if ok_tank and tank and tank.start then
        local ok_s, err_s = pcall(tank.start)
        if ok_s then
            log('DETAIL', "Tank Fuel started.", 'TANK_FUEL')
        else
            log('ERROR', "Tank Fuel FAILED to start: " .. tostring(err_s), 'TANK_FUEL')
        end
    end

    -- Start the Still, beside the tanks its spirit fuels. It owns spirit
    -- from booze: a whole barrel distilled into one vessel, done at
    -- completion because the reaction itself mints nothing. It needs
    -- nothing started before it, and nothing needs it.
    local ok_still, still = pcall(reqscript, 'making-fuel-still')
    if ok_still and still and still.start then
        local ok_s, err_s = pcall(still.start)
        if ok_s then
            log('DETAIL', "Still started.", 'STILL')
        else
            log('ERROR', "Still FAILED to start: " .. tostring(err_s), 'STILL')
        end
    end

    -- Start the Hide Chain. Three scripts, in this order, because each
    -- one needs the one before it to already be live.
    --
    -- 1. hide-mats renames every vanilla creature skin to "rawhide" and
    --    owns the per-creature currency materials. The rename is a RAM
    --    edit of the loaded raws, so a crash costs nothing: the next
    --    world load reads the raw files clean.
    -- 2. hide-watcher hooks butchery and mints the currency globs. It
    --    asks hide-mats to inject a material the first time an animal is
    --    seen, so mats has to be live before it.
    -- 3. hide-chain drives COMBINE_PARTIAL_SKIN and PROCESS_SKIN.
    --    Without it BOTH reactions run as bare DF declarations: COMBINE
    --    takes any two partials it can reach regardless of animal, and
    --    PROCESS pays no rawhide at all because a corpsepiece is not a
    --    thing a reaction can declare.
    local ok_hmats, hmats = pcall(reqscript, 'making-fuel-hide-mats')
    if ok_hmats and hmats and hmats.rename_vanilla then
        pcall(hmats.rename_vanilla)
    end

    -- true is ARM. start(false) is the preview mode the CLI exposes,
    -- which reports every butchered animal and changes nothing.
    local ok_hwatch, hwatch = pcall(reqscript, 'making-fuel-hide-watcher')
    if ok_hwatch and hwatch and hwatch.start then
        pcall(hwatch.start, true)
    end

    local ok_hrxn, hrxn = pcall(reqscript, 'making-fuel-hide-chain')
    if ok_hrxn and hrxn and hrxn.start then
        pcall(hrxn.start)
    end

    -- 4. hide-rot spoils untanned hides on item age and sets
    --    flags.rotten itself. DF never rots a glob: rot_timer recycles
    --    at 200 without flipping the flag, measured on vanilla llama
    --    fat as well as on ours. Everything downstream, the name, the
    --    miasma and the rot watcher's burn job, is vanilla reacting to
    --    a vanilla flag once we set it.
    local ok_hrot, hrot = pcall(reqscript, 'making-fuel-hide-rot')
    if ok_hrot and hrot and hrot.start then
        pcall(hrot.start)
    end

    -- 5. hide-stock registers the hide materials in DF's Glob
    --    enumeration. Ours are the only materials in the module that
    --    claim an organic storage category while being inorganic, so
    --    they are the only ones with no position for a stockpile
    --    setting to address. Everything else hauls off the inorganic
    --    indexed vectors and always has.
    local ok_hstk, hstk = pcall(reqscript, 'making-fuel-hide-stock')
    if ok_hstk and hstk and hstk.start then
        pcall(hstk.start)
    end

    -- 6. dye-stock registers the module's dyes in DF's PlantPowder
    --    enumeration, Food / Milled Plants, where every vanilla dye is
    --    kept. The same gap as the hides: an inorganic that belongs in
    --    an organic storage category has no position a stockpile
    --    setting can address until it is given one.
    local ok_dstk, dstk = pcall(reqscript, 'making-fuel-dye-stock')
    if ok_dstk and dstk and dstk.start then
        pcall(dstk.start)
    end

    -- Point ITEM_LIQUID at the HIDES sheet so skin globs draw as
    -- hides. A watcher rather than a one time write, because the gps
    -- tables rebuild on graphics reload and come back vanilla. The
    -- known collateral, lye and other bare ground liquids drawing
    -- hide shaped, is documented at the top of the script itself.
    local ok_hspr, hspr = pcall(reqscript, 'making-fuel-hide-sprite')
    if ok_hspr and hspr and hspr.start then
        pcall(hspr.start)
    end

    -- The Bark Dye push is gone: its one consumer, GRIND_BARK, was
    -- replaced by per-tree log and bark routes that name their
    -- materials by token (making-fuel-tree-dyes.lua), so nothing is
    -- pushed onto vanilla WOOD materials any more.

    -- Tinder twins: pushed here, popped at stop, RAM only.
    local ok_tw, err_tw = pcall(function()
        reqscript('making-fuel-tinder-mat').start()
    end)
    if not ok_tw then
        log('ERROR', "Tinder twin push FAILED: " .. tostring(err_tw), 'TINDER_MAT')
    end
    -- Aggregate stone twins. The ORDER of this call is the contract:
    -- an item stores a mat_index number, so the twins have to land in
    -- the same place every session. See making-fuel-stone-mat.lua.
    local ok_sm, err_sm = pcall(function()
        reqscript('making-fuel-stone-mat').start()
    end)
    if not ok_sm then
        log('ERROR', "Aggregate twin push FAILED: " .. tostring(err_sm), 'STONE_MAT')
    end

    -- Start the Vanilla Job Hijack
    -- Start the Coal Exterminator FIRST among the background
    -- scripts: nothing downstream may pay out builtin coal into a
    -- world where the watcher is not yet listening.
    local ok_coal, coal = pcall(reqscript, 'making-fuel-coal-watcher')
    if ok_coal and coal and coal.start then
        coal.start()
        log('DETAIL', "Coal Watcher started.", 'COAL_WATCHER')
        local ok_tw, tw = pcall(reqscript, 'making-fuel-tinder-watcher')
        if ok_tw and tw then
            pcall(tw.start)
            log('DETAIL', "Tinder Watcher started.", 'TINDER_WATCHER')
        end
        -- Tool tint: our own manufactured texture written into DF's
        -- graphics_info cache, because while an entry exists DF draws
        -- that and never the itemdef's texpos fields.
        local ok_tt, tt = pcall(reqscript, 'making-fuel-tool-tint')
        if ok_tt and tt and tt.start then
            pcall(tt.start)
            log('DETAIL', "Tool Tint started.", 'TOOL_TINT')
        end
    end

    -- Start the Menu Shaper: the poofed builtin furnace jobs
    -- (MakeCharcoal, MakeAsh) are removed from the task menus and
    -- from the manager's New Work Order list; CHAR_LOG and ASH_LOG
    -- carry those names in module diction now. The hijacker below
    -- still pays any vanilla order that already exists.
    local ok_shaper, shaper = pcall(reqscript, 'making-fuel-menu-shaper')
    if ok_shaper and shaper and shaper.start then
        pcall(shaper.start)
        log('DETAIL', "Menu Shaper started.", 'MENU_SHAPER')
    end

    local ok_hijack, hijack = pcall(reqscript, 'making-fuel-hijacker')
    if ok_hijack and hijack and hijack.start then
        hijack.start()
        log('DETAIL', "Job Hijack started.", 'HIJACKER')
    end

    -- Start the Ash Bar Sprite. It writes bar_texpos and texflag on
    -- builtin ASH, which is a DF object, so it washes on stop and is
    -- torn down with the other DF mutators. Safe when the art is not
    -- installed: it says so and leaves vanilla's bar alone.
    local ok_ashart, ashart = pcall(reqscript, 'making-fuel-ash-sprite')
    if ok_ashart and ashart and ashart.start then
        local ok_s, err_s = pcall(ashart.start)
        if not ok_s then
            log('ERROR', "Ash Sprite FAILED to start: " .. tostring(err_s), 'ASH_SPRITE')
        end
    end

    -- Say what the tint system actually did. By here the injects have
    -- run, so this is the first honest moment to report. One line at
    -- NORMAL, because silence should mean a subsystem did not run and
    -- never that it succeeded.
    local ok_tart, tart = pcall(reqscript, 'refinish-sprite-art')
    if ok_tart and tart and tart.report then pcall(tart.report) end

    -- Start Universal Fuel Access. Last in, first out: it mints a
    -- real item into the world, so it must be torn down before
    -- anything else and before any save is written.
    local ok_access, access = pcall(reqscript, 'making-fuel-access')
    if ok_access and access and access.start then
        local ok_s, err_s = pcall(access.start)
        if ok_s then
            log('DETAIL', "Universal Fuel Access started.", 'FUEL_ACCESS')
        else
            log('ERROR', "Fuel Access FAILED to start: " .. tostring(err_s), 'FUEL_ACCESS')
        end
    end
end

local function stop_background_scripts()
    -- Stop Universal Fuel Access FIRST. It holds a minted item, and
    -- LIFO teardown means the thing that touched the world last is
    -- undone first. A save must never contain the menu key.
    local ok_access, access = pcall(reqscript, 'making-fuel-access')
    if ok_access and access and access.stop then
        pcall(access.stop)
    end

    -- Ash Bar Sprite next, for the same reason: it holds two written
    -- fields on builtin ASH, and DF's own object must be handed back
    -- unmarked before RAM is cleared.
    local ok_ashart, ashart = pcall(reqscript, 'making-fuel-ash-sprite')
    if ok_ashart and ashart and ashart.stop then
        pcall(ashart.stop)
    end

    -- Coal watcher second in teardown: the key is already gone,
    -- and everything still capable of paying out builtin coal is
    -- torn down after this, into a world with nothing listening,
    -- which is fine because nothing runs jobs during teardown.
    local ok_coal, coal = pcall(reqscript, 'making-fuel-coal-watcher')
    if ok_coal and coal and coal.stop then
        pcall(coal.stop)
    end

    local ok_shaper, shaper = pcall(reqscript, 'making-fuel-menu-shaper')
    if ok_shaper and shaper and shaper.stop then
        pcall(shaper.stop)
    end
    local ok_tinder, tinder = pcall(reqscript, 'making-fuel-tinder-watcher')
    if ok_tinder and tinder and tinder.stop then
        pcall(tinder.stop)
    end
    local ok_tint, tint = pcall(reqscript, 'making-fuel-tool-tint')
    if ok_tint and tint and tint.stop then
        pcall(tint.stop)
    end

    -- Stop the JIT Watcher
    local ok_watcher, watcher = pcall(reqscript, 'making-fuel-ghost')
    if ok_watcher and watcher and watcher.stop then
        watcher.stop()
    end

    -- Stop the Kindling Spawner
    local ok_spawner, spawner = pcall(reqscript, 'making-fuel-branch-spawner')
    if ok_spawner and spawner and spawner.stop then
        spawner.stop()
    end

    -- Stop the Dung Spawner
    local ok_pooper, pooper = pcall(reqscript, 'making-fuel-pooper')
    if ok_pooper and pooper and pooper.stop then
        pooper.stop()
    end

    -- Stop the Rot Watcher
    local ok_rotw, rotw = pcall(reqscript, 'making-fuel-rot-watcher')
    if ok_rotw and rotw and rotw.stop then
        pcall(rotw.stop)
    end

    -- Stop the Cremation Watcher
    local ok_crem, crem = pcall(reqscript, 'making-fuel-cremate-watcher')
    if ok_crem and crem and crem.stop then
        pcall(crem.stop)
    end

    -- Stop the Drain Key Watcher
    local ok_dkey, dkey = pcall(reqscript, 'making-fuel-drain-key')
    if ok_dkey and dkey and dkey.stop then
        pcall(dkey.stop)
    end

    -- Stop the Liquid Fuel Tanks beside the drain key, mirror of the
    -- start. stop() darkens every fill clone on the way out, so a dead
    -- session cannot leave "fill fuel tank" standing in a building
    -- with no tank. The clones are left to the engine's prefix sweep.
    local ok_tank, tank = pcall(reqscript, 'making-fuel-tank-fuel')
    if ok_tank and tank and tank.stop then
        pcall(tank.stop)
    end

    -- Stop the Still, mirror of the start. Its carry is written through
    -- as each barrel is distilled, so nothing is settled on the way out.
    local ok_still, still = pcall(reqscript, 'making-fuel-still')
    if ok_still and still and still.stop then
        pcall(still.stop)
    end

    -- Stop the Hide Chain, reverse of the start order. The rename is
    -- put back LAST so both consumers are already off before any
    -- material name moves under them.
    -- Put the sprite pointer back FIRST, before the rest of the hide
    -- chain comes down, so a shutdown mid session leaves vanilla
    -- exactly as it found it.
    local ok_hspr, hspr = pcall(reqscript, 'making-fuel-hide-sprite')
    if ok_hspr and hspr and hspr.stop then
        pcall(hspr.stop)
    end

    local ok_hrot, hrot = pcall(reqscript, 'making-fuel-hide-rot')
    if ok_hrot and hrot and hrot.stop then
        pcall(hrot.stop)
    end

    local ok_hrxn, hrxn = pcall(reqscript, 'making-fuel-hide-chain')
    if ok_hrxn and hrxn and hrxn.stop then
        pcall(hrxn.stop)
    end

    local ok_hwatch, hwatch = pcall(reqscript, 'making-fuel-hide-watcher')
    if ok_hwatch and hwatch and hwatch.stop then
        pcall(hwatch.stop)
    end

    -- Before the engine sweeps our materials: pop the dyes back out of
    -- the PlantPowder enumeration, so no raws vector refers to them
    -- across the save. The next start appends them at the same places.
    local ok_dstk, dstk = pcall(reqscript, 'making-fuel-dye-stock')
    if ok_dstk and dstk and dstk.stop then
        pcall(dstk.stop)
    end

    local ok_hmats, hmats = pcall(reqscript, 'making-fuel-hide-mats')
    if ok_hmats and hmats and hmats.restore_vanilla then
        pcall(hmats.restore_vanilla)
    end

    -- Stop Air Drying.
    local ok_airdry, airdry = pcall(reqscript, 'making-fuel-air-dry')
    if ok_airdry and airdry and airdry.stop then
        pcall(airdry.stop)
    end

    pcall(function() reqscript('making-fuel-tinder-mat').stop() end)
    -- Before the engine sweeps its own materials: these twins sit at
    -- the end of the same inorganics vector and come off LIFO.
    pcall(function() reqscript('making-fuel-stone-mat').stop() end)

    -- The manufactured textures are KEPT, not freed. Deleting them here
    -- crashed DF twice on the way out of a world, 2026-09-22 at 16:55
    -- and 17:10, inside DFHack's own texture code where pcall cannot
    -- reach. They live in the reserved range, which is never wiped, so
    -- the next start reuses them rather than making a second set. See
    -- TEARDOWN: KEPT, NOT FREED in refinish-sprite-art.lua.
    --
    -- The call stays: it reports the count, and the decision keeps one
    -- owner rather than being half here and half there.
    local ok_tart, tart = pcall(reqscript, 'refinish-sprite-art')
    if ok_tart and tart and tart.release_all then pcall(tart.release_all) end

    -- Stop the Vanilla Job Hijack
    -- No coal watcher call belongs here. It is stopped above,
    -- second in the teardown order, right after fuel access.
    -- A start() block used to sit at this spot, pasted in from
    -- start_background_scripts, so every shutdown stopped the
    -- watcher and then immediately re-armed onItemCreated and
    -- the poll sweep into a world being torn down.
    local ok_hijack, hijack = pcall(reqscript, 'making-fuel-hijacker')
    if ok_hijack and hijack and hijack.stop then
        hijack.stop()
    end
end


-- ==========================================
-- REGISTRATION
-- ==========================================
-- Connects to RM's module engine and registers a listener
-- that fires when RM broadcasts its startup token call.
-- The listener loads JSONs, runs value calculation if needed,
-- and returns pre-built data tables to the engine.
-- ==========================================
local function register_with_rm()
    -- Locate RM's module engine. If RM isn't installed, this
    -- fails gracefully: the module just doesn't register.
    local ok, engine = pcall(dfhack.script_environment, 'refinish-module-engine')
    if not ok or not engine or not engine.register_listener then
        return
    end

    engine.register_listener(MODULE_NAME, function()
        -- Every bail below logs its reason as an ERROR. The engine only
        -- records "listener returned nil", so the reason has to come
        -- from here: a trailing comma in a reaction file once cost a
        -- full cycle with no reason given. These used to be prints,
        -- shadowed so they reached the log as well as the console.
        -- Resolve our mod's root folder at runtime.
        -- scriptmanager.getModSourcePath returns paths like:
        --   "mods/2945575779/" (Steam Workshop)
        --   "data/installed_mods/making_fuel (108)/" (installed)
        local mod_path = scriptmanager.getModSourcePath(MODULE_ID)
        if not mod_path then
            log('ERROR', "Cannot resolve mod path for ID '" .. MODULE_ID .. "'.",
                'REGISTER')
            return nil
        end

        local data_path = mod_path .. "data/"
        log('DETAIL', "Loading from " .. data_path, 'REGISTER')

        -- ---- LOAD JSON DATA ----
        -- Both files are optional (either can be nil in config),
        -- but at least one must succeed for the module to register.
        local mat_data = nil
        local rxn_data = nil

        if MATERIALS_FILE then
            mat_data = load_json(data_path .. MATERIALS_FILE)
            if not mat_data then
                log('ERROR', "Failed to load " .. MATERIALS_FILE, 'REGISTER')
                return nil
            end
        end

        -- ---- REACTIONS: SPLIT FILES, ONE MERGED PAYLOAD ----
        -- Each part carries the same schema as the old single file
        -- ({module, categories, reactions}); the merge rebuilds
        -- exactly what the engine has always received, so nothing
        -- downstream of this block changes. A missing part or a key
        -- collision is a hard stop naming the file, because a
        -- silently thinner reaction set is the worst outcome here.
        if REACTIONS_FILES then
            local seen_rxn, seen_cat = {}, {}
            for _, fname in ipairs(REACTIONS_FILES) do
                local part = load_json(data_path .. fname)
                if not part then
                    log('ERROR', "Failed to load " .. fname, 'REGISTER')
                    return nil
                end
                if not rxn_data then
                    -- The first part donates the module identity.
                    rxn_data = { module = part.module,
                                 categories = {}, reactions = {} }
                end
                for _, cat in ipairs(part.categories or {}) do
                    if seen_cat[cat.key] then
                        log('ERROR', "category [" .. cat.key
                            .. "] in " .. fname .. " and "
                            .. seen_cat[cat.key] .. ". Fix before load.",
                            'REGISTER')
                        return nil
                    end
                    seen_cat[cat.key] = fname
                    table.insert(rxn_data.categories, cat)
                end
                for _, rxn in ipairs(part.reactions or {}) do
                    if seen_rxn[rxn.key] then
                        log('ERROR', "reaction [" .. rxn.key
                            .. "] in " .. fname .. " and "
                            .. seen_rxn[rxn.key] .. ". Fix before load.",
                            'REGISTER')
                        return nil
                    end
                    seen_rxn[rxn.key] = fname
                    table.insert(rxn_data.reactions, rxn)
                end
            end
        end

        -- Tools are the third data file. Optional like the other two.
        -- A module with no tools sets TOOLS_FILE to nil and nothing
        -- downstream fires.
        local tool_data = nil

        if TOOLS_FILE then
            tool_data = load_json(data_path .. TOOLS_FILE)
            if not tool_data then
                log('ERROR', "Failed to load " .. TOOLS_FILE, 'REGISTER')
                return nil
            end
        end

        -- Buildings are the fourth data file, optional like the
        -- rest. Fully injected: no raws twin should exist once
        -- this is live, or the injector's duplicate guard skips.
        local bld_data = nil

        if BUILDINGS_FILE then
            bld_data = load_json(data_path .. BUILDINGS_FILE)
            if not bld_data then
                log('ERROR', "Failed to load " .. BUILDINGS_FILE, 'REGISTER')
                return nil
            end
        end

        -- ---- PLANTS ----
        -- The host carrying the coal materials. Optional twice over:
        -- PLANTS_FILE nil turns it off, and a missing file is not a
        -- fault either. Neither case is a bail, because a module
        -- without the host is the module as it shipped before, with
        -- inorganic coals and a "bars" suffix.
        --
        -- Deliberately NOT in the bail test below: plants alone are
        -- not a reason to inject, and their absence is not a reason
        -- to stop.
        local plt_data = nil
        if PLANTS_FILE then
            plt_data = load_json(data_path .. PLANTS_FILE)
            if not plt_data then
                -- INFO: an optional file, and running without it is the
                -- module as it shipped before the host existed.
                log('INFO', "no plants file, running without"
                      .. " the plant host.", 'REGISTER')
            end
        end

        -- Bail only if all three are missing. A tools-only module is a
        -- legitimate shape now: containers are infrastructure and a
        -- module could ship nothing else.
        if not mat_data and not rxn_data and not tool_data and not bld_data then
            log('ERROR', "No data files loaded, nothing to inject.", 'REGISTER')
            return nil
        end

        log('DETAIL', "Data loaded successfully.", 'REGISTER')

        -- ---- WEIGHTED VALUE CALCULATION ----
        -- For materials with value=null, compute from a linked
        -- reaction's BAR reagents. The link is explicit:
        -- each material can specify "value_from_reaction" with
        -- the key of the reaction to derive its value from.
        --
        -- Example material JSON:
        --   { "key": "ALLOY_SHAKUDO", "value": null,
        --     "value_from_reaction": "FORGE_SHAKUDO", ... }
        --
        -- If no materials have value=null, this block is inert.
        if mat_data and rxn_data then
            local has_null_values = false
            for _, mat in ipairs(mat_data.materials) do
                if mat.value == nil then
                    has_null_values = true
                    break
                end
            end

            if has_null_values then
                -- Build reaction lookup for value resolution
                local rxn_lookup = {}
                for _, rxn in ipairs(rxn_data.reactions) do
                    rxn_lookup[rxn.key] = rxn
                end

                for _, mat in ipairs(mat_data.materials) do
                    if mat.value == nil then
                        -- Look for explicit reaction linkage
                        if mat.value_from_reaction then
                            local rxn = rxn_lookup[mat.value_from_reaction]
                            if rxn and rxn.reagents then
                                mat.value = calculate_weighted_value(rxn.reagents)
                            end
                        end
                        -- Final fallback: every material needs a value
                        if mat.value == nil then
                            mat.value = 1
                        end
                    end
                end
            end
        end

        -- ---- BACKGROUND SCRIPTS ----
        -- Triggers right before sending the data to the engine.
        -- The ghost receives the reactions table and derives its
        -- adaptive configuration from it, so the JSON is the only
        -- place a reaction's adaptive status is ever declared.
        start_background_scripts(rxn_data and rxn_data.reactions)

        -- ==========================================
        -- RUNTIME MATERIALS: THE HIDE ROSTER
        -- ==========================================
        -- The JSON file is not the whole material list. hide-mats owns
        -- one pair of materials per creature this fort has butchered,
        -- and that roster lives in site data, not in any file.
        --
        -- Without this block the roster survives the save and the
        -- MATERIALS DO NOT. The species is still rostered, so the
        -- butcher watcher believes the material exists and never mints
        -- it again, and every llama skin in the fort is left pointing
        -- at a material nobody injected.
        --
        -- Appended, not merged, so the JSON declared materials keep
        -- their positions and their order.
        local runtime_mats = {}
        if mat_data and mat_data.materials then
            for _, m in ipairs(mat_data.materials) do
                runtime_mats[#runtime_mats + 1] = m
            end
        end
        local json_count = #runtime_mats

        local hide_prefix = mat_data and mat_data.module
                            and mat_data.module.prefix or nil
        local hide_count = 0
        if hide_prefix then
            local ok_hm, hm = pcall(reqscript, 'making-fuel-hide-mats')
            if ok_hm and hm and hm.build_payload then
                local ok_p, payload = pcall(hm.build_payload)
                if ok_p and type(payload) == 'table' then
                    for _, m in ipairs(payload) do
                        runtime_mats[#runtime_mats + 1] = m
                        hide_count = hide_count + 1
                    end
                else
                    log('ERROR', 'hide roster payload FAILED: '
                        .. tostring(payload), 'REGISTER')
                end
            else
                log('ERROR', 'hide-mats did not load. No per'
                    .. ' creature skin materials this session.', 'REGISTER')
            end
        else
            log('ERROR', 'no module prefix in the materials'
                .. ' file. Hide roster skipped.', 'REGISTER')
        end
        log('DETAIL', string.format('%d JSON material(s) + %d hide material(s).',
            json_count, hide_count), 'REGISTER')

        -- ==========================================
        -- FINISHING THE HIDE MATERIALS
        -- ==========================================
        -- apply_runtime_fields stamps the creature name, the heat
        -- block, the glob flags, density and colour onto each hide
        -- material, copied from that animal's own skin. It CANNOT run
        -- here: the engine has injected nothing yet, so there is
        -- nothing to stamp.
        --
        -- HEAT IS WHY THIS IS NOT OPTIONAL. Skin melts at 60001, which
        -- is to say never. A hide material left carrying the SOIL
        -- clone donor's heat block can be liquid at fort room
        -- temperature, and a molten glob is gone the moment the game
        -- unpauses. making-fuel-hide-mats.lua line 392 records that
        -- happening to a test glob.
        --
        -- So it goes to the engine as a callback and runs the moment
        -- the materials are in.
        local on_mats = nil
        if hide_count > 0 then
            on_mats = function()
                reqscript('making-fuel-hide-mats')
                    .apply_runtime_fields(hide_prefix)
            end
        end

        -- ---- TREE BARK DYES, GENERATED ----
        -- One bark dye per tree in this world, built from the live
        -- plant raws and handed to RM with the JSON data, the way the
        -- hide materials above are: a TREE_DYE_HOST plant carrying the
        -- new dyes, and their log and bark routes. RM validates,
        -- injects and sweeps them like any JSON entry. See
        -- making-fuel-tree-dyes.lua.
        local ok_td, err_td = pcall(function()
            reqscript('making-fuel-tree-dyes').generate(plt_data, rxn_data,
                mat_data and mat_data.module and mat_data.module.prefix)
        end)
        if not ok_td then
            log('ERROR', "Tree bark dye generation FAILED: " .. tostring(err_td), 'TREE_DYES')
        end

        -- ---- RETURN TO ENGINE ----
        -- Pre-built payloads (Lua power user mode). The engine
        -- accepts either JSON file paths or direct Lua tables.
        -- By loading and processing here, we can inject computed
        -- values before the engine sees the data.
        return {
            materials  = (#runtime_mats > 0) and runtime_mats or nil,
            on_materials_injected = on_mats,
            plants     = plt_data and plt_data.plants or nil,
            reactions  = rxn_data and rxn_data.reactions or nil,
            categories = rxn_data and rxn_data.categories or nil,
            tools      = tool_data and tool_data.tools or nil,
            buildings  = bld_data and bld_data.buildings or nil,
            buildings_dir = bld_data and data_path or nil,
            module     = mat_data and mat_data.module or
                         rxn_data and rxn_data.module or
                         tool_data and tool_data.module or nil,
        }
    end, MODULE_ID)
end


-- ==========================================
-- SHUTDOWN HOOK
-- ==========================================
-- Tied directly to the map unloader, mirroring Making Concrete.
dfhack.onStateChange.making_fuel_unload = function(code)
    if code == SC_MAP_UNLOADED then
        stop_background_scripts()
        -- The bank is a global so it survives RAM cycles and saves. On
        -- a real map unload the fort is gone, so its balance should go
        -- with it rather than leak into the next fort.
        _G.refinish_fuel_bank = nil
    end
end


-- ==========================================
-- AUTO-REGISTER ON LOAD
-- ==========================================
register_with_rm()

-- The settings page, declared at load so it is there whenever the HUD
-- opens. The settings file logs its own refusals; this only catches a
-- file that will not load at all.
do
    local ok_set, set = pcall(reqscript, 'making-fuel-settings')
    if ok_set and set and set.register then
        pcall(set.register)
    elseif not ok_set then
        log('ERROR', "COULD NOT LOAD making-fuel-settings: " .. tostring(set)
            .. ". No settings page.", 'SETTINGS')
    end
end

return _ENV