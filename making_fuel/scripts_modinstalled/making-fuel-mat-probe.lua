-- making-fuel-mat-probe.lua
-- ==========================================
-- MATERIAL PROPERTY PROBE
-- ==========================================
-- Answers one question: which material properties actually vary, and
-- what are the real field names to read them from.
--
-- Exists because two blind guesses at a field path in a row produced a
-- command that ran clean and printed nothing, which is the worst
-- possible failure mode. Nothing here assumes a path. Every candidate
-- is tried, the ones that resolve are reported, and the ones that do
-- not are reported too.
--
-- USAGE
--   making-fuel-mat-probe            survey plant woods and fort items
--   making-fuel-mat-probe dump       print every field of one wood
--                                 material, for when the candidate
--                                 lists below all miss
--   making-fuel-mat-probe flags      print every flag set on one wood
--                                 material, to learn the real bit names
--   making-fuel-mat-probe classes    the class detection report: which
--                                 flag bits actually exist, and what
--                                 class every material in the fort
--                                 would resolve to
-- ==========================================

-- ==========================================
-- BUILD STAMP
-- ==========================================
-- Printed at the top of every run. If the number on screen is not the
-- number you expect, the file in the scripts folder is not the file
-- you just downloaded, and the output is from an older classifier.
--
-- This exists because two probe runs were read as fresh results when
-- they were stale builds, and nothing in the output distinguished
-- them. Bump this on every change.
local PROBE_BUILD = 'B4  layer 1.5 mod materials, MINERAL fallback'
-- ==========================================

local args = {...}
local mode = (args[1] or 'survey'):lower()

print('')
print('making-fuel-mat-probe  build ' .. PROBE_BUILD)

-- ==========================================
-- SAFE PATH WALKER
-- ==========================================
-- Walks a dotted path such as "heat.ignite_point" one step at a time
-- inside a pcall. Returns value, or nil plus the step that failed.
--
-- Indexing a DF struct with a field that does not exist throws rather
-- than returning nil, so this cannot be written with plain lookups.
-- ==========================================
local function dig(obj, path)
    local cur = obj
    for step in string.gmatch(path, '[^%.]+') do
        local ok, nxt = pcall(function() return cur[step] end)
        if not ok or nxt == nil then return nil, step end
        cur = nxt
    end
    return cur
end

-- ==========================================
-- CANDIDATE FIELD PATHS
-- ==========================================
-- Each property lists every path it might live under. The first one
-- that returns a number wins, and which one won gets printed so the
-- answer is recorded rather than rediscovered next time.
-- ==========================================
local CANDIDATES = {
    density = { 'solid_density', 'material.solid_density' },
    ignite  = { 'heat.ignite_point', 'ignite_point',
                'heat_point.ignite', 'heat.ignite' },
    spec    = { 'heat.spec_heat', 'spec_heat' },
    burn    = { 'heat.heatdam_point', 'heatdam_point' },
    value   = { 'material_value', 'value' },
}

-- Resolved once against the first material we can reach, then reused.
local RESOLVED = {}

local function resolve_fields(mat)
    for prop, paths in pairs(CANDIDATES) do
        for _, p in ipairs(paths) do
            local v = dig(mat, p)
            if type(v) == 'number' then
                RESOLVED[prop] = p
                break
            end
        end
    end
end

local function read(mat, prop)
    local p = RESOLVED[prop]
    if not p then return nil end
    return dig(mat, p)
end

