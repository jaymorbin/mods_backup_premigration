--@ module = true
-- making-fuel-fell-probe.lua
-- ==========================================
-- FELL FORENSICS
-- ==========================================
-- Read only. Spawns nothing, changes nothing. Pairs each felled
-- tree's real anatomy with the logs vanilla actually paid for it,
-- which is the number the branch spawner redesign hangs on.
--
-- For every FellTree job this memos the standing tree BEFORE it
-- vanishes: species, body dimensions, and tile counts by category,
-- using the access idiom proven by refinish-branch-probe v2
-- (Lua_API.txt, two dimensional arrays: body:_displace(z).value).
--
-- When the job completes it counts logs three ways:
--
--   attributed   species-matched WOOD items never counted before.
--                The honest number.
--   raw box      every WOOD item in the old spawner's 9x9x2 scan,
--                the number the current spawner acts on. The gap
--                between these two is the contamination, printed.
--   late         attributed logs that appear between the 20 frame
--                settle and a 100 frame recheck, testing whether
--                20 frames is actually enough.
--
-- Each fell prints a law check line comparing attributed logs to
-- trunk, trunk plus thick, and trunk plus heavy, and a preview of
-- what the derived branch law would mint for this exact tree.
--
-- Counted log ids go into a ledger so a later fell nearby cannot
-- count them again. The ledger resets on start.
--
-- Usage from the console:
--   making-fuel-fell-probe start
--   making-fuel-fell-probe stop
--   making-fuel-fell-probe status
--
-- Runs happily alongside the live spawner; it only reads.
-- ==========================================

local repeatUtil = require('repeat-util')
local utils      = require('utils')

local REPEAT_KEY = 'refinish_fell_probe'

-- Preview pins only. The canonical copies land in
-- making-fuel-tuning.lua; these exist so the preview line can print
-- before that round ships. Exact fractions of a log per tile.
local W_HEAVY = 1 / 3
local W_LIGHT = 1 / 12
local W_TWIG  = 1 / 60
local BRANCH_ITEM_VOLUME = 312
local ANCHOR_VOLUME      = 5000

-- ---- LOG IDENTITY, DECLARED HERE ----
-- RM core does not know this module exists and must never have to, so
-- the probe states its own system and subsystem. Guarded reqscript: a
-- bare top level one is a hard load time dependency.
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'FELL_PROBE'
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
-- SUBJECT is the correlation slot: FELL for a finished tree's report,
-- WATCH for a job picked up, POLL, and START, STOP and STATUS for the
-- commands.
--
-- The fell reports are INFO: the probe only runs when started by hand,
-- and those lines are what it was started for.
--
-- This replaces a log() that wrote bare untagged lines under the FELL
-- FORENSIC prefix, and printed them to the console when RM was not
-- loaded.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- The commands are only ever typed at the console, so their answers
-- are also printed: see answer() below. The fell reports arrive later,
-- from the poll, so they go to the log alone.
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

-- ---- THE ANSWER TO A TYPED COMMAND ----
-- Printed, because it is the direct response to what was typed, and
-- logged, because everything goes in the log.
local function answer(typ, msg, subject)
    print('making-fuel-fell-probe: ' .. tostring(msg))
    log(typ, msg, subject)
end

-- ==========================================
-- TREE BODY COUNTING
-- ==========================================
-- Carried over verbatim from refinish-branch-probe v2, where it
-- scanned 300 trees with zero read failures. Bit masks are from
-- df.veg.xml, Bay12 original names.
-- ==========================================
local BIT_TRUNK   = 0x0001
local BIT_LIGHT   = 0x0020
local BIT_TWIG    = 0x0040
local BIT_BLOCKED = 0x0080
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
        if t.blocked then v = v + BIT_BLOCKED end
        if t.trunk_is_thick then v = v + BIT_THICK end
    end)
    if ok then return v end
    return nil
end

local function count_tree(ti)
    local c = { trunk = 0, thick = 0, heavy = 0, light = 0,
                twig = 0, blocked = 0 }
    local per_plane = ti.dim_x * ti.dim_y
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
                    if band % 2 == 1 then c.trunk = c.trunk + 1 end
                    if band >= 2 then c.heavy = c.heavy + 1 end
                    if math.floor(w / BIT_LIGHT) % 2 == 1 then
                        c.light = c.light + 1
                    end
                    if math.floor(w / BIT_TWIG) % 2 == 1 then
                        c.twig = c.twig + 1
                    end
                    if math.floor(w / BIT_THICK) % 2 == 1 then
                        c.thick = c.thick + 1
                    end
                end
            end
        end
    end
    return c
end

