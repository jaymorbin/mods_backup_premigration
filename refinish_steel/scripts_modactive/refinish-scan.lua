-- refinish-scan.lua
-- ==========================================
-- SCRIPT LOGIC: REFINISH-SCAN (MULTI-BASE MODE)
-- ==========================================
-- ONE FINISH, ONE MATERIAL, ONE NAME
--
-- The old scanner keyed a colour material on colour AND VALUE, so
-- every blue reagent whose arithmetic landed on a different number
-- minted its own "blue steel". Three of them existed at once. DF
-- shows a material by its display name and nothing else, so the
-- forge listed three identical rows, the two the fort had no bars
-- for start-cancelled, and the cancellation could only say "needs
-- blue steel bars". Same trap on the SPECIFIC side, where three
-- iron ores all produced a material called "ferriferous steel".
--
-- THE RULE NOW, in one line: a display name identifies exactly one
-- material, and value conservation is what a shared name costs.
--
--   COLOUR finishes   one material per colour per base metal.
--                     Value is the base metal's value, always.
--                     Every reagent of that colour makes that one
--                     material. Colour is a family, not a recipe.
--
--   SHARED finishes   a named finish more than one reagent can
--                     produce (ferriferous from three iron ores).
--                     One material, value is the base metal's.
--
--   UNIQUE finishes   a named finish exactly one reagent produces.
--                     Its own material, and value IS conserved:
--                     base plus a share of the reagent's worth.
--
-- Conservation survives wherever the material can carry it, which
-- is wherever the name points at a single recipe. Where several
-- recipes share a name, no single material can hold several values,
-- so the value goes rather than the name.
--
-- WHY TWO PASSES. Whether a finish is shared cannot be known while
-- walking the reagents, because the second taker may be hundreds of
-- entries later. Pass A surveys and counts; pass B builds knowing
-- the totals. A one pass version has to guess and is wrong for
-- whichever reagent it meets first.
-- ==========================================
local json = require('json')

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
-- SUBJECT is the correlation slot: the step or thing a line is
-- about. Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'SCANNER'
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

if _G.refinish_blueprint ~= nil then
    log('DETAIL', 'Blueprint already exists in memory. Skipping scan.')
    return
end

log('DETAIL', 'Master scan initiated (multi-base mode).')

local perf_setting = dfhack.persistent.getSiteData('refinish_config_perf') or 'ON'

-- ==========================================
-- INITIALIZE BLUEPRINT & TIER 1 ROOT
-- ==========================================
_G.refinish_blueprint = {
    materials = {},
    reactions = {},
    original_names = {},
    categories = {
        -- TIER 1: THE ROOT
        ROOT = { id = "REFINISH_STEEL_CAT_ROOT", name = "Refinish metal bars", parent = "" }
    }
}

