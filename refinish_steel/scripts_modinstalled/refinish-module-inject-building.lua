--@ module = true
-- refinish-module-inject-building.lua
-- ==========================================
-- RM BUILDING DEFINITION INJECTOR
-- ==========================================
-- Injects custom building definitions (workshops and furnaces)
-- directly into world.raws.buildings at runtime, graphics
-- included. No raws anywhere: no BUILDING_ tokens, no TILE_PAGE,
-- no TILE_GRAPHICS. A module ships a JSON entry and a png in its
-- own directory, and this file does the rest.
--
-- MEASURED FACTS THIS FILE IS BUILT ON (probe session, retort):
--
--   * A placed building stores the def's id field in custom_type.
--     Not a vector position, not a pointer. Writing a different id
--     onto a placed building changes what it is, live.
--   * A placed building whose custom_type matches no def survives
--     save and reload intact, selectable, unnamed and unarted.
--     Writing a live id back repairs it completely.
--   * building_def_furnacest:new() returns a struct with the
--     graphics arrays inline and zeroed. Construction from scratch
--     works; no clone donor needed.
--   * graphics_normal / graphics_overlay are int32_t[4][31][32]
--     indexed [stage][x][y], holding plain atlas texpos values.
--   * Raw defs are cached into the save at worldgen and reparsed
--     from that cache every load, ids 0..next_id-1, frozen for the
--     life of the save. Injected defs never enter that cache.
--
-- GRAPHICS SOURCE: dfhack.textures (Lua_API 2837-2850)
--
--   loadTileset(file, w, h, reserved) registers a png from disk
--   into the game texture vector, sliced row major, and returns an
--   array of TexposHandle. getTexposByHandle(handle) returns the
--   CURRENT texpos for a handle. Raw texpos values can be
--   invalidated when the game resets its texture vector; handles
--   cannot. The building def stores raw int32 texpos, so this file
--   defends in three layers:
--
--     1. reserved = true. The reserved range is documented as
--        never wiped. Primary defense.
--     2. Handles are cached per session in
--        _G.refinish_texture_cache, so grids can be recomputed
--        from stable handles at any time. RM shutdown must NOT
--        clear this global: handles are process level, and
--        reloading a png every data cycle would exhaust the
--        reserved range.
--     3. A sentinel per building records one written value.
--        graphics_stale() detects drift, refresh_graphics()
--        rewrites every owned grid from handles.
--
-- ID RESERVATION, NOT REMAP
--
-- Materials and tools store vector POSITIONS on live objects, so
-- their ledgers walk the world rewriting objects when positions
-- shift. Buildings store an id RM assigns, so the ledger here is a
-- reservation: code -> id, persisted per save, honored forever.
-- A module's building gets the same id every session regardless of
-- injection order changes or module additions, so placed buildings
-- resolve with no repair pass at all. Removed modules keep their
-- reservation; an id is never reissued to a different code.
--
-- Allocation floor is buildings.next_id as the cached parse left
-- it, so reservations can never collide with raws declared defs.
-- buildings.next_id itself is NEVER written.
--
-- SHEET CONVENTION (unchanged from the raws era, so existing pngs
-- work as they are):
--
--   A building of dim_x columns and dim_y rows uses dim_y+1 sheet
--   rows (art may overhang one row above the footprint) and
--   8*dim_x sheet columns:
--
--     main    stage s at sheet cols (3-s)*dim_x .. +dim_x-1
--     overlay stage s at main cols + 4*dim_x
--
--   For a 3x3: main 0-2 / 3-5 / 6-8 / 9-11, overlay 12-23.
--
-- CALLED FROM:
--   refinish-module-engine.lua  run_module_pipeline (inject,
--                               after materials, before categories)
--   refinish-module-engine.lua  clear_module_assets (clear,
--                               after categories, before materials)
--
-- PUBLIC API:
--   inject_buildings(buildings, prefix, mod_name, base_dir) -> count
--   clear_buildings(prefix)                                 -> count
--   buildings_physically_clear(prefix)                      -> bool
--   graphics_stale()                                        -> bool
--   refresh_graphics()                                      -> count
--   orphan_census()                                         -> count
-- ==========================================

local json = require('json')


-- ==========================================
-- CONFIGURATION
-- ==========================================

-- Site data key. Sits alongside the material and tool ledgers.
local LEDGER_KEY = "REFINISH_STEEL_BUILDING_LEDGER"

