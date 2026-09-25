-- making-fuel-curve.lua
-- ==========================================
-- FUEL CURVE PREVIEW
-- ==========================================
-- Prints the entire yield curve from the current contents of
-- making-fuel-tuning.lua, then runs the invariant checks.
--
-- Pure arithmetic. No world needs to be loaded, nothing is injected,
-- nothing is read out of DF. Edit a number in the tuning file, run
-- this, see every consequence at once. That loop is the point: it is
-- the difference between changing a constant and finding out what it
-- did, and changing a constant and finding out three days later.
--
-- WHAT THIS IS NOT
--   It is not a report on the fort. The item and creature tables are
--   fixed sample inputs used to draw the curve's shape. The running
--   system never reads them: the ghost and hijacker measure the real
--   item in the real job every time.
--
--   The INVARIANT CHECKS at the bottom are different. They compute
--   from the tuning constants directly and are the part of this
--   script that can actually catch a broken setting.
--
-- USAGE
--   making-fuel-curve             the full report
--   making-fuel-curve check       just the invariant checks
--   making-fuel-curve items       just the item table
--   making-fuel-curve corpses     just the creature table
-- ==========================================

local ok_load, tuning = pcall(reqscript, 'making-fuel-tuning')
if not ok_load or not tuning then
    print('Could not load making-fuel-tuning. Is it in the same')
    print('scripts folder? Error: ' .. tostring(tuning))
    return
end

local T    = tuning.T
local args = {...}
local mode = (args[1] or 'all'):lower()

local function hr(title)
    print('')
    print('==================================================================')
    if title then print(title) end
    print('==================================================================')
end

-- ==========================================
-- REFERENCE ITEMS
-- ==========================================
-- ILLUSTRATION ONLY. These rows feed nothing. They are sample inputs
-- run through the real formula so the shape of the curve can be read
-- at a glance, and they are consumed by exactly one print loop.
--
-- The ghost and the hijacker never touch this table. They call
-- item:getVolume() on the actual item in the actual job, which is why
-- their logs show a kumquat chair at 3000 without anything here being
-- consulted.
--
-- Every volume below now comes from a real probe or ghost log. The
-- previous set used wiki figures divided by ten for anything not yet
-- seen in world, which put chair at 700 and door at 1000 when both
-- are really 3000, and made this chart misleading to read balance
-- off.
-- ==========================================
local ITEMS = {
    { 'log (WOOD)',       5000 },
    { 'slab',             6000 },
    { 'minecart',         4000 },
    { 'stepladder',       4000 },
    { 'chair / door',     3000 },
    { 'table / bed',      3000 },
    { 'cabinet / coffin', 3000 },
    { 'cage / chest',     3000 },
    { 'barrel',           2000 },
    { 'mechanisms',       2000 },
    { 'armor stand',      1000 },
    { 'hatch / grate',    1000 },
    { 'instrument',        400 },
    { 'branch',            312 },
    { 'bucket',            300 },
    { 'animal trap',       300 },
    { 'hive',              200 },
    { 'figurine',          100 },
    { 'bookcase / goblet', 100 },
    { 'kindling',           78 },
    { 'sawdust',            78 },
    { 'bark',               78 },
    { 'jug',                30 },
    { 'twig',               20 },
    { 'earring',             3 },
}

-- Every distinct vanilla wood density, with a representative species.
local WOODS = {
    { 'feather tree',  100 }, { 'papaya',        130 },
    { 'kapok',         260 }, { 'willow',        390 },
    { 'cherry',        425 }, { 'ginkgo',        450 },
    { 'highwood',      500 }, { 'pine',          510 },
    { 'nether cap',    550 }, { 'hazel',         580 },
    { 'tower cap',     600 }, { 'black cap',     650 },
    { 'oak',           700 }, { 'pecan',         735 },
    { 'peach',         795 }, { 'mangrove',      830 },
    { 'lychee',        880 }, { 'olive',         990 },
    { 'glumprong',    1200 }, { 'blood thorn',  1250 },
}

-- ILLUSTRATION ONLY, and the least reliable table here. These sizes
-- are guesses, not measurements: the sperm whale entry is roughly a
-- twentieth of the real adult_size. The shape of the curve is right,
-- the absolute numbers are not.
--
-- Nothing reads this but the print loop below. The ghost takes real
-- sizes from caste.misc.adult_size on the actual creature.
local CREATURES = {
    { 'rat',              25 },
    { 'cat',            1000 },
    { 'dog',            2000 },
    { 'dwarf',          6000 },
    { 'horse',         30000 },
    { 'elephant',     200000 },
    { 'sperm whale', 1000000 },
}

