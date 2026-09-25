-- refinish-index-reaction.lua
-- ==========================================
-- SCRIPT LOGIC: REACTION & CATEGORY BUILDER
-- ==========================================

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
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'INDEX_REACTIONS'
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

log('DETAIL', 'Reaction and category injection initiated.')

-- STATE MANAGER: Deep RAM Verification
if _G.refinish_reactions_loaded == nil or _G.refinish_reactions_loaded == false then
    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        if string.find(rxn.code, "REFINISH_STEEL_RXN_") then
            _G.refinish_reactions_loaded = true
            break
        end
    end
end

if _G.refinish_reactions_loaded then
    log('DETAIL', 'Reactions already indexed. Skipping.')
    return
end

local reactions_array = df.global.world.raws.reactions.reactions
local cat_array = df.global.world.raws.reactions.reaction_categories

if not _G.refinish_blueprint or not _G.refinish_blueprint.reactions then
    log('ERROR', 'Blueprint missing, so no refinish reactions were built.'
        .. ' refinish-scan has to run first.')
    return
end

-- ==========================================
-- 1. DYNAMIC CATEGORY INJECTION (DEPTH MAPPED)
-- ==========================================

-- PRE-BUILD: Snapshot every category ID already in the live array ONCE
-- before we start injecting. This replaces the O(N) linear scan that the
-- old inject_category did on every single call, which grew more expensive
-- with every category added during the same loop.
local existing_cats = {}
for _, c in ipairs(cat_array) do
    existing_cats[c.id] = true
end

local function inject_category(id, name, parent)
    -- O(1) hash lookup instead of O(N) array scan
    if existing_cats[id] then return end
    
    local c = df.reaction_category:new()
    c.id = id
    c.name = name
    c.parent = parent or ""
    cat_array:insert('#', c)
    
    -- Keep the set current so duplicate IDs within the
    -- same injection batch are also caught correctly
    existing_cats[id] = true
end

local pending_cats = {}
for _, cat_data in pairs(_G.refinish_blueprint.categories) do
    table.insert(pending_cats, cat_data)
end

-- ==========================================
-- THE FIX: DEPTH-FIRST TREE FLATTENER
-- Eliminates arbitrary name/tier sorting. Uses pure ID/Parent relationships
-- to feed categories to the engine in a contiguous state-machine order.
-- ==========================================
local cat_map = {}
local root_cats = {}

-- 1. Index everything by ID
for _, cat in ipairs(pending_cats) do
    cat_map[cat.id] = cat
    cat.children = {}
end

-- 2. Build the exact family tree
for _, cat in ipairs(pending_cats) do
    if cat.parent == "" or not cat_map[cat.parent] then
        table.insert(root_cats, cat)
    else
        table.insert(cat_map[cat.parent].children, cat)
    end
end

-- 3. Recursively sort siblings alphabetically by ID
local function sort_children(node)
    table.sort(node.children, function(a, b) return a.id < b.id end)
    for _, child in ipairs(node.children) do
        sort_children(child)
    end
end
table.sort(root_cats, function(a, b) return a.id < b.id end)
for _, root in ipairs(root_cats) do
    sort_children(root)
end

-- 4. Flatten the tree Depth-First so parents are immediately followed by their lineages
local sorted_cats = {}
local function flatten(node)
    table.insert(sorted_cats, node)
    for _, child in ipairs(node.children) do
        flatten(child)
    end
end
for _, root in ipairs(root_cats) do
    flatten(root)
end

pending_cats = sorted_cats

-- Inject cleanly contiguous lineage
for _, cat in ipairs(pending_cats) do
    inject_category(cat.id, cat.name, cat.parent)
end