-- =================
-- OVERRIDES
-- =================
-- The prefix is the FINISH NAME. Where several reagents share one,
-- they share the finish and therefore the material: the three iron
-- ores below all make one "ferriferous steel". That sharing is the
-- point of the table, not an accident of it.
local SPECIAL_FINISH = {
    ["IRON"] = { prefix = "ironclad" },
    ["GOLD"] = { prefix = "gilded" },
    ["PLATINUM"] = { prefix = "platinized" },
    ["SILVER"] = { prefix = "silvered" },
    ["COPPER"] = { prefix = "coppered" },
    ["NICKEL"] = { prefix = "nickeled" },
    ["ZINC"] = { prefix = "galvanized" },
    ["BRONZE"] = { prefix = "bronzed" },
    ["BRASS"] = { prefix = "brassed" },
    ["ROSE_GOLD"] = { prefix = "rose-gilded" },
    ["PIG_IRON"] = { prefix = "pig" },
    ["STEEL"] = { prefix = "satin" },
    ["ELECTRUM"] = { prefix = "electrumized" },
    ["TIN"] = { prefix = "tinned" },
    ["PEWTER_FINE"] = { prefix = "fine-pewtered" },
    ["PEWTER_TRIFLE"] = { prefix = "trifle-pewtered" },
    ["PEWTER_LAY"] = { prefix = "lay-pewtered" },
    ["LEAD"] = { prefix = "leaded" },
    ["ALUMINUM"] = { prefix = "aluminized" },
    ["NICKEL_SILVER"] = { prefix = "nickel-silvered" },
    ["BILLON"] = { prefix = "billonclad" },
    ["STERLING_SILVER"] = { prefix = "sterling-silvered" },
    ["BLACK_BRONZE"] = { prefix = "black-bronzed" },
    ["BISMUTH"] = { prefix = "bismuth-washed" },
    ["BISMUTH_BRONZE"] = { prefix = "bismuth-bronzed" },
    ["ADAMANTINE"] = { prefix = "adamantinized" },
    ["HEMATITE"] = { prefix = "ferriferous" },
    ["LIMONITE"] = { prefix = "ferriferous" },
    ["GARNIERITE"] = { prefix = "kupfernickeled" },
    ["NATIVE_GOLD"] = { prefix = "auriferous" },
    ["NATIVE_SILVER"] = { prefix = "argentiferous" },
    ["NATIVE_COPPER"] = { prefix = "cupriferous" },
    ["MALACHITE"] = { prefix = "cupriferous" },
    ["GALENA"] = { prefix = "plumbiferous" },
    ["SPHALERITE"] = { prefix = "zinciferous" },
    ["CASSITERITE"] = { prefix = "stanniferous" },
    ["NATIVE_PLATINUM"] = { prefix = "platiniferous" },
    ["TETRAHEDRITE"] = { prefix = "cupriferous" },
    ["HORN_SILVER"] = { prefix = "argentiferous" },
    ["BISMUTHINITE"] = { prefix = "bismuthiferous" },
    ["MAGNETITE"] = { prefix = "ferriferous" },
    ["NATIVE_ALUMINUM"] = { prefix = "aluminiferous" },
    ["RAW_ADAMANTINE"] = { prefix = "adamantiferous" }
}

local inorganics = df.global.world.raws.inorganics.all
local colors = df.global.world.raws.descriptors.colors

-- ==========================================
-- LOAD ACTIVE BASE METALS FROM JSON
-- ==========================================
local saved_bases_str = dfhack.persistent.getSiteData('refinish_config_bases')
local active_bases_dict = {}

if saved_bases_str and saved_bases_str ~= "" then
    pcall(function() active_bases_dict = json.decode(saved_bases_str) end)
else
    active_bases_dict["STEEL"] = true
end

if not next(active_bases_dict) then
    -- INFO, not a fault: an empty selection is a player's choice. It
    -- still says so, since it is why no finish exists anywhere.
    log('INFO', 'No base metals selected; refinishing stays dormant.',
        'BASES')
    return
end

-- ==========================================
-- GATEKEEPER INTERCEPT
-- ==========================================
local bases_env = dfhack.script_environment('refinish-bases')
-- We pass true, true to pull the absolute maximum list of physical metals so we can check against it
local valid_metals_list = bases_env.get_valid_bases(true, true) 

local metal_reaction_lookup = {}
for _, m in ipairs(valid_metals_list) do
    metal_reaction_lookup[m.id] = m.has_reaction
end

-- Validate the Base Metals requested by the user
local active_bases = {}
for _, mat in ipairs(inorganics) do
    if active_bases_dict[mat.id] then
        if metal_reaction_lookup[mat.id] then
            local name = mat.material.state_name[0] or mat.id
            table.insert(active_bases, {
                id = mat.id,
                name = string.lower(name),
                value = mat.material.material_value
            })
        else
            -- Legitimately failed validation. Notify explicitly.
            log('WARNING', string.format('Base metal %s dropped: it has no'
                .. ' valid crafting or smelting path.', mat.id), 'BASES')
        end
    end
end