-- ==========================================
-- CONSTANTS IN FORCE
-- ==========================================
if mode == 'all' then
    hr('TUNING CONSTANTS IN FORCE')
    print(string.format('  anchor              %d volume = %.3f charcoal',
        T.ANCHOR_VOLUME, T.ANCHOR_YIELD))
    print(string.format('  size exponent       %.3f', T.SIZE_EXPONENT))
    print(string.format('  reference density   %d', T.REF_DENSITY))
    print(string.format('  density exponent    %.3f  clamped %.2f to %.2f',
        T.DENSITY_EXPONENT, T.DENSITY_MIN, T.DENSITY_MAX))
    print(string.format('  kindling volume     %d   (must match'
        .. ' making_fuel_tools.json)', T.KINDLING_VOLUME))
    print(string.format('  split efficiency    %.4f', T.SPLIT_EFFICIENCY))
    print(string.format('  ladder              %d cinder = 1 charcoal,'
        .. ' %d charcoal = 1 boulder',
        T.CINDERS_PER_CHARCOAL, T.CHARCOAL_PER_BOULDER))
    print(string.format('  pay cinders         %s', tostring(T.PAY_CINDERS)))
    print(string.format('  burn secondaries    charring leaves %.3f ash per'
        .. ' charcoal, ashing leaves %.3f charcoal per ash',
        T.ASH_FROM_CHARRING, T.CHARCOAL_FROM_ASHING))
    print(string.format('  retort              %.3f of the charcoal, plus'
        .. ' %.3f liquid units per reference log',
        T.RETORT_CHARCOAL_SHARE, T.FLUID_ANCHOR_UNITS))
    print('')
    local keys = {}
    for k in pairs(T.CLASS) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return T.CLASS[a] > T.CLASS[b] end)
    local line = '  class factors       '
    for _, k in ipairs(keys) do
        line = line .. string.format('%s %.3f  ', k, T.CLASS[k])
    end
    print(line)
end

-- ==========================================
-- ITEM TABLE
-- ==========================================
-- The split ratio column is the one to watch. It must read the same
-- number on every row. A row that differs means split_count has been
-- changed back to a volume derivation and the exploit is live.
-- ==========================================
if mode == 'all' or mode == 'items' then
    hr('ITEM CHAR YIELD   (wood at reference density)')
    print(string.format('  %-18s %8s %10s %10s %10s',
        'item', 'volume', 'charcoal', 'kindling', 'split/char'))
    print('  ' .. string.rep('-', 60))
    for _, r in ipairs(ITEMS) do
        local v      = r[2]
        local direct = tuning.yield(v, 'WOOD', T.REF_DENSITY)
        local kn     = tuning.split_count(v)
        local split  = kn * tuning.yield(T.KINDLING_VOLUME, 'WOOD',
                                         T.REF_DENSITY)
        print(string.format('  %-18s %8d %10.4f %10.2f %10.3f',
            r[1], v, direct, kn, split / direct))
    end
    print('')
    print('  split/char must be identical on every row. It is'
        .. ' SPLIT_EFFICIENCY')
    print('  by construction, because split_count derives from yield'
        .. ' rather')
    print('  than from volume, which cancels the size exponent.')
end

-- ==========================================
-- SPECIES SPREAD
-- ==========================================
if mode == 'all' or mode == 'items' then
    hr('SPECIES SPREAD   (one barrel, volume 2000)')
    print(string.format('  %-16s %8s %10s %10s',
        'wood', 'density', 'charcoal', 'vs ref'))
    print('  ' .. string.rep('-', 48))
    local ref = tuning.yield(2000, 'WOOD', T.REF_DENSITY)
    for _, r in ipairs(WOODS) do
        local y = tuning.yield(2000, 'WOOD', r[2])
        print(string.format('  %-16s %8d %10.4f %9.2fx',
            r[1], r[2], y, y / ref))
    end
end

-- ==========================================
-- CLASS SPREAD
-- ==========================================
if mode == 'all' or mode == 'items' then
    hr('MATERIAL CLASS SPREAD   (volume 2000, reference density)')
    local keys = {}
    for k in pairs(T.CLASS) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return T.CLASS[a] > T.CLASS[b] end)
    for _, k in ipairs(keys) do
        print(string.format('  %-10s factor %.3f   charcoal %.4f',
            k, T.CLASS[k], tuning.yield(2000, k, T.REF_DENSITY)))
    end