-- ==========================================
-- 2. TEMPLATE ACQUISITION (FROM BOOT CACHE)
-- ==========================================
-- Boot ran the metal-making and dust-making evaluators at startup
-- and cached the highest-scoring templates in _G. We pull those
-- cached results here instead of re-scanning every loaded reaction.
--
-- The evaluators score candidates on structural criteria (building
-- type, skill, reagent/product shapes, fuel flags) and pick the
-- best match. This is a scored selection, not a first-match grab.
--
-- The cached tables contain:
--   _G.refinish_best_metal_template:
--     .reaction  = the df.reaction object
--     .rgt_idx   = index of the inorganic bar reagent
--     .prod_idx  = index of the inorganic bar product
--     .code, .score
--
--   _G.refinish_best_dust_template:
--     .reaction  = the df.reaction object
--     .bag_idx   = index of the bag reagent
--     .prod_idx  = index of the powder product
--     .code, .score
-- ==========================================
local metal_rxn = nil
local metal_rgt_idx = -1
local metal_prod_idx = -1

local powder_rxn = nil
local powder_bag_idx = -1
local powder_prod_idx = -1

local inorganics = df.global.world.raws.inorganics.all

-- Pull from boot cache
local metal_cache = _G.refinish_best_metal_template
local dust_cache = _G.refinish_best_dust_template

if metal_cache and metal_cache.reaction then
    metal_rxn = metal_cache.reaction
    metal_rgt_idx = metal_cache.rgt_idx
    metal_prod_idx = metal_cache.prod_idx
end

if dust_cache and dust_cache.reaction then
    powder_rxn = dust_cache.reaction
    powder_bag_idx = dust_cache.bag_idx
    powder_prod_idx = dust_cache.prod_idx
end

if not metal_rxn or not powder_rxn then
    log('ERROR', string.format('Missing cached engine templates (metal: %s,'
        .. ' powder: %s), so no refinish reactions were built.',
        tostring(metal_rxn ~= nil), tostring(powder_rxn ~= nil)), 'TEMPLATES')
    return
else
    log('DETAIL', string.format('Cached shells acquired. Metal: %s (R:%d,'
        .. ' P:%d) | Powder: %s (R:%d, P:%d)', metal_rxn.code, metal_rgt_idx,
        metal_prod_idx, powder_rxn.code, powder_bag_idx, powder_prod_idx),
        'TEMPLATES')
end

-- Build the Virtual Template from the dynamically acquired metal reaction
local template_rxn = df.reaction:new()
template_rxn:assign(metal_rxn)

template_rxn.code = "VIRTUAL_REFINISH_TEMPLATE"
template_rxn.name = "virtual refinish template"

-- THE FIX: Hardcode the fuel flag to true so all finishes demand fuel. 
-- The engine will automatically ignore this flag if the task is run at a Magma Forge.
template_rxn.flags.FUEL = true

local SAFE_INDEX = 0
for i, mat in ipairs(inorganics) do
    if mat.id == "STEEL" then SAFE_INDEX = i; break end
end

-- ==========================================
-- REAGENTS (Synthesized from Dynamic Shells)
-- ==========================================
template_rxn.reagents:resize(0)

-- 1. The Input Bar (Cloned from the dynamically found metal reagent)
local r_steel = df.reaction_reagent_itemst:new()
r_steel:assign(metal_rxn.reagents[metal_rgt_idx]) 
r_steel.code = "steel_bar"
r_steel.quantity = 450 -- Adjusted to standard 150 bar volume based on probe
r_steel.min_dimension = -1 
r_steel.mat_type = 0
r_steel.mat_index = SAFE_INDEX 
template_rxn.reagents:insert('#', r_steel)

-- 2. The Dust (Synthesized into true Powder)
local r_dust = df.reaction_reagent_itemst:new()
r_dust:assign(metal_rxn.reagents[metal_rgt_idx]) -- Clone the basic item shape
r_dust.code = "dust"
r_dust.item_type = 70 -- PROBE TRUTH: 70 is POWDER_MISC
r_dust.quantity = 150 -- PROBE TRUTH: Powders use 150 qty
r_dust.min_dimension = -1 
r_dust.mat_type = 0
r_dust.mat_index = -1 

-- THE MISSING LINK: The powder MUST be flagged to accept containers
r_dust.flags.IN_CONTAINER = true 

template_rxn.reagents:insert('#', r_dust)

