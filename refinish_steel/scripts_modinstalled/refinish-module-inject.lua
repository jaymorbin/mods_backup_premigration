--@ module = true
-- refinish-module-inject.lua
-- ==========================================
-- RM MODULE MATERIAL INJECTION
-- ==========================================
-- Takes validated material definitions and injects them into the
-- live inorganic array. For each material:
--   1. Pull clone donor from the evaluator cache (by class)
--   2. Deep-copy the donor
--   3. Set identity (ID, display names)
--   4. Apply material class preset (clear + set flags)
--   5. Apply property overrides (color, value, density, heat, strength)
--   6. Apply reaction_classes and reaction_products
--   7. Apply flag overrides (material_flags, inorganic_flags)
--   8. Inject into the live array
--
-- DEPENDENCIES:
--   refinish-module-types.lua   - Class presets, clone signatures
--   refinish-evaluate-clone-source.lua - Cached clone donors
--
-- CALLED FROM:
--   refinish-module-engine.lua (pipeline step)
-- ==========================================

-- ==========================================
-- LOG FUNNELS
-- ==========================================
-- RM's own, and peripheral rather than pipeline. Every line this file
-- writes goes through one of the two funnels below, in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body.
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
-- Two subsystems, as this file always had: MODULE_INJECT for the
-- materials and GRAPHICS for their sprites. One funnel per subsystem,
-- from the same factory refinish_steel uses, so the call sites no
-- longer pass it. SUBJECT is the correlation slot: the part of the job
-- a line is about, or the module it concerns.
--
-- A material this file could not build, or built broken, is an ERROR:
-- the player meets it in play. A declaration ignored in favour of a
-- sane default is a WARNING.
--
-- This replaces a log() that let refinish-log guess TYPE from the
-- words (read_type) unless a call site said otherwise.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else.
-- ==========================================
local LOG_SYS = 'REFINISH_METAL'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

local function make_log(sub)
    return function(typ, msg, subject)
        if not _G.refinish_log_event then return end
        local line
        if rlog then
            line = rlog.compose(LOG_SYS, sub, subject, typ, msg)
        else
            -- The composer failed to load. Same grammar, unsanitised.
            line = string.format('%s %s %s %s | %s', LOG_SYS, sub,
                tostring(subject or '-'), tostring(typ or 'UNTYPED'),
                tostring(msg))
        end
        _G.refinish_log_event(line)
    end
end

local log_inject   = make_log('MODULE_INJECT')
local log_graphics = make_log('GRAPHICS')

local types = reqscript('refinish-module-types')
local clone_eval = reqscript('refinish-evaluate-clone-source')


