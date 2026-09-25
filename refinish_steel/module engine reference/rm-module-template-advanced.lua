--@ module = true
-- rm-module-template-advanced.lua
-- ==========================================
-- RM MODULE TEMPLATE (ADVANCED)
-- ==========================================
-- The full-featured Lua shell for a Refinish Metal module.
--
-- The basic template (rm-module-template.lua) hands RM two file
-- paths and lets the engine do the rest. That is the right choice
-- when your JSON is complete on disk and nothing about it depends
-- on the world that just loaded.
--
-- This template is for the other case. It loads the JSON itself,
-- edits the parsed tables in memory, and hands RM finished data.
-- That extra step is what lets a module ask questions it cannot
-- answer until the world exists:
--
--   "Which sand does this world have?"
--   "Is my raws half actually installed?"
--   "What should this alloy be worth, given local metal prices?"
--
-- Every system below is optional and independently removable.
-- Delete the ones you do not need. Nothing here depends on
-- anything else except the registration block at the bottom.
--
-- WHAT IS IN HERE:
--   1. JSON LOADER            Read and parse a data file.
--   2. RAW DEPENDENCY CHECK   Verify things your JSON assumes exist.
--   3. VALUE CALCULATOR       Resolve "value": null from reagent prices.
--   4. RUNTIME MATERIAL       Resolve "mat_id": null against this world.
--      RESOLUTION             (the sand pattern)
--   5. HELPER SCRIPT          Start and stop companion scripts.
--      LIFECYCLE
--   6. REGISTRATION           Hand the finished tables to RM.
--   7. SHUTDOWN HOOK          Stop everything on map unload.
--
-- SETUP:
--   1. Set MODULE_ID to the [ID:...] from your mod's info.txt.
--   2. Set MODULE_NAME to a friendly name for log output.
--   3. Set the JSON file names.
--   4. Put this file in scripts_modinstalled/ and rename it to
--      match your mod, for example mymod.lua.
--   5. Put your JSON files in your mod's data/ folder.
--
-- REFERENCE:
--   RM_Module_Modder_Guide.md, section 7.
-- ==========================================

local json = require('json')
local scriptmanager = require('script-manager')


-- ==========================================
-- CONFIGURATION
-- Edit these to match your mod.
-- ==========================================

-- MUST match the [ID:...] line in your mod's info.txt. If this is
-- wrong, the path lookup fails and the module never loads.
local MODULE_ID = "my_module"

-- Friendly name used in RM's log output and in this file's prints.
local MODULE_NAME = "My Module"

-- JSON data files, relative to your mod's data/ folder.
-- Set either one to nil if your module has only materials or
-- only reactions.
local MATERIALS_FILE = "my_module_materials.json"
local REACTIONS_FILE = "my_module_reactions.json"


-- ==========================================
-- 1. JSON LOADER
-- ==========================================
-- Reads a file from disk and parses it. Returns the parsed Lua
-- table, or nil on any failure.
--
-- Three things can go wrong and all three return nil: the file is
-- missing, the file is empty, or the JSON is malformed. The caller
-- reports which file failed, which is enough to find the problem.
--
-- pcall wraps the decode because json.decode raises a Lua error on
-- bad syntax rather than returning a failure value. Without pcall a
-- stray comma in your data file would take down the whole script.
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
-- 2. RAW DEPENDENCY CHECK
-- ==========================================
-- Verifies that things your JSON names but does not define are
-- actually present in this world.
--
-- WHY THIS EXISTS:
-- Injection is forgiving in the worst possible way. A missing
-- material resolves to index -1 and the reaction silently accepts
-- nothing. A missing colour descriptor resolves to grey and no
-- error is printed anywhere. The player sees a mod that half works
-- and has no way to find out why.
--
-- This check turns those silent failures into one clear message in
-- the DFHack console at load time.
--
-- IMPORTANT: none of this blocks registration. A missing dependency
-- degrades the module, it does not disable it. Say what is wrong
-- and load anyway.
--
-- WHEN THIS RUNS:
-- At token-call time, not when this script first executes. The
-- world raws do not exist yet when DFHack runs your script file.
-- ==========================================

