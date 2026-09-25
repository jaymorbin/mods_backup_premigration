--@ module = true
-- refinish-sprite-engine.lua
-- ==========================================
-- RM UNIVERSAL SPRITE ENGINE
-- ==========================================
-- One capability: resolve a sprite from any LIVE source in the
-- loaded game, and write it onto any supported target, at inject
-- time, schema driven. "Live source" means anything that already
-- holds an atlas texpos: a material's sprite slots, a tool
-- itemdef's sprite fields, or a *_graphics_info entry. Texpos is
-- atlas global, so a value read anywhere renders identically
-- wherever it is written; the cross type trick (a boulder's pile
-- art on a dung tool) is a first class operation here, not a hack.
--
-- WHAT THIS DOES NOT DO YET: turn a raw page cell (PAGE:x:y) into
-- a texpos. No live structure holding page grids has been found,
-- so a wanted cell that no live record points at still needs a
-- dummy raws itemdef as its oracle. When the tile page structures
-- are found, that grammar lands here and the oracles retire.
--
-- ==========================================
-- SOURCE GRAMMAR (the string on the right hand side)
-- ==========================================
--   "TEXPOS:12345"                 literal value. VOLATILE across
--                                  sessions; debugging only.
--   "TOOL:ITEM_TOOL_X"             whole donor: every sprite shaped
--                                  field of that tool itemdef, the
--                                  proven copyall behaviour. Only
--                                  valid as a tool target's donor.
--   "TOOL:ITEM_TOOL_X#field"       one named field off a tool
--                                  itemdef.
--   "INFO:anvil:0"                 texpos of
--                                  itemdefs.anvil_graphics_info[0].
--   "PAGE:BOULDERS:1:15"           a raw page cell, resolved
--                                  through df.global.texture.page.
--                                  The dummy oracle killer: any
--                                  cell on any loaded page, by the
--                                  same coordinates the raws speak.
--   "FILE:<path>:<x>:<y>"          a cell of a PNG on disk, loaded
--                                  at runtime. No raws, no tile page.
--   "BUILTIN:COAL#bar"             a builtin material's slot.
--   "INORGANIC:MAGNETITE#boulder1" any matinfo token plus slot.
--   Material slots: bar, wood, boulder1, boulder2, rough1, rough2,
--   cheese1, cheese2, texflag.
--   A material source WITHOUT '#' is legal only where the target
--   itself is a material slot: it means "same slot on the donor",
--   which keeps the original material schema working unchanged.
--
-- Long form anywhere a source is expected:
--   { "source": "...", "offset": n }   offset shifts each resolved
--   value by whole cells; texflag is never offset.
--   { "donor": "..." } is accepted as an alias of source, for
--   backward compatibility with the first material schema.
-- ==========================================

-- ==========================================
-- MATERIAL SLOT MAP
-- ==========================================
-- The slot names the schema speaks, to the fields the material
-- struct actually carries. Flip proven live for inorganics.
local MAT_SLOT_FIELDS = {
    bar      = 'bar_texpos',
    wood     = 'wood_texpos',
    boulder1 = 'boulder_texpos1',
    boulder2 = 'boulder_texpos2',
    rough1   = 'rough_texpos1',
    rough2   = 'rough_texpos2',
    cheese1  = 'cheese_texpos1',
    cheese2  = 'cheese_texpos2',
    texflag  = 'texflag',
}

-- The material TARGET schema still speaks in paired slots, exactly
-- as shipped: one entry covers both fields of a pair.
local MAT_TARGET_SLOTS = {
    bar     = { 'bar_texpos' },
    wood    = { 'wood_texpos' },
    boulder = { 'boulder_texpos1', 'boulder_texpos2' },
    rough   = { 'rough_texpos1',   'rough_texpos2'   },
    cheese  = { 'cheese_texpos1',  'cheese_texpos2'  },
    texflag = { 'texflag' },
}

-- ==========================================
-- TOOL SPRITE FIELD RECOGNITION
-- ==========================================
-- Ported verbatim in spirit from refinish-tool-graphics, the
-- system that has been dressing injected tools all along: fields
-- are sprite shaped by NAME PATTERN, never by a hardcoded list,
-- so a structure update cannot silently strand a new field.
local PATTERNS   = { 'texpos', 'tile', 'graphic', 'sprite', 'color' }
local NEVER_COPY = {
    id = true, subtype = true,
    name = true, name_plural = true, adjective = true,
}

local function looks_graphical(name)
    local lower = string.lower(name)
    for _, p in ipairs(PATTERNS) do
        if string.find(lower, p, 1, true) then return true end
    end
    return false
end

local function field_names(struct)
    local names = {}
    local ok = pcall(function()
        for k in pairs(struct) do
            if type(k) == 'string' then table.insert(names, k) end
        end
    end)
    if not ok then return {} end
    table.sort(names)
    return names
end

-- ==========================================
-- LOG FUNNELS
-- ==========================================
-- This file is RM's own, so it names RM as the owner. It is NOT part
-- of the pipeline: it is a peripheral subsystem that emits a line per
-- sprite, which is 29 of 177 lines in a real startup. That belongs in
-- the scannable stream rather than in the spine, so those lines are
-- DETAIL.
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
-- Three subsystems, as this file always had: GRAPHICS for material
-- sprites, TOOL_SPRITES for tools and SPRITE_EDITS for direct edits.
-- One funnel per subsystem, from the same factory refinish_steel uses,
-- so the call sites no longer pass it. SUBJECT is the material, tool
-- or edit a line is about.
--
-- This replaces a log() that let refinish-log guess TYPE from the
-- words (read_type) unless a call site said otherwise.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here. The prints in CONSOLE AID
-- at the bottom answer commands typed at the console.
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