-- ==========================================
-- FIND THE WOOD MATERIAL ON A PLANT
-- ==========================================
-- plant_raw.material is a VECTOR of several materials per plant:
-- STRUCTURAL, WOOD, LEAF, DRINK, SEED and so on depending on the
-- species. Index 0 is whichever came first in the raws, which for most
-- trees is not the wood. That assumption is what made the first probe
-- print nothing.
--
-- Match on the material's own id string instead. It is stable, it is
-- what the raws declare, and it needs no flag name to be correct.
-- ==========================================
local function plant_wood(p)
    local n = 0
    pcall(function() n = #p.material end)
    for i = 0, n - 1 do
        local m = nil
        pcall(function() m = p.material[i] end)
        if m then
            local id = nil
            pcall(function() id = tostring(m.id) end)
            if id == 'WOOD' then return m, i end
        end
    end
    return nil
end

-- ==========================================
-- DUMP MODE
-- ==========================================
local function first_wood()
    local n = 0
    pcall(function() n = #df.global.world.raws.plants.all end)
    for i = 0, n - 1 do
        local p = df.global.world.raws.plants.all[i]
        local m = plant_wood(p)
        if m then return m, tostring(p.id) end
    end
    return nil
end

if mode == 'dump' then
    local m, pid = first_wood()
    if not m then
        print('No plant with a WOOD material found.')
        return
    end
    print('Dumping every field on the WOOD material of: ' .. pid)
    print('')
    printall(m)
    return
end

if mode == 'flags' then
    local m, pid = first_wood()
    if not m then
        print('No plant with a WOOD material found.')
        return
    end
    print('Flags on the WOOD material of: ' .. pid)
    print('')
    local ok = pcall(function() printall(m.flags) end)
    if not ok then
        print('m.flags did not resolve. Run "dump" and look for the')
        print('flag container under a different name.')
    end
    return
end

-- ==========================================
-- CLASS DETECTION REPORT
-- ==========================================
-- The yield system needs a material's CLASS (wood, bone, leather,
-- flesh, plant) to pick a multiplier. The plan is to read it off
-- material.flags plus spec_heat, but flag bit names are exactly the
-- kind of thing that has already cost this project two blind guesses,
-- so nothing here assumes one exists.
--
-- Step 1 discovers the real names by iterating the bitfield.
-- Step 2 classifies every material in the fort using only names that
-- were actually found, and prints which rule fired.
--
-- A material landing on UNKNOWN means the rule set has a gap. A
-- material landing on INERT means it must never reach a char reaction,
-- and its reagent needs a gate.
-- ==========================================
if mode == 'classes' then
    local seed = first_wood()
    if not seed then print('No plant WOOD material found.') return end
    resolve_fields(seed)

    -- ---- STEP 1: WHICH FLAG NAMES ACTUALLY EXIST ----
    local names = {}
    local ok = pcall(function()
        for k, _ in pairs(seed.flags) do table.insert(names, tostring(k)) end
    end)
    if not ok or #names == 0 then
        print('Could not iterate material.flags. Run "dump" and read the')
        print('flag container name out of the output instead.')
        return
    end
    table.sort(names)

    -- Only the bits the classifier intends to use. Printed with a
    -- present or missing verdict so a wrong assumption shows up here
    -- rather than three files downstream.
    local WANTED = { 'WOOD', 'STRUCTURAL_PLANT_MAT', 'BONE', 'TOOTH',
                     'HORN', 'HOOF', 'SHELL', 'PEARL', 'LEATHER',
                     'SILK', 'YARN', 'THREAD_PLANT', 'FEATHER',
                     'IS_STONE', 'IS_METAL', 'MEAT', 'EDIBLE_RAW' }
    local have = {}
    for _, n in ipairs(names) do have[n] = true end

    print('==========================================')
    print('STEP 1: FLAG BITS THE CLASSIFIER WANTS')
    print('==========================================')
    print(string.format('  %d flag bits exist on a material.', #names))
    print('')
    local missing = 0
    for _, w in ipairs(WANTED) do
        if have[w] then
            print(string.format('  %-24s PRESENT', w))
        else
            print(string.format('  %-24s MISSING  <<< classifier cannot use this', w))
            missing = missing + 1
        end
    end
    print('')
    if missing > 0 then
        print(string.format('  %d wanted bit(s) do not exist under that name.', missing))
        print('  Full list of real names follows so the rules can be rewritten:')
        print('')
        local line = '   '
        for _, n in ipairs(names) do
            line = line .. n .. ' '
            if #line > 66 then print(line) line = '   ' end
        end
        if #line > 3 then print(line) end
    else
        print('  All wanted bits exist. The classifier can be written as planned.')
    end

    -- ---- STEP 2: CLASSIFY EVERY MATERIAL IN THE FORT ----
    -- Order matters. First rule that matches wins, so the specific
    -- tissue tests come before the broad plant and wood ones.
    -- ---- THREE LAYER CLASSIFIER ----
    -- Flags, then the material's own id string, then mode as a floor.
    --
    -- One layer was not enough. Flags alone left 87 materials UNKNOWN,
    -- every one of which would have silently taken the wood
    -- multiplier, including MAKING_FUEL_CHAR and MAKING_FUEL_DUNG.
    --
    -- Layer 3 cannot fail: every material is plant, creature,
    -- inorganic or builtin, so UNKNOWN becomes impossible rather than
    -- merely unlikely. The report still names the layer that answered,
    -- because a material reaching layer 3 means layers 1 and 2 have a
    -- gap worth closing even though nothing is broken.
    local function classify(mi)
        local m = mi.material
        local f = m.flags
        local function bit(n)
            if not have[n] then return false end
            local v = false
            pcall(function() v = f[n] end)
            return v == true
        end
        local ig = read(m, 'ignite')
        local sp = read(m, 'spec') or 0

        -- Gate. No ignite point means it does not burn, and nothing
        -- else about the material matters.
        if not ig or ig <= 0 or ig >= 60000 then
            return 'INERT', 'no ignite point', 1
        end

        -- ---- LAYER 1: FLAGS ----
        -- spec_heat 4181 is water's specific heat capacity. DF uses it
        -- to mark wet tissue, which is heavy from water rather than
        -- carbon, so density badly over-reads it.
        if sp >= 4000                        then return 'FLESH',   'spec_heat ' .. sp, 1 end
        if bit('BONE') or bit('TOOTH')
           or bit('HORN') or bit('HOOF')
           or bit('SHELL') or bit('PEARL')   then return 'BONE',    'skeletal flag', 1 end
        if bit('LEATHER')                    then return 'LEATHER', 'LEATHER flag', 1 end
        if bit('SILK') or bit('YARN')
           or bit('FEATHER')                 then return 'HAIR',    'fibre flag', 1 end
        if bit('WOOD')                       then return 'WOOD',    'WOOD flag', 1 end
        if bit('THREAD_PLANT')
           or bit('STRUCTURAL_PLANT_MAT')    then return 'PLANT',   'plant flag', 1 end

        -- ---- LAYER 1.5: THE MOD'S OWN MATERIALS ----
        -- Char, dung, straw and mash are organic in every sense that
        -- matters, but DF files them as INORGANIC because a material
        -- RM injects is not attached to a creature or a plant and has
        -- nowhere else to go. Left to the mode fallback they would be
        -- classed alongside lignite, which is wrong twice over: wrong
        -- because they are not mineral, and wrong because CHAR_DUNG
        -- would then read a coal multiplier.
        --
        -- Matched on the TOKEN rather than on m.id, because getToken
        -- is proven to work on every material type here while m.id on
        -- an inorganic is not something this file has verified.
        local tok = ''
        pcall(function() tok = tostring(mi:getToken()):upper() end)
        local MOD_MAT = {
            MAKING_FUEL_CHAR  = 'CHARRED',
            MAKING_FUEL_DUNG  = 'PLANT',
            MAKING_FUEL_STRAW = 'PLANT',
            MAKING_FUEL_MASH  = 'PLANT',
        }
        for name, cls in pairs(MOD_MAT) do
            if tok:find(name, 1, true) then
                return cls, 'mod material ' .. name, 1
            end
        end

        -- ---- LAYER 2: MATERIAL ID ----
        -- The last segment of the token. Stable, declared in the raws,
        -- and the only handle on tissues DF gives no flag for.
        -- Parchment is dried skin and behaves like leather. Demon hair
        -- has no YARN bit because it cannot be sheared, but it is
        -- still hair.
        local id = ''
        pcall(function() id = tostring(m.id):upper() end)
        local BY_ID = {
            PARCHMENT = 'LEATHER', SKIN = 'LEATHER',
            HAIR = 'HAIR', SCALE = 'HAIR', NAIL = 'BONE',
            CHITIN = 'BONE', CARTILAGE = 'BONE',
            SEED = 'PLANT', LEAF = 'PLANT', FRUIT = 'PLANT',
            MILL = 'PLANT', DRINK = 'PLANT', STRUCTURAL = 'PLANT',
            FAT = 'FAT', TALLOW = 'FAT', SOAP = 'FAT',
            WOOD = 'WOOD',
        }
        if BY_ID[id] then return BY_ID[id], 'id ' .. id, 2 end

        -- ---- LAYER 3: MODE ----
        -- Cannot fail, which is the whole point of having it.
        --
        -- What lands here is real mineral fuel: lignite, bituminous,
        -- cannel, vanilla charcoal, and the four diamonds that carry
        -- an ignite point because they are carbon. NO CHAR REACTION
        -- ACCEPTS ANY OF THEM. Coal belongs to the retort and coke
        -- path. So MINERAL is classified for completeness and is not
        -- expected to ever be consulted; if it shows up in a live
        -- yield log, a reagent is missing a gate.
        local mode_s = tostring(mi.mode)
        if mode_s == 'plant'    then return 'PLANT',   'mode plant', 3 end
        if mode_s == 'creature' then return 'FLESH',   'mode creature', 3 end
        return 'MINERAL', 'mode ' .. mode_s .. ', burns', 3
    end

    print('')
    print('==========================================')
    print('STEP 2: EVERY MATERIAL IN THE FORT')
    print('==========================================')
    local by_token, tally = {}, {}
    local n_items = 0
    pcall(function() n_items = #df.global.world.items.all end)
    for i = 0, n_items - 1 do
        local mi = nil
        pcall(function() mi = dfhack.matinfo.decode(df.global.world.items.all[i]) end)
        if mi and mi.material then
            local tok = '?'
            pcall(function() tok = mi:getToken() end)
            if not by_token[tok] then
                local cls, why, layer = classify(mi)
                by_token[tok] = { cls = cls, why = why, layer = layer,
                                  d = read(mi.material, 'density') }
                tally[cls] = (tally[cls] or 0) + 1
            end
        end
    end
    local toks = {}
    for t in pairs(by_token) do table.insert(toks, t) end
    table.sort(toks, function(a, b)
        if by_token[a].cls ~= by_token[b].cls then
            return by_token[a].cls < by_token[b].cls
        end
        return a < b
    end)
    for _, t in ipairs(toks) do
        local r = by_token[t]
        print(string.format('  %-9s L%d %-42s d=%-6s %s',
            r.cls, r.layer or 0, t, tostring(r.d), r.why))
    end

    print('')
    print('==========================================')
    print('TALLY')
    print('==========================================')
    local order = {}
    for c in pairs(tally) do table.insert(order, c) end
    table.sort(order)
    for _, c in ipairs(order) do
        print(string.format('  %-9s %d material(s)', c, tally[c]))
    end
    print('')
    print('  L1 answered on flags, L2 on the material id, L3 on mode.')
    print('  Any UNKNOWN now would be a bug: layer 3 cannot fail.')
    print('  INERT means it must never reach a char reaction. If any')
    print('  inert material is reachable by a char reagent, that')
    print('  reagent needs a material gate.')
    return
end

-- ==========================================
-- SURVEY MODE
-- ==========================================
print('==========================================')
print('MATERIAL PROPERTY SURVEY')
print('==========================================')

-- ---- RESOLVE ONCE ----
local seed = first_wood()
if not seed then
    print('No plant WOOD material found. Nothing to resolve against.')
    return
end
resolve_fields(seed)

print('')
print('FIELD PATHS RESOLVED')
for _, prop in ipairs({ 'density', 'ignite', 'spec', 'burn', 'value' }) do
    if RESOLVED[prop] then
        print(string.format('  %-8s -> %s', prop, RESOLVED[prop]))
    else
        print(string.format('  %-8s -> NOT FOUND (tried: %s)',
            prop, table.concat(CANDIDATES[prop], ', ')))
    end
end

-- ---- PLANT WOODS ----
-- The complete set, not just what happens to be lying in the fort.
print('')
print('==========================================')
print('PLANT WOODS')
print('==========================================')

local rows = {}
local dens_seen = {}
local n_plants = 0
pcall(function() n_plants = #df.global.world.raws.plants.all end)

for i = 0, n_plants - 1 do
    local p = df.global.world.raws.plants.all[i]
    local m, midx = plant_wood(p)
    if m then
        local d = read(m, 'density')
        local ig = read(m, 'ignite')
        table.insert(rows, {
            id  = tostring(p.id),
            idx = midx,
            d   = d,
            ig  = ig,
        })
        if d then dens_seen[d] = (dens_seen[d] or 0) + 1 end
    end
end

table.sort(rows, function(a, b)
    if (a.d or 0) ~= (b.d or 0) then return (a.d or 0) < (b.d or 0) end
    return a.id < b.id
end)

for _, r in ipairs(rows) do
    print(string.format('  %-28s mat[%d]  density=%-8s ignite=%s',
        r.id, r.idx, tostring(r.d), tostring(r.ig)))
end

-- ---- THE VERDICT ----
-- The entire reason this script exists. If every wood reads the same
-- density then a per species material factor cannot be built, no
-- matter how much we would like one, and Stage 2 gets the material
-- CLASS factor only.
print('')
print('==========================================')
print('VERDICT')
print('==========================================')
print(string.format('  %d plant woods found', #rows))

local distinct = 0
local lo, hi = nil, nil
for d, n in pairs(dens_seen) do
    distinct = distinct + 1
    if not lo or d < lo then lo = d end
    if not hi or d > hi then hi = d end
    print(string.format('    density %-8s : %d species', tostring(d), n))
end

if distinct <= 1 then
    print('')
    print('  Every wood reads the SAME density.')
    print('  Per species material factor is not buildable.')
    print('  Stage 2 gets the material CLASS factor only.')
else
    print('')
    print(string.format('  Density VARIES: %d distinct values, %s to %s.',
        distinct, tostring(lo), tostring(hi)))
    print('  Per species material factor is buildable.')
end

-- ---- MATERIAL CLASSES IN THE FORT ----
-- Every distinct material actually reachable from an item, which is
-- what the char reactions will meet. Deduped by token.
print('')
print('==========================================')
print('MATERIALS PRESENT IN THE FORT')
print('==========================================')

local by_token = {}
local n_items = 0
pcall(function() n_items = #df.global.world.items.all end)

for i = 0, n_items - 1 do
    local item = df.global.world.items.all[i]
    local mi = nil
    pcall(function() mi = dfhack.matinfo.decode(item) end)
    if mi and mi.material then
        local tok = '?'
        pcall(function() tok = mi:getToken() end)
        if not by_token[tok] then
            by_token[tok] = {
                mode  = tostring(mi.mode),
                d     = read(mi.material, 'density'),
                ig    = read(mi.material, 'ignite'),
                spec  = read(mi.material, 'spec'),
                count = 0,
            }
        end
        by_token[tok].count = by_token[tok].count + 1
    end
end

local toks = {}
for t in pairs(by_token) do table.insert(toks, t) end
table.sort(toks)

local burnable, inert = 0, 0
for _, t in ipairs(toks) do
    local r = by_token[t]
    -- No ignite point means it does not burn. That is the gate the
    -- char reactions need, and it costs one field.
    local can_burn = (r.ig ~= nil and r.ig > 0 and r.ig < 60000)
    if can_burn then burnable = burnable + 1 else inert = inert + 1 end
    print(string.format('  %-40s %-9s n=%-5d density=%-7s ignite=%-8s %s',
        t, r.mode, r.count, tostring(r.d), tostring(r.ig),
        can_burn and 'BURNS' or 'inert'))
end

print('')
print(string.format('  %d distinct materials: %d burnable, %d inert',
    #toks, burnable, inert))
print('')
print('  An inert material reaching a char reaction is a reagent that')
print('  needs a material restriction it does not currently have.')
