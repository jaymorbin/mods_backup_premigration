--@ module = true
-- refinish-module-validate.lua
-- ==========================================
-- RM MODULE SCHEMA VALIDATOR
-- ==========================================
-- Checks a parsed JSON payload (materials or reactions) against
-- the v1 schema rules before the engine lets it anywhere near
-- the injection pipeline. Returns true/false and a reason string.
--
-- DESIGN:
--   Each validate_* function checks one layer of the payload.
--   They're called top-down: module identity first, then each
--   material or reaction entry, then each reagent/product within
--   a reaction. Errors are returned immediately - first failure
--   stops validation for that payload.
--
--   The types dictionary is imported for checking that type names
--   (reagent types, product types, building types, material classes)
--   actually exist in the engine's lookup tables.
--
-- USAGE:
--   local validator = reqscript('refinish-module-validate')
--   local ok, reason = validator.validate_materials(parsed_json)
--   local ok, reason = validator.validate_reactions(parsed_json)
-- ==========================================

local types = reqscript('refinish-module-types')


-- ==========================================
-- UTILITY: TYPE CHECKS
-- ==========================================
-- Small helpers to keep validation code readable.
-- ==========================================

local function is_string(v)
    return type(v) == "string"
end

local function is_nonempty_string(v)
    return type(v) == "string" and v ~= ""
end

local function is_number(v)
    return type(v) == "number"
end

local function is_table(v)
    return type(v) == "table"
end

local function is_nil_or_number(v)
    return v == nil or type(v) == "number"
end

local function is_nil_or_string(v)
    return v == nil or type(v) == "string"
end

local function is_nil_or_table(v)
    return v == nil or type(v) == "table"
end


-- ==========================================
-- VALIDATE: MODULE IDENTITY
-- ==========================================
-- Shared between materials and reactions files. Checks the
-- module block that must appear in both.
-- ==========================================
local function validate_module_identity(payload)
    if not is_table(payload.module) then
        return false, "Missing 'module' block"
    end

    local m = payload.module

    if not is_nonempty_string(m.prefix) then
        return false, "module.prefix must be a non-empty string"
    end

    -- Prefix must end with underscore (convention for ID generation)
    if not string.find(m.prefix, "_$") then
        return false, "module.prefix must end with underscore: '" .. tostring(m.prefix) .. "'"
    end

    -- Prefix must not collide with RM's core prefix
    if string.find(m.prefix, "REFINISH_STEEL_") then
        return false, "module.prefix collides with RM core prefix: '" .. tostring(m.prefix) .. "'"
    end

    if not is_nonempty_string(m.name) then
        return false, "module.name must be a non-empty string"
    end

    if not is_nonempty_string(m.version) then
        return false, "module.version must be a non-empty string"
    end

    -- ---- OPTIONAL: DECLARED DEPENDENCIES ----
    -- depends_on lists the prefixes of other modules whose materials
    -- this module names by mat_id. The engine injects those modules
    -- first. Absent or empty means no dependencies, which is the
    -- normal case.
    --
    -- Only the shape is checked here. Whether the named modules are
    -- actually installed cannot be known until every listener has
    -- answered the token call, so that check lives in the engine.
    if m.depends_on ~= nil then
        if not is_table(m.depends_on) then
            return false, "module.depends_on must be an array of prefix strings"
        end
        for i, dep in ipairs(m.depends_on) do
            if not is_nonempty_string(dep) then
                return false, "module.depends_on[" .. i .. "] must be a non-empty string"
            end
            if not string.find(dep, "_$") then
                return false, "module.depends_on[" .. i .. "] must end with underscore: '" .. tostring(dep) .. "'"
            end
            if dep == m.prefix then
                return false, "module.depends_on[" .. i .. "] cannot be the module's own prefix"
            end
        end
    end

    return true
end