local log_graphics = make_log('GRAPHICS')
local log_tools    = make_log('TOOL_SPRITES')
local log_edits    = make_log('SPRITE_EDITS')

-- ==========================================
-- LOOKUPS
-- ==========================================
local function find_tool(code)
    local found = nil
    pcall(function()
        for _, td in ipairs(df.global.world.raws.itemdefs.tools) do
            if td.id == code then found = td return end
        end
    end)
    return found
end

-- BUILTIN:<NAME> through mat_table.builtin, anything else through
-- matinfo raws grammar. Returns the material struct or nil.
local function find_material(token)
    local b = token:match('^BUILTIN:(.+)$')
    if b then
        local m = nil
        pcall(function()
            local idx = df.builtin_mats[b]
            if idx then
                m = df.global.world.raws.mat_table.builtin[idx]
            end
        end)
        return m
    end
    local m = nil
    pcall(function()
        local mi = dfhack.matinfo.find(token)
        if mi then m = mi.material end
    end)
    return m
end

-- ==========================================
-- RUNTIME IMAGE CACHE
-- ==========================================
-- [path] = array of TexposHandle, as loadTileset returned it.
-- Session scoped: DF forgets registered textures on shutdown, and a
-- stale handle from a previous run would resolve to nothing.
--
-- file_width lets a multi row sheet be addressed in x and y. Declare
-- one with set_file_width before the first resolve; anything
-- undeclared is read as a single row, which is what a strip is.
local file_cache = {}
local file_width = {}

-- ---- FILE ROOT ----
-- Where a relative FILE path is resolved from. loadTileset resolves
-- a relative path against the process working directory, which is
-- not the mod folder and not reliably the game folder either, so a
-- schema saying images/x.png would look in the wrong place.
--
-- Buildings already solve this: the injector joins the image path to
-- the directory its own JSON came from. This is the same root, set
-- by whoever is injecting before it injects, so images/x.png means
-- the same thing in a materials file as in a buildings file.
--
-- Empty means resolve as given, which is what a caller wanting an
-- absolute path or a game relative one gets.
local file_root = ''

function set_file_root(path)
    file_root = path and tostring(path) or ''
    if file_root ~= '' and not file_root:match('[/\\]$') then
        file_root = file_root .. '/'
    end
end

-- Tile size every FILE source is sliced at. 32 is what DF ships and
-- what every module page here uses.
local CELL_PX = 32

function set_file_width(path, width)
    file_width[path] = width
end