-- ==========================================
-- PLANT LOOKUP
-- ==========================================
-- The fell designation sits on a trunk tile; the plant's own pos is
-- its anchor. Which convention connects them is one of the things
-- this probe measures, so the match pass is reported per fell:
--   pass 1  exact x, y and z
--   pass 2  exact x, y any z
--   pass 3  inside the body footprint, centred on the anchor
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

-- ==========================================
-- LOG COUNTING
-- ==========================================
-- seen holds every log id this probe has ever attributed, so a
-- second fell in the same grove cannot count them again. Two
-- adjacent same-species fells racing their settle windows can still
-- split logs between them; the memo notes when another memo of the
-- same species was live at verify time.
-- ==========================================
local seen = {}

-- The old spawner's scan, verbatim geometry: 9x9, z-1 to z0. kept
-- as the contamination baseline. When wide is true the x and y
-- reach grows to the tree's own footprint if that is larger.
local function scan_logs(pos, memo, wide)
    local hx, hy = 4, 4
    if wide then
        hx = math.max(hx, math.ceil(memo.dim_x / 2) + 1)
        hy = math.max(hy, math.ceil(memo.dim_y / 2) + 1)
    end
        local minted = _G.refinish_fuel_minted or {}
    local raw, mine, foreign = 0, {}, 0
    local ours = { log = 0, branch = 0 }
    for dz = -1, 0 do
        for dx = -hx, hx do
            for dy = -hy, hy do
                local block = dfhack.maps.getTileBlock(
                    pos.x + dx, pos.y + dy, pos.z + dz)
                if block then
                    for _, item_id in ipairs(block.items) do
                        local item = df.item.find(item_id)
                        if item
                            and item.pos.x == pos.x + dx
                            and item.pos.y == pos.y + dy
                            and item.pos.z == pos.z + dz then
                            local kind = minted[item_id]
                            if kind then
                                ours[kind] = (ours[kind] or 0) + 1
                            elseif item:getType()
                                == df.item_type.WOOD then
                                raw = raw + 1
                                local sid = nil
                                pcall(function()
                                    local mi =
                                        dfhack.matinfo.decode(item)
                                    if mi and mi.plant then
                                        sid = mi.plant.id
                                    end
                                end)
                                if sid == memo.species then
                                    if not seen[item_id] then
                                        table.insert(mine, item_id)
                                    end
                                else
                                    foreign = foreign + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return raw, mine, foreign, ours
end

-- ==========================================
-- VERDICTS
-- ==========================================
local function law_line(logs, c)
    local function near(a, b) return math.abs(a - b) <= 1 end
    local calls = {}
    if near(logs, c.trunk) then
        table.insert(calls, 'TRUNK')
    end
    if c.thick > 0 and near(logs, c.trunk + c.thick) then
        table.insert(calls, 'TRUNK+THICK')
    end
    if c.heavy > 0 and near(logs, c.trunk + c.heavy) then
        table.insert(calls, 'TRUNK+HEAVY')
    end
    if #calls == 0 then return 'matches NONE of the candidates' end
    return 'matches ' .. table.concat(calls, ' and ')
end

local function preview_line(c)
    local v_with = ANCHOR_VOLUME *
        (c.heavy * W_HEAVY + c.light * W_LIGHT + c.twig * W_TWIG)
    local v_without = ANCHOR_VOLUME *
        (c.light * W_LIGHT + c.twig * W_TWIG)
    local n_with = math.sqrt(v_with / BRANCH_ITEM_VOLUME)
    local n_without = math.sqrt(v_without / BRANCH_ITEM_VOLUME)
    return string.format(
        'law preview: %.1f branches with heavy, %.1f without',
        n_with, n_without)
end

-- ==========================================
-- FELL LIFECYCLE
-- ==========================================
local memos = {}          -- job id -> memo
local results = 0

local function report(memo, mine20, raw20, foreign20, late, rawW,
        ours)
    ours = ours or {}
    log('INFO', string.format('%s at %d,%d,%d (match pass %d)',
        memo.species, memo.pos.x, memo.pos.y, memo.pos.z, memo.pass), 'FELL')
    log('INFO', string.format(
        '  body %dx%dx%d: trunk %d thick %d heavy %d light %d'
        .. ' twig %d blocked %d',
        memo.dim_x, memo.dim_y, memo.height, memo.c.trunk,
        memo.c.thick, memo.c.heavy, memo.c.light, memo.c.twig,
        memo.c.blocked), 'FELL')
    log('INFO', string.format(
        '  vanilla logs: %d | raw box %d | foreign %d | late %d'
        .. ' | footprint %d',
        mine20, raw20, foreign20, late, rawW), 'FELL')
    log('INFO', string.format(
        '  spawner drop seen: %d logs %d branches',
        ours.log or 0, ours.branch or 0), 'FELL')
    log('INFO', '  vanilla ' .. law_line(mine20 + late, memo.c), 'FELL')
    log('INFO', '  ' .. preview_line(memo.c), 'FELL')
    if memo.shared then
        log('INFO', '  note: another live fell of the same species nearby,'
            .. ' attribution may be split between them', 'FELL')
    end