-- ==========================================
-- NEUTRAL RESET
-- ==========================================
-- After deep-copying a clone donor via m:assign(donor), the new
-- inorganic_raw carries ALL of the donor's state - identity, flags,
-- geological data, ore relationships, syndromes, everything. The
-- donor gives us valid C++ structural plumbing (pointers, vtable,
-- vector containers) that prevents CTDs, but the semantic content
-- on top of that plumbing is the donor's, not ours.
--
-- This function resets every semantic field to the neutral values
-- defined by the builtin INORGANIC template:
--   df.global.world.raws.mat_table.builtin.INORGANIC
-- That builtin is a `material` object (not an inorganic_raw), so
-- it maps to the `.material` sub-object. For inorganic_raw-level
-- fields, neutral means "no geological identity, no relationships."
--
-- The reset runs AFTER assign() and BEFORE any schema overrides.
-- Every field it touches is named explicitly - no loops over
-- unknown fields, no magic. The schema steps that follow (identity,
-- class preset, color, heat, strength, etc.) then build up the
-- new material's real state cleanly from this neutral foundation.
--
-- WHY NOT JUST USE THE BUILTIN DIRECTLY?
-- The builtin is a material object, not an inorganic_raw. It has
-- no C++ internal state for the inorganic container (no valid
-- pointers, no vtable for inorganic_raw methods). Cloning from a
-- real donor gives us that structural validity. The builtin just
-- tells us what "empty" looks like for each field.
--
-- FIELD CATEGORIES (from Phase 1 audit of 16 reference objects):
--   Structural - pointers, vtable, vector containers. NEVER TOUCH.
--   Identity   - names, IDs, display strings. Set by later steps.
--   Semantic   - flags, relationships, gameplay state. RESET HERE.
--   Physical   - density, heat, strength. Set by later steps.
--
-- Reference objects consulted:
--   builtin.INORGANIC, IRON, PLASTER, GRANITE, TETRAHEDRITE,
--   MAGNETITE, LIMESTONE, MARBLE, OBSIDIAN, DIORITE, KAOLINITE,
--   FIRE_CLAY, CLEAR_DIAMOND, DIVINE_1, MYTHICAL_REMNANT_1,
--   MYTHICAL_SUBSTANCE_1, dirty ORICHALCUM (post-inject snapshot)
-- ==========================================
local function reset_to_neutral(m)

    -- =====================
    -- INORGANIC_RAW LEVEL
    -- =====================
    -- These fields live on the outer inorganic_raw object, above
    -- the .material sub-object. The builtin doesn't have these
    -- (it's just a material), so neutral = "no geological identity."

    -- Geological placement flags (SEDIMENTARY, IGNEOUS_INTRUSIVE,
    -- METAL_ORE, SOIL, DIVINE, GENERATED, MYTHICAL, etc.)
    -- Iron has all false; stones/ores/divine materials have various
    -- flags set. An injected material has no geological identity,
    -- so all 32 flags go to false. Named flags go first for
    -- readability, then the unnamed high bits for completeness.
    local inorg_flag_names = {
        "LAVA", "GENERATED", "CAN_OCCUR_ON_SURFACE",
        "SEDIMENTARY", "SEDIMENTARY_OCEAN_SHALLOW",
        "IGNEOUS_INTRUSIVE", "IGNEOUS_EXTRUSIVE", "METAMORPHIC",
        "DEEP_SURFACE", "METAL_ORE", "AQUIFER",
        "SOIL_ANY", "SOIL_OCEAN", "SOIL_SAND",
        "SEDIMENTARY_OCEAN_DEEP", "THREAD_METAL",
        "SPECIAL", "SOIL", "DEEP_SPECIAL",
        "DIVINE", "MYTHICAL", "MYTHICAL_REMNANT",
        "MYTHICAL_SUBSTANCE", "UNUSED_03_08", "UNUSED_04_01",
        "WAFERS",
    }
    for _, flag in ipairs(inorg_flag_names) do
        m.flags[flag] = false
    end
    -- Unnamed high bits (26-31) - false on every reference object
    for i = 26, 31 do
        m.flags[i] = false
    end

    -- Ore-smelting relationships. Tetrahedrite has mat_index=[3,2]
    -- probability=[100,20] (copper + silver). Magnetite has [0]/[100]
    -- (iron). An injected material isn't an ore.
    m.metal_ore.str:resize(0)
    m.metal_ore.mat_index:resize(0)
    m.metal_ore.probability:resize(0)

    -- Thread-metal relationships (adamantine-style). Empty on all
    -- 16 reference objects, but could exist on modded donors.
    m.thread_metal.str:resize(0)
    m.thread_metal.mat_index:resize(0)
    m.thread_metal.probability:resize(0)

    -- Economic uses - reaction indexes that tell DF "this material
    -- is consumed by these reactions." Iron has [151,152] (steel/pig
    -- iron making), fire clay has 38 entries. Already was cleared
    -- in old Step 2.5; now consolidated here.
    m.economic_uses:resize(0)

    -- Geological environment data - where worldgen places this
    -- mineral. Tetrahedrite has 5 entries (veins in various rock
    -- types), magnetite has 4. An injected material isn't placed
    -- by worldgen.
    m.environment.location:resize(0)
    m.environment.type:resize(0)
    m.environment.probability:resize(0)

    -- Environment spec (specific host rock relationships). Empty
    -- on all 16 references, but could exist on exotic donors.
    m.environment_spec.str:resize(0)
    m.environment_spec.mat_index:resize(0)
    m.environment_spec.inclusion_type:resize(0)
    m.environment_spec.probability:resize(0)

    -- =====================
    -- MATERIAL LEVEL
    -- =====================
    -- These fields live on m.material, the inner material object.
    -- Neutral values come from the builtin INORGANIC template.

    local mat = m.material

    -- Hardens-with-water linkage. Plaster has mat_type=0,
    -- mat_index=203, str=["INORGANIC","GYPSUM",""].
    -- Builtin neutral: mat_type=-1, mat_index=-1, all str="".
    -- THIS IS THE PRIMARY ITE BUG FIX - a plaster-cloned stone
    -- with hardens_with_water set tells DF it needs water to
    -- solidify, preventing normal construction use.
    mat.hardens_with_water.mat_type  = -1
    mat.hardens_with_water.mat_index = -1
    mat.hardens_with_water.str[0]    = ""
    mat.hardens_with_water.str[1]    = ""
    mat.hardens_with_water.str[2]    = ""

    -- Sphere assignments (deity domain). Divine materials have
    -- sphere entries (e.g. CHAOS=9). Builtin has empty vector.
    -- A module material has no divine patron.
    mat.sphere:resize(0)

    -- Syndrome/interaction effects. Mythical substances can carry
    -- full syndrome trees (12+ creature interaction effects).
    -- Builtin has empty vector. Leaking a "weird goo effect"
    -- onto a module alloy would be catastrophic.
    mat.syndrome.syndrome:resize(0)

    -- Display tile. Builtin=219 (solid block █). Stones vary:
    -- plaster=35 (#), magnetite=126 (~), obsidian/granite=178 (▓).
    -- Reset to builtin default; schema color step handles visual
    -- identity. If we later want schema-level tile control, we
    -- add an override path then.
    mat.tile = 219

    -- Item symbol - the inventory icon glyph. Builtin=7 (♦),
    -- which is the universal default for metals and stones. Ore
    -- stones that declare [ITEM_SYMBOL:'*'] get 42. Reset to the
    -- builtin default so ore donors don't leak their star icon.
    mat.item_symbol = 7

    -- Boulder/rough texture atlas positions. These are graphics-
    -- layer sprite indexes populated by DF's texture system.
    -- Builtin has 0 for all. Stones may have non-zero values
    -- from texture packs or mods (e.g. Keteros' Stone Variations).
    -- An injected material shouldn't claim another stone's sprite.
    mat.boulder_texpos1 = 0
    mat.boulder_texpos2 = 0
    mat.rough_texpos1   = 0
    mat.rough_texpos2   = 0

    -- Material RGB values. Builtin=[1.0, 1.0, 1.0] (white).
    -- Donors have their own RGB (iron=0.502 gray, fire clay has
    -- rust-colored values). Reset to white; the color resolver
    -- handles state_color/build_color/basic_color/tile_color from
    -- the schema, but mat_rgb is a separate channel that could
    -- affect rendering if not neutralized.
    mat.mat_rgb[0] = 1.0
    mat.mat_rgb[1] = 1.0
    mat.mat_rgb[2] = 1.0

    -- Strength absorption. Builtin=0, all stones/metals=0, but
    -- SOIL_TEMPLATE materials (fire clay) have 100. Reset to
    -- builtin neutral; schema strength overrides handle the rest.
    mat.strength.absorption = 0

    -- Stone name. Empty string on all 16 references and builtin.
    -- Reset for safety in case an exotic donor has one, then
    -- rewritten from def.stone_name at STEP 3b if the schema asks.
    mat.stone_name = ""

    -- Dye colour. -1 on the builtin and on every dumped inorganic, so
    -- a stone donor already brings -1; reset anyway so an exotic donor
    -- cannot hand a non-dye a dye colour. apply_dye_color writes the
    -- real value once the flags are final (STEP 13b).
    mat.powder_dye = -1

    -- Block name, same reasoning. A ceramic donor would otherwise
    -- leak its "bricks" naming onto anything cloned from it.
    mat.block_name[0] = ""
    mat.block_name[1] = ""

    -- ALL material flags get blanked to builtin neutral (all false).
    -- The class preset step that follows immediately after will
    -- then set the correct flags for the target class (IS_METAL,
    -- IS_STONE, etc.). This replaces the old approach where presets
    -- only cleared cross-class flags - now the reset guarantees a
    -- clean slate, and presets purely build up identity.
    --
    -- This catches flags the old presets missed:
    --   NO_STONE_STOCKPILE (plaster donor leak → ite bug)
    --   ITEMS_QUERN (STONE_TEMPLATE universal → wrong for metals)
    --   ITEMS_HARD (assumed but not guaranteed from all donors)
    --   DISPLAY_UNGLAZED, STOCKPILE_THREAD_METAL, etc.
    --
    -- Named flags (0-82), then unnamed high bits (83-87).
    local mat_flag_names = {
        "BONE", "MEAT", "EDIBLE_VERMIN", "EDIBLE_RAW", "EDIBLE_COOKED",
        "ALCOHOL",
        "ITEMS_METAL", "ITEMS_BARRED", "ITEMS_SCALED",
        "ITEMS_LEATHER", "ITEMS_SOFT", "ITEMS_HARD",
        "IMPLIES_ANIMAL_KILL",
        "ALCOHOL_PLANT", "ALCOHOL_CREATURE",
        "CHEESE_PLANT", "CHEESE_CREATURE",
        "POWDER_MISC_PLANT", "POWDER_MISC_CREATURE",
        "STOCKPILE_GLOB",
        "LIQUID_MISC_PLANT", "LIQUID_MISC_CREATURE", "LIQUID_MISC_OTHER",
        "WOOD", "THREAD_PLANT",
        "TOOTH", "HORN", "PEARL", "SHELL", "LEATHER", "SILK",
        "SOAP", "ROTS", "IS_DYE",
        "POWDER_MISC", "LIQUID_MISC",
        "STRUCTURAL_PLANT_MAT", "SEED_MAT", "STOCKPILE_PLANT_GROWTH",
        "CHEESE", "ENTERS_BLOOD",
        "BLOOD_MAP_DESCRIPTOR", "ICHOR_MAP_DESCRIPTOR",
        "GOO_MAP_DESCRIPTOR", "SLIME_MAP_DESCRIPTOR",
        "PUS_MAP_DESCRIPTOR",
        "GENERATES_MIASMA",
        "IS_METAL", "IS_GEM", "IS_GLASS", "CRYSTAL_GLASSABLE",
        "ITEMS_WEAPON", "ITEMS_WEAPON_RANGED",
        "ITEMS_ANVIL", "ITEMS_AMMO", "ITEMS_DIGGER",
        "ITEMS_ARMOR", "ITEMS_DELICATE", "ITEMS_SIEGE_ENGINE",
        "ITEMS_QUERN", "IS_STONE", "UNDIGGABLE",
        "YARN", "STOCKPILE_GLOB_PASTE", "STOCKPILE_GLOB_PRESSED",
        "DISPLAY_UNGLAZED", "DO_NOT_CLEAN_GLOB",
        "NO_STONE_STOCKPILE", "STOCKPILE_THREAD_METAL",
        "SWEAT_MAP_DESCRIPTOR", "TEARS_MAP_DESCRIPTOR",
        "SPIT_MAP_DESCRIPTOR",
        "EVAPORATES", "STOCKPILE_PLANT",
        "IS_CERAMIC",
        "CARTILAGE", "FEATHER", "SCALE", "HAIR",
        "NERVOUS_TISSUE", "HOOF", "CHITIN", "ANTLER",
    }
    for _, flag in ipairs(mat_flag_names) do
        mat.flags[flag] = false
    end
    -- Unnamed high bits (83-87) - false on every reference object
    for i = 83, 87 do
        mat.flags[i] = false
    end
end


-- ==========================================
-- COLOR RESOLVER
-- ==========================================
-- Looks up a descriptor color name in the world's color table.
-- Falls through fallback names, then to ANSI index 7 (light gray).
-- Same pattern as making_metal.lua's resolve_color, now shared.
-- ==========================================
-- Global for the same reason as the appliers below: the plant
-- injector resolves colour through this before calling apply_color,
-- which takes a RESOLVED spec (solid, display, build) rather than
-- the raw JSON keys (color, fallback_colors).
function resolve_color(primary, fallbacks)
    local colors = df.global.world.raws.descriptors.colors
    if primary then
        local upper_primary = string.upper(primary)
        for i, c in ipairs(colors) do
            if c.id == upper_primary then return i end
        end
    end
    if fallbacks then
        for _, fb_name in ipairs(fallbacks) do
            local upper_fb = string.upper(fb_name)
            for i, c in ipairs(colors) do
                if c.id == upper_fb then return i end
            end
        end
    end
    -- Final fallback: ANSI color 7 (white/light gray)
    return 7
end


-- ==========================================
-- APPLY DISPLAY NAME
-- ==========================================
-- Sets all six state name/adj variations. Covers every state so no
-- donor names leak through on Powder, Paste, or Pressed.
--
-- Default convention (used when no overrides are supplied):
--   Solid:   "ite"          Powder:  "ite"
--   Liquid:  "molten ite"   Paste:   "ite"
--   Gas:     "boiling ite"  Pressed: "ite"
--
-- That convention is right for metals and stones, but wrong for any
-- material already named as a liquid: a material whose solid state is
-- "frozen oil of vitriol" must not become "molten frozen oil of
-- vitriol". Those materials supply an explicit `names` table in their
-- schema, and each state it names wins over the generated form.
--
-- names fields (all optional, mix and match freely):
--   solid, liquid, gas, powder, paste, pressed
--
-- Omitting `names` entirely reproduces the old behaviour exactly, so
-- existing modules are unaffected.
--
-- Powder uses the base name with no suffix. RM's dust naming system
-- handles powder display names ("[name] dust") separately in its own
-- pipeline for materials it processes.
-- ==========================================
-- ==========================================
-- SHARED MATERIAL APPLIERS: GLOBAL ON PURPOSE
-- ==========================================
-- The functions below are declared without `local` so that
-- refinish-module-inject-plant.lua can call them. reqscript returns
-- a script's GLOBAL environment and cannot see file locals, so as
-- locals they were invisible to the plant path, which would then
-- need its own copy of all eight.
--
-- Re-localising any of them compiles cleanly and silently breaks
-- plant material naming, colour, sprites and reaction classes.
-- ==========================================
function apply_display_name(material, name, names)
    names = names or {}

    -- Generate the default for each state, then let an explicit
    -- name from the schema take precedence.
    local solid   = names.solid   or name
    local liquid  = names.liquid  or ("molten "  .. name)
    local gas     = names.gas     or ("boiling " .. name)
    local powder  = names.powder  or name
    local paste   = names.paste   or name
    local pressed = names.pressed or name

    material.state_name.Solid   = solid
    material.state_adj.Solid    = solid
    material.state_name.Liquid  = liquid
    material.state_adj.Liquid   = liquid
    material.state_name.Gas     = gas
    material.state_adj.Gas      = gas
    material.state_name.Powder  = powder
    material.state_adj.Powder   = powder
    material.state_name.Paste   = paste
    material.state_adj.Paste    = paste
    material.state_name.Pressed = pressed
    material.state_adj.Pressed  = pressed
end


-- ==========================================
-- APPLY COLOR
-- ==========================================
-- DF stores material colour in TWO UNRELATED number spaces. Mixing
-- them is the bug this function exists to prevent.
--
--   state_color[]  -- Index into world.raws.descriptors.colors.
--                     Drives the colour WORD ("silver-colored bar").
--                     Range is however many descriptors are loaded,
--                     typically in the hundreds.
--
--   tile_color[]   -- ANSI triple {foreground, background, brightness}.
--   build_color[]     Drives the actual on-screen colour. Range 0-7.
--   basic_color[]  -- ANSI pair {foreground, brightness}.
--
-- Verified against vanilla IRON. Its raws read:
--   [DISPLAY_COLOR:0:7:1] [BUILD_COLOR:0:7:1] [STATE_COLOR:ALL_SOLID:GRAY]
-- and its loaded material reads:
--   tile_color={0,7,1}  build_color={0,7,1}  state_color.Solid=49
-- Confirming the DISPLAY/BUILD tokens pass straight through as ANSI
-- while STATE_COLOR resolves to a descriptor index.
--
-- spec fields:
--   solid   -- descriptor index (required)
--   liquid  -- descriptor index for the molten state (defaults to solid)
--   gas     -- descriptor index for the boiling state (defaults to solid)
--   display -- {fg, bg, bright} ANSI triple, or nil
--   build   -- {fg, bg, bright} ANSI triple, or nil (defaults to display)
--
-- When display is omitted we use {7,0,0}, which is what STONE_TEMPLATE,
-- METAL_TEMPLATE and SOIL_TEMPLATE all specify. Note these come from
-- JSON, so they are 1-indexed Lua arrays, while the DF struct arrays
-- they feed are 0-indexed.
-- ==========================================
local DEFAULT_ANSI = { 7, 0, 0 }

function apply_color(material, spec)
    local solid  = spec.solid
    local liquid = spec.liquid or solid
    local gas    = spec.gas    or solid

    -- ---- Descriptor indices: the colour WORD ----
    material.state_color.Solid   = solid
    material.state_color.Powder  = solid
    material.state_color.Paste   = solid
    material.state_color.Pressed = solid
    material.state_color.Liquid  = liquid
    material.state_color.Gas     = gas

    -- ---- ANSI values: the ON-SCREEN colour ----
    local disp  = spec.display or DEFAULT_ANSI
    local build = spec.build   or disp

    material.tile_color[0] = disp[1]
    material.tile_color[1] = disp[2]
    material.tile_color[2] = disp[3]

    material.build_color[0] = build[1]
    material.build_color[1] = build[2]
    material.build_color[2] = build[3]

    -- basic_color is tile_color with the background dropped.
    material.basic_color[0] = disp[1]
    material.basic_color[1] = disp[3]
end


-- ==========================================
-- APPLY GRAPHICS (material-side sprite slots)
-- ==========================================
-- Canonical version, replacing all prior variants wholesale.
-- Immediate application (the load-order race theory was disproven:
-- coal read warm, 42294, during the failing runs). The one real
-- bug was donor grammar: matinfo.find speaks raws tokens and knows
-- no builtins, so BUILTIN:<NAME> is resolved by this engine
-- directly against mat_table.builtin.
--
-- Schema, on a material definition:
--   "graphics": {
--     "bar":     "BUILTIN:COAL",
--     "boulder": { "donor": "INORGANIC:MAGNETITE" },
--     "wood":    { "donor": "PLANT:OAK:WOOD", "offset": 1 },
--     "texflag": "BUILTIN:COAL"
--   }
-- Slots: bar, boulder, wood, rough, cheese, texflag. Paired slots
-- copy both donor fields. offset shifts by whole cells; the atlas
-- row stride measured on ITEM_CONSTRUCTION is 4.
--
-- texpos is read LIVE from the donor at inject time, never stored,
-- so values stay correct across asset changes between sessions.
-- Delegation: the material handler moved into the universal sprite
-- engine so materials and tools share one resolver and one source
-- grammar. Behaviour is identical; only the address changed.
local sprite_engine = nil
local function get_sprite_engine()
    if sprite_engine == nil then
        local ok, eng = pcall(reqscript, 'refinish-sprite-engine')
        sprite_engine = ok and eng or false
    end
    return sprite_engine or nil
end

function apply_graphics(material, spec, mat_key)
    if spec == nil then return end
    local eng = get_sprite_engine()
    if eng then
        eng.apply_to_material(material, spec, mat_key)
    else
        -- WARNING: the material draws without its sprite.
        log_graphics('WARNING', 'sprite engine missing,'
            .. ' nothing applied for ' .. tostring(mat_key), 'ENGINE')
    end
end


-- ==========================================
-- APPLY MATERIAL CLASS PRESET
-- ==========================================
-- Reads the clear/set lists from the types dictionary and
-- applies them to the material's flags. This is the two-step
-- process that handles cross-class cloning cleanly:
--   1. Clear: force-set listed flags to false
--   2. Set:   force-set listed flags to true
-- ==========================================
function apply_class_preset(material, class_name)
    local preset = types.MATERIAL_CLASS_PRESETS[class_name]
    if not preset then return end

    -- Step 1: Clear flags that don't belong to this class
    for _, flag_name in ipairs(preset.clear) do
        material.flags[flag_name] = false
    end

    -- Step 2: Set flags that define this class
    for _, flag_name in ipairs(preset.set) do
        material.flags[flag_name] = true
    end
end


-- ==========================================
-- APPLY DYE COLOUR
-- ==========================================
-- powder_dye is the colour a dye DYES with, a descriptor index, and it
-- is a separate field from the colour the material LOOKS like. Every
-- vanilla dye sets it with [POWDER_DYE:<colour>]; IS_DYE never appears
-- in vanilla without it. Vanilla keeps the two apart on purpose:
-- redroot dye looks BROWN and dyes RED.
--
-- MEASURED (making-fuel-dye-probe, 2026-09-23):
--   * DF's dye system is keyed on this field. Every dye job slot names
--     a colour (job_item.dye_color), and a dye answers through
--     isDyeColor(), which reads its material's powder_dye: a dye item
--     made while the field was -1 reported BLACK as soon as the field
--     was written. The Make dye menu swatch is the product's
--     powder_dye as well.
--   * A dye left at -1 is still IS_DYE, so a plain Dye cloth job takes
--     it, completes, and dyes nothing.
--
-- RULE. A material that is IS_DYE gets a dye colour. The module's
-- dye_color wins when it names a loaded colour. Otherwise the default
-- is the colour the material already wears, state_color.Powder, which
-- apply_color writes. A dye_color naming no loaded colour is reported
-- and the default used; a dye with no colour at all is reported and
-- left at -1. A material that is not IS_DYE is given -1.
--
-- Called once the flags are final, since IS_DYE can come from the
-- class preset or from a material_flags override. label names the
-- material in the log.
-- ==========================================
function apply_dye_color(material, def, label)
    if not material.flags.IS_DYE then
        material.powder_dye = -1
        return
    end

    -- The override, by exact token. resolve_color is not used here
    -- because its last resort is a fixed index, which would hand a
    -- misspelt dye_color a real but wrong colour with no report.
    local idx = nil
    if def and def.dye_color then
        local want = string.upper(tostring(def.dye_color))
        for i, c in ipairs(df.global.world.raws.descriptors.colors) do
            if c.id == want then idx = i; break end
        end
        if not idx then
            log_inject('WARNING', string.format(
                "[%s] dye_color '%s' is not a loaded colour; the material's own colour is used.",
                tostring(label), tostring(def.dye_color)), 'DYE')
        end
    end

    -- The derived default.
    if not idx then
        local own = material.state_color.Powder
        if own and own >= 0 then idx = own end
    end

    if not idx then
        -- ERROR: plain Dye jobs take it and dye nothing, which the player
        -- will notice.
        log_inject('ERROR', "[" .. tostring(label) .. "] is a dye with no colour"
            .. " to dye with. DF will take it for plain dye jobs and dye"
            .. " nothing.", 'DYE')
        material.powder_dye = -1
        return
    end
    material.powder_dye = idx
end


-- ==========================================
-- APPLY HEAT OVERRIDES
-- ==========================================
-- Each sub-field is independent. nil = keep clone's value.
-- ==========================================
function apply_heat(material, heat)
    if not heat then return end
    if heat.spec_heat       then material.heat.spec_heat       = heat.spec_heat end
    if heat.melting_point    then material.heat.melting_point    = heat.melting_point end
    if heat.boiling_point    then material.heat.boiling_point    = heat.boiling_point end
    if heat.ignite_point     then material.heat.ignite_point     = heat.ignite_point end
    if heat.heatdam_point    then material.heat.heatdam_point    = heat.heatdam_point end
    if heat.colddam_point    then material.heat.colddam_point    = heat.colddam_point end
    if heat.mat_fixed_temp   then material.heat.mat_fixed_temp   = heat.mat_fixed_temp end
end


-- ==========================================
-- APPLY STRENGTH OVERRIDES
-- ==========================================
-- Three sub-groups (yield, fracture, strain_at_yield) plus max_edge.
-- Each field within each group is independent. nil = keep clone.
-- ==========================================
function apply_strength(material, strength)
    if not strength then return end

    local stress_types = { "IMPACT", "COMPRESSIVE", "TENSILE", "TORSION", "SHEAR", "BENDING" }

    if strength.yield then
        for _, s in ipairs(stress_types) do
            if strength.yield[s] then
                material.strength.yield[s] = strength.yield[s]
            end
        end
    end

    if strength.fracture then
        for _, s in ipairs(stress_types) do
            if strength.fracture[s] then
                material.strength.fracture[s] = strength.fracture[s]
            end
        end
    end

    if strength.strain_at_yield then
        for _, s in ipairs(stress_types) do
            if strength.strain_at_yield[s] then
                material.strength.strain_at_yield[s] = strength.strain_at_yield[s]
            end
        end
    end

    if strength.max_edge then
        material.strength.max_edge = strength.max_edge
    end

    -- Absorption. reset_to_neutral zeroes this, which is right for
    -- stones and metals, but SOIL_TEMPLATE materials carry a real
    -- value and the clays and ceramics here need it back.
    if strength.absorption then
        material.strength.absorption = strength.absorption
    end
end


-- ==========================================
-- STRING POINTER HELPER
-- ==========================================
-- DF's vector<string*> fields (reaction_class, reaction_product.id)
-- require allocated string pointer objects, not raw Lua strings.
-- Direct insert/assignment with a Lua string fails with
-- "incompatible pointer type". This helper allocates a string
-- pointer via df.new('string'), sets its value, and returns it
-- ready for vector:insert().
-- ==========================================
function new_string_ptr(str)
    local s = df.new('string')
    s.value = str
    return s
end


-- ==========================================
-- APPLY REACTION CLASSES
-- ==========================================
-- Populates the material.reaction_class vector from the
-- definition's reaction_classes array. Clears existing entries
-- first (from the clone) to avoid inheriting unwanted classes.
-- ==========================================
function apply_reaction_classes(material, reaction_classes)
    -- nil = field omitted from schema, preserve clone's classes.
    -- Empty array = modder explicitly wants no reaction classes,
    -- clear the clone's inherited classes.
    if reaction_classes == nil then return end

    -- Clear clone's reaction classes
    material.reaction_class:resize(0)

    -- Insert new ones (if any - empty array just clears).
    -- Uses new_string_ptr() because reaction_class is a
    -- vector<string*> that requires pointer allocation.
    for _, rc in ipairs(reaction_classes) do
        material.reaction_class:insert('#', new_string_ptr(rc))
    end
end


-- ==========================================
-- APPLY REACTION PRODUCTS
-- ==========================================
-- Populates the material.reaction_product sub-structure.
-- Each entry maps a product ID (e.g. "FIRED_MAT") to an
-- inorganic material (e.g. "CERAMIC_STONEWARE").
--
-- The reaction_product structure has parallel arrays:
--   .id[]                 - Product ID strings
--   .item_type[]          - Always -1 for our purposes
--   .item_subtype[]       - Always -1
--   .material.mat_type[]  - Always 0 (INORGANIC)
--   .material.mat_index[] - Resolved inorganic index
-- ==========================================
-- warn: whether an unresolved target should be reported.
--
-- This runs twice. Pass 2 resolves references inside one module, where
-- a target in ANOTHER module genuinely does not exist yet; a miss there
-- means nothing and is picked up later. resolve_deferred_products runs
-- after every module has injected, and a miss THERE is a real failure.
--
-- Only the second pass gets to complain. Warning on both reported
-- healthy cross-module references as broken on every single boot.
local function apply_reaction_products(material, reaction_products, mat_lookup, warn)
    -- nil = field omitted from schema, preserve clone's products.
    -- Empty array = modder explicitly wants no reaction products,
    -- clear the clone's inherited products (e.g. iron's "make steel"
    -- and "make pig iron" entries shouldn't leak onto new alloys).
    if reaction_products == nil then return end

    local rp = material.reaction_product

    -- Clear clone's reaction products
    rp.id:resize(0)
    rp.item_type:resize(0)
    rp.item_subtype:resize(0)
    rp.material.mat_type:resize(0)
    rp.material.mat_index:resize(0)
    -- str is a fixed array of FIVE string vectors, str[0] to str[4],
    -- the token parts of the MATERIAL_REACTION_PRODUCT tag. The raws
    -- parser fills all five for every entry, so their lengths must
    -- track id. Layout verified against the live object map, not
    -- assumed. Guarded: a mismatch logs instead of aborting boot.
    for k = 0, 4 do
        local ok, err = pcall(function() rp.str[k]:resize(0) end)
        if not ok then
            log_inject('WARNING', 'reaction_product str['
                .. k .. '] clear failed: ' .. tostring(err), 'RXN_PRODUCT')
        end
    end

    -- Insert new ones (if any - empty array just clears).
    -- rp.id is a vector<string*> requiring pointer allocation;
    -- the numeric vectors accept raw values directly. str mirrors
    -- the parser: TYPE token, INDEX token, three trailing slots empty.
    for _, entry in ipairs(reaction_products) do
        local target_idx = mat_lookup[entry.mat_id]
        if target_idx then
            rp.id:insert('#', new_string_ptr(entry.id))
            rp.item_type:insert('#', -1)
            rp.item_subtype:insert('#', -1)
            rp.material.mat_type:insert('#', 0)  -- INORGANIC
            rp.material.mat_index:insert('#', target_idx)
            local tokens = { 'INORGANIC',
                df.global.world.raws.inorganics.all[target_idx].id, '', '', '' }
            for k = 0, 4 do
                local ok, err = pcall(function()
                    rp.str[k]:insert('#', new_string_ptr(tokens[k + 1]))
                end)
                if not ok then
                    log_inject('WARNING', 'reaction_product str['
                        .. k .. '] write failed for ' .. entry.id .. ': ' .. tostring(err), 'RXN_PRODUCT')
                end
            end
        elseif warn then
            -- Target material not found on the FINAL pass, so every
            -- module has already injected. This is a real dangling
            -- reference: a typo, or a module that failed to load.
            -- ERROR: anything that asks this material for the product
            -- gets nothing.
            log_inject('ERROR', string.format(
                "reaction_product '%s' -> '%s' not found. Skipping.",
                tostring(entry.id), tostring(entry.mat_id)
            ), 'RXN_PRODUCT')
        end
    end
end


-- ==========================================
-- APPLY GEM NAMES
-- ==========================================
-- Sets gem_name1 and gem_name2 for GEM class materials.
-- ==========================================
local function apply_gem_names(material, gem_names)
    if not gem_names then return end
    material.gem_name1 = gem_names[1]
    material.gem_name2 = gem_names[2]
end


-- ==========================================
-- PUBLIC: INJECT MODULE MATERIALS
-- ==========================================
-- Main entry point. Takes a list of validated material definitions
-- (from a parsed materials JSON) and injects each into the live
-- inorganic array.
--
-- Parameters:
--   materials - Array of material definition tables (post-validation)
--   prefix    - The module's ID prefix string
--   mod_name  - The module's display name (for logging)
--
-- Returns: count of materials successfully injected
-- ==========================================
function inject(materials, prefix, mod_name)
    local raws = df.global.world.raws.inorganics.all
    local count = 0

    -- Build inorganic lookup for reaction_product resolution.
    -- This runs after clone eval but before injection, so it
    -- includes vanilla + raws materials but not yet-to-be-injected
    -- module materials. Cross-module reaction_product references
    -- may fail on first run but succeed on subsequent cycles.
    local mat_lookup = {}
    local deferred_products = {}
    for i, mat in ipairs(raws) do
        mat_lookup[mat.id] = i
    end

    -- Sort materials by key for deterministic injection order.
    -- pairs() over a table gives non-deterministic hash order -
    -- sorting by key ensures stable positions across cycles.
    local sorted = {}
    for _, mat_def in ipairs(materials) do
        table.insert(sorted, mat_def)
    end
    table.sort(sorted, function(a, b) return a.key < b.key end)

    for _, def in ipairs(sorted) do
        local full_id = prefix .. def.key

        -- ---- STEP 1: GET CLONE DONOR ----
        local donor = clone_eval.get_donor(def.material_class)
        if not donor then
            -- ERROR: the material is missing from the game. The clone
            -- evaluator has already warned that the class has no donor.
            log_inject('ERROR', string.format(
                "No donor for class [%s], skipped [%s].",
                tostring(def.material_class), full_id
            ), tostring(mod_name))
            goto continue
        end

        -- ---- STEP 2: DEEP COPY ----
        local m = df.inorganic_raw:new()
        m:assign(donor)

        -- ---- STEP 2.5: NEUTRAL RESET ----
        -- The deep copy inherits ALL of the donor's semantic state.
        -- Reset every non-structural field to builtin neutral before
        -- the schema steps build up the new material's real identity.
        -- See reset_to_neutral() header for the full field audit.
        reset_to_neutral(m)

        -- ---- STEP 3: IDENTITY ----
        m.id = full_id
        m.material.id = full_id
        apply_display_name(m.material, def.name, def.names)

        -- ---- STEP 3b: ITEM TYPE NAME OVERRIDES ----
        -- DF lets a material rename the items made from it, but only
        -- for two item types, and each has its own field.
        --
        --   block_name   BLOCKS   {singular, plural}
        --                The material name prefixes it, so fire clay
        --                with {"brick","bricks"} reads "fire clay
        --                bricks", not "bricks".
        --
        --   stone_name   BOULDER  one string, already plural
        --                Replaces the name outright rather than
        --                suffixing it. Native gold uses "gold
        --                nuggets".
        --
        -- THERE IS NO EQUIVALENT FOR BARS. A bar always reads
        -- "<material> bars" unless the inorganic carries the WAFERS
        -- flag, which makes it "<material> wafers". Those are the
        -- only two words DF offers, so a bar cannot be freely named.
        --
        -- Both fields are blanked in the neutral reset above, so an
        -- omitted schema key means DF's default naming rather than a
        -- leak from whatever donor was cloned.
        if def.block_name then
            m.material.block_name[0] = def.block_name[1]
            m.material.block_name[1] = def.block_name[2]
        end

        if def.stone_name then
            m.material.stone_name = def.stone_name
        end

        -- ---- STEP 4: MATERIAL CLASS PRESET ----
        -- Clear cross-class flags, then set the target class flags
        apply_class_preset(m.material, def.material_class)

        -- ---- STEP 5: COLOR ----
        -- See apply_color: descriptor indices and ANSI triples are
        -- separate channels and must not be crossed.
        if def.color then
            local solid_idx  = resolve_color(def.color, def.fallback_colors)
            local liquid_idx = solid_idx
            local gas_idx    = solid_idx

            -- Vanilla templates give the molten/boiling states their own
            -- colour (METAL_TEMPLATE uses RED, SOIL_TEMPLATE uses ORANGE
            -- for magma). Only override when the schema asks for it.
            if def.liquid_color then liquid_idx = resolve_color(def.liquid_color) end
            if def.gas_color    then gas_idx    = resolve_color(def.gas_color)    end

            apply_color(m.material, {
                solid   = solid_idx,
                liquid  = liquid_idx,
                gas     = gas_idx,
                display = def.display_color,
                build   = def.build_color,
            })
        end

        -- ---- STEP 6: VALUE ----
        if def.value then
            m.material.material_value = def.value
        end
        -- ---- STEP 6b: TILE GLYPH ----
        -- Character code the material renders as. Vanilla iron is 219
        -- (a solid block); powders and soils typically use 34 ('"').
        -- Left untouched when the schema omits it, so the clone donor's
        -- glyph carries through as before.
        if def.tile then
            m.material.tile = def.tile
        end

        -- ---- STEP 7: DENSITY & MASS ----
        if def.solid_density  then m.material.solid_density  = def.solid_density end
        if def.liquid_density then m.material.liquid_density = def.liquid_density end
        if def.molar_mass     then m.material.molar_mass     = def.molar_mass end

        -- ---- STEP 8: HEAT ----
        apply_heat(m.material, def.heat)
        apply_graphics(m.material, def.graphics, def.key)

        -- ---- STEP 9: STRENGTH ----
        apply_strength(m.material, def.strength)

        -- ---- STEP 10: GEM NAMES ----
        apply_gem_names(m.material, def.gem_names)

        -- ---- STEP 11: REACTION CLASSES ----
        apply_reaction_classes(m.material, def.reaction_classes)

        -- ---- STEP 12: REACTION PRODUCTS (DEFERRED) ----
        -- Cannot run here. reaction_products reference other materials
        -- by ID, and mat_lookup only contains what has been injected so
        -- far - injection is alphabetical, so roughly half of this
        -- module's own materials don't exist yet. Applying now would
        -- silently drop every forward reference.
        --
        -- Collected and applied in pass 2 below, once every material in
        -- the batch is in the lookup.
        if def.reaction_products then
            table.insert(deferred_products, { material = m.material, def = def })

            -- Also queue globally. Pass 2 below resolves everything
            -- inside this module, but a reference to ANOTHER module's
            -- material cannot resolve until that module has injected,
            -- and the dependency can run either way: Glass and Ceramics
            -- needs ArgMOD's oxides, while ArgMOD's chlorides need its
            -- SALT_GLAZE. No ordering satisfies both, so those get a
            -- final pass once every module is in.
            _G.refinish_module_deferred_products = _G.refinish_module_deferred_products or {}
            table.insert(_G.refinish_module_deferred_products,
                         { material = m.material, def = def })
        end

        -- ---- STEP 13: FLAG OVERRIDES ----
        -- Applied last so they can override anything the preset set
        if def.material_flags then
            for flag_name, flag_val in pairs(def.material_flags) do
                m.material.flags[flag_name] = flag_val
            end
        end
        if def.inorganic_flags then
            for flag_name, flag_val in pairs(def.inorganic_flags) do
                m.flags[flag_name] = flag_val
            end
        end

        -- Soap is a flag plus a level. The SOAP flag (set through
        -- material_flags above) says the material cleans; soap_level
        -- says how well, and vanilla soap is 2 (SOAP_TEMPLATE:
        -- [SOAP][SOAP_LEVEL:2]). Hospitals read the level. Written
        -- only when the definition names it, so every existing
        -- material is untouched.
        if def.soap_level then
            m.material.soap_level = def.soap_level
        end

        -- ---- STEP 13b: DYE COLOUR ----
        -- After every flag is final: IS_DYE can come from the class
        -- preset or from a material_flags override above.
        apply_dye_color(m.material, def, full_id)

        -- ---- STEP 14: INJECT ----
        raws:insert(#raws, m)

        -- Update the lookup so later materials in this batch
        -- (and reaction_products that reference this material)
        -- can find it by ID
        mat_lookup[full_id] = #raws - 1

        count = count + 1

        ::continue::
    end

    -- ==========================================
    -- PASS 2: REACTION PRODUCTS (THIS MODULE)
    -- ==========================================
    -- Every material in this batch is now in mat_lookup, so references
    -- resolve regardless of alphabetical position. Targets in OTHER
    -- modules still miss here and are picked up by the global pass in
    -- resolve_deferred_products(), which the engine runs after every
    -- module has injected. Re-applying is safe: apply_reaction_products
    -- clears and rebuilds from the definition each time.
    for _, entry in ipairs(deferred_products) do
        apply_reaction_products(entry.material, entry.def.reaction_products, mat_lookup, false)
    end

    log_inject('DETAIL', string.format(
        "[%s] injected %d materials.", mod_name, count
    ), tostring(mod_name))

    -- ---- MATERIAL CACHE HANDSHAKE ----
    -- Every injection appends to inorganics.all, so any token to
    -- index answer cached before this call may now name a different
    -- material. Same contract the tool injector already has with the
    -- itemdef cache. The global is the handshake so nothing here has
    -- to know whether refinish-resolve is loaded.
    if count > 0 then
        _G.refinish_material_cache_dirty = true
    end

    return count
end

-- ==========================================
-- PUBLIC: RESOLVE DEFERRED REACTION PRODUCTS
-- ==========================================
-- Final pass, run by the engine once every module has injected its
-- materials. Rebuilds the lookup from the live array and re-applies
-- every queued reaction_product definition.
--
-- This is what makes cross-module references work in both directions.
-- Injection order is decided by depends_on, but reaction_products can
-- point the other way, and a genuine cycle between two modules has no
-- ordering that satisfies it. Resolving after the fact sidesteps the
-- question entirely.
--
-- Idempotent: apply_reaction_products clears and rebuilds from the
-- definition, so materials already resolved in pass 2 land identically.
--
-- Returns: count of definitions re-applied.
-- ==========================================
function resolve_deferred_products()
    local queued = _G.refinish_module_deferred_products
    if not queued or #queued == 0 then return 0 end

    local raws = df.global.world.raws.inorganics.all
    local mat_lookup = {}
    for i, mat in ipairs(raws) do
        mat_lookup[mat.id] = i
    end

    for _, entry in ipairs(queued) do
        apply_reaction_products(entry.material, entry.def.reaction_products, mat_lookup, true)
    end

    local count = #queued
    _G.refinish_module_deferred_products = nil
    return count
end


return _ENV