if #active_bases == 0 then
    log('WARNING', 'Every selected base metal was invalid; refinishing'
        .. ' stays dormant.', 'BASES')
    return
end

log('DETAIL', 'Loaded ' .. #active_bases .. ' verified active base metals.',
    'BASES')

-- ==========================================
-- DYNAMIC CATEGORY GENERATION (BASE-FIRST RESTRUCTURE)
-- ==========================================
for _, base in ipairs(active_bases) do
    -- Capitalize the first letter for UI readability (e.g., "steel" -> "Steel")
    local cap_name = string.gsub(base.name, "^%l", string.upper)
    
    -- TIER 2: THE BASE METAL BRANCH (e.g., "Steel finishes")
    local branch_id = "REFINISH_STEEL_CAT_BASE_" .. base.id
    _G.refinish_blueprint.categories[branch_id] = { id = branch_id, name = "Refinish " .. base.name .. " bars", parent = "REFINISH_STEEL_CAT_ROOT" }
    
    -- TIER 3: THE TYPE STEMS (Colour vs Material)
    local c_stem_id = branch_id .. "_COLOUR"
    _G.refinish_blueprint.categories[c_stem_id] = { id = c_stem_id, name = "Colour-based", parent = branch_id }
    
    local m_stem_id = branch_id .. "_MAT"
    _G.refinish_blueprint.categories[m_stem_id] = { id = m_stem_id, name = "Material-based", parent = branch_id }
    
    -- TIER 4: THE COLOUR LEAVES
    _G.refinish_blueprint.categories[c_stem_id .. "_STONE"] = { id = c_stem_id .. "_STONE", name = "Stone finish", parent = c_stem_id }
    _G.refinish_blueprint.categories[c_stem_id .. "_METAL"] = { id = c_stem_id .. "_METAL", name = "Metal finish", parent = c_stem_id }
    _G.refinish_blueprint.categories[c_stem_id .. "_GEM"]   = { id = c_stem_id .. "_GEM", name = "Gem finish", parent = c_stem_id }
    _G.refinish_blueprint.categories[c_stem_id .. "_OTHER"] = { id = c_stem_id .. "_OTHER", name = "Other finish", parent = c_stem_id }

    -- TIER 4: THE MATERIAL LEAVES
    _G.refinish_blueprint.categories[m_stem_id .. "_STONE"] = { id = m_stem_id .. "_STONE", name = "Stone finish", parent = m_stem_id }
    _G.refinish_blueprint.categories[m_stem_id .. "_METAL"] = { id = m_stem_id .. "_METAL", name = "Metal finish", parent = m_stem_id }
    _G.refinish_blueprint.categories[m_stem_id .. "_GEM"]   = { id = m_stem_id .. "_GEM", name = "Gem finish", parent = m_stem_id }
    _G.refinish_blueprint.categories[m_stem_id .. "_OTHER"] = { id = m_stem_id .. "_OTHER", name = "Other finish", parent = m_stem_id }
end

local valid_reagents = 0
local color_mats_created = 0
local specific_mats_created = 0
local shared_finishes = 0
local colourless = 0

local function has_word(str, word)
    return string.match(string.lower(str), "%f[%a]" .. word .. "%f[%A]") ~= nil
end

-- Turns a finish word into the stable tail of a material id.
-- Deterministic, so the same finish yields the same id every load,
-- which is what the ledger and the payload restore both depend on.
local function id_token(word)
    local t = string.upper(word)
    t = string.gsub(t, "[^%w]+", "_")
    t = string.gsub(t, "^_+", "")
    t = string.gsub(t, "_+$", "")
    return t
end

-- ==========================================
-- PASS A: INTAKE SURVEY
-- ==========================================
-- Walks every inorganic once, applies the same validation the old
-- scanner did, and records what each accepted reagent CONTRIBUTES.
-- Nothing is built here. The blueprint stays empty until pass B
-- knows how many reagents want each finish name.
--
-- The one state change that still happens here is the powder
-- rename, because it edits the live material and must run exactly
-- once per reagent.
-- ==========================================
local intake = {}
local rej_type, rej_phase, rej_value, rej_ghost = 0, 0, 0, 0

