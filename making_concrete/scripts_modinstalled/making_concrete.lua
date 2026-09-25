--@ module = true
-- making_concrete.lua
-- ==========================================
-- MAKING CONCRETE: RM MODULE
-- ==========================================
-- Adds cement and concrete production to the game. A complete
-- industrial chain from raw limestone through quicklime, clinker,
-- and ground cement to finished portland cement blocks and boulders,
-- with colored variants via metal oxide pigments.
--
-- ARCHITECTURE:
--   Content lives in two JSON files:
--     making_concrete_materials.json: Cement material definitions
--     making_concrete_reactions.json: Cement reaction definitions
--
--   This Lua file loads JSONs, runs value calculation if needed,
--   and registers with RM's module engine via the listener API.
--
-- SAND BUTTON:
--   Also manages the "Collect Sand" native button injector for
--   mason workshops. The injector (making-concrete-sand-button.lua)
--   is started during module boot and stopped on map unload.
--   See RM_Native_Button_Injection.md for the technique reference.
-- ==========================================

local json = require('json')
local scriptmanager = require('script-manager')

-- ---- LOG IDENTITY, DECLARED HERE ----
-- RM core does not know this module exists and must never have to, so
-- the module states its own system and subsystem. Guarded reqscript: a
-- bare top level one is a hard load time dependency.
local LOG_SYS, LOG_SUB = 'MAKING_CONCRETE', 'MODULE'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed
-- by refinish-log. The identity above is declared by the module, not
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
-- SUBJECT is the correlation slot: the part of the module a line is
-- about (DATA, SAND, SAND_BUTTON, SAND_MULTIPLY, SAND_WATCHER).
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else.
-- This file used to print every message to the console and write
-- nothing to the log, so none of it reached the log panel.
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


-- ==========================================
-- CONFIGURATION: edit these to match your mod
-- ==========================================

-- Must match the [ID:...] in your mod's info.txt
local MODULE_ID = "making_concrete"

-- Friendly name for RM's log output
local MODULE_NAME = "Making Concrete"

