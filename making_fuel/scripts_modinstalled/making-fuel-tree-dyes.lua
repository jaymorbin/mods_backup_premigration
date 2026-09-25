--@ module = true
-- making-fuel-tree-dyes.lua
-- ==========================================
-- MAKING FUEL: TREE BARK DYES, GENERATED AT THE TOKEN CALL
-- ==========================================
-- Every tree in the world gets a bark dye at the Dyer's Shop, in the
-- Make dye folder beside vanilla's own.
--
-- ==========================================
-- WHAT IS MADE, PER TREE (Jay's decisions, 2026-09-23)
-- ==========================================
-- A tree is any plant with a WOOD material, which is exactly the set
-- that has logs (abaca and banana have none and are left out).
--
--   Own vanilla BARK_DYE (acacia, alder, apple ...): vanilla already
--   makes it from a log ("make acacia bark dye", reaction_dyes.txt),
--   so only the BARK route is added, making that same vanilla dye.
--
--   No bark dye of its own: a new dye material, plus a LOG route and a
--   BARK route that both make it.
--
-- The log route is vanilla's recipe exactly: 1 log of that tree and an
-- empty bag, at the Dyer's Shop, Plant Processing, into Make dye. The
-- bark route takes 2 bark of that tree instead of the log. Bark is a
-- byproduct of other jobs, so it is a bonus source on top of logs,
-- used directly with no grinding step.
--
-- Both rows carry vanilla's name, "make <tree> bark dye"; the
-- requirement line tells log from bark.
--
-- ==========================================
-- COLOUR
-- ==========================================
-- The five trees with a documented bark dye take that colour
-- (OVERRIDES below, sources in making_fuel_tree_dye_research.md).
-- Every other tree takes its own WOOD colour, read from the live
-- material, so a tree added or recoloured by another mod gets a dye in
-- its own colour with nothing written for it.
--
-- ==========================================
-- WHERE THE DYES LIVE, AND WHY IT IS GENERATED HERE
-- ==========================================
-- The new dyes are plant materials on their own host plant,
-- TREE_DYE_HOST, built here and handed to RM with the module's JSON
-- data, the same way making_fuel.lua hands over the hide materials:
--   - plant materials, because that is the only way a powder is both
--     listed by name and hauled (RM_Organic_Category_Registration.md,
--     5b); making-fuel-dye-stock.lua registers them like the others;
--   - handed over as data, so RM validates, injects and sweeps them
--     with everything else in one pass: no cleanup code, and they are
--     in RAM before the first tick like every JSON material;
--   - a host of their own, so a change to the JSON dyes on DYE_HOST
--     never renumbers a generated one, or the reverse.
--
-- Generated in plants.all order, which is fixed for a world, so the
-- numbering is the same every session. KNOWN LIMIT: the ledger does
-- not yet cover plant materials, so a change to this generator's
-- output between sessions would renumber existing tree dyes. Jay has
-- asked for the ledger to cover plant materials.
--
-- The reactions name their materials by token (reagent mat_token,
-- refinish-module-react.lua). A token that does not resolve closes
-- that reagent slot and logs an ERROR, so a bad row cannot run.
--
-- ==========================================
-- BARK
-- ==========================================
-- Bark items are MAKING_FUEL_BARK tools made of their tree's WOOD. The
-- hijacker mints them from the value a wood job lost and gives them the
-- job's own feedstock material (waste_output, FORM VERSUS SUBSTANCE:
-- "a feather wood door gives feather wood bark"). The tinder watcher
-- does NOT move bark: its HOP_TOOLS are tinder and kindling only. So
-- the bark route names PLANT_MAT:<tree>:WOOD, the same material as the
-- log route, on a TOOL item instead of a log.
-- ==========================================

local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'TREE_DYES'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

local HOST_KEY      = 'TREE_DYE_HOST'
local BARK_TOOL     = 'MAKING_FUEL_BARK'
local LOGS_PER_DYE  = 1                        -- vanilla ACACIA_BARK_DYE
local BARK_PER_DYE  = 2

-- Plant material types run 419 to 618, so a plant holds at most 200.
local MAX_PLANT_MATERIALS = 200

-- Documented bark dye colours. Everything else uses its WOOD colour.
local OVERRIDES = {
    WALNUT    = 'DARK_BROWN',
    CASHEW    = 'BLACK',
    MANGO     = 'YELLOW',
    CANDLENUT = 'RUSSET',
    BAYBERRY  = 'LIGHT_BROWN',
}

-- Used only if the world holds no vanilla bark dye to copy from:
-- vanilla's PLANT_POWDER_TEMPLATE (material_template_default.txt),
-- NONE written as 60001.
local TEMPLATE_FALLBACK = {
    heat = { spec_heat = 800, melting_point = 60001, boiling_point = 60001,
             ignite_point = 10400, heatdam_point = 10500,
             colddam_point = 9900, mat_fixed_temp = 60001 },
    solid_density = 600,
    value = 20,
}

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
-- SUBJECT is the correlation slot: DATA, TEMPLATE, COLOUR, CAPACITY
-- or SUMMARY, the part of the generation a line is about.
--
-- This replaces a log() that took no subject and let refinish-log
-- guess TYPE from the words (read_type) unless a call site said
-- otherwise, and printed to the console when RM was not loaded.
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