for _, mat in ipairs(inorganics) do
    if not string.find(mat.id, "REFINISH_STEEL_") then
        local mat_flags = mat.material.flags
        local inorg_flags = mat.flags 
        local reagent_val = mat.material.material_value
        local melt_point = mat.material.heat.melting_point
        
        local is_valid_type = mat_flags.IS_STONE or mat_flags.IS_METAL or mat_flags.IS_GEM or inorg_flags.SOIL_ANY or inorg_flags.SOIL_SAND
        -- THE FIX: Prune ghost metals from becoming finishes
        if mat_flags.IS_METAL and not metal_reaction_lookup[mat.id] then
            is_valid_type = false
            rej_ghost = rej_ghost + 1
        end
        local is_stable_solid = (melt_point == 0 or melt_point > 10015)
        local is_valid_value = (reagent_val >= 0)

        if is_valid_type and is_stable_solid and is_valid_value then
            
            -- Safe Integer Indexing (0 = Solid, 3 = Powder)
            local solid_name = mat.material.state_name[0]
            local powder_name = mat.material.state_name[3]
            local powder_adj = mat.material.state_adj[3]
            if not (has_word(powder_name, "sand") or has_word(powder_name, "gravel") or has_word(powder_name, "dust") or has_word(powder_name, "farin") or has_word(powder_name, "cement") or has_word(powder_name, "powder") or has_word(powder_name, "ash") or has_word(powder_name, "dirt")) then
                
                _G.refinish_blueprint.original_names[mat.id] = {
                    name = powder_name,
                    adj = powder_adj
                }
                
                mat.material.state_name[3] = solid_name .. " dust"
                mat.material.state_adj[3] = solid_name .. " dust"
            end

            -- THE CONDENSED COLOR FINISH (Color Matching)
            local color_idx = mat.material.state_color[0]
            local color_id = "UNKNOWN"
            local clean_color_name = "unknown"

            if color_idx >= 0 and color_idx < #colors then
                color_id = colors[color_idx].id
                clean_color_name = colors[color_idx].name
            end

            if color_idx < 0 then
                local states_to_check = {3, 5, 4}
                for _, s_idx in ipairs(states_to_check) do
                    local c_val = mat.material.state_color[s_idx]
                    if c_val >= 0 and c_val < #colors then
                        color_idx = c_val
                        color_id = colors[c_val].id
                        clean_color_name = colors[c_val].name
                        break
                    end
                end
            end

            if clean_color_name and clean_color_name ~= "unknown" then
                if clean_color_name == "" then
                    clean_color_name = string.lower(string.gsub(color_id, "_", " "))
                end
            end

            if clean_color_name == "unknown" or color_idx < 0 then
                local ansi_colors = {
                    [0] = { [0] = "black",      [1] = "dark gray" },
                    [1] = { [0] = "blue",       [1] = "light blue" },
                    [2] = { [0] = "green",      [1] = "light green" },
                    [3] = { [0] = "cyan",       [1] = "light cyan" },
                    [4] = { [0] = "red",        [1] = "light red" },
                    [5] = { [0] = "magenta",    [1] = "light magenta" },
                    [6] = { [0] = "brown",      [1] = "yellow" },
                    [7] = { [0] = "light gray", [1] = "white" }
                }
                
                local b_col = mat.material.build_color[0]
                local b_brt = mat.material.build_color[2]
                
                if b_col >= 0 and b_col <= 7 then
                    local brt_idx = (b_brt > 0) and 1 or 0
                    clean_color_name = ansi_colors[b_col][brt_idx]
                    color_id = string.upper(string.gsub(clean_color_name, " ", "_"))
                end
            end

            -- WHICH LEAF THIS REAGENT'S REACTIONS FILE UNDER, and the
            -- divisor its worth is shared by when a finish is unique
            -- enough to conserve value. Depends only on the reagent,
            -- so it is settled once here rather than per base metal.
            local class = "OTHER"
            if mat_flags.IS_GEM then
                class = "GEM"
            elseif mat_flags.IS_METAL then
                class = "METAL"
            elseif mat_flags.IS_STONE or inorg_flags.SOIL_ANY or inorg_flags.SOIL_SAND then
                class = "STONE"
            end

            table.insert(intake, {
                mat_id      = mat.id,
                solid_name  = solid_name,
                reagent_val = reagent_val,
                color_idx   = color_idx,
                color_id    = color_id,
                color_name  = clean_color_name,
                class       = class,
            })

            valid_reagents = valid_reagents + 1
        else
            if not is_valid_type then rej_type = rej_type + 1
            elseif not is_stable_solid then rej_phase = rej_phase + 1
            elseif not is_valid_value then rej_value = rej_value + 1
            end
        end
    end