-- JSON file names (relative to your mod's data/ folder)
local MATERIALS_FILE = "making_concrete_materials.json"
local REACTIONS_FILE = "making_concrete_reactions.json"


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
-- Only BAR reagents contribute. Non-metal inputs like
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
-- SAND MATERIAL RESOLVER
-- ==========================================
-- Scans the live inorganic array for a suitable sand material.
-- Vanilla DF has multiple sand types (SAND_TAN, SAND_WHITE,
-- SAND_BLACK, SAND_RED, SAND_YELLOW), all flagged SOIL_SAND.
-- Modded worlds may add more or remove some.
--
-- Preference order:
--   1. SAND_TAN (most common vanilla sand, always present
--      in unmodded worlds)
--   2. First inorganic with the SOIL_SAND flag
--
-- Returns: the inorganic ID string (e.g. "SAND_TAN"), or nil
-- if the world has no sand materials at all.
-- ==========================================
local function resolve_sand_id()
    local raws = df.global.world.raws.inorganics.all
    local fallback = nil

    for _, mat in ipairs(raws) do
        if mat.flags.SOIL_SAND then
            -- Preferred: vanilla SAND_TAN, so return immediately
            if mat.id == "SAND_TAN" then
                return "SAND_TAN"
            end
            -- Otherwise remember the first sand we find
            if not fallback then
                fallback = mat.id
            end
        end
    end

    return fallback  -- nil if no sand exists in this world
end


-- ==========================================
-- SAND PATCHER
-- ==========================================
-- Resolves null mat_id fields on sand-related reactions to the
-- best available sand inorganic in this world.
--
-- Patches three places:
--   1. GRIND_SAND products: what the grinder outputs
--   2. Any other null POWDER_MISC product (CRUSH_GRAVEL
--      byproducts, volcanic sand ghost remainders)
--   3. MIX_CONCRETE sand reagents: what the mixer accepts
--
-- All three use mat_id = null (JSON null → Lua nil) as a sentinel
-- meaning "resolve to the best sand at boot time."
--
-- If no sand material exists in the world, GRIND_SAND is removed
-- entirely. Everything else keeps its real output but loses
-- sand byproducts and their bag reagents. MIX_CONCRETE's sand
-- reagents stay nil (engine can't resolve them = no concrete).
--
-- This runs AFTER JSON loading but BEFORE the data is returned
-- to the module engine, so the engine never sees a nil mat_id.
-- ==========================================
local function patch_sand(rxn_data)
    if not rxn_data or not rxn_data.reactions then return end

    local sand_id = resolve_sand_id()

    if sand_id then
        local reagents_patched = 0

        for _, rxn in ipairs(rxn_data.reactions) do

            -- Any POWDER_MISC product carrying the null sentinel is
            -- ordinary sand, whatever reaction it belongs to.
            --
            -- This used to name reactions: GRIND_SAND and
            -- CRUSH_AGGREGATE. CRUSH_AGGREGATE was renamed to
            -- CRUSH_GRAVEL and the branch quietly stopped matching
            -- anything, which is exactly the failure a key list
            -- invites. The volcanic sand ghosts then added four more
            -- reactions that would each have needed adding here.
            --
            -- Matching on the sentinel instead means a new reaction
            -- opts in simply by writing "mat_id": null, and nothing
            -- else in this module writes that. Products with a real
            -- material (volcanic sand, gravel) are untouched.
            for _, prod in ipairs(rxn.products or {}) do
                if prod.type == "POWDER_MISC" and prod.mat_id == nil then
                    prod.mat_id = sand_id
                end
            end

            -- MIX_CONCRETE and any other sand consumer: patch null
            -- reagent mat_id. This is item 3 in the header above. It was
            -- documented but never implemented, so the mixer's sand slots
            -- stayed wildcard in RAM (mat_type -1 / mat_index -1) while
            -- only the GRIND_SAND output ever got a real material.
            --
            -- A wildcard POWDER reagent matches ANY powder sitting in a
            -- bag. With four wildcard sand slots next to a specific
            -- cement slot, DF has nothing to tell them apart and reagent
            -- matching goes non deterministic. Resolving the material
            -- here makes every sand slot specific, exactly like cement.
            --
            -- Predicate: type POWDER, no mat_id, code starting "sand".
            --   sand_bag_N  is type BAG      -> skipped, bags are
            --                                   deliberately material free
            --   sandstone   is type BOULDER  -> skipped, and it already
            --                                   carries mat_id SANDSTONE
            for _, rgt in ipairs(rxn.reagents or {}) do
                if rgt.type == "POWDER"
                        and rgt.mat_id == nil
                        and string.find(rgt.code, "^sand") then

                    rgt.mat_id = sand_id
                    reagents_patched = reagents_patched + 1

                    -- Drop sand_bearing once the material is known. It
                    -- was introduced as a stand in for this resolution
                    -- while the reagent was wildcard. Leaving both means
                    -- an item must satisfy the material AND the
                    -- SOIL_SAND flag: redundant, and one more filter
                    -- that can silently reject a valid bag.
                    rgt.sand_bearing = nil
                end
            end

        end
        log('DETAIL', 'Sand resolved to ' .. sand_id .. ' ('
            .. reagents_patched .. ' sand reagents patched).', 'SAND')
    else
        -- No sand in this world, so remove GRIND_SAND entirely (it only
        -- makes sand, so it's useless). Strip sand byproducts from
        -- every other reaction but keep it (its real output, gravel
        -- or volcanic sand, does not depend on world sand).
        local removed, products_stripped = 0, 0

        for i = #rxn_data.reactions, 1, -1 do
            local rxn = rxn_data.reactions[i]
            if rxn.key == "GRIND_SAND" then
                table.remove(rxn_data.reactions, i)
                removed = removed + 1
            else
                -- Every other reaction keeps its real products and
                -- loses only its sand ones. That covers CRUSH_GRAVEL's
                -- byproducts and the volcanic ghosts, which still make
                -- volcanic sand from their own material and simply
                -- fill fewer bags.
                local stripped = false
                for pi = #(rxn.products or {}), 1, -1 do
                    local prod = rxn.products[pi]
                    if prod.type == "POWDER_MISC" and prod.mat_id == nil then
                        table.remove(rxn.products, pi)
                        stripped = true
                    end
                end
                if stripped then products_stripped = products_stripped + 1 end
            end
        end

        log('WARNING', 'No sand material in this world. GRIND_SAND removed, '
            .. products_stripped .. ' reaction(s) lost their sand products.',
            'SAND')
    end
end


-- ==========================================
-- COLLECT SAND BUTTON MANAGEMENT
-- ==========================================
-- Starts and stops the mason workshop button injector. The
-- injector adds a native "Collect Sand" order to every mason
-- workshop, identical to the glass furnace's built-in button.
--
-- The injector script (making-concrete-sand-button.lua) manages
-- its own polling via repeat-util. We just call start/stop.
-- ==========================================

local function start_sand_button()
    local ok, sand_btn = pcall(reqscript, 'making-concrete-sand-button')
    if ok and sand_btn and sand_btn.start then
        sand_btn.start()
        log('DETAIL', 'Collect Sand button injector started.', 'SAND_BUTTON')
    else
        -- ERROR: mason workshops get no Collect Sand button.
        log('ERROR', 'Could not start the sand button injector.', 'SAND_BUTTON')
    end
end

local function stop_sand_button()
    local ok, sand_btn = pcall(reqscript, 'making-concrete-sand-button')
    if ok and sand_btn and sand_btn.stop then
        sand_btn.stop()
    end
end


-- ==========================================
-- COLLECT SAND MULTIPLIER MANAGEMENT
-- ==========================================
-- Starts and stops the onJobCompleted hook that multiplies
-- collect sand output from 1 unit to 4 units per bag. This
-- makes collected sand bags uniform with GRIND_SAND output
-- (4 units each), preventing mixed-size bag problems in
-- reaction matching and cutting sand haul counts by 75%.
--
-- The multiplier script (making-concrete-sand-multiply.lua)
-- registers an eventful callback. We just call start/stop.
-- ==========================================

local function start_sand_multiplier()
    local ok, sand_mul = pcall(reqscript, 'making-concrete-sand-multiply')
    if ok and sand_mul and sand_mul.start then
        sand_mul.start()
        log('DETAIL', 'Collect Sand multiplier started.', 'SAND_MULTIPLY')
    else
        -- ERROR: collected sand stays at one unit per bag.
        log('ERROR', 'Could not start the sand multiplier.', 'SAND_MULTIPLY')
    end
end

local function stop_sand_multiplier()
    local ok, sand_mul = pcall(reqscript, 'making-concrete-sand-multiply')
    if ok and sand_mul and sand_mul.stop then
        sand_mul.stop()
    end
end


-- ==========================================
-- GHOST SWAP WATCHER MANAGEMENT
-- ==========================================
-- Starts and stops the watcher that redirects generic grind
-- jobs to material specific ghost reactions.
--
-- What it does: the player orders one "grind stone into sand"
-- job. Before it completes, the watcher reads the stone the
-- dwarf actually carried in. Volcanic stone gets the job
-- pointed at GRIND_VOLCANIC_SAND instead, so the same menu
-- entry yields volcanic sand from obsidian and ordinary sand
-- from everything else.
--
-- The ghost is declared dormant in the JSON (permissions NONE,
-- fortress_mode false) so it never appears in a workshop menu.
-- The watcher wakes it only while a job needs it.
--
-- It also refuses to grind this module's own materials, the
-- way RM refuses to grind finished bars.
--
-- The watcher script (making-concrete-sand-watcher.lua) manages
-- its own polling via repeat-util. We just call start/stop.
-- ==========================================

local function start_sand_watcher()
    local ok, watcher = pcall(reqscript, 'making-concrete-sand-watcher')
    if ok and watcher and watcher.start then
        watcher.start()
        log('DETAIL', 'Ghost swap watcher started.', 'SAND_WATCHER')
    else
        -- ERROR: no volcanic sand swaps, and nothing stops this module's
        -- own materials being ground.
        log('ERROR', 'Could not start the ghost swap watcher.', 'SAND_WATCHER')
    end
end

local function stop_sand_watcher()
    local ok, watcher = pcall(reqscript, 'making-concrete-sand-watcher')
    if ok and watcher and watcher.stop then
        watcher.stop()
    end
end


-- ==========================================
-- REGISTRATION
-- ==========================================
-- Connects to RM's module engine and registers a listener
-- that fires when RM broadcasts its startup token call.
-- The listener loads JSONs, runs value calculation if needed,
-- resolves sand materials, starts the sand button injector,
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
        -- Resolve our mod's root folder at runtime.
        local mod_path = scriptmanager.getModSourcePath(MODULE_ID)
        if not mod_path then
            log('ERROR', "Cannot resolve the mod path for ID '" .. MODULE_ID
                .. "'.", 'DATA')
            return nil
        end

        local data_path = mod_path .. "data/"
        log('DETAIL', 'Loading from ' .. data_path, 'DATA')

        -- ---- LOAD JSON DATA ----
        local mat_data = nil
        local rxn_data = nil

        if MATERIALS_FILE then
            mat_data = load_json(data_path .. MATERIALS_FILE)
            if not mat_data then
                log('ERROR', 'Failed to load ' .. MATERIALS_FILE .. '.', 'DATA')
                return nil
            end
        end

        if REACTIONS_FILE then
            rxn_data = load_json(data_path .. REACTIONS_FILE)
            if not rxn_data then
                log('ERROR', 'Failed to load ' .. REACTIONS_FILE .. '.', 'DATA')
                return nil
            end
        end

        if not mat_data and not rxn_data then
            log('ERROR', 'No data files loaded, so there is nothing to inject.',
                'DATA')
            return nil
        end

        log('DETAIL', 'Data loaded successfully.', 'DATA')

        -- ---- WEIGHTED VALUE CALCULATION ----
        if mat_data and rxn_data then
            local has_null_values = false
            for _, mat in ipairs(mat_data.materials) do
                if mat.value == nil then
                    has_null_values = true
                    break
                end
            end

            if has_null_values then
                local rxn_lookup = {}
                for _, rxn in ipairs(rxn_data.reactions) do
                    rxn_lookup[rxn.key] = rxn
                end

                for _, mat in ipairs(mat_data.materials) do
                    if mat.value == nil then
                        if mat.value_from_reaction then
                            local rxn = rxn_lookup[mat.value_from_reaction]
                            if rxn and rxn.reagents then
                                mat.value = calculate_weighted_value(rxn.reagents)
                            end
                        end
                        if mat.value == nil then
                            mat.value = 1
                        end
                    end
                end
            end
        end

        -- ---- SAND MATERIAL RESOLUTION ----
        -- Resolve null mat_id on GRIND_SAND product to the best
        -- available sand inorganic in this world. Must run before
        -- the engine processes reaction data, since the engine
        -- expects all mat_id values to be resolvable strings.
        if rxn_data then
            patch_sand(rxn_data)
        end

        -- ---- COLLECT SAND BUTTON ----
        -- Start the mason workshop button injector. Adds a native
        -- "Collect Sand" order to every mason workshop, identical
        -- to the glass furnace's built-in button. Runs after sand
        -- resolution since it depends on the world having sand.
        start_sand_button()

        -- ---- COLLECT SAND MULTIPLIER ----
        -- Start the onJobCompleted hook that multiplies collect
        -- sand output from 1 to 4 units per bag. This makes
        -- collected sand uniform with GRIND_SAND output and cuts
        -- sand haul counts by 75%.
        start_sand_multiplier()

        -- ---- GHOST SWAP WATCHER ----
        -- Started last. It sweeps orphaned ghost names off any
        -- jobs that survived a save, which needs the reactions
        -- to be present, and the engine injects those from the
        -- data returned just below. The first poll is a frame
        -- away, so the sweep lands after injection either way.
        start_sand_watcher()

        -- ---- RETURN TO ENGINE ----
        return {
            materials  = mat_data and mat_data.materials or nil,
            reactions  = rxn_data and rxn_data.reactions or nil,
            categories = rxn_data and rxn_data.categories or nil,
            module     = mat_data and mat_data.module or
                         rxn_data and rxn_data.module or nil,
        }
    end, MODULE_ID)
end


-- ==========================================
-- SHUTDOWN HOOK
-- ==========================================
-- Stops the button injector, sand multiplier and ghost swap
-- watcher when the map
-- unloads. This prevents callbacks from running after the
-- world data they reference has been freed.
-- ==========================================
dfhack.onStateChange.making_concrete_unload = function(code)
    if code == SC_MAP_UNLOADED then
        stop_sand_button()
        stop_sand_multiplier()
        stop_sand_watcher()
    end
end


-- ==========================================
-- AUTO-REGISTER ON LOAD
-- ==========================================
register_with_rm()

return _ENV