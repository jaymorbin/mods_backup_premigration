--@ module = true
-- refinish-module-inject-plant.lua
-- ==========================================
-- RM MODULE PLANT INJECTION
-- ==========================================
local types = reqscript('refinish-module-types')
local clone_eval = reqscript('refinish-evaluate-clone-source')

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
-- SUBJECT is the correlation slot: the module a line is about. Nil
-- renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'INJECT_PLANT'
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

local function has_prefix(str, prefix)
    return string.sub(str, 1, #prefix) == prefix
end

-- ==========================================
-- NEUTRAL RESET
-- ==========================================
-- A deep copy of a plant_raw brings over its string anatomy,
-- growth behaviors, and tree metrics. We must scrub the semantic
-- data while leaving the C++ vectors and pointers intact.
local function apply_neutral_reset(plant)
    -- 1. Wipe all bitfield flags (Spring, Biomes, Tree, Mill, etc.)
    for i = 0, #plant.flags - 1 do
        plant.flags[i] = false
    end

    -- 2. Clear anatomical strings
    plant.root_name = ""
    plant.trunk_name = ""
    plant.heavy_branch_name = ""
    plant.light_branch_name = ""
    plant.twig_name = ""
    plant.cap_name = ""

    -- 3. Reset basic tree/shrub metrics
    plant.trunk_period = 0
    plant.heavy_branch_density = 0
    plant.light_branch_density = 0
    plant.max_trunk_height = 0
    plant.heavy_branch_radius = 0
    plant.light_branch_radius = 0
    
    -- 4. General identity wipes
    -- The prefstring vector contains std::string objects, so resizing to 0 is safe.
    plant.prefstring:resize(0) 

    -- ==========================================
    -- NEW: THE DEEP-COPY HAZARDS
    -- ==========================================
    
    -- 5. Sever the Growths Vector (Leaves, Fruit, Flowers, Nuts)
    -- Because assign() shallow-copied the vector of pointers, the clone and 
    -- donor share the same growths. We must clear the vector WITHOUT deleting 
    -- the underlying C++ objects, or we will corrupt the donor plant.
    -- Erasing the vector severs the link safely.
    if plant.growths then
        while #plant.growths > 0 do
            plant.growths:erase(#plant.growths - 1)
        end
    end

    -- 6. Zero out Biome & Spawn Rates
    -- If a donor is highly frequent in the wild, the clone will flood the map.
    plant.frequency = 0
    -- clustersize, one word. plant_object_map.txt is the authority:
    -- there is no cluster_size on plant_raw, and writing it throws,
    -- which killed the whole injection step before any plant landed.
    plant.clustersize = 0
    plant.underground_depth_min = 0
    plant.underground_depth_max = 0
    
    -- 7. The Raws Vector (Original Raw Text)
    -- DF stores a vector of string pointers representing the raw text used to 
    -- build the item. Like growths, this is shallow-copied. We clear it so 
    -- the clone doesn't echo the donor's raw text in debug dumps.
    if plant.raws then
        while #plant.raws > 0 do
            plant.raws:erase(#plant.raws - 1)
        end
    end
    
    -- NOTE ON INTERNAL MATERIALS (plant.materials)
    -- Do NOT empty the plant.materials vector. DF expects a plant to have 
    -- at least a basic structural material (usually at index 0). If you sever 
    -- the materials vector entirely, the plant will CTD when rendered. 
    -- RM's philosophy here is to let the clone keep the donor's materials 
    -- (e.g., structural, seed, drink) as safe, functional placeholders.
end

-- ==========================================
-- DONOR RESOLUTION
-- ==========================================
-- WHY THIS REPLACED THE CLONE EVALUATOR CALL
--
-- The old line was clone_eval.get_donor('PLANT', donor_class). That
-- function takes ONE argument, a class name, and looks it up in
-- _G.refinish_module_clone_cache, which the evaluator fills with
-- MATERIAL classes. So the call read the cache at the key 'PLANT',
-- found nothing, returned nil, and every plant logged "No valid
-- plant donor found" and injected nothing. That is why this file has
-- never produced a plant.
--
-- A plant donor is a plant, so it is taken from the plant raws
-- directly. Which one barely matters: apply_neutral_reset wipes the
-- clone's identity and apply_plant_materials below replaces its
-- materials outright, so the donor supplies a valid struct and
-- nothing else.
--
-- Deterministic by construction. world.raws.plants.all is built from
-- the raws in a fixed order, so the same donor is chosen every
-- session, which keeps injected plant indices stable across a
-- reload. A donor named explicitly on the definition wins, so a
-- module that needs a tree shaped host can say so.
-- ==========================================
local function resolve_donor(pd)
    local all = df.global.world.raws.plants.all

    -- 1. Named on the definition, by plant id.
    if pd.donor_plant then
        for _, pl in ipairs(all) do
            local ok, id = pcall(function() return pl.id end)
            if ok and id == pd.donor_plant then return pl, id end
        end
    end

    -- 2. The first plant carrying at least one material. A plant with
    -- none would leave the clone with nothing to template from and
    -- nothing to render, which is the crash the neutral reset's own
    -- note warns about.
    for _, pl in ipairs(all) do
        local n = 0
        pcall(function() n = #pl.material end)
        if n > 0 then
            local id = '?'
            pcall(function() id = pl.id end)
            return pl, id
        end
    end

    return nil, nil
end

-- ==========================================
-- MATERIAL SUPPORT
-- ==========================================
-- WHY THIS EXISTS
--
-- A bar of an INORGANIC material displays as "charcoal bars". The
-- same bar of a PLANT material displays bare. Measured on one item
-- swapped across modes: the suffix belongs to the inorganic branch
-- of DF's item description code, and no flag, name or string
-- suppresses it. Material MODE is the only lever, so a module
-- wanting a bare bar name hosts its material on a plant.
--
-- THE DEEP COPY HAZARD, AND IT IS THIS FILE'S OWN HAZARD
--
-- The note at the end of apply_neutral_reset is right that the
-- materials vector must not be emptied, and it says the clone KEEPS
-- the donor's materials. Keeps, meaning SHARES: assign copied a
-- vector of POINTERS. Measured live, donor and clone material[0] are
-- one address. Writing a state name through it renames the donor's
-- material too, and the donor is a real plant somebody is farming.
--
-- So every material written here is a fresh df.material assigned
-- FROM the donor's as a template, and the shared entries are dropped
-- from the clone's vector without being deleted, exactly as growths
-- and raws are handled above. The donor is never touched.
--
-- SCHEMA, per plant, optional. A plant with no materials block keeps
-- the donor's shared placeholders and behaves exactly as before.
--
--   "materials": [
--     { "key": "CHARCOAL", "name": "charcoal",
--       "reaction_classes": ["FUEL", "FUEL_SMELTING", "CHARCOAL"],
--       "graphics": { "bar": { "donor": "BUILTIN:COAL", "offset": 0 },
--                     "texflag": "BUILTIN:COAL" },
--       "material_class": "SOIL", "value": 2 }
--   ]
--
-- The resulting token is PLANT_MAT:<PLANT ID>:<KEY>, so the plant's
-- own id carries the module prefix and the key does not repeat it.
-- ==========================================

-- The appliers live in refinish-module-inject.lua and are global for
-- this reason. Loaded lazily: a load time reqscript here would make
-- the inorganic injector a hard dependency of this file at scan
-- time, and a fault in either would take both down.
local function appliers()
    local ok, env = pcall(reqscript, 'refinish-module-inject')
    if ok and env and env.apply_display_name then return env end
    return nil
end

-- ---- PREFIX IS THE POINT ----
-- Display is prefix plus state_name when prefix is non-empty, and
-- state_name alone when it is blank. Measured: a wheat STRUCTURAL
-- bar reads "single-grain wheat plant", prefix plus state name, no
-- suffix. A donor's material carries the donor's prefix, so a cloned
-- material left alone reintroduces the exact bug this path exists to
-- fix. It is written blank EXPLICITLY rather than trusted to be.
local function apply_plant_materials(plant, pd, mod_name)
    local defs = pd.materials
    if not defs or #defs == 0 then return 0 end

    local A = appliers()
    if not A then
        log('ERROR', string.format('refinish-module-inject is unavailable,'
            .. " so plant materials cannot be named. Plant '%s' keeps the"
            .. " donor's materials.", tostring(plant.id)), mod_name)
        return 0
    end

    -- The donor's first material, used ONLY as a template to copy
    -- from. Nothing is ever written through it.
    local template = plant.material[0]
    if not template then return 0 end

    -- Drop the shared entries. erase, never delete: these objects
    -- belong to the donor plant and outlive this clone.
    while #plant.material > 0 do
        plant.material:erase(#plant.material - 1)
    end

    local made = 0
    for _, md in ipairs(defs) do
        local m = df.material:new()
        m:assign(template)

        -- assign copied the template's vectors of string POINTERS by
        -- reference. Dropped here before anything repopulates them,
        -- because a definition declaring no reaction classes would
        -- otherwise silently inherit the donor's.
        pcall(function() m.reaction_class:resize(0) end)
        pcall(function()
            local rp = m.reaction_product
            rp.id:resize(0)
            rp.item_type:resize(0)
            rp.item_subtype:resize(0)
            rp.material.mat_type:resize(0)
            rp.material.mat_index:resize(0)
        end)

        -- Every flag off. A food crop donor brings EDIBLE_RAW,
        -- ALCOHOL and friends, and charcoal must not be any of them.
        -- Measured: material.flags has 88 entries and both reads and
        -- writes by index, the same shape as the plant flags above.
        pcall(function()
            for i = 0, #m.flags - 1 do m.flags[i] = false end
        end)

        -- Identity. prefix blank, explicitly. See the note above.
        m.id     = tostring(md.key)
        m.prefix = ""

        pcall(function() A.apply_display_name(m, md.name, md.names) end)
        pcall(function() A.apply_class_preset(m, md.material_class) end)
        -- apply_color wants a RESOLVED spec. Passing the raw def
        -- silently wrote the default ANSI and every plant material
        -- came out bare gray, because spec.solid and spec.display
        -- were both nil. The inorganic path resolves first; so does
        -- this one now.
        -- apply_color wants a RESOLVED spec, and it reads two
        -- different things. `solid` is a descriptor INDEX, the colour
        -- word used in text. `display` and `build` are ANSI triples
        -- and they are what actually tints the item on screen. The
        -- inorganic path builds this table from def.display_color and
        -- def.build_color; nothing resolves those, so they are passed
        -- through as declared.
        --
        -- Missing display means DEFAULT_ANSI, which is plain gray.
        -- That is invisible on a material with real bar art and very
        -- visible on one wearing a tinted boulder mask.
        pcall(function()
            A.apply_color(m, {
                solid   = A.resolve_color(md.color, md.fallback_colors),
                display = md.display_color,
                build   = md.build_color,
            })
        end)
        -- Dye colour, once the class preset has set the flags. Plant
        -- materials take no material_flags overrides, so the preset
        -- is the only source of IS_DYE on this path.
        pcall(function() A.apply_dye_color(m, md, tostring(md.key)) end)
        pcall(function() A.apply_heat(m, md.heat) end)
        pcall(function() A.apply_strength(m, md.strength) end)
        pcall(function() A.apply_reaction_classes(m, md.reaction_classes) end)
        if md.value then
            pcall(function() m.material_value = md.value end)
        end
        if md.solid_density then
            pcall(function() m.solid_density = md.solid_density end)
        end
        if md.graphics then
            pcall(function()
                A.apply_graphics(m, md.graphics, tostring(md.key))
            end)
        end

        plant.material:insert('#', m)
        made = made + 1
    end

    return made
end

-- ==========================================
-- PUBLIC: INJECT PLANTS
-- ==========================================
function inject_plants(plants_defs, prefix, mod_name)
    local raws = df.global.world.raws.plants.all
    local count = 0

    if not plants_defs or #plants_defs == 0 then return 0 end

    for _, pd in ipairs(plants_defs) do
        local full_id = prefix .. pd.key
        
        local donor, donor_id = resolve_donor(pd)

        if donor then
            local new_plant = df.plant_raw:new()
            new_plant:assign(donor)
            
            -- Set Identity
            new_plant.id = full_id
            if pd.name then new_plant.name = pd.name end
            if pd.name_plural then new_plant.name_plural = pd.name_plural end
            
            -- WIPE the donor's semantic identity
            apply_neutral_reset(new_plant)

            -- OVERRIDE from schema
            if pd.plant_flags then
                for json_key, state in pairs(pd.plant_flags) do
                    local ok = pcall(function()
                        new_plant.flags[json_key] = state
                    end)
                    if not ok then
                        log('WARNING', string.format("Invalid plant flag '%s' on"
                            .. " '%s'.", tostring(json_key), tostring(full_id)),
                            mod_name)
                    end
                end
            end

            -- Materials LAST, after the neutral reset and the flag
            -- overrides, because the reset works on the plant and this
            -- works on the materials hanging off it. Ordered this way
            -- so a future reset touching materials cannot undo names
            -- written before it ran.
            apply_plant_materials(new_plant, pd, mod_name)

            -- Inject into Global Vector
            raws:insert('#', new_plant)
            count = count + 1
        else
            log('ERROR', string.format('No plant in the raws could serve as a'
                .. " donor for '%s'. Every plant carries zero materials,"
                .. ' which should be impossible in a loaded world.',
                tostring(full_id)), mod_name)
        end
    end

    return count
end

-- ==========================================
-- CLEANUP: THE HOTSAVE PROTOCOL
-- ==========================================
function clear_plants(prefix)
    local raws = df.global.world.raws.plants.all
    local count = 0

    for i = #raws - 1, 0, -1 do
        local p = raws[i]
        local ok, id = pcall(function() return p.id end)
        
        if ok and has_prefix(id, prefix) then
            raws:erase(i)
            p:delete()
            count = count + 1
        end
    end
    return count
end

function plants_physically_clear(prefix)
    local raws = df.global.world.raws.plants.all
    for _, p in ipairs(raws) do
        local ok, id = pcall(function() return p.id end)
        if ok and has_prefix(id, prefix) then return false end
    end
    return true
end

return _ENV