-- Class dictionary. Everything type shaped about the two supported
-- building classes lives here, resolved through DF's own enums
-- rather than numeric literals, because SMELTER vs Smelter has
-- already burned this project once.
local CLASSES = {
    WORKSHOP = {
        ctor    = function() return df.building_def_workshopst:new() end,
        btype   = function() return df.building_type.Workshop end,
        subtype = function() return df.workshop_type.Custom end,
        vector  = function() return df.global.world.raws.buildings.workshops end,
    },
    FURNACE = {
        ctor    = function() return df.building_def_furnacest:new() end,
        btype   = function() return df.building_type.Furnace end,
        subtype = function() return df.furnace_type.Custom end,
        vector  = function() return df.global.world.raws.buildings.furnaces end,
    },
}


-- ==========================================
-- SESSION STATE
-- ==========================================
-- refinish_texture_cache  [abs png path] -> { handles, tile_dim }
--     Process level. Survives data cycles ON PURPOSE; see header.
--
-- refinish_building_graphics  [code] -> geometry + sentinel
--     What refresh_graphics needs to rewrite a grid without the
--     original spec. Holds NO live df pointers (ghost cache
--     lesson): defs are found by code fresh on every refresh.
-- ==========================================
_G.refinish_texture_cache     = _G.refinish_texture_cache or {}
_G.refinish_building_graphics = _G.refinish_building_graphics or {}


-- ==========================================
-- HELPERS
-- ==========================================

-- ==========================================
-- LOG FUNNELS
-- ==========================================
-- RM's own, and peripheral rather than pipeline. Every line this file
-- writes goes through one of the five funnels below, in the one
-- grammar the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body.
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
-- Five subsystems, as this file always had: BUILDING_INJECT for the
-- inject, BUILDING_GRAPHICS for the tilesets, FURNACE_RENDER for the
-- render loop, BUILDING_CLEAR for the clear and BUILDING_CENSUS for the
-- orphan count. One funnel per subsystem, from the same factory
-- refinish_steel uses, so the call sites no longer pass it. SUBJECT is
-- the correlation slot: the part of the job a line is about, or the
-- module or prefix it concerns.
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

local log_inject   = make_log('BUILDING_INJECT')
local log_graphics = make_log('BUILDING_GRAPHICS')
local log_render   = make_log('FURNACE_RENDER')
local log_clear    = make_log('BUILDING_CLEAR')
local log_census   = make_log('BUILDING_CENSUS')