local function try(fn, dflt)
    local ok, v = pcall(fn)
    if ok then return v end
    return dflt
end

-- A plant's material by id, or nil.
local function find_material(plant, id)
    local mats = try(function() return plant.material end)
    if not mats then return nil end
    for _, m in ipairs(mats) do
        if try(function() return m.id end) == id then return m end
    end
    return nil
end

-- ---- NAMES, AS VANILLA WRITES THEM ----
-- Vanilla's dye rows use the short tree name: "make apple bark dye",
-- not "apple tree". The plant's NAME carries "tree" ([NAME:apple tree])
-- and its materials carry PREFIX:NONE, so the short name is read off
-- the WOOD material's own name ([STATE_NAME:ALL_SOLID:apple wood]) with
-- " wood" taken off. A wood named without it ("tower-cap") is used
-- whole. Only if that fails does the plant name stand in, " tree"
-- dropped, and last of all the id in lower case.
local function short_name(plant, wood)
    local s = tostring(try(function() return wood.state_name.Solid end, '') or '')
    if s ~= '' then
        return s:match('^(.-) wood$') or s
    end
    local n = tostring(try(function() return plant.name end, '') or '')
    if n ~= '' then return (n:gsub(' tree$', '')) end
    return tostring(try(function() return plant.id end, '?')):lower()
end

-- A material's own display name (its solid state name), or nil. A
-- vanilla bark dye is named in full in the raws ("apple bark dye"), so
-- the bark route over it takes that name as it is.
local function display_name(m)
    local s = m and try(function() return m.state_name.Solid end)
    if s and tostring(s) ~= '' then return tostring(s) end
    return nil
end

-- Descriptor colour id for an index, or nil.
local function color_id(idx)
    return try(function() return df.global.world.raws.descriptors.colors[idx].id end)
end

local function color_exists(id)
    local found = false
    pcall(function()
        for _, c in ipairs(df.global.world.raws.descriptors.colors) do
            if c.id == id then found = true break end
        end
    end)
    return found
end

-- Keys are upper case, letters, digits and underscores.
local function key_part(id)
    return (tostring(id):upper():gsub('[^A-Z0-9_]', '_'))
end

-- One duplicated reaction key rejects the WHOLE module (engine-
-- learnings), and two plant ids can clean to the same key part, so
-- every key is made unique before it is used.
local function unique(used, base)
    local k, n = base, 1
    while used[k] do
        n = n + 1
        k = base .. '_' .. n
    end
    used[k] = true
    return k
end

local function copy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

-- Physical numbers copied from the first vanilla bark dye in the world,
-- so a generated dye behaves exactly as vanilla's do.
local function bark_dye_template(prefix)
    local out = nil
    pcall(function()
        for _, p in ipairs(df.global.world.raws.plants.all) do
            if not tostring(p.id):find(prefix, 1, true) then
                local m = find_material(p, 'BARK_DYE')
                if m then
                    local h = m.heat
                    out = {
                        heat = { spec_heat = h.spec_heat, melting_point = h.melting_point,
                                 boiling_point = h.boiling_point, ignite_point = h.ignite_point,
                                 heatdam_point = h.heatdam_point, colddam_point = h.colddam_point,
                                 mat_fixed_temp = h.mat_fixed_temp },
                        solid_density = m.solid_density,
                        value = m.material_value,
                        from = tostring(p.id),
                    }
                    return
                end
            end
        end
    end)
    return out
end


-- ==========================================
-- REACTIONS
-- ==========================================
-- Every table is built fresh per reaction: nothing handed to RM is
-- shared, so nothing RM does to one definition can reach another.
local function bag_reagent()
    return { code = 'bag', type = 'BAG', quantity = 1,
             flags = { empty = true, preserve = true } }
end

local function reaction(key, name, reagent, product_token)
    return {
        key = key, name = name, category = 'MAKE_DYE',
        building = 'DYER', skill = 'PROCESSPLANTS', fuel = false,
        permissions = { mode = 'AUTO' },
        reagents = { reagent, bag_reagent() },
        products = { { type = 'POWDER_MISC', mat_token = product_token,
                       to_container = 'bag', count = 1, dimension = 150 } },
    }
end

local function log_reagent(tree_id)
    return { code = 'log', type = 'WOOD', quantity = LOGS_PER_DYE,
             mat_token = 'PLANT_MAT:' .. tree_id .. ':WOOD' }
end

-- Bark wears its tree's WOOD; see BARK in the header.
local function bark_reagent(tree_id)
    return { code = 'bark', type = 'TOOL', tool_id = BARK_TOOL, quantity = BARK_PER_DYE,
             mat_token = 'PLANT_MAT:' .. tree_id .. ':WOOD' }
end


