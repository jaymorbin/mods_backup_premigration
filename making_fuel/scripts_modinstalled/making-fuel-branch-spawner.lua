--@ module = true
-- making-fuel-branch-spawner.lua
-- ==========================================
-- MAKING FUEL: THE COMPLETED FELL
-- ==========================================
-- Vanilla pays one log per TRUNK tile and deletes the rest of the
-- tree. Proven by fell forensics: five species exact to the tile,
-- including a thick trunked ginkgo whose thick tiles paid one log
-- each like any other trunk tile.
--
-- This script completes the fell. While a FellTree job runs it
-- reads the standing tree's actual body, and when the tree drops it
-- drops the canopy in kind:
--
--   heavy branch tiles  ->  logs        limb wood, real timber
--   light branch tiles  ->  branches
--   twig tiles          ->  branches    twigs converted to branches
--
-- Counts are LINEAR in the tree's own tiles, per the pins in
-- making-fuel-tuning.lua. Sources are the map's endowment: a rich
-- forest is rich because its trees measure rich, and a map of
-- scrags starves you honestly. The value law governs conversions
-- downstream, never what the world grows.
--
-- NOTHING HERE COUNTS LOGS. The old scan re-rolled strangers' logs
-- inside a 9x9 box and missed late fallers on tall trees. Both
-- problems are structurally impossible now, because the mint reads
-- the tree, not the ground.
--
-- Body access idiom is Lua_API.txt on two dimensional arrays,
-- body:_displace(z).value:_displace(i). Tile bits are df.veg.xml,
-- Bay12 original names. Both carried from making-fuel-fell-probe,
-- where a 300 tree census and every live fell read clean.
-- ==========================================

local repeatUtil = require('repeat-util')
local utils      = require('utils')

local REPEAT_KEY = 'making_fuel_branch_spawner'
-- ---- LOG IDENTITY, DECLARED HERE ----
-- RM core does not know this module exists and must never have to.
-- The onus is on the module to hand RM correct information, so the
-- system and subsystem are stated here rather than inferred anywhere
-- else.
--
-- Guarded reqscript: a bare top level one is a hard load time
-- dependency and has taken a module down before. Without it the log
-- falls back to the same grammar, unsanitised, and the script still
-- loads.
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'BRANCH_SPAWNER'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

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
-- SUBJECT is the correlation slot: FELL for a finished tree, POLL,
-- START and STOP.
--
-- A tree's canopy is a YIELD: the player ordered the fell and this is
-- what it paid. WARNING when the drop came up short of the count, or
-- the tree could not be read at all.
--
-- This replaces a log() that let refinish-log guess TYPE from the
-- words (read_type) unless a call site said otherwise, and printed to
-- the console when RM was not loaded.
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

-- ==========================================
-- TUNING
-- ==========================================
-- fell_drops and the per tile pins live in the tuning file, single
-- source of truth. No number in this file decides a quantity.
-- ==========================================
local tuning = nil
pcall(function() tuning = reqscript('making-fuel-tuning') end)

local function have_tuning()
    return tuning and tuning.T and tuning.fell_drops
end

-- ==========================================
-- TREE BODY COUNTING
-- ==========================================
-- Verbatim from making-fuel-fell-probe. Bit masks per df.veg.xml.
-- thick is counted for the log line but never minted: thick tiles
-- carry the trunk bit too, so vanilla already paid them.
-- ==========================================
local BIT_TRUNK   = 0x0001
local BIT_LIGHT   = 0x0020
local BIT_TWIG    = 0x0040
local BIT_THICK   = 0x0800

local function plane_first(body, z)
    local ok, first = pcall(function()
        return body:_displace(z).value
    end)
    if ok then return first end
    return nil
end

local function tile_at(first, i)
    if i == 0 then return first end
    local ok, t = pcall(function() return first:_displace(i) end)
    if ok then return t end
    return nil
end

local function tile_whole(t)
    local ok, w = pcall(function() return t.whole end)
    if ok and type(w) == 'number' then return w end
    local v = 0
    ok = pcall(function()
        if t.trunk then v = v + BIT_TRUNK end
        if t.branch_w then v = v + 0x0002 end
        if t.branch_n then v = v + 0x0004 end
        if t.branch_e then v = v + 0x0008 end
        if t.branch_s then v = v + 0x0010 end
        if t.branches then v = v + BIT_LIGHT end
        if t.leaves then v = v + BIT_TWIG end
        if t.trunk_is_thick then v = v + BIT_THICK end
    end)
    if ok then return v end
    return nil