-- ==========================================
-- RESOLUTION
-- ==========================================
-- Returns values, err. values is an array of numbers (usually one;
-- more when the source field is a vector). default_slot serves the
-- material shorthand: a material token with no '#' resolves at the
-- slot the TARGET is asking for.
local function resolve_source(src, default_slot)
    if type(src) ~= 'string' or src == '' then
        return nil, 'source must be a string'
    end

    local lit = src:match('^TEXPOS:(%-?%d+)$')
    if lit then return { tonumber(lit) }, nil end

    local info_name, info_idx = src:match('^INFO:([%w_]+):(%d+)$')
    if info_name then
        local v = nil
        pcall(function()
            local vec = df.global.world.raws.itemdefs
                [info_name .. '_graphics_info']
            v = vec[tonumber(info_idx)].texpos
        end)
        if v then return { v }, nil end
        return nil, 'INFO entry not found: ' .. src
    end

    -- ==========================================
    -- FILE:<path>:<x>:<y>
    -- ==========================================
    -- A cell of an image on disk, sliced at CELL_PX and registered
    -- with DF at runtime. This is the branch that retires the raws
    -- tile page: a module ships a PNG in its own folder and points
    -- a slot straight at it, with nothing declared anywhere.
    --
    -- dfhack.textures.loadTileset slices row major and hands back
    -- TexposHandles. The HANDLE is the durable thing; the texpos
    -- behind it moves whenever DF resets its textures, which is why
    -- the cache holds handles and getTexposByHandle is called on
    -- every resolve rather than once at load.
    --
    -- The path may be absolute or relative to the DF folder. A
    -- module resolving its own data folder through
    -- scriptmanager.getModSourcePath produces the relative form
    -- already, so it can be passed through untouched.
    --
    -- Loaded once per path per session. Loading the same file twice
    -- registers a second copy of every tile, which is a slow leak
    -- rather than a visible fault, so it is worth the cache.
    -- Optional fourth number is the page WIDTH in tiles. It matters
    -- whenever the image is a grid rather than a strip: loadTileset
    -- slices row major and hands back a flat list, so a cell at x,y
    -- is y * width + x and there is no way to recover width from the
    -- list alone. Without it a full page reads as one long row and
    -- any y above 0 lands out of range.
    --
    -- A copied vanilla page uses that page's own width: BOULDERS is
    -- 2 tiles wide, ITEM_CONSTRUCTION is 4, per their TILE_PAGE
    -- declarations. Then every cell index matches the original.
    local f_path, f_x, f_y, f_w = src:match('^FILE:(.+):(%d+):(%d+):(%d+)$')
    if not f_path then
        f_path, f_x, f_y = src:match('^FILE:(.+):(%d+):(%d+)$')
    end
    if f_path then
        if f_w then file_width[f_path] = tonumber(f_w) end
        -- Rooted first, bare second. An absolute path is unchanged by
        -- the join and so answers on the first attempt; a relative
        -- one only resolves once a root has been set. Both are named
        -- on failure, because "could not load" without saying where
        -- it looked is what cost the last round.
        local tried = {}
        local set = file_cache[f_path]
        if not set then
            for _, candidate in ipairs({ file_root .. f_path, f_path }) do
                if not set then
                    table.insert(tried, candidate)
                    local ok, res = pcall(function()
                        return dfhack.textures.loadTileset(
                            candidate, CELL_PX, CELL_PX)
                    end)
                    if ok and type(res) == 'table' and res[1] then
                        set = res
                        -- Cached under the SCHEMA path, not the
                        -- resolved one, so width declared against
                        -- the schema path still matches.
                        file_cache[f_path] = set
                    end
                end
            end
        end
        if not set then
            return nil, 'could not load image: '
                .. table.concat(tried, ' or ')
        end

        -- Row major, and the row width is not knowable from the
        -- handle list alone, so x indexes within the row only when
        -- a width has been declared for this file. Undeclared, the
        -- file is read as a single row, which is what a strip of
        -- item sprites is.
        local w   = file_width[f_path] or #set
        local idx = tonumber(f_y) * w + tonumber(f_x) + 1
        if idx < 1 or idx > #set then
            return nil, string.format(
                'cell %s:%s out of range in %s (%d tiles, row width %d)',
                f_x, f_y, f_path, #set, w)
        end
        local v = nil
        pcall(function()
            v = dfhack.textures.getTexposByHandle(set[idx])
        end)
        if v and v > 0 then return { v }, nil end
        return nil, 'cell has no texpos: ' .. src
    end

    -- PAGE:<TOKEN>:<x>:<y> resolves a raw page cell through the
    -- live page registry at df.global.texture.page, the same
    -- translation the raws parser performs for TOOL_GRAPHICS
    -- lines. This is the branch that retires dummy oracles. Token
    -- match is exact; index is y * page_dim_x + x, bounds checked
    -- because pages vary in size and an out of range cell should
    -- name itself rather than error.
    local pg_name, pg_x, pg_y = src:match('^PAGE:([%w_]+):(%d+):(%d+)$')
    if pg_name then
        local val, why = nil, 'page not found: ' .. pg_name
        pcall(function()
            for _, p in ipairs(df.global.texture.page) do
                if tostring(p.token) == pg_name then
                    local idx = tonumber(pg_y) * p.page_dim_x
                        + tonumber(pg_x)
                    if idx >= 0 and idx < #p.texpos then
                        val = p.texpos[idx]
                        if val == 0 then
                            val, why = nil, 'cell reads 0: ' .. src
                        end
                    else
                        why = string.format(
                            'cell %s:%s out of range on %s (%dx%d)',
                            pg_x, pg_y, pg_name,
                            p.page_dim_x, p.page_dim_y)
                    end
                    return
                end
            end
        end)
        if val then return { val }, nil end
        return nil, why
    end

    local tool_code, tool_field = src:match('^TOOL:([%w_]+)#([%w_]+)$')
    if tool_code then
        local td = find_tool(tool_code)
        if not td then return nil, 'tool not found: ' .. tool_code end
        local vals = nil
        pcall(function()
            local v = td[tool_field]
            if type(v) == 'userdata' then
                vals = {}
                for i = 0, #v - 1 do table.insert(vals, v[i]) end
            else
                vals = { v }
            end
        end)
        if vals then return vals, nil end
        return nil, 'field ' .. tool_field .. ' unreadable on '
            .. tool_code
    end

    if src:match('^TOOL:[%w_]+$') then
        return nil, 'bare TOOL: source is only valid as a tool'
            .. ' target donor'
    end

    -- Material: token, optionally #slot, else the target's slot.
    local token, slot = src:match('^(.+)#([%w_]+)$')
    if not token then token, slot = src, default_slot end
    if not slot then
        return nil, 'material source needs #slot here: ' .. src
    end
    local field = MAT_SLOT_FIELDS[slot] or slot
    local m = find_material(token)
    if not m then return nil, 'material not found: ' .. token end
    local v = nil
    pcall(function() v = m[field] end)
    if v == nil then
        return nil, 'slot ' .. slot .. ' unreadable on ' .. token
    end
    return { v }, nil
end

-- Normalise short/long entry forms to source, offset.
local function entry_parts(entry)
    if type(entry) == 'string' then return entry, 0 end
    if type(entry) == 'table' then
        return entry.source or entry.donor, entry.offset or 0
    end
    return nil, 0
end

-- ==========================================
-- TARGET: MATERIAL
-- ==========================================
-- Behaviour identical to the shipped material handler, with the
-- source side upgraded to the full grammar. Zero valued resolved
-- fields are skipped (a cold or unbound donor slot must not stamp
-- zeros over a target), texflag copies verbatim including zero.
function apply_to_material(material, spec, mat_key)
    if spec == nil then return end
    local applied, failed = {}, {}
    for slot, fields in pairs(MAT_TARGET_SLOTS) do
        local entry = spec[slot]
        if entry ~= nil then
            local src, offset = entry_parts(entry)

            -- TINT:<art> manufactures a texture from THIS material's
            -- own colour instead of reading an existing texpos, so it
            -- is intercepted before resolve_source rather than inside
            -- it: resolve_source takes (src, default_slot) and has no
            -- access to the material, and its last fallback treats an
            -- unrecognised source as a donor material token, which is
            -- how TINT: previously failed as "material not found:
            -- TINT:green_coke".
            --
            -- Both appliers need this. apply_edits has its own copy for
            -- the MATERIAL: target grammar, which is the path the ash
            -- sprite script takes; this is the path the modules' JSON
            -- graphics blocks take. Patching only one made peat work
            -- and the four JSON materials fail.
            --
            -- Every field of a paired slot gets the SAME texpos. The
            -- pair exists so DF can vary the picture, and there is only
            -- one picture here. Offset is meaningless on a manufactured
            -- texpos and is ignored rather than added.
            local tint_art = type(src) == 'string'
                and src:match('^TINT:([%w_]+)$') or nil
            if tint_art then
                local ok_any, why = false, nil
                local art = nil
                pcall(function() art = reqscript('refinish-sprite-art') end)
                if not art then
                    why = 'refinish-sprite-art not available'
                else
                    local tp, e = art.texpos_for(material, tint_art,
                        tostring(mat_key) .. '#' .. slot)
                    if not tp then
                        why = 'TINT:' .. tint_art .. ': ' .. tostring(e)
                    else
                        for _, f in ipairs(fields) do
                            if f ~= 'texflag' then
                                pcall(function()
                                    material[f] = tp
                                    ok_any = true
                                end)
                            end
                        end
                        if not ok_any then
                            why = 'no writable field on slot ' .. slot
                        end
                    end
                end
                table.insert(ok_any and applied or failed,
                    ok_any and slot or (slot .. ': ' .. tostring(why)))
                goto next_slot
            end

            -- Paired target slots pull their two fields from the
            -- donor's matching pair when the source names no slot.
            local ok_any, why = false, nil
            for i, f in ipairs(fields) do
                local default_slot = slot
                if #fields > 1 then default_slot = slot .. i end
                if f == 'texflag' then default_slot = 'texflag' end
                local vals, err = resolve_source(src, default_slot)
                if not vals then
                    why = err
                else
                    pcall(function()
                        local v = vals[1]
                        if v and (v ~= 0 or f == 'texflag') then
                            material[f] = (f == 'texflag')
                                and v or (v + offset)
                            ok_any = true
                        elseif not why then
                            why = 'source read 0, skipped'
                        end
                    end)
                end
            end
            table.insert(ok_any and applied or failed,
                ok_any and slot or (slot .. ': ' .. tostring(why)))
        end
        ::next_slot::
    end
    if #applied + #failed > 0 then
        -- DETAIL as a rule, one line per sprite. WARNING when a slot failed:
        -- that sprite is missing, which is cosmetic. refinish-log used to
        -- read FAILED in the text and call it ERROR.
        log_graphics(#failed > 0 and 'WARNING' or 'DETAIL', string.format('applied [%s]%s',
            table.concat(applied, ','),
            #failed > 0
                and ('  FAILED [' .. table.concat(failed, '; ') .. ']')
                or ''), tostring(mat_key))
    end