-- 3. THE BAG (Cloned from the dynamically found bag reagent)
local r_bag = df.reaction_reagent_itemst:new()
r_bag:assign(powder_rxn.reagents[powder_bag_idx])
r_bag.code = "dust_bag"

-- Nuke the EMPTY bitfield so the bag is allowed to contain our dust
r_bag.flags1.empty = false

r_bag.contains:resize(0)
r_bag.contains:insert('#', 1) -- Points exactly to Reagent [1] (Our Dust)
template_rxn.reagents:insert('#', r_bag)

-- ==========================================
-- PRODUCTS 
-- ==========================================
template_rxn.products:resize(0)
local p_bar = df.reaction_product_itemst:new()
p_bar:assign(metal_rxn.products[metal_prod_idx])
p_bar.count = 3 -- 3 standard bars
p_bar.product_dimension = 150 -- 150 volume per bar
p_bar.mat_type = 0
p_bar.mat_index = -1 
template_rxn.products:insert('#', p_bar)

-- 3. INORGANIC LOOKUP TABLE
local inorganics = df.global.world.raws.inorganics.all
local mat_lookup = {}
for i, mat in ipairs(inorganics) do
    mat_lookup[mat.id] = i
end

-- ==========================================
-- 4. BUILD THE DYNAMIC COLOUR REACTIONS
-- ==========================================
local count = 0

local pending_rxns = {}
for rxn_id, data in pairs(_G.refinish_blueprint.reactions) do
    table.insert(pending_rxns, { id = rxn_id, data = data })
end

-- Sort reactions so they are cleanly clumped by category in memory
table.sort(pending_rxns, function(a, b)
    if a.data.category == b.data.category then
        return a.id < b.id
    end
    return a.data.category < b.data.category
end)