end

-- With want_cols it also records WHERE each canopy tile sat, as
-- offsets from the anchor, so the drop lands under the wood that
-- produced it and the tree's own silhouette stamps the ground. A
-- column with five branch tiles stacked appears five times, which
-- weights the drop by where the wood actually was.
local function count_tree(ti, want_cols)
    local c = { trunk = 0, thick = 0, heavy = 0, light = 0, twig = 0 }
    local cols = nil
    if want_cols then
        cols = { heavy = {}, light = {}, twig = {} }
    end
    local per_plane = ti.dim_x * ti.dim_y
    local cx = math.floor(ti.dim_x / 2)
    local cy = math.floor(ti.dim_y / 2)
    for z = 0, ti.body_height - 1 do
        local first = plane_first(ti.body, z)
        if first ~= nil then
            for i = 0, per_plane - 1 do
                local t = tile_at(first, i)
                if t == nil then return nil end
                local w = tile_whole(t)
                if w == nil then return nil end
                if w ~= 0 then
                    local band = w % 0x20
                    local dx = (i % ti.dim_x) - cx
                    local dy = math.floor(i / ti.dim_x) - cy
                    if band % 2 == 1 then c.trunk = c.trunk + 1 end
                    if band >= 2 then
                        c.heavy = c.heavy + 1
                        if cols then
                            table.insert(cols.heavy, { dx, dy, z })
                        end
                    end
                    if math.floor(w / BIT_LIGHT) % 2 == 1 then
                        c.light = c.light + 1
                        if cols then
                            table.insert(cols.light, { dx, dy, z })
                        end
                    end
                    if math.floor(w / BIT_TWIG) % 2 == 1 then
                        c.twig = c.twig + 1
                        if cols then
                            table.insert(cols.twig, { dx, dy, z })
                        end
                    end
                    if math.floor(w / BIT_THICK) % 2 == 1 then
                        c.thick = c.thick + 1
                    end
                end
            end
        end
    end
    return c, cols
end

-- ==========================================
-- PLANT LOOKUP
-- ==========================================
-- The fell designation usually sits on the plant's anchor tile,
-- pass 1. Thick trunks put it on a neighbouring trunk tile, which
-- is what pass 3 caught on the ginkgo. Reported per fell so a
-- convention change in DF shows up in the log instead of as
-- silent misses.
-- ==========================================
local function plants_vector()
    local v = nil
    pcall(function() v = df.global.world.plants.all end)
    if not v then pcall(function() v = df.global.world.plants end) end
    return v
end

