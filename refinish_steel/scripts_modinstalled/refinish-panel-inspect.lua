--@ module = true
-- refinish-panel-inspect.lua
-- ==========================================
-- MEMORY INSPECTOR: CURATED OBJECT SHEETS
-- ==========================================
-- Searches DF's live C++ arrays and returns formatted data sheets
-- for inorganics, reactions, entities, items, buildings,
-- constructions, and jobs. Each object type has a purpose-built
-- sheet that resolves references (mat_index -> material name,
-- color indices -> color names, etc.) and filters noise (only
-- active flags, only meaningful fields).
--
-- UI flow: Search -> Results List -> Detail Sheet
-- Navigation: Ctrl-I (search), Ctrl-B (back), Ctrl-G (gm-editor)
-- ==========================================

local gui = require('gui')
local widgets = require('gui.widgets')
local dialogs = require('gui.dialogs')
local utils = require('utils')

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
-- SUBJECT is the correlation slot: the view or object type a line is
-- about. Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'INSPECTOR'
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
-- TEXT WRAPPING
-- ==========================================
-- Breaks a long string into lines that fit within max_width
-- characters. Used by sheet builders for flag lists, raw
-- strings, and any other content that might exceed the
-- panel width.
-- ==========================================
local function wrap_text(text, max_width)
    if not text or text == "" then return {} end
    max_width = max_width or 72
    local lines = {}
    for word in text:gmatch("%S+") do
        if #lines == 0 then
            table.insert(lines, word)
        else
            local last = lines[#lines]
            if #last + 1 + #word <= max_width then
                lines[#lines] = last .. " " .. word
            else
                table.insert(lines, word)
            end
        end
    end
    return lines
end

-- ==========================================
-- LOAD ORDER ANALYZER
-- ==========================================
-- Parses a raw string vector (inorganic.str, reaction.raw_strings,
-- or entity_raw.raws) and detects overwritten tokens. DF applies
-- raw tokens sequentially - if MATERIAL_VALUE appears twice, the
-- second one overwrites the first, but both remain in the vector.
--
-- Returns two things:
--   token_history: a table keyed by token name, where each value
--                  is an array of {index, full_string} entries in
--                  the order they appeared.
--   overwrites:    an array of token names that appear more than
--                  once (i.e. were overwritten by a later entry).
--
-- Token name extraction: pulls the first field from inside brackets.
-- "[MATERIAL_VALUE:10]" -> "MATERIAL_VALUE"
-- "[ENVIRONMENT:SEDIMENTARY:CLUSTER:100]" -> "ENVIRONMENT"
-- "[IS_STONE]" -> "IS_STONE"
--
-- Tokens like ENVIRONMENT that are inherently multi-entry (you can
-- have multiple ENVIRONMENT lines without them being overwrites)
-- are tracked in a skip list so they don't produce false positives.
-- ==========================================

-- Tokens that legitimately appear multiple times without being overwrites.
-- These are additive/accumulative rather than last-write-wins.
-- REAGENT/PRODUCT/etc. are structural repeaters (one per input/output).
-- CONTAINS, PRESERVE_REAGENT, etc. are per-reagent modifiers.
-- ENVIRONMENT/METAL_ORE are accumulative world-gen entries.
-- Anything NOT in this list is treated as last-write-wins, meaning
-- a second appearance indicates a mod overwrite.
local MULTI_TOKENS = {
    -- Reaction structural repeaters
    REAGENT = true, PRODUCT = true, PRODUCT_DIMENSION = true,
    BUILDING = true, CONTAINS = true,
    PRESERVE_REAGENT = true, DOES_NOT_DETERMINE_PRODUCT_AMOUNT = true,
    IN_CONTAINER = true,
    -- Inorganic accumulative entries
    ENVIRONMENT = true, ENVIRONMENT_SPEC = true,
    METAL_ORE = true, THREAD_METAL = true,
    REACTION_CLASS = true, MATERIAL_REACTION_PRODUCT = true,
    STATE_NAME_ADJ = true, STATE_COLOR = true,
    -- Entity structural repeaters
    WEAPON = true, AMMO = true, ARMOR = true, HELM = true,
    GLOVES = true, SHOES = true, PANTS = true, SHIELD = true,
    PERMITTED_REACTION = true, PERMITTED_BUILDING = true,
    DIGGER = true, CREATURE = true, TRANSLATION = true,
    POSITION = true, RESPONSIBILITY = true, LAND_HOLDER_TRIGGER = true,
    SITE_VARIABLE_POSITIONS = true, VARIABLE_POSITIONS = true,
}

local function analyze_load_order(str_vector)
    local token_history = {}
    local overwrites = {}
    local overwrite_set = {}

    if not str_vector then return token_history, overwrites end

    for i = 0, #str_vector - 1 do
        local ok, raw_str = pcall(function()
            local entry = str_vector[i]
            -- Some str vectors hold string pointers, others hold plain strings
            return tostring(entry.value or entry)
        end)
        if ok and raw_str then
            -- Extract the token name: first field inside brackets
            local token_name = string.match(raw_str, "^%[([^:%]]+)")
            if token_name then
                if not token_history[token_name] then
                    token_history[token_name] = {}
                end
                table.insert(token_history[token_name], {index = i, text = raw_str})

                -- Flag as overwrite if this token appeared before and
                -- it's not a legitimately multi-entry token
                if #token_history[token_name] > 1 and not MULTI_TOKENS[token_name] then
                    if not overwrite_set[token_name] then
                        overwrite_set[token_name] = true
                        table.insert(overwrites, token_name)
                    end
                end
            end
        end
    end

    return token_history, overwrites
end

-- ==========================================
-- SHARED RESOLVERS
-- ==========================================
-- These small helpers turn raw numeric indices into readable
-- names. They're used across multiple sheet builders so they
-- live here at the top as shared utilities.
-- ==========================================

-- Resolve an inorganic mat_index to a human-readable name.
-- Returns the solid state name if available, otherwise the raw ID.
-- Returns "N/A" for out-of-range or nil indices.
local function resolve_inorganic(mat_index)
    if not mat_index or mat_index < 0 then return "N/A" end
    local inorganics = df.global.world.raws.inorganics.all
    if mat_index >= #inorganics then return "IDX:" .. tostring(mat_index) end
    local mat = inorganics[mat_index]
    local name = mat.material.state_name[0]
    if name and name ~= "" then return name .. " [" .. mat.id .. "]" end
    return mat.id
end

-- Resolve a mat_type + mat_index pair into a readable material string.
-- mat_type 0 = INORGANIC (uses the inorganics array directly).
-- Other mat_types use dfhack.matinfo.decode for organic/creature materials.
-- Falls back to raw numeric display if resolution fails.
local function resolve_material(mat_type, mat_index)
    if mat_type == 0 and mat_index >= 0 then
        return resolve_inorganic(mat_index)
    elseif mat_type == -1 and mat_index == -1 then
        return "INHERIT FROM REAGENT"
    else
        local ok, minfo = pcall(dfhack.matinfo.decode, mat_type, mat_index)
        if ok and minfo then return tostring(minfo) end
        return string.format("Type:%d Idx:%d", mat_type, mat_index)
    end
end

-- Resolve item_type enum integer to its string name.
-- df.item_type is the DFHack enum table for item types.
local function resolve_item_type(itype)
    local name = df.item_type[itype]
    return name or ("UNKNOWN(" .. tostring(itype) .. ")")
end

-- Resolve a building type/subtype/custom triplet to a name.
-- custom >= 0 means a modded building (lookup via df.building_def.find).
-- Otherwise it's a vanilla building (type + subtype enum).
local function resolve_building(btype, bsubtype, bcustom)
    if bcustom and bcustom >= 0 then
        local bdef = df.building_def.find(bcustom)
        return bdef and bdef.code or ("Custom #" .. tostring(bcustom))
    end
    local type_name = df.building_type[btype] or tostring(btype)
    if bsubtype and bsubtype >= 0 then
        return type_name .. " (sub:" .. tostring(bsubtype) .. ")"
    end
    return type_name
end

-- Resolve a job_skill integer to its string name.
local function resolve_skill(skill_id)
    if skill_id == -1 then return "NONE" end
    local name = df.job_skill[skill_id]
    return name or tostring(skill_id)
end

-- Resolve a descriptor color index to a color name.
-- state_color values point into the patterns array, not colors directly.
-- The pattern's first color entry is the actual color index.
local function resolve_color_name(state_color_idx)
    if not state_color_idx or state_color_idx < 0 then return "Unknown" end
    local ok, name = pcall(function()
        local pattern = df.global.world.raws.descriptors.patterns[state_color_idx]
        if pattern and pattern.colors and #pattern.colors > 0 then
            local true_c_idx = pattern.colors[0]
            if true_c_idx >= 0 and true_c_idx < #df.global.world.raws.descriptors.colors then
                local color_obj = df.global.world.raws.descriptors.colors[true_c_idx]
                if color_obj and color_obj.name ~= "" then return color_obj.name end
            end
        end
        return "Pattern #" .. tostring(state_color_idx)
    end)
    return ok and name or "Unknown"
end

-- Collect only the flags that are set to true from a bitfield.
-- Returns a sorted array of flag name strings.
-- Skips numeric-indexed flags (unnamed/reserved bits).
local function collect_active_flags(flags_obj)
    local active = {}
    if not flags_obj then return active end
    local ok = pcall(function()
        for k, v in pairs(flags_obj) do
            if v == true and type(k) == 'string' then
                table.insert(active, k)
            end
        end
    end)
    table.sort(active)
    return active
end

-- Check whether an ID belongs to Refinish Metal's injected assets.
-- Uses the fast prefix check (no pattern engine overhead).
local RM_PREFIX = "REFINISH_STEEL_"
local RM_PREFIX_LEN = #RM_PREFIX

local function is_rm_asset(id)
    return id and string.sub(id, 1, RM_PREFIX_LEN) == RM_PREFIX
end

-- Format a load order position string showing where this object
-- sits in the global array relative to vanilla content.
local function format_load_position(index, array_name)
    local base_count = 0
    if _G.refinish_telemetry and _G.refinish_telemetry.counts then
        if array_name == "inorganics" then
            base_count = _G.refinish_telemetry.counts.base_inorganics or 0
        elseif array_name == "reactions" then
            base_count = _G.refinish_telemetry.counts.base_reactions or 0
        end
    end
    if base_count > 0 and index >= base_count then
        return string.format("#%d (injected; vanilla ends at #%d)", index, base_count - 1)
    end
    return string.format("#%d", index)
end


-- ==========================================
-- SHEET BUILDERS
-- ==========================================
-- Each builder takes a DF object and returns an array of
-- entries. Plain strings render in SEC (body text). Tagged
-- tables like {text = "...", pen = "PRI"} get their pen
-- resolved in open_sheet(). This keeps theme logic out of
-- the builders entirely.
--
-- LINE HELPERS: These wrap common patterns so the builders
-- stay readable. hdr() for section headers, tag() for
-- arbitrary pen-tagged lines.
-- ==========================================

-- Section header line (renders in NEUTRAL_B)
local function hdr(text)
    return {text = text, pen = "NEUTRAL_B"}
end

-- Pen-tagged line (any theme pen name)
local function tag(pen_name, text)
    return {text = text, pen = pen_name}
end

-- ==========================================
-- INORGANIC MATERIAL SHEET
-- ==========================================
-- Shows identity, physical properties, combat stats, thermal
-- data, color/display info, ore targets, reaction classes,
-- reaction products, environment data, and active flags.
-- ==========================================
local function build_material_sheet(mat, mat_index)
    local lines = {}
    local m = mat.material

    -- IDENTITY
    table.insert(lines, hdr("=== IDENTITY ==="))
    table.insert(lines, " ID: " .. tostring(mat.id))
    table.insert(lines, " Name: " .. (m.state_name[0] or "N/A"))
    table.insert(lines, " Adjective: " .. (m.state_adj[0] or "N/A"))
    table.insert(lines, " Load Position: " .. format_load_position(mat_index, "inorganics"))
    if is_rm_asset(mat.id) then
        table.insert(lines, tag("TER", " Origin: REFINISH METAL (runtime-injected)"))
    end
    table.insert(lines, "")

    -- CORE PROPERTIES
    table.insert(lines, hdr("=== CORE PROPERTIES ==="))
    table.insert(lines, string.format(" Value: %d  |  Solid Density: %d  |  Liquid Density: %d",
        m.material_value, m.solid_density, m.liquid_density))
    table.insert(lines, string.format(" Molar Mass: %d  |  Max Edge: %d",
        m.molar_mass, m.strength.max_edge))
    table.insert(lines, "")

    -- THERMAL
    table.insert(lines, hdr("=== THERMAL ==="))
    table.insert(lines, string.format(" Spec Heat: %d  |  Melt: %d  |  Boil: %d",
        m.heat.spec_heat, m.heat.melting_point, m.heat.boiling_point))
    table.insert(lines, string.format(" Ignite: %d  |  Heat Dam: %d  |  Cold Dam: %d  |  Fixed: %d",
        m.heat.ignite_point, m.heat.heatdam_point, m.heat.colddam_point, m.heat.mat_fixed_temp))
    table.insert(lines, "")

    -- COMBAT STATS (compact table format)
    table.insert(lines, hdr("=== COMBAT STATS (Yield / Fracture / Strain) ==="))
    local str = m.strength
    local function stat_line(label, field)
        return string.format(" %-10s %7d / %7d / %d", label,
            str.yield[field], str.fracture[field], str.strain_at_yield[field])
    end
    table.insert(lines, stat_line("Impact", "IMPACT"))
    table.insert(lines, stat_line("Compress", "COMPRESSIVE"))
    table.insert(lines, stat_line("Tensile", "TENSILE"))
    table.insert(lines, stat_line("Torsion", "TORSION"))
    table.insert(lines, stat_line("Shear", "SHEAR"))
    table.insert(lines, stat_line("Bending", "BENDING"))
    table.insert(lines, "")

    -- STATES & COLORS
    table.insert(lines, hdr("=== STATES & DISPLAY ==="))
    local state_names = {"Solid", "Liquid", "Gas", "Powder", "Paste", "Pressed"}
    for i, sname in ipairs(state_names) do
        local idx = i - 1
        local name_val = m.state_name[idx] or ""
        local color_val = resolve_color_name(m.state_color[idx])
        if name_val ~= "" then
            table.insert(lines, string.format(" %-8s  %-20s  Color: %s", sname, name_val, color_val))
        end
    end
    table.insert(lines, string.format(" Build Color: fg=%d bg=%d bright=%d",
        m.build_color[0], m.build_color[1], m.build_color[2]))
    table.insert(lines, "")

    -- ORE TARGETS (which metals can be smelted from this material)
    if mat.metal_ore and mat.metal_ore.mat_index and #mat.metal_ore.mat_index > 0 then
        table.insert(lines, hdr("=== ORE TARGETS ==="))
        for i = 0, #mat.metal_ore.mat_index - 1 do
            local target_idx = mat.metal_ore.mat_index[i]
            local prob = mat.metal_ore.probability[i]
            table.insert(lines, string.format(" %s (%d%%)", resolve_inorganic(target_idx), prob))
        end
        table.insert(lines, "")
    end

    -- THREAD METAL TARGETS (e.g. RAW_ADAMANTINE -> ADAMANTINE)
    if mat.thread_metal and mat.thread_metal.mat_index and #mat.thread_metal.mat_index > 0 then
        table.insert(lines, hdr("=== THREAD METAL TARGETS ==="))
        for i = 0, #mat.thread_metal.mat_index - 1 do
            local target_idx = mat.thread_metal.mat_index[i]
            local prob = mat.thread_metal.probability[i]
            table.insert(lines, string.format(" %s (%d%%)", resolve_inorganic(target_idx), prob))
        end
        table.insert(lines, "")
    end

    -- REACTION CLASSES
    if m.reaction_class and #m.reaction_class > 0 then
        table.insert(lines, hdr("=== REACTION CLASSES ==="))
        for i = 0, #m.reaction_class - 1 do
            pcall(function()
                local cls = m.reaction_class[i]
                if cls then table.insert(lines, " " .. tostring(cls.value or cls)) end
            end)
        end
        table.insert(lines, "")
    end

    -- REACTION PRODUCTS (material_reaction_product entries)
    if m.reaction_product and m.reaction_product.id and #m.reaction_product.id > 0 then
        table.insert(lines, hdr("=== REACTION PRODUCTS ==="))
        for i = 0, #m.reaction_product.id - 1 do
            pcall(function()
                local prod_id = m.reaction_product.id[i]
                local prod_mat_type = m.reaction_product.material.mat_type[i]
                local prod_mat_idx = m.reaction_product.material.mat_index[i]
                table.insert(lines, string.format(" %s -> %s",
                    tostring(prod_id.value or prod_id),
                    resolve_material(prod_mat_type, prod_mat_idx)))
            end)
        end
        table.insert(lines, "")
    end

    -- ENVIRONMENT (where this material generates in the world)
    if mat.environment and mat.environment.location and #mat.environment.location > 0 then
        table.insert(lines, hdr("=== ENVIRONMENT ==="))
        for i = 0, #mat.environment.location - 1 do
            pcall(function()
                local loc = tostring(df.environment_type[mat.environment.location[i]] or mat.environment.location[i])
                local inc = tostring(df.inclusion_type[mat.environment.type[i]] or mat.environment.type[i])
                local prob = mat.environment.probability[i]
                table.insert(lines, string.format(" %s as %s (%d%%)", loc, inc, prob))
            end)
        end
        table.insert(lines, "")
    end

    -- ACTIVE FLAGS (only flags that are true, word-wrapped)
    table.insert(lines, hdr("=== ACTIVE FLAGS ==="))
    local mat_flags = collect_active_flags(m.flags)
    local inorg_flags = collect_active_flags(mat.flags)
    if #mat_flags > 0 then
        local wrapped = wrap_text("Material: " .. table.concat(mat_flags, ", "), 72)
        for _, wl in ipairs(wrapped) do table.insert(lines, " " .. wl) end
    end
    if #inorg_flags > 0 then
        local wrapped = wrap_text("Inorganic: " .. table.concat(inorg_flags, ", "), 72)
        for _, wl in ipairs(wrapped) do table.insert(lines, " " .. wl) end
    end
    if #mat_flags == 0 and #inorg_flags == 0 then
        table.insert(lines, " (none)")
    end
    table.insert(lines, "")

    -- LOAD ORDER ANALYSIS
    -- Parses the raw string tape (mat.str) to detect tokens that
    -- were overwritten by mods loading after the base definition.
    -- Only shown if overwrites are detected - clean objects skip this.
    if mat.str and #mat.str > 0 then
        local history, overwrites = analyze_load_order(mat.str)
        if #overwrites > 0 then
            table.insert(lines, hdr("=== LOAD ORDER (Overwrites Detected) ==="))
            for _, token_name in ipairs(overwrites) do
                local entries = history[token_name]
                for j, entry in ipairs(entries) do
                    -- Last entry is the active (winning) value
                    local marker = (j == #entries) and "ACTIVE" or "SHADOWED"
                    local line = string.format(" [%s] #%d %s", marker, entry.index, entry.text)
                    if marker == "SHADOWED" then
                        table.insert(lines, tag("RISK_M", line))
                    else
                        table.insert(lines, tag("PRI", line))
                    end
                end
            end
            table.insert(lines, "")
        end

        -- RAW TOKEN TAPE (full sequential listing)
        table.insert(lines, hdr("=== RAW DEFINITION (" .. #mat.str .. " tokens) ==="))
        for i = 0, #mat.str - 1 do
            pcall(function()
                local s = mat.str[i]
                table.insert(lines, string.format(" [%d] %s", i, tostring(s.value or s)))
            end)
        end
    end

    return lines
end


-- ==========================================
-- REACTION SHEET
-- ==========================================
-- Shows identity, workshop permissions, reagent/product
-- breakdown with resolved materials, skill, flags, raw
-- strings, and RM origin detection.
-- ==========================================
local function build_reaction_sheet(rxn, rxn_index)
    local lines = {}

    -- IDENTITY
    table.insert(lines, hdr("=== IDENTITY ==="))
    table.insert(lines, " Code: " .. tostring(rxn.code))
    table.insert(lines, " Name: " .. (rxn.name or "N/A"))
    table.insert(lines, " Skill: " .. resolve_skill(rxn.skill))
    table.insert(lines, " Category: " .. (rxn.category ~= "" and rxn.category or "(none)"))
    table.insert(lines, " Index: " .. format_load_position(rxn.index, "reactions"))
    if is_rm_asset(rxn.code) then
        table.insert(lines, tag("TER", " Origin: REFINISH METAL (runtime-injected)"))
    end
    table.insert(lines, "")

    -- REACTION FLAGS
    local rxn_flags = collect_active_flags(rxn.flags)
    if #rxn_flags > 0 then
        table.insert(lines, hdr("=== REACTION FLAGS ==="))
        table.insert(lines, " " .. table.concat(rxn_flags, ", "))
        table.insert(lines, "")
    end

    -- WORKSHOP PERMISSIONS
    table.insert(lines, hdr("=== WORKSHOP PERMISSIONS ==="))
    if not rxn.building or #rxn.building.type == 0 then
        table.insert(lines, " (no explicit workshop requirement)")
    else
        for i = 0, #rxn.building.type - 1 do
            local btype = rxn.building.type[i]
            local bsub = rxn.building.subtype[i]
            local bcust = rxn.building.custom[i]
            table.insert(lines, " " .. resolve_building(btype, bsub, bcust))
        end
    end
    table.insert(lines, "")

    -- REAGENTS
    table.insert(lines, hdr("=== REAGENTS ==="))
    if not rxn.reagents or #rxn.reagents == 0 then
        table.insert(lines, " (none)")
    else
        for i, reag in ipairs(rxn.reagents) do
            local item_name = resolve_item_type(reag.item_type)
            local mat_name = resolve_material(reag.mat_type, reag.mat_index)
            local preserve = ""
            pcall(function()
                if reag.flags.PRESERVE_REAGENT then preserve = " [PRESERVED]" end
            end)
            table.insert(lines, string.format(" [%s] %dx %s  (%s)%s",
                reag.code or "?", reag.quantity, item_name, mat_name, preserve))
            -- Show reaction_class if set (e.g. FLUX)
            if reag.reaction_class and reag.reaction_class ~= "" then
                table.insert(lines, "         Reaction Class: " .. reag.reaction_class)
            end
            -- Show has_material_reaction_product if set
            if reag.has_material_reaction_product and reag.has_material_reaction_product ~= "" then
                table.insert(lines, "         Material Product: " .. reag.has_material_reaction_product)
            end
        end
    end
    table.insert(lines, "")

    -- PRODUCTS
    table.insert(lines, hdr("=== PRODUCTS ==="))
    if not rxn.products or #rxn.products == 0 then
        table.insert(lines, " (none)")
    else
        for i, prod in ipairs(rxn.products) do
            local item_name = resolve_item_type(prod.item_type)
            local mat_name = resolve_material(prod.mat_type, prod.mat_index)
            local dim_str = ""
            if prod.product_dimension and prod.product_dimension > 0 then
                dim_str = string.format("  Dimension: %d", prod.product_dimension)
            end
            -- Check for GET_MATERIAL_SAME or GET_MATERIAL_PRODUCT flags
            local inherit = ""
            pcall(function()
                if prod.flags.GET_MATERIAL_SAME then
                    inherit = " [INHERITS: " .. (prod.get_material.reagent_code or "?") .. "]"
                elseif prod.flags.GET_MATERIAL_PRODUCT then
                    inherit = " [PRODUCT_OF: " .. (prod.get_material.product_code or "?") .. "]"
                end
            end)
            table.insert(lines, string.format(" %dx %s  (%s)  Prob: %d%%%s%s",
                prod.count or 1, item_name, mat_name, prod.probability, dim_str, inherit))
        end
    end
    table.insert(lines, "")

    -- TUNING (skill multipliers, exp, etc.)
    table.insert(lines, hdr("=== TUNING ==="))
    table.insert(lines, string.format(" Max Multiplier: %d  |  Skill Mult: %d  |  Attr Gain: %d  |  Exp Gain: %d",
        rxn.max_multiplier or -1, rxn.skill_mult or 0, rxn.attr_gain or 0, rxn.exp_gain or 0))
    table.insert(lines, "")

    -- LOAD ORDER ANALYSIS + RAW DEFINITION
    if rxn.raw_strings and #rxn.raw_strings > 0 then
        local history, overwrites = analyze_load_order(rxn.raw_strings)
        if #overwrites > 0 then
            table.insert(lines, hdr("=== LOAD ORDER (Overwrites Detected) ==="))
            for _, token_name in ipairs(overwrites) do
                local entries = history[token_name]
                for j, entry in ipairs(entries) do
                    local marker = (j == #entries) and "ACTIVE" or "SHADOWED"
                    local line = string.format(" [%s] #%d %s", marker, entry.index, entry.text)
                    if marker == "SHADOWED" then
                        table.insert(lines, tag("RISK_M", line))
                    else
                        table.insert(lines, tag("PRI", line))
                    end
                end
            end
            table.insert(lines, "")
        end

        table.insert(lines, hdr("=== RAW DEFINITION (" .. #rxn.raw_strings .. " tokens) ==="))
        for i = 0, #rxn.raw_strings - 1 do
            pcall(function()
                local s = rxn.raw_strings[i]
                table.insert(lines, string.format(" [%d] %s", i, tostring(s.value or s)))
            end)
        end
    end

    return lines
end


-- ==========================================
-- ENTITY SHEET
-- ==========================================
-- Shows civ identity, permitted reaction count, RM injection
-- count, and the RM-specific reaction codes if present.
-- ==========================================
local function build_entity_sheet(ent)
    local lines = {}
    local raw = ent.entity_raw

    table.insert(lines, hdr("=== ENTITY / CIVILIZATION ==="))
    table.insert(lines, " Runtime ID: " .. tostring(ent.id))
    table.insert(lines, " RAW Code: " .. (raw and tostring(raw.code) or "UNKNOWN"))

    -- Resolve the creature type for this entity
    if ent.race and ent.race >= 0 and ent.race < #df.global.world.raws.creatures.all then
        local c_raw = df.global.world.raws.creatures.all[ent.race]
        if c_raw and c_raw.name then
            table.insert(lines, " Race: " .. (c_raw.name[0] or "Unknown"))
        end
    end
    table.insert(lines, "")

    -- WORKSHOP PERMISSIONS
    if raw and raw.workshops and raw.workshops.permitted_reaction_id then
        local perm_list = raw.workshops.permitted_reaction_id
        local reactions = df.global.world.raws.reactions.reactions
        local total = #perm_list
        local rm_count = 0
        local rm_codes = {}

        for _, pid in ipairs(perm_list) do
            if pid >= 0 and pid < #reactions then
                local code = reactions[pid].code
                if is_rm_asset(code) then
                    rm_count = rm_count + 1
                    -- Only collect first few for display
                    if #rm_codes < 10 then
                        table.insert(rm_codes, code)
                    end
                end
            end
        end

        table.insert(lines, hdr("=== WORKSHOP PERMISSIONS ==="))
        table.insert(lines, string.format(" Total Permitted: %d  |  Refinish Metal: %d", total, rm_count))

        if #rm_codes > 0 then
            table.insert(lines, "")
            table.insert(lines, " RM Reactions (first " .. #rm_codes .. "):")
            for _, code in ipairs(rm_codes) do
                table.insert(lines, "   " .. code)
            end
            if rm_count > #rm_codes then
                table.insert(lines, "   ... and " .. (rm_count - #rm_codes) .. " more")
            end
        end
    else
        table.insert(lines, hdr("=== WORKSHOP PERMISSIONS ==="))
        table.insert(lines, " (no permitted reactions)")
    end
    table.insert(lines, "")

    -- LOAD ORDER ANALYSIS (entity_raw.raws vector)
    -- Entity raws can also show mod overwrites - permissions added,
    -- creatures changed, etc. Only shown if overwrites detected.
    if raw and raw.raws and #raw.raws > 0 then
        local history, overwrites = analyze_load_order(raw.raws)
        if #overwrites > 0 then
            table.insert(lines, hdr("=== LOAD ORDER (Overwrites Detected) ==="))
            for _, token_name in ipairs(overwrites) do
                local entries = history[token_name]
                for j, entry in ipairs(entries) do
                    local marker = (j == #entries) and "ACTIVE" or "SHADOWED"
                    local line = string.format(" [%s] #%d %s", marker, entry.index, entry.text)
                    if marker == "SHADOWED" then
                        table.insert(lines, tag("RISK_M", line))
                    else
                        table.insert(lines, tag("PRI", line))
                    end
                end
            end
        end
    end

    return lines
end


-- ==========================================
-- ITEM SHEET
-- ==========================================
-- Shows item identity, material composition with resolved
-- names, RM detection, wear level, and active flags.
-- ==========================================
local function build_item_sheet(item)
    local lines = {}

    table.insert(lines, hdr("=== ITEM ==="))
    table.insert(lines, " ID: " .. tostring(item.id))

    local desc = "UNKNOWN"
    pcall(function() desc = dfhack.items.getDescription(item, 0) end)
    table.insert(lines, " Description: " .. desc)

    local itype = item:getType()
    table.insert(lines, " Type: " .. resolve_item_type(itype))
    table.insert(lines, "")

    -- MATERIAL
    table.insert(lines, hdr("=== MATERIAL ==="))
    local mat_str = resolve_material(item.mat_type, item.mat_index)
    table.insert(lines, " Material: " .. mat_str)
    table.insert(lines, string.format(" Raw Values: mat_type=%d  mat_index=%d", item.mat_type, item.mat_index))
    if item.mat_type == 0 and item.mat_index >= 0 then
        local inorganics = df.global.world.raws.inorganics.all
        if item.mat_index < #inorganics then
            local inorg = inorganics[item.mat_index]
            if is_rm_asset(inorg.id) then
                table.insert(lines, tag("TER", " Origin: REFINISH METAL (runtime-injected material)"))
            end
            table.insert(lines, " Inorganic Index: " .. format_load_position(item.mat_index, "inorganics"))
        end
    end
    table.insert(lines, "")

    -- CONDITION
    table.insert(lines, hdr("=== CONDITION ==="))
    local wear = 0
    pcall(function() wear = item.wear end)
    local wear_labels = {[0] = "Pristine", [1] = "Worn", [2] = "Damaged", [3] = "Tattered"}
    table.insert(lines, " Wear: " .. (wear_labels[wear] or tostring(wear)))
    table.insert(lines, "")

    -- ACTIVE FLAGS
    table.insert(lines, hdr("=== ACTIVE FLAGS ==="))
    local flags = collect_active_flags(item.flags)
    if #flags > 0 then
        local wrapped = wrap_text(table.concat(flags, ", "), 72)
        for _, wl in ipairs(wrapped) do table.insert(lines, " " .. wl) end
    else
        table.insert(lines, " (none)")
    end

    return lines
end


-- ==========================================
-- BUILDING SHEET
-- ==========================================
local function build_building_sheet(bld)
    local lines = {}

    table.insert(lines, hdr("=== BUILDING ==="))
    table.insert(lines, " ID: " .. tostring(bld.id))
    local btype = bld:getType()
    table.insert(lines, " Type: " .. (df.building_type[btype] or tostring(btype)))
    table.insert(lines, string.format(" Position: %d, %d, %d", bld.centerx, bld.centery, bld.z))
    table.insert(lines, "")

    table.insert(lines, hdr("=== MATERIAL ==="))
    table.insert(lines, " " .. resolve_material(bld.mat_type, bld.mat_index))
    table.insert(lines, string.format(" Raw Values: mat_type=%d  mat_index=%d", bld.mat_type, bld.mat_index))

    return lines
end


-- ==========================================
-- CONSTRUCTION SHEET
-- ==========================================
local function build_construction_sheet(c)
    local lines = {}

    table.insert(lines, hdr("=== CONSTRUCTION ==="))
    table.insert(lines, string.format(" Position: %d, %d, %d", c.pos.x, c.pos.y, c.pos.z))
    table.insert(lines, " Item Type Used: " .. resolve_item_type(c.item_type))
    table.insert(lines, "")

    table.insert(lines, hdr("=== MATERIAL ==="))
    table.insert(lines, " " .. resolve_material(c.mat_type, c.mat_index))
    table.insert(lines, string.format(" Raw Values: mat_type=%d  mat_index=%d", c.mat_type, c.mat_index))

    return lines
end


-- ==========================================
-- JOB SHEET
-- ==========================================
-- Shows live job data with resolved reaction name, RM
-- detection, and item references.
-- ==========================================
local function build_job_sheet(job)
    local lines = {}

    table.insert(lines, hdr("=== ACTIVE JOB ==="))
    table.insert(lines, " ID: " .. tostring(job.id))

    local type_str = df.job_type[job.job_type] or tostring(job.job_type)
    table.insert(lines, " Type: " .. type_str)
    table.insert(lines, " Reaction: " .. tostring(job.reaction_name or "N/A"))
    table.insert(lines, string.format(" Position: %d, %d, %d", job.pos.x, job.pos.y, job.pos.z))

    if job.reaction_name and is_rm_asset(tostring(job.reaction_name)) then
        table.insert(lines, tag("TER", " Origin: REFINISH METAL reaction"))
    end
    table.insert(lines, "")

    -- JOB ITEMS (what the dwarf has picked up or is looking for)
    if job.items and #job.items > 0 then
        table.insert(lines, hdr("=== JOB ITEMS ==="))
        for i, ji in ipairs(job.items) do
            if ji.item then
                local item = ji.item
                local desc = "?"
                pcall(function() desc = dfhack.items.getDescription(item, 0) end)
                table.insert(lines, string.format(" [%d] %s", i, desc))
            end
        end
    end

    return lines
end


-- ==========================================
-- SEARCH ENGINE
-- ==========================================
-- Scans the six primary DF arrays for objects matching the
-- query string. Returns a list of result entries, each with
-- a display text, the raw object, its type tag, and a
-- gm-editor path for the deep-dive link.
--
-- Search caps: items, buildings, constructions, and jobs are
-- capped at 50 results each to prevent UI lag on large forts.
-- Materials and reactions are uncapped (they're smaller arrays).
-- ==========================================
local function execute_search(query)
    query = string.lower(query)
    local results = {}

    -- INORGANICS (uncapped)
    pcall(function()
        for i, mat in ipairs(df.global.world.raws.inorganics.all) do
            local id_lower = string.lower(mat.id or "")
            local name_lower = string.lower(mat.material.state_name[0] or "")
            if string.find(id_lower, query, 1, true) or string.find(name_lower, query, 1, true) then
                local tag = is_rm_asset(mat.id) and "MAT*" or "MAT"
                table.insert(results, {
                    text = string.format("[%s] %s (%s)", tag, mat.id, mat.material.state_name[0] or "N/A"),
                    data = {obj = mat, type = "INORGANIC", idx = i,
                            path = 'df.global.world.raws.inorganics.all[' .. i .. ']'}
                })
            end
        end
    end)

    -- REACTIONS (uncapped)
    pcall(function()
        for i, rxn in ipairs(df.global.world.raws.reactions.reactions) do
            local code_lower = string.lower(rxn.code or "")
            local name_lower = string.lower(rxn.name or "")
            if string.find(code_lower, query, 1, true) or string.find(name_lower, query, 1, true) then
                local tag = is_rm_asset(rxn.code) and "RXN*" or "RXN"
                table.insert(results, {
                    text = string.format("[%s] %s (%s)", tag, rxn.code, rxn.name or "N/A"),
                    data = {obj = rxn, type = "REACTION", idx = i,
                            path = 'df.global.world.raws.reactions.reactions[' .. i .. ']'}
                })
            end
        end
    end)

    -- ENTITIES (uncapped, small array)
    pcall(function()
        for i, ent in ipairs(df.global.world.entities.all) do
            local id_str = tostring(ent.id)
            local raw_code = ent.entity_raw and string.lower(ent.entity_raw.code or "") or ""
            if string.find(id_str, query, 1, true) or string.find(raw_code, query, 1, true) then
                table.insert(results, {
                    text = string.format("[ENT] ID:%d (%s)", ent.id, ent.entity_raw and ent.entity_raw.code or "?"),
                    data = {obj = ent, type = "ENTITY",
                            path = 'df.historical_entity.find(' .. ent.id .. ')'}
                })
            end
        end
    end)

    -- ITEMS (capped at 50)
    pcall(function()
        local count = 0
        for i, item in ipairs(df.global.world.items.all) do
            local id_str = tostring(item.id)
            local i_type = ""
            pcall(function() i_type = string.lower(tostring(df.item_type[item:getType()] or "")) end)
            if string.find(id_str, query, 1, true) or string.find(i_type, query, 1, true) then
                table.insert(results, {
                    text = string.format("[ITM] ID:%d (%s)", item.id, string.upper(i_type)),
                    data = {obj = item, type = "ITEM",
                            path = 'df.item.find(' .. item.id .. ')'}
                })
                count = count + 1
                if count >= 50 then break end
            end
        end
    end)

    -- BUILDINGS (capped at 50)
    pcall(function()
        local count = 0
        for i, bld in ipairs(df.global.world.buildings.all) do
            local id_str = tostring(bld.id)
            local b_type = ""
            pcall(function() b_type = string.lower(tostring(df.building_type[bld:getType()] or "")) end)
            if string.find(id_str, query, 1, true) or string.find(b_type, query, 1, true) then
                table.insert(results, {
                    text = string.format("[BLD] ID:%d (%s)", bld.id, string.upper(b_type)),
                    data = {obj = bld, type = "BUILDING",
                            path = 'df.building.find(' .. bld.id .. ')'}
                })
                count = count + 1
                if count >= 50 then break end
            end
        end
    end)

    -- CONSTRUCTIONS (capped at 50)
    pcall(function()
        local count = 0
        for i, c in ipairs(df.global.world.constructions) do
            local pos_str = c.pos.x .. "," .. c.pos.y .. "," .. c.pos.z
            if string.find(pos_str, query, 1, true) then
                table.insert(results, {
                    text = string.format("[CON] %d,%d,%d", c.pos.x, c.pos.y, c.pos.z),
                    data = {obj = c, type = "CONSTRUCTION",
                            path = 'df.global.world.constructions[' .. i .. ']'}
                })
                count = count + 1
                if count >= 50 then break end
            end
        end
    end)

    -- JOBS (capped at 50)
    pcall(function()
        local count = 0
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            local id_str = tostring(job.id)
            local r_name = string.lower(tostring(job.reaction_name or ""))
            local j_type = ""
            pcall(function() j_type = string.lower(tostring(df.job_type[job.job_type] or "")) end)
            if string.find(id_str, query, 1, true) or string.find(r_name, query, 1, true) or string.find(j_type, query, 1, true) then
                local display_name = job.reaction_name and tostring(job.reaction_name) or string.upper(j_type)
                local tag = (job.reaction_name and is_rm_asset(tostring(job.reaction_name))) and "JOB*" or "JOB"
                table.insert(results, {
                    text = string.format("[%s] ID:%d (%s)", tag, job.id, display_name),
                    data = {obj = job, type = "JOB",
                            path = 'df.job.find(' .. job.id .. ')'}
                })
                count = count + 1
                if count >= 50 then break end
            end
        end
    end)

    return results
end


-- ==========================================
-- SHEET DISPATCHER
-- ==========================================
-- Routes an object to its type-specific sheet builder.
-- Returns an array of display strings, or an error message
-- if the sheet builder fails.
-- ==========================================
local function build_sheet(obj, obj_type, obj_index)
    local ok, result = pcall(function()
        if obj_type == "INORGANIC"    then return build_material_sheet(obj, obj_index)
        elseif obj_type == "REACTION" then return build_reaction_sheet(obj, obj_index)
        elseif obj_type == "ENTITY"   then return build_entity_sheet(obj)
        elseif obj_type == "ITEM"     then return build_item_sheet(obj)
        elseif obj_type == "BUILDING" then return build_building_sheet(obj)
        elseif obj_type == "CONSTRUCTION" then return build_construction_sheet(obj)
        elseif obj_type == "JOB"      then return build_job_sheet(obj)
        end
    end)

    if ok and type(result) == "table" then
        return result
    else
        -- ERROR: the panel shows READ ERROR, and this says why.
        log('ERROR', 'Sheet build failed: ' .. tostring(result),
            tostring(obj_type))
        return {"=== READ ERROR ===", " Failed to build sheet for type: " .. tostring(obj_type), " " .. tostring(result)}
    end
end


-- ==========================================
-- MAIN PANEL CLASS
-- ==========================================
RefinishPanelInspect = defclass(RefinishPanelInspect, widgets.Panel)
RefinishPanelInspect.ATTRS = { theme = DEFAULT_NIL }

function RefinishPanelInspect:init()
    self.theme = self.theme or reqscript('refinish-theme').get_current_theme()

    -- View state machine: IDLE -> RESULTS -> SHEET
    -- IDLE:    default state, shows instructions
    -- RESULTS: search returned multiple matches, showing list
    -- SHEET:   viewing a single object's detail sheet
    self.view_state = "IDLE"
    self.search_results = {}
    self.current_gm_path = ""

    -- ==========================================
    -- HOTKEY LABEL FACTORY
    -- ==========================================
    -- Builds a text token array with the hotkey character in PRI
    -- and the label text in the specified pen. This follows the
    -- mod's UI convention: key pops, label recedes.
    -- ==========================================
    local function make_key_label(key_token, label_text, pen_label)
        local key_str = dfhack.screen.getKeyDisplay(df.interface_key[key_token])
        return {
            {text = key_str, pen = self.theme.PRI},
            {text = ": " .. label_text, pen = pen_label}
        }
    end

    -- ==========================================
    -- ACTION HANDLERS
    -- ==========================================
    self.actions = {
        -- Search: opens a text input dialog for the query
        CUSTOM_CTRL_I = function()
            dialogs.showInputPrompt(
                "MEMORY INSPECTION",
                "Enter ID, Name, or Coordinates.\nLeave blank and press Enter to clear:",
                self.theme.SEC, "",
                function(text) self:do_search(text) end
            )
        end,
        -- Back: returns to the results list from a sheet view
        CUSTOM_CTRL_B = function() self:show_results() end,
        -- gm-editor: opens the current object in DFHack's gm-editor
        CUSTOM_CTRL_G = function()
            if self.current_gm_path ~= "" then
                -- DETAIL: navigation inside a debugging tool.
                log('DETAIL', 'Opened gm-editor on '
                    .. tostring(self.current_gm_path) .. '.', 'GM_EDITOR')
                dfhack.run_command('gui/gm-editor', self.current_gm_path)
            end
        end
    }

    -- ==========================================
    -- WIDGET LAYOUT
    -- ==========================================
    self.search_widget = widgets.Label{
        frame = {t = 2, l = 0, w = 18},
        text = make_key_label('CUSTOM_CTRL_I', 'Search RAM', self.theme.SEC),
        on_click = self.actions.CUSTOM_CTRL_I
    }

    self.list_widget = widgets.List{
        frame = {t = 4, l = 0, r = 0, b = 3},
        text_pen = self.theme.SEC,
        cursor_pen = self.theme.PRI,
        on_submit = function(idx, choice)
            if self.view_state == "RESULTS" and choice.data then
                log('DETAIL', 'Selected ' .. tostring(choice.text) .. '.',
                    'RESULTS')
                self:open_sheet(choice.data.obj, choice.data.type, choice.data.path, choice.data.idx)
            end
        end
    }

    self.btn_back = widgets.Label{
        frame = {b = 0, l = 0, w = 23},
        text = make_key_label('CUSTOM_CTRL_B', 'Back to Results', self.theme.SEC),
        visible = function() return self.view_state == "SHEET" and #self.search_results > 1 end,
        on_click = self.actions.CUSTOM_CTRL_B
    }

    self.btn_gm = widgets.Label{
        frame = {b = 0, l = 28, w = 25},
        text = make_key_label('CUSTOM_CTRL_G', 'Open in gm-editor', self.theme.SEC),
        visible = function() return self.view_state == "SHEET" and self.current_gm_path ~= "" end,
        on_click = self.actions.CUSTOM_CTRL_G
    }

    self:addviews{
        widgets.Label{ frame = {t = 0, l = 0}, text = "MEMORY INSPECTOR", text_pen = self.theme.PRI },
        self.search_widget,
        self.list_widget,
        widgets.Panel{ frame = {b = 0, l = 0, r = 0, h = 2},
            subviews = { self.btn_back, self.btn_gm }
        }
    }

    self.list_widget:setChoices({"  Press Ctrl-I to search C++ memory."})
end


-- ==========================================
-- INPUT ROUTING
-- ==========================================
function RefinishPanelInspect:onInput(keys)
    for key_name, action in pairs(self.actions) do
        if keys[key_name] then
            action()
            return true
        end
    end
    return RefinishPanelInspect.super.onInput(self, keys)
end


-- ==========================================
-- SEARCH EXECUTION
-- ==========================================
-- Clears previous state, runs the search, and routes to the
-- appropriate view: idle (empty query), auto-open (single
-- result), or results list (multiple results).
-- ==========================================
function RefinishPanelInspect:do_search(query)
    -- Empty query = clear and return to idle
    if not query or query == "" then
        -- DETAIL throughout: search tracking inside a debugging tool.
        log('DETAIL', 'Search cleared.', 'SEARCH')
        self.view_state = "IDLE"
        self.search_results = {}
        self.current_gm_path = ""
        self.list_widget:setChoices({"  Press Ctrl-I to search C++ memory."})
        return
    end

    log('DETAIL', "Searching for '" .. tostring(query) .. "'.", 'SEARCH')

    self.search_results = execute_search(query)
    local results = self.search_results

    if #results == 0 then
        log('DETAIL', "No results for '" .. tostring(query) .. "'.", 'SEARCH')
        self.view_state = "IDLE"
        self.list_widget:setChoices({"  No objects found matching '" .. query .. "'."})
    elseif #results == 1 then
        -- Single match: auto-open the detail sheet
        log('DETAIL', 'Single match: ' .. tostring(results[1].text) .. '.',
            'SEARCH')
        self:open_sheet(results[1].data.obj, results[1].data.type, results[1].data.path, results[1].data.idx)
    else
        log('DETAIL', #results .. ' results found.', 'SEARCH')
        self:show_results()
    end
end


-- ==========================================
-- RESULTS LIST VIEW
-- ==========================================
function RefinishPanelInspect:show_results()
    self.view_state = "RESULTS"
    self.current_gm_path = ""
    self.list_widget:setChoices(self.search_results)
end


-- ==========================================
-- DETAIL SHEET VIEW
-- ==========================================
-- Sheet builders return a mix of plain strings and tagged tables.
-- Plain strings render in SEC (standard body text).
-- Tagged entries like {text = "...", pen = "PRI"} get their pen
-- resolved from the theme table. This keeps the theme out of the
-- builders and centralizes colour logic here.
--
-- Recognized pen tags: PRI, SEC, TER, NEUTRAL_B, NEUTRAL_S,
-- RISK_L, RISK_M, RISK_H (mapped from self.theme).
-- ==========================================
function RefinishPanelInspect:open_sheet(target_obj, target_type, gm_path, obj_index)
    self.view_state = "SHEET"
    self.current_gm_path = gm_path

    local raw_lines = build_sheet(target_obj, target_type, obj_index)

    -- Translate tagged lines into themed List choices
    local choices = {}
    for _, entry in ipairs(raw_lines) do
        if type(entry) == "table" and entry.text then
            -- Tagged entry: resolve the pen name to an actual theme pen
            local pen = self.theme[entry.pen] or self.theme.SEC
            table.insert(choices, {text = {{text = entry.text, pen = pen}}})
        else
            -- Plain string: default SEC body text
            table.insert(choices, {text = {{text = tostring(entry), pen = self.theme.SEC}}})
        end
    end

    self.list_widget:setChoices(choices)
end

return _ENV