-- Is a named inorganic loaded? Use this for materials your raws
-- half defines, and for vanilla materials your reactions consume.
local function inorganic_exists(id)
    for _, mat in ipairs(df.global.world.raws.inorganics.all) do
        if mat.id == id then return true end
    end
    return false
end

-- Is a named colour descriptor loaded? Colours resolve by name at
-- injection time and a miss is completely silent, so anything not
-- from vanilla descriptor_color_standard.txt is worth checking.
local function color_exists(id)
    for _, c in ipairs(df.global.world.raws.descriptors.colors) do
        if c.id == id then return true end
    end
    return false
end

-- Is a custom workshop loaded? Custom workshops are raw objects,
-- not enum entries, and RM finds them by code at build time. If the
-- workshop is missing, every reaction assigned to it has nowhere to
-- appear and vanishes without comment.
local function workshop_exists(code)
    local ok, defs = pcall(function()
        return df.global.world.raws.buildings.workshops
    end)
    if not ok or not defs then return false end

    for _, b in ipairs(defs) do
        if b.code == code then return true end
    end
    return false
end

-- ---- WHAT THIS MODULE REQUIRES ----
-- Fill these in for your own module. Leave a list empty to skip
-- that check entirely.
--
-- Pick SENTINELS, not exhaustive lists. One material that only your
-- raws half defines proves the whole file loaded. Checking all
-- twenty-six of them just makes a longer error message.
--
-- Colours are the exception: one missing colour means one grey
-- material, not a broken file, so list them all and name the ones
-- that failed.
local REQUIRED_INORGANICS = {
    -- "MY_RAW_CLAY",
}

local REQUIRED_COLORS = {
    -- "BRIGHTSTEEL",
}

local REQUIRED_WORKSHOPS = {
    -- "MY_WORKSHOP",
}