-- Pass 1: the designated tile is a tree's anchor, exact xyz.
-- Pass 2: the designated tile is one of a tree's own TRUNK tiles,
-- read from that tree's body at that offset. A fell designation
-- always sits on a trunk tile and trunk tiles belong to exactly
-- one tree, so this is identification, not guessing.
--
-- The old pass 2 matched same x,y at ANY z: a wormhole down the
-- column that once reached through the surface into the caverns
-- and reported a spore tree nobody up top could find, because it
-- was under their feet. The old pass 3 took the first overlapping
-- neighbour and handed a highwood fell to the tree beside it.
local function locate_plant(pos)
    local plants = plants_vector()
    if not plants then return nil end
    local anchor, trunkhit = nil, nil
    pcall(function()
        for _, pl in ipairs(plants) do
            local ti = pl.tree_info
            if ti ~= nil then
                if pl.pos.x == pos.x and pl.pos.y == pos.y
                    and pl.pos.z == pos.z then
                    anchor = pl
                    return
                end
                if not trunkhit then
                    local dz = pos.z - pl.pos.z
                    if dz >= 0 and dz < ti.body_height then
                        local cx = math.floor(ti.dim_x / 2)
                        local cy = math.floor(ti.dim_y / 2)
                        local dx = pos.x - pl.pos.x + cx
                        local dy = pos.y - pl.pos.y + cy
                        if dx >= 0 and dx < ti.dim_x
                            and dy >= 0 and dy < ti.dim_y then
                            local first = plane_first(ti.body, dz)
                            if first then
                                local t = tile_at(first,
                                    dy * ti.dim_x + dx)
                                local w = t and tile_whole(t)
                                if w and w % 2 == 1 then
                                    trunkhit = pl
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
    if anchor then return anchor, 1 end
    if trunkhit then return trunkhit, 2 end
    return nil
end

local function species_of(pl)
    local sid = '?'
    pcall(function()
        sid = df.global.world.raws.plants.all[pl.material].id
    end)
    return sid
end

-- True only if THAT exact tree still stands: same anchor tile, same
-- species. A same species neighbour overlapping the fell site no
-- longer reads as the felled tree surviving.
local function plant_at_anchor(tpos, sid)
    local plants = plants_vector()
    if not plants then return false end
    local hit = false
    pcall(function()
        for _, pl in ipairs(plants) do
            if pl.tree_info ~= nil
                and pl.pos.x == tpos.x
                and pl.pos.y == tpos.y
                and pl.pos.z == tpos.z then
                hit = (species_of(pl) == sid)
                return
            end
        end
    end)
    return hit
end

local function is_cap_species(pl)
    local cap = false
    pcall(function()
        cap = df.global.world.raws.plants.all[pl.material]
            .flags.TREE_HAS_MUSHROOM_CAP
    end)
    return cap
end

-- ==========================================
-- SPAWNING
-- ==========================================
-- Direct createItem, one call per item, then moved to a footprint
-- tile. A monster chestnut mints well over a hundred items and a
-- shell out per item was the old script's cost, not this one's.
--
-- The material is the SPECIES wood, resolved at mint time because
-- a matinfo holds pointers and the memo outlives the tick it was
-- taken on. Species with no WOOD material also have no canopy in
-- practice, but the guard stays because a modded exception should
-- log, not crash.
-- ==========================================
local function wood_mat(sid)
    local mi = nil
    pcall(function()
        mi = dfhack.matinfo.find('PLANT_MAT:' .. sid .. ':WOOD')
    end)
    return mi
end

local function find_tool(id)
    local defs = df.global.world.raws.itemdefs.tools
    for i, td in ipairs(defs) do
        local ok, tid = pcall(function() return td.id end)
        if ok and tid == id then
            local ok2, sub = pcall(function() return td.subtype end)
            if ok2 and type(sub) == 'number' and sub >= 0 then
                return sub
            end
            return i
        end
    end
    return nil
end

-- Vanilla already decided where this tree fell: its own logs are on
-- the ground pointing the way. Read them, species matched, our own
-- minted items excluded through the ledger, and take the centroid
-- as the fall direction. No modelled physics and no seam: whatever
-- DF used to choose the direction, feller skill included if it is
-- in there, is inherited by reading the outcome.
--
-- Returns the log count read and a unit vector. Zero logs, or a
-- centroid hugging the anchor, reports 0,0: direction unreadable,
-- and placement falls back to under the canopy.
local function fall_vector(memo)
    local minted = _G.refinish_fuel_minted or {}
    local n, sx, sy = 0, 0, 0
    pcall(function()
        for dz = -1, 0 do
            for dx = -12, 12 do
                for dy = -12, 12 do
                    local block = dfhack.maps.getTileBlock(
                        memo.pos.x + dx, memo.pos.y + dy,
                        memo.pos.z + dz)
                    if block then
                        for _, item_id in ipairs(block.items) do
                            local item = df.item.find(item_id)
                            if item and not minted[item_id]
                                and item:getType()
                                    == df.item_type.WOOD
                                and item.pos.x == memo.pos.x + dx
                                and item.pos.y == memo.pos.y + dy
                                and item.pos.z == memo.pos.z + dz
                                then
                                local sid = nil
                                pcall(function()
                                    local mi =
                                        dfhack.matinfo.decode(item)
                                    if mi and mi.plant then
                                        sid = mi.plant.id
                                    end
                                end)
                                if sid == memo.species then
                                    n = n + 1
                                    sx = sx + dx
                                    sy = sy + dy
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
    if n == 0 then return 0, 0, 0 end
    local cx, cy = sx / n, sy / n
    local m = math.sqrt(cx * cx + cy * cy)
    if m < 0.6 then return n, 0, 0 end
    return n, cx / m, cy / m
end

-- Items land under the tiles that held the wood: a random column
-- from the tier's own list, so limb logs fall near the trunk,
-- branches under the branch ring, kindling at the twig fringe, and
-- the drop reads as a felled tree rather than a stamped square.
-- Every minted item goes into the shared ledger, id to kind, so
-- the forensic can keep our wood out of vanilla's count.
local function drop_batch(memo, item_type, subtype, mi, n, cols,
        kind, fall)
    local minted = _G.refinish_fuel_minted
    local made = 0
    for _ = 1, n do
        local ok = pcall(function()
            local created = dfhack.items.createItem(
                df.global.world.units.active[0],
                item_type, subtype, mi.type, mi.index)
            local item = created and created[1]
            if not item then error('createItem returned nothing') end
            local dx, dy = 0, 0
            if cols and #cols > 0 then
                local o = cols[math.random(#cols)]
                local ox, oy, oz = o[1], o[2], o[3] or 0
                if fall and (fall.ux ~= 0 or fall.uy ~= 0) then
                    -- Lay the tree down. Height above the anchor
                    -- becomes distance along the fall, the radial
                    -- offset keeps only its perpendicular part, so
                    -- limb logs land base to mid, branches along
                    -- the length, twigs at the far end: the path
                    -- the canopy actually travelled.
                    local dot = ox * fall.ux + oy * fall.uy
                    dx = math.floor(fall.ux * oz
                        + (ox - dot * fall.ux) + 0.5)
                    dy = math.floor(fall.uy * oz
                        + (oy - dot * fall.uy) + 0.5)
                else
                    dx, dy = ox, oy
                end
            end
            dfhack.items.moveToGround(item, {
                x = memo.pos.x + dx,
                y = memo.pos.y + dy,
                z = memo.pos.z })
            if minted then minted[item.id] = kind end
        end)
        if ok then made = made + 1 end
    end
    return made
end

-- ==========================================
-- FELL LIFECYCLE
-- ==========================================
-- Memo on first sight of the job, while the tree stands. Mint when
-- the job vanishes AND the tree is gone; a job that vanishes with
-- the tree still standing was cancelled and mints nothing.
-- ==========================================
local active_fells = {}

local function take_memo(job)
    local pos = { x = job.pos.x, y = job.pos.y, z = job.pos.z }
    local pl, pass = locate_plant(pos)
    if not pl then
        return { pos = pos, species = '?', no_plant = true }
    end
    local c, cols = count_tree(pl.tree_info, true)
    local memo = {
        pos     = pos,
        pass    = pass,
        tpos    = { x = pl.pos.x, y = pl.pos.y, z = pl.pos.z },
        species = species_of(pl),
        cap     = is_cap_species(pl),
        dim_x   = pl.tree_info.dim_x,
        dim_y   = pl.tree_info.dim_y,
        c       = c,
        cols    = cols,
    }
    return memo
end

local function mint(memo)
    if memo.no_plant then
        log('WARNING', string.format(
            'FellTree at %d,%d,%d matched no plant, nothing minted.',
            memo.pos.x, memo.pos.y, memo.pos.z), 'FELL')
        return
    end

    -- Cancelled, not felled: THAT exact tree still standing at its
    -- own anchor. And it says so, because the silent version of
    -- this check ate a highwood fell whole.
    if memo.tpos and plant_at_anchor(memo.tpos, memo.species) then
        log('DETAIL', string.format(
            '%s at %d,%d,%d: fell job ended, tree still standing.'
            .. ' Cancelled, nothing minted.',
            memo.species, memo.pos.x, memo.pos.y, memo.pos.z), 'FELL')
        return
    end

    if not memo.c then
        log('WARNING', string.format(
            '%s at %d,%d,%d: anatomy unreadable, vanilla logs only.',
            memo.species, memo.pos.x, memo.pos.y, memo.pos.z), 'FELL')
        return
    end

    if memo.cap and not tuning.T.CAP_TREES_MINT_BRANCHES then
        log('DETAIL', string.format(
            '%s at %d,%d,%d: cap species, cap flesh is not branch'
            .. ' wood, vanilla logs only.',
            memo.species, memo.pos.x, memo.pos.y, memo.pos.z), 'FELL')
        return
    end

    local lg, br, kd = tuning.fell_drops(
        memo.c.heavy, memo.c.light, memo.c.twig)
    lg = math.floor(lg + 0.5)
    br = math.floor(br + 0.5)
    kd = math.floor(kd + 0.5)

    -- The one clutter switch that predates this system. Limb logs
    -- are the endowment itself and carry no off switch; both
    -- branch streams honour the switch, since both drop as
    -- branches.
    if tuning.T.BYPRODUCTS
        and tuning.T.BYPRODUCTS.BRANCH == false then
        br, kd = 0, 0
    end

    if lg + br + kd == 0 then
        log('DETAIL', string.format(
            '%s at %d,%d,%d: no canopy, vanilla logs only.',
            memo.species, memo.pos.x, memo.pos.y, memo.pos.z), 'FELL')
        return
    end

    local mi = wood_mat(memo.species)
    if not mi then
        log('WARNING', string.format(
            '%s at %d,%d,%d: no WOOD material, cannot mint canopy.',
            memo.species, memo.pos.x, memo.pos.y, memo.pos.z), 'FELL')
        return
    end

    -- Vanilla's own logs point the way this tree fell; our wood
    -- follows them down the same line.
    local fn, fux, fuy = fall_vector(memo)
    local fall = { ux = fux, uy = fuy }

    local cols = memo.cols or {}
    local made_lg, made_br, made_kd = 0, 0, 0
    if lg > 0 then
        made_lg = drop_batch(memo, df.item_type.WOOD, -1, mi,
            lg, cols.heavy, 'log', fall)
    end
    if br + kd > 0 then
        local sub = find_tool('MAKING_FUEL_BRANCH')
        if sub then
            -- Light tile branches land under the branch ring, twig
            -- bundled branches at the canopy fringe: one item, two
            -- placements, true silhouette.
            if br > 0 then
                made_br = drop_batch(memo, df.item_type.TOOL, sub,
                    mi, br, cols.light, 'branch', fall)
            end
            if kd > 0 then
                made_kd = drop_batch(memo, df.item_type.TOOL, sub,
                    mi, kd, cols.twig, 'branch', fall)
            end
        end
    end

    local dir = 'unread'
    if fux ~= 0 or fuy ~= 0 then
        local ns = ''
        if fuy < -0.38 then ns = 'N'
        elseif fuy > 0.38 then ns = 'S' end
        local ew = ''
        if fux > 0.38 then ew = 'E'
        elseif fux < -0.38 then ew = 'W' end
        if ns .. ew ~= '' then dir = ns .. ew end
    end

    local short = ''
    if made_lg ~= lg or made_br ~= br or made_kd ~= kd then
        short = string.format('  SHORT: wanted %d/%d/%d', lg, br, kd)
    end
    log(short ~= '' and 'WARNING' or 'YIELD', string.format(
        '%s at %d,%d,%d (pass %d): trunk %d vanilla | canopy'
        .. ' %d heavy %d light %d twig -> %d logs, %d branches'
        .. ' (%d bundled twigs) | fell %s, %d logs read%s',
        memo.species, memo.pos.x, memo.pos.y, memo.pos.z,
        memo.pass or 0, memo.c.trunk, memo.c.heavy, memo.c.light,
        memo.c.twig, made_lg, made_br + made_kd, made_kd, dir,
        fn, short), 'FELL')
end

local function poll()
    if not dfhack.isMapLoaded() or not _G.refinish_active then return end
    if not have_tuning() then return end

    local ok, err = pcall(function()
        local current = {}
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            if job.job_type == df.job_type.FellTree then
                current[job.id] = true
                if not active_fells[job.id] then
                    active_fells[job.id] = take_memo(job)
                end
            end
        end
        for id, memo in pairs(active_fells) do
            if not current[id] then
                active_fells[id] = nil
                -- Thirty frames: long enough for vanilla's first
                -- wave of logs to land, since they are what the
                -- fall direction is read from, short enough that
                -- hauling has not touched them yet.
                dfhack.timeout(30, 'frames', function() mint(memo) end)
            end
        end
    end)
    if not ok then log('ERROR', 'POLL ERROR: ' .. tostring(err), 'POLL') end
end

function start()
    active_fells = {}
    -- Session scoped ledger of everything this script mints, item
    -- id to kind. The forensic reads it to keep minted wood out of
    -- the vanilla count. Reset here so a recycle starts clean.
    _G.refinish_fuel_minted = {}
    repeatUtil.scheduleEvery(REPEAT_KEY, 10, 'frames', poll)
    log('DETAIL', 'active. Completing fells from tree anatomy.', 'START')
end

function stop()
    repeatUtil.cancel(REPEAT_KEY)
    active_fells = {}
    log('DETAIL', 'terminated.', 'STOP')
end