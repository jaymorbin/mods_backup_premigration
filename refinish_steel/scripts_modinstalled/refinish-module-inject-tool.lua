-- refinish-module-inject-tool.lua
-- ==========================================
-- TOOL INJECTION
-- ==========================================
-- Injects itemdef_toolst entries into world.raws.itemdefs at runtime,
-- the same way refinish-module-inject.lua injects inorganics.
--
-- Tools are core engine infrastructure, not module property. A module
-- declares tools in its JSON and every other module can reference them
-- by code string, because refinish-module-react.lua already resolves
-- itemdef codes to numeric subtypes by lookup rather than by position.
-- The consumption half was built already. This is the creation half.
--
-- Containers are the first user, but nothing here is container specific.
-- Any tool the schema can describe can be injected, which means reactions
-- can start requiring tools instead of every new capability needing a
-- whole new workshop.
--
-- Load order note: this must run before refinish-module-react.lua builds
-- reagents, because a reagent naming an injected tool needs that tool to
-- already be in the array.
-- ==========================================


-- ==========================================
-- FIELD MAP
-- ==========================================
-- The only place in the tool system that knows itemdef_toolst layout.
-- Left side is the schema key, right side is the struct field.
--
-- CONFIRM THESE BEFORE FIRST RUN. Run refinish-tool-inspect.lua, read
-- refinish_tool_inspect.txt, and correct any right hand value that does
-- not match. Everything below is driven off this table, so a wrong name
-- is a one line fix here rather than a hunt through the file.
--
-- A field listed here that does not exist on the struct is skipped with
-- a log line rather than crashing, so a partly wrong map still injects
-- a usable tool.
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
-- Two subsystems, as this file always had: TOOL_INJECT for the inject,
-- TOOL_CLEAR for the clear. One funnel per subsystem, from the same
-- factory refinish_steel uses, so the call sites no longer pass it.
-- SUBJECT is the correlation slot: the part of the job a line is
-- about, or the module or prefix it concerns.
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

local log_inject = make_log('TOOL_INJECT')
local log_clear  = make_log('TOOL_CLEAR')

local FIELD_MAP = {
    name         = "name",
    name_plural  = "name_plural",
    adjective    = "adjective",
    value        = "value",
    tile         = "tile",
    size         = "size",
    material_size = "material_size",
    capacity     = "container_capacity",
}

-- Token flags from item_tool.txt, mapped to members of the flags
-- bitfield. Confirm against step 6 of the inspector output.
local FLAG_MAP = {
    furniture              = "FURNITURE",
    inverted_tile          = "INVERTED_TILE",
    no_default_job         = "NO_DEFAULT_JOB",
    incomplete_item        = "INCOMPLETE_ITEM",
    unimprovable           = "UNIMPROVABLE",
    no_default_improvements = "NO_DEFAULT_IMPROVEMENTS",
    hard_mat               = "HARD_MAT",
    metal_mat              = "METAL_MAT",
    soft_mat               = "SOFT_MAT",
    stone_mat              = "STONE_MAT",
    wood_mat               = "WOOD_MAT",
    sheet_mat              = "SHEET_MAT",
    metal_weapon_mat       = "METAL_WEAPON_MAT",
}


-- ==========================================
-- TOOL USE RESOLUTION
-- ==========================================
-- A TOOL_USE token in the raws is an entry in df.tool_uses. The schema
-- takes the token string, so it resolves through the live enum rather
-- than a hardcoded number table. Numbers shift between DF versions,
-- names do not.
-- ==========================================

local function resolve_tool_use(token)
    local ok, value = pcall(function() return df.tool_uses[token] end)
    if ok and type(value) == "number" then
        return value
    end
    return nil
end


-- ==========================================
-- SAFE FIELD WRITE
-- ==========================================
-- Writing a field that does not exist on a DFHack wrapper throws. Every
-- write is guarded so a field map that is wrong in one place still
-- produces a working tool for every other field.
--
-- Returns true if written, false if the field was missing or refused.
-- ==========================================

local function set_field(struct, field, value, tool_id)
    if value == nil then return false end

    local ok, err = pcall(function() struct[field] = value end)
    if not ok then
        log_inject('WARNING', string.format(
            "'%s' has no field '%s'. Check FIELD_MAP. (%s)",
            tostring(tool_id), tostring(field), tostring(err)), 'FIELD')
        return false
    end
    return true
end