local function check_raw_dependencies()
    local problems = {}

    for _, id in ipairs(REQUIRED_INORGANICS) do
        if not inorganic_exists(id) then
            table.insert(problems,
                "Missing inorganic '" .. id .. "'. Reactions consuming it will match nothing.")
        end
    end

    for _, code in ipairs(REQUIRED_WORKSHOPS) do
        if not workshop_exists(code) then
            table.insert(problems,
                "Missing workshop '" .. code .. "'. Its reactions have no building to appear at.")
        end
    end

    -- Named individually, for the reason given above.
    local missing_colors = {}
    for _, name in ipairs(REQUIRED_COLORS) do
        if not color_exists(name) then
            table.insert(missing_colors, name)
        end
    end
    if #missing_colors > 0 then
        table.insert(problems,
            "Missing colour descriptors (those materials will render grey): " ..
            table.concat(missing_colors, ", "))
    end

    if #problems > 0 then
        print(MODULE_NAME .. ": raw dependency check found " .. #problems .. " issue(s):")
        for _, p in ipairs(problems) do
            print("  - " .. p)
        end
        print("  Injected content will still load, but parts of this mod will not work as intended.")
    end

    return #problems == 0
end


-- ==========================================
-- 3. VALUE CALCULATOR
-- ==========================================
-- Computes a material's value from the metals that go into it,
-- weighted by how much of each the reaction consumes.
--
-- WHY THIS EXISTS:
-- A hardcoded alloy value is a guess about a world you have not
-- seen. Metal prices shift with the mods installed, so an alloy
-- priced against vanilla iron can end up worth less than its own
-- ingredients. Reading live values at load time keeps the alloy
-- correctly positioned in whatever economy it lands in.
--
-- Only BAR reagents count. Flux, coal, boulders and powders
-- have no meaningful price signal for an alloy.
--
-- HOW TO USE IT:
--   In your materials JSON:   "value": null
--   Alongside it:             "value_from_reaction": "MAKE_MY_ALLOY"
--
--   value_from_reaction names a reaction KEY in your reactions
--   file. It is not part of RM's schema. RM ignores unknown fields,
--   so it passes through untouched and this file reads it. Anything
--   still null after this runs falls back to 1.
--
-- Returns: an integer, minimum 1.
-- ==========================================
local function calculate_weighted_value(reagents)
    local inorganics = df.global.world.raws.inorganics.all

    -- Build a price lookup from every loaded inorganic
    local value_lookup = {}
    for _, mat in ipairs(inorganics) do
        value_lookup[mat.id] = mat.material.material_value
    end

    local total_quantity = 0
    local weighted_sum   = 0

    for _, rgt in ipairs(reagents) do
        if rgt.type == "BAR" and rgt.mat_id then
            local base_val = value_lookup[rgt.mat_id] or 1
            local qty      = rgt.quantity or 1
            weighted_sum   = weighted_sum + (base_val * qty)
            total_quantity = total_quantity + qty
        end
    end

    if total_quantity > 0 then
        return math.floor(weighted_sum / total_quantity)
    end
    return 1
end

-- Walks every material with a null value and fills it in. Safe to
-- call when nothing needs it: the loop simply finds nothing.
local function resolve_values(mat_data, rxn_data)
    if not mat_data or not rxn_data then return end

    -- Index reactions by key so a material can find its own
    local rxn_lookup = {}
    for _, rxn in ipairs(rxn_data.reactions or {}) do
        rxn_lookup[rxn.key] = rxn
    end

    for _, mat in ipairs(mat_data.materials or {}) do
        if mat.value == nil then
            if mat.value_from_reaction then
                local rxn = rxn_lookup[mat.value_from_reaction]
                if rxn and rxn.reagents then
                    mat.value = calculate_weighted_value(rxn.reagents)
                end
            end
            -- Floor. A null value reaching the engine means the
            -- clone donor's price survives, which is arbitrary.
            if mat.value == nil then
                mat.value = 1
            end
        end
    end
end


-- ==========================================
-- 4. RUNTIME MATERIAL RESOLUTION
-- ==========================================
-- Fills in a mat_id that cannot be known until the world loads.
--
-- THE PROBLEM THIS SOLVES:
-- Sand is the standard example. Vanilla ships five sand materials
-- (SAND_TAN, SAND_WHITE, SAND_BLACK, SAND_RED, SAND_YELLOW) and
-- mods add or remove more. Your JSON cannot name one, because you
-- do not know which exist. But it also cannot leave the slot as a
-- wildcard: a POWDER reagent with no material matches ANY powder in
-- a bag, and once two such slots sit in the same reaction, DF has
-- nothing to tell them apart and reagent matching goes
-- non-deterministic.
--
-- THE PATTERN:
--   1. Write "mat_id": null in the JSON as a sentinel meaning
--      "resolve this at load time."
--   2. Scan the live raws for a material matching some property
--      (here, the SOIL_SAND flag).
--   3. Write the real ID into the parsed table before returning it.
--   4. If nothing matches, remove the affected content so the
--      module degrades cleanly instead of injecting broken jobs.
--
-- The engine never sees the null. By the time RM reads the table,
-- every mat_id is a real string.
--
-- ADAPTING THIS:
-- Nothing here is sand-specific except the flag name and the
-- preference. Swap df flag or reaction_class test in
-- resolve_target_id and reuse the whole shape.
-- ==========================================

-- Scans the inorganic array for a suitable material.
--
-- Preference order:
--   1. The known-good vanilla material, if this world has it
--   2. The first material carrying the required flag
--
-- Returns the inorganic ID string, or nil if this world has none.
local function resolve_target_id()
    local raws = df.global.world.raws.inorganics.all
    local fallback = nil

    for _, mat in ipairs(raws) do
        if mat.flags.SOIL_SAND then
            -- Preferred: the common vanilla sand, present in every
            -- unmodded world. Return the moment we see it.
            if mat.id == "SAND_TAN" then
                return "SAND_TAN"
            end
            -- Otherwise remember the first match and keep looking
            if not fallback then
                fallback = mat.id
            end
        end
    end

    return fallback
end

-- Rewrites every null sentinel in the parsed reaction data.
--
-- The predicate matters more than it looks. Matching on type plus
-- a code prefix keeps the patcher off slots that legitimately have
-- no material, such as the bags the sand travels in.
local function patch_runtime_materials(rxn_data)
    if not rxn_data or not rxn_data.reactions then return end

    local target_id = resolve_target_id()

    -- ---- NO MATCH: DEGRADE CLEANLY ----
    -- Remove the reactions that cannot work without it. Leaving
    -- them injected means the player sees jobs that never start
    -- and never explain why.
    if not target_id then
        for i = #rxn_data.reactions, 1, -1 do
            local rxn = rxn_data.reactions[i]
            if rxn.key == "GRIND_SAND" then
                table.remove(rxn_data.reactions, i)
            end
        end
        print(MODULE_NAME .. ": WARNING - no sand material in this world. Sand reactions removed.")
        return
    end

    -- ---- MATCH: WRITE IT IN ----
    local products_patched = 0
    local reagents_patched = 0

    for _, rxn in ipairs(rxn_data.reactions) do

        -- Products: reactions that OUTPUT the material.
        for _, prod in ipairs(rxn.products or {}) do
            if prod.type == "POWDER_MISC" and prod.mat_id == nil then
                prod.mat_id = target_id
                products_patched = products_patched + 1
            end
        end

        -- Reagents: reactions that CONSUME the material.
        for _, rgt in ipairs(rxn.reagents or {}) do
            if rgt.type == "POWDER"
                    and rgt.mat_id == nil
                    and string.find(rgt.code, "^sand") then

                rgt.mat_id = target_id
                reagents_patched = reagents_patched + 1

                -- Drop sand_bearing now that the material is known.
                -- It was a stand-in for this resolution while the
                -- slot was a wildcard. Keeping both means an item
                -- must satisfy the material AND the flag, which is
                -- redundant and is one more filter that can quietly
                -- reject a valid bag.
                rgt.sand_bearing = nil
            end
        end
    end

    print(string.format("%s: sand resolved to %s (%d products, %d reagents patched).",
        MODULE_NAME, target_id, products_patched, reagents_patched))
end


-- ==========================================
-- 5. HELPER SCRIPT LIFECYCLE
-- ==========================================
-- Starts and stops companion scripts that do work RM's schema
-- cannot express: interface button injection, job completion
-- hooks, item fixups.
--
-- CONTRACT:
-- A helper script exposes start() and stop() and manages its own
-- polling or event registration. This file only calls those two.
-- Everything is wrapped in pcall so a missing or broken helper
-- prints a warning instead of taking the module down with it.
--
-- WHY stop() MATTERS:
-- A helper that keeps running after the map unloads holds pointers
-- into freed world data. The shutdown hook at the bottom of this
-- file exists for exactly this reason and must not be removed.
--
-- Add one entry per helper script.
-- ==========================================
local HELPER_SCRIPTS = {
    -- "my-module-button",
    -- "my-module-job-hook",
}

local function start_helpers()
    for _, name in ipairs(HELPER_SCRIPTS) do
        local ok, helper = pcall(reqscript, name)
        if ok and helper and helper.start then
            helper.start()
            print(MODULE_NAME .. ": started helper [" .. name .. "].")
        else
            print(MODULE_NAME .. ": WARNING - could not start helper [" .. name .. "].")
        end
    end
end

local function stop_helpers()
    for _, name in ipairs(HELPER_SCRIPTS) do
        local ok, helper = pcall(reqscript, name)
        if ok and helper and helper.stop then
            helper.stop()
        end
    end
end


-- ==========================================
-- 6. REGISTRATION
-- ==========================================
-- Connects to RM's module engine and registers a listener. RM
-- calls that listener once, at startup, after the world raws are
-- loaded and before injection begins.
--
-- The listener runs everything above in order and returns finished
-- tables. That is the difference between this template and the
-- basic one: the basic template returns file PATHS and lets RM
-- parse them, which gives you no chance to edit the data first.
--
-- RETURN SHAPE:
--   materials   array from your materials JSON, or nil
--   reactions   array from your reactions JSON, or nil
--   categories  array from your reactions JSON, or nil
--   module      the identity block from either file
--
-- Returning nil from the listener means "skip this module." Do
-- that on any failure that would otherwise inject partial content.
-- ==========================================
local function register_with_rm()
    -- Find RM's module engine. If RM is not installed this fails
    -- quietly and the module simply never registers, which is the
    -- correct behaviour: nothing to attach to, nothing to say.
    local ok, engine = pcall(dfhack.script_environment, 'refinish-module-engine')
    if not ok or not engine or not engine.register_listener then
        return
    end

    engine.register_listener(MODULE_NAME, function()

        -- ---- RESOLVE OUR MOD FOLDER ----
        -- getModSourcePath returns paths like "mods/2945575779/"
        -- for a Workshop subscription, or
        -- "data/installed_mods/my_module (108)/" for a local
        -- install. Never hardcode either form.
        local mod_path = scriptmanager.getModSourcePath(MODULE_ID)
        if not mod_path then
            print(MODULE_NAME .. ": cannot resolve mod path for ID '" .. MODULE_ID .. "'.")
            return nil
        end

        local data_path = mod_path .. "data/"

        -- ---- RAW DEPENDENCY CHECK ----
        -- Runs first so its report appears above any other output.
        -- The return value is deliberately ignored: this reports,
        -- it does not gate.
        check_raw_dependencies()

        -- ---- LOAD JSON ----
        local mat_data = nil
        local rxn_data = nil

        if MATERIALS_FILE then
            mat_data = load_json(data_path .. MATERIALS_FILE)
            if not mat_data then
                print(MODULE_NAME .. ": failed to load " .. MATERIALS_FILE)
                return nil
            end
        end

        if REACTIONS_FILE then
            rxn_data = load_json(data_path .. REACTIONS_FILE)
            if not rxn_data then
                print(MODULE_NAME .. ": failed to load " .. REACTIONS_FILE)
                return nil
            end
        end

        if not mat_data and not rxn_data then
            print(MODULE_NAME .. ": no data files loaded, nothing to inject.")
            return nil
        end

        -- ---- EDIT THE PARSED DATA ----
        -- Everything from here to the return runs on plain Lua
        -- tables. This is your window to change anything before
        -- RM validates it. After the return it is too late.
        resolve_values(mat_data, rxn_data)
        patch_runtime_materials(rxn_data)

        -- ---- START HELPERS ----
        start_helpers()

        -- ---- HAND OFF ----
        return {
            materials  = mat_data and mat_data.materials or nil,
            reactions  = rxn_data and rxn_data.reactions or nil,
            categories = rxn_data and rxn_data.categories or nil,
            module     = (mat_data and mat_data.module)
                         or (rxn_data and rxn_data.module)
                         or nil,
        }
    end)
end


-- ==========================================
-- 7. SHUTDOWN HOOK
-- ==========================================
-- Stops every helper when the map unloads.
--
-- DO NOT REMOVE THIS if you use helper scripts. A polling callback
-- that survives a map unload is reading world data that has been
-- freed, and the crash it causes will look like it came from
-- somewhere else entirely.
--
-- The table key must be unique across all of DFHack. Use your
-- module ID so it cannot collide with another mod's hook.
--
-- RM handles its own cleanup separately. Everything this module
-- injected is swept out of RAM by the engine, so nothing here
-- needs to undo an injection.
-- ==========================================
dfhack.onStateChange.my_module_unload = function(code)
    if code == SC_MAP_UNLOADED then
        stop_helpers()
    end
end


-- ==========================================
-- AUTO-REGISTER ON LOAD
-- ==========================================
-- Registration is cheap: it stores a callback and returns. All the
-- real work happens later, when RM calls that callback.
-- ==========================================
register_with_rm()

return _ENV
