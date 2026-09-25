-- refinish-ledger.lua
-- ==========================================
-- MATERIAL INDEX LEDGER
-- ==========================================
-- THE PROBLEM
--
-- Items, buildings and constructions store mat_type and mat_index.
-- They do not store material names. An index is only meaningful
-- against the exact inorganics array that produced it.
--
-- The array is rebuilt from scratch every load, in three bands:
--
--   [0 .. V-1]    vanilla, read from the save's raw folder
--   [V .. ]       module materials, injected at startup Step 2
--   [.. end]      core RM materials, injected at startup Step 4
--
-- Vanilla never moves. The two injected bands do, whenever a
-- module is installed, removed, or updated with a different
-- material count. Because core RM injects after modules, a change
-- in the module band shifts core RM as well.
--
-- WHY THE PAYLOAD IS NOT ENOUGH
--
-- refinish-save washes core RM objects to a vanilla index and
-- records their names, so refinish-load can restore them without
-- interpreting anything. That covers core RM under AUTOSAVE only.
-- It covers nothing under HOTSAVE, which never calls refinish-save
-- (refinish-autosave.lua:105 and :118), and it has never covered
-- module materials under either protocol.
--
-- COVERAGE
--
--   HOTSAVE   every object sits at an injected index, is in the
--             ledger, and is remapped here. refinish-load does not
--             run at all.
--
--   AUTOSAVE  core RM objects were washed to vanilla indices,
--             which are below the injected band and therefore
--             absent from the ledger. remap() skips them and
--             refinish-load restores them by name. Module objects
--             were never washed, so they are in the ledger and are
--             remapped here. The two passes touch disjoint sets.
--
-- DYE REFERENCES AND HISTORY
--
-- A dyed item stores its dye's material apart from its own, so a
-- cloth woven from plant fibre can carry a module dye's inorganic
-- index. World history stores materials too: a masterpiece and its
-- dye, the weapon in a death, a stolen item, the spike or rope in a
-- body abuse. All of these are references, like an item's own
-- index, not entries in a raws array. They may sit in the save
-- pointing at an injected index, and remap() moves them by name on
-- the next load, the same way. The fields are listed at DYE
-- REFERENCES and HISTORY EVENTS inside remap().
--
-- PLANT MATERIALS
--
-- RM also injects PLANT materials: a module's host plant (Making
-- Fuel's COAL_HOST, DYE_HOST, TREE_DYE_HOST) and materials a module
-- appends to a vanilla plant (the MAKING_FUEL_FUELWOOD twin on every
-- tree). A plant material is addressed by a PAIR: mat_type is 419
-- plus its position on the plant, mat_index is the plant's position
-- in plants.all. Either half moves when a module's plant list, or a
-- host's material list, changes. So the ledger also records every
-- owned plant material by name, "PLANT_ID|MAT_ID", against its pair,
-- and remap() moves stored pairs by name exactly as it moves
-- inorganic indices, everywhere it looks: items, constructions,
-- buildings, dye references and history.
--
-- Owned means either a material on a plant whose id carries an owned
-- prefix (a host, all of whose materials are the module's), or a
-- material whose own id carries one, wherever it hangs (a twin on a
-- vanilla tree). Vanilla's own plant materials never move and are
-- never recorded. A ledger written before this has no plant section,
-- and plant pairs are left alone that once.
--
-- CALL ORDER (refinish-startup)
--
--   Step 4    material injection, indices become final
--   Step 6.5  remap()   must run BEFORE refinish-load
--   Step 7    refinish-load, payload restore
--   Step 8    write()   snapshot for the next session
--
-- remap() runs before refinish-load because the payload restore
-- sets mat_index from names. Remapping afterwards would take
-- freshly correct indices and rewrite them against a stale ledger.
-- ==========================================

local json = require('json')


-- ==========================================
-- CONFIGURATION
-- ==========================================

-- Site data key. Sits alongside REFINISH_STEEL_PAYLOAD.
local LEDGER_KEY = "REFINISH_STEEL_LEDGER"

-- Core RM material id prefix. Module prefixes come from the live
-- registry at runtime.
local CORE_PREFIX = "REFINISH_STEEL_"

-- Plant material types: 419 plus the material's position on its plant,
-- 200 to a plant (DFHack MaterialInfo: PLANT_BASE, NUM_PLANT_MAT). Used
-- only to recognise a plant pair in a stored reference; every pair the
-- ledger RECORDS comes from dfhack.matinfo.find, never from this sum.
local PLANT_TYPE_LO, PLANT_TYPE_HI = 419, 618


-- ==========================================
-- HELPERS
-- ==========================================

-- Same test the module engine uses (refinish-module-engine.lua:81).
local function has_prefix(str, prefix)
    return string.sub(str, 1, #prefix) == prefix
end

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
-- SUBJECT is the correlation slot: WRITE or REMAP, the half of the
-- ledger a line comes from.
--
-- Any failure that leaves saved objects unmoved is an ERROR: those
-- objects then point at whatever material now sits at their old
-- index, which a player will notice.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'LEDGER'
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

-- Every id prefix that RM or one of its modules owns. Core RM is
-- always included; module prefixes are the keys of the registry,
-- populated by the module pipeline at Step 2.
local function owned_prefixes()
    local list = { CORE_PREFIX }
    for prefix, _ in pairs(_G.refinish_module_registry or {}) do
        table.insert(list, prefix)
    end
    return list
end

local function is_owned(mat_id, prefixes)
    for _, p in ipairs(prefixes) do
        if has_prefix(mat_id, p) then return true end
    end
    return false
end

local function is_plant_type(t)
    return type(t) == 'number' and t >= PLANT_TYPE_LO and t <= PLANT_TYPE_HI
end

-- Every owned plant material in the live raws, by name, with the pair
-- it sits at now: "PLANT_ID|MAT_ID" -> { mat_type, mat_index }. See
-- PLANT MATERIALS in the header for what counts as owned. Returns the
-- table and its count.
local function owned_plant_materials(prefixes)
    local out, n = {}, 0
    for _, p in ipairs(df.global.world.raws.plants.all) do
        local pid = p.id
        local host = is_owned(pid, prefixes)
        for _, m in ipairs(p.material) do
            if host or is_owned(m.id, prefixes) then
                local info = dfhack.matinfo.find('PLANT_MAT:' .. pid .. ':' .. m.id)
                if info then
                    out[pid .. '|' .. m.id] = { info.type, info.index }
                    n = n + 1
                end
            end
        end
    end
    return out, n
end

-- The previous ledger for THIS site, decoded, or nil and a reason.
local function read_ledger()
    local raw = dfhack.persistent.getSiteData(LEDGER_KEY)
    if not raw or raw == "" then return nil, 'none' end
    local ok, led = pcall(json.decode, raw)
    if not ok or type(led) ~= 'table' or type(led.mats) ~= 'table' then
        return nil, 'undecodable'
    end
    if led.site_id and led.site_id ~= df.global.plotinfo.site_id then
        return nil, 'other site', led.site_id
    end
    return led
end


-- ==========================================
-- WRITE
-- ==========================================
-- Snapshots id -> current index for every injected inorganic, and
-- name -> current pair for every owned plant material.
--
-- Safe any time after Step 4, since nothing later in the pipeline
-- moves a material.
--
-- Returns the number of materials recorded.
-- ==========================================
function write()
    local prefixes = owned_prefixes()
    local mats = {}
    local n = 0

    for i, mat in ipairs(df.global.world.raws.inorganics.all) do
        if is_owned(mat.id, prefixes) then
            mats[mat.id] = i
            n = n + 1
        end
    end

    local plants, np = {}, 0
    local ok_p, err_p = pcall(function()
        plants, np = owned_plant_materials(prefixes)
    end)
    if not ok_p then
        log('ERROR', 'Plant materials could not be read, so none were'
            .. ' recorded: ' .. tostring(err_p), 'WRITE')
        plants, np = {}, 0
    end

    -- Refuse to overwrite a good ledger with an empty one. If
    -- injection failed this session, last session's record is the
    -- only thing that can still recover these objects. The same goes
    -- for each half on its own: whichever came back empty keeps last
    -- session's record instead of being wiped.
    if n == 0 and np == 0 then
        log('DETAIL', 'No injected materials found. Existing ledger left'
            .. ' intact.', 'WRITE')
        return 0
    end
    if n == 0 or np == 0 then
        local prev = read_ledger()
        if prev then
            if n == 0 then mats = prev.mats end
            if np == 0 and type(prev.plants) == 'table' then plants = prev.plants end
        end
    end

    dfhack.persistent.saveSiteData(LEDGER_KEY, json.encode({
        site_id = df.global.plotinfo.site_id,
        mats    = mats,
        plants  = plants,
    }))

    log('DETAIL', string.format('Recorded %d material indices and %d plant'
        .. ' materials.', n, np), 'WRITE')
    return n + np
end


-- ==========================================
-- REMAP
-- ==========================================
-- Rewrites every object whose stored index belonged to an injected
-- material last session.
--
-- Returns moved, skipped.
-- ==========================================
function remap()
    -- ---- READ THE PREVIOUS SESSION'S LEDGER ----
    local raw = dfhack.persistent.getSiteData(LEDGER_KEY)
    if not raw or raw == "" then
        -- A save that has never had a ledger. Guessing at what the
        -- stored indices used to mean would corrupt objects that are
        -- currently fine, so do nothing. write() runs later this
        -- session and the save is protected from here on.
        log('DETAIL', 'No previous ledger on this save. Remap skipped.',
            'REMAP')
        return 0, 0
    end

    local ok, old = pcall(json.decode, raw)
    if not ok or type(old) ~= 'table' or type(old.mats) ~= 'table' then
        log('ERROR', 'Ledger could not be decoded. Remap skipped.', 'REMAP')
        return 0, 0
    end

    -- ---- SITE ID GATE ----
    -- Same anti-ghosting rule as refinish-load.lua:74. A ledger from
    -- a different fortress describes a different array.
    local current_site = df.global.plotinfo.site_id
    if old.site_id and old.site_id ~= current_site then
        log('INFO', string.format('Discarded a ledger from another world'
            .. ' (site %s). Remap skipped.', tostring(old.site_id)), 'REMAP')
        return 0, 0
    end

    -- ---- BUILD BOTH DIRECTIONS ----
    -- by_old_idx answers "what material was this index last time".
    -- by_id answers "where does that material live now".
    --
    -- Two lookups rather than a precomputed old->new pair map,
    -- because a pair map breaks as soon as two materials swap
    -- places. The name is the only stable identity.
    local inorganics = df.global.world.raws.inorganics.all

    local by_old_idx = {}
    for id, idx in pairs(old.mats) do
        by_old_idx[idx] = id
    end

    local by_id = {}
    for i, mat in ipairs(inorganics) do
        by_id[mat.id] = i
    end

    -- ---- PLANT PAIRS, BOTH DIRECTIONS ----
    -- by_old_pair answers "which plant material was this pair last
    -- time", by_name "which pair is it now". Same two-lookup shape as
    -- the inorganics, for the same reason.
    local by_old_pair = {}
    local has_plants = type(old.plants) == 'table'
    if has_plants then
        for name, pair in pairs(old.plants) do
            if type(pair) == 'table' and type(pair[1]) == 'number'
               and type(pair[2]) == 'number' then
                by_old_pair[pair[1] .. ':' .. pair[2]] = name
            end
        end
    else
        log('INFO', 'Previous ledger records no plant materials; plant'
            .. ' pairs left alone this once.', 'REMAP')
    end
    local by_name = {}
    local ok_np, err_np = pcall(function()
        by_name = owned_plant_materials(owned_prefixes())
    end)
    if not ok_np then
        log('ERROR', 'Plant materials could not be read, so plant pairs'
            .. ' were not remapped: ' .. tostring(err_np), 'REMAP')
        by_name = {}
    end

    local moved, skipped, plant_moved = 0, 0, 0

    -- ---- THE DECISION, MADE ONCE PER OBJECT ----
    -- Returns nil to mean "write nothing". That covers two cases:
    --
    --   not in the ledger    vanilla stone, and core RM objects
    --                        that refinish-save washed to a vanilla
    --                        index under AUTOSAVE. Those sit below
    --                        the injected band and are restored by
    --                        name in Step 7 instead.
    --
    --   material is gone     the mod that provided it was removed.
    --                        RM never writes a sentinel in this
    --                        case; refinish-load.lua:119, :163 and
    --                        :182 all require a resolved target and
    --                        skip the object otherwise. Same here.
    local function resolve(old_idx)
        local id = by_old_idx[old_idx]
        if not id then return nil end

        local new_idx = by_id[id]
        if not new_idx then
            skipped = skipped + 1
            return nil
        end

        if new_idx ~= old_idx then moved = moved + 1 end
        return new_idx
    end

    -- Bounds test matching refinish-save.lua:114 and :161. An index
    -- outside the array is never dereferenced.
    local function valid_index(idx)
        return type(idx) == 'number' and idx >= 0 and idx < #inorganics
    end

    -- ---- THE SAME DECISION, FOR A PAIR ----
    -- Every stored reference is a (mat_type, mat_index) pair. Returns
    -- the pair to write, or nil to write nothing. An inorganic (type 0)
    -- goes through resolve() above; a plant pair through the plant maps,
    -- by name, with the same two nil cases (not ours, or gone). Any
    -- other type, creature or builtin, is never RM's.
    local function resolve_pair(t, i)
        if t == 0 then
            if not valid_index(i) then return nil end
            local ni = resolve(i)
            if ni then return 0, ni end
            return nil
        end
        if not is_plant_type(t) or type(i) ~= 'number' then return nil end
        local name = by_old_pair[t .. ':' .. i]
        if not name then return nil end
        local now = by_name[name]
        if not now then
            skipped = skipped + 1
            return nil
        end
        if now[1] ~= t or now[2] ~= i then
            moved = moved + 1
            plant_moved = plant_moved + 1
        end
        return now[1], now[2]
    end

    -- ---- CONSTRUCTIONS ----
    -- Constructions have no id and no array. They are addressed
    -- only by tile, through dfhack.constructions.findAtTile, and
    -- they are reached through the item that built them, exactly as
    -- refinish-save.lua:124-147 does it.
    --
    -- A wall occupies its own tile and the floor above, so z+1 is
    -- checked too, and only when it carries the same old pair as the
    -- tile below (refinish-save.lua:141).
    --
    -- mat_type is written alongside mat_index because every
    -- construction write in RM does that (refinish-save.lua:135-136,
    -- refinish-load.lua:131-132 and :183-184).
    --
    -- Wrapped so a construction fault cannot abort the item and
    -- building passes, matching refinish-load.lua:171.
    local function remap_construction_at(item)
        pcall(function()
            local pos = item.pos
            local cons = dfhack.constructions.findAtTile(pos)
            if not cons then return end

            local ot, oi = cons.mat_type, cons.mat_index
            local nt, ni = resolve_pair(ot, oi)
            if not nt then return end

            cons.mat_type = nt
            cons.mat_index = ni

            local above = dfhack.constructions.findAtTile(
                { x = pos.x, y = pos.y, z = pos.z + 1 })
            if above and above.mat_type == ot and above.mat_index == oi then
                above.mat_type = nt
                above.mat_index = ni
            end
        end)
    end

    -- ---- DYE REFERENCES ----
    -- Each reference below is a (type, index) pair and is moved exactly
    -- as an item's own is: through resolve_pair(), by name, inorganic or
    -- plant, and left untouched when its material is gone. Module dyes
    -- are plant materials now (DYE_HOST, TREE_DYE_HOST), so the plant
    -- half is the one that matters for them.
    --
    -- Where they live (df-structures; not yet measured in play, since
    -- no module dye has dyed anything yet):
    --   THREAD         dye_mat_type / dye_mat_index, and dye_profile
    --   SKIN_TANNED    dye_material / dye_matgloss, and dye_profile
    --   POWDER_MISC    dye_profile (a mixed dye lists its sources)
    --   built items    every thread improvement (the dye on cloth) and
    --                  sewn image improvement: a dye pair and a
    --                  dye_profile each
    --   history        see HISTORY EVENTS, after the building pass
    --
    -- dye_profile keeps its sources in parallel vectors. dye_material[k]
    -- is read as the source's material TYPE and dye_matg[k] as its
    -- INDEX, the naming DF uses for every other dye pair. That reading
    -- is unmeasured, so an entry changes only when the pair resolves
    -- through the old ledger. Were the reading backwards, the pair would
    -- not be one the ledger recorded, and it would be left alone rather
    -- than corrupted.
    local dye_moved, dye_faults = 0, 0

    -- One material pair: obj[type_f] is the material type, obj[index_f]
    -- the index. Both are written when the pair moves, since a plant
    -- material can change plant as well as position. Returns true when
    -- it changed, so each caller keeps its own count.
    local function move_pair(obj, type_f, index_f)
        local t, i = obj[type_f], obj[index_f]
        local nt, ni = resolve_pair(t, i)
        if nt and (nt ~= t or ni ~= i) then
            if nt ~= t then obj[type_f] = nt end
            obj[index_f] = ni
            return true
        end
        return false
    end

    local function dye_pair(obj, type_f, index_f)
        if move_pair(obj, type_f, index_f) then dye_moved = dye_moved + 1 end
    end

    local function dye_profile(p)
        local n = math.min(#p.dye_material, #p.dye_matg)
        for k = 0, n - 1 do
            local t, i = p.dye_material[k], p.dye_matg[k]
            local nt, ni = resolve_pair(t, i)
            if nt and (nt ~= t or ni ~= i) then
                if nt ~= t then p.dye_material[k] = nt end
                p.dye_matg[k] = ni
                dye_moved = dye_moved + 1
            end
        end
    end

    local THREAD      = df.item_type.THREAD
    local SKIN_TANNED = df.item_type.SKIN_TANNED
    local POWDER_MISC = df.item_type.POWDER_MISC

    -- Every dye reference one item carries. The item type is checked
    -- before any type-specific field is read: those fields exist only
    -- on their own item classes, and reading one elsewhere throws.
    local function remap_item_dyes(item)
        local t = item:getType()
        if t == THREAD then
            dye_pair(item, 'dye_mat_type', 'dye_mat_index')
            dye_profile(item.dye_profile)
        elseif t == SKIN_TANNED then
            dye_pair(item, 'dye_material', 'dye_matgloss')
            dye_profile(item.dye_profile)
        elseif t == POWDER_MISC then
            dye_profile(item.dye_profile)
        end
        if df.item_constructed:is_instance(item) then
            for _, imp in ipairs(item.improvements) do
                if df.itemimprovement_threadst:is_instance(imp)
                   or df.itemimprovement_sewn_imagest:is_instance(imp) then
                    dye_pair(imp.dye, 'mat_type', 'mat_index')
                    dye_profile(imp.dye_profile)
                end
            end
        end
    end

    -- ---- ITEMS ----
    -- getActualMaterial() is the item's own mat_type. Type 0 is the
    -- inorganic test used throughout RM; a type in the plant range may
    -- be one of our plant materials. Anything else (creature, builtin)
    -- is never RM's and is never touched here.
    --
    -- The construction pass rides this loop because the item is the
    -- only handle a construction has. flags.construction marks an
    -- item that is part of one (refinish-load.lua:124).
    for _, item in ipairs(df.global.world.items.all) do
        local mt = item:getActualMaterial()
        if mt == 0 or is_plant_type(mt) then
            if item.flags.construction then
                remap_construction_at(item)
            end

            local ok_i, mi = pcall(function() return item.mat_index end)
            if ok_i then
                local nt, ni = resolve_pair(mt, mi)
                if nt then
                    if nt ~= mt then item.mat_type = nt end
                    item.mat_index = ni
                end
            end
        end

        -- Dye references, on every item whatever its own material: a
        -- plant or creature item can carry an inorganic dye. One item's
        -- fault is counted and reported, and the pass carries on.
        if not pcall(remap_item_dyes, item) then
            dye_faults = dye_faults + 1
        end
    end

    -- ---- BUILDINGS ----
    for _, bld in ipairs(df.global.world.buildings.all) do
        local ok_b, bt, bi = pcall(function() return bld.mat_type, bld.mat_index end)
        if ok_b then
            local nt, ni = resolve_pair(bt, bi)
            if nt then
                if nt ~= bt then bld.mat_type = nt end
                bld.mat_index = ni
            end
        end
    end

    -- ---- HISTORY EVENTS ----
    -- World history stores the material of what an event was about, and
    -- legends read it back by index. Every history event class in
    -- df-structures that carries a material (unmeasured in play):
    --
    --   masterpiece_created_item              mat_type / mat_index
    --   masterpiece_created_dye_item          mat_type / mat_index and
    --                                         dye_mat_type / dye_mat_index
    --   masterpiece_created_item_improvement  mat_type / mat_index and
    --                                         imp_mat_type / imp_mat_index
    --   item_stolen                           mattype / matindex
    --   hist_figure_died                      weapon.mattype / matindex and
    --                                         weapon.shooter_mattype /
    --                                         shooter_matindex
    --   body_abused                           the spike (Impaled) or the
    --                                         rope (Hung), mat_type /
    --                                         mat_index. abuse_data is a
    --                                         union, so only the member
    --                                         abuse_type names is read.
    --
    -- COST. RM injects only into this fort, so only this fort's era can
    -- hold one of our indices, and that era is a short tail on a vector
    -- worldgen fills with hundreds of thousands of events. Events are
    -- appended as they happen, so the walk starts at the newest and
    -- stops at the event that founded this site; everything before it
    -- is older than the fort. If that event is not found, the whole
    -- vector is walked. A class lookup keeps each event to one table
    -- read. The count, where it stopped and the time are logged.
    local hist_moved, n_events, found_start = 0, 0, false
    local t0 = dfhack.getTickCount()

    local function hist_pair(obj, type_f, index_f)
        if move_pair(obj, type_f, index_f) then hist_moved = hist_moved + 1 end
    end

    -- A class missing from this DFHack build drops that class only.
    local function df_type(name)
        local ok_t, t = pcall(function() return df[name] end)
        if ok_t then return t end
        return nil
    end

    local ok_h, err_h = pcall(function()
        local IMPALED = df.body_abuse_method_type.Impaled
        local HUNG    = df.body_abuse_method_type.Hung

        -- Keyed by class type. An event's _type is its exact class,
        -- since DFHack exposes vtable classes in their exact type.
        local handlers = {}
        local function on(name, fn)
            local t = df_type(name)
            if t then handlers[t] = fn end
        end
        on('history_event_masterpiece_created_itemst', function(ev)
            hist_pair(ev, 'mat_type', 'mat_index')
        end)
        on('history_event_masterpiece_created_dye_itemst', function(ev)
            hist_pair(ev, 'mat_type', 'mat_index')
            hist_pair(ev, 'dye_mat_type', 'dye_mat_index')
        end)
        on('history_event_masterpiece_created_item_improvementst', function(ev)
            hist_pair(ev, 'mat_type', 'mat_index')
            hist_pair(ev, 'imp_mat_type', 'imp_mat_index')
        end)
        on('history_event_item_stolenst', function(ev)
            hist_pair(ev, 'mattype', 'matindex')
        end)
        on('history_event_hist_figure_diedst', function(ev)
            hist_pair(ev.weapon, 'mattype', 'matindex')
            hist_pair(ev.weapon, 'shooter_mattype', 'shooter_matindex')
        end)
        on('history_event_body_abusedst', function(ev)
            if ev.abuse_type == IMPALED then
                hist_pair(ev.abuse_data.Impaled, 'mat_type', 'mat_index')
            elseif ev.abuse_type == HUNG then
                hist_pair(ev.abuse_data.Hung, 'mat_type', 'mat_index')
            end
        end)

        local FOUNDED = df_type('history_event_created_sitest')
        local site    = df.global.plotinfo.site_id
        local events  = df.global.world.history.events

        for i = #events - 1, 0, -1 do
            local ev  = events[i]
            local cls = ev._type
            if cls == FOUNDED and ev.site == site then
                found_start = true
                break
            end
            n_events = n_events + 1
            local fn = handlers[cls]
            -- One odd event is skipped, never allowed to end the walk.
            if fn then pcall(fn, ev) end
        end
    end)
    if not ok_h then
        -- WARNING, not ERROR: a stale history reference reads oddly in
        -- a legend, but nothing in the fort points at a wrong material.
        log('WARNING', 'History events not remapped: ' .. tostring(err_h),
            'REMAP')
    end
    log('DETAIL', string.format('History pass read %d events %s in %d ms.',
        n_events,
        found_start and "back to this site's founding"
                     or "(founding not found, whole list)",
        dfhack.getTickCount() - t0), 'REMAP')

    -- ---- REPORT ----
    if moved > 0 then
        -- INFO: this only happens when a module was added, removed or
        -- changed, which a player may well want to confirm.
        log('INFO', string.format('Remapped %d objects to new material'
            .. ' indices.', moved), 'REMAP')
    end

    if plant_moved > 0 then
        log('DETAIL', string.format('%d of those were plant materials (host'
            .. ' plants and appended twins).', plant_moved), 'REMAP')
    end

    if dye_moved > 0 then
        log('DETAIL', string.format('%d of those were dye references on dyed'
            .. ' goods and dye profiles.', dye_moved), 'REMAP')
    end

    if hist_moved > 0 then
        log('DETAIL', string.format('%d of those were material references in'
            .. ' world history.', hist_moved), 'REMAP')
    end

    if dye_faults > 0 then
        log('WARNING', string.format('The dye pass faulted on %d items; their'
            .. ' dye references were not remapped.', dye_faults), 'REMAP')
    end

    if skipped > 0 then
        -- WARNING: the expected result of removing a mod, not a fault in
        -- the remap itself.
        log('WARNING', string.format('%d objects left untouched; their'
            .. ' materials are no longer present.', skipped), 'REMAP')
    end

    if moved == 0 and skipped == 0 then
        log('DETAIL', 'No objects needed remapping.', 'REMAP')
    end

    return moved, skipped
end


return _ENV