end

-- ==========================================
-- THE FINISH CENSUS
-- ==========================================
-- The single question pass B cannot answer on its own: how many
-- reagents want each named finish. One taker means the name points
-- at one recipe and the material can carry that recipe's value.
-- More than one means the name is a family and the value goes.
--
-- The finish word is the SPECIAL_FINISH prefix where there is one,
-- because that table exists precisely to make several reagents
-- share a name. Otherwise it is the reagent's own name.
-- ==========================================
local function finish_word(entry)
    local special = SPECIAL_FINISH[entry.mat_id]
    if special then return special.prefix end
    return string.lower(entry.solid_name)
end

local finish_takers = {}
for _, e in ipairs(intake) do
    local w = finish_word(e)
    finish_takers[w] = (finish_takers[w] or 0) + 1
end

-- ==========================================
-- WORLD NAME GUARD
-- ==========================================
-- A finish whose display name already belongs to a material outside
-- RM does not go in. DF shows a material by its display name alone,
-- so a finish sharing one is indistinguishable from the material that
-- already owns it, anywhere DF lists materials. BLACK on BRONZE is
-- called "black bronze", which is vanilla BLACK_BRONZE's own name.
--
-- Nothing is renamed and nothing is redirected. The finish is simply
-- not minted, along with every reaction that would make it, so the
-- existing material is never shadowed.
--
-- Lowercased, because a name differing only in case still reads as
-- the same material to a player. RM's own mints are left out: a clash
-- between two RM finishes of one base is name_owner's job in pass B.
--
-- Snapshotted once, here. Modules inject before this scan runs
-- (refinish-startup Step 2, and the hotsave rebuild in
-- refinish-autosave keeps the same order), so everything outside RM
-- is already in the array.
local world_names = {}
for _, mat in ipairs(inorganics) do
    if not string.find(mat.id, "REFINISH_STEEL_") then
        local nm = mat.material.state_name[0]
        if nm and nm ~= "" then
            world_names[string.lower(nm)] = mat.id
        end
    end
end

-- Every skipped finish, recorded once per base however many reagents
-- asked for it, and reported after the build. A finish missing from
-- the menu should never be a mystery.
local skipped_list, skipped_seen = {}, {}
local function note_conflict(base_id, name, owner)
    local key = base_id .. "|" .. name
    if skipped_seen[key] then return end
    skipped_seen[key] = true
    table.insert(skipped_list, { base = base_id, name = name, owner = owner })
end