-- ==========================================
-- GENERATE
-- ==========================================
-- plt_data and rxn_data are the module's loaded JSON tables; the host
-- plant is appended to plt_data.plants and the reactions to
-- rxn_data.reactions. prefix is the module prefix ('MAKING_FUEL_').
function generate(plt_data, rxn_data, prefix)
    if not plt_data or not rxn_data or not prefix then
        -- ERROR: no tree bark dyes at all this session.
        log('ERROR', 'no plant or reaction data to extend; tree bark dyes skipped.', 'DATA')
        return
    end
    plt_data.plants = plt_data.plants or {}
    rxn_data.reactions = rxn_data.reactions or {}

    local host_id = prefix .. HOST_KEY
    local tpl = bark_dye_template(prefix)
    if not tpl then
        tpl = TEMPLATE_FALLBACK
        log('WARNING', 'no vanilla bark dye to copy; the template fallback supplies heat, density and value.', 'TEMPLATE')
    end

    local mats, n_trees, n_own, n_new, n_override, n_capped, n_skipped = {}, 0, 0, 0, 0, 0, 0

    -- Every key already in the module, so none generated can clash.
    local used = {}
    for _, r in ipairs(rxn_data.reactions) do
        if r.key then used[r.key] = true end
    end

    for _, p in ipairs(df.global.world.raws.plants.all) do
        local pid = tostring(try(function() return p.id end, ''))
        if pid ~= '' and not pid:find(prefix, 1, true) then
            local wood = find_material(p, 'WOOD')
            if wood then
                n_trees = n_trees + 1
                local short = short_name(p, wood)
                local kp = key_part(pid)
                local own = find_material(p, 'BARK_DYE')

                if own then
                    -- ---- OWN VANILLA DYE: BARK ROUTE ONLY ----
                    -- Named exactly as vanilla's log row for the same dye.
                    n_own = n_own + 1
                    local row_name = 'make ' .. (display_name(own) or (short .. ' bark dye'))
                    table.insert(rxn_data.reactions, reaction(unique(used, 'BARK_DYE_' .. kp .. '_BARK'),
                        row_name, bark_reagent(pid), 'PLANT_MAT:' .. pid .. ':BARK_DYE'))

                elseif #mats >= MAX_PLANT_MATERIALS then
                    n_capped = n_capped + 1

                else
                    -- ---- NEW DYE: MATERIAL, LOG ROUTE, BARK ROUTE ----
                    local color = OVERRIDES[pid]
                    if color and not color_exists(color) then
                        log('WARNING', string.format('override colour %s for %s is not a loaded'
                            .. ' descriptor; using its wood colour.', color, pid), 'COLOUR')
                        color = nil
                    end
                    if color then n_override = n_override + 1 end
                    if not color then
                        color = color_id(try(function() return wood.state_color.Solid end))
                    end
                    if not color then
                        n_skipped = n_skipped + 1
                        -- DETAIL: one per tree. The count after the loop is the WARNING,
                        -- so a world with many such trees does not fill Quiet.
                        log('DETAIL', 'no readable wood colour for ' .. pid .. '; no dye made.', 'COLOUR')
                    else
                        local key = unique(used, 'BARK_DYE_' .. kp)
                        local dye_name = short .. ' bark dye'
                        local row_name = 'make ' .. dye_name
                        mats[#mats + 1] = {
                            key = key, name = dye_name,
                            material_class = 'DYE', color = color,
                            value = tpl.value, heat = copy(tpl.heat),
                            solid_density = tpl.solid_density,
                        }
                        n_new = n_new + 1
                        local token = 'PLANT_MAT:' .. host_id .. ':' .. key
                        table.insert(rxn_data.reactions, reaction(unique(used, key .. '_LOG'),
                            row_name, log_reagent(pid), token))
                        table.insert(rxn_data.reactions, reaction(unique(used, key .. '_BARK'),
                            row_name, bark_reagent(pid), token))
                    end
                end
            end
        end
    end

    -- A plant with no materials is never handed over: the injector
    -- needs something to template from and render.
    if #mats > 0 then
        table.insert(plt_data.plants, {
            key = HOST_KEY, name = 'tree dye host', name_plural = 'tree dye hosts',
            plant_class = 'BASIC_CROP', plant_flags = {},
            materials = mats,
        })
    end

    log('DETAIL', string.format('%d trees: %d new bark dyes (%d by documented colour, the rest by wood'
        .. ' colour) with log and bark routes, %d with their own vanilla dye given a bark'
        .. ' route. Physical numbers from %s.',
        n_trees, n_new, n_override, n_own, tostring(tpl.from or 'the template fallback')), 'SUMMARY')
    if n_capped > 0 then
        log('ERROR', string.format('%d trees left without a dye: %s holds at most %d materials.',
            n_capped, host_id, MAX_PLANT_MATERIALS), 'CAPACITY')
    end
    if n_skipped > 0 then
        log('WARNING', string.format('%d trees skipped for want of a colour.', n_skipped), 'COLOUR')
    end
end

if dfhack_flags and dfhack_flags.module then return end
-- Typed at the console, the only answer is this one: printed, since it
-- is the direct response to what was typed.
print('making-fuel-tree-dyes is called by making_fuel.lua at the token call; it has no commands.')