end

-- ==========================================
-- THE TWO BURNS
-- ==========================================
-- The same item through MakeCharcoal and through MakeAsh, or through
-- a CHAR_ and an ASH_ reaction. The primary column is identical on
-- both sides by construction, one curve; the secondary is the other
-- burn's product at its dial. Both secondaries bank, so the whole
-- items here are what a run of such items averages, not what one job
-- pays.
-- ==========================================
if mode == 'all' or mode == 'items' then
    hr('THE TWO BURNS   (wood at reference density)')
    print(string.format('  %-18s %8s | %9s %9s | %9s %9s',
        'item', 'volume', 'charred', '+ash', 'ashed', '+charcoal'))
    print('  ' .. string.rep('-', 66))
    for _, r in ipairs(ITEMS) do
        local v = r[2]
        local y = tuning.yield(v, 'WOOD', T.REF_DENSITY)
        print(string.format('  %-18s %8d | %9.4f %9.4f | %9.4f %9.4f',
            r[1], v, y, y * T.ASH_FROM_CHARRING,
            y, y * T.CHARCOAL_FROM_ASHING))
    end
end

-- ==========================================
-- THE RETORT
-- ==========================================
-- The same items through the retort: reduced charcoal, plus liquid on
-- its own curve. Wood rows condense to wood tar; the FLESH row shows
-- the corpse case, which is nearly all fluid.
-- ==========================================
if mode == 'all' or mode == 'items' then
    hr('THE RETORT   (charcoal share, liquid units of ' .. T.LIQUID_UNIT .. ')')
    print(string.format('  %-18s %8s %10s %10s %10s',
        'item', 'volume', 'charcoal', 'liquid', 'jobs/unit'))
    print('  ' .. string.rep('-', 60))
    for _, r in ipairs(ITEMS) do
        local v  = r[2]
        local c  = tuning.yield(v, 'WOOD', T.REF_DENSITY) * T.RETORT_CHARCOAL_SHARE
        local fl = tuning.fluid_yield(v, 'WOOD', T.REF_DENSITY)
        print(string.format('  %-18s %8d %10.4f %10.4f %10.1f',
            r[1], v, c, fl, fl > 0 and 1 / fl or 0))
    end
    local fl = tuning.fluid_yield(6000, 'FLESH')
    print(string.format('  %-18s %8d %10.4f %10.4f %10.1f',
        'dwarf corpse', 6000,
        tuning.yield(6000, 'FLESH') * T.RETORT_CHARCOAL_SHARE, fl,
        fl > 0 and 1 / fl or 0))
end

-- ==========================================
-- CREATURE TABLE
-- ==========================================
-- No density column. A corpse's material is whichever tissue happens
-- to dominate, so the same dwarf reads BONE on one corpse and SKIN on
-- another, at 500 and 1000. Applying density there would make
-- identical creatures differ by 2x on nothing.
-- ==========================================
if mode == 'all' or mode == 'corpses' then
    hr('CREATURE CHAR YIELD   (FLESH class, no density)')
    print(string.format('  %-14s %10s %10s %14s',
        'creature', 'size', 'charcoal', 'per charcoal'))
    print('  ' .. string.rep('-', 52))
    for _, r in ipairs(CREATURES) do
        local y = tuning.yield(r[2], 'FLESH')
        local n = (y > 0) and (1 / y) or 0
        print(string.format('  %-14s %10d %10.4f %13.1f',
            r[1], r[2], y, n))
    end
    print('')
    print(string.format(
        '  FLESH is %.3f, from making_fuel_planning.txt putting corpses',
        T.CLASS.FLESH))
    print('  at 80 to 93 percent less charcoal than logs per cm3.')
    print('  Raise it to make corpse charring an industry rather than')
    print('  a disposal method. It scales linearly: doubling the')
    print('  factor doubles every number in this table.')
end

-- ==========================================
-- INVARIANT CHECKS
-- ==========================================
hr('INVARIANT CHECKS')
local results = tuning.check()
local failed  = 0
for _, r in ipairs(results) do
    if not r.ok then failed = failed + 1 end
    print(string.format('  [%s] %-38s %s',
        r.ok and 'PASS' or 'FAIL', r.name, r.detail or ''))
end
print('')
if failed == 0 then
    print('  All checks pass. Safe to recycle and play.')
else
    print(string.format('  %d CHECK(S) FAILED. Do not ship this.', failed))
end
print('')