for _, item in ipairs(pending_rxns) do
    local rxn_id = item.id
    local data = item.data

    local reagent_idx = mat_lookup[data.reagent_id]
    local output_idx = mat_lookup[data.output_mat_id]
    
    -- NEW BREADCRUMB LOOKUP: Find the correct input bar index
    local base_idx = mat_lookup[data.base_metal_id]

    if reagent_idx and output_idx and base_idx then
        local m = df.reaction:new()
        m:assign(template_rxn)

        m.code = rxn_id
        m.name = data.name
        m.category = data.category

        m.reagents:resize(0) 
        for _, orig_rgt in ipairs(template_rxn.reagents) do
            local new_rgt = df.reaction_reagent_itemst:new()
            new_rgt:assign(orig_rgt)
            
            if new_rgt.item_type == df.item_type.POWDER_MISC then
                new_rgt.mat_type = 0
                new_rgt.mat_index = reagent_idx
                local dust_string = data.dust_code or "dust"
                new_rgt.code = dust_string
                
            -- Swap the input bar to the user's selected base metal
            elseif new_rgt.code == "steel_bar" then
                new_rgt.mat_index = base_idx
                new_rgt.code = string.lower(data.base_metal_id) .. "_bar"
            end
            
            m.reagents:insert('#', new_rgt)
        end

        m.products:resize(0)
        for _, orig_prod in ipairs(template_rxn.products) do
            local new_prod = df.reaction_product_itemst:new()
            new_prod:assign(orig_prod)
            
            if new_prod.item_type == df.item_type.BAR then
                new_prod.mat_type = 0
                new_prod.mat_index = output_idx
            end
            
            m.products:insert('#', new_prod)
        end

        reactions_array:insert('#', m)
        m.index = #reactions_array - 1 
        reactions_array[#reactions_array - 1].flags.FUEL = true
        count = count + 1
    else
        -- A finish option missing from the menu, so worth a WARNING. The
        -- reaction id is too long for the subject column, so it rides in
        -- the body and the base metal is the subject.
        log('WARNING', 'Reaction ' .. rxn_id .. ' not built: a material'
            .. ' index is missing (reagent ' .. tostring(data.reagent_id)
            .. ', output ' .. tostring(data.output_mat_id) .. ').',
            tostring(data.base_metal_id))
    end
end

-- ==========================================
-- 5. LUA-GENERATED GRINDERS
-- ==========================================
local function build_grinder(code, name, skill, bld_type, bld_subtypes, item_type, qty, prod_count, is_worthless, requires_fuel)
    local rxn = df.reaction:new()
    rxn:assign(powder_rxn) -- The dynamic powder shell
    
    rxn.code = code
    rxn.name = name
    rxn.skill = skill
    rxn.category = ""
    pcall(function() rxn.flags.FORTRESS_MODE_ENABLED = true end)
    
    rxn.flags.FUEL = requires_fuel or false

    -- Reprogram Building
    rxn.building.type:resize(0)
    rxn.building.subtype:resize(0)
    rxn.building.custom:resize(0)
    for _, st in ipairs(bld_subtypes) do
        rxn.building.type:insert('#', bld_type)
        rxn.building.subtype:insert('#', st)
        rxn.building.custom:insert('#', -1)
    end

    -- DEEP COPY: Reagents & Products
    rxn.reagents:resize(0)

    -- Reagent 0: The Input Item
    local r_in = df.reaction_reagent_itemst:new()
    r_in:assign(metal_rxn.reagents[metal_rgt_idx]) -- Use a clean base item to overwrite
    r_in.code = "input"
    r_in.quantity = qty
    r_in.item_type = item_type
    r_in.item_subtype = -1
    r_in.mat_type = 0   -- INORGANIC
    r_in.mat_index = -1 -- ANY
    
    -- Safely strip classes just in case
    r_in.reaction_class = ""
    rxn.reagents:insert('#', r_in)

    -- Reagent 1: The Bag
    local r_bag = df.reaction_reagent_itemst:new()
    r_bag:assign(powder_rxn.reagents[powder_bag_idx])
    r_bag.code = "bag"
    rxn.reagents:insert('#', r_bag)

    -- Product 0: The Output Dust
    rxn.products:resize(0)
    local p_out = df.reaction_product_itemst:new()
    p_out:assign(powder_rxn.products[powder_prod_idx])
    p_out.count = prod_count
    p_out.mat_type = -1
    p_out.mat_index = -1
    
    -- Exact mapped paths
    p_out.product_to_container = "bag"
    p_out.flags.GET_MATERIAL_SAME = true
    p_out.get_material.reagent_code = "input"
    
    rxn.products:insert('#', p_out)

    -- Insert the complete reaction into the live global array
    rxn.index = #reactions_array
    reactions_array:insert('#', rxn)

    -- Write the static C++ bitfield directly to the live memory pointer
    reactions_array[#reactions_array - 1].reagents[0].flags2.non_economic = is_worthless

end

-- Inject all 4 Grinders safely using exact ground-truth paths (Added Fuel Bool at the end)
-- 13/4 = Jeweler, 13/2 = Mason, 13/5 & 13/6 = Forge & Magma Forge
build_grinder("REFINISH_STEEL_RXN_LUA_GRIND_GEMS", "grind rough gems into dust", df.job_skill.CUTGEM, 13, {4}, df.item_type.ROUGH, 3, 1, false, false)
build_grinder("REFINISH_STEEL_RXN_LUA_GRIND_COMMON", "grind common stone into dust", df.job_skill.MASONRY, 13, {2}, df.item_type.BOULDER, 1, 4, true, false)
build_grinder("REFINISH_STEEL_RXN_LUA_GRIND_ANY", "grind any stone into dust", df.job_skill.MASONRY, 13, {2}, df.item_type.BOULDER, 1, 4, false, false)
build_grinder("REFINISH_STEEL_RXN_LUA_GRIND_METAL", "grind metal bars into dust", df.job_skill.METALCRAFT, 13, {5, 6}, df.item_type.BAR, 150, 1, false, false)

_G.refinish_reactions_loaded = true

log('DETAIL', 'Reaction injection complete: ' .. count .. ' refinish'
    .. ' reactions added, plus the four grinders.')