end

local function verify(memo)
    -- The SAME tree still standing at its own anchor means the job
    -- was canceled, not completed. A neighbouring tree of the same
    -- species is not this tree.
    if memo.tpos and plant_at_anchor(memo.tpos, memo.species) then
        log('INFO', string.format('%s at %d,%d,%d: job vanished but tree'
            .. ' stands. Canceled, nothing counted.',
            memo.species, memo.pos.x, memo.pos.y, memo.pos.z), 'FELL')
        return
    end

    for _, other in pairs(memos) do
        if other ~= memo and other.species == memo.species then
            memo.shared = true
        end
    end

    local raw20, mine20, foreign20 = scan_logs(memo.pos, memo, false)
    local rawW, mineW, _, oursW = scan_logs(memo.pos, memo, true)
    -- The wide scan attributes anything the 9x9 missed right now.
    for _, id in ipairs(mineW) do seen[id] = true end
    for _, id in ipairs(mine20) do seen[id] = true end
    local base = math.max(#mine20, #mineW)

    -- Second look at +280 more frames. Tall trees keep delivering
    -- past 100, the apple proved it twice, so the window now waits
    -- them out.
    dfhack.timeout(280, 'frames', function()
        local _, lateIds, _, oursL = scan_logs(memo.pos, memo, true)
        for _, id in ipairs(lateIds) do seen[id] = true end
        for k, v in pairs(oursL) do
            if v > (oursW[k] or 0) then oursW[k] = v end
        end
        results = results + 1
        report(memo, base, raw20, foreign20, #lateIds, rawW, oursW)
    end)
end

local function poll()
    if not dfhack.isMapLoaded() then return end
    local ok, err = pcall(function()
        local current = {}
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            if job.job_type == df.job_type.FellTree then
                current[job.id] = true
                if not memos[job.id] then
                    local pos = { x = job.pos.x, y = job.pos.y,
                                  z = job.pos.z }
                    local pl, pass = locate_plant(pos)
                    if pl then
                        local c = count_tree(pl.tree_info)
                        if c then
                            memos[job.id] = {
                                pos = pos, pass = pass,
                                tpos = { x = pl.pos.x,
                                         y = pl.pos.y,
                                         z = pl.pos.z },
                                species = species_of(pl),
                                dim_x = pl.tree_info.dim_x,
                                dim_y = pl.tree_info.dim_y,
                                height = pl.tree_info.body_height,
                                c = c,
                            }
                            log('DETAIL', string.format(
                                'watching %s at %d,%d,%d',
                                memos[job.id].species,
                                pos.x, pos.y, pos.z), 'WATCH')
                        end
                    else
                        memos[job.id] = { pos = pos, pass = 0,
                            species = '?', dim_x = 0, dim_y = 0,
                            height = 0, no_plant = true,
                            c = { trunk = 0, thick = 0, heavy = 0,
                                  light = 0, twig = 0, blocked = 0 } }
                        log('WARNING', string.format(
                            'FellTree at %d,%d,%d but no plant'
                            .. ' matched any pass. Worth pasting.',
                            pos.x, pos.y, pos.z), 'WATCH')
                    end
                end
            end
        end
        for id, memo in pairs(memos) do
            if not current[id] then
                memos[id] = nil
                if not memo.no_plant then
                    dfhack.timeout(20, 'frames', function()
                        verify(memo)
                    end)
                end
            end
        end
    end)
    if not ok then log('ERROR', 'POLL ERROR: ' .. tostring(err), 'POLL') end
end

-- ==========================================
-- COMMANDS
-- ==========================================
function start()
    memos, seen, results = {}, {}, 0
    repeatUtil.scheduleEvery(REPEAT_KEY, 10, 'frames', poll)
    answer('INFO', 'active. Fell trees; each report lands in the log.',
        'START')
end

function stop()
    repeatUtil.cancel(REPEAT_KEY)
    answer('INFO', 'stopped.', 'STOP')
end

function status()
    local n = 0
    for _ in pairs(memos) do n = n + 1 end
    local s = 0
    for _ in pairs(seen) do s = s + 1 end
    answer('INFO', string.format(
        'watching %d fell jobs, %d results reported, %d log ids'
        .. ' in the ledger.', n, results, s), 'STATUS')
end

-- Console dispatch. When loaded as a module by another script this
-- returns before touching arguments.
if dfhack_flags and dfhack_flags.module then return end
local args = {...}
if args[1] == 'start' then start()
elseif args[1] == 'stop' then stop()
elseif args[1] == 'status' then status()
else
    print('usage: making-fuel-fell-probe start | stop | status')
end