-- Anchored literal prefix test, same as the module engine's.
local function has_prefix(str, prefix)
    return string.sub(str, 1, #prefix) == prefix
end

-- Windows drive letter or a leading slash means absolute.
local function is_absolute(path)
    return path:match('^%a:') ~= nil or path:match('^[/\\]') ~= nil
end

local function join_path(base, rel)
    if not base or base == '' or is_absolute(rel) then return rel end
    return (base:gsub('[/\\]$', '')) .. '/' .. rel
end


-- ==========================================
-- TILESET LOADING
-- ==========================================
-- Loads a png through dfhack.textures into the RESERVED range and
-- caches the handle array per absolute path. A cache hit is
-- validated by resolving one handle; if that throws, the entry is
-- stale (should not happen for reserved range, guarded anyway) and
-- the file is loaded again.
--
-- Every dfhack.textures call is pcall wrapped so an API absence or
-- rename names itself in the log instead of killing the pipeline.
-- ==========================================

local function load_tileset(abspath, tile_dim)
    local cached = _G.refinish_texture_cache[abspath]
    if cached and cached.tile_dim == tile_dim then
        local ok = pcall(function()
            return dfhack.textures.getTexposByHandle(cached.handles[1])
        end)
        if ok then return cached end
        _G.refinish_texture_cache[abspath] = nil
    end

    local handles, err = nil, nil
    local ok, res = pcall(function()
        return dfhack.textures.loadTileset(abspath, tile_dim, tile_dim, true)
    end)
    if ok and type(res) == 'table' and #res > 0 then
        handles = res
    else
        err = ok and 'no handles returned' or tostring(res)
    end

    if not handles then
        return nil, string.format("tileset load failed [%s]: %s",
            abspath, tostring(err))
    end

    local entry = { handles = handles, tile_dim = tile_dim }
    _G.refinish_texture_cache[abspath] = entry
    log_graphics('DETAIL', string.format(
        "Loaded [%s]: %d cells (reserved range).",
        abspath, #handles), 'LOAD')
    return entry
end

-- Handle for sheet cell (c, r), 1 indexed into the flat array.
local function handle_at(entry, cols, c, r)
    return entry.handles[r * cols + c + 1]
end

local function texpos_of(handle)
    local ok, v = pcall(function()
        return dfhack.textures.getTexposByHandle(handle)
    end)
    if ok then return v end
    return nil
end


-- ==========================================
-- ID RESERVATION LEDGER
-- ==========================================
-- { site_id = n, ids = { [code] = id }, high = next unreserved }
--
-- read() tolerates a missing or foreign ledger by returning a
-- fresh one, matching the material ledger's site gate. write()
-- runs after every allocation batch so a crash mid session cannot
-- lose an id a placed building already depends on.
-- ==========================================

local function ledger_read()
    local site = df.global.plotinfo.site_id
    local raw = dfhack.persistent.getSiteData(LEDGER_KEY)
    if raw and raw ~= "" then
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == 'table' and type(data.ids) == 'table'
            and data.site_id == site then
            data.high = tonumber(data.high) or 0
            return data
        end
    end
    return { site_id = site, ids = {}, high = 0 }
end

local function ledger_write(ledger)
    dfhack.persistent.saveSiteData(LEDGER_KEY, json.encode(ledger))
end

-- Returns the id this code is entitled to, reserving one if it has
-- never been seen on this save. The floor is the cached parse's
-- next_id, read fresh each call and never written, so a raws
-- building can never be shadowed by a reservation.
local function reserve_id(ledger, code)
    if ledger.ids[code] then
        return ledger.ids[code], false
    end
    local floor = df.global.world.raws.buildings.next_id
    local id = math.max(floor, ledger.high)
    ledger.ids[code] = id
    ledger.high = id + 1
    return id, true
end


-- ==========================================
-- GRID WRITER
-- ==========================================
-- Fills both grids and the list icon for one def from a cached
-- tileset, per the sheet convention. Values are written verbatim,
-- zeros included: a blank cell on the sheet is "no art here",
-- which is what the raws path produced too.
--
-- geo is the persisted geometry record (see inject); it doubles as
-- the refresh input so this one function serves both paths.
-- Returns cells written and the sentinel value.
-- ==========================================

local function write_building_graphics(d, entry, geo)
    local written = 0
    local sentinel_val = nil

    local function write_one(grid, shift)
        for s = 0, 3 do
            local col_base = geo.origin_c + (3 - s) * geo.dim_x + shift
        for x = 0, geo.dim_x - 1 do
                for y = 0, geo.dim_y do
                    local c = col_base + x
                    local r = geo.origin_r + y
                    if c < geo.cols and r < geo.rows then
                        local v = texpos_of(handle_at(entry, geo.cols, c, r))
                        if v then
                            grid[s][x][y] = v
                            written = written + 1
                            if not sentinel_val then
                                sentinel_val = v
                                geo.sentinel_c = c
                                geo.sentinel_r = r
                            end
                        end
                    end
                end
            end
        end
    end

    write_one(d.graphics_normal, 0)
    if geo.overlay then
        write_one(d.graphics_overlay, 4 * geo.dim_x)
    end

    if geo.icon_c then
        local v = texpos_of(handle_at(entry, geo.cols, geo.icon_c, geo.icon_r))
        if v then d.list_icon_texpos = v end
    end

    geo.sentinel_val = sentinel_val
    return written
end


-- ==========================================
-- BUILD ITEM CONSTRUCTION
-- ==========================================
-- One building_def_item per schema entry. v1 resolves:
--
--   type            df.item_type name, required
--   subtype         TOOL itemdef code, or a raw integer, else -1
--   reaction_class  string gate, the REFRACTORY pattern
--   quantity        count, default 1
--   flags1/2/3      named bit passthrough
--
-- Material tokens are deliberately out of v1. The parsed retort
-- gates its slots on reaction_class and item type alone, and the
-- diff probe against a parsed def is what earns any widening here.
-- ==========================================

local function resolve_subtype(spec)
    if spec.subtype == nil then return -1 end
    if type(spec.subtype) == 'number' then return spec.subtype end
    for i, td in ipairs(df.global.world.raws.itemdefs.tools) do
        if td.id == spec.subtype then return td.subtype end
    end
    return nil, "unknown tool subtype: " .. tostring(spec.subtype)
end

local function build_item_from(spec, code)
    local itype = df.item_type[spec.type or '']
    if not itype then
        return nil, string.format("bad item type [%s]", tostring(spec.type))
    end

    local sub, err = resolve_subtype(spec)
    if not sub then return nil, err end

    -- Optional material token, INORGANIC:X style, resolved fresh
    -- every injection so module material indices are always
    -- current. A token that fails to resolve fails the whole
    -- definition: a building whose recipe silently widened is a
    -- worse outcome than one that refused to inject and said why.
    local m_type, m_index = -1, -1
    if spec.mat then
        local info = nil
        pcall(function() info = dfhack.matinfo.find(spec.mat) end)
        assert(info, "material token did not resolve: " .. tostring(spec.mat))
        m_type, m_index = info.type, info.index
    end

    local it = df.building_def_item:new()
    it.item_type     = itype
    it.item_subtype  = sub
    it.mat_type      = m_type
    it.mat_index     = m_index
    it.quantity      = spec.quantity or 1
    it.metal_ore     = -1
    it.min_dimension = -1
    it.has_tool_use  = -1
    if spec.reaction_class then
        it.reaction_class = spec.reaction_class
    end

    -- Named flag passthrough, each bit its own pcall so a renamed
    -- enum member names itself in the log instead of killing the
    -- whole item.
    for _, band in ipairs({ 'flags1', 'flags2', 'flags3' }) do
        for name, val in pairs(spec[band] or {}) do
            local ok = pcall(function() it[band][name] = val and true or false end)
            if not ok then
                log_inject('WARNING', string.format(
                    "[%s] unknown %s bit [%s].",
                    code, band, tostring(name)), 'FLAG')
            end
        end
    end

    return it
end


-- ==========================================
-- FURNACE COMPLETED-RENDER FILL
-- ==========================================
-- Measured model (probe campaign, retort + live smelter):
--   * Completed FURNACE-class buildings render LIVE from
--     workshop_graphics_info entries keyed (synthetic subtype,
--     color_index), where color is the BUILDING MATERIAL color.
--     Standing buildings gained art the instant slots filled.
--   * DF creates a (subtype, color) slot lazily when a furnace of
--     a new material is built, baking art from the parse
--     registry. Custom furnaces have no parse source, so the bake
--     is TRANSPARENT: invisible completed buildings.
--   * Synthetic subtype observed: furnace ceiling 7 + 1 + def id
--     (retort id 2 -> 10). Logged at inject so other worlds can
--     falsify the formula.
--   * Slots persist in the save's raws cache; texpos are session
--     scoped. So: unconditional overwrite of every owned slot at
--     inject, plus a poll loop for slots DF creates mid-session.
--     Slots are never erased (soap maker rule).
-- Fire parity: slots hold single texpos, no runtime compositing,
-- so this fills from the sheet MAIN block; vanilla bakes arrive
-- with fire composited in. Custom furnaces complete UNLIT until
-- the preflight composite step lands. Known gap, one step.
-- ==========================================

_G.refinish_furnace_targets = _G.refinish_furnace_targets or {}

-- Erases every is_furnace slot of the given synthetic subtype.
-- Measured inversion: an EMPTY slot overrides the def grid
-- fallback (invisible completed buildings); an ABSENT slot lets
-- the renderer live-layer the def grids, which draw main plus
-- overlay correctly. DF recreates slots lazily per material, so
-- erasure runs at inject and from the poll loop. These slots
-- exist only because of our def; erasing them is ownership, not
-- the soap maker hazard.
local function erase_furnace_entries(code, subtype)
    local vec = df.global.world.raws.buildings.workshop_graphics_info
    local erased = 0
    for i = #vec - 1, 0, -1 do
        local g = vec[i]
        local w = 0
        pcall(function() w = g.flags.whole end)
        local isf = math.floor(w / 2^24) % 2 == 1
        local sub = math.floor(w / 256) % 65536
        if isf and sub == subtype then
            vec:erase(i)
            erased = erased + 1
        end
    end
    return erased
end

-- ==========================================
-- FURNACE RENDER POLL LOOP
-- ==========================================
-- Stamper mold. Catches slots DF creates when a furnace of a NEW
-- material is built mid-session, which arrive baked transparent.
-- Emptiness test reads stage 3 row 0 only: cheap, and any real
-- fill writes it.
-- ==========================================

_G.refinish_furnace_poll_running = _G.refinish_furnace_poll_running or false
_G.refinish_furnace_poll_session = _G.refinish_furnace_poll_session or 0
local FURNACE_POLL_FRAMES = 50

local function furnace_poll_pass()
    local vec = df.global.world.raws.buildings.workshop_graphics_info
    for i = 0, #vec - 1 do
        local g = vec[i]
        local w = 0
        pcall(function() w = g.flags.whole end)
        local isf = math.floor(w / 2^24) % 2 == 1
        local sub = math.floor(w / 256) % 65536
        local code = _G.refinish_furnace_targets[sub]
        if isf and code then
            local n = erase_furnace_entries(code, sub)
            if n > 0 then
                log_render('DETAIL', string.format(
                    "[%s] erased %d regenerated slot(s) (subtype %d).",
                    code, n, sub), 'ERASE')
            end
        end
    end
end

function start_furnace_render_loop()
    if _G.refinish_furnace_poll_running then return false end
    _G.refinish_furnace_poll_running = true
    _G.refinish_furnace_poll_session = _G.refinish_furnace_poll_session + 1
    local my = _G.refinish_furnace_poll_session
    local function loop()
        dfhack.timeout(FURNACE_POLL_FRAMES, 'frames', function()
            if not _G.refinish_furnace_poll_running then return end
            if my ~= _G.refinish_furnace_poll_session then return end
            pcall(furnace_poll_pass)
            loop()
        end)
    end
    loop()
    log_render('DETAIL', "Poll loop started.", 'START')
    return true
end

function stop_furnace_render_loop()
    if _G.refinish_furnace_poll_running then
        _G.refinish_furnace_poll_running = false
        log_render('DETAIL', "Poll loop stopped.", 'STOP')
    end
end


-- ==========================================
-- INJECT
-- ==========================================
-- Builds and registers every building in the payload. Each def is
-- its own pcall: one bad definition costs itself and logs, never
-- the batch, matching every other injector in the pipeline.
--
-- base_dir is the directory of the module's buildings JSON, so
-- image paths in the schema can be relative to the module.
-- ==========================================

function inject_buildings(buildings, prefix, mod_name, base_dir)
    local raws = df.global.world.raws.buildings
    local ledger = ledger_read()
    local injected = 0
    local reserved_new = false

    for _, spec in ipairs(buildings) do
        local ok, err = pcall(function()
            local code = prefix .. spec.key
            local class = CLASSES[spec.class or 'WORKSHOP']
            assert(class, "unknown building class: " .. tostring(spec.class))

            -- ---- SKIP IF PRESENT ----
            -- A raws twin (transition period) or a re-entrant call
            -- must not produce a duplicate definition.
            for _, d0 in ipairs(raws.all) do
                if d0.code == code then
                    log_inject('DETAIL', string.format(
                        "[%s] already present at id %d. Skipped.",
                        code, d0.id), 'SKIP')
                    return
                end
            end

            local dim_x = (spec.dim and spec.dim[1]) or 3
            local dim_y = (spec.dim and spec.dim[2]) or 3

            -- ---- IDENTITY ----
            local d = class.ctor()
            local id, fresh = reserve_id(ledger, code)
            reserved_new = reserved_new or fresh

            d.code             = code
            d.id               = id
            d.name             = spec.name or spec.key
            d.building_type    = class.btype()
            d.building_subtype = class.subtype()

            local nc = spec.name_color or { 0, 7, 1 }
            d.name_color[0], d.name_color[1], d.name_color[2] = nc[1], nc[2], nc[3]

            -- ---- FOOTPRINT ----
            d.dim_x = dim_x
            d.dim_y = dim_y
            -- Struct workloc is 0 indexed (measured: 1,1 is the
            -- center of a 3x3). The old raws WORK_LOCATION tag was
            -- 1 indexed; this schema is 0 indexed like the struct.
            d.workloc_x = (spec.workloc and spec.workloc[1]) or math.floor(dim_x / 2)
            d.workloc_y = (spec.workloc and spec.workloc[2]) or math.floor(dim_y / 2)
            d.build_stages = spec.build_stages or 3
            -- Hotkey by interface_key name (CUSTOM_SHIFT_R) or a
            -- raw integer. An unknown name logs and falls to no
            -- key rather than failing a building over a hotkey.
            local bk = spec.build_key or 0
            if type(bk) == 'string' then
                local kv = df.interface_key[bk]
                if not kv then
                    log_inject('WARNING', string.format(
                        "[%s] unknown build key [%s].",
                        code, bk), 'BUILD_KEY')
                end
                bk = kv or 0
            end
            d.build_key    = bk
            d.needs_magma  = spec.needs_magma and true or false

            -- ---- WALKABILITY ----
            -- Schema rows are outer=y, inner=x, reading like the
            -- old BLOCK raws. Written as tile_block[x][y] to match
            -- the measured orientation of the sibling graphics
            -- arrays. UNMEASURED for asymmetric layouts: the diff
            -- probe settles it before any asymmetric building
            -- ships. Symmetric grids are unaffected either way.
            for y, row in ipairs(spec.block or {}) do
                for x, v in ipairs(row) do
                    d.tile_block[x - 1][y - 1] = (v ~= 0) and 1 or 0
                end
            end

            -- ---- LABOR ----
            for _, lname in ipairs(spec.build_labors or { 'MASON' }) do
                local lv = (type(lname) == 'number') and lname
                    or df.unit_labor[lname]
                if lv then
                    d.build_labors:insert('#', lv)
                else
                    log_inject('WARNING', string.format(
                        "[%s] unknown labor [%s].",
                        code, tostring(lname)), 'LABOR')
                end
            end
            if spec.labor_description then
                d.labor_description = spec.labor_description
            end

            -- ---- TOOLTIP ----
            -- vector<string*>, so each line is a df.new('string'),
            -- the reaction class idiom.
            for _, line in ipairs(spec.tooltip or {}) do
                local s = df.new('string')
                s.value = line
                d.tooltip.text:insert('#', s)
            end

            -- ---- BUILD ITEMS ----
            for _, ispec in ipairs(spec.build_items or {}) do
                local it, ierr = build_item_from(ispec, code)
                if it then
                    d.build_items:insert('#', it)
                else
                    log_inject('WARNING', string.format(
                        "[%s] build item skipped: %s",
                        code, tostring(ierr)), 'BUILD_ITEM')
                end
            end

            -- ---- GRAPHICS ----
            -- Loaded from the module's own png through the texture
            -- module, no raws involved. A missing or misdeclared
            -- image is cosmetic and logs; the building still
            -- injects and renders as a bare shell.
            if spec.graphics and spec.graphics.image then
                local g = spec.graphics
                local abspath = join_path(base_dir, g.image)
                local tile_dim = g.tile_dim or 32

                local geo = {
                    file     = abspath,
                    tile_dim = tile_dim,
                    dim_x    = dim_x,
                    dim_y    = dim_y,
                    cols     = (g.sheet_dim and g.sheet_dim[1]) or (8 * dim_x),
                    rows     = (g.sheet_dim and g.sheet_dim[2]) or (dim_y + 1),
                    origin_c = (g.origin and g.origin[1]) or 0,
                    origin_r = (g.origin and g.origin[2]) or 0,
                    overlay  = (g.overlay ~= false),
                    icon_c   = g.list_icon and g.list_icon[1] or nil,
                    icon_r   = g.list_icon and g.list_icon[2] or nil,
                }

                local entry, gerr = load_tileset(abspath, tile_dim)
                if entry and #entry.handles ~= geo.cols * geo.rows then
                    entry, gerr = nil, string.format(
                        "sheet is %d cells, declaration says %dx%d = %d. " ..
                        "Check the png size or set sheet_dim.",
                        #_G.refinish_texture_cache[abspath].handles,
                        geo.cols, geo.rows, geo.cols * geo.rows)
                end

                if entry then
                    local n = write_building_graphics(d, entry, geo)
                    _G.refinish_building_graphics[code] = geo
                    log_inject('DETAIL', string.format(
                        "[%s] graphics: %d cells from [%s].",
                        code, n, g.image), 'GRAPHICS')
                else
                    log_inject('WARNING', string.format(
                        "[%s] no graphics: %s",
                        code, tostring(gerr)), 'GRAPHICS')
                end
            end

            -- Furnace class: completed buildings render live from
            -- workshop_graphics_info (subtype, material color)
            -- slots, not the def grids. Register the synthetic
            -- subtype and overwrite every existing slot now; the
            -- poll loop catches slots DF creates later.
            if (spec.class or 'WORKSHOP') == 'FURNACE' then
                local sub = 8 + id
                _G.refinish_furnace_targets[sub] = code
                local n = erase_furnace_entries(code, sub)
                log_inject('DETAIL', string.format(
                    "[%s] furnace render: subtype %d, %d slot(s) erased; def grid fallback active.",
                    code, sub, n), 'RENDER')
            end

            -- ---- ICON ----
            -- A standalone icon png, loaded as its own single cell
            -- tileset. Separate from list_icon because that
            -- indexes the art sheet, and a 1x1 file has no cell to
            -- index. Independent of the graphics block above: a
            -- building may have an icon with no art, or the
            -- reverse.
            if spec.graphics and spec.graphics.icon_image then
                local ip = join_path(base_dir, spec.graphics.icon_image)
                local idim = spec.graphics.icon_dim
                    or spec.graphics.tile_dim or 32
                local ientry, ierr = load_tileset(ip, idim)
                if ientry and ientry.handles[1] then
                    local v = texpos_of(ientry.handles[1])
                    if v then
                        d.list_icon_texpos = v
                        log_inject('DETAIL', string.format(
                            "[%s] icon from [%s].",
                            code, spec.graphics.icon_image), 'ICON')
                    end
                else
                    log_inject('WARNING', string.format(
                        "[%s] no icon: %s",
                        code, tostring(ierr)), 'ICON')
                end
            end

            -- ---- REGISTER ----
            -- Same pointer into both vectors, mirroring how the
            -- parser registers its own defs. Class vector second so
            -- a fault above leaves neither half registered.
            raws.all:insert('#', d)
            class.vector():insert('#', d)

            injected = injected + 1
            log_inject('DETAIL', string.format(
                "[%s] injected as id %d (%s).",
                code, id, spec.class or 'WORKSHOP'), 'INJECTED')
        end)

        if not ok then
            -- ERROR: this building is missing from the game.
            log_inject('ERROR', string.format(
                "definition failed in [%s]: %s",
                tostring(mod_name), tostring(err)), tostring(mod_name))
        end
    end

    -- Persist reservations immediately. A crash later this session
    -- must not orphan an id a placed building already carries.
    if reserved_new then
        ledger_write(ledger)
    end

    -- ---- COMPLETION, NOT A GRAPHICS REFRESH ----
    -- At least one copy of this file had a pasted duplicate of the
    -- line from refresh_building_grids here: guarded by `injected`,
    -- returning `injected`, but logging `refreshed` and tagged
    -- BUILDING_GRAPHICS. `refreshed` is not a local in this scope, so
    -- it read a nil global and printed "Refreshed nil grid(s)" on
    -- every successful injection.
    --
    -- The guard and the return were never touched, which is why it
    -- survived: the condition still read correctly and only the
    -- message came from the wrong function.
    --
    -- DETAIL, no longer COMPLETE. Quiet does not carry every
    -- subsystem's completion, and the module engine's roster already
    -- says which modules came up. A building that failed to inject is
    -- its own ERROR above, which Quiet does carry.
    if injected > 0 then
        log_inject('DETAIL', string.format("injected %d building(s).", injected), tostring(prefix))
    end
    return injected
end


-- ==========================================
-- GRAPHICS FRESHNESS
-- ==========================================
-- The renderer can, per the API docs, reset its texture vector and
-- invalidate raw texpos values. Reserved range loading should
-- prevent that from ever touching these grids; these two functions
-- are the measurement and the cure for the case where it does not.
-- ==========================================

-- True when any injected building's sentinel cell no longer reads
-- the value that was written into its grid.
function graphics_stale()
    for code, geo in pairs(_G.refinish_building_graphics) do
        local entry = _G.refinish_texture_cache[geo.file]
        if entry and geo.sentinel_val and geo.sentinel_c then
            local now = texpos_of(handle_at(entry, geo.cols, geo.sentinel_c, geo.sentinel_r))
            if now and now ~= geo.sentinel_val then
                return true
            end
        end
    end
    return false
end

-- Rewrites every owned grid from cached handles. Defs are located
-- by code at call time, never held (ghost cache lesson): a def
-- cleared since injection is simply skipped.
function refresh_graphics()
    local refreshed = 0
    for code, geo in pairs(_G.refinish_building_graphics) do
        local entry = _G.refinish_texture_cache[geo.file]
        if entry then
            for _, d in ipairs(df.global.world.raws.buildings.all) do
                if d.code == code then
                    write_building_graphics(d, entry, geo)
                    refreshed = refreshed + 1
                    break
                end
            end
        end
    end
    if refreshed > 0 then
        log_graphics('DETAIL', string.format(
            "Refreshed %d grid(s) from cached handles.", refreshed), 'REFRESH')
    end
    return refreshed
end


-- ==========================================
-- CLEAR
-- ==========================================
-- Unlinks every OWNED definition from all three vectors before a
-- save, so injected defs never enter the save's cached raw set.
-- Placed buildings are deliberately untouched: a dead custom_type
-- survives save and reload (measured) and resolves again the
-- moment the reservation puts the same id back.
--
-- HARD RULE: prefix ownership only. Unlinking a def RM does not
-- own removes a RAWS building from the save's cached set
-- permanently, with no recovery path. That is a category of
-- corruption, not a bug.
--
-- No :delete(), matching clear_tools: the memory stays valid for
-- the rest of the session so nothing that resolved a def this
-- frame dereferences freed memory. One def leaks per data cycle,
-- reclaimed when DF exits, same accepted cost as tools.
--
-- The graphics geometry record for the code is dropped; the
-- TEXTURE cache is not (see header). Next injection rebuilds the
-- geometry against the same cached handles.
-- ==========================================

function clear_buildings(prefix)
    local raws = df.global.world.raws.buildings
    local cleared = 0

    for _, vec in ipairs({ raws.all, raws.workshops, raws.furnaces }) do
        for i = #vec - 1, 0, -1 do
            if has_prefix(vec[i].code, prefix) then
                vec:erase(i)
                cleared = cleared + 1
            end
        end
    end

    for code, _ in pairs(_G.refinish_building_graphics) do
        if has_prefix(code, prefix) then
            _G.refinish_building_graphics[code] = nil
        end
    end

    -- Owned furnace render slots: erase before save so none enter
    -- the raws cache; the def grid fallback needs their absence.
    for sub, fcode in pairs(_G.refinish_furnace_targets or {}) do
        if has_prefix(fcode, prefix) then
            erase_furnace_entries(fcode, sub)
            _G.refinish_furnace_targets[sub] = nil
        end
    end

    -- cleared counts vector slots; each def occupies two (all plus
    -- its class vector), so the def count is half.
    if cleared > 0 then
        log_clear('DETAIL', string.format(
            "[%s] unlinked %d definition(s).",
            prefix, math.floor(cleared / 2)), tostring(prefix))
    end
    return math.floor(cleared / 2)
end


-- ==========================================
-- VERIFICATION
-- ==========================================

-- True when no owned def remains in any vector. The save protocol
-- can refuse to write while this is false, the same check tools
-- expose.
function buildings_physically_clear(prefix)
    local raws = df.global.world.raws.buildings
    for _, vec in ipairs({ raws.all, raws.workshops, raws.furnaces }) do
        for i = 0, #vec - 1 do
            if has_prefix(vec[i].code, prefix) then
                return false
            end
        end
    end
    return true
end

-- Logs every placed custom building whose custom_type resolves to
-- no definition. After injection this should always report zero;
-- anything else means a reservation failed to hold and says which
-- building, which is the fault the whole ledger exists to prevent.
function orphan_census()
    local live = {}
    for _, d in ipairs(df.global.world.raws.buildings.all) do
        live[d.id] = true
    end

    local orphans = 0
    for _, b in ipairs(df.global.world.buildings.all) do
        local ok, ct = pcall(function() return b:getCustomType() end)
        if ok and ct and ct >= 0 and not live[ct] then
            orphans = orphans + 1
            -- ERROR: the fault the building ledger exists to prevent. This
            -- building's type no longer exists.
            log_census('ERROR', string.format(
                "placed building %d holds dead custom_type %d.",
                b.id, ct), 'ORPHAN')
        end
    end

    if orphans == 0 then
        log_census('DETAIL', "All placed custom buildings resolve.", 'CENSUS')
    end
    return orphans
end


return _ENV