-- ==========================================
-- PASS B: BUILD
-- ==========================================
-- Colours first, then specifics, and the order is load bearing.
-- name_owner records which material already answers to a display
-- name for this base metal. A specific finish whose name is already
-- taken points at the material that owns it instead of minting a
-- twin, which is what keeps "emerald steel" from existing twice
-- when a colour and a stone are both called emerald.
-- ==========================================
for _, base in ipairs(active_bases) do
    local name_owner = {}

    -- ---- ROUTINE A: COLOUR FINISH ----
    -- One material per colour. Value is the base metal's, with no
    -- reagent contribution at all: a colour is a family of recipes
    -- and no single number can speak for all of them.
    for _, e in ipairs(intake) do
        if e.color_idx >= 0 and e.color_idx < #colors then
            local c_adj    = e.color_name .. " " .. base.name
            local c_mat_id = string.format("REFINISH_STEEL_MAT_COLOUR_%s_%s",
                                           e.color_id, base.id)

            -- WORLD NAME GUARD: a colour finish named like a material
            -- outside RM is not minted, and neither is this reagent's
            -- reaction into it.
            local c_owner = world_names[string.lower(c_adj)]
            if c_owner then
                note_conflict(base.id, c_adj, c_owner)
                goto next_colour
            end

            if not _G.refinish_blueprint.materials[c_mat_id] then
                _G.refinish_blueprint.materials[c_mat_id] = {
                    color_idx = e.color_idx,
                    mat_value = base.value,
                    adj_name = c_adj,
                    base_metal_id = base.id
                }
                name_owner[c_adj] = c_mat_id
                color_mats_created = color_mats_created + 1
            end

            local c_rxn_id = string.format("REFINISH_STEEL_RXN_COLOUR_%s_%s",
                                           base.id, e.mat_id)
            _G.refinish_blueprint.reactions[c_rxn_id] = {
                name = c_adj .. " (" .. string.lower(e.solid_name) .. " dust)",
                reagent_id = e.mat_id,
                base_metal_id = base.id,
                dust_code = string.lower(e.solid_name) .. " dust",
                output_mat_id = c_mat_id,
                category = "REFINISH_STEEL_CAT_BASE_" .. base.id .. "_COLOUR_" .. e.class
            }
        else
            -- No descriptor index resolved, so there is no colour to
            -- name the finish after. Counted and skipped rather than
            -- minted with an out of range state_color, which is what
            -- the old scanner did on this path.
            colourless = colourless + 1
        end
        -- The guard above lands here: skip this reagent, keep going.
        ::next_colour::
    end

    -- ---- ROUTINE B: SPECIFIC FINISH ----
    for _, e in ipairs(intake) do
        if perf_setting == 'ON' or SPECIAL_FINISH[e.mat_id] then
            local word  = finish_word(e)
            local s_adj = word .. " " .. base.name

            -- WORLD NAME GUARD, the same rule as the colour side.
            local s_owner = world_names[string.lower(s_adj)]
            if s_owner then
                note_conflict(base.id, s_adj, s_owner)
                goto next_specific
            end

            -- A reagent whose finish word IS its own colour name has
            -- nothing to add: the colour reaction above already makes
            -- a material of that name from this exact dust, so a
            -- second identical entry would only pad the menu.
            if s_adj ~= (e.color_name .. " " .. base.name) then
                local s_mat_id = name_owner[s_adj]

                if not s_mat_id then
                    -- Value is conserved only where the name points
                    -- at a single recipe. Shared names take the base
                    -- metal's value, because one material cannot hold
                    -- three reagents' worth.
                    local shared = (finish_takers[word] or 1) > 1
                    local val = base.value
                    if not shared then
                        if e.class == "GEM" then
                            val = base.value + e.reagent_val
                        elseif e.class == "METAL" then
                            val = base.value + math.floor(e.reagent_val / 3)
                        elseif e.class == "STONE" then
                            val = base.value + math.floor(e.reagent_val / 12)
                        end
                    else
                        shared_finishes = shared_finishes + 1
                    end

                    -- Keyed on the FINISH, not the reagent, so every
                    -- taker of a shared name lands on the same id no
                    -- matter which one the loop reaches first.
                    s_mat_id = string.format("REFINISH_STEEL_MAT_SPECIFIC_%s_%s",
                                             base.id, id_token(word))

                    _G.refinish_blueprint.materials[s_mat_id] = {
                        color_idx = e.color_idx,
                        mat_value = val,
                        adj_name = s_adj,
                        base_metal_id = base.id
                    }
                    name_owner[s_adj] = s_mat_id
                    specific_mats_created = specific_mats_created + 1
                end

                local s_rxn_id = string.format("REFINISH_STEEL_RXN_SPECIFIC_%s_%s",
                                               base.id, e.mat_id)
                _G.refinish_blueprint.reactions[s_rxn_id] = {
                    name = s_adj .. " (" .. string.lower(e.solid_name) .. " dust)",
                    reagent_id = e.mat_id,
                    base_metal_id = base.id,
                    dust_code = string.lower(e.solid_name) .. " dust",
                    output_mat_id = s_mat_id,
                    category = "REFINISH_STEEL_CAT_BASE_" .. base.id .. "_MAT_" .. e.class
                }
            end
        end
        -- The guard above lands here: skip this reagent, keep going.
        ::next_specific::
    end