-- ==========================================
-- VALIDATE: SINGLE MATERIAL ENTRY
-- ==========================================
local function validate_material(mat, index, prefix)
    local tag = string.format("materials[%d]", index)

    -- Key: required, must be uppercase with no spaces
    if not is_nonempty_string(mat.key) then
        return false, tag .. ".key must be a non-empty string"
    end
    if string.find(mat.key, "%s") then
        return false, tag .. ".key must not contain spaces: '" .. mat.key .. "'"
    end
    if mat.key ~= string.upper(mat.key) then
        return false, tag .. ".key must be UPPERCASE: '" .. mat.key .. "'"
    end

    -- Name: required
    if not is_nonempty_string(mat.name) then
        return false, tag .. ".name must be a non-empty string"
    end

    -- Material class: required, must exist in the types dictionary
    if not is_nonempty_string(mat.material_class) then
        return false, tag .. ".material_class is required"
    end
    if not types.MATERIAL_CLASS_PRESETS[mat.material_class] then
        return false, tag .. ".material_class '" .. mat.material_class .. "' is not a recognized class"
    end

    -- Color: optional but must be string if present
    if mat.color ~= nil and not is_string(mat.color) then
        return false, tag .. ".color must be a string or null"
    end

    -- Fallback colors: optional, must be array of strings if present
    if mat.fallback_colors ~= nil then
        if not is_table(mat.fallback_colors) then
            return false, tag .. ".fallback_colors must be an array or null"
        end
        for i, fc in ipairs(mat.fallback_colors) do
            if not is_string(fc) then
                return false, tag .. ".fallback_colors[" .. i .. "] must be a string"
            end
        end
    end

    -- Dye colour override: optional string. Only read on a dye; the
    -- default is the material's own colour (apply_dye_color).
    if not is_nil_or_string(mat.dye_color) then
        return false, tag .. ".dye_color must be a string or null"
    end

    -- Value: optional number
    if not is_nil_or_number(mat.value) then
        return false, tag .. ".value must be a number or null"
    end

    -- Density fields: optional numbers
    if not is_nil_or_number(mat.solid_density) then
        return false, tag .. ".solid_density must be a number or null"
    end
    if not is_nil_or_number(mat.liquid_density) then
        return false, tag .. ".liquid_density must be a number or null"
    end
    if not is_nil_or_number(mat.molar_mass) then
        return false, tag .. ".molar_mass must be a number or null"
    end

    -- Heat: optional table, each field optional number
    if mat.heat ~= nil then
        if not is_table(mat.heat) then
            return false, tag .. ".heat must be a table or null"
        end
        local heat_fields = {
            "spec_heat", "melting_point", "boiling_point",
            "ignite_point", "heatdam_point", "colddam_point",
            "mat_fixed_temp"
        }
        for _, field in ipairs(heat_fields) do
            if not is_nil_or_number(mat.heat[field]) then
                return false, tag .. ".heat." .. field .. " must be a number or null"
            end
        end
    end

    -- Strength: optional table with sub-tables
    if mat.strength ~= nil then
        if not is_table(mat.strength) then
            return false, tag .. ".strength must be a table or null"
        end
        local stress_fields = { "IMPACT", "COMPRESSIVE", "TENSILE", "TORSION", "SHEAR", "BENDING" }
        for _, group in ipairs({"yield", "fracture", "strain_at_yield"}) do
            if mat.strength[group] ~= nil then
                if not is_table(mat.strength[group]) then
                    return false, tag .. ".strength." .. group .. " must be a table or null"
                end
                for _, field in ipairs(stress_fields) do
                    if not is_nil_or_number(mat.strength[group][field]) then
                        return false, tag .. ".strength." .. group .. "." .. field .. " must be a number or null"
                    end
                end
            end
        end
        if not is_nil_or_number(mat.strength.max_edge) then
            return false, tag .. ".strength.max_edge must be a number or null"
        end
    end

    -- Gem names: optional, must be array of exactly 2 strings if present
    if mat.gem_names ~= nil then
        if not is_table(mat.gem_names) or #mat.gem_names ~= 2 then
            return false, tag .. ".gem_names must be an array of exactly 2 strings or null"
        end
        if not is_string(mat.gem_names[1]) or not is_string(mat.gem_names[2]) then
            return false, tag .. ".gem_names entries must be strings"
        end
    end

    -- GEM class requires gem_names
    if mat.material_class == "GEM" and mat.gem_names == nil then
        return false, tag .. ": material_class GEM requires gem_names to be set"
    end

    -- Item type name overrides. The two fields have DIFFERENT
    -- shapes, which is the trap: block_name is a {singular, plural}
    -- pair that DF suffixes onto the material name, stone_name is
    -- one already-plural string that REPLACES the name outright.
    -- Passing an array to stone_name throws inside injection.
    if mat.block_name ~= nil then
        if not is_table(mat.block_name) or #mat.block_name ~= 2 then
            return false, tag .. ".block_name must be an array of exactly 2 strings or null"
        end
        if not is_string(mat.block_name[1]) or not is_string(mat.block_name[2]) then
            return false, tag .. ".block_name entries must be strings"
        end
    end

    if mat.stone_name ~= nil then
        if not is_string(mat.stone_name) then
            return false, tag .. ".stone_name must be a single string or null"
                .. " (unlike block_name, it is not a pair)"
        end
    end

    -- Reaction classes: optional array of strings
    if mat.reaction_classes ~= nil then
        if not is_table(mat.reaction_classes) then
            return false, tag .. ".reaction_classes must be an array or null"
        end
        for i, rc in ipairs(mat.reaction_classes) do
            if not is_string(rc) then
                return false, tag .. ".reaction_classes[" .. i .. "] must be a string"
            end
        end
    end

    -- Graphics: optional object of slot -> donor spec. Slots are
    -- fixed; each value is a donor token string, or a table with
    -- donor (required string) and offset (optional number).
    if mat.graphics ~= nil then
        if not is_table(mat.graphics) then
            return false, tag .. ".graphics must be a table or null"
        end
        local slots = { bar = true, boulder = true, wood = true,
                        rough = true, cheese = true, texflag = true }
        for slot, entry in pairs(mat.graphics) do
            if not slots[slot] then
                return false, tag .. ".graphics has unknown slot '"
                    .. tostring(slot) .. "'"
            end
            if is_string(entry) then
                -- short form, fine
            elseif is_table(entry) then
                if not is_string(entry.donor) then
                    return false, tag .. ".graphics." .. slot
                        .. ".donor must be a string"
                end
                if entry.offset ~= nil
                   and type(entry.offset) ~= 'number' then
                    return false, tag .. ".graphics." .. slot
                        .. ".offset must be a number"
                end
            else
                return false, tag .. ".graphics." .. slot
                    .. " must be a donor string or a table"
            end
        end
    end

    -- Reaction products: optional array of {id, mat_id} objects
    if mat.reaction_products ~= nil then
        if not is_table(mat.reaction_products) then
            return false, tag .. ".reaction_products must be an array or null"
        end
        for i, rp in ipairs(mat.reaction_products) do
            if not is_table(rp) then
                return false, tag .. ".reaction_products[" .. i .. "] must be a table"
            end
            if not is_nonempty_string(rp.id) then
                return false, tag .. ".reaction_products[" .. i .. "].id is required"
            end
            if not is_nonempty_string(rp.mat_id) then
                return false, tag .. ".reaction_products[" .. i .. "].mat_id is required"
            end
        end
    end

    -- Flag overrides: optional dicts of string->boolean
    if mat.material_flags ~= nil then
        if not is_table(mat.material_flags) then
            return false, tag .. ".material_flags must be a table or null"
        end
    end
    if mat.inorganic_flags ~= nil then
        if not is_table(mat.inorganic_flags) then
            return false, tag .. ".inorganic_flags must be a table or null"
        end
    end

    return true
