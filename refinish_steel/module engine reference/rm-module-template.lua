--@ module = true
-- ==========================================
-- RM MODULE: [YOUR MOD NAME]
-- ==========================================
-- This is the Lua shell for an RM (Refinish Metal) module.
-- It registers with RM's module engine and points it at your
-- JSON data files. You should not need to modify this file
-- beyond the configuration section below.
--
-- HOW IT WORKS:
--   1. When DF loads your mod, DFHack runs this script.
--   2. This script registers a listener with RM's module engine.
--   3. When RM starts up, it broadcasts a token call.
--   4. Your listener responds with paths to your JSON data files.
--   5. RM loads, validates, and injects your materials/reactions.
--   6. On shutdown, RM sweeps everything clean from RAM.
--
-- REQUIREMENTS:
--   - Refinish Metal must be installed and active.
--   - Your JSON data files must be in the location specified below.
--
-- SETUP:
--   1. Set MODULE_ID to match your mod's ID from info.txt.
--   2. Set MODULE_NAME to a friendly name for logs.
--   3. Set the JSON file names to match your data files.
--   4. Place this file in scripts_modactive/ (or scripts_modinstalled/)
--   5. Place your JSON files in the data/ subfolder of your mod.
-- ==========================================


-- ==========================================
-- CONFIGURATION — Edit these to match your mod
-- ==========================================

-- Must match the [ID:...] in your mod's info.txt
local MODULE_ID = "my_cool_alloys"

-- Friendly name for RM's log output
local MODULE_NAME = "my_cool_alloys"

-- JSON file names (relative to your mod's data/ folder)
local MATERIALS_FILE = "my_cool_alloys_materials.json"
local REACTIONS_FILE = "my_cool_alloys_reactions.json"

-- Set to nil if your mod only has materials or only has reactions
-- local MATERIALS_FILE = nil   -- uncomment if no materials file
-- local REACTIONS_FILE = nil   -- uncomment if no reactions file


-- ==========================================
-- REGISTRATION — Do not edit below this line
-- ==========================================

local scriptmanager = require('script-manager')

local function register_with_rm()
    -- Locate RM's module engine. If RM isn't installed, this
    -- fails gracefully — the module just doesn't register.
    local ok, engine = pcall(dfhack.script_environment, 'refinish-module-engine')
    if not ok or not engine or not engine.register_listener then
        return
    end

    engine.register_listener(MODULE_NAME, function()
        -- Resolve our mod's root folder at runtime.
        -- scriptmanager.getModSourcePath returns paths like:
        --   "mods/2945575779/" (Steam Workshop)
        --   "data/installed_mods/my_cool_alloys (108)/" (installed)
        local mod_path = scriptmanager.getModSourcePath(MODULE_ID)
        if not mod_path then
            print("Refinish Metal: Module [" .. MODULE_NAME .. "] cannot resolve mod path for ID '" .. MODULE_ID .. "'.")
            return nil
        end

        local data_path = mod_path .. "data/"
        local result = {}

        if MATERIALS_FILE then
            result.materials_json = data_path .. MATERIALS_FILE
        end

        if REACTIONS_FILE then
            result.reactions_json = data_path .. REACTIONS_FILE
        end

        return result
    end, MODULE_ID)
end

register_with_rm()

return _ENV