end

-- ==========================================
-- TARGET: TOOL ITEMDEF
-- ==========================================
-- Two layers, combinable. donor runs first, fields refine after,
-- so a tool can wear a whole donor look and then override one
-- field from anywhere.
--
--   "graphics": {
--     "donor":  "TOOL:ITEM_TOOL_DUNG_DUMMY",
--     "fields": {
--       "texpos": { "source": "BUILTIN:COAL#bar", "offset": 0 }
--     }
--   }
--
-- donor copy is the ported proven core: every sprite shaped field,
-- vectors copied element by element rather than by reference,
-- because assigning the object would alias the donor's storage and
-- a later write to one tool would silently change the other.
--
-- A fields write into a VECTOR field fills every existing element
-- with the resolved value when the source gave one value (the pile
-- on every rotation case), and copies element wise when the source
-- gave a matching vector.
local function copy_whole_donor(target, donor_code)
    local code = donor_code:match('^TOOL:([%w_]+)$') or donor_code
    local donor = find_tool(code)
    if not donor then return 0, 'donor tool not found: ' .. code end
    local copied = 0
    for _, name in ipairs(field_names(donor)) do
        if not NEVER_COPY[name] and looks_graphical(name) then
            local ok_d, dv = pcall(function() return donor[name] end)
            if ok_d then
                if type(dv) == 'userdata' then
                    local ok_w = pcall(function()
                        local len = #dv
                        local tv = target[name]
                        -- Fixed arrays cannot resize; grow only a
                        -- genuinely empty vector, tolerantly, and
                        -- copy element wise into whatever length
                        -- the target truly has.
                        if #tv == 0 and len > 0 then
                            pcall(function() tv:resize(len) end)
                        end
                        for i = 0, math.min(#tv, len) - 1 do
                            tv[i] = dv[i]
                        end
                    end)
                    if ok_w then copied = copied + 1 end
                else
                    local ok_w = pcall(function()
                        target[name] = dv
                    end)
                    if ok_w then copied = copied + 1 end
                end
            end
        end
    end
    return copied, nil
end

function apply_to_tool(td, spec, tool_key)
    if spec == nil then return end
    local applied, failed = {}, {}

    if spec.donor then
        local src = entry_parts(spec.donor)
        local n, err = copy_whole_donor(td, src or '')
        if err then table.insert(failed, 'donor: ' .. err)
        else table.insert(applied,
            string.format('donor(%d fields)', n)) end
    end

    if type(spec.fields) == 'table' then
        for fname, entry in pairs(spec.fields) do
            local src, offset = entry_parts(entry)
            -- fill: explicit vector length for writes into a
            -- vector field, needed on freshly injected tools whose
            -- vectors start EMPTY (filling zero existing elements
            -- writes nothing). The parser fans one cell into 7
            -- slot material class vectors; the schema states that
            -- 7 rather than the engine assuming it.
            local fill = type(entry) == 'table' and entry.fill or nil
            local vals, err = resolve_source(src, nil)
            if not vals then
                table.insert(failed, fname .. ': ' .. tostring(err))
            else
                local ok_w, w_err = pcall(function()
                    local cur = td[fname]
                    if type(cur) == 'userdata' then
                        -- MEASURED: these are fixed int32_t arrays,
                        -- not vectors. resize() does not exist on
                        -- them and throws, which was the whole
                        -- failure. Writes are element wise into
                        -- whatever length exists. resize is
                        -- attempted, tolerantly, ONLY on a length
                        -- zero target, the true empty vector case,
                        -- where fill states the size.
                        local n = #cur
                        if n == 0 and (fill or #vals > 1) then
                            pcall(function()
                                cur:resize(fill or #vals)
                            end)
                            n = #cur
                        end
                        if n == 0 then
                            error('target has zero length and'
                                .. ' could not be grown')
                        end
                        if #vals == 1 then
                            for i = 0, n - 1 do
                                cur[i] = vals[1] + offset
                            end
                        else
                            for i = 0, math.min(n, #vals) - 1 do
                                cur[i] = vals[i + 1] + offset
                            end
                        end
                    else
                        td[fname] = vals[1] + offset
                    end
                end)
                -- The real error text travels to the log. A write
                -- failure that reports only "write failed" is an
                -- unanswerable bug report, and this engine does not
                -- produce those.
                table.insert(ok_w and applied or failed,
                    ok_w and fname
                    or (fname .. ': ' .. tostring(w_err)))
            end
        end
    end

    if #applied + #failed > 0 then
        log_tools(#failed > 0 and 'WARNING' or 'DETAIL', string.format('applied [%s]%s',
            table.concat(applied, ','),
            #failed > 0
                and ('  FAILED [' .. table.concat(failed, '; ') .. ']')
                or ''), tostring(tool_key))
    end
end

-- ==========================================
-- GRAPHICS SURFACE REGISTRY
-- ==========================================
-- Every remaining sprite surface in the loaded game, transcribed
-- from a live depth 2 dump of world.raws, addressed by short name.
-- container: dotted path under df.global.world.raws
-- struct:    df type name for appends
-- shape:     'simple' means the proven {flags, texpos} item shape;
--            'rich' means multi field (workshops, wagons, floors,
--            trees), which the engine addresses but never assumes:
--            writes there name their fields explicitly.
-- Entry counts CHANGE AT RUNTIME (bin grew 4 to 5, bar 0 to 1
-- between dumps), so nothing here ever hardcodes a count.
local INFO_SURFACES = {
    -- itemdefs family, simple shape
    coin={c='itemdefs',v='coin_graphics_info',t='item_coin_graphics_infost',s='simple'},
    figurine={c='itemdefs',v='figurine_graphics_info',t='item_craft_graphics_infost',s='simple'},
    amulet={c='itemdefs',v='amulet_graphics_info',t='item_craft_graphics_infost',s='simple'},
    scepter={c='itemdefs',v='scepter_graphics_info',t='item_craft_graphics_infost',s='simple'},
    crown={c='itemdefs',v='crown_graphics_info',t='item_craft_graphics_infost',s='simple'},
    ring={c='itemdefs',v='ring_graphics_info',t='item_craft_graphics_infost',s='simple'},
    bracelet={c='itemdefs',v='bracelet_graphics_info',t='item_craft_graphics_infost',s='simple'},
    earring={c='itemdefs',v='earring_graphics_info',t='item_craft_graphics_infost',s='simple'},
    bld_chain={c='itemdefs',v='bld_chain_graphics_info',t='item_bld_chain_graphics_infost',s='simple'},
    table={c='itemdefs',v='table_graphics_info',t='item_table_graphics_infost',s='simple'},
    window={c='itemdefs',v='window_graphics_info',t='item_window_graphics_infost',s='simple'},
    chair={c='itemdefs',v='chair_graphics_info',t='item_chair_graphics_infost',s='simple'},
    cabinet={c='itemdefs',v='cabinet_graphics_info',t='item_cabinet_graphics_infost',s='simple'},
    bed={c='itemdefs',v='bed_graphics_info',t='item_bed_graphics_infost',s='simple'},
    statue={c='itemdefs',v='statue_graphics_info',t='item_statue_graphics_infost',s='simple'},
    box={c='itemdefs',v='box_graphics_info',t='item_box_graphics_infost',s='simple'},
    door={c='itemdefs',v='door_graphics_info',t='item_door_graphics_infost',s='simple'},
    grate={c='itemdefs',v='grate_graphics_info',t='item_grate_graphics_infost',s='simple'},
    hatch_cover={c='itemdefs',v='hatch_cover_graphics_info',t='item_hatch_cover_graphics_infost',s='simple'},
    floodgate={c='itemdefs',v='floodgate_graphics_info',t='item_floodgate_graphics_infost',s='simple'},
    traction_bench={c='itemdefs',v='traction_bench_graphics_info',t='item_traction_bench_graphics_infost',s='simple'},
    coffin={c='itemdefs',v='coffin_graphics_info',t='item_coffin_graphics_infost',s='simple'},
    cloth={c='itemdefs',v='cloth_graphics_info',t='item_cloth_graphics_infost',s='simple'},
    splint={c='itemdefs',v='splint_graphics_info',t='item_splint_graphics_infost',s='simple'},
    crutch={c='itemdefs',v='crutch_graphics_info',t='item_crutch_graphics_infost',s='simple'},
    slab={c='itemdefs',v='slab_graphics_info',t='item_slab_graphics_infost',s='simple'},
    cage={c='itemdefs',v='cage_graphics_info',t='item_cage_graphics_infost',s='simple'},
    bucket={c='itemdefs',v='bucket_graphics_info',t='item_bucket_graphics_infost',s='simple'},
    animal_trap={c='itemdefs',v='animal_trap_graphics_info',t='item_animal_trap_graphics_infost',s='simple'},
    bin={c='itemdefs',v='bin_graphics_info',t='item_bin_graphics_infost',s='simple'},
    bag={c='itemdefs',v='bag_graphics_info',t='item_bag_graphics_infost',s='simple'},
    anvil={c='itemdefs',v='anvil_graphics_info',t='item_anvil_graphics_infost',s='simple'},
    thread={c='itemdefs',v='thread_graphics_info',t='item_thread_graphics_infost',s='simple'},
    backpack={c='itemdefs',v='backpack_graphics_info',t='item_backpack_graphics_infost',s='simple'},
    quiver={c='itemdefs',v='quiver_graphics_info',t='item_quiver_graphics_infost',s='simple'},
    catapult_parts={c='itemdefs',v='catapult_parts_graphics_info',t='item_catapult_parts_graphics_infost',s='simple'},
    ballista_parts={c='itemdefs',v='ballista_parts_graphics_info',t='item_ballista_parts_graphics_infost',s='simple'},
    bolt_thrower_parts={c='itemdefs',v='bolt_thrower_parts_graphics_info',t='item_bolt_thrower_parts_graphics_infost',s='simple'},
    mechanisms={c='itemdefs',v='mechanisms_graphics_info',t='item_mechanisms_graphics_infost',s='simple'},
    egg={c='itemdefs',v='egg_graphics_info',t='item_egg_graphics_infost',s='simple'},
    book={c='itemdefs',v='book_graphics_info',t='item_book_graphics_infost',s='simple'},
    wood_barrel={c='itemdefs',v='wood_barrel_graphics_info',t='item_food_container_graphics_infost',s='simple'},
    metal_barrel={c='itemdefs',v='metal_barrel_graphics_info',t='item_food_container_graphics_infost',s='simple'},
    chain={c='itemdefs',v='chain_graphics_info',t='item_chain_graphics_infost',s='simple'},
    flask={c='itemdefs',v='flask_graphics_info',t='item_flask_graphics_infost',s='simple'},
    goblet={c='itemdefs',v='goblet_graphics_info',t='item_goblet_graphics_infost',s='simple'},
    bar={c='itemdefs',v='bar_graphics_info',t='item_bar_graphics_infost',s='simple'},
    block={c='itemdefs',v='block_graphics_info',t='item_block_graphics_infost',s='simple'},
    wood={c='itemdefs',v='wood_graphics_info',t='item_wood_graphics_infost',s='simple'},
    gem={c='itemdefs',v='gem_graphics_info',t='item_gem_graphics_infost',s='simple'},
    sheet={c='itemdefs',v='sheet_graphics_info',t='item_sheet_graphics_infost',s='simple'},
    instrument={c='itemdefs',v='instrument_graphics_info',t='item_instrument_graphics_infost',s='simple'},
    liquid={c='itemdefs',v='liquid_graphics_info',t='item_liquid_graphics_infost',s='simple'},
    powder={c='itemdefs',v='powder_graphics_info',t='item_powder_graphics_infost',s='simple'},
    pipe_section={c='itemdefs',v='pipe_section_graphics_info',t='item_pipe_section_graphics_infost',s='simple'},
    rock={c='itemdefs',v='rock_graphics_info',t='item_rock_graphics_infost',s='simple'},
    totem={c='itemdefs',v='totem_graphics_info',t='item_totem_graphics_infost',s='simple'},
    skin_tanned={c='itemdefs',v='skin_tanned_graphics_info',t='item_skin_tanned_graphics_infost',s='simple'},
    bodypart_skin={c='itemdefs',v='bodypart_skin_graphics_info',t='item_bodypart_skin_graphics_infost',s='simple'},
    -- plants, rich
    tree_leaf={c='plants',v='tree_leaf_graphics_info',t='tree_leaf_graphics_infost',s='rich'},
    tree_wood={c='plants',v='tree_wood_graphics_info',t='tree_wood_graphics_infost',s='rich'},
    -- descriptors, rich
    boulder_floor={c='descriptors',v='boulder_floor_graphics_info',t='boulder_floor_graphics_infost',s='rich'},
    engraved_floor={c='descriptors',v='engraved_floor_graphics_info',t='engraved_floor_graphics_infost',s='rich'},
    wood_floor={c='descriptors',v='wood_floor_graphics_info',t='wood_floor_graphics_infost',s='rich'},
    metal_floor={c='descriptors',v='metal_floor_graphics_info',t='metal_floor_graphics_infost',s='rich'},
    stone_block_floor={c='descriptors',v='stone_block_floor_graphics_info',t='stone_block_floor_graphics_infost',s='rich'},
    wall={c='descriptors',v='wall_graphics_info',t='wall_graphics_infost',s='rich'},
    ramp={c='descriptors',v='ramp_graphics_info',t='ramp_graphics_infost',s='rich'},
    stair={c='descriptors',v='stair_graphics_info',t='stair_graphics_infost',s='rich'},
    fortification={c='descriptors',v='fortification_graphics_info',t='fortification_graphics_infost',s='rich'},
    track={c='descriptors',v='track_graphics_info',t='track_graphics_infost',s='rich'},
    spatter={c='descriptors',v='spatter_graphics_info',t='spatter_graphics_infost',s='rich'},
    -- buildings, rich
    wagon={c='buildings',v='wagon_graphics_info',t='building_wagon_graphics_infost',s='rich'},
    workshop={c='buildings',v='workshop_graphics_info',t='workshop_graphics_infost',s='rich'},
    trap={c='buildings',v='trap_graphics_info',t='building_trap_graphics_infost',s='rich'},
    bridge={c='buildings',v='bridge_graphics_info',t='building_bridge_graphics_infost',s='rich'},
    windmill={c='buildings',v='windmill_graphics_info',t='building_windmill_graphics_infost',s='rich'},
    water_wheel={c='buildings',v='water_wheel_graphics_info',t='building_water_wheel_graphics_infost',s='rich'},
    screwpump={c='buildings',v='screwpump_graphics_info',t='building_screwpump_graphics_infost',s='rich'},
    support={c='buildings',v='support_graphics_info',t='building_support_graphics_infost',s='rich'},
    track_stop={c='buildings',v='track_stop_graphics_info',t='building_track_stop_graphics_infost',s='rich'},
}

local function surface_vector(name)
    local e = INFO_SURFACES[name]
    if not e then return nil, nil, 'unknown surface: ' .. tostring(name) end
    local vec = nil
    pcall(function()
        vec = df.global.world.raws[e.c][e.v]
    end)
    if not vec then return nil, nil, 'surface unreachable: ' .. name end
    return vec, e, nil
end

-- ==========================================
-- UNIVERSAL EDITS
-- ==========================================
-- One edit = one write, target grammar mirroring source grammar:
--   { target = "INFO:bin:2",            source = "PAGE:ITEMS:0:0" }
--   { target = "INFO:bar:+",            source = "BUILTIN:COAL#bar" }
--   { target = "INFO:workshop:1",       fields = { <name> = <src>, ... } }
--   { target = "TOOL:ITEM_TOOL_X#texpos_item", source = ..., offset, fill }
--   { target = "MATERIAL:BUILTIN:COAL#bar",    source = ... }
--   { target = "STATUE_TOP:5", source = ... }   (and STATUE_BOTTOM)
-- INFO index '+' appends a fresh struct (registry type) before
-- writing. simple surfaces default their written field to texpos
-- when only source is given; rich surfaces REQUIRE fields, the
-- engine refuses to guess their layout.
function apply_edits(edits, tag)
    if type(edits) ~= 'table' then return end
    local applied, failed = {}, {}
    for i, ed in ipairs(edits) do
        local label = tostring(ed.target or ('edit ' .. i))
        local ok, why = false, 'unrecognised target'
        pcall(function()
            local t = tostring(ed.target or '')
            local sname, sidx = t:match('^INFO:([%w_]+):([%d%+]+)$')
            if sname then
                local vec, meta, err = surface_vector(sname)
                if not vec then why = err return end
                local entry = nil
                if sidx == '+' then
                    entry = df[meta.t]:new()
                    vec:insert('#', entry)
                else
                    local n = tonumber(sidx)
                    if n and n >= 0 and n < #vec then entry = vec[n]
                    else why = 'index out of range on ' .. sname return end
                end
                if ed.fields then
                    for fname, src in pairs(ed.fields) do
                        local s, off = entry_parts(src)
                        local vals, e2 = resolve_source(s, nil)
                        if vals then
                            pcall(function()
                                entry[fname] = vals[1] + off
                            end)
                        else why = fname .. ': ' .. tostring(e2) end
                    end
                    ok = why == 'unrecognised target'
                elseif meta.s == 'simple' and ed.source then
                    local s, off = entry_parts(ed)
                    local vals, e2 = resolve_source(s, nil)
                    if vals then
                        entry.texpos = vals[1] + off
                        ok = true
                    else why = tostring(e2) end
                else
                    why = 'rich surface ' .. sname
                        .. ' requires an explicit fields map'
                end
                return
            end
            local st_which, st_i = t:match('^STATUE_(%u+):(%d+)$')
            if st_which then
                local arr = df.global.world.raws.itemdefs[
                    'statue_texpos_' .. st_which:lower()]
                local s, off = entry_parts(ed)
                local vals, e2 = resolve_source(s, nil)
                if not vals then why = tostring(e2) return end
                local n = tonumber(st_i)
                if arr and n < #arr then
                    arr[n] = vals[1] + off
                    ok = true
                else why = 'statue index out of range' end
                return
            end
            local tcode, tfield = t:match('^TOOL:([%w_]+)#([%w_]+)$')
            if tcode then
                local td = find_tool(tcode)
                if not td then why = 'tool not found: ' .. tcode return end
                local spec = { fields = { [tfield] = {
                    source = ed.source, offset = ed.offset,
                    fill = ed.fill } } }
                apply_to_tool(td, spec, tcode)
                ok = true
                return
            end
            local mtoken, mslot = t:match('^MATERIAL:(.+)#([%w_]+)$')
            if mtoken then
                local m = find_material(mtoken)
                if not m then why = 'material not found: ' .. mtoken return end
                local field = MAT_SLOT_FIELDS[mslot] or mslot
                local s, off = entry_parts(ed)

                -- TINT:<art> manufactures its own texture from the
                -- material's colour instead of pointing at an existing
                -- one. It is handled HERE rather than in resolve_source
                -- because it needs the material, and resolve_source's
                -- signature is (src, default_slot) with no target.
                -- Threading a third argument through would touch all
                -- seven call sites when only this one needs it.
                --
                -- Offset is meaningless on a manufactured texpos, so it
                -- is ignored rather than added.
                local art_name = type(s) == 'string'
                    and s:match('^TINT:([%w_]+)$') or nil
                if art_name then
                    local art = reqscript('refinish-sprite-art')
                    local tp, e3 = art.texpos_for(m, art_name)
                    if not tp then
                        why = 'TINT:' .. art_name .. ': ' .. tostring(e3)
                        return
                    end
                    pcall(function() m[field] = tp ok = true end)
                    return
                end

                local vals, e2 = resolve_source(s, mslot)
                if not vals then why = tostring(e2) return end
                pcall(function()
                    m[field] = (field == 'texflag') and vals[1]
                        or (vals[1] + off)
                    ok = true
                end)
                return
            end
        end)
        table.insert(ok and applied or failed,
            ok and label or (label .. ': ' .. tostring(why)))
    end
    if #applied + #failed > 0 then
        log_edits(#failed > 0 and 'WARNING' or 'DETAIL', string.format('applied [%s]%s',
            table.concat(applied, ','),
            #failed > 0
                and ('  FAILED [' .. table.concat(failed, '; ') .. ']')
                or ''), tostring(tag or '?'))
    end
end

-- ==========================================
-- CONSOLE AID
-- ==========================================
-- Lists a tool itemdef's sprite shaped fields and current values,
-- for writing fields maps without guessing. The probe verb in
-- refinish-tool-graphics remains the deeper diff instrument.
function list_tool_sprite_fields(code)
    local td = find_tool(code)
    if not td then print('tool not found: ' .. tostring(code)) return end
    for _, name in ipairs(field_names(td)) do
        if looks_graphical(name) and not NEVER_COPY[name] then
            local v = nil
            pcall(function() v = td[name] end)
            if type(v) == 'userdata' then
                local parts = {}
                pcall(function()
                    for i = 0, math.min(#v - 1, 11) do
                        table.insert(parts, tostring(v[i]))
                    end
                end)
                print(string.format('  %-24s [%s]', name,
                    table.concat(parts, ',')))
            else
                print(string.format('  %-24s %s', name, tostring(v)))
            end
        end
    end
end

if dfhack_flags and dfhack_flags.module then return end
local args = {...}
if args[1] == 'fields' and args[2] then
    list_tool_sprite_fields(args[2])
elseif args[1] == 'mat' and args[2] then
    -- Re-enumerates the material struct's sprite fields by the
    -- same pattern scan that produced MAT_SLOT_FIELDS, zeros
    -- included. Run after any DF update: a field printed here
    -- that the map lacks is the map's next line.
    local m = find_material(args[2])
    if not m then print('material not found: ' .. args[2]) return end
    for k, v in pairs(m) do
        local s = tostring(k):lower()
        if s:find('tex') or s:find('graphic') then
            print(string.format('  %-20s %s', tostring(k),
                tostring(v)))
        end
    end
elseif args[1] == 'surfaces' then
    for name, e in pairs(INFO_SURFACES) do
        local vec = surface_vector(name)
        print(string.format('  %-20s n=%-4s %s',
            name, vec and #vec or '?', e.s))
    end
elseif args[1] == 'info' and args[2] then
    -- Prints one entry's full field set: the discovery step that
    -- rich surface edits are written from, never guessed.
    local vec, _, err = surface_vector(args[2])
    if not vec then print(err) return end
    local n = tonumber(args[3] or 0)
    if n >= #vec then print('index out of range, n=' .. #vec) return end
    printall(vec[n])
else
    print('usage: refinish-sprite-engine fields <ITEMDEF_CODE>')
    print('       refinish-sprite-engine surfaces')
    print('       refinish-sprite-engine info <surface> [index]')
end