end


-- ==========================================
-- VALIDATE: SINGLE REAGENT
-- ==========================================
local function validate_reagent(rgt, index, reaction_tag)
    local tag = reaction_tag .. ".reagents[" .. index .. "]"

    if not is_nonempty_string(rgt.code) then
        return false, tag .. ".code is required"
    end

    if not is_nonempty_string(rgt.type) then
        return false, tag .. ".type is required"
    end
    if not types.REAGENT_TYPES[rgt.type] then
        return false, tag .. ".type '" .. rgt.type .. "' is not a recognized reagent type"
    end

    -- Types that require a material take mat_id (an inorganic) or
    -- mat_token (any material by full token, a plant's above all). The
    -- token is resolved at build time; here it only has to be a string.
    local rtype = types.REAGENT_TYPES[rgt.type]
    if rgt.mat_token ~= nil and not is_nonempty_string(rgt.mat_token) then
        return false, tag .. ".mat_token must be a non-empty string"
    end
    if rtype.needs_mat_id and not is_nonempty_string(rgt.mat_id)
       and not is_nonempty_string(rgt.mat_token) then
        return false, tag .. ": type '" .. rgt.type .. "' requires mat_id or mat_token"
    end

    -- ORE_OF requires metal_id
    if rtype.needs_metal_id and not is_nonempty_string(rgt.metal_id) then
        return false, tag .. ": type '" .. rgt.type .. "' requires metal_id"
    end

    -- Quantity: required number
    if not is_number(rgt.quantity) then
        return false, tag .. ".quantity must be a number"
    end

    -- Flags: optional table
    if rgt.flags ~= nil and not is_table(rgt.flags) then
        return false, tag .. ".flags must be a table or null"
    end

    -- Container linkage: optional strings
    if rgt.contains ~= nil and not is_string(rgt.contains) then
        return false, tag .. ".contains must be a string or null"
    end
    if rgt.contains_in ~= nil and not is_string(rgt.contains_in) then
        return false, tag .. ".contains_in must be a string or null"
    end

    -- Reaction class / material reaction product: optional strings
    if not is_nil_or_string(rgt.has_material_reaction_product) then
        return false, tag .. ".has_material_reaction_product must be a string or null"
    end
    if not is_nil_or_string(rgt.reaction_class) then
        return false, tag .. ".reaction_class must be a string or null"
    end

    return true
end


-- ==========================================
-- VALIDATE: SINGLE PRODUCT
-- ==========================================
local function validate_product(prod, index, reaction_tag)
    local tag = reaction_tag .. ".products[" .. index .. "]"

    if not is_nonempty_string(prod.type) then
        return false, tag .. ".type is required"
    end

    -- Named entries in PRODUCT_TYPES exist for the cases needing a
    -- non-default mat_type or a special flag. Anything else is accepted
    -- if df.item_type knows the name, which is how the builder resolves
    -- it. Without this second check every plain item type (TOOL, TABLE,
    -- WINDOW and the rest) would be refused here before the builder
    -- ever saw it.
    if not types.PRODUCT_TYPES[prod.type]
       and type(df.item_type[prod.type]) ~= "number" then
        return false, tag .. ".type '" .. prod.type .. "' is not a recognized product type"
    end

    -- ---- IMPROVEMENT PRODUCTS ----
    -- A different product class with a different field set, so it is
    -- checked on its own terms and returns early.
    --
    -- get_material_product is required, not optional. The builder
    -- clones a donor and keeps the donor's flag bits, which are set for
    -- GET_MATERIAL_FROM_REAGENT. Any other material mode would inject
    -- against flags nobody set, so it is refused here instead.
    if prod.type == "IMPROVEMENT" then
        if not is_nonempty_string(prod.improvement_type) then
            return false, tag .. ".improvement_type is required for IMPROVEMENT products"
        end
        -- Check the name resolves. GLAZED is accepted as the raws name
        -- for a COVERED improvement carrying the GLAZED flag; anything
        -- else has to be a real df.improvement_type member.
        --
        -- Previously any non-empty string passed here and the failure
        -- surfaced at build time as a bare print, which meant a typo
        -- produced a reaction with no products and nothing in the log.
        if prod.improvement_type ~= "GLAZED"
           and type(df.improvement_type[prod.improvement_type]) ~= "number" then
            return false, tag .. ".improvement_type '" .. tostring(prod.improvement_type)
                   .. "' is not a known improvement type"
        end
        if not is_nonempty_string(prod.target_reagent) then
            return false, tag .. ".target_reagent is required for IMPROVEMENT products"
        end
        if not is_table(prod.get_material_product)
           or not is_nonempty_string(prod.get_material_product.reagent_code)
           or not is_nonempty_string(prod.get_material_product.product_code) then
            return false, tag .. ".IMPROVEMENT products require get_material_product with reagent_code and product_code"
        end
        if prod.mat_id ~= nil or prod.get_material_same ~= nil then
            return false, tag .. ".IMPROVEMENT products cannot use mat_id or get_material_same"
        end
        return true
    end

    -- Builtin-material products carry their material in the type
    -- itself (ash, pearlash, coal, potash bars), so they name no
    -- material at all and would fail the exactly-one check below.
    local ptype = types.PRODUCT_TYPES[prod.type]
    if ptype and ptype.builtin
       and prod.mat_id == nil
       and prod.get_material_same == nil
       and prod.get_material_product == nil then
        return true
    end

    -- Must have exactly one material source: mat_id, get_material_same, or get_material_product
    -- mat_token is the fourth mode: a full material token resolved
    -- live at build time. It exists because a PLANT material's
    -- mat_type is 419 plus the host's own index, which no static
    -- table can hold. Counted as a source like the other three, so a
    -- product naming one is complete and a product naming two is
    -- still a contradiction.
    local source_count = 0
    if prod.mat_id ~= nil then source_count = source_count + 1 end
    if prod.mat_token ~= nil then source_count = source_count + 1 end
    if prod.get_material_same ~= nil then source_count = source_count + 1 end
    if prod.get_material_product ~= nil then source_count = source_count + 1 end

    if source_count == 0 then
        return false, tag .. ": must specify exactly one of mat_id, mat_token, get_material_same, or get_material_product"
    end
    if source_count > 1 then
        return false, tag .. ": only one of mat_id, mat_token, get_material_same, or get_material_product allowed"
    end

    -- Validate get_material_product structure if present
    if prod.get_material_product ~= nil then
        if not is_table(prod.get_material_product) then
            return false, tag .. ".get_material_product must be a table"
        end
        if not is_nonempty_string(prod.get_material_product.reagent_code) then
            return false, tag .. ".get_material_product.reagent_code is required"
        end
        if not is_nonempty_string(prod.get_material_product.product_code) then
            return false, tag .. ".get_material_product.product_code is required"
        end
    end

    -- Count: optional number, defaults to 1 downstream
    if prod.count ~= nil and not is_number(prod.count) then
        return false, tag .. ".count must be a number or null"
    end

    -- Dimension: optional number
    if prod.dimension ~= nil and not is_number(prod.dimension) then
        return false, tag .. ".dimension must be a number or null"
    end

    -- Probability: optional number
    if prod.probability ~= nil and not is_number(prod.probability) then
        return false, tag .. ".probability must be a number or null"
    end

    return true
end


-- ==========================================
-- VALIDATE: SINGLE REACTION
-- ==========================================
local function validate_reaction(rxn, index, prefix)
    local tag = string.format("reactions[%d]", index)

    -- Key
    if not is_nonempty_string(rxn.key) then
        return false, tag .. ".key must be a non-empty string"
    end

    -- Name
    if not is_nonempty_string(rxn.name) then
        return false, tag .. ".name must be a non-empty string"
    end

    -- Building: required, must exist in types dictionary
    if not is_nonempty_string(rxn.building) then
        return false, tag .. ".building is required"
    end
    if not types.BUILDING_TYPES[rxn.building] then
        return false, tag .. ".building '" .. rxn.building .. "' is not a recognized building type"
    end

    -- Skill: optional, must exist in skill map if present
    if rxn.skill ~= nil then
        if not is_string(rxn.skill) then
            return false, tag .. ".skill must be a string or null"
        end
        if not types.SKILL_MAP[rxn.skill] then
            return false, tag .. ".skill '" .. rxn.skill .. "' is not a recognized skill"
        end
    end

    -- Fuel: optional boolean
    if rxn.fuel ~= nil and type(rxn.fuel) ~= "boolean" then
        return false, tag .. ".fuel must be true, false, or null"
    end

    -- Category: optional string
    if not is_nil_or_string(rxn.category) then
        return false, tag .. ".category must be a string or null"
    end

    -- Fallback template: optional string
    if not is_nil_or_string(rxn.fallback_template) then
        return false, tag .. ".fallback_template must be a string or null"
    end

    -- ---- PERMISSIONS ----
    -- Optional block controlling which civs receive this reaction.
    -- If omitted, the evaluator defaults to AUTO (all civs that
    -- can process the reagent metals get the permit). When present,
    -- the mode field selects the evaluation strategy.
    --
    -- Valid modes:
    --   "AUTO"        - Evaluate all civs. Any civ that can process
    --                    all reagent metals gets the permit.
    --   "ENTITY_CODE" - Only evaluate named entity_raw codes. Same
    --                    reagent knowledge gate still applies. Works
    --                    with any entity_raw.code - vanilla or modded.
    --   "NONE"        - No permits pushed to any civ. The reaction
    --                    is only accessible if fortress_mode is true.
    --                    This is the purple-gold pattern: valid
    --                    inorganic + valid reaction + no permissions +
    --                    fort mode = player-only access.
    --
    -- See refinish-module-evaluate-permissions.lua for gate logic.
    if rxn.permissions ~= nil then
        if not is_table(rxn.permissions) then
            return false, tag .. ".permissions must be a table or null"
        end

        local VALID_MODES = { AUTO = true, ENTITY_CODE = true, NONE = true }
        local mode = rxn.permissions.mode
        if mode ~= nil then
            if not is_string(mode) then
                return false, tag .. ".permissions.mode must be a string or null"
            end
            if not VALID_MODES[mode] then
                return false, tag .. ".permissions.mode '" .. mode
                    .. "' is not recognized (valid: AUTO, ENTITY_CODE, NONE)"
            end
        end

        -- ENTITY_CODE requires a non-empty entities array.
        -- These are entity_raw.code strings - not hardcoded to vanilla.
        if mode == "ENTITY_CODE" then
            if not is_table(rxn.permissions.entities) or #rxn.permissions.entities == 0 then
                return false, tag .. ".permissions: ENTITY_CODE mode requires a non-empty 'entities' array"
            end
            for i, ent in ipairs(rxn.permissions.entities) do
                if not is_nonempty_string(ent) then
                    return false, tag .. ".permissions.entities[" .. i .. "] must be a non-empty string"
                end
            end
        end

        -- Entities should NOT be present in AUTO or NONE mode
        if (mode == nil or mode == "AUTO" or mode == "NONE")
           and rxn.permissions.entities ~= nil then
            return false, tag .. ".permissions: 'entities' should only be set with ENTITY_CODE mode"
        end
    end

    -- ---- REACTION FLAGS ----
    -- Optional block for DF reaction flags that the react builder
    -- should set explicitly rather than inheriting from the template.
    -- Currently supports fortress_mode (FORTRESS_MODE_ENABLED).
    if rxn.reaction_flags ~= nil then
        if not is_table(rxn.reaction_flags) then
            return false, tag .. ".reaction_flags must be a table or null"
        end

        if rxn.reaction_flags.fortress_mode ~= nil
           and type(rxn.reaction_flags.fortress_mode) ~= "boolean" then
            return false, tag .. ".reaction_flags.fortress_mode must be true, false, or null"
        end
    end

    -- Reagents: required, must be non-empty array
    if not is_table(rxn.reagents) or #rxn.reagents == 0 then
        return false, tag .. ".reagents must be a non-empty array"
    end
    -- Check for duplicate reagent codes
    local seen_codes = {}
    for i, rgt in ipairs(rxn.reagents) do
        local ok, reason = validate_reagent(rgt, i, tag)
        if not ok then return false, reason end
        if seen_codes[rgt.code] then
            return false, tag .. ".reagents[" .. i .. "].code '" .. rgt.code .. "' is duplicated"
        end
        seen_codes[rgt.code] = true
    end

    -- Validate container linkage: contains/contains_in references must exist
    for i, rgt in ipairs(rxn.reagents) do
        if rgt.contains ~= nil and not seen_codes[rgt.contains] then
            return false, tag .. ".reagents[" .. i .. "].contains references unknown code '" .. rgt.contains .. "'"
        end
        if rgt.contains_in ~= nil and not seen_codes[rgt.contains_in] then
            return false, tag .. ".reagents[" .. i .. "].contains_in references unknown code '" .. rgt.contains_in .. "'"
        end
    end

    -- Products: required, must be non-empty array
    if not is_table(rxn.products) or #rxn.products == 0 then
        return false, tag .. ".products must be a non-empty array"
    end
    for i, prod in ipairs(rxn.products) do
        local ok, reason = validate_product(prod, i, tag)
        if not ok then return false, reason end
    end

    return true
end


-- ==========================================
-- VALIDATE: CATEGORY
-- ==========================================
local function validate_category(cat, index)
    local tag = string.format("categories[%d]", index)

    if not is_nonempty_string(cat.key) then
        return false, tag .. ".key must be a non-empty string"
    end

    if not is_nonempty_string(cat.name) then
        return false, tag .. ".name must be a non-empty string"
    end

    -- Parent can be empty string (top-level) or a category ID
    if not is_string(cat.parent) then
        return false, tag .. ".parent must be a string (empty for top-level)"
    end

    -- Optional: menu blurb shown under the category in the job list
    if not is_nil_or_string(cat.description) then
        return false, tag .. ".description must be a string or null"
    end

    -- Optional: menu hotkey, an interface_key name such as "CUSTOM_G".
    -- Unknown names warn at injection rather than failing here, so this
    -- only checks the shape.
    if not is_nil_or_string(cat.hotkey) then
        return false, tag .. ".hotkey must be a string or null"
    end

    return true
end


-- ==========================================
-- PUBLIC: VALIDATE MATERIALS FILE
-- ==========================================
-- Call with the parsed JSON table from the materials data file.
-- Returns true on success, false + reason on failure.
-- ==========================================
function validate_materials(payload)
    -- Module identity
    local ok, reason = validate_module_identity(payload)
    if not ok then return false, reason end

    -- Materials array
    if not is_table(payload.materials) then
        return false, "Missing 'materials' array"
    end
    if #payload.materials == 0 then
        return false, "'materials' array is empty"
    end

    -- Check for duplicate keys
    local seen_keys = {}
    for i, mat in ipairs(payload.materials) do
        local ok, reason = validate_material(mat, i, payload.module.prefix)
        if not ok then return false, reason end
        if seen_keys[mat.key] then
            return false, "materials[" .. i .. "].key '" .. mat.key .. "' is duplicated"
        end
        seen_keys[mat.key] = true
    end

    return true
end


-- ==========================================
-- PUBLIC: VALIDATE REACTIONS FILE
-- ==========================================
-- Call with the parsed JSON table from the reactions data file.
-- Returns true on success, false + reason on failure.
-- ==========================================
function validate_reactions(payload)
    -- Module identity
    local ok, reason = validate_module_identity(payload)
    if not ok then return false, reason end

    -- Reactions array
    if not is_table(payload.reactions) then
        return false, "Missing 'reactions' array"
    end
    if #payload.reactions == 0 then
        return false, "'reactions' array is empty"
    end

    -- Check for duplicate keys
    local seen_keys = {}
    for i, rxn in ipairs(payload.reactions) do
        local ok, reason = validate_reaction(rxn, i, payload.module.prefix)
        if not ok then return false, reason end
        if seen_keys[rxn.key] then
            return false, "reactions[" .. i .. "].key '" .. rxn.key .. "' is duplicated"
        end
        seen_keys[rxn.key] = true
    end

    -- Categories: optional but if present, validate each
    if payload.categories ~= nil then
        if not is_table(payload.categories) then
            return false, "'categories' must be an array"
        end
        local seen_cat_keys = {}
        for i, cat in ipairs(payload.categories) do
            local ok, reason = validate_category(cat, i)
            if not ok then return false, reason end
            if seen_cat_keys[cat.key] then
                return false, "categories[" .. i .. "].key '" .. cat.key .. "' is duplicated"
            end
            seen_cat_keys[cat.key] = true
        end
    end

    return true
end


return _ENV