-- ==========================================
-- SUBTYPE CACHE INVALIDATION
-- ==========================================
-- refinish-module-react.lua caches itemdef code to subtype lookups in a
-- module level table built once per session. That is safe while every
-- itemdef comes from raws, because raws never move. It stops being safe
-- the moment tools are injected and cleared across save cycles: the
-- cache would hand out positions for tools that no longer exist, and it
-- would do it silently, because the miss branch only fires when a code
-- is absent from the cache, not when the cached number is stale.
--
-- Same failure shape as the ghost_cache use after free. Called on both
-- ends of every injection and every clear.
-- ==========================================

local function invalidate_subtype_cache()
    -- The react module exposes this if it has been updated. Until then
    -- the global is the handshake, and react checks it before trusting
    -- its own cache.
    _G.refinish_itemdef_cache_dirty = true

    local ok, react = pcall(function() return reqscript('refinish-module-react') end)
    if ok and react and react.invalidate_itemdef_cache then
        pcall(function() react.invalidate_itemdef_cache() end)
    end
end


-- ==========================================
-- OWNERSHIP TEST
-- ==========================================
-- A tool belongs to this engine when its id carries a module prefix.
-- Same predicate shape as rm_owned() for materials, and for the same
-- reason: the clear pass must never touch a vanilla itemdef.
-- ==========================================