end

local total_rejected = rej_type + rej_phase + rej_value + rej_ghost
log('DETAIL', string.format('Intake complete. %d reagents accepted, %d'
    .. ' rejected (Type: %d, Phase: %d, Value: %d, Ghost Metal: %d).',
    valid_reagents, total_rejected, rej_type, rej_phase, rej_value,
    rej_ghost), 'INTAKE')

-- ==========================================
-- WORLD NAME GUARD REPORT
-- ==========================================
-- One line per skipped finish, with the base metal as its subject.
-- INFO rather than a fault: nothing failed, the guard did its job,
-- and the line exists so the gap in the menu explains itself.
for _, s in ipairs(skipped_list) do
    log('INFO', string.format("Finish '%s' not minted: the name already"
        .. ' belongs to %s. Skipped with every reaction into it.',
        s.name, s.owner), s.base)
end

-- ==========================================
-- UI DICTIONARY CACHE (O(1) LOOKUPS FOR HUD)
-- ==========================================
_G.refinish_blueprint.ui_dict = { 
    metal_names = {}, 
    ore_map = {}, 
    finish_counts = {}
}

for _, inorg in ipairs(inorganics) do
    local raw_name = inorg.material.state_name[0] or inorg.id
    local clean_name = raw_name:gsub("_", " "):gsub("(%S+)", function(word)
        return word:sub(1,1):upper() .. word:sub(2):lower()
    end)
    _G.refinish_blueprint.ui_dict.metal_names[inorg.id] = clean_name

    if inorg.metal_ore and inorg.metal_ore.mat_index then
        for _, target_idx in ipairs(inorg.metal_ore.mat_index) do
            local target_mat = inorganics[target_idx]
            if target_mat then _G.refinish_blueprint.ui_dict.ore_map[target_mat.id] = true end
        end
    end
end

for _, rxn in pairs(_G.refinish_blueprint.reactions) do
    local base = rxn.base_metal_id
    if base then
        _G.refinish_blueprint.ui_dict.finish_counts[base] = (_G.refinish_blueprint.ui_dict.finish_counts[base] or 0) + 1
    end
end

-- ==========================================
-- CIV TECH (FROM BOOT CACHE)
-- ==========================================
-- Boot's Pass 4 already evaluated every civilization's tech capabilities
-- and cached the results in _G.refinish_civ_tech. We copy it into the
-- blueprint so downstream consumers (index-entity, panel-civs, etc.)
-- find it in the expected location.
-- ==========================================
_G.refinish_blueprint.civ_tech = _G.refinish_civ_tech or {}

local total_mats = color_mats_created + specific_mats_created
log('DETAIL', string.format('Scan complete. Mapped %d reagents across %d'
    .. ' bases to %d materials (%d colour, %d specific, %d shared'
    .. ' finishes, %d colourless).', valid_reagents, #active_bases,
    total_mats, color_mats_created, specific_mats_created, shared_finishes,
    colourless), 'SCAN')