local function tool_is_owned(id, prefix)
    if type(id) ~= "string" then return false end
    return id:sub(1, #prefix) == prefix
end


-- ==========================================
-- INJECT
-- ==========================================
-- Builds an itemdef_toolst per definition and appends it to both the
-- tools vector and the all vector.
--
-- Definitions are sorted by key before injection. Non negotiable: pairs()
-- over a table gives hash order, and hash order means a tool lands at a
-- different subtype on every cycle, which breaks every saved item stack
-- that references it. Same rule as materials.
--
-- The id written to the struct is prefix .. key, so MAKING_FUEL_ plus
-- SMALL_BOTTLE gives MAKING_FUEL_SMALL_BOTTLE. Reagents and products
-- name that full string.
--
-- Returns: count injected.
-- ==========================================

function inject_tools(tools, prefix, mod_name)
    if not tools then return 0 end

    local defs = df.global.world.raws.itemdefs.tools
    local all  = df.global.world.raws.itemdefs.all

    -- Stable order. Sort before anything touches the game arrays.
    local sorted = {}
    for _, def in pairs(tools) do
        table.insert(sorted, def)
    end
    table.sort(sorted, function(a, b) return a.key < b.key end)

    local count = 0

    for _, def in ipairs(sorted) do
        local id = prefix .. def.key

        -- Skip anything already present. Re-injecting a live tool would
        -- create a duplicate id and two positions claiming one code.
        local exists = false
        for _, td in ipairs(defs) do
            local ok, existing = pcall(function() return td.id end)
            if ok and existing == id then
                exists = true
                break
            end
        end

        if exists then
            log_inject('DETAIL', string.format(
                "'%s' already present, skipped.", id), 'SKIP')
        else
            local t = df.itemdef_toolst:new()

            t.id = id

            -- subtype is the position in the tools vector. Set to the
            -- index this entry is about to occupy, before the insert,
            -- because the insert does not assign it.
            t.subtype = #defs

            -- Scalar fields, all driven off FIELD_MAP.
            for schema_key, field in pairs(FIELD_MAP) do
                set_field(t, field, def[schema_key], id)
            end

            -- Flags. Anything absent from the definition stays at its
            -- constructed default rather than being forced false, because
            -- unlike materials there is no class preset here to restore
            -- a sane baseline afterwards.
            if def.flags then
                for schema_key, flag_name in pairs(FLAG_MAP) do
                    local want = def.flags[schema_key]
                    if want ~= nil then
                        local ok = pcall(function() t.flags[flag_name] = want end)
                        if not ok then
                            log_inject('WARNING', string.format(
                                "'%s' has no flag '%s'. Check FLAG_MAP.",
                                id, flag_name), 'FLAG')
                        end
                    end
                end
            end

            -- Tool uses. Resolved by name through the live enum.
            if def.tool_use then
                for _, token in ipairs(def.tool_use) do
                    local use = resolve_tool_use(token)
                    if use then
                        pcall(function() t.tool_use:insert('#', use) end)
                    else
                        log_inject('WARNING', string.format(
                            "'%s' names unknown TOOL_USE '%s'.",
                            id, tostring(token)), 'TOOL_USE')
                    end
                end
            end

            -- Sprites, schema driven, same engine as materials.
            if def.graphics then
                local ok_eng, eng = pcall(reqscript,
                    'refinish-sprite-engine')
                if ok_eng and eng and eng.apply_to_tool then
                    eng.apply_to_tool(t, def.graphics, id)
                end
            end

            defs:insert('#', t)
            all:insert('#', t)
            count = count + 1
        end
    end

    if count > 0 then
        invalidate_subtype_cache()
    end

    -- DETAIL: the module engine's roster already says which modules
    -- came up; this is the count beneath it.
    log_inject('DETAIL', string.format(
        "%d tools injected for %s (prefix %s).",
        count, tostring(mod_name), tostring(prefix)), tostring(mod_name))

    return count
end


-- ==========================================
-- CLEAR
-- ==========================================
-- Removes every owned tool from both vectors, then rewrites the subtype
-- of everything that remains so it matches its new position.
--
-- That rewrite is the whole difficulty. A tool's subtype is its array
-- index, and every item stack in the fort stores that number, so pulling
-- an entry out of the middle silently repoints every stack above it.
-- Injected tools always land at the end, so removing them from the end
-- leaves lower positions untouched, but the loop below does not assume
-- that: it walks backwards and reindexes regardless.
--
-- CALLER OBLIGATION: this must run inside the same save protocol point
-- that clears module materials, and any item instance carrying an owned
-- subtype has to be in the payload before this runs. A save taken with
-- owned tools live in the arrays is the same class of corruption as a
-- save taken with module materials live.
--
-- Returns: count removed.
-- ==========================================

function clear_tools(prefix)
    local defs = df.global.world.raws.itemdefs.tools
    local all  = df.global.world.raws.itemdefs.all

    -- ---- CIV TOOL GRANTS COME OFF FIRST ----
    -- refinish-module-evaluate-permissions grants a module tool that
    -- asks for DF's native job to the fort's civ, as its subtype in
    -- historical_entity.resources.tool_type. That is a POSITION in the
    -- array this function is about to shrink and reindex, and it is
    -- saved game state. Left in place it would point at nothing, or at
    -- a different tool, both for the rest of the session and in the
    -- save. So it is withdrawn here, before the erase, while the number
    -- still means the tool, on every path that clears tools.
    --
    -- Every entity is swept rather than only the fort's civ, so a grant
    -- from any earlier session or a console test cannot survive either.
    -- Only runs when an owned tool is present, so a clear with nothing
    -- left to remove costs one loop over the itemdefs.
    local owned_subs = {}
    for _, td in ipairs(defs) do
        local ok, id = pcall(function() return td.id end)
        if ok and tool_is_owned(id, prefix) then
            pcall(function() owned_subs[td.subtype] = true end)
        end
    end
    local withdrawn = 0
    if next(owned_subs) then
        for _, ent in ipairs(df.global.world.entities.all) do
            pcall(function()
                local v = ent.resources.tool_type
                for i = #v - 1, 0, -1 do
                    if owned_subs[v[i]] then
                        v:erase(i)
                        withdrawn = withdrawn + 1
                    end
                end
            end)
        end
    end
    if withdrawn > 0 then
        log_clear('DETAIL', string.format("%d civ tool grant(s) withdrawn for"
            .. " prefix %s.", withdrawn, tostring(prefix)), 'GRANTS')
    end

    local count = 0

    -- Backwards, because removing shifts every index above the removal.
    for i = #defs - 1, 0, -1 do
        local ok, id = pcall(function() return defs[i].id end)
        if ok and tool_is_owned(id, prefix) then
            -- Drop from the all vector first, matching by identity of the
            -- id string rather than by object, because DFHack hands back a
            -- fresh wrapper on every access and object comparison fails.
            for j = #all - 1, 0, -1 do
                local ok2, aid = pcall(function() return all[j].id end)
                if ok2 and aid == id then
                    all:erase(j)
                    break
                end
            end

            defs:erase(i)
            count = count + 1
        end
    end

    -- Reindex. Every surviving entry gets a subtype equal to where it
    -- actually sits now.
    for i, td in ipairs(defs) do
        pcall(function() td.subtype = i end)
    end

    if count > 0 then
        invalidate_subtype_cache()
    end

    log_clear('DETAIL', string.format(
        "%d tools removed for prefix %s. %d remain.",
        count, tostring(prefix), #defs), tostring(prefix))

    return count
end


-- ==========================================
-- PHYSICAL CLEAR CHECK
-- ==========================================
-- Walks the array directly rather than trusting a flag, matching the
-- rule that is already in place for materials. Used by the autosave
-- baseline check and by is_memory_physically_clear().
--
-- Returns true when no owned tool is present.
-- ==========================================

function tools_physically_clear(prefix)
    local defs = df.global.world.raws.itemdefs.tools
    for _, td in ipairs(defs) do
        local ok, id = pcall(function() return td.id end)
        if ok and tool_is_owned(id, prefix) then
            return false
        end
    end
    return true
end


return _ENV