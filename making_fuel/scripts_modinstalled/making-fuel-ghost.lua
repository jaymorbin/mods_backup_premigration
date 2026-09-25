--@ module = true
-- making-fuel-ghost.lua
-- ==========================================
-- MAKING FUEL: JIT GHOST WATCHER
-- ==========================================
-- Swaps a queued char, ash or split reaction to a per job ghost reaction,
-- then writes that ghost's product counts from the actual value of
-- what walked in.
--
-- One item per job. Fractional value carries between jobs in a bank
-- rather than being collected within one job.
--
-- Every number this file uses lives in making-fuel-tuning.lua. There
-- are no yield constants here. Run making-fuel-curve after changing
-- any of them to see the whole curve and the invariant checks.
-- ==========================================

-- ==========================================
-- ADAPTIVE REACTION FINDINGS
-- ==========================================
-- Established by testing. Every line below was confirmed in game or
-- against the raws, not inferred. Preserve this block.
--
-- A ghost reaction owns everything about a job except which items were
-- already attached when the swap happened.
--
-- PRODUCT COUNTS are writable on a live ghost at any point before the
-- job completes, and completion honours the latest value. The whole
-- design rests on this and it holds.
--
-- MULTI ITEM COLLECTION DOES NOT WORK. THE FILTER VECTOR SURVIVES A
-- REPEAT JOB'S RE-POST. job_items is materialised once at job creation
-- and never re-derived, so growing it to two means every later cycle
-- is BORN demanding two items. When the pile ran dry the job asked for
-- a second, found none, and DF cancelled it inside one second without
-- it ever entering the working phase. Proven on job 826: the last
-- bucket landed at attached=1 filters=2, no working=true was ever
-- logged, and the AUDIT fired one second later still holding it.
--
-- THE SIZE EXPONENT IS SUB ADDITIVE. Below 1.0, n equal pieces of one
-- whole are worth n^(1-exponent) times the whole. At 0.5 that is 2x
-- for four pieces and 7x for fifty. Two consequences, both handled:
--   Split counts are derived from YIELD, not volume, which cancels the
--   exponent and makes split-then-char exactly SPLIT_EFFICIENCY of
--   charring directly at every size.
--   Corpse pieces are computed as the WHOLE creature's yield times the
--   piece fraction, so a creature's parts sum to the creature. The old
--   form raised each piece to the exponent separately and made a river
--   otter toe worth 57x its share.
--
-- ITEMS THAT LIE ABOUT VOLUME. getVolume returns a flat number
-- regardless of the real thing:
--   CORPSE     350 for a rabbit and for a sperm whale
--   REMAINS    200 across cap hopper, olm, cave swallow and bat
--   CLOTH      20,  real measure is getTotalDimension at 10000
--   THREAD     30,  real measure is getTotalDimension at 15000
-- Corpses and remains come from caste.misc.adult_size instead. Cloth
-- and thread are not handled here at all and are excluded from the
-- adaptive set.
--
-- getVolume DOES scale with stack size. A stack of five dog tripe
-- reads 1000 against one at 200, so summing job.items is correct
-- whether DF attaches one stacked ref or five loose ones.
--
-- getMaterial returns -1 on every corpse. Identity comes from
-- matinfo.decode on the fields, and from .race and .caste.
--
-- ALL INTERNAL SIZES ARE ONE TENTH of the wiki published figure.
--
-- A job whose attached count reaches zero consumed its items. A job
-- that vanishes still holding items was cancelled. job.flags.working
-- distinguishes them: a cancelled job never sets it.
--
-- Do NOT raise .quantity on a reagent to consume more. It deadlocks
-- the job.
-- ==========================================

local repeatUtil = require('repeat-util')
local utils      = require('utils')

-- ==========================================
-- TUNING
-- ==========================================
-- reqscript returns a script's ENVIRONMENT, meaning its table of
-- GLOBAL functions and variables. It ignores any return value and
-- cannot see file locals, which is why making-fuel-tuning declares
-- everything global. Do not "tidy" that file by adding local.
-- ==========================================
local tuning = reqscript('making-fuel-tuning')
local T      = tuning.T

local REPEAT_KEY    = 'making_fuel_ghost'
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
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'GHOST'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)
local MODULE_PREFIX = 'MAKING_FUEL_RXN_'
local POLL_FRAMES   = 10

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
-- SUBJECT is the correlation slot: LEDGER for a completed job's
-- accounting, VESSEL, DRAIN and STACK for the liquid and stack
-- mechanics, FILTER and SLOT for job shape, INERT, REAPER, CACHE,
-- ALIAS, JIT, SWAP, CLASSIFY, AUDIT, PHASE, POLL, START and STOP.
--
-- The ledger's first line and its "out" line are a YIELD when the job
-- burned, so Normal shows each finished job and what it made; the rest
-- of the block is DETAIL and reads in full at Debug.
--
-- This replaces a log() gated by a private level (refinish_fuel_loglevel,
-- default 2): 0 faults, 1 normal, 2 debug. The panel's Log Detail
-- setting does that job now, so the level and its global are gone and
-- every line reaches the disk log. Level 2 lines are DETAIL, and the
-- rest are typed by what they say. The old log() also let refinish-log
-- guess TYPE from the words (read_type).
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

-- ---- CRASH BREADCRUMBS ----
-- TEMPORARY. Delete this and its call sites once the CTD is found.
--
-- The log writer opens, writes and closes the file on every call, so
-- nothing is buffered and the last line on disk is genuinely the last
-- line executed. That makes a breadcrumb trail a reliable way to name
-- the statement a hard crash died on, which a pcall cannot do because
-- a C++ crash is not a Lua error.
--
-- No log_once, deliberately: it has to repeat, because it is the LAST
-- one that matters. Every line reaches the disk log whatever the Log
-- Detail setting, so a crumb always lands.
-- SILENCED, not deleted. All fourteen call sites are left exactly
-- where they are, so re-arming the trail is this one line rather than
-- reconstructing where the crumbs went. They cost nothing while the
-- body is empty.
--
-- They earned their retirement by not being needed: all three crashes
-- this week were found from ordinary log lines, and the crumb volume
-- actively got in the way of reading them.
local CRUMBS_ON = false
local function crumb(where, extra)
    if not CRUMBS_ON then return end
    log('DETAIL', 'CRUMB ' .. tostring(where)
        .. (extra and (' ' .. tostring(extra)) or ''), 'CRUMB')
end

local seen = {}
local function log_once(key, typ, msg, subject)
    if seen[key] then return end
    seen[key] = true
    log(typ, msg, subject)
end

-- ==========================================
-- MATERIAL CLASSIFIER
-- ==========================================
-- Returns class, why, layer. Verified against 279 distinct materials
-- in a live fort with zero UNKNOWN. Every flag name below was
-- confirmed PRESENT by making-fuel-mat-probe before this was written.
--
-- FOUR LAYERS, in order. First match wins.
--
--   GATE  No ignite point means it does not burn, and nothing else
--         about the material matters. 140 of 279 materials in a
--         typical fort land here.
--
--   L1    Flags. spec_heat 4181 is water's specific heat capacity and
--         DF uses it to mark wet tissue, which is heavy from water
--         rather than carbon, so density badly over-reads it.
--
--   L1.5  The mod's own materials, matched on the TOKEN. Char, dung,
--         straw and mash are organic in every sense that matters, but
--         DF files them as INORGANIC because an injected material is
--         attached to no creature or plant and has nowhere else to go.
--         Left to layer 3 they would read as mineral fuel and
--         CHAR_DUNG would take a coal multiplier.
--
--   L2    The material's id string. The only handle on tissues DF
--         gives no flag for: parchment is dried skin and behaves like
--         leather, and demon hair carries no YARN bit because it
--         cannot be sheared.
--
--   L3    matinfo.mode. Cannot fail, which is the point of having it.
--         Every material is plant, creature, inorganic or builtin.
--
--         MINERAL IS NO LONGER A BLANKET FAULT SIGNAL. It was, while
--         no reaction in the module accepted a mineral at all, and
--         the note here said so. Coal changed that: lignite and
--         bituminous are now RANKED at L2, are legitimate adaptive
--         feedstock, and never reach this layer. What still lands
--         here is unranked mineral, which includes vanilla charcoal
--         and the diamonds, the latter carrying ignite 11440 because
--         diamond is carbon and oxidises rather than melting.
--
--         So MINERAL in a live yield log still wants looking at, but
--         the question is now "which mineral, and should it have a
--         rank" rather than "which reagent is missing a gate".
-- ==========================================
local MOD_MAT = {
    MAKING_FUEL_CHAR  = 'CHARRED',
    MAKING_FUEL_DUNG  = 'PLANT',
    MAKING_FUEL_STRAW = 'PLANT',
    MAKING_FUEL_MASH  = 'PLANT',

    -- Round B's dried peat. The match below is a substring find on
    -- the token, so each entry above already covers its own _DRIED
    -- form (MAKING_FUEL_DUNG matches MAKING_FUEL_DUNG_DRIED). Dried
    -- peat needs its own line because no PEAT entry exists to cover
    -- it, and its CHAR and ASH retargets are adaptive: without this
    -- it lands on L3 as MINERAL, the bug signal.
    MAKING_FUEL_PEAT_DRIED = 'PEAT',

    -- ---- VANILLA COAL, AND WHY IT IS HERE AND NOT IN BY_ID ----
    -- MEASURED, job 13: a bituminous boulder classified
    -- "MINERAL [item:L3 mode inorganic]" with COAL_BITUMINOUS sitting
    -- in BY_ID. So an inorganic's m.id is NOT its token. The token
    -- lives on the inorganic_raw; the material struct's id is
    -- something else, and every BY_ID key that has ever worked is a
    -- plant or creature TISSUE name.
    --
    -- Wet peat is the precedent and the comment above already said
    -- so: it fell to L3 as MINERAL until it was matched on the token
    -- here. Coal takes the same route.
    --
    -- Substring, so nothing else may contain these. Nothing does:
    -- checked against every material token the module and vanilla
    -- produce, and neither string appears inside another.
    LIGNITE         = 'COAL_LIGNITE',
    COAL_BITUMINOUS = 'COAL_BITUMINOUS',

    -- Wet peat is a vanilla inorganic, so no MAKING_FUEL token ever
    -- matched it and it fell to L3 as MINERAL, which values liquids
    -- at nothing. The substring match makes this line cover the
    -- dried token too, harmlessly: both land on PEAT.
    PEAT = 'PEAT',
}

-- Vanilla materials the mod has tagged with its own reaction class
-- vocabulary. Read by L2.5. Keep this to tags the mod actually
-- declares in its raws: a tag DF ships with would silently
-- reclassify materials this module never meant to touch.
local BY_REACTION_CLASS = {
    PEAT = 'PEAT',

    -- ---- COAL RANK, THE OPT IN ROUTE ----
    -- DF records no rank. Lignite and bituminous are byte identical
    -- in their raws but for the name, the colour and 1250 against
    -- 1346 of density, which is a 7.7 percent spread carrying an 80
    -- percent difference in vanilla's own coke yields. So rank is
    -- declared, and these are the classes another mod's coal can
    -- carry to join the ladder without this file learning its id.
    --
    -- Neither is a tag DF ships, so neither can reclassify something
    -- the module never meant to touch, which is the standing rule
    -- for this table.
    COAL_LIGNITE    = 'COAL_LIGNITE',
    COAL_BITUMINOUS = 'COAL_BITUMINOUS',

    -- Oil shale is a module inorganic carrying its own tag, seeded in
    -- shale, mudstone and siltstone. Without this line it falls to
    -- MINERAL at 0.000 fluid, which is the dead reaction peat used to
    -- be: vessels haul, nothing bottles.
    SHALE_OIL       = 'SHALE_OIL',
    COAL_ANTHRACITE = 'COAL_ANTHRACITE',

    -- The module's own anthracite. Its raw carries its identity class,
    -- ANTHRACITE, its unprefixed id, per Supply Chain Classes 0.4, the
    -- way PEAT and SHALE_OIL do. COAL_ANTHRACITE above stays as the
    -- opt in route for another mod's anthracite. Without this line
    -- ours matched neither row and no MOD_MAT substring covers it, so
    -- it fell through to L3 as MINERAL.
    ANTHRACITE      = 'COAL_ANTHRACITE',
}

local BY_ID = {
    PARCHMENT = 'LEATHER', SKIN      = 'LEATHER',
    HAIR      = 'HAIR',    SCALE     = 'HAIR',
    NAIL      = 'BONE',    CHITIN    = 'BONE',  CARTILAGE = 'BONE',
    SEED      = 'PLANT',   LEAF      = 'PLANT', FRUIT     = 'PLANT',
    MILL      = 'PLANT',   DRINK     = 'PLANT', STRUCTURAL = 'PLANT',
    FAT       = 'FAT',     TALLOW    = 'FAT',   SOAP      = 'FAT',
    WOOD      = 'WOOD',
}

-- GLOBAL, not local, and the only function in this file that is.
-- The hijacker prices vanilla's smelter coke off the same curve,
-- which means it needs the same rank split between lignite and
-- bituminous. That split is everything below plus MOD_MAT and
-- BY_REACTION_CLASS above, and a second copy of it in the hijacker
-- would drift the first time either is tuned.
--
-- reqscript hands back a script's ENVIRONMENT. A local is not in
-- it and a global is, so this one word is the whole export.
function classify(mi)
    if not mi or not mi.material then return 'WOOD', 'no matinfo', 0 end
    local m = mi.material

    local ig, sp = nil, 0
    pcall(function() ig = m.heat.ignite_point end)
    pcall(function() sp = m.heat.spec_heat or 0 end)

    -- ---- GATE ----
    if not ig or ig <= 0 or ig >= 60000 then
        return 'INERT', 'no ignite point', 0
    end

    local function bit(n)
        local v = false
        pcall(function() v = m.flags[n] end)
        return v == true
    end

    -- ---- L0.9: FAT, BEFORE WET TISSUE CAN SWALLOW IT ----
    -- FAT_TEMPLATE and TALLOW_TEMPLATE both carry SPEC_HEAT 4181,
    -- which is the identical value MUSCLE_TEMPLATE carries, because
    -- DF uses water's specific heat to mark anything mostly water and
    -- fat qualifies. Checked in material_template_default.txt, lines
    -- 219 and 1902 against muscle's 270.
    --
    -- So the wet tissue test immediately below has been swallowing
    -- every fat since it was written, and BY_ID's FAT, TALLOW and
    -- SOAP rows have never once been reached. They were dead code.
    --
    -- Measured in play: water buffalo fat classified FLESH, which
    -- splits OIL_BONE three quarters and AMMONIA one quarter, while
    -- RETORT_GLOB declares a single vessel. So the ammonia had
    -- nowhere to go and the reaction named "render tallow oil"
    -- produced no tallow at all.
    --
    -- Read from BY_ID rather than repeating the list, so there stays
    -- one place that decides what counts as a fat.
    --
    -- Deliberately NOT fixed by loosening the 4000 threshold: 4181 is
    -- genuinely right for fat, it just is not the whole story about
    -- it. Only the ordering was wrong.
    local early_id = ''
    pcall(function() early_id = tostring(m.id):upper() end)
    if BY_ID[early_id] == 'FAT' then
        return 'FAT', 'id ' .. early_id, 1
    end

    -- ---- L1: FLAGS ----
    if sp >= 4000                      then return 'FLESH',   'wet tissue', 1 end
    if bit('BONE') or bit('TOOTH')
       or bit('HORN') or bit('HOOF')
       or bit('SHELL') or bit('PEARL') then return 'BONE',    'skeletal', 1 end
    if bit('LEATHER')                  then return 'LEATHER', 'leather', 1 end
    if bit('SILK') or bit('YARN')
       or bit('FEATHER')               then return 'HAIR',    'fibre', 1 end
    if bit('WOOD')                     then return 'WOOD',    'wood', 1 end
    if bit('THREAD_PLANT')
       or bit('STRUCTURAL_PLANT_MAT')  then return 'PLANT',   'plant', 1 end

    -- ---- L1.5: THE MOD'S OWN MATERIALS ----
    -- Matched on getToken rather than m.id, because getToken is proven
    -- to work on every material type here while m.id on an injected
    -- inorganic is not something this file has verified.
    local tok = ''
    pcall(function() tok = tostring(mi:getToken()):upper() end)
    for name, cls in pairs(MOD_MAT) do
        if tok:find(name, 1, true) then return cls, 'mod ' .. name, 1 end
    end

    -- ---- L2: MATERIAL ID ----
    local id = ''
    pcall(function() id = tostring(m.id):upper() end)
    if BY_ID[id] then return BY_ID[id], 'id ' .. id, 2 end

    -- ---- L2.5: THE MOD'S REACTION CLASS VOCABULARY ----
    -- The last chance before the fallback, and specifically for
    -- VANILLA materials the mod has tagged. Peat carries
    -- REACTION_CLASS:PEAT in inorganic_making_fuel.txt, so the tag
    -- that already tiers it for reagents also classifies it here,
    -- and nothing has to substring match a token.
    --
    -- material.reaction_class is a vector of strings on the
    -- material struct, confirmed against df.material.xml. Exact
    -- match, not find, so a class named PEATLAND could never
    -- collide with peat.
    --
    -- Anything tagged here stays OUT of L3, which is the point:
    -- L3 landing on MINERAL remains a bug signal meaning a reagent
    -- is missing a gate, exactly as its comment says.
    local rc_hit = nil
    pcall(function()
        for _, rc in ipairs(m.reaction_class) do
            -- .value, not tostring(). These are string POINTERS and
            -- tostring gives an address, so this layer matched
            -- nothing and peat fell through to MINERAL unnoticed.
            local name = nil
            pcall(function() name = tostring(rc.value):upper() end)
            name = name or ''
            if BY_REACTION_CLASS[name] then
                rc_hit = { BY_REACTION_CLASS[name], name }
                return
            end
        end
    end)
    if rc_hit then
        return rc_hit[1], 'class ' .. rc_hit[2], 2.5
    end

    -- ---- L3: MODE ----
    local mode_s = tostring(mi.mode)
    if mode_s == 'plant'    then return 'PLANT', 'mode plant', 3 end
    if mode_s == 'creature' then return 'FLESH', 'mode creature', 3 end
    return 'MINERAL', 'mode ' .. mode_s, 3
end

-- ==========================================
-- CREATURE SIZE
-- ==========================================
-- adult_size off the caste, NOT size_info.size_cur.
--
-- size_cur is per individual and only meaningful on creatures that
-- lived: a river otter reads 816 against adult 1000. Anything SPAWNED
-- reads a flat 7000 regardless of species, so a demon rat leg and a
-- dragon leg came out within a factor of two of each other.
--
-- The cost is that a runt and a giant of one species char identically,
-- which is a rounding error next to a dragon charring like a rat.
-- ==========================================
local function adult_size(item)
    local s = nil
    pcall(function()
        s = df.global.world.raws.creatures.all[item.race]
              .caste[item.caste].misc.adult_size
    end)
    return s
end

-- ==========================================
-- ITEM VALUE
-- ==========================================
-- Charcoal value of one item, dispatched on the ITEM rather than the
-- reaction, because the greedy reactions take several item types in a
-- single job and only the item knows which path applies.
--
-- Returns value, size, class, density, path. Returns nil for anything
-- with no readable size; the caller skips those rather than counting
-- them as zero.
-- ==========================================
local function item_value(item)
    if not item then return nil end

    local mi = nil
    pcall(function() mi = dfhack.matinfo.decode(item) end)
    local class, why, layer = classify(mi)

    local density = nil
    pcall(function() density = mi.material.solid_density end)

    -- The material token, for the moisture factor. Resolved the same
    -- way classify does it at L1.5, on getToken rather than m.id,
    -- because getToken is proven on every material type here.
    --
    -- Read a second time rather than threaded out of classify, so the
    -- classifier's signature stays the three values every caller
    -- already expects. It is one pcall on an mi already in hand.
    local mat_token = nil
    pcall(function() mat_token = tostring(mi:getToken()):upper() end)

    local itype = -1
    pcall(function() itype = tonumber(item:getType()) end)

    -- ---- WHOLE CORPSE ----
    -- getVolume lies: 350 for a rabbit and for a sperm whale.
    if itype == df.item_type.CORPSE then
        local size = adult_size(item)
        if not size or size <= 0 then return nil end
        -- No density on the flesh path. A corpse's material is
        -- whichever tissue dominates, so the same dwarf reads BONE on
        -- one corpse and SKIN on another, at 500 and 1000, and density
        -- would make identical creatures differ by 2x on nothing.
        return tuning.yield(size, 'FLESH'), size, 'FLESH', nil, 'corpse'
    end

    -- ---- CORPSE PIECE ----
    -- adult_size is the whole creature, so an arm would read as a
    -- whole dwarf. body_part_status marks every part the piece does
    -- NOT have as missing, so what is left is the piece.
    --
    -- ADDITIVITY. The whole creature is compressed FIRST and the
    -- fraction applied after, so a creature's parts sum to exactly the
    -- creature. Raising each piece to the exponent separately, which
    -- is what this used to do, made a river otter toe at relsize
    -- 3/9687 worth 0.0072 against the whole otter's 0.408, when its
    -- share is 0.00013. That is 57x, and it made butchering strictly
    -- better than charring the body.
    if itype == df.item_type.CORPSEPIECE then
        local total, present = 0, 0
        pcall(function()
            local rs     = item.body.body_part_relsize
            local status = item.body.components.body_part_status
            for k = 0, #rs - 1 do
                total = total + rs[k]
                local gone = true
                pcall(function() gone = status[k].missing end)
                if not gone then present = present + rs[k] end
            end
        end)
        local size = adult_size(item)
        if not size or size <= 0 or total <= 0 or present <= 0 then
            return nil
        end
        local frac  = present / total

        -- ---- BUTCHERED OR NOT, R9 ----
        -- The whole corpse branch above hardcodes FLESH for a reason
        -- written there: a corpse's material is whichever tissue
        -- dominates, so the same dwarf reads BONE on one and SKIN on
        -- another. This branch inherited the hardcode without
        -- inheriting the reason, and half of it does not apply.
        --
        -- A corpse piece is two different items wearing one type.
        -- DF says which, and the flag is corpse_flags.unbutchered.
        -- Measured, 30 pieces in one fort, and it partitions cleanly:
        --
        --   12 WITHOUT it, butchered in game from two buffalo:
        --      bone [14], horn [2], hoof [4], skull, skin, nervous
        --      tissue. One tissue each, by construction.
        --   18 WITH it, whole pieces:
        --      8 dwarf and 10 dragon parts. A head, a leg, a tail.
        --      Several tissues wearing whichever one covers them,
        --      which is why a dwarf arm reads DWARF:SKIN and a dwarf
        --      head reads DWARF:HAIR. Neither is made of that.
        --
        -- DF's own vocabulary agrees with the classifier on the
        -- butchered set: corpse_flags carried bone on the bone stacks,
        -- horn on horns AND hooves, skull on skulls, rottable on skin
        -- and nerve. Every one matches what classify() returns from
        -- the material, so the material is trustworthy here.
        --
        -- UNREADABLE MEANS UNBUTCHERED. The flag failing to read keeps
        -- today's FLESH, which changes nothing. Guessing the other way
        -- would reprice a mixed piece off a covering tissue.
        local butchered = false
        pcall(function()
            butchered = (item.corpse_flags.unbutchered == false)
        end)

        -- ---- AND THE CLASS HAS TO BE A TISSUE ----
        -- Belt and braces on top of the flag. A butchered piece could
        -- still classify to something no creature is made of, and the
        -- costly case is INERT: dragon scale reads ignite 60001 and
        -- heatdam 60001, and CLASS.INERT and FLUID_CLASS.INERT are
        -- both 0.000, so accepting it would make the piece worth
        -- exactly nothing. A fireproof creature surviving the retort
        -- is a real thing, it belongs to the unbuilt non-burning
        -- components system, and it is not being decided here.
        -- MINERAL is refused for the same reason. It used to be
        -- refused partly because MINERAL appearing at all was a fault
        -- signal; coal retired that, but nothing a butcher produces
        -- is a mineral either way, so the refusal stands on the
        -- tissue whitelist below rather than on the old ruling.
        local PIECE_CLASSES = {
            FLESH = true, BONE = true, LEATHER = true,
            HAIR  = true, FAT  = true,
        }

        local pclass = 'FLESH'
        if butchered and PIECE_CLASSES[class] then
            pclass = class
        elseif butchered then
            -- Butchered, so the material should have been readable,
            -- and it was not a tissue. Worth one line: this is the
            -- evidence the components system will want, and collecting
            -- it now costs nothing.
            log_once('piececlass:' .. tostring(mat_token), 'DETAIL', string.format(
                    'PIECE: butchered %s classifies %s, which is not a'
                    .. ' tissue a creature is made of, so it keeps'
                    .. ' FLESH. Reason given was "%s".',
                    tostring(mat_token), tostring(class),
                    tostring(why)), 'CLASSIFY')
        end

        -- Density stays nil exactly as it was. The class factors are
        -- calibrated without a moisture correction, and handing one in
        -- here would charge for the same water twice. Changing the
        -- class is one change; changing the basis would be two.
        local whole = tuning.yield(size, pclass)
        -- The whole size and the share ride back as extra returns so
        -- the retort fluid limb can price the whole creature and take
        -- the share, keeping pieces additive there too. Curving
        -- size * frac would hand every piece the exponent again.
        return whole * frac, size * frac, pclass, nil,
               'piece:' .. tostring(pclass), nil, size, frac
    end

    -- ---- REMAINS ----
    -- Flat 200 across cap hopper, olm, cave swallow and bat, so it
    -- lies exactly the way a corpse does. The size probe tagged it
    -- VARIABLE SIZE, but that tag is a prediction from it being
    -- creature derived; the eight measurements all read 200.
    --
    -- Falls back to getVolume if race and caste are unreadable, and
    -- says which path it took, because remains carrying race is the
    -- one assumption here that has not been confirmed in game.
    if itype == df.item_type.REMAINS then
        local size = adult_size(item)
        if size and size > 0 then
            return tuning.yield(size, 'FLESH'), size, 'FLESH', nil,
                   'remains:caste'
        end
        pcall(function() size = tonumber(item:getVolume()) end)
        if not size or size <= 0 then return nil end
        log_once('remains_fallback', 'DETAIL',
            'remains have no readable race or caste, falling back'
            .. ' to getVolume, which reads a flat 200 for every vermin.',
            'CLASSIFY')
        return tuning.yield(size, 'FLESH'), size, 'FLESH', nil,
               'remains:volume'
    end

    -- ---- EVERYTHING ELSE ----
    -- getVolume is honest for furniture, crafts, tools, instruments,
    -- bones, hides and plant matter, and it scales with stack size.
    local size = nil
    pcall(function() size = tonumber(item:getVolume()) end)
    if not size or size <= 0 then return nil end

    -- mat_token turns on factor_moisture, which divides out the water
    -- so the curve reads DRY mass. Without it, fresh dung at density
    -- 700 out-yielded its own dried cake at 400, and DRY_DUNG was a
    -- reaction that destroyed value.
    --
    -- Only this path gets it. The flesh paths above pass no density
    -- and must not pass a token either: FLESH is 0.125 precisely
    -- BECAUSE wet tissue is mostly water, so correcting for moisture
    -- there would charge for the same water twice.
    -- Sixth return feeds the retort's fluid curve, which needs the
    -- same moisture correction the solid curve gets. The flesh paths
    -- above deliberately return five: FLESH is priced for water in
    -- its class factor, and handing its token onward would charge
    -- for the same water twice.
    return tuning.yield(size, class, density, { mat_token = mat_token }),
           size, class, density,
           'item:L' .. tostring(layer) .. ' ' .. tostring(why),
           mat_token
end

-- ==========================================
-- ITEM SPLIT COUNT
-- ==========================================
-- How many kindling one item splits into. Fractional; the remainder
-- banks exactly the way charcoal does.
--
-- Only ever sees the item path, because every SPLIT reaction takes a
-- wooden item. No corpse is ever split.
-- ==========================================
local function item_kindling(item)
    if not item then return nil end
    local size = nil
    pcall(function() size = tonumber(item:getVolume()) end)
    if not size or size <= 0 then return nil end
    return tuning.split_count(size), size
end

-- ==========================================
-- THE BANK
-- ==========================================
-- [base reaction code] = value carried forward.
--
-- WHY THIS REPLACED MULTI ITEM COLLECTION
--
-- A barrel is worth 0.632 charcoal and a bucket 0.245. Neither is a
-- whole product alone, so the old design made one job collect several
-- items until they added up. That required an unfilled filter, an
-- unfilled filter is what DF cancels a job over, and the filter vector
-- survives a repeat job's re-post so the demand became permanent.
--
-- The bank reaches a whole product without ever opening a slot. One
-- item per job, filters permanently at the base reaction's count,
-- fractional value accumulated here between jobs. DF has nothing to
-- cancel because nothing is ever outstanding. It also stops the old
-- per job rounding loss, which threw away up to a quarter charcoal on
-- every completion.
--
-- Keyed on the BASE code, so every furniture job shares one running
-- total no matter which wood walked in, and each reaction keeps its
-- own. The UNIT follows the profile: charcoal for CHAR reactions,
-- kindling for SPLIT reactions.
--
-- Session scoped. A reload drops at most one payout unit per
-- reaction, which is not worth persistence machinery.
-- ==========================================
-- ---- WHY THIS LIVES ON A GLOBAL ----
-- The bank must survive a RAM transition, and a RAM transition happens
-- on EVERY save under the hotsave protocol, not just on a world
-- reload. Clearing it there destroyed a partial balance every time the
-- game saved. At FLESH 0.125 a corpsepiece bank needs roughly sixteen
-- legs to reach a single cinder, so that was not a rounding error.
--
-- It is safe to keep across a cycle in a way ghost_cache is not: this
-- holds no pointers, only reaction code strings against numbers, and
-- those codes are stable. Living on a global also carries it across a
-- world unload and reload, since start() runs again on load.
--
-- Cleared only on a DFHack restart, or by hand:
--   :lua refinish_fuel_bank = {}
_G.refinish_fuel_bank = _G.refinish_fuel_bank or {}
local yield_bank = _G.refinish_fuel_bank

-- ---- BANK SCOPE ----
-- Which jobs share a running balance.
--
--   'PROFILE'   one bank per CURRENCY: charcoal, ash and kindling.
--               Shared by every job that pays that thing, whether
--               as its primary or its secondary, ghost or hijacker.
--               A barrel's remainder can finish what a corpse
--               started, which is right because they produce the
--               same charcoal, and the ash a char job leaves behind
--               tops up what a MakeAsh job fell short by.
--
--   'REACTION'  a separate bank per reaction and currency. Tidier in
--               the log and strands value badly: 73 charcoal
--               reactions holding up to a quarter each and 49
--               kindling reactions holding up to a whole each is
--               roughly 67 units that can sit unpaid forever unless
--               every reaction is fed on its own until it crosses
--               its own threshold. This was the original behaviour
--               and it is why switching from corpses to furniture
--               looked like the bank had been lost: CHAR_FURNITURE
--               had simply never had one.
local BANK_SCOPE = 'PROFILE'

-- ==========================================
-- CURRENCIES
-- ==========================================
-- The three things a bank can hold. A profile's PRIMARY currency is
-- the profile itself, which is why the two sets of names match; its
-- SECONDARY is looked up in streams_for below.
--
-- BANK_CHARCOAL and BANK_ASH are the exact keys the hijacker uses
-- for MakeCharcoal and MakeAsh. Same keys, same pools: vanilla
-- output and module output are one currency.
-- ==========================================
local CURRENCY_CHARCOAL = 'CHARCOAL'
local CURRENCY_ASH      = 'ASH'
local CURRENCY_KINDLING = 'KINDLING'
local CURRENCY_COKE     = 'COKE'

-- Coal's ash, and a currency rather than a fixed byproduct for the
-- same reason coke is: the incombustible fraction of a boulder is a
-- property of the coal, and a flat one bar per job pays a lignite and
-- a bituminous the same. Wood ash banks; ash is ash.
local CURRENCY_ASH_COAL = 'ASH_COAL'

-- ==========================================
-- THE TWO LADDERS
-- ==========================================
-- Wood and coal pack identically: a middle rung that IS the
-- currency, a top rung holding four of it, and a bottom rung worth a
-- quarter each.
--
--   charcoal:  1 char boulder = 4 charcoal,  1 charcoal = 4 cinder
--   coke:      1 green coke   = 4 coke,      1 coke     = 4 breeze
--
-- So one writer serves both and only the constants and the ledger
-- names differ. That is also the answer to why tuning carries a
-- SEPARATE pair of coal constants when both are 4 today: the shape
-- is shared, the numbers are not, and coal can be re-tuned without
-- moving charcoal.
--
-- Constants are named rather than inlined so dial() reports a
-- missing one by name instead of failing as arithmetic on a nil.
local LADDER_WOOD = {
    per_top = 'CHARCOAL_PER_BOULDER',
    per_sub = 'CINDERS_PER_CHARCOAL',
    names   = { 'charcoal', 'boulder', 'cinder' },
}
local LADDER_COAL = {
    per_top = 'COKE_PER_GREEN_COKE',
    per_sub = 'BREEZE_PER_COKE',
    names   = { 'coke', 'green coke', 'breeze' },
}

-- ---- LEDGER NAME FOR AN `each` PRODUCT ----
-- The two derive_config sites read a product's name for the ledger.
-- They read mat_id and fell back to the item TYPE when it was absent,
-- so the coal ash slot, which is declared with a mat_token rather
-- than a mat_id, printed as "bar". MEASURED, job 20:
--   out 0 coke, 2 green coke, 0 breeze, 1 gypsum, 1 brimstone, 1 bar
--
-- mat_token is COLON DELIMITED and the material key is the last
-- segment: PLANT_MAT:MAKING_FUEL_COAL_HOST:ASH_COAL is ASH_COAL.
--
-- The qualifier flip mirrors the bank readout's: the reactions spell
-- these qualifier-last and English wants them first, so ASH_COAL
-- reads "coal ash" and not "ash coal". Same table, same reason, and
-- it is mirrored rather than shared because this file must name a
-- product even when the readout is not loaded.
local EACH_QUAL = { WOOD = true, COAL = true, PLANT = true,
                    BONE = true, SHALE = true, PEAT = true,
                    TALLOW = true }

-- ---- A MATERIAL'S BARE NAME ----
-- An id without the module's prefixes, for everywhere an id becomes a
-- key or a name: MAKING_FUEL_ on everything the module injects, and
-- MKGFUEL_ on the stones inorganic_making_fuel.txt adds to the world.
-- So the raws bitumen still banks as BITUMEN and still reads
-- "bitumen", and a bank saved under that key still pays out.
local function bare(id)
    local s = tostring(id or '')
    s = s:gsub('^MAKING_FUEL_', '')
    s = s:gsub('^MKGFUEL_', '')
    return s
end

-- The MATERIAL KEY, uppercase and underscored, which is what a bank
-- and a FRACTION_SPLIT row are keyed on. each_name below returns the
-- display string and the two must not be confused: a currency of
-- 'oil lubricating' is how BANK_oil lubricating@4 came to exist.
local function each_key(p)
    local raw = p.mat_id
    if not raw or raw == '' then
        local tok = p.mat_token
        if tok and tok ~= '' then raw = tok:match('([^:]+)$') end
    end
    return bare(raw)
end

local function each_name(p)
    local raw = p.mat_id
    if not raw or raw == '' then
        local tok = p.mat_token
        if tok and tok ~= '' then raw = tok:match('([^:]+)$') end
    end
    raw = bare(raw or p.type or '?')

    local base, qual = raw:match('^(.*)_([A-Z]+)$')
    if qual and EACH_QUAL[qual] then raw = qual .. '_' .. base end

    return (raw:lower():gsub('_', ' '))
end

-- Keyed on the CURRENCY rather than the profile, because one job now
-- feeds two banks: a char job deposits charcoal AND ash.
--
-- ---- THE KEY IS PER FURNACE ----
-- 'BANK_<currency>@<building id>', and 'BANK_<currency>' when no
-- building can be identified, so nothing is ever lost to a missing
-- holder.
--
-- WHY. The bank was read at projection and OVERWRITTEN at settle with
-- that job's own carry. Two retorts running at once on the same
-- currency both read the same balance, both wrote payouts against it,
-- and whichever settled last erased the other's debit. Under the old
-- one package per job rule the error was about one package and
-- nobody would ever have seen it; with overflow banks the error is
-- the whole balance, which can be dozens.
--
-- A furnace runs one job at a time, so keying on the building closes
-- the race at its source rather than guarding it.
--
-- The same format is written in the ghost, the hijacker and the
-- readout. It has to match in all three: the ghost and the hijacker
-- share pools deliberately, so vanilla MakeCharcoal and module
-- charring are one currency at one furnace, and the readout must look
-- at the furnace whose sheet is open.
local function bank_key(base_code, currency, job)
    if BANK_SCOPE == 'REACTION' then
        return base_code .. ':' .. tostring(currency)
    end
    local bid = nil
    pcall(function()
        local b = job and dfhack.job.getHolder(job)
        if b then bid = b.id end
    end)
    if bid then
        return 'BANK_' .. tostring(currency) .. '@' .. tostring(bid)
    end
    return 'BANK_' .. tostring(currency)
end

-- ==========================================
-- PRODUCT PROFILES
-- ==========================================
-- What a reaction's products mean and how a banked total is split
-- across them. The profile is read off the FIRST product in the
-- JSON, which is the PRIMARY stream; every other slot is a fixed
-- position the writers below count on.
--
-- CHARCOAL   primary charcoal, secondary ash.
--              [0] charcoal bar  [1] char boulder  [2] cinder
--              [3] ash bar
--            Whole charcoal packs into boulders four at a time so a
--            sperm whale is boulders rather than fifty-eight bars,
--            and the sub-charcoal remainder pays out as cinders at a
--            quarter each. Ash is what the kiln fire left behind:
--            ASH_FROM_CHARRING of the charcoal value, whole bars
--            only, the fraction banked.
--
-- ASH        primary ash, secondary charcoal. The mirror image:
--              [0] ash bar
--              [1] charcoal bar  [2] char boulder  [3] cinder
--            An open burn leaves ash plus whatever smothered before
--            it finished, CHARCOAL_FROM_ASHING of the ash value, paid
--            down the same charcoal ladder as everything else.
--
-- KINDLING   one product, whole units only. There is no sub-kindling
--            item, so anything under 1.0 simply banks. No secondary.
--
-- RETORT     CHARCOAL with liquids. Any charcoal reaction that also
--            declares LIQUID_MISC_INORGANIC products at count 0:
--              [0..3] the charcoal layout above
--              [4..]  one liquid per bucket, matched by mat_id
--            The charcoal and ash streams are scaled by
--            RETORT_CHARCOAL_SHARE; each liquid is its own currency
--            on its own curve (fluid_yield), split across the
--            liquids by class (FLUID_SPLIT). ONE ITEM PER BUCKET:
--            the ghost never raises a liquid's count past 1, it
--            writes the product's DIMENSION instead, so whatever DF
--            does with several liquids in one container is never
--            asked of it.
--
-- The fractions live in making-fuel-tuning.lua under THE TWO BURNS
-- and THE RETORT. A reaction that does not declare its secondary
-- slot pays its primary only and is named once at start.
-- ==========================================
local PROFILE_CHARCOAL = 'CHARCOAL'
local PROFILE_ASH      = 'ASH'
local PROFILE_KINDLING = 'KINDLING'
-- The coal side of the charcoal profile. Same shape, same slot
-- order, same liquid handling; a different pair of ladder constants
-- and no retort share. Told apart by the first product's MATERIAL
-- KEY, because nothing else about the two layouts differs. The type
-- does not separate them either: a coal bar is declared as builtin
-- BAR_COAL or as BAR carrying a PLANT_MAT token, and the module's own
-- reactions use the second so the watcher never has to swap a builtin
-- bar that was only minted to be replaced.
local PROFILE_COKE     = 'COKE'
-- Banked consumption: one tar in, credit banked, a pitch boulder
-- paid when the purse crosses one whole pitch.
local PROFILE_PITCH    = 'PITCH'
-- ---- DRAIN ----
-- A reaction with NO feed: only preserved vessels in, banked liquid
-- out. It exists so a fort can empty a retort's banks without waiting
-- for another burn, and so a small input does not have to drag extra
-- containers along to release what is already owed.
--
-- Its liquid slots carry no fixed material. The ghost points each one
-- at whichever bank at that furnace is fullest, per job. That is only
-- possible because DF re-reads a product's material at completion
-- rather than caching it at job creation, which was measured: a slot
-- authored OIL_BONE and rewritten to AMMONIA mid job minted ammonia.
local PROFILE_DRAIN    = 'DRAIN'

-- A tuning dial read at call time, so a tuning change only ever
-- needs the recycle it needs anyway. A missing dial is named rather
-- than left to fail as "arithmetic on a nil value" somewhere below.
local function dial(name)
    local v = T[name]
    if type(v) ~= 'number' then
        error('making-fuel-tuning is missing ' .. tostring(name))
    end
    return v
end

-- ==========================================
-- SLOT WRITERS
-- ==========================================
-- Each takes a bank total already credited with this job's share,
-- writes whole products into the ghost from slot `at` onward, and
-- reports what it wrote and what that costs the bank.
--
-- Returns paid, out. `out` is a list of { n, name }, so the ledger
-- can say exactly what the products were set to.
--
-- LENGTH CHECKS, NOT TRUTHINESS. Indexing past the end of a DF
-- vector throws, so `if ghost.products[1] then` is not a guard, it
-- is the crash. A slot that does not exist is not written and is
-- NOT charged: nothing is paid for a product the reaction cannot
-- make, so that value waits in the bank for a reaction that can.
-- ==========================================

-- A packing ladder: the currency bar at `at`, the packed top rung at
-- `at + 1`, the sub unit at `at + 2`. Whole units pack into the top
-- rung `per_top` at a time and the remainder pays as sub units at
-- 1/`per_sub` each, when PAY_CINDERS allows and the reaction has a
-- slot for them.
--
-- `ladder` selects which pair of constants and which ledger names.
-- Omitted means LADDER_WOOD, so every existing caller is unchanged.
local function write_ladder(ghost, at, projected, ladder)
    ladder = ladder or LADDER_WOOD
    local per_top = dial(ladder.per_top)
    local per_sub = dial(ladder.per_sub)
    local n = #ghost.products
    if at >= n then return 0, {} end

    -- EPSILON goes INTO the floor, not around it. Without it a dwarf
    -- corpse computing 0.99999 floors to nothing and the whole
    -- charcoal it earned disappears. The clamps catch the case where
    -- epsilon rounds projected past its own value.
    local whole = math.floor(projected + T.EPSILON)
    if whole < 0 then whole = 0 end
    local remainder = projected - whole
    if remainder < 0 then remainder = 0 end

    -- No top rung slot means every whole unit goes out as a bar.
    local packed, bars = 0, whole
    if at + 1 < n then
        packed = math.floor(whole / per_top)
        bars   = whole % per_top
    end
    local subs = 0
    if T.PAY_CINDERS and at + 2 < n then
        subs = math.floor(remainder * per_sub)
    end

    pcall(function() ghost.products[at].count = bars end)
    local out = { { n = bars, name = ladder.names[1] } }
    if at + 1 < n then
        pcall(function() ghost.products[at + 1].count = packed end)
        table.insert(out, { n = packed, name = ladder.names[2] })
    end
    if at + 2 < n then
        pcall(function() ghost.products[at + 2].count = subs end)
        table.insert(out, { n = subs, name = ladder.names[3] })
    end

    -- The sub unit is a real product, so its value leaves the bank
    -- with it. Only the dust below one carries forward.
    return whole + (subs / per_sub), out
end

-- One whole-unit product at `at`: ash bars and kindling. Neither has
-- a sub-unit item, so anything under 1.0 banks.
-- Fixed per cycle: writes exactly n at the slot, every cycle the
-- stream runs. Dimension and to_container are already authored on
-- the clone, so a liquid slot mints its jugful and a boulder slot
-- its boulder with no further help.
local function write_each(ghost, at, n, name)
    pcall(function() ghost.products[at].count = n end)
    return n, { { n = n, name = name } }
end

local function write_whole_units(ghost, at, projected, name)
    if at >= #ghost.products then return 0, {} end
    local whole = math.floor(projected + T.EPSILON)
    if whole < 0 then whole = 0 end
    pcall(function() ghost.products[at].count = whole end)
    return whole, { { n = whole, name = name } }
end

-- ==========================================
-- VESSEL EXPANSION
-- ==========================================
-- A stack burns whole, so a big stack can earn several packages of a
-- liquid in one run. A reaction declares ONE output container per
-- liquid slot, so without this it pays one and banks the rest.
-- Measured: a 200 rye stack earns 6.400 tar_plant, pays 1, strands
-- 5.400 every single run. That is not a rare bound, it is ordinary
-- farm output, and the surplus never drains.
--
-- THE FIX IS MORE CONTAINERS, NEVER FULLER ONES. One package per
-- container, always. Contents are not a lever: not dimension, not
-- count. A reaction takes the FIRST item meeting its requirements,
-- so a container holding anything other than exactly one package
-- breaks every consumer that meets it. That is the partial bug and
-- it is never allowed.
--
-- SO: append a whole triple per extra package, and take them off
-- again when the cycle ends.
--   a vessel REAGENT, cloned from the reaction's own vessel so it
--   inherits has_tool_use, empty and preserve, with a unique code
--   a job_item FILTER pointing at that reagent by index
--   a PRODUCT slot for the same liquid, whose product_to_container
--   names the new reagent's code
--
-- WHY ALL THREE. The reagent drives completion, the filter drives
-- collection, and product_to_container is a STRING naming a reagent
-- code, so a second package needs its own product slot. Appending
-- only some of them produces a job that cannot be satisfied.
--
-- WHY REAGENT AND FILTER MUST MOVE TOGETHER. repair_filters shrinks
-- the filter vector every poll to a target counted from
-- ghost.reagents. Append a filter alone and it is erased within a
-- poll; append both and the target grows in step. This is also why
-- the slot surgery round trip passed with that repair running live.
--
-- APPEND AT THE END, ERASE FROM THE END. Nothing before the last
-- entry shifts, so every existing job_item_idx and reagent_index
-- stays valid and no fixup is needed.
--
-- REMOVE ONLY BETWEEN CYCLES, in the poll, when job.items is empty
-- AND the cycle actually held items. An empty item list also occurs
-- before the first haul, and removing there would strip slots off a
-- job that has not run.
--
-- NEVER ASK FOR A JUG THAT IS NOT THERE. The count below is exact on
-- everything but reachability: a container must be a LIQUID_CONTAINER
-- tool, empty, unforbidden and unclaimed. Reachability uses
-- canWalkBetween, which is a walkability cache lookup and cannot see
-- burrows or invaders, so it is a FILTER and never a guarantee. Both
-- failure directions are bounded: a wrong accept costs one over ask
-- ending in a DF cancellation that recovers cleanly, a wrong reject
-- costs one package banked that drains later.
--
-- THE SWITCH. Off returns the old behaviour exactly, one package per
-- slot per job, so this can be disabled live without a recycle:
--   :lua refinish_fuel_vessels = false
-- ==========================================
local VESSEL_EXPANSION = true

-- Hard ceiling on extra jugs PER CURRENCY, regardless of what the
-- arithmetic asks for. A backstop against a runaway, not a balance
-- number: an earlier build had no memory of what it had appended and
-- grew the vectors on every poll, reaching 684 appends in eighteen
-- seconds. This file has been here before, with filters reaching 26
-- on dung and 65 on branches.
--
-- PER CURRENCY, not per job. Counted per job it was a shared budget,
-- so whichever currency the stream loop reached first spent all of
-- it. Measured on a giant sperm whale corpse: oil_bone took all four
-- extras and ammonia, which had earned 11 packages, got none at all.
-- The JUGS are still shared and counted once per poll, which is
-- correct, because every currency draws from the same pile.
--
-- IT MUST NOT BIND IN NORMAL PLAY. A cap below what a run earns makes
-- the bank grow forever, because the remainder carries into the next
-- run and pushes the demand higher still. Measured on repeating 200
-- rye earning 6.4: a cap of 4 grows the bank 1.4 a run without limit,
-- a cap of 5 still creeps, and a cap of 6 oscillates and drains to
-- zero. Headroom above the earning is what lets it drain, so the
-- fort's jug supply should be the throttle, not this.
-- Sized to take a giant sperm whale in one run. A fresh whale earns
-- 35 oil bone and 11 ammonia, so 34 and 10 extras, and it was
-- measured collecting about 46 containers and emptying the banks
-- completely in a single run.
local VESSEL_MAX_EXTRA = 40

-- A SECOND bound, on the whole job rather than one currency, and it
-- exists for a different reason. Measured: 44 filters completes, and
-- a run that wanted about 67 took the corpse, took one container, and
-- then dropped the corpse. Whatever that boundary is, it is between
-- those two numbers, and a job that FAILS is worse than a job that
-- banks. So the total stays inside proven territory and a compounded
-- input banks the difference instead of asking for a shape that has
-- been seen to fail.
--
-- This is not the per job budget that starved ammonia. That was the
-- per currency ceiling being shared; this sits above both and only
-- binds when their sum is large enough to be dangerous.
-- ---- DF WILL NOT GATHER FOR A JOB PAST THIS MANY FILTERS ----
-- Measured, on whales at one furnace:
--
--   47 filters, 44 extras   gathered and BURNED
--   49 filters, 46 extras   two containers claimed in twenty seconds
--                           against fifty two free, then the job died
--                           without consuming anything
--   about 67 filters        same shape, took the corpse and dropped it
--
-- So the ceiling is 48 and 47 is proven. It is a limit on the JOB,
-- not on our extras, which is why it must be counted in FILTERS: a
-- reaction with four base reagents reaches it sooner than one with
-- three.
--
-- WHAT MADE IT LOOK RANDOM. The variable is the carried bank, not the
-- feedstock. The first whale earns 35 oil and 11 ammonia and needs 47
-- filters. Its remainder carries, so the SECOND whale at the same
-- furnace earns 36 and 12, needs 49, and cannot run at all. It looked
-- like cancelling a job broke the next one; what actually happened is
-- that the next one asked for two more containers.
--
-- Set to the proven number, not the boundary. One short costs a
-- package that banks and is paid next run; one over costs the whole
-- burn.
local VESSEL_MAX_FILTERS = 47

-- Containers never offered to a job, so it can never ask for the last
-- one in the fort. See the margin note in count_free_vessels: asking
-- for exactly everything gets the job refused outright, and a refused
-- job loses its whole burn while an unasked container only delays a
-- package.
local VESSEL_RESERVE = 4

-- Live override, same shape as the on/off switch, so the ceiling can
-- be lifted for a test and dialled back without editing this file or
-- recycling:
--     :lua refinish_fuel_vessel_max = 999   run it bare
--     :lua refinish_fuel_vessel_max = nil   back to the default
-- The material's OWN name, not the id lowercased. The materials file
-- already names these properly: OIL_BONE is "bone oil", TAR_COAL is
-- "coal tar", VINEGAR_WOOD is "wood vinegar". Lowercasing the id
-- gives "oil bone", which is not what anything else in the game calls
-- it, and reordering the words by hand only moves the guesswork.
--
-- Falls back to the flattened id ONLY if the material cannot be read,
-- so a missing material shows something rather than nothing.
local function currency_name(currency)
    local nm = nil
    pcall(function()
        local mi = dfhack.matinfo.find(
            'INORGANIC:MAKING_FUEL_' .. tostring(currency))
        if mi and mi.material then
            local s = mi.material.state_name.Liquid
            s = s and tostring(s) or nil
            if s and #s > 0 then nm = s end
        end
    end)
    if nm then return nm end
    local flat = string.lower(tostring(currency)):gsub('_', ' ')
    return flat
end

local function vessel_max()
    local g = _G.refinish_fuel_vessel_max
    if type(g) == 'number' and g >= 0 then return math.floor(g) end
    return VESSEL_MAX_EXTRA
end

local function vessels_on()
    local g = _G.refinish_fuel_vessels
    if g == nil then return VESSEL_EXPANSION end
    return g and true or false
end

-- ---- FAIR SHARE OF THE CONTAINERS ----
-- count_free_vessels reads the world, and the world does not know
-- what another job appended a moment ago. flags.in_job only excludes
-- a container once a dwarf has claimed it, and every append happens
-- before hauling starts, so two furnaces starting together each
-- counted the whole pile and each promised itself all of it.
-- Measured: two whales at once, jobs 10 and 11, appended 44 apiece
-- against one pile. 88 demanded, neither aware of the other.
--
-- The pile is divided by the number of jobs that WANT extras, not by
-- the number running. Nine furnaces burning single logs beside one
-- whale should not cut the whale to a tenth; they would never have
-- taken an extra container.
--
-- Nothing here can make a run worse than it was before expansion
-- existed. A job always has its own base vessels, which are the
-- reaction's own reagents and are never touched, so the floor is one
-- package per currency. Extras are upside, and this only decides how
-- the upside is split.
--
-- vessel_poll is a counter of this file's own. audit_tick is declared
-- far below and reading it here would resolve to a global, silently
-- nil, which is a trap this file has been caught by before.
local vessel_poll = 0

-- [job.id] = {
--   n     = triples appended this cycle
--   wants = extras this job would take if the pile allowed
--   tick  = the poll it last asked on, so a dead job stops counting
--   held  = true once the job was seen holding items
--   slots = { [currency] = { product indices appended for it } }
-- }
--
-- `slots` is the part that was missing and it is the whole bug. The
-- stream loop runs six times a second, and without a record of what
-- was already appended, every poll rebuilt the list from the base
-- slot and appended the difference AGAIN.
local expand_state = {}

local function expand_for(job)
    local st = expand_state[job.id]
    if not st then
        st = { n = 0, held = false, slots = {} }
        expand_state[job.id] = st
    end
    return st
end

-- ---- IS THIS JOB STILL COLLECTING? ----
-- Extra slots appended to a job whose base filters are ALL already
-- filled are never hauled for. DF closes a job's collection phase
-- once its own reagents are covered, and appending after that does
-- not re-open it.
--
-- MEASURED, two whale corpse runs in one session:
--   job 10 expanded holding 1 of its 3 base filters. DF fetched
--          every extra, reached attached=47 filters=47, and BURNED.
--   job 14 expanded holding 3 of 3. It claimed not one further
--          container out of 52 free in the fort, and died with 44
--          filters unfilled.
-- Availability was never the difference. Timing was.
--
-- This is why the defect needs a CANCEL to reproduce. A cancelled
-- job leaves its feed and its jugs standing at the workshop, so the
-- next job fills every base filter inside a single frame and is
-- already closed by the time the swap fires.
--
-- MEASURED BY FILTER COVERAGE, NOT BY ITEM COUNT. DF attaches spare
-- items to filters that are already satisfied (register K1, the
-- unforbidden corpse swept onto a full q1 slot) and sometimes
-- attaches at job_item_idx -1. Either inflates #job.items and would
-- refuse a job that genuinely still had a slot open. Asking which
-- base indices are covered is immune to both.
--
-- The base filters are the ones this cycle was born with, so they
-- are everything below the extras this cycle has appended: st.n.
local function collection_open(job, st)
    local n_base = 0
    local ok_n = pcall(function()
        n_base = #job.job_items.elements - (st and st.n or 0)
    end)

    local covered = {}
    local ok_c = pcall(function()
        for _, iref in ipairs(job.items) do
            local i = iref.job_item_idx
            if i and i >= 0 and i < n_base then covered[i] = true end
        end
    end)

    -- ---- UNREADABLE MEANS CLOSED ----
    -- The two errors are not symmetric. Wrongly answering OPEN
    -- appends filters nothing will ever haul and kills the whole
    -- burn, which is the defect this exists to stop. Wrongly
    -- answering CLOSED banks the surplus and the next run pays it
    -- out. So a failed read takes the cheap error, and announces
    -- itself rather than going quiet about it.
    if not ok_n or not ok_c or n_base < 1 then
        log_once('collect_read:' .. tostring(job.id), 'WARNING', string.format('VESSEL: job %s filter coverage unreadable,'
                .. ' so no extra containers are asked for and the'
                .. ' surplus banks.', tostring(job.id)), 'VESSEL')
        return false
    end

    for i = 0, n_base - 1 do
        if not covered[i] then return true end
    end
    return false
end

-- The workshop tile. job.pos first, then any attached item, which is
-- standing at the workshop by definition. Verified in play: job.pos
-- read 96,92,130 on a live retort.
local function job_tile(job)
    local p = nil
    pcall(function()
        if job.pos and job.pos.x and job.pos.x >= 0 then
            p = xyz2pos(job.pos.x, job.pos.y, job.pos.z)
        end
    end)
    if p then return p end
    pcall(function()
        for _, iref in ipairs(job.items) do
            local x, y, z = dfhack.items.getPosition(iref.item)
            if x then p = xyz2pos(x, y, z) return end
        end
    end)
    return p
end

-- Empty, unforbidden, unclaimed, reachable liquid containers.
-- getPosition returns THREE values; capturing it into one takes only
-- x and every later call throws. That mistake counted two jugs
-- sealed inside a walled structure.
--
-- RESERVES THE BASE VESSELS. A jug is excluded once it is claimed,
-- but the reaction's OWN vessels are often not claimed yet at the
-- moment of counting, so they were counted as spare and then promised
-- to the extras as well. Measured: a job wanting 7 jugs was sized
-- against a count that had double counted 2 of them, and it took
-- every jug in the fort and then failed for want of a liquid
-- container. Subtracting the base count always is conservative: when
-- the base jugs ARE already claimed it under counts, which only banks
-- a package for later.
local function count_free_vessels(job, ghost)
    local wpos = job_tile(job)
    if not wpos then return 0 end   -- cannot verify, so ask for nothing

    local vec = nil
    pcall(function() vec = df.global.world.items.other.TOOL end)
    if not vec then
        pcall(function() vec = df.global.world.items.all end)
    end
    if not vec then return 0 end

    local n = 0
    for _, it in ipairs(vec) do
        local ok = false
        pcall(function()
            if it:getType() ~= df.item_type.TOOL then return end
            local use = false
            for _, u in ipairs(it.subtype.tool_use) do
                if u == df.tool_uses.LIQUID_CONTAINER then use = true end
            end
            if not use then return end
            if it.flags.forbid or it.flags.in_job then return end
            if #(dfhack.items.getContainedItems(it) or {}) > 0 then return end
            local x, y, z = dfhack.items.getPosition(it)
            if not x then return end
            ok = dfhack.maps.canWalkBetween(wpos, xyz2pos(x, y, z)) and true
        end)
        if ok then n = n + 1 end
    end

    -- Hold back one for each vessel the reaction already declares.
    -- The ghost is PASSED IN rather than fetched from ghost_cache,
    -- because this function is defined above that upvalue. Reading it
    -- here would resolve to a global, silently be nil, and skip the
    -- reservation while compiling perfectly.
    local base = 0
    pcall(function()
        for i = 0, #ghost.reagents - 1 do
            if ghost.reagents[i].flags.PRESERVE_REAGENT then
                base = base + 1
            end
        end
    end)
    n = n - base

    -- ---- LEAVE A MARGIN ----
    -- A job that asks for every container in the fort is refused
    -- outright. Measured: 48 free with 46 asked completed; 18 free,
    -- 20 with the base, with 20 asked was cancelled inside one
    -- second, before a single container had been hauled, announcing
    -- "Needs corpse". The filter count was not it, 47 filters worked
    -- and 21 did not. The difference was two spare containers against
    -- none.
    --
    -- Erring low costs nothing. An unasked container is one package
    -- waiting in the bank that the next run pays out; an over ask is
    -- a cancelled job that loses the whole burn.
    n = n - VESSEL_RESERVE

    if n < 0 then n = 0 end
    return n
end

-- Appends one triple for `cur`, cloning the reaction's own vessel
-- reagent and the product at `at`. Returns the new product index, or
-- nil if anything could not be built.
-- ---- DEFINED HERE, ABOVE EVERY CALLER, DELIBERATELY ----
-- This block first sat immediately above write_liquid, which is below
-- slots_for_liquid. slots_for_liquid calls slot_room, so the reference
-- resolved to a GLOBAL at call time and came back nil:
--
--   ERROR in poll: attempt to call a nil value (global 'slot_room')
--
-- It only fired on a job that actually expanded, because a job wanting
-- one container returns from slots_for_liquid before reaching the
-- call. So a buffalo worked and a whale produced nothing at all.
--
-- Same family as the scope trap already in the register. The rule is
-- the same: define above every caller, and check the ordering rather
-- than trusting that it compiled.
-- ==========================================
-- HOW MUCH THE GRABBED CONTAINER HOLDS
-- ==========================================
-- MEASURED, not assumed, and confirmed three separate ways:
--
--   1 A bone oil package in a jug reads dimension 150 and volume 60,
--     so one package costs 60 of the currency capacity is spent in.
--   2 The wiki states a tool needs 600 capacity per unit of liquid at
--     RAWS scale, and DF divides raws by ten on load. 600/10 is 60.
--   3 A test reaction writing dimension 2400 into a jug of capacity
--     1000 landed as "tallow oil (1600%)", exactly 16 packages, which
--     is 960 of 1000. Seventeen would have been 1020 and over.
--
-- Three routes to the same number, one of them a live run, so it is a
-- constant rather than a guess. It is a DF constant, not a tuning
-- knob, which is why it lives here and not in the tuning file.
local LIQUID_VOLUME_PER_UNIT = 60

-- ---- SLOT -> THE CONTAINER ACTUALLY ATTACHED TO IT ----
-- A product names its vessel by REAGENT CODE in product_to_container,
-- the same string the JSON writes, for example "vessel_1". So the walk
-- is code -> reagent index -> the job item filling that reagent.
--
-- Every step is pcall wrapped and any failure returns nil, which the
-- caller reads as "fall back to one package", today's behaviour. A
-- container we cannot measure must never be assumed roomy.
-- ---- EVERY INDEX BOUNDED BEFORE IT IS USED ----
-- Both reads below are into VECTORS OF POINTERS, and an index past the
-- end of one of those is not a Lua error that pcall can catch. DFHack
-- hands the raw slot to lua_item_read, the pointer is garbage, and the
-- process dies. The DF crash log named exactly that:
--
--   dfhack!DFHack::ptr_container_identity::lua_item_read+0x56
--
-- and the poll's own error handler printed nothing, which is the tell:
-- a Lua error would have been caught and logged, so it was not one.
--
-- `idx` comes straight off iref.job_item_idx and was only checked for
-- being non negative. Nothing checked it against the number of
-- elements that actually exist, and the two can disagree: DF attaches
-- items at -1, and collapse_vessels erases elements from the END of
-- the vector while attached items keep pointing at where they used to
-- be.
--
-- Out of range is REPORTED rather than silently skipped. If this fires
-- it is the answer, and a silent skip would have hidden it.
local function slot_container(job, ghost, at)
    local n_prod = -1
    pcall(function() n_prod = #ghost.products end)
    if type(at) ~= 'number' or at < 0 or at >= n_prod then
        crumb('X product slot out of range', string.format(
            'at=%s of %d', tostring(at), n_prod))
        return nil
    end

    local code = nil
    pcall(function()
        code = tostring(ghost.products[at].product_to_container)
    end)
    if not code or code == '' then return nil end

    local ri = nil
    pcall(function()
        for i = 0, #ghost.reagents - 1 do
            if tostring(ghost.reagents[i].code) == code then
                ri = i
                break
            end
        end
    end)
    if not ri then return nil end

    local n_el = -1
    pcall(function() n_el = #job.job_items.elements end)

    local found = nil
    pcall(function()
        for _, iref in ipairs(job.items) do
            local idx = iref.job_item_idx
            if type(idx) == 'number' and idx >= 0 then
                if idx >= n_el then
                    -- THE CANDIDATE. An attached item pointing past
                    -- the end of the filter vector.
                    crumb('X filter index out of range', string.format(
                        'idx=%d of %d, job %s, item %s',
                        idx, n_el, tostring(job and job.id),
                        tostring(iref.item and iref.item.id)))
                else
                    local r2 = job.job_items.elements[idx].reagent_index
                    if r2 == ri then
                        found = iref.item
                        break
                    end
                end
            end
        end
    end)
    return found
end

-- Whole packages the container on this slot can take, or nil if it
-- cannot be read. `pack` is the package size in LIQUID_UNITs, so a
-- currency packaged in twos gets half as many packages in the same
-- container.
-- ---- ROOM ESTIMATED FROM THE POOL, NOT FROM THE ATTACHED VESSEL ----
-- Vessel expansion has to decide how many containers to ask for while
-- collection is still OPEN, which is precisely before any vessel has
-- arrived. Measured: job 17 expanded holding one item, the corpse, so
-- the attached container could not be read and the estimate fell
-- through to the package count. It asked for three containers to hold
-- three packages, which is the behaviour this was meant to replace.
--
-- So the estimate reads the POOL instead: the smallest capacity among
-- the containers that could actually be grabbed. Smallest rather than
-- average or largest, because under-estimating room means asking for
-- one container too many, which banks, while over-estimating means
-- asking for too few and stranding the surplus.
--
-- Cached per poll. This walks the item vector and the stream loop
-- calls it once per currency, so without the cache a two liquid
-- reaction would scan the fort twice a poll for the same answer.
local pool_room_cache = { poll = -1, cap = nil }

local function pool_min_capacity()
    if pool_room_cache.poll == vessel_poll then
        return pool_room_cache.cap
    end
    pool_room_cache.poll = vessel_poll
    pool_room_cache.cap  = nil

    local vec = nil
    pcall(function() vec = df.global.world.items.other.TOOL end)
    if not vec then
        pcall(function() vec = df.global.world.items.all end)
    end
    if not vec then return nil end

    local nvec = -1
    pcall(function() nvec = #vec end)
    crumb('P pool walk in', string.format('%d item(s)', nvec))
    local lo = nil
    local walked = 0
    for _, it in ipairs(vec) do
        walked = walked + 1
        -- Every 25, so a crash inside the walk is bounded to a 25 item
        -- window instead of the whole vector, without one line per item.
        if walked % 25 == 0 then crumb('P..', walked .. '/' .. nvec) end
        pcall(function()
            if it:getType() ~= df.item_type.TOOL then return end
            local use = false
            for _, u in ipairs(it.subtype.tool_use) do
                if u == df.tool_uses.LIQUID_CONTAINER then use = true end
            end
            if not use then return end
            if it.flags.forbid or it.flags.in_job then return end
            if #(dfhack.items.getContainedItems(it) or {}) > 0 then return end
            local c = it.subtype.container_capacity
            if c and c > 0 and (lo == nil or c < lo) then lo = c end
        end)
    end
    pool_room_cache.cap = lo
    crumb('Q pool walk out', tostring(lo))
    return lo
end

local function slot_room(job, ghost, at, pack)
    -- The attached container is the accurate answer and is preferred
    -- whenever it exists, because that is the vessel this slot will
    -- actually fill. The pool minimum is the ESTIMATE used before the
    -- vessels arrive.
    local it = job and slot_container(job, ghost, at) or nil
    if not it then
        local cap = pool_min_capacity()
        if not cap or cap <= 0 then return nil end
        local n = math.floor(cap / (LIQUID_VOLUME_PER_UNIT * pack))
        if n < 1 then return 0 end
        return n
    end

    local cap = nil
    pcall(function() cap = it.subtype.container_capacity end)
    if not cap or cap <= 0 then return nil end

    local n = math.floor(cap / (LIQUID_VOLUME_PER_UNIT * pack))
    if n < 1 then
        -- A container too small for even one package. Nothing in
        -- vanilla is, so this is a mod authoring fault and it says so
        -- rather than quietly writing zero.
        log_once('tiny_vessel:' .. tostring(cap), 'WARNING', string.format(
            'VESSEL: a container of capacity %d cannot hold even one'
            .. ' package of %d volume. Nothing will be bottled into'
            .. ' it.', cap, LIQUID_VOLUME_PER_UNIT * pack), 'VESSEL')
        return 0
    end
    return n
end

-- ---- HOW MANY CONTAINERS, NOT HOW MANY PACKAGES ----
-- packages_wanted returns PACKAGES. Vessel expansion has always used
-- that number as a CONTAINER count, which was correct only while every
-- container took exactly one package. Now that a jug takes sixteen, a
-- whale asking for 46 would append 45 slots to fill three.
--
-- The base container is the estimate, because it is the one already
-- attached and readable. If the extras turn out smaller, write_liquid
-- fills each to its own capacity and banks the remainder, so an
-- optimistic estimate costs a banked package rather than a bad write.
--
-- Unreadable falls back to the package count, which is exactly the old
-- behaviour: it over-asks, and over-asking was survivable before.
local function containers_wanted(job, ghost, at, packages, pack)
    if packages < 1 then return packages end
    local room = slot_room(job, ghost, at, pack)
    if not room or room < 1 then return packages end
    return math.ceil(packages / room)
end

local function append_vessel_triple(job, ghost, at, seq)
    -- ---- CLONE A VESSEL, NOT MERELY A PRESERVED REAGENT ----
    -- This took the LAST preserved reagent, on the unstated assumption
    -- that preserved means liquid container. That held only because
    -- every preserved reagent in the module was one.
    --
    -- The drain key breaks it. It is preserved and it is NOT a vessel,
    -- so expansion would clone the KEY: a filter demanding a second
    -- drain key, and a liquid product pointed at it. The drain does
    -- expand, so this would fire on its first run.
    --
    -- The test is now LIQUID_CONTAINER tool use, which is what actually
    -- makes a reagent a vessel, rather than a property vessels happen
    -- to share with other things. Ordering the key first in the JSON
    -- would also have worked, and would have been an accident passing
    -- for a rule.
    local vi = nil
    pcall(function()
        for i = 0, #ghost.reagents - 1 do
            local rg = ghost.reagents[i]
            if rg.flags.PRESERVE_REAGENT
               and rg.has_tool_use == df.tool_uses.LIQUID_CONTAINER then
                vi = i
            end
        end
    end)
    if not vi then
        -- Nothing to clone. Said out loud rather than returning
        -- quietly, because a reaction that expands but declares no
        -- vessel is an authoring fault, not a runtime condition.
        log_once('novessel:' .. tostring(ghost.code), 'WARNING', string.format(
            'VESSEL: %s has no preserved LIQUID_CONTAINER reagent to'
            .. ' clone, so no extra containers can be added.',
            tostring(ghost.code)), 'VESSEL')
        return nil
    end

    local new_at = nil
    local ok = pcall(function()
        local code = 'vessel_x' .. tostring(seq)

        local rproto = ghost.reagents[vi]
        local nr = rproto._type:new()
        nr:assign(rproto)
        nr.code = code
        ghost.reagents:insert('#', nr)
        local new_ri = #ghost.reagents - 1

        -- The filter to clone is the one belonging to THAT reagent,
        -- found by reagent_index, not whatever happens to sit last in
        -- the vector. Same fault as above, one level down: with a key
        -- declared after the vessels, the last element is the key's.
        local els    = job.job_items.elements
        local eproto = nil
        for k = 0, #els - 1 do
            if els[k].reagent_index == vi then eproto = els[k] end
        end
        -- The fallback picks by owner too: the last filter that names
        -- ANY reagent. Taking the last filter outright could take one
        -- of the fuel access layer's bulk copies, which owns no
        -- reagent, and clone a jug slot that demands fuel.
        if not eproto then
            for k = #els - 1, 0, -1 do
                local ri = -1
                pcall(function() ri = els[k].reagent_index end)
                if ri >= 0 then eproto = els[k] break end
            end
        end
        local ne = eproto._type:new()
        ne:assign(eproto)
        ne.reagent_index = new_ri
        els:insert('#', ne)

        local pproto = ghost.products[at]
        local np = pproto._type:new()
        np:assign(pproto)
        np.product_to_container = code
        np.count = 0
        ghost.products:insert('#', np)
        new_at = #ghost.products - 1
    end)
    if not ok then return nil end
    return new_at
end

-- ---- THE GHOST MUST DESCRIBE THE JOB IT SERVES ----
--
-- A job expanded to N vessel slots carries N filters, and its ghost
-- carried N reagents to match. Destroy that ghost, which a data cycle
-- does, and the job is reverted to its base and a fresh ghost is cut
-- from it. The base declares only the slots its author wrote, so the
-- job now has more filters than the reaction has reagents.
--
-- DF CANNOT COMPLETE A JOB IN THAT STATE. Every job_item carries a
-- reagent_index and completion looks each one up on the reaction to
-- decide consume or preserve. An index past the end is an out of
-- bounds read inside DF, and it happens at the moment the job
-- finishes rather than while it runs.
--
-- MEASURED. Job 10, five filters against a three reagent ghost:
--
--   FILTER REPAIR: job 10 has 5 filters against 3 reagent(s), but 5
--                  of them are occupied. NOT shrinking; ...
--   SLOT DESYNC: job 10 filters=5 expected=3 (reagents=3, 0 folded).
--
-- repeating for eleven seconds, then a crash as the job completed.
--
-- THE JOB IS THE GROUND TRUTH, not the reaction. DF has already
-- fetched the items, the filters are already written, and a dwarf is
-- already standing at the furnace. So the reaction is grown to match.
-- No filter is added: they exist, that is the whole problem.
--
-- WHY GROWING RATHER THAN RE-POINTING. Pointing the surplus filters at
-- an existing vessel reagent is a smaller write, but it produces a
-- shape DF has never been asked to complete, two filters claiming one
-- reagent. Growing produces 5 reagents against 5 filters, which is
-- exactly what a normal expansion produces and what this fort
-- completes successfully every day. The low risk option is the one
-- that reproduces a proven shape.
--
-- REAGENT AND PRODUCT TOGETHER, and registered with expand_state.
-- collapse_vessels erases a TRIPLE off the end, filter, reagent and
-- product, st.n times. Growing reagents alone would leave it removing
-- a product that expansion never added. Adding both and setting st.n
-- makes the reconstruction indistinguishable from the expansion it
-- replaces, so the job collapses back to base shape between cycles
-- exactly as it would have.
--
-- The rebuilt products carry count 0, so they mint nothing. The
-- surplus jugs are held, released empty at completion, and their
-- liquid banks. That is the honest outcome: the allocation those
-- slots once had died with the ghost and is not recoverable, and
-- inventing one would be worse than banking.
local function reconcile_reagents(job, ghost)
    local n_f, n_r = 0, 0
    pcall(function()
        -- ---- DF'S FUEL FILTER DOES NOT COUNT ----
        -- A fuel:true reaction carries one job_item DF wrote for
        -- itself, at reagent_index -1. Counting it makes the filter
        -- total permanently exceed the reagent total by one, so this
        -- reads a well formed job as a job that expanded, and grows
        -- the reaction by a bogus vessel reagent EVERY cycle.
        -- Measured on job 13: "kept 4 filter(s) ... declares 3" on a
        -- three reagent retort holding exactly its three items plus
        -- fuel.
        for i = 0, #job.job_items.elements - 1 do
            local ri = job.job_items.elements[i].reagent_index
            if not ri or ri >= 0 then n_f = n_f + 1 end
        end
        n_r = #ghost.reagents
    end)
    if n_f <= n_r then return 0 end

    -- Preserved AND a liquid container, the same test
    -- append_vessel_triple uses and for the same reason: the drain key
    -- is preserved and is not a vessel.
    local vi = nil
    pcall(function()
        for i = 0, #ghost.reagents - 1 do
            local rg = ghost.reagents[i]
            if rg.flags.PRESERVE_REAGENT
               and rg.has_tool_use == df.tool_uses.LIQUID_CONTAINER then
                vi = i
            end
        end
    end)

    -- A product already bound to a container, which is what makes it a
    -- vessel slot rather than a solid rung of the ladder.
    local pi = nil
    pcall(function()
        for i = 0, #ghost.products - 1 do
            local pc = tostring(ghost.products[i].product_to_container or '')
            if pc ~= '' then pi = i end
        end
    end)

    if not vi or not pi then
        log_once('noreconcile:' .. tostring(job.id), 'ERROR', string.format(
            'Job %d has %d filters against %d reagent(s), and %s has no'
            .. ' vessel slot to rebuild from. It cannot be reconciled'
            .. ' and DF cannot complete it. Report this line.',
            job.id, n_f, n_r, tostring(ghost.code)), 'VESSEL')
        return 0
    end

    local added = 0
    pcall(function()
        while #ghost.reagents < n_f do
            local code = 'vessel_r' .. tostring(#ghost.reagents)

            local rproto = ghost.reagents[vi]
            local nr = rproto._type:new()
            nr:assign(rproto)
            nr.code = code
            ghost.reagents:insert('#', nr)

            local pproto = ghost.products[pi]
            local np = pproto._type:new()
            np:assign(pproto)
            np.product_to_container = code
            np.count = 0
            ghost.products:insert('#', np)

            added = added + 1
        end
    end)

    if added > 0 then
        local st = expand_for(job)
        st.n = (st.n or 0) + added
        log_once('reconcile:' .. tostring(job.id) .. ':' .. tostring(n_f), 'INFO', string.format(
                'VESSEL: job %d kept %d filter(s) across a data cycle'
                .. ' but its rebuilt reaction declares %d. Rebuilt %d'
                .. ' vessel slot(s) so the job can finish; they hold'
                .. ' their jugs and pay nothing, and collapse with the'
                .. ' rest between cycles.',
                job.id, n_f, n_r, added), 'VESSEL')
    end
    return added
end

-- Every product slot this currency can pay into, base first.
-- Appends up to `want - 1` extras, capped by free vessels.
-- How many whole packages this currency has earned. Used by the
-- pre pass AND by the stream loop, so the two can never disagree
-- about what a currency wants. Two copies of this arithmetic is
-- exactly how a currency ends up allocated for one number and asking
-- for another.
local function packages_wanted(projected, currency)
    local pk = (T.LIQUID_STANDARD or {})[currency]
               or T.LIQUID_STANDARD_DEFAULT or 1
    if pk < 1 then pk = 1 end
    return math.floor((projected + T.EPSILON) / pk)
end

-- `want` counts CONTAINERS. `packages` is carried alongside purely so
-- the shortfall message can tell the player what they earned in the
-- unit they think in, rather than in vessels.
local function slots_for_liquid(job, ghost, at, want, free, currency, packages)
    local slots = { at }
    if not vessels_on() or not at then return slots, free end

    local st = expand_for(job)
    st.tick  = vessel_poll
    st.wants = (want and want > 1) and (want - 1) or 0

    -- ---- REUSE BEFORE APPENDING ----
    -- The slots this currency already owns from an earlier poll of
    -- the SAME cycle. Rebuilding the list without them is what made
    -- the first build append the difference again every poll.
    local mine = st.slots[currency]
    if not mine then mine = {} st.slots[currency] = mine end
    for _, s in ipairs(mine) do
        if s < #ghost.products then table.insert(slots, s) end
    end

    if want < 2 then return slots, free end

    -- ---- ONLY WHILE DF IS STILL COLLECTING ----
    -- Past that point an appended filter is never hauled for, so
    -- asking for one converts a working job into a job that waits
    -- forever on a slot nothing will fill. Zeroing the pile rather
    -- than returning early is deliberate: the shortfall log and the
    -- player announcement below are already the right words for this
    -- ("earned N but can only bottle M, the rest banks"), so the
    -- refusal reports itself through the path that already exists.
    if not collection_open(job, st) then
        free = 0
        -- Said ONCE, and only for a cycle that never got to append.
        -- A cycle that DID expand goes on answering "closed" on every
        -- later poll, correctly and harmlessly, and announcing that
        -- would be a false report on a run that worked.
        if st.n < 1 then
            log_once('vessel_closed:' .. job.id, 'DETAIL', string.format(
                    'VESSEL: job %d was already holding every base'
                    .. ' item when it started, so DF has closed its'
                    .. ' collection phase and extra containers would'
                    .. ' never be fetched. Asking for none; the'
                    .. ' surplus banks and the next run pays it.',
                    job.id), 'VESSEL')
        end
    end

    -- One claimant per job that wants extras and asked on this poll
    -- or the last one. Self is included, since st.wants was set above.
    -- A job that has already taken its share still counts: it is
    -- still holding those containers.
    local claimants = 0
    for _, o in pairs(expand_state) do
        if (o.wants or 0) > 0 and (o.tick or -1) >= vessel_poll - 1 then
            claimants = claimants + 1
        end
    end
    if claimants < 1 then claimants = 1 end
    local allowed = math.floor(free / claimants)
    if claimants > 1 and free > 0 then
        log_once('vessel_share:' .. job.id .. ':' .. tostring(currency), 'DETAIL', string.format(
                'VESSEL: job %d shares %d container(s) with %d other'
                .. ' furnace(s), taking up to %d.',
                job.id, free, claimants - 1, allowed), 'VESSEL')
    end

    -- ---- ALL AT ONCE, ON PURPOSE ----
    -- An earlier build pipelined these against arrivals, on the theory
    -- that unfilled filters kept the job hunting and let an unforbidden
    -- corpse be swept in. The theory was wrong: the corpse was still
    -- taken with the throttle in place, and the throttle cost real
    -- output. Appends came at hauling speed, roughly one a second, and
    -- a whale correctly allotted 34 containers finished having asked
    -- for 19 and bottled 17.
    --
    -- Issuing them together is the point: DF dispatches haulers in
    -- parallel. The appends are already bounded by the container
    -- count, the per currency allotment, vessel_max and
    -- VESSEL_MAX_FILTERS. A throttle on top of those bought nothing and
    -- cost half the output of the largest input in the game.
    -- Tracked rather than re-read, since the loop adds exactly one
    -- filter per pass.
    local n_filters = 0
    pcall(function() n_filters = #job.job_items.elements end)

    while #slots < want and free > 0
          and #mine < allowed
          and #mine < vessel_max()
          and n_filters < VESSEL_MAX_FILTERS do
        local new_at = append_vessel_triple(job, ghost, at, st.n + 1)
        if not new_at then break end
        st.n = st.n + 1
        free = free - 1
        table.insert(mine, new_at)
        table.insert(slots, new_at)
        n_filters = n_filters + 1
        log('DETAIL', string.format(
            'VESSEL: job %d asks container %d of %d for %s',
            job.id, #slots, want, string.lower(tostring(currency))), 'VESSEL')
    end

    if want > #slots and n_filters >= VESSEL_MAX_FILTERS then
        log_once('vessel_filtercap:' .. job.id, 'DETAIL', string.format(
                'VESSEL: job %d stopped at %d filters, the limit past'
                .. ' which DF will not gather for a job. The rest banks'
                .. ' and the next run pays it.', job.id, n_filters), 'VESSEL')
    end

    -- What one container on this reaction actually holds, for the
    -- message below. Same reader the writer uses, so the two cannot
    -- disagree about how roomy a jug is.
    -- Sizes, not just position. A vector reporting a size that includes
    -- a dead pointer is the shape of this crash, so the size is the
    -- number worth having on the line before the read.
    local nsz = {}
    pcall(function() nsz[1] = #ghost.products end)
    pcall(function() nsz[2] = #ghost.reagents end)
    pcall(function() nsz[3] = #job.items end)
    pcall(function() nsz[4] = #job.job_items.elements end)
    crumb('A slot_room in', string.format(
        'job %s at %s | products %s reagents %s items %s filters %s',
        tostring(job and job.id), tostring(at),
        tostring(nsz[1]), tostring(nsz[2]), tostring(nsz[3]),
        tostring(nsz[4])))
    local room_each = slot_room(job, ghost, at, 1) or 1
    crumb('B slot_room out', room_each)

    if want > #slots then
        crumb('C currency_name in', tostring(currency))
        local pretty = currency_name(currency)
        crumb('D currency_name out', tostring(pretty))
        -- The fuel log is not where a player looks. A run that earned
        -- more than it could bottle looks identical to one that did
        -- not, and the difference is sitting in a bank nobody can see,
        -- so it goes in front of them. log_once keys on the job and
        -- the currency, so this says its piece once per run rather
        -- than six times a second.
        -- INFO: the player can act on this: more containers, or a higher
        -- ceiling.
        log_once('vessel_short:' .. job.id .. ':' .. tostring(currency), 'INFO', string.format(
                'VESSEL: job %d earned %d package(s) of %s but has'
                .. ' only %d container(s), holding %d. The rest banks.'
                .. ' Make more containers, or lift the ceiling with'
                .. ' refinish_fuel_vessel_max.',
                job.id, packages or want,
                string.lower(tostring(currency)), #slots,
                #slots * room_each), 'VESSEL')
        -- ---- ONCE, AND INDEPENDENT OF THE LOG LEVEL ----
        -- This fired every poll. log_once guards only the LOG line
        -- and returns early when the level is below its threshold,
        -- so the announcement sat outside the guard entirely and DF
        -- collapsed the repeats into 'x259' and 'x435'. An
        -- announcement is for the player, not the log, so it carries
        -- its own key and does not consult the level at all.
        local akey = 'vessel_ann:' .. job.id .. ':' .. tostring(currency)
        if not seen[akey] then
            seen[akey] = true
            -- 'kept' rather than 'held back': the value is banked and
            -- the next smaller input pays it out, so the number is a
            -- queue and not a loss. Saying it needs N more containers
            -- reads as a demand for 45 jugs right now, which is what
            -- made this look alarming.
            crumb('E announce in', string.format('%d %s',
                  want - #slots, tostring(pretty)))
            pcall(function()
                dfhack.gui.showAnnouncement(string.format(
                    'The retort kept %d %s for lack of accessible containers.',
                    want - #slots, pretty),
                    COLOR_BROWN, false)
            end)
            crumb('F announce out')
        end
    end
    return slots, free
end

-- Takes every appended triple back off. Called from the poll between
-- cycles, where nothing is attached.
--
-- ---- THE FILTERS BY OWNER, THE REACTION BY POSITION ----
-- job_items is shared with the fuel access layer, which appends its
-- bulk copies to the same end, so a filter is claimed by the reagent it
-- names, never by where it sits. ghost.reagents and ghost.products are
-- this file's alone, so there the last st.n are ours. See WHAT LEAVING
-- FUEL ALONE DOES NOT COVER, and register R31.
local function collapse_vessels(job, ghost)
    local st = expand_state[job.id]
    if not st or st.n < 1 then return 0 end
    -- ---- BY OWNER, NOT BY POSITION ----
    -- job_items is shared: making-fuel-access.lua appends its bulk fuel
    -- copies to the same end, and restore_fuel puts a tanked job's slot
    -- back there too. Taking the last st.n filters took whatever
    -- happened to be last, so on a job carrying both it would erase
    -- fuel copies while deleting the reagents the jug filters name,
    -- which is the R22 crash.
    --
    -- Every filter this file appends names its own reagent
    -- (append_vessel_triple writes reagent_index), and so do the slots
    -- R22's reconcile rebuilds. So the expansion's filters are exactly
    -- those owned by a reagent at or past the base count. A fuel slot
    -- owns no reagent, reads -1, and is passed over.
    --
    -- Only ever called between cycles, with nothing attached, so
    -- erasing from the middle moves no live job_item_idx.
    local removed = 0
    pcall(function()
        local keep = #ghost.reagents - st.n
        if keep < 0 then keep = 0 end
        local els = job.job_items.elements
        -- Descending, so an erase never moves a filter still to visit.
        for i = #els - 1, 0, -1 do
            if removed >= st.n then break end
            local ri = -1
            pcall(function() ri = els[i].reagent_index end)
            if ri >= keep then
                els[i]:delete()
                els:erase(i)
                removed = removed + 1
            end
        end
    end)

    -- The reaction's own vectors are this file's alone: nothing else
    -- appends to them, so the last st.n there really are the
    -- expansion's, and they come off whether or not their filters were
    -- still present.
    local dropped = 0
    for _ = 1, st.n do
        local ok = pcall(function()
            local lr = #ghost.reagents - 1
            ghost.reagents[lr]:delete()
            ghost.reagents:erase(lr)

            local lp = #ghost.products - 1
            ghost.products[lp]:delete()
            ghost.products:erase(lp)
        end)
        if not ok then break end
        dropped = dropped + 1
    end

    if removed > 0 or dropped > 0 then
        log('DETAIL', string.format('VESSEL: job %d released %d extra jug slot(s):'
            .. ' %d filter(s), %d reagent(s) and product(s)',
            job.id, st.n, removed, dropped), 'VESSEL')
    end
    if removed < st.n then
        log_once('jugfilter:' .. tostring(job.id), 'DETAIL', string.format(
            'VESSEL: job %d recorded %d extra jug slot(s) but only %d'
            .. ' filter(s) were still owned by them. The rest were gone'
            .. ' already, and the reaction was trimmed to match.',
            job.id, st.n, removed), 'VESSEL')
    end
    expand_state[job.id] = nil
    return removed
end

-- A liquid into its bucket. Count is 0 or 1 PER SLOT, never more:
-- the size goes into product_dimension, so one container holds one
-- item. Several packages means several slots, never a fuller jug.
--
-- PAYS A WHOLE PACKAGE OR NOTHING.
--
-- Never a fraction, never a multiple. The package size for a currency
-- is LIQUID_STANDARD in making-fuel-tuning.lua, and every consumer of
-- that currency asks for exactly that much.
--
-- The old behaviour paid at every whole unit, which produced buckets
-- of whatever the bank happened to hold. That cannot work, because DF
-- fills a reagent slot from ONE container and picks without regard to
-- size. A short bucket fails the ask outright. An oversized one
-- either fails too, or gets partially drained and leaves a non
-- standard remainder that fails every job it is handed to afterwards.
-- One size per currency is the only arrangement that matches every
-- time.
--
-- Holding back costs nothing. settle() carries sum minus paid, so an
-- unaffordable package leaves the whole credit banked for a later
-- job.
--
-- ONE PACKAGE PER JOB is a structural limit, not a choice: the
-- reaction declares one output container for this slot, so there is
-- nowhere to put a second. A currency credited more than a package
-- per job would bank faster than it drains. If that shows up, the fix
-- is to raise that currency's entry in LIQUID_STANDARD, not to raise
-- the count.
--
-- A stream whose reaction has no slot for it (at == nil) is banked
-- and not written.
local function write_liquid(job, ghost, slots, projected, name, currency)
    -- `slots` is the list of product slots this currency may pay
    -- into: the base slot, plus any appended by vessel expansion.
    -- A bare number is still accepted so nothing else has to change.
    if type(slots) == 'number' then slots = { slots } end
    if not slots or #slots < 1 then return 0, {} end

    -- Missing table is an error rather than a default. Silently
    -- falling back to one unit would mint containers nothing can
    -- consume, which is the exact failure this replaced.
    local std = T.LIQUID_STANDARD
    if type(std) ~= 'table' then
        error('making-fuel-tuning is missing LIQUID_STANDARD')
    end
    local pack = std[currency] or T.LIQUID_STANDARD_DEFAULT or 1
    pack = math.floor(pack)
    if pack < 1 then pack = 1 end

    -- One whole package per slot, in order, while the projection
    -- affords it. Every slot writes exactly `pack`, so every minted
    -- item is exactly one package and no consumer can ever meet a
    -- part filled container.
    local left, paid = projected, 0
    for _, at in ipairs(slots) do
        if not at or at >= #ghost.products then break end

        -- ---- FILL WHAT WAS GRABBED, NOT ONE PACKAGE ----
        -- The old rule wrote exactly one package into every slot,
        -- which is why a whale needed 46 containers to bottle 46
        -- packages. A jug holds 16. The container was never the
        -- constraint; the writer was.
        --
        -- COUNT IS NOT THE LEVER. A test reaction with count 50
        -- produced a stack 0 null. Every vanilla LIQUID_MISC product
        -- is count 1 with the amount in the dimension, and that is
        -- what already works here, so raising the dimension is the
        -- whole change.
        --
        -- SAFE WHETHER OR NOT DF ENFORCES ITS OWN CEILING. If DF
        -- checks capacity we match it; if it does not, we have chosen
        -- a sane limit rather than overflowing a container.
        --
        -- Unreadable container falls back to `pack`, which is exactly
        -- today's behaviour, so nothing regresses when the read fails.
        local room = slot_room(job, ghost, at, pack) or pack

        -- Whole packages only, on both sides. A part filled container
        -- is the partial bug and the packaging law forbids it.
        local afford = math.floor((left + T.EPSILON) / pack) * pack
        local take   = math.min(room * pack, afford)

        pcall(function()
            local p = ghost.products[at]
            if take < pack then
                p.count = 0
            else
                p.count = 1
                p.product_dimension = take * dial('LIQUID_UNIT')
            end
        end)
        -- ---- ZERO THE REST, DO NOT BREAK ----
        -- Breaking here left every later slot holding whatever an
        -- EARLIER POLL wrote into it. write_liquid runs on every poll,
        -- and a poll before the vessels arrived wrote one package into
        -- each slot, so a later poll that could afford only the first
        -- slot left stale ones behind it.
        --
        -- Harmless while every slot took exactly one package, because
        -- the slot count and the package count always matched. With a
        -- container holding sixteen they diverge, and the stale writes
        -- surface as liquid split oddly across containers.
        --
        -- A zeroed slot mints a null that the reaper clears, which is
        -- the same thing an unused slot has always done.
        if take >= pack then
            left = left - take
            paid = paid + take
        end
    end
    return paid, { { n = paid, name = name } }
end

-- ==========================================
-- STREAMS
-- ==========================================
-- What one job pays, per currency. Every profile has a primary
-- stream worth the whole haul; the two burn profiles add a secondary
-- worth a tuned fraction of it. Each stream draws on its own bank
-- and writes its own slots, so the two never touch.
--
--   currency   which bank it draws on
--   at         first product slot it writes, nil for bank only
--   share      this stream's fraction of the charcoal haul, OR
--   credit     an absolute value for streams on their own curve
--   kind       'ladder' writes the charcoal ladder, 'units' one
--              whole-unit slot, 'liquid' one bucket by dimension
--
-- `fluids` is the per-currency liquid value the retort valuation
-- summed for this job, empty for every non-retort reaction.
-- ==========================================
-- ==========================================
-- DRAIN: PICKING WHAT TO POUR
-- ==========================================

-- The prefix module MATERIALS carry. Deliberately not MODULE_PREFIX,
-- which is MAKING_FUEL_RXN_ and names reactions.
local MAT_PREFIX = 'MAKING_FUEL_'

-- Currency to inorganic index, built once. The drain writes this into
-- a product's mat_index, so it has to be the same index DF uses to
-- look the material up.
local drain_mat_cache = nil

local function build_drain_mat_cache()
    drain_mat_cache = {}
    pcall(function()
        for i, m in ipairs(df.global.world.raws.inorganics.all) do
            -- MAT_PREFIX, not MODULE_PREFIX. The latter is
            -- MAKING_FUEL_RXN_ and names reactions; materials
            -- carry MAKING_FUEL_ with no RXN_. Using the wrong one
            -- matches nothing and the drain silently pours nothing,
            -- which is the worst shape a bug can take here.
            local c = tostring(m.id):match('^' .. MAT_PREFIX .. '(.+)$')
            if c then drain_mat_cache[c] = i end
        end
    end)
end

-- ---- CHECKED ON READ, THE SAME AS base_reaction ----
--
-- This holds INDICES, not pointers, so a stale entry cannot be caught
-- by comparing an object's own code. It is checked the only way an
-- index can be: read the material back and see whether it is still the
-- one this currency names.
--
-- UNMEASURED, and included anyway. A data cycle rebuilds the whole
-- inorganics array, and these indices survive it. They happen to land
-- in the same places while the material count does not change, which
-- is why this has never bitten. Install or remove a module and it
-- would, and the symptom would be a drain quietly pouring the wrong
-- liquid into a jug, which is the hardest kind of fault to notice.
-- The check is one array read per drain slot.
local function currency_mat_index(cur)
    if not drain_mat_cache then build_drain_mat_cache() end

    local idx = drain_mat_cache[cur]
    if idx == nil then return nil end

    local live = nil
    pcall(function()
        live = tostring(df.global.world.raws.inorganics.all[idx].id)
    end)
    if live == MAT_PREFIX .. cur then return idx end

    log_once('stale_drainmat:' .. tostring(cur), 'WARNING', string.format(
        'Currency %s was cached at inorganic %s, which now holds %s.'
        .. ' Rebuilding the index.',
        tostring(cur), tostring(idx), tostring(live)), 'CACHE')
    build_drain_mat_cache()
    return drain_mat_cache[cur]
end

-- Every bank at THIS furnace holding at least one whole package of an
-- actual liquid, richest first.
--
-- The key shape is derived from bank_key rather than assumed, by
-- asking it for a sentinel currency and splitting on it. BANK_SCOPE
-- can be building or reaction scoped and the two produce completely
-- different keys; hardcoding either would work until someone changed
-- it, and then fail silently by finding nothing.
--
-- LIQUID_STANDARD is the whitelist. Banks also hold charcoal, ash and
-- pitch, and pouring a boulder into a jug is not a thing.
local function drain_candidates(base_code, job)
    local out = {}
    local pre, suf = nil, nil
    pcall(function()
        local mark   = '\1CURRENCY\1'
        local sample = bank_key(base_code, mark, job)
        local a, b = sample:find(mark, 1, true)
        if a then
            pre = sample:sub(1, a - 1)
            suf = sample:sub(b + 1)
        end
    end)
    if not pre then return out end

    local liq = T.LIQUID_STANDARD or {}
    for k, v in pairs(yield_bank or {}) do
        if type(v) == 'number' and k:sub(1, #pre) == pre
           and (#suf == 0 or k:sub(- #suf) == suf) then
            local cur = k:sub(#pre + 1, #k - #suf)
            local pk  = liq[cur]
            if pk and pk > 0 and v + T.EPSILON >= pk then
                table.insert(out, { cur = cur, bal = v, pack = pk })
            end
        end
    end
    table.sort(out, function(a, b) return a.bal > b.bal end)
    return out
end

local function streams_for(cfg, fluids, pitch_cur, pitch_n, job,
                           base_code, ghost)
    -- ---- PITCH ----
    -- The boil's haul is definitionally one package of one tar,
    -- discovered by the valuation loop and passed in as pitch_cur.
    -- Credits are denominated in PITCH units, 1/threshold per tar,
    -- so write_whole_units pays a boulder exactly when the purse
    -- crosses one and the bank bar counts down to the next pitch.
    -- is per SIDE, BANK_PITCH or BANK_BITUMEN, named by the product
    -- the tar declares, kept apart from the production tar banks so
    -- credit never share a pocket, and a payout's material always
    -- derives from the tar that run actually consumed. No tar
    -- sighted this poll writes nothing and touches nothing.
    if cfg.profile == PROFILE_PITCH then
        if not pitch_cur then return {} end
        -- pitch_cur carries the PURSE currency itself, PITCH or
        -- BITUMEN, named by the product side upstream; pitch_n is
        -- how many qualifying tars this cycle holds, so a two tar
        -- fractionation credits two thirds. One threshold serves
        -- both sides by directive. Byproducts pay once per cycle
        -- through the each writer and touch no bank.
        local per = dial('TAR_UNITS_PER_PITCH')
        local out = {
            { currency = pitch_cur, at = cfg.pitch_slot or 0,
              credit = (pitch_n or 1) / per, kind = 'units',
              name = string.lower(pitch_cur) },
        }
        -- ---- THE FRACTIONS ----
        -- credit, not share: share is multiplied by haul, and a
        -- fractionation has no haul because its feedstock is
        -- witnessed inside a jug rather than valued as an item.
        -- pitch_n is the package count this cycle holds, so two jugs
        -- of crude credit twice one jug, which is the scaling that
        -- was missing.
        for _, fr in ipairs(cfg.fractions or {}) do
            table.insert(out, { currency = fr.currency, at = fr.at,
                credit = fr.share * (pitch_n or 0),
                kind = fr.kind, name = fr.name })
        end

        for _, e in ipairs(cfg.each or {}) do
            table.insert(out, { currency = e.name, at = e.at,
                kind = 'each', n = 1, name = e.name,
                nobank = true })
        end
        return out
    end

    -- ---- DRAIN ----
    -- No feed, so no credit: the projection is purely what the bank
    -- already holds. write_liquid then pays each slot up to its own
    -- container's capacity and settle carries the remainder, exactly
    -- as it does for a burn. Nothing downstream needs to know this
    -- reaction is different.
    if cfg.profile == PROFILE_DRAIN then
        local slots = cfg.drain_slots or {}
        local cands = (job and ghost)
                      and drain_candidates(base_code, job) or {}
        local out = {}
        for i, at in ipairs(slots) do
            local c = cands[i]
            local mi = c and currency_mat_index(c.cur) or nil
            if c and mi then
                -- The material write this whole design rests on.
                pcall(function()
                    ghost.products[at].mat_type  = 0
                    ghost.products[at].mat_index = mi
                end)
                table.insert(out, { currency = c.cur, at = at,
                    credit = 0, kind = 'liquid',
                    name = string.lower(c.cur) })
            else
                -- A slot with no bank behind it is zeroed rather than
                -- left carrying whatever a previous cycle wrote. Same
                -- stale slot hazard the writer already had.
                pcall(function() ghost.products[at].count = 0 end)
                if c and not mi then
                    log_once('drain_nomat:' .. tostring(c.cur), 'WARNING', string.format(
                            'DRAIN: %s has a bank but no inorganic'
                            .. ' named %s%s, so it cannot be poured.',
                            tostring(c.cur), MAT_PREFIX,
                            tostring(c.cur)), 'DRAIN')
                end
            end
        end
        if #out == 0 then
            -- INFO: it answers why a drain run poured nothing.
            log_once('drain_empty:' .. tostring(job and job.id or '?'), 'INFO', 'DRAIN: no bank at this furnace holds a whole package'
                .. ' of any liquid, so this run pours nothing.', 'DRAIN')
        end
        return out
    end

    if cfg.profile == PROFILE_KINDLING then
        return {
            { currency = CURRENCY_KINDLING, at = 0, share = 1,
              kind = 'units', name = 'kindling' },
        }
    end

    if cfg.profile == PROFILE_ASH then
        local s = {
            { currency = CURRENCY_ASH, at = 0, share = 1,
              kind = 'units', name = 'ash' },
        }
        if cfg.secondary_at then
            table.insert(s, {
                currency = CURRENCY_CHARCOAL, at = cfg.secondary_at,
                share = dial('CHARCOAL_FROM_ASHING'), kind = 'ladder' })
        end
        return s
    end

    -- CHARCOAL, COKE, and the default for anything unrecognised. A
    -- retort is a charcoal reaction with liquid slots, and its
    -- charcoal and ash are scaled by the retort share.
    --
    -- ---- COKE TAKES THE RETORT SHARE, LIKE EVERYTHING ELSE ----
    -- This used to exempt coke, on the grounds that coal had no
    -- furnace route to be measured against. That is no longer true:
    -- the hijacker prices vanilla's smelter coking on this same
    -- curve, so coal now has exactly the pair wood has always had.
    --
    -- The share is what stops a retort dominating the furnace it
    -- sits beside. Without it the retort pays identical coke AND
    -- captures the tar and ammonia, which makes the smelter dead
    -- content and the choice between them no choice at all.
    --
    -- The old note also argued the volatiles were already deducted
    -- twice, by CARBON_RECOVERY and by FLUID_CLASS. That is just as
    -- true of wood, which takes the share anyway, so it was never an
    -- argument about coke. The share is a design lever, not volatile
    -- accounting.
    --
    -- MEASURED, at 0.750: a bituminous boulder pays 7 green coke at
    -- the smelter and 1 coke plus 5 green at the retort, and lignite
    -- pays 2 coke, 2 green and 2 breeze against 2 green. The smelter
    -- gives about a third more solid fuel and burns fuel to do it;
    -- the retort runs cold and keeps the liquids.
    --
    -- Everything below this line is shared. Coke differs by two
    -- fields now and reuses the liquid handling untouched, which is
    -- why there is no second copy of it.
    local coke  = (cfg.profile == PROFILE_COKE)
    local scale = cfg.liquid_slots
                  and dial('RETORT_CHARCOAL_SHARE') or 1
    local s = {
        { currency = coke and CURRENCY_COKE or CURRENCY_CHARCOAL,
          at = 0, share = scale, kind = 'ladder',
          ladder = coke and LADDER_COAL or nil },
    }
    if cfg.secondary_at then
        table.insert(s, {
            currency = CURRENCY_ASH, at = cfg.secondary_at,
            share = scale * dial('ASH_FROM_CHARRING'), kind = 'units',
            name = 'ash' })
    end

    -- ---- COAL ASH, THE COKE SIDE'S SECONDARY ----
    -- The same shape as wood's ash above and for the same reason: one
    -- whole-unit stream off the primary's value, banked, everything
    -- under one carried. It is a separate line only because the coke
    -- ladder has no BAR_ASH slot to hang SECONDARY_SLOT off, so the
    -- position is found by material in derive_config instead.
    --
    -- NOT scaled by the retort share. The share prices the volatiles
    -- the retort keeps instead of burning, and ash is what neither
    -- route can burn: a boulder's mineral fraction is the same whether
    -- it cokes in a smelter or a retort.
    if cfg.ash_coal_at then
        table.insert(s, {
            currency = CURRENCY_ASH_COAL, at = cfg.ash_coal_at,
            share = dial('ASH_FROM_COKING'), kind = 'units',
            name = 'coal ash' })
    end

    -- Coke's reagent byproducts. One per cycle, no bank, exactly as
    -- the pitch chain pays its non residue slots. Empty on every
    -- other profile, so this line costs nothing anywhere else.
    for _, e in ipairs(cfg.each or {}) do
        table.insert(s, { currency = e.name, at = e.at, kind = 'each',
                          n = 1, name = e.name, nobank = true })
    end

    -- ---- LIQUIDS ----
    -- One stream per currency that either has a slot on this
    -- reaction or was valued off what walked in. A slot with no
    -- value this job still gets its bank read, so a stranded
    -- balance from another feedstock pays out here.
    if cfg.liquid_slots then
        local seen_cur = {}
        for cur, at in pairs(cfg.liquid_slots) do
            seen_cur[cur] = true
            table.insert(s, { currency = cur, at = at, credit = (fluids or {})[cur] or 0,
                              kind = 'liquid', name = string.lower(cur) })
        end
        for cur, v in pairs(fluids or {}) do
            if not seen_cur[cur] and v > 0 then
                table.insert(s, { currency = cur, at = nil, credit = v,
                                  kind = 'liquid', name = string.lower(cur) })
            end
        end
    end
    return s
end

-- ==========================================
-- BANKED OUTPUT
-- ==========================================
-- Values what the job holds, credits each stream's bank with its
-- share on the way in, writes the ghost's product counts, and
-- reports what the payout consumes.
--
-- NOTHING IS DEBITED HERE. The banks are settled only when a job is
-- confirmed to have burned its items, in the audit sweep. A job that
-- dies holding its item must not be charged for value it never
-- burned, and this function cannot tell the difference.
--
-- Returns streams, detail, inert_hit, out, haul.
--
-- `streams` is one record per currency: the bank it drew on, what
-- that bank held, what this job added, the total the slots were
-- written from, and what those slots cost. settle() carries the
-- difference. `out` is what was actually written to the products;
-- without it there is no way to tell a payout that fired from one
-- that did not, which is exactly the question a bank raises every
-- time it moves.
-- ==========================================
-- ==========================================
-- PRESERVED SLOT, ONE IMPLEMENTATION, FILE SCOPE
-- ==========================================
-- Takes everything it reads as parameters, because this file has
-- now shipped the same wound twice in one hunt: code in one
-- function silently calling names that live inside another, with a
-- pcall eating the nil call for rounds. The witness insert did it
-- from apply into handle's tables; the identity block did it from
-- handle into apply's nested function. Nothing here reaches for an
-- upvalue again.
-- job_item_idx names a FILTER; the filter names its reagent. An
-- unreadable mapping counts the item IN, since false evidence has
-- lost credits and never once invented one.
-- ---- AN UNREADABLE SLOT IS PRESERVED, NOT FEED ----
--
-- This used to return false whenever the read failed, which put the
-- item into the consumable pile. That default is backwards: not
-- knowing what a slot is must never mean "burn it".
--
-- MEASURED, and it crashed the game. A corpse job expanded to five
-- vessel slots, then a data cycle deleted its ghost, and sweep_orphans
-- reverted the job onto MAKING_FUEL_RXN_RETORT_CORPSE, which declares
-- THREE reagents. The job still held five items. Reagent indices 3 and
-- 4 did not exist on the reaction it now pointed at, the read threw,
-- and both of those jugs were valued as feed:
--
--   . aluminum jug  size=30  INERT  d=2700  = 0.000000
--   . aluminum jug  size=30  INERT  d=2700  = 0.000000
--   INERT REFUSED: job 19 holds aluminum jug, which does not burn.
--
-- Exactly two, which is five items minus the three reagents the base
-- has. That count is the fingerprint.
--
-- The three outcomes now differ, and each is honest about what it
-- knows:
--
--   no owner recorded   not preserved, the original behaviour, and
--                       genuinely unowned
--   read succeeded      whatever the reagent says
--   read failed         PRESERVED, because the job and the reaction
--                       disagree about their own shape and the only
--                       safe move is to leave the item alone
--
-- The last case is a fault, so it is named once per item rather than
-- swallowed. On a well formed job it never fires.
local function slot_preserved(job, rxn, iref)
    local idx = iref.job_item_idx
    if not idx or idx < 0 then return false end

    -- ---- DF'S FUEL IS NOT A REAGENT ----
    -- A fuel:true reaction gets one extra job_item that DF wrote
    -- itself, carrying reagent_index -1 and reaction_id -1. Measured
    -- on a live MAKE_CLAY_JUG: it is disconnected from the reaction
    -- entirely. Looking -1 up on rxn.reagents throws, which used to
    -- land in the fault path below and name a well formed job as
    -- broken once per fuel item.
    --
    -- Answered as PRESERVED because that is what it is from this
    -- file's point of view: DF consumes the fuel through its own
    -- machinery and the ghost must neither value it nor charge for
    -- it. The difference from the fault path is only that this is
    -- expected and says nothing.
    local ri = nil
    pcall(function() ri = job.job_items.elements[idx].reagent_index end)
    if ri and ri < 0 then return true end

    local ok, preserved = pcall(function()
        return rxn.reagents[ri].flags.PRESERVE_REAGENT
    end)
    if ok then return preserved == true end

    -- ---- WHAT THIS HAS MEANT IN PLAY ----
    -- MEASURED, job 10111, BOIL_TAR: a fuel item left pointing past the
    -- end of job_items after access.lua's start sweep erased bulk fuel
    -- copies under it (since guarded: the sweep no longer erases under
    -- an item). DF completed the job without a crash and burned what it
    -- held, 2 dried dung of the 4 owed. So on a fuel item this line
    -- means an underpaid cycle, not a coming crash. R22's crash was a
    -- different mismatch, a FILTER naming a reagent the reaction does
    -- not have. Register L22.
    local iid = '?'
    pcall(function() iid = tostring(iref.item.id) end)
    log_once('slotgap:' .. tostring(job.id) .. ':' .. iid, 'WARNING', string.format(
        'Job %d holds item #%s in a slot %s does not have. The job and'
        .. ' the reaction disagree about their shape. Treating it as'
        .. ' PRESERVED so nothing is consumed by accident.',
        job.id, iid, tostring(rxn and rxn.code or '?')), 'SLOT')
    return true
end

local function apply_banked_yield(job, ghost, base_code, cfg)
    if not ghost or #ghost.products < 1 then return nil end
    local profile = cfg.profile

    -- ---- VALUE OF WHAT THE JOB HOLDS ----
    -- One item under normal running. More only on a legacy job left
    -- mid-collection by the old shape, which needs no special casing
    -- because this simply sums whatever is there.
    local haul      = 0
    local detail    = {}
    local inert_hit = nil
    -- The tar currency this cycle holds, for the pitch purse.
    local pitch_cur = nil
    -- The burn witnesses, returned to the CALLER, because ids,
    -- stacks and dims are handle_ghosted locals: an insert from in
    -- here lands on nil and the pcall eats the throw. Three rounds
    -- of silently discarded evidence taught this comment its tone.
    -- A LIST now: fractionations hold several tars per cycle.
    local pitch_witness = {}
    local pitch_n = 0
    local pitch_seen = {}
    -- [currency] = liquid units this job's items condense to. Only
    -- ever filled on a reaction with liquid slots.
    local fluids    = {}

    -- ---- PRESERVED REAGENTS ARE NOT FEEDSTOCK ----
    -- job.items is every item DF attached, which includes the empty
    -- buckets and the container holding a liquid reagent. Those are
    -- PRESERVE_REAGENT slots: they come back out untouched, so they
    -- are apparatus, not charge, and valuing them is wrong twice.
    --
    -- A wooden bucket classifies WOOD and gets burned as feedstock,
    -- silently inflating every retort yield by the volume of the
    -- container. A metal one classifies INERT and trips the refusal
    -- below, which suspends the job, releases the item, and lets the
    -- repeat job pick the same bucket again forever.
    --
    -- The refusal comment says an inert hit means a reagent is
    -- missing its material gate. That holds for feedstock. It does
    -- not hold for containers, which are deliberately ungated because
    -- any bucket will do, so they have to be skipped here instead.
    --
    -- iref.job_item_idx indexes the reagent list. It is -1 when DF
    -- attached an item to no particular filter, and those are left in
    -- rather than guessed at.
    -- Delegates to the file scope implementation above so the chain
    -- lives exactly once. The local name survives for the call
    -- sites in the valuation loop below.
    local function is_preserved_slot(iref)
        return slot_preserved(job, ghost, iref)
    end

    for _, iref in ipairs(job.items) do
        local v, size, class, density, path, mat_token
        -- Corpse pieces also hand back whole size and piece share.
        local whole_size, piece_share
        if profile == PROFILE_PITCH then
            -- The feedstock is never ATTACHED: tars ride inside
            -- preserved jugs, so this branch runs BEFORE the
            -- preserved slot skip and searches item CONTENTS. Every
            -- qualifying tar is witnessed and counted; the purse is
            -- named by the PRODUCT side each tar declares, target
            -- id minus the module prefix. Read with the .value
            -- accessor; a tostring on these entries prints a
            -- pointer.
            pcall(function()
                local inside = dfhack.items.getContainedItems(iref.item)
                if not inside then return end
                for _, cc in ipairs(inside) do
                    if cc:getType() == df.item_type.LIQUID_MISC
                       and cc.mat_type == 0 and cc.mat_index >= 0
                       and not pitch_seen[cc.id] then
                        local m = df.global.world.raws.inorganics
                            .all[cc.mat_index]
                        local rp = m.material.reaction_product
                        for i = 0, #rp.id - 1 do
                            if rp.id[i].value == 'PITCH_MAT' then
                                local ti = rp.material.mat_index[i]
                                local tgt = df.global.world.raws
                                    .inorganics.all[ti].id
                                pitch_cur = bare(tgt)
                                pitch_n = pitch_n + 1
                                pitch_seen[cc.id] = true
                                table.insert(detail, string.format(
                                    'tar #%d %s -> %s purse',
                                    cc.id, m.id,
                                    string.lower(pitch_cur)))
                                local sz = 1
                                pcall(function()
                                    sz = cc.stack_size or 1
                                end)
                                local dm = nil
                                pcall(function()
                                    dm = cc.dimension
                                end)
                                table.insert(pitch_witness, {
                                    id = cc.id, stack = sz, dim = dm,
                                })
                                break
                            end
                        end
                    end
                end
            end)
            goto next_item
        end
        if is_preserved_slot(iref) then
            goto next_item
        end
        if profile == PROFILE_KINDLING then
            -- Kindling leaves mat_token nil on purpose: split wood
            -- is dry by definition and nil is the fluid curve's
            -- neutral.
            v, size = item_kindling(iref.item)
            class, path = 'WOOD', 'split'
        else
            v, size, class, density, path, mat_token,
                whole_size, piece_share = item_value(iref.item)
        end

        -- ---- STACK FRACTION ----
        -- v is the WHOLE item's value, and getVolume scales with the
        -- stack, but DF consumes only the reagent's quantity from a
        -- stack and leaves the rest as the same item. Value only what
        -- this cycle takes: quantity over stack size, capped at one.
        -- Measured on rotten meat fed one unit per cycle: a [20] stack
        -- was priced at 4000 volume every cycle while one unit burned.
        -- Non-stacked items are untouched (fraction one).
        local frac = 1
        pcall(function()
            local sz = iref.item.stack_size or 1
            if sz > 1 then
                -- Consumption per completion is the RAWS reagent
                -- quantity (measured: one unit per cycle even with the
                -- job item zeroed), so the fraction reads the ghost
                -- clone's own reagent, which mirrors the base. The job
                -- item quantity only governs seeking.
                local q = 1
                pcall(function() q = ghost.reagents[0].quantity end)
                if not q or q < 1 then q = 1 end
                frac = math.min(1, q / sz)
            end
        end)

        -- ---- RETORT: THE LIQUID SIDE OF THE SAME ITEM ----
        -- Its own curve, split across liquids by class. Size and
        -- class are the ones item_value already read; a stack's
        -- volume carries through, and a corpse piece prices the
        -- whole creature times its share below.
        if cfg.liquid_slots and v and size and class ~= 'INERT' then
            -- ctx carries the moisture correction; see fluid_yield.
            -- Flesh arrives with a nil token by design and pays the
            -- old curve exactly.
            --
            -- Corpse pieces price the WHOLE creature and take the
            -- piece share, the additive form the solid limb already
            -- uses. Curving the pre-cut size re-inflates a piece by
            -- the exponent, x7 on a skull, and paid butchery over
            -- charring whole corpses.
            local fl
            if whole_size and piece_share then
                fl = tuning.fluid_yield(whole_size, class, density,
                         { mat_token = mat_token }) * piece_share * frac
            else
                fl = tuning.fluid_yield(size, class, density,
                         { mat_token = mat_token }) * frac
            end
            if fl > 0 then
                for cur, share in pairs(T.FLUID_SPLIT[class] or {}) do
                    fluids[cur] = (fluids[cur] or 0) + fl * share
                end
            end
        end

        -- ---- INERT ----
        -- A wood furnace cannot consume something that does not burn.
        -- This should be unreachable: the reagent gate stops DF ever
        -- selecting an inert item. Reaching it means a reagent is
        -- missing its material flag, so it is reported as a fault
        -- rather than silently valued at zero.
        --
        -- EXCEPT ON A DRAIN. Its only consumed reagent is the key, a
        -- fireproof tool that exists to make the reaction available and
        -- is destroyed by running it. It is not fuel and was never
        -- meant to burn, so "this does not burn" is not a complaint
        -- worth suspending a job over. Without this gate every drain
        -- run would suspend itself on its own key.
        if class == 'INERT' and cfg.profile ~= PROFILE_DRAIN then
            local d = '?'
            pcall(function() d = dfhack.items.getDescription(iref.item, 0) end)
            inert_hit = tostring(d)
        end

        if v then
            haul = haul + v * frac
            local d = '?'
            pcall(function() d = dfhack.items.getDescription(iref.item, 0) end)
            table.insert(detail, string.format(
                '%s  size=%.0f %s d=%s -> %.6f',
                tostring(d), size or -1, tostring(class),
                tostring(density or '-'), v))
            -- Keyed on the ITEM, not on the value. handle_ghosted runs
            -- six times a second per job, so an unkeyed line here
            -- produced hundreds of identical entries. Keying on the
            -- item id prints once per item that actually arrives,
            -- which is the event worth seeing, while still showing a
            -- repeat if the same item is somehow read twice.
            log_once('item:' .. job.id .. ':' .. tostring(iref.item.id), 'DETAIL', string.format('    . %s  size=%.0f  %s  d=%s  [%s]  = %.6f',
                    tostring(d), size or -1, tostring(class),
                    tostring(density or '-'), tostring(path), v), 'AUDIT')
        end
        ::next_item::
    end

    -- ---- REFUSE ONLY A CHARGE THAT CANNOT BURN AT ALL ----
    -- This used to refuse on the FIRST inert item, whatever else was
    -- in the job. MEASURED, job 20: a fluxed retort holding lignite
    -- worth 8.043 and one limestone was suspended on the limestone,
    -- and the log said the reagent was missing a material gate. The
    -- gate was correct. Limestone is a flux stone, the flux slot asks
    -- for one on purpose, and it is where the gypsum and brimstone
    -- come from.
    --
    -- The guard's actual purpose is that a furnace cannot consume a
    -- charge that does not burn, and the honest test of that is the
    -- haul, not any single item. A job that valued something burns;
    -- an inert item beside it is an additive, not a mistake. A lone
    -- stone chair still hauls zero and is still refused.
    --
    -- The tolerated case is logged rather than silent, because an
    -- inert item IS consumed for no yield and that is worth seeing
    -- once if a reagent really is ungated.
    if inert_hit then
        if haul <= 0 then
            return nil, detail, inert_hit, nil, haul
        end
        log_once('inertok:' .. tostring(job.id), 'DETAIL', string.format(
            'job %d consumes %s, which does not burn, alongside a'
            .. ' charge worth %.4f. Allowed as an additive.',
            job.id, tostring(inert_hit), haul), 'AUDIT')
    end

    -- ---- ONE STREAM PER CURRENCY ----
    -- Each stream is credited with its share of the haul on top of
    -- what its bank already holds, writes its slots from that total,
    -- and records total and cost for settle().
    local streams = {}
    local out     = {}

    -- ---- CONTAINERS, SPLIT IN PROPORTION TO WHAT WAS EARNED ----
    -- The containers are shared across a job's currencies, because
    -- two currencies asking for a second jug are competing for the
    -- same pile and counting per stream would promise the same jug
    -- twice. Sharing was right; FIRST COME was not.
    --
    -- Measured on one whale: ammonia runs earlier in the stream order,
    -- took all seven containers on its 11 packages, and oil bone,
    -- which had earned 35, got none at all. A currency earning three
    -- times as much came away with nothing because of the order the
    -- loop happened to visit it in.
    --
    -- So the wants are totalled BEFORE anything is handed out, and
    -- each currency gets its share of the pile. Largest remainder, so
    -- the whole pile is dealt out rather than lost to rounding.
    local spec_list = streams_for(cfg, fluids, pitch_cur, pitch_n,
                                  job, base_code, ghost)

    -- ---- SAY WHEN SLOTS AND CLASS DISAGREE ----
    -- streams_for builds the liquid list from the UNION of what this
    -- reaction declares a container for and what the feed actually
    -- earned, so the two can disagree in either direction and neither
    -- one is an error the code can decide on its own. Both are silent
    -- without this, and both were reported identically to a stream
    -- that was working, which is exactly how a fat banked bone oil
    -- for as long as RETORT_GLOB existed.
    --
    -- EARNED WITH NO CONTAINER. Legitimate: banks key on currency and
    -- building, BANK_OIL_BONE@5, so a sibling reaction at the same
    -- furnace pays it out and nothing is lost. Worth saying once so a
    -- currency piling up somewhere it can never leave is visible.
    --
    -- CONTAINER WITH NOTHING TO PUT IN IT. This is the one that
    -- matters. A declared slot the feed never funds pays zero and DF
    -- mints a null into it on every single run, which the reaper then
    -- clears. Harmless and endless. It means the reaction's slots and
    -- the feed's FLUID_SPLIT do not agree, which is an authoring
    -- fault, not a runtime one.
    --
    -- Gated on two things so it does not cry wolf. The job must have
    -- earned SOME liquid, otherwise an inert feed would light up every
    -- slot it has. And the bank must be empty too, because
    -- streams_for deliberately keeps a slot alive on a zero earning
    -- job so a balance stranded by another feedstock can drain
    -- through it, and that is working as intended rather than a
    -- disagreement.
    --
    -- log_once keyed on reaction and currency, not on job, because
    -- this is a property of how the reaction is written. Once per
    -- session is the whole point; saying it per job would be noise.
    do
        local earned_any = false
        for _, v in pairs(fluids or {}) do
            if (v or 0) > 0 then earned_any = true end
        end

        for _, spec in ipairs(spec_list) do
            if spec.kind == 'liquid' then
                local c = spec.credit or 0
                if not spec.at then
                    if c > 0 then
                        log_once('noslot:' .. tostring(base_code)
                                 .. ':' .. tostring(spec.currency), 'DETAIL', string.format(
                                'VESSEL: job %d earned %.6f %s, which %s has'
                                .. ' no container for. It banks at this'
                                .. ' furnace and a reaction here that does'
                                .. ' declare one will pay it out.',
                                job.id, c, tostring(spec.name),
                                tostring(base_code)), 'VESSEL')
                    end
                elseif c <= 0 and earned_any then
                    local held = 0
                    if not spec.nobank then
                        pcall(function()
                            held = yield_bank[
                                bank_key(base_code, spec.currency, job)] or 0
                        end)
                    end
                    if held <= 0 then
                        log_once('deadslot:' .. tostring(base_code)
                                 .. ':' .. tostring(spec.currency), 'WARNING', string.format(
                                'VESSEL: %s declares a container for %s but'
                                .. ' this feed funds none of it and the bank'
                                .. ' is empty, so that slot pays nothing and'
                                .. ' DF mints a null every run. Check this'
                                .. ' reaction against FLUID_SPLIT for the'
                                .. ' class it is being fed.',
                                tostring(base_code), tostring(spec.name)), 'VESSEL')
                    end
                end
            end
        end
    end

    local free_vessels = nil
    local allow = {}

    do
        local wants, total, pkgs = {}, 0, {}
        for _, spec in ipairs(spec_list) do
            if spec.kind == 'liquid' and spec.at then
                -- NOT `spec.nobank and nil or bank_key(...)`. In Lua
                -- that expression can never yield nil: `true and nil`
                -- is nil, and `nil or x` is x, so the fallback fired
                -- on BOTH branches and nobank never once took effect.
                local key = nil
                if not spec.nobank then
                    key = bank_key(base_code, spec.currency, job)
                end
                local banked = key and (yield_bank[key] or 0) or 0
                local credit = spec.credit
                    or (spec.share and haul * spec.share) or 0
                -- Containers, not packages. See containers_wanted.
                local pk = (T.LIQUID_STANDARD or {})[spec.currency]
                           or T.LIQUID_STANDARD_DEFAULT or 1
                if pk < 1 then pk = 1 end
                -- Both numbers are kept. `wants` counts CONTAINERS,
                -- which is what gets allotted. `pkgs` counts PACKAGES,
                -- which is what the player is told they earned. Since
                -- a jug holds sixteen, reporting one where the other
                -- is meant is a log that lies.
                local pw = packages_wanted(banked + credit, spec.currency)
                local w = containers_wanted(job, ghost, spec.at, pw, pk) - 1
                pkgs[spec.currency] = pw
                if w > 0 then
                    wants[spec.currency] = w
                    total = total + w
                end
            end
        end

        -- Asked once, here, so the whole pre pass is skipped for a
        -- job that cannot use containers anyway. That saves a full
        -- item vector walk in count_free_vessels, and it stops the
        -- allotment line claiming a job was allotted 35 containers
        -- on a run where it was never able to ask for one.
        if total > 0 and not collection_open(job, expand_for(job)) then
            total = 0
        end

        if total > 0 then
            free_vessels = count_free_vessels(job, ghost)
            local pool = free_vessels
            if pool > total then pool = total end

            -- Floor each share, then hand the remainder to whoever
            -- lost the most to rounding. Without this a pile of 7
            -- split 34 to 10 deals out 5 and 1 and strands a
            -- container nobody asked for.
            local left, rema = pool, {}
            for cur, w in pairs(wants) do
                local exact = pool * w / total
                local n = math.floor(exact)
                allow[cur] = n
                left = left - n
                table.insert(rema, { cur = cur, r = exact - n })
            end
            table.sort(rema, function(a, b) return a.r > b.r end)
            local i = 1
            while left > 0 and #rema > 0 do
                local cur = rema[i].cur
                if allow[cur] < (wants[cur] or 0) then
                    allow[cur] = allow[cur] + 1
                    left = left - 1
                end
                i = i + 1
                if i > #rema then
                    -- One full pass handed nothing out, so every
                    -- currency is already at its want. Stop rather
                    -- than spin.
                    if left == pool then break end
                    i, pool = 1, left
                end
            end

            for cur, n in pairs(allow) do
                if n > 0 then
                    log_once('vessel_alloc:' .. job.id .. ':' .. cur, 'DETAIL', string.format(
                            'VESSEL: job %d allots %d extra container(s)'
                            .. ' of %d free to %s, which earned %d'
                            .. ' package(s). One container takes many.',
                            job.id, n, free_vessels,
                            string.lower(cur), pkgs[cur] or 0), 'VESSEL')
                end
            end
        end
    end

    for _, spec in ipairs(spec_list) do
        -- Same trap as the liquid loop above: `x and nil or y` is
        -- always y. Every `each` stream in the module has been
        -- carrying a bank key it was explicitly denied, which is how
        -- BANK_oil lubricating@4 came to exist with a space in it.
        local key = nil
        if not spec.nobank then
            key = bank_key(base_code, spec.currency, job)
        end
        local banked    = key and (yield_bank[key] or 0) or 0
        local credit    = spec.credit
            or (spec.share and haul * spec.share) or 0
        local projected = banked + credit

        local paid, wrote
        if spec.kind == 'ladder' then
            -- spec.ladder is nil on every wood path, which selects
            -- LADDER_WOOD inside the writer.
            paid, wrote = write_ladder(ghost, spec.at, projected,
                spec.ladder)
        elseif spec.kind == 'liquid' then
            -- Containers, not packages. The same conversion the pre
            -- pass uses, so the two cannot disagree about how many
            -- vessels this currency is asking for.
            local pk = (T.LIQUID_STANDARD or {})[spec.currency]
                       or T.LIQUID_STANDARD_DEFAULT or 1
            if pk < 1 then pk = 1 end
            local want  = containers_wanted(job, ghost, spec.at,
                packages_wanted(projected, spec.currency), pk)
            local slots = { spec.at }
            if want > 1 and spec.at then
                -- Its OWN allowance from the pre pass, not whatever
                -- the pile happens to hold when the loop reaches it.
                -- Anything it does not spend goes back, so a currency
                -- that cannot use its full share does not strand it.
                local mine_pool = allow[spec.currency] or 0
                local before = mine_pool
                slots, mine_pool = slots_for_liquid(
                    job, ghost, spec.at, want, mine_pool, spec.currency,
                    packages_wanted(projected, spec.currency))
                allow[spec.currency] = mine_pool
                local spent = before - mine_pool
                if free_vessels then free_vessels = free_vessels - spent end
            end
            crumb('G write_liquid in', string.format('%s slots=%d',
                  tostring(spec.currency), #slots))
            paid, wrote = write_liquid(job, ghost, slots, projected,
                                       spec.name, spec.currency)
            crumb('H write_liquid out', tostring(paid))
        elseif spec.kind == 'each' then
            paid, wrote = write_each(ghost, spec.at, spec.n or 1,
                                     spec.name)
        else
            paid, wrote = write_whole_units(ghost, spec.at, projected,
                                            spec.name)
        end
        for _, o in ipairs(wrote) do table.insert(out, o) end

        table.insert(streams, {
            currency = spec.currency, bank = key,
            bank_in = banked, haul = credit, sum = projected, paid = paid,
        })
    end

    return streams, detail, nil, out, haul, pitch_witness
end

-- ==========================================
-- FILTER REPAIR
-- ==========================================
-- Two jobs, both narrow, and NEITHER of them grows anything.
--
--   1. Clear the material lock off every filter, every poll.
--   2. Shrink a filter vector that a previous build left too long.
--
-- WHY THERE IS NO GROWTH PATH ANY MORE
--
-- The old version set its target from #job.items and grew the filter
-- and reagent vectors to match. That is only correct if one item means
-- one filter, which was true under the old collection scheme and is
-- false now.
--
-- A REAGENT WITH quantity N IS ONE FILTER THAT WANTS N ITEMS. Dung is
-- one reagent at quantity 8, branches one at quantity 2. So eight dung
-- attached means #job.items is 8 while #job.job_items.elements is 1.
-- Reading 8 as a filter count grew the vector to 8, each clone
-- carrying quantity 8 from the prototype, so the job then wanted 64.
-- Every arrival grew it again. Observed live: dung reached filters=26
-- and branches filters=65, and neither job could ever be satisfied.
-- 28 of the 123 adaptive reactions declare quantity above 1.
--
-- The base reaction already declares the right reagent count and the
-- right quantity. DF materialises filters from it correctly. There is
-- nothing for this function to add.
--
-- Shrinking erases but does not delete(). A leaked job_item is a few
-- dozen bytes; a use after free is a crash.
-- ==========================================
-- Base reactions resolved once per code and cached. The repair runs
-- five times a second per live job; walking the reaction array that
-- often would be a scan per poll for a value that never changes.
--
-- ---- THE CACHE VALIDATES ITSELF ON READ ----
--
-- MEASURED, second whale after an ESC menu. A data cycle logs
-- `CLEAR RXN: Excised 594 injected reactions from RAM` and then
-- rebuilds. A pointer cached before that points at a freed block, and
-- the allocator hands that block to one of the reactions injected
-- afterwards. It is not corrupted memory: it is a real, live, WRONG
-- reaction.
--
-- What that did. repair_filters copies materials off base.reagents
-- onto the live job's filters. The address held one of the RM alloy
-- variants, which carry `mat_type = 0` and a specific inorganic
-- mat_index (refinish-index-reaction.lua:309 and :316) and have two
-- reagents. So a corpse job came back with
--
--   [0] type=CORPSE mat=0/8    [1] type=TOOL mat=0/83    [2] mat=-1/-1
--
-- Filter 2 was untouched because that object has no third reagent.
-- mat_type 0 is INORGANIC and a corpse is 22, so slot 0 could never
-- be satisfied and DF cancelled: "needs corpse".
--
-- Clearing the cache on a cycle is not enough on its own, because it
-- depends on someone remembering to call the hook. Comparing the
-- cached object's own code against the one asked for costs one string
-- read and cannot be forgotten. A mismatch means the address was
-- reused, so the entry is dropped and the array rescanned.
--
-- ---- AND A MISS IS NEVER CACHED ----
--
-- The old `false` sentinel meant "looked, not there, never look
-- again". That was safe while every reaction existed at boot. It is
-- not any more: making-fuel-drain-key.lua mints per retort drain
-- clones during play, so a drain job in flight across a cycle can ask
-- for a clone that has not been re-minted yet. Caching that miss
-- would leave the job on wildcard filters for the rest of the session
-- with nothing said. Same rule the concrete watcher states for its own
-- ghost lookup.
local base_cache = {}
local function base_reaction(code)
    local hit = base_cache[code]
    if hit then
        local live = nil
        pcall(function() live = tostring(hit.code) end)
        if live == code then return hit end
        base_cache[code] = nil
        log_once('stale_base:' .. code, 'WARNING', string.format(
            'Base reaction %s was cached across a data cycle and its'
            .. ' address now holds %s. Dropped and rescanned.',
            code, tostring(live)), 'CACHE')
    end

    local found = nil
    pcall(function()
        for _, rx in ipairs(df.global.world.raws.reactions.reactions) do
            if rx.code == code then found = rx; break end
        end
    end)
    if found then base_cache[code] = found end
    return found
end

-- ==========================================
-- FUEL FILTERS ARE NOT THE GHOST'S
-- ==========================================
-- A reaction with fuel on carries DF's own fuel filter, and on the
-- kiln tier making-fuel-access.lua appends three copies of it (the
-- bulk surcharge: four bulk fuels or one finished fuel). None of them
-- belongs to a reagent, so none is part of the authored shape
-- repair_filters defends, and none is the ghost's to stamp or erase.
--
-- MEASURED, job 10050, BOIL_TAR at the kitchen with fuel on: access
-- grew the job to 5 filters, repair_filters counted them against 2
-- reagents and shrank it back to 2, and the job burned one bulk fuel
-- where it owed four. The shrink erases from the END, which is where
-- the surcharge copies sit.
--
-- Recognised by is_fuel_slot in making-fuel-tuning.lua, the one
-- definition the fuel access layer uses too: a slot that serves no
-- reagent and looks like fuel. A reagent that IS coal names its reagent,
-- so it is restored and counted like any other reagent. Register L21.
--
-- ---- WHAT LEAVING FUEL ALONE DOES NOT COVER ----
-- Read before putting fuel on any ghosted reaction.
--
-- 1. THE TAIL IS SHARED, AND BOTH SIDES NOW KNOW IT. The fuel access
--    layer appends its bulk copies at the END of job_items, and
--    restore_fuel puts a tanked job's slot back at the END.
--    append_vessel_triple appends here too, a filter, a reagent and a
--    product per extra jug. Each side now takes back only what it can
--    name: the fuel side its own copies, which own no reagent, and this
--    side the filters owned by the reagents it appended. Neither reads
--    position any more.
--    UNTESTED TOGETHER: no ghosted reaction that makes liquids has run
--    with fuel on. Before turning fuel on for the retort reactions or
--    the distils, run one full cycle with jugs expanded and read the
--    VESSEL line: it should release as many filters as jug slots, and
--    the job's DETAIL line should keep its fuel count. Register R31.
--
-- 2. A REAGENT TYPED AS BUILTIN COAL. access.lua swaps it for the
--    module's coals (widen_coal_reagents, register L15), then
--    repair_filters restores the authored material, builtin COAL, on
--    every poll. The coal watcher makes sure no builtin coal exists, so
--    the job waits forever. On a ghosted reaction, author coal reagents
--    by identity class (COKE, CHARCOAL, COAL), never as builtin coal.
--
-- 3. FUEL IS OUTSIDE THE BAND. FILTER REPAIR and SLOT DESYNC count
--    reagent filters only. Fuel shows as "(N fuel)" on the job's DETAIL
--    and PHASE lines: 4 on the kiln tier, 1 on the smith tier, none on
--    a tanked job or a wood furnace job.
--
-- 4. "HOLDS ITEM #N IN A SLOT ... DOES NOT HAVE" ON A FUEL ITEM means
--    an underpaid cycle, not a coming crash. See slot_preserved.
local function is_fuel_filter(e)
    if not tuning.is_fuel_slot then return false end
    return tuning.is_fuel_slot(e) == true
end

local function repair_filters(job, ghost, base_code)
    if not ghost then return -1, -1 end
    local base = base_code and base_reaction(base_code) or nil

    -- ---- THE LEGAL FILTER COUNT IS A BAND, NOT A NUMBER ----
    -- The ghost declares the reagents, and the ghost is deep copied
    -- from the base, so its reagent count is the authored shape. What
    -- it does NOT tell us is how many FILTERS DF will post for that
    -- shape, because DF sometimes folds a contained reagent into its
    -- container's filter and sometimes does not.
    --
    -- MEASURED, both directions, same engine:
    --   BOIL_PITCH        2 reagents, 1 contained, DF posted 1
    --   DISTIL_TAR_COAL   3 reagents, 1 contained, DF posted 3
    --
    -- The old code predicted the fold always happens. That matched the
    -- boil, which is where it was derived, and called the still broken
    -- six times a second for its whole run. Predicting it never
    -- happens would just move the noise onto the boil. The fold is not
    -- predictable from the reagent list, so it is not predicted.
    --
    -- CEILING     one filter per reagent, nothing folded.
    -- FOLD_FLOOR  every contained reagent folded into its container.
    --
    -- Between the two is DF being DF and is not a fault. Above the
    -- ceiling is the growth bug, which is what the shrink recovery
    -- below exists for. Below the floor is genuine loss.
    local ceiling, fold_floor = 0, 0
    pcall(function()
        ceiling = #ghost.reagents
        fold_floor = ceiling
        for _, r in ipairs(ghost.reagents) do
            if r.flags.IN_CONTAINER then
                fold_floor = fold_floor - 1
            end
        end
    end)
    if ceiling < 1 then return -1, -1 end

    -- ---- FUEL FILTERS STAND OUTSIDE THE BAND ----
    -- Marked once, up front, by index. Every fuel filter is skipped by
    -- the material restore below, left out of the count the shrink and
    -- the band check compare, and never erased. See FUEL FILTERS ARE
    -- NOT THE GHOST'S above. The marks stay valid through the shrink,
    -- because it only ever erases from the end.
    local fuel_at, n_fuel = {}, 0
    pcall(function()
        local els = job.job_items.elements
        for i = 0, #els - 1 do
            if is_fuel_filter(els[i]) then
                fuel_at[i] = true
                n_fuel = n_fuel + 1
            end
        end
    end)

    pcall(function()
        local els = job.job_items.elements

        -- ---- RESTORE FILTERS TO THE AUTHOR ----
        -- History, because this block has now been wrong in both
        -- directions. The JIT clone is specialised per creature, and
        -- on a re-post DF rebuilds job_items from the CLONE, so a
        -- corpse job inherited an exact tissue and race lock and
        -- waited forever beside a fort full of other creatures'
        -- parts. The first fix wiped every filter to WILDCARD, which
        -- killed that stall and quietly erased every gate an author
        -- had declared: the filter is the only lock DF honours when
        -- fetching, so wiping it is how a dried dung job ate wet
        -- piles. Proven on job 466, five dried and three wet in one
        -- burn.
        --
        -- The principle that survives both failures: filters mirror
        -- the BASE reaction, never the clone and never the wildcard.
        -- The base says -1 for corpses, so the race lock stays dead.
        -- The base says dried dung for CHAR_DUNG_DRIED, so the gate
        -- survives the repair. This only holds because the engine
        -- now actually resolves mat_id onto base reagents; with no
        -- base in hand the old wildcard wipe is kept, since a stale
        -- clone lock is worse than an open filter.
        --
        -- Every poll rather than only on change, because DF
        -- re-materialises filters whenever it likes and we do not
        -- get to see when.
        -- ---- AN OCCUPIED SLOT IS NOT SEEKING ----
        -- The stall this block prevents happens on a RE-POST, when DF
        -- rebuilds job_items from the clone and inherits its race
        -- lock. A re-post starts with nothing attached, so the repair
        -- still does its whole job if it skips slots that already
        -- hold their item.
        --
        -- Skipping them stops it destroying a seal another watcher put
        -- there on purpose. MEASURED: the rot watcher sealed job 25's
        -- filter to `mat=21/296`, rotten wolf meat, and this loop
        -- wrote it back to `mat=-1/-1` because RETORT_ROT's base
        -- declares no material. The demand was then re-raised
        -- elsewhere and DF filled it with a chopped naked mole dog
        -- liver, which is not rotten and was never consumed.
        --
        -- It is also what R19 did: 0/8 stamped onto an occupied corpse
        -- slot, which cancelled the job. Both faults are this loop
        -- writing a material onto a slot whose item had already
        -- arrived.
        local occupied = {}
        pcall(function()
            for _, iref in ipairs(job.items) do
                local ix = iref.job_item_idx
                if ix and ix >= 0 then occupied[ix] = true end
            end
        end)

        for i = 0, #els - 1 do
            -- A fuel filter keeps its own material. It has no owner, so
            -- the positional fallback below would stamp a base reagent's
            -- material onto it, locking the fuel slot to that material
            -- on any reaction with enough reagents. Caught before access
            -- widens it, the same write would also wipe the COAL that
            -- marks it as fuel, and access would never find it.
            if occupied[i] or fuel_at[i] then goto next_filter end
            pcall(function()
                -- Each filter names its owner: reagent_index. The old
                -- loop mapped by position, which is only true when
                -- filters are one to one with reagents. Under the
                -- fold, filter 0 is the CONTAINER filter (owner
                -- reagent 1), and mapping by position stamped the
                -- tar reagent's material onto it every poll. Proven
                -- in a live dump: the ghosted container filter
                -- carried 0/-1 while the native one carried -1/-1.
                local mt, mi = -1, -1
                local ri = -1
                pcall(function() ri = els[i].reagent_index end)
                if base and ri >= 0 and ri < #base.reagents then
                    mt = base.reagents[ri].mat_type
                    mi = base.reagents[ri].mat_index
                elseif base and ri < 0 and i < #base.reagents then
                    -- No owner recorded on this build: the old
                    -- positional read, kept as the fallback.
                    mt = base.reagents[i].mat_type
                    mi = base.reagents[i].mat_index
                end
                els[i].mat_type  = mt
                els[i].mat_index = mi
            end)
            ::next_filter::
        end

        -- ---- SHRINK ONLY ----
        -- Recovery from a save made while the growth bug was live, or
        -- from the old collection build. Back to front, so surviving
        -- indices and the reagent_index each filter carries do not
        -- shift underneath the job.
        -- ---- NEVER SHRINK PAST AN OCCUPIED FILTER ----
        -- Shrinking is a recovery path, and pulling a filter out from
        -- under an item that is sitting in it is not recovery. A job
        -- reverted onto a base with fewer reagents than it has
        -- attached items reaches here holding all of them, and erasing
        -- those slots would leave every item above the cut pointing at
        -- a filter that no longer exists.
        --
        -- The occupied floor is the highest occupied slot plus one. If
        -- that is above the ceiling the job keeps its shape and says
        -- so, which is a state worth seeing rather than one to quietly
        -- force.
        --
        -- SHRINK TO THE CEILING, NEVER TO THE FOLD FLOOR. The ceiling
        -- is one filter per reagent, a shape DF posts every day and
        -- this fort completes every day. Shrinking to the fold floor
        -- would have erased a legitimate unfolded filter off any still
        -- caught before its hauler arrived, and the only reason that
        -- never fired is that DISTIL_TAR_COAL happened to be fully
        -- attached on every poll we ever looked at. The occupied guard
        -- was carrying a rule that should never have needed it.
        local floor_idx = -1
        pcall(function()
            for _, iref in ipairs(job.items) do
                local ix = iref.job_item_idx
                if ix and ix > floor_idx then floor_idx = ix end
            end
        end)
        local floor = floor_idx + 1

        -- The legal count is the reagents plus the fuel filters the job
        -- carries, so fuel alone never reads as growth.
        local target = ceiling + n_fuel
        if #els > target then
            if target < floor then
                log_once('noshrink:' .. tostring(job.id), 'WARNING', string.format(
                    'FILTER REPAIR: job %d has %d filters against %d'
                    .. ' reagent(s), but %d of them are occupied. NOT'
                    .. ' shrinking; an attached item must never lose the'
                    .. ' slot it is standing in.',
                    job.id, #els, ceiling, floor), 'FILTER')
            elseif fuel_at[#els - 1] then
                -- Growth sitting BELOW a fuel filter. Reaching it would
                -- mean erasing mid vector or erasing the fuel, and
                -- neither is this repair's to do, so it says so once.
                log_once('fuelshrink:' .. tostring(job.id), 'WARNING', string.format(
                    'FILTER REPAIR: job %d has %d filters against %d'
                    .. ' reagent(s) and %d fuel, with a fuel filter last.'
                    .. ' NOT shrinking; fuel filters are never the'
                    .. ' ghost\'s to erase.',
                    job.id, #els, ceiling, n_fuel), 'FILTER')
            else
                -- INFO: a job left grown by an earlier build, repaired. Nothing for
                -- the player to do.
                log('INFO', string.format(
                    'FILTER REPAIR: job %d had %d filters against %d'
                    .. ' reagent(s) and %d fuel. Shrinking. This job was'
                    .. ' left grown by an earlier build.',
                    job.id, #els, ceiling, n_fuel), 'FILTER')
                -- Off the end only, and never through a fuel filter.
                while #els > target and not fuel_at[#els - 1] do
                    els:erase(#els - 1)
                end
            end
        end
    end)

    local n_f, n_r = -1, -1
    pcall(function()
        n_f = #job.job_items.elements
        n_r = #ghost.reagents
    end)

    -- Reporting one number and calling it "slots" is what hid a
    -- filters-2 reagents-1 job for two rounds. The comparison is now
    -- against the BAND, because a single expected number is a
    -- prediction about DF's fold and DF does not honour it. The boil
    -- sits on the floor at 1 of 2, the still sits on the ceiling at 3
    -- of 3, and both are correct. Only a count outside the band is a
    -- shape neither the author nor DF ever asked for.
    -- Fuel filters stand outside the band: DF's own one and the
    -- surcharge copies belong to no reagent, so only the rest is the
    -- authored shape being checked.
    local n_core = n_f - n_fuel
    if n_core < fold_floor or n_core > ceiling then
        -- WARNING, once per job and shape: this runs on every poll,
        -- several times a second, for as long as the desync lasts.
        log_once('desync:' .. tostring(job.id) .. ':' .. tostring(n_f),
            'WARNING', string.format(
            'SLOT DESYNC: job %d filters=%d (%d fuel) outside'
            .. ' %d..%d (reagents=%d).',
            job.id, n_f, n_fuel, fold_floor, ceiling, n_r), 'FILTER')
    end

    return n_f, n_r, n_fuel
end

-- ==========================================
-- JIT CONFIGURATION
-- ==========================================
-- Which reactions are adaptive, and what their products mean.
--
-- DERIVED AT START from the same reactions table making_fuel.lua
-- hands the engine, never hand written. A reaction is adaptive
-- exactly when every product count in its JSON is zero, because a
-- zero count is the reaction declaring that something else fills
-- it in. Profile falls out of the FIRST product, which is the
-- primary: a coal bar is the charcoal chain, an ash bar is the ash
-- chain, a lone kindling product is the split chain. Creature
-- keying falls out of the reagents.
--
-- The secondary slot is read from its fixed position and CHECKED:
-- slot 3 of a charcoal reaction must be BAR_ASH, slot 1 of an ash
-- reaction must be BAR_COAL. A reaction missing the slot pays its
-- primary only and is named once at start; a reaction with the
-- wrong product type in the slot is a fault, named at level 0, and
-- its secondary is not paid rather than written into whatever
-- happens to sit there.
--
-- This used to be three hardcoded lists regenerated by hand, and
-- the hand missed: three JSON renames once left the leather and
-- shield reactions consuming items and paying NOTHING, with totals
-- that still looked right, and a later addition never made it into
-- the list at all. Derivation makes both failures impossible. Edit
-- the JSON and the ghost follows. Add a reaction, it is covered.
-- Delete one, it is forgotten.
--
-- STILL FIXED, and deliberately so:
--   CHAR_CINDERS, CHAR_CHAR_BOULDER, CHAR_CHAR_BLOCKS are the
--   packing ladder itself. Their fixed counts are the definition
--   of what a cinder and a char boulder are worth, and making them
--   adaptive would desync the raws from CINDERS_PER_CHARCOAL.
--   CHAR_CLOTH, CHAR_PLANT_CLOTH and CHAR_THREAD report a flat
--   volume and need getTotalDimension, which is a different read.
--   None of them declare zero counts, so none of them derive, and
--   none of them pay a secondary.
--
-- Creature keyed reactions key on race and caste rather than on
-- material, because a corpse's mat_index is the creature but its
-- mat_type is whichever tissue dominates. The same dwarf appears
-- as BONE on one corpse and SKIN on another, so keying on material
-- alone scatters one creature across several ghosts and lets two
-- creatures collide on a shared tissue. Any reaction eating a
-- corpse, corpse piece or remains gets this treatment, read
-- straight from its reagent type.
-- ==========================================
local CREATURE_REAGENTS = {
    CORPSE = true, CORPSEPIECE = true, REMAINS = true,
}

-- Every reaction key the MODULE DECLARED, adaptive or not. JIT_CONFIG
-- holds only the adaptive ones, so "no config" on its own cannot tell
-- a deliberately flat reaction from a runtime clone whose maker forgot
-- register_alias. This set is the discriminator.
--
-- AUTHORED means the key came out of the module's own reactions table.
-- A flat authored reaction paying its declared counts is the design:
-- CALCINE_GREEN_COKE is 16 breeze to 4 coke to 1 green coke and is
-- meant to be deterministic, exactly as char is. Roughly 77 of the 432
-- reactions are flat on purpose, and every one of them used to fire a
-- level 0 warning saying it pays nothing.
--
-- Rebuilt by derive_config on every data cycle alongside JIT_CONFIG,
-- so the two can never drift apart.
local AUTHORED    = {}
local JIT_CONFIG  = {}
local cached_rxns = nil

-- Where each profile keeps its secondary, and what must be declared
-- there. Slot numbers are DF's zero-based product positions; the
-- JSON table is Lua one-based, so slot 3 is prods[4].
-- The ash chain's secondary is the charcoal bar, now declared as BAR
-- carrying a PLANT_MAT token rather than the builtin BAR_COAL. Both
-- are accepted, but alt is only honoured when alt_key matches too, so
-- a plain BAR of something else is still a fault rather than being
-- paid as charcoal.
local SECONDARY_SLOT = {
    [PROFILE_CHARCOAL] = { at = 3, wants = 'BAR_ASH'  },
    [PROFILE_ASH]      = { at = 1, wants = 'BAR_COAL',
                           alt = 'BAR', alt_key = 'CHARCOAL' },
}

-- Rebuilds JIT_CONFIG from the module's reactions table. Returns
-- three lists of reaction keys so start() can name them out loud
-- instead of letting them pay nothing in silence: adaptive but
-- recognizable by no chain; recognized but with no secondary slot;
-- recognized with the wrong product in the secondary slot.
local function derive_config(rxns)
    JIT_CONFIG = {}
    AUTHORED   = {}
    local skipped, no_secondary, bad_layout = {}, {}, {}
    for _, r in ipairs(rxns or {}) do
        -- Recorded BEFORE the adaptive test, because the flat ones are
        -- the whole reason this set exists. Same key shape JIT_CONFIG
        -- uses below, so a lookup that finds one finds the other.
        AUTHORED[MODULE_PREFIX .. tostring(r.key)] = true

        local prods = r.products or {}
        local adaptive = #prods > 0
        for _, p in ipairs(prods) do
            if (p.count or 1) ~= 0 then adaptive = false end
        end
        -- WATCHER OWNED IS NOT ADAPTIVE. A zero COUNT means the engine
        -- fills the count in. A zero PROBABILITY means nothing is ever
        -- minted at all: a watcher does the whole job, and the product
        -- exists only because refinish-module-validate.lua:675 refuses
        -- an empty products array.
        --
        -- Checked against the module: every product at probability 0
        -- matches exactly COMBINE_PARTIAL_SKIN, PROCESS_SKIN and
        -- FILL_TANK, the same three start() used to name as adaptive
        -- but recognizable by no chain, paying nothing. They were never
        -- meant to be paid. They stay AUTHORED, recorded above, so they
        -- read as deliberately flat rather than as faults.
        if adaptive then
            local silent = true
            for _, p in ipairs(prods) do
                if (p.probability or 100) ~= 0 then silent = false end
            end
            if silent then adaptive = false end
        end
        if adaptive then
            local first = prods[1] or {}
            local creature = false
            for _, a in ipairs(r.reagents or {}) do
                if CREATURE_REAGENTS[a.type] then creature = true end
            end

            -- ---- PROFILE FROM THE PRIMARY ----
            -- A coal bar is declared two ways and both are this same
            -- chain. BAR_COAL is DF's builtin, which the coal watcher
            -- then has to replace; BAR carrying a PLANT_MAT token
            -- mints the module's own coal directly and skips that
            -- swap. So the TYPE no longer separates the chains and the
            -- MATERIAL KEY does, read through each_key, which already
            -- handles mat_id and the last mat_token segment.
            --
            -- A plain BAR of anything else still falls through to no
            -- profile, so this cannot quietly adopt an unrelated bar.
            local profile   = nil
            local first_key = each_key(first)
            if first.type == 'BAR_COAL' or first.type == 'BAR' then
                if first_key == 'COKE' then
                    profile = PROFILE_COKE
                elseif first_key == 'CHARCOAL'
                    or first.type == 'BAR_COAL' then
                    profile = PROFILE_CHARCOAL
                end
            elseif first.type == 'BAR_ASH' then
                profile = PROFILE_ASH
            elseif #prods == 1
               and first.subtype == 'MAKING_FUEL_KINDLING' then
                profile = PROFILE_KINDLING
            end
            -- ---- DRAIN, RECOGNISED BY SHAPE ----
            -- Every reagent preserved, meaning nothing is consumed,
            -- and every product a container bound liquid. No other
            -- reaction in the module looks like that, so it needs no
            -- naming convention and cannot be triggered by accident.
            --
            -- The slots are kept as an ORDERED LIST rather than the
            -- currency keyed map the retorts use, because a drain's
            -- currencies are not known until the banks are read.
            -- ---- DRAIN, RECOGNISED BY ITS PRODUCTS ----
            -- Every product a container bound liquid. Checked against
            -- all 429 reactions in the module: RETORT_DRAIN is the only
            -- one, so the products alone are enough.
            --
            -- The earlier version also required every reagent to be
            -- preserved. That has to go, because the drain key is now
            -- CONSUMED by the job rather than returned. Consuming it is
            -- what makes the reaction settle at all: the key enters the
            -- ordinary ledger, vanishes on completion, and settle sees
            -- it go. No witness, no special case.
            if not profile then
                local all_liquid = (#prods > 0)
                for _, p in ipairs(prods) do
                    if p.type ~= 'LIQUID_MISC_INORGANIC'
                       or not p.to_container then
                        all_liquid = false
                    end
                end
                if all_liquid then profile = PROFILE_DRAIN end
            end

            local cfg_pitch_slot = nil
            if not profile then
                -- FRACTIONATION. Any adaptive reaction with a
                -- product that derives through PITCH_MAT is the
                -- pitch chain, wherever that product sits and
                -- whatever rides beside it: the residue banks by
                -- side, every other product pays once per cycle.
                -- The get_material block stays DF's derivation
                -- instruction AND the signature.
                for i, p in ipairs(prods) do
                    if p.type == 'BOULDER'
                       and (p.get_material_product or {}).product_code
                           == 'PITCH_MAT' then
                        profile = PROFILE_PITCH
                        cfg_pitch_slot = i - 1
                        break
                    end
                end
            end

            if not profile then
                table.insert(skipped, tostring(r.key))
            else
                local cfg = { profile = profile, is_creature = creature }
                if profile == PROFILE_PITCH then
                    cfg.pitch_slot = cfg_pitch_slot
                    -- ---- FRACTIONS BANK, THEY DO NOT PAY FLAT ----
                    -- Every non residue slot used to pay exactly one
                    -- per cycle, which made a still a liquid printer:
                    -- one package of coal tar came out as three
                    -- fractions plus a third of a pitch, 3.33 from
                    -- 1.00. A still separates a liquid. It cannot
                    -- make more of it.
                    --
                    -- A slot listed in FRACTION_SPLIT now credits its
                    -- real share of what walked in and banks the rest,
                    -- so the reaction conserves. A slot with no entry
                    -- keeps the old flat behaviour, so an unlisted
                    -- reaction is wrong rather than dead.
                    local split = (T.FRACTION_SPLIT or {})[r.key] or {}
                    cfg.each      = {}
                    cfg.fractions = {}
                    for i, p in ipairs(prods) do
                        if i - 1 ~= cfg.pitch_slot then
                            local key   = each_key(p)
                            local share = split[key]
                            local nm    = string.lower(each_name(p))
                                :gsub('_', ' ')
                            if share then
                                table.insert(cfg.fractions, {
                                    at       = i - 1,
                                    currency = key,
                                    share    = share,
                                    name     = nm,
                                    kind     = (p.type ==
                                        'LIQUID_MISC_INORGANIC')
                                        and 'liquid' or 'units',
                                })
                            else
                                table.insert(cfg.each,
                                    { at = i - 1, name = nm })
                            end
                        end
                    end
                end

                -- ---- DRAIN SLOTS, IN ORDER ----
                -- Position matters here and the currency does not, so
                -- this is a list. The fullest bank goes in the first
                -- slot, the next in the second, and so on.
                if profile == PROFILE_DRAIN then
                    cfg.drain_slots = {}
                    for i, p in ipairs(prods) do
                        if p.type == 'LIQUID_MISC_INORGANIC' then
                            table.insert(cfg.drain_slots, i - 1)
                        end
                    end
                end

                -- ---- LIQUID SLOTS ----
                -- Any zero-count liquid product makes this a retort.
                -- Keyed by the material WITHOUT the module prefix,
                -- which is how FLUID_SPLIT names them.
                for i, p in ipairs(prods) do
                    if p.type == 'LIQUID_MISC_INORGANIC'
                       and (p.count or 1) == 0 and p.mat_id then
                        local cur = bare(p.mat_id)
                        cfg.liquid_slots = cfg.liquid_slots or {}
                        cfg.liquid_slots[cur] = i - 1
                    end
                end

                -- ---- COKE: THE FIXED SLOTS ----
                -- Slots 0, 1 and 2 are the ladder, and the liquid
                -- slots pay off their own banks. Anything else on a
                -- coke reaction is a byproduct of a REAGENT rather
                -- than of the coal, the gypsum and brimstone off the
                -- fluxed pair being the whole reason this exists, so
                -- it pays one per cycle and touches no bank. Same
                -- shape PROFILE_PITCH uses for its byproducts.
                --
                -- NOT OPTIONAL. A reaction only becomes adaptive
                -- here if EVERY product is count 0, so a slot with no
                -- spec behind it would sit at zero and mint nothing
                -- for the rest of the fort's life.
                if profile == PROFILE_COKE then
                    cfg.each = {}
                    for i, p in ipairs(prods) do
                        local at = i - 1
                        local liquid = false
                        for _, la in pairs(cfg.liquid_slots or {}) do
                            if la == at then liquid = true end
                        end
                        if at > 2 and not liquid then
                            -- ---- COAL ASH IS NOT A REAGENT BYPRODUCT ----
                            -- Gypsum and brimstone come off the FLUX,
                            -- one per cycle, stoichiometric, no bank.
                            -- Coal ash comes off the COAL, scales with
                            -- it, and banks like every other measured
                            -- output. Matched on the material key so a
                            -- future ash slot inherits this for free.
                            local tok = tostring(p.mat_token or '')
                            if tok:match(':ASH_COAL$') then
                                cfg.ash_coal_at = at
                            else
                                local nm = each_name(p)
                                table.insert(cfg.each,
                                    { at = at, name = string.lower(nm) })
                            end
                        end
                    end
                end

                -- ---- SECONDARY SLOT, CHECKED ----
                local slot = SECONDARY_SLOT[profile]
                if slot then
                    local declared = prods[slot.at + 1]
                    if not declared then
                        table.insert(no_secondary, tostring(r.key))
                    elseif declared.type == slot.wants
                        or (slot.alt
                            and declared.type == slot.alt
                            and each_key(declared) == slot.alt_key) then
                        cfg.secondary_at = slot.at
                    else
                        -- Names the MATERIAL as well as the type. A
                        -- bare "slot 1 is BAR" does not say which bar,
                        -- and which bar is the whole question once
                        -- coal can be declared as a plain BAR.
                        local dk = each_key(declared)
                        table.insert(bad_layout, string.format(
                            '%s (slot %d is %s%s, wanted %s)',
                            tostring(r.key), slot.at,
                            tostring(declared.type),
                            dk ~= '' and (' of ' .. dk) or '',
                            slot.wants))
                    end
                end

                JIT_CONFIG[MODULE_PREFIX .. r.key] = cfg
            end
        end
    end
    return skipped, no_secondary, bad_layout
end

local ghost_cache     = {}
local last_ram_loaded = nil

-- ==========================================
-- COMPLETION AUDIT
-- ==========================================
-- [job.id] = snapshot of the last poll that saw this job holding
-- items. When a job id stops being refreshed, that cycle is over and
-- this holds the state it had.
--
-- It is also where the bank is settled, because this is the only point
-- at which we know whether the job burned or died.
--
--   worked  true if job.flags.working was EVER observed set during
--           this cycle. A completed job always sets it; a cancelled
--           job never does. This is the burn test.
--   ids     item ids, checked as a second opinion.
--   paid    value the written products represent.
-- ==========================================
local audit_state = {}
local audit_tick  = 0

-- Job ids seen in world.jobs.list on the current poll. A snapshot can
-- only be called cancelled if its job is NOT here: a job that is still
-- in the list is still running, however long it takes. Without this
-- the sweep declared NOT CONSUMED on live jobs that simply went two
-- ticks without a refresh, then logged BURNED ten seconds later.
local live_jobs = {}

-- Forward declaration. handle_ghosted settles the previous cycle, and
-- settle is defined after it because it reads the bank and the log
-- helpers that sit between them.
local settle

-- ==========================================
-- READ THE INPUT MATERIAL
-- ==========================================
-- Identifies what walked in, which decides which ghost this job gets.
--
-- One branch, not four. Every reaction in this file resolves through
-- matinfo.decode, which reads the item's material FIELDS rather than
-- calling getMaterial, and those fields are populated even on corpses
-- where the accessor returns -1.
-- ==========================================
local function read_input_material(job)
    for _, iref in ipairs(job.items) do
        local item = iref.item
        if item then
            local mat_type, mat_index = -1, -1
            local nice_name = ''
            pcall(function()
                local mi = dfhack.matinfo.decode(item)
                if mi then
                    mat_type  = mi.type
                    mat_index = mi.index
                end
            end)
            pcall(function()
                nice_name = dfhack.items.getDescription(item, 0)
            end)
            if nice_name == '' then nice_name = 'item' end
            return mat_type, mat_index, nice_name
        end
    end
    return nil, nil, nil
end

-- ==========================================
-- GHOST COMPILER
-- ==========================================
-- Deep copies the base reaction into a new reaction owned by one job,
-- so that job's product counts can be rewritten without touching any
-- other job running the same reaction.
--
-- Ghosts accumulate in the reactions array for the session and carry
-- the module prefix so the shutdown sweep collects them.
-- ==========================================
local function build_ghost_jit(base_code, ghost_code, mat_type, mat_index)
    local base_rxn = nil
    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        if rxn.code == base_code then base_rxn = rxn break end
    end
    if not base_rxn then return false end

    local reactions_array = df.global.world.raws.reactions.reactions
    local rxn = df.reaction:new()
    rxn:assign(base_rxn)
    rxn.code = ghost_code

    -- The base reaction's name is kept. Renaming would be right if the
    -- input were chosen, but every reaction here takes whatever turns
    -- up, and naming a job after the first thing through the door is a
    -- label that stops being true on the next cycle.

    -- Keep the ghost out of the workshop UI menus.
    rxn.building.type:resize(0)
    rxn.building.subtype:resize(0)
    rxn.building.custom:resize(0)

    -- Deep copy reagents and products. assign() on the reaction copies
    -- these vectors BY REFERENCE, so without this the ghost and the
    -- base share them and every product write would reach the base
    -- reaction and every other job running it.
    rxn.reagents:resize(0)
    for _, old_r in ipairs(base_rxn.reagents) do
        local r_new = old_r._type:new()
        r_new:assign(old_r)
        rxn.reagents:insert('#', r_new)
    end
    rxn.products:resize(0)
    for _, old_p in ipairs(base_rxn.products) do
        local p_new = old_p._type:new()
        p_new:assign(old_p)
        rxn.products:insert('#', p_new)
    end

    -- Lock the material into the clone's reagent, which drives
    -- completion. Filters are unlocked again in normalize_slots,
    -- because filters drive collection.
    if rxn.reagents[0] then
        rxn.reagents[0].mat_type  = mat_type
        rxn.reagents[0].mat_index = mat_index
    end

    -- Reagent COUNT is left exactly as the base reaction declares it.
    -- Nothing decides how much a job consumes any more: one item per
    -- job, fraction banked between jobs.

    rxn.index = #reactions_array
    reactions_array:insert('#', rxn)
    ghost_cache[ghost_code] = rxn

    pcall(function() rxn.flags.FORTRESS_MODE_ENABLED = true end)
    log('DETAIL', 'JIT Compiled: ' .. ghost_code .. ' (' .. tostring(rxn.name) .. ')', 'JIT')
    return true
end

-- ==========================================
-- PER JOB HANDLING
-- ==========================================
-- Runs on every poll that sees a ghosted job holding at least one
-- item, and once more immediately after a swap so a job that finishes
-- inside the ten frame poll gap still gets correct products.
--
-- Products are written BEFORE slots are normalised, so if normalising
-- is what lets the job complete, the counts it completes on are
-- already right.
-- ==========================================
local function handle_ghosted(job, base_code)
    local ghost = ghost_cache[tostring(job.reaction_name)]
    if not ghost then return end
    if #job.items < 1 then return end

    -- BEFORE anything reads a reagent. Everything below indexes
    -- ghost.reagents by a filter's reagent_index, so a ghost that
    -- cannot describe the job has to be made able to first. Cheap and
    -- idempotent: on a job whose shapes already agree it is one length
    -- comparison and a return.
    reconcile_reagents(job, ghost)

    -- The poll only sends jobs whose base has a config, so the
    -- fallback is belt and braces: plain charcoal, no secondary.
    local cfg     = JIT_CONFIG[base_code]
                    or { profile = PROFILE_CHARCOAL, is_creature = false }
    local profile = cfg.profile

    -- ---- A STACK BURNS WHOLE ----
    -- THE RULE: if a feed item holds several units, the job takes all
    -- of them in one run. Nobody sits through forty runs for one
    -- output, and a player only has to learn one behaviour: whole
    -- stacks burn and the output matches the arithmetic.
    --
    -- DF consumes the reagent's QUANTITY per completion, so a
    -- quantity of 1 against a stack of fourteen took fourteen runs.
    -- Raising the quantity to the stack's own count collapses that to
    -- one run, and on a corpsepiece it fixes three separate faults at
    -- the same time:
    --
    --   The valuation credits the WHOLE pile every run, because the
    --   stack fraction reads stack_size and a corpsepiece pins that
    --   at 1, so it never divides. Measured at 8.7x over five runs.
    --   The pile SURVIVES each completion, so settle's burn test,
    --   which asks whether the item vanished, its stack shrank or its
    --   dimension dropped, answers no to all three and reads NOT
    --   CONSUMED.
    --   NOT CONSUMED never debits, so a payout that fired was free.
    --   Measured at six free jugs of bone oil off one buffalo.
    --
    -- Consuming the pile whole makes the item VANISH, which settle
    -- already detects, and makes crediting the whole pile correct,
    -- because the whole pile really did burn. Proven in game on a 14
    -- bone water buffalo stack: item gone, ledger BURNED, every bank
    -- carried, all eight figures reconciled to six decimals.
    --
    -- WHERE THE COUNT LIVES, and it is not one field:
    --   CORPSEPIECE  material_amount. stack_size is pinned at 1, so
    --                reading it sees a pile of fourteen as a single
    --                bone. This is the case that hid the bug.
    --   everything   stack_size, the ordinary count. Plants, meat,
    --   else         fish and cheese all work this way.
    --
    -- NOT COVERED, deliberately: items that carry their amount in
    -- DIMENSION rather than a count, meaning thread and cloth. They
    -- read stack_size 1, so the guard below skips them and they keep
    -- their existing behaviour. Whether a dimensioned item can be
    -- consumed whole the same way is UNMEASURED, and it is not being
    -- guessed at here.
    --
    -- BOTH SIDES, TOGETHER. The reagent drives completion and the
    -- job_item filter drives collection. RM_Adaptive_Reactions
    -- records raising a reagent alone as a confirmed deadlock, which
    -- is why both move together. That case was also a different
    -- shape: it gathered several SEPARATE items and the dwarf could
    -- not haul enough. One stack is one item already in hand, so
    -- there is nothing further to fetch.
    --
    -- SCOPE:
    --   Stacks of 2 or more only, so a single skull, limb or plant
    --   keeps whatever its reaction asked for. CHAR_SKULL and
    --   ASH_SKULL ask for ten single skulls by design and are
    --   untouched.
    --   Feed slots only. Preserved vessels are skipped explicitly;
    --   they also read 1 and would be skipped anyway, but relying on
    --   that would be an accident rather than a rule.
    --   Inside handle_ghosted, which runs for adaptive jobs only. A
    --   static reaction pays a fixed output, so consuming more would
    --   be pure loss. BOIL_BONE_GLUE is static, never ghosted, and
    --   never reaches this.
    --
    -- Re-read every poll rather than set once, because a repeat job
    -- keeps its id across cycles and the next stack is a different
    -- size. Setting it at swap would demand fourteen from a stack of
    -- six.
    --
    -- KNOWN BOUND: a stack large and dense enough to earn more than
    -- one package of a liquid banks the surplus, because a reaction
    -- declares one output container per liquid slot. Measured: every
    -- bone stack up to a cow fits in one jug, a water buffalo earns
    -- 1.14 and drains the remainder on the next carcass, and only
    -- elephants, dragons and large dense plant stacks exceed that.
    -- Multi vessel output is the fix for those and is separate work.
    pcall(function()
        -- How many feed items are sitting in each reagent slot. A slot
        -- the stack rule raises should hold exactly ONE item, because
        -- the whole point is that one stack covers the demand. Two
        -- means DF was told to fetch more than it needed and the
        -- surplus will not be consumed.
        --
        -- Counted rather than assumed, and only reported for a slot
        -- the rule actually touches: a reagent that legitimately
        -- declares several items, dung at quantity 8, holds eight and
        -- is none of this rule's business.
        local per_slot, done_slot = {}, {}
        for _, iref in ipairs(job.items) do
            if not slot_preserved(job, ghost, iref) then
                local ix = iref.job_item_idx
                if ix and ix >= 0 then
                    local ri = job.job_items.elements[ix].reagent_index
                    per_slot[ri] = (per_slot[ri] or 0) + 1
                end
            end
        end

        for _, iref in ipairs(job.items) do
            local it = iref.item
            if slot_preserved(job, ghost, iref) then goto next_q end
            local idx = iref.job_item_idx
            if not idx or idx < 0 then goto next_q end

            -- How many units this one item holds.
            local n = 1
            if it:getType() == df.item_type.CORPSEPIECE then
                n = 0
                local ma = it.material_amount
                for i = 0, #ma - 1 do
                    if ma[i] > n then n = ma[i] end
                end
            else
                -- ---- A DIMENSIONED FEED BURNS WHOLE TOO ----
                -- THE RULE IS THE SAME ONE: whatever the dwarf is
                -- holding, burn all of it. Nobody scoops a spoonful
                -- out of a glob forty times.
                --
                -- Thread, cloth and globs carry their amount in
                -- DIMENSION, not in stack_size, so `n` has to be read
                -- from the field that actually holds it. Writing a
                -- stack count into a dimension quantity is nonsense:
                -- RETORT_GLOB asks for 150, which is ONE glob by the
                -- vanilla convention, and a glob reading stack_size 2
                -- would have rewritten that 150 into 2 and collapsed
                -- the demand to almost nothing.
                --
                -- THIS ALSO CLOSES AN OVER CREDIT, which is the real
                -- reason it is worth doing rather than just skipping
                -- these items. The stack fraction below divides by
                -- stack_size, and a dimensioned item pins that at 1,
                -- so frac is 1 and the valuation credits the WHOLE
                -- item. getVolume scales with the amount held. So a
                -- 300 dimension glob was being priced at 300 while
                -- the reaction consumed 150. Same shape as the
                -- corpsepiece fault, which was measured at 8.7x.
                -- Consuming the whole makes credit and consumption
                -- agree instead of papering over the gap.
                --
                -- Settle already copes: untouched() watches dimension
                -- as well as stack, so a drained glob reads BURNED.
                --
                -- pcall because reading .dimension on an item without
                -- the field raises, and a failed read means this is an
                -- ordinary counted item.
                -- MEASURED, water buffalo fat, job 15: the item read
                -- "[9]", getVolume 540, and one run took it to "[8]"
                -- with getVolume 480. Sixty volume per unit, and the
                -- reagent asked for 150 and got exactly one unit.
                --
                -- So a glob is BOTH: stack_size holds how many, and
                -- dimension holds how big each one is. Reading only
                -- dimension gave 150, which already equalled what the
                -- reaction asked for, so the guard wrote nothing and
                -- the stack burned one unit per run. That was my
                -- error in the previous round.
                --
                -- The total the dwarf is holding is stack times
                -- dimension, and the quantity DF consumes is counted
                -- in dimension units, which is why 150 removed one
                -- unit of nine. So 9 x 150 asks for the whole pile.
                --
                -- Thread and cloth fall out of the same arithmetic: a
                -- single item at stack 1 gives 1 x 15000, which is
                -- what those reactions already ask for, so nothing
                -- changes for them unless a stacked one turns up.
                --
                -- pcall because reading .dimension on an item without
                -- the field raises, and a failed read means this is an
                -- ordinary counted item like meat or bone.
                local sz, dim = 1, nil
                pcall(function() sz = it.stack_size or 1 end)
                pcall(function() dim = it.dimension end)
                if dim and dim > 0 then
                    n = sz * dim
                    -- ---- SAY IT EVERY TIME, NOT ONLY ON A CHANGE ----
                    -- The log below only speaks when the quantity
                    -- actually moves, which is exactly why the fat
                    -- defect was invisible: it read 150, matched, and
                    -- said nothing. This territory is unexplored, so
                    -- every dimensioned item reports what it is made
                    -- of whether or not anything is done about it.
                    log_once('dimfeed:' .. job.id .. ':' .. it.id, 'DETAIL', string.format(
                            'STACK: #%d is a dimensioned feed, stack %d'
                            .. ' at dimension %d, so %d unit(s) held in'
                            .. ' total.', it.id, sz, dim, n), 'STACK')
                else
                    n = sz
                end
            end
            if n < 2 then goto next_q end

            local ri = job.job_items.elements[idx].reagent_index

            -- ---- ONE SLOT, ONE QUANTITY ----
            -- The first item in a slot decides it. Two items meant
            -- each visit rewrote the reagent to its own size, so the
            -- quantity flipped between them forever while the rot
            -- watcher pushed it back from the other side. MEASURED on
            -- job 25: a [20] and a [5] in one slot logged that pair
            -- over a hundred times in a single run.
            --
            -- The first item is the one that was actually sought, so
            -- it is the one to believe.
            if done_slot[ri] then goto next_q end
            done_slot[ri] = true

            -- Reported here rather than after the write, so it is said
            -- whether or not the quantity happens to change.
            if (per_slot[ri] or 1) > 1 then
                log_once('overfetch:' .. job.id .. ':' .. tostring(ri), 'WARNING', string.format(
                        'STACK: job %d has %d items in reagent slot %d,'
                        .. ' which takes whole stacks and needs one.'
                        .. ' The surplus will not be consumed.',
                        job.id, per_slot[ri], ri), 'STACK')
            end

            if ghost.reagents[ri].quantity ~= n then
                ghost.reagents[ri].quantity = n

                -- ---- THE JOB ITEM QUANTITY IS NOT WRITTEN ----
                -- It used to be set to n alongside the reagent, and
                -- that is what made a burn fetch a SECOND stack it
                -- then never consumed.
                --
                -- The two fields do different jobs, and this file
                -- already measured which: "consumption per completion
                -- is the RAWS reagent quantity (measured: one unit per
                -- cycle even with the job item zeroed) ... the job
                -- item quantity only governs SEEKING." So raising the
                -- reagent is what burns the whole stack, and raising
                -- the job item only tells DF to go and get more.
                --
                -- It does not even count what is already there. An
                -- attached stack in transit contributes nothing toward
                -- the demand, so a stack of five raised the demand to
                -- five, counted the stack as zero, and sent a dwarf
                -- for another five. On completion the reagent took its
                -- five out of the first stack and the second was left
                -- attached and untouched.
                --
                -- ON THE ROT REACTION IT IS WORSE. The rot watcher
                -- seals the filter to the chosen item's exact type and
                -- material and then zeroes this same field for exactly
                -- this reason (making-fuel-rot-watcher.lua:482). This
                -- write landed afterwards and undid it, so the demand
                -- came back on a filter that now reads "meat of that
                -- material" and DF happily fetched FRESH meat to fill
                -- it.
                --
                -- Left alone rather than zeroed. Zeroing is right when
                -- the filter is already satisfied, which is the rot
                -- watcher's situation, but a declared multi item
                -- reagent like dung at quantity 8 may still be
                -- collecting, and zeroing would strand it half filled.
                log('DETAIL', string.format(
                    'STACK: job %d takes all %d of #%d in one run',
                    job.id, n, it.id), 'STACK')
            end
            ::next_q::
        end
    end)

    -- ---- CURRENT ITEM IDENTITY ----
    -- A repeat job keeps its id forever, so the id alone cannot say
    -- whether this is the same run continuing or a fresh one that has
    -- already replaced the last. The item ids can.
    -- Stack size is recorded alongside the id because DF does not
    -- always destroy a consumed reagent. CHAR_PLANT takes 15 from a
    -- stack of 20 amaranths and leaves 5, so the item survives with a
    -- smaller stack. Testing existence alone reads that as "nothing
    -- was consumed" and the bank never gets credited for value that
    -- was very much burned.
    local ids, stacks, dims, contents = {}, {}, {}, {}

    -- ---- DRAIN WITNESS ----
    -- A drain consumes nothing, so the ordinary ledger stays empty and
    -- untouched() can never return false: the cycle would pay out and
    -- never settle, which is R2, a free payout, at scale.
    --
    -- But a vessel goes in EMPTY and comes out FULL, and that is just
    -- as observable as a feed vanishing. So the vessels themselves are
    -- the witness here, recorded with the number of items inside them.
    -- Same idea as the boil's pitch witness: a profile is allowed its
    -- own way of filling the ledger, as long as it puts in something
    -- DF will actually change.
    --
    -- This is the ONLY place preserved slots enter the ledger, and it
    -- is gated on the profile so nothing else inherits it.
    if cfg.profile == PROFILE_DRAIN then
        pcall(function()
            for _, iref in ipairs(job.items) do
                local iid = iref.item.id
                table.insert(ids, iid)
                contents[iid] =
                    #(dfhack.items.getContainedItems(iref.item) or {})
            end
        end)
    end

    pcall(function()
        for _, iref in ipairs(job.items) do
            -- Preserved slots are contractually returned. Their
            -- survival is the design, not evidence that nothing
            -- burned, so they never enter the consumption ledger.
            -- Char never had a preserved slot, which is why this
            -- rule could sleep until the boil: its ONLY attached
            -- item is the preserved jug, and a ledger holding just
            -- the jug reads every burned tar as NOT CONSUMED.
            if not slot_preserved(job, ghost, iref) then
                local iid = iref.item.id
                table.insert(ids, iid)
                local sz = 1
                pcall(function() sz = iref.item.stack_size or 1 end)
                stacks[iid] = sz
                -- Liquids are consumed by DIMENSION, the way stacks
                -- are consumed by count. Record it where it exists
                -- so untouched() can see a drained jugful.
                pcall(function()
                    if iref.item.dimension then
                        dims[iid] = iref.item.dimension
                    end
                end)
            end
        end
    end)
    local id_key = table.concat(ids, ',')

    -- Did every item the snapshot recorded survive intact? An item
    -- that vanished, or one whose stack shrank, was consumed.
    local function untouched(s)
        if not s or not s.ids then return true end
        for _, iid in ipairs(s.ids) do
            local it = nil
            pcall(function() it = df.item.find(iid) end)
            if not it then return false end
            local sz = 1
            pcall(function() sz = it.stack_size or 1 end)
            if sz < ((s.stacks or {})[iid] or sz) then return false end
            -- The liquid twin of the stack rule above: a drained
            -- dimension is a consume, and so is an item DF has
            -- already flagged for cleanup but not yet removed.
            local dm = nil
            pcall(function() dm = it.dimension end)
            if dm and dm < ((s.dims or {})[iid] or dm) then
                return false
            end
            -- ---- A FILLED CONTAINER IS A FIRED CYCLE ----
            -- The drain's witness. Recorded only for PROFILE_DRAIN, so
            -- for every other reaction s.contents is empty and this
            -- test can never fire. A vessel that gained an item was
            -- poured into, and that is the cycle completing.
            local cn = nil
            pcall(function()
                cn = #(dfhack.items.getContainedItems(it) or {})
            end)
            local was = (s.contents or {})[iid]
            if cn and was and cn > was then return false end

            local gc = false
            pcall(function() gc = it.flags.garbage_collect end)
            if gc then return false end
        end
        return true
    end

    local prev = audit_state[job.id]

    -- ---- SETTLE THE PREVIOUS CYCLE FIRST ----
    -- ORDER IS LOAD BEARING. This ran AFTER the valuation below, which
    -- meant the products were computed from a bank that had not yet
    -- been credited for the item the last cycle burned. The figure was
    -- permanently one item behind, and a job that completed before the
    -- next poll wrote its products from that stale number. The payout
    -- threshold was reached a cycle late and the value was already
    -- spent by then, so a bank that was filling correctly still
    -- produced nothing.
    -- ---- HAS THE PREVIOUS CYCLE ACTUALLY ENDED ----
    -- An id change alone does NOT mean a new cycle. A reagent with
    -- quantity above 1 gathers its items one at a time, so the id set
    -- changes on every arrival. Settling on that reported NOT CONSUMED
    -- once per item and buried the real ledger: bark logged it at one,
    -- two and three items before finally burning at four.
    --
    -- Growth is the old ids still being present. A genuinely new cycle
    -- means at least one of them is gone or reduced.
    local settled_now = false
    -- Same item id, smaller stack, is a completed cycle too. The old
    -- id-change test never fired while a job re-fed the same stack,
    -- so twenty one-unit burns settled once, at the end.
    if prev and prev.id_key and not untouched(prev) then
        settle(job.id, prev, true)
        audit_state[job.id] = nil
        prev = nil
        settled_now = true
    end

    local streams, detail, inert, out, haul, pitch_witness =
        apply_banked_yield(job, ghost, base_code, cfg)
    -- Deposit the witness where the verdict actually looks. These
    -- tables live HERE, in handle_ghosted; the valuation loop that
    -- finds the tar lives in apply_banked_yield and cannot reach
    -- them, which is precisely how three rounds of witness code ran
    -- without a single id arriving.
    for _, w in ipairs(pitch_witness or {}) do
        table.insert(ids, w.id)
        stacks[w.id] = w.stack
        -- ---- THE BASELINE IS TAKEN ONCE, AT COLLECTION ----
        -- dims is rebuilt from scratch on every poll, so writing w.dim
        -- outright replaces the opening reading with the current one
        -- and settle ends up comparing a value against itself.
        --
        -- prev is nil on the first poll of a cycle, because settling
        -- clears it, so that poll records the dimension as collected.
        -- Every later poll in the same cycle carries that value
        -- forward untouched. One snapshot per cycle, compared against
        -- what is left when the cycle closes.
        if w.dim then
            local opened = prev and prev.dims and prev.dims[w.id]
            dims[w.id] = opened or w.dim
        end
    end

    -- ---- INERT REFUSAL ----
    -- A wood furnace cannot consume something that does not burn, so
    -- the item must come back out. Suspending is the only way to
    -- release it without a livelock: preserving the reagent and
    -- producing nothing also releases it, but then the repeat job
    -- re-posts and picks the same stone chair again forever.
    --
    -- This should be unreachable. The reagent's material gate stops DF
    -- selecting an inert item in the first place. A suspended job here
    -- means a reagent is missing its flag, which is a bug report, not
    -- a gameplay path.
    -- ---- ONCE PER JOB, NOT ONCE PER POLL ----
    -- A refusal is a terminal verdict. Re-asserting it six times a
    -- second means writing to a job's flags and re-reading its item
    -- list while DF is releasing those items, and that is what turned
    -- one malformed job into a crash: sixteen seconds of this at the
    -- end of the log, then a CTD in "Advancing unit moves".
    --
    -- The suspend write is skipped once the job already carries it, so
    -- nothing touches a job DF has already parked, and the report is
    -- keyed on the job so it is said exactly once.
    if inert then
        if T.INERT_SUSPENDS_JOB then
            local already = false
            pcall(function() already = job.flags.suspend == true end)
            if not already then
                pcall(function() job.flags.suspend = true end)
            end
            log_once('inert:' .. tostring(job.id), 'WARNING', string.format(
                'INERT REFUSED: job %d holds %s, which does not burn.'
                .. ' Job SUSPENDED and the item released.',
                job.id, tostring(inert)), 'INERT')
            log_once('inertwhy:' .. tostring(job.id), 'WARNING', '  The reagent on ' .. tostring(base_code)
                .. ' is missing a material gate. Nothing was consumed.', 'INERT')
        end
        return
    end

    if not streams then return end

        -- Once per cycle, not once per poll. Only the first poll of a
    -- cycle, or one that just settled the previous cycle, has anything
    -- new to say; the other five per second repeat it verbatim.
    local n_f, n_r, n_fuel = repair_filters(job, ghost, base_code)
    -- The early returns hand back two values, so fuel reads as none.
    n_fuel = n_fuel or 0
    if settled_now or not prev then
        -- One line per currency, so a char job shows its charcoal
        -- and its ash filling side by side.
        for _, st in ipairs(streams) do
            log('DETAIL', string.format(
                '    . job %d  %s  %d item(s)  %s bank %.6f + %.6f'
                .. ' = %.6f  [filters %d (%d fuel) reagents %d]',
                job.id, profile, #job.items, string.lower(st.currency),
                st.bank_in, st.haul, st.sum, n_f, n_fuel, n_r), 'AUDIT')
        end
    end

    -- ---- BURN TEST ----
    -- job.flags.working is the only reliable difference between a job
    -- that completed and one that was cancelled. A completing job
    -- holds it for its whole run, roughly twelve seconds at the
    -- observed rate; a cancelled job never sets it at all.
    --
    -- Sticky for the cycle, because the poll that catches the job may
    -- not be the poll on which it finishes. It resets naturally: the
    -- audit sweep deletes the snapshot when the cycle ends and the
    -- next cycle builds a fresh one.
    local wk = false
    pcall(function() wk = job.flags.working end)
        local worked = wk or (prev and prev.worked) or false

    if prev and not prev.worked and worked then
        log('DETAIL', string.format('PHASE: job %d working (attached=%d filters=%d,'
            .. ' %d fuel)', job.id, #job.items, n_f, n_fuel), 'PHASE')
    end

    local snap = {
        code = tostring(job.reaction_name), base = base_code,
        profile = profile, items = {},
        -- One entry per currency this job pays: what the bank held,
        -- what this job added, the total the slots were written
        -- from, and what those slots cost. settle() carries the
        -- difference into each bank.
        streams = streams, out = out, haul = haul,
        id_key = id_key, ids = ids, stacks = stacks, dims = dims,
        contents = contents,
        detail = detail, worked = worked, seen = audit_tick,
    }
    pcall(function()
        for _, iref in ipairs(job.items) do
            local d = '?'
            pcall(function() d = dfhack.items.getDescription(iref.item, 0) end)
            table.insert(snap.items, tostring(d))
        end
    end)
    -- The header's contract, enforced on EVIDENCE, not attachment:
    -- audit_state must hold the last snap that carries witness ids.
    -- The first cut guarded on #job.items, and retort char walked
    -- straight through it: the log dies mid job while the preserved
    -- vessels stay attached, so later polls held items but zero
    -- evidence, overwrote the snap, and every liquid credit was
    -- discarded as NOT CONSUMED. A snap WITH ids may always land; a
    -- snap without them lands only when nothing better exists.
    local prior = audit_state[job.id]
    local prior_ev = prior and prior.ids and #prior.ids > 0
    if #ids > 0 or not prior_ev then
        audit_state[job.id] = snap
    end
end

-- ==========================================
-- SWAP A FRESH JOB TO ITS GHOST
-- ==========================================
local function swap_to_ghost(job, rname, config)
    local mat_type, mat_index = read_input_material(job)
    -- PITCH: the attached item is the preserved jug; the feedstock
    -- is the liquid INSIDE it. Sampling the jug once locked a clone
    -- to the jug's material, and that clone consumed nothing,
    -- forever. Sample the contents instead: the lock below then pins
    -- reagent[0] to the actual tar, completion consumes exactly that
    -- tar, and GET_MATERIAL derives from it. No tar visible yet
    -- means no swap this poll; the base job waits, the same way an
    -- empty char job does.
    if config.profile == PROFILE_PITCH then
        mat_type, mat_index = nil, nil
        pcall(function()
            for _, iref in ipairs(job.items) do
                local inside = dfhack.items.getContainedItems(iref.item)
                if inside then
                    for _, c in ipairs(inside) do
                        if c:getType() == df.item_type.LIQUID_MISC
                           and c.mat_type == 0 and c.mat_index >= 0 then
                            mat_type, mat_index = 0, c.mat_index
                            return
                        end
                    end
                end
            end
        end)
    end
    if not mat_type or not mat_index then return end

    local suffix = ''
    if config.is_creature then
        local ok, r, c = pcall(function()
            return job.items[0].item.race, job.items[0].item.caste
        end)
        if ok and r then suffix = '_R' .. r .. 'C' .. (c or 0) end
    end

    -- Per JOB, not per material. Product counts are rewritten live, so
    -- two jobs sharing one ghost would overwrite each other's output.
    -- The job id is the only key that cannot collide.
    local ghost_code = rname .. '_GHOST_' .. mat_type .. '_' .. mat_index
                       .. suffix .. '_J' .. tostring(job.id)

    local rxn = ghost_cache[ghost_code]
    if not rxn then
        for _, r in ipairs(df.global.world.raws.reactions.reactions) do
            if r.code == ghost_code then
                rxn = r ghost_cache[ghost_code] = r break
            end
        end
    end
    if not rxn then
        build_ghost_jit(rname, ghost_code, mat_type, mat_index)
        rxn = ghost_cache[ghost_code]
    end
    if not rxn then return end

    pcall(function() rxn.flags.FORTRESS_MODE_ENABLED = true end)
    job.reaction_name = ghost_code
    log_once('swap:' .. job.id, 'DETAIL', 'Ghost Swap: ' .. rname .. ' -> ' .. ghost_code, 'SWAP')

    -- Products and snapshot IMMEDIATELY, not on the next poll. A one
    -- item job can finish inside the ten frame gap. If it does and
    -- nothing ran here, it completes on whatever counts the ghost was
    -- built with, and no snapshot ever exists so the bank is never
    -- settled for it. Both failures are silent.
    handle_ghosted(job, rname)
end

-- ==========================================
-- SETTLEMENT
-- ==========================================
-- Credits the bank for one finished job cycle and prints the ledger
-- block for it. Called from TWO places, and it needs both.
--
--   1. handle_ghosted, the moment it sees the job holding DIFFERENT
--      items than the snapshot it already has.
--   2. audit_sweep, when a snapshot goes stale because the job
--      finished and nothing replaced it.
--
-- Path 1 exists because path 2 alone loses value. The sweep only fires
-- on a snapshot that has been stale for two poll ticks. When a job
-- completes and grabs its next item faster than that, the snapshot is
-- overwritten before the sweep ever sees it and the burned item is
-- never credited. Measured on a live corpsepiece run: 2 of 22 pieces
-- vanished that way, 4.4 percent of the value fed in.
--
-- BURN TEST. job.flags.working is the only reliable difference between
-- a job that completed and one that was cancelled: a completing job
-- holds it for its whole run, a cancelled job never sets it. Item
-- existence corroborates, since a consumed reagent is destroyed and
-- df.item.find returns nil for its id.
-- ==========================================
-- force skips the retry below. Used when a new cycle has already
-- started, because the snapshot cannot survive under the same job id
-- and a verdict has to be reached now.
--
-- Returns true when a verdict was reached, false when the caller
-- should keep the snapshot and let the sweep look again.
function settle(id, s, force)
    -- Consumed means vanished OR reduced. A partly eaten stack is the
    -- common case on plants, food and cloth, where DF takes what the
    -- reagent asked for and leaves the rest as the same item.
    local gone = false
    for _, iid in ipairs(s.ids or {}) do
        local it = nil
        pcall(function() it = df.item.find(iid) end)
        if not it then
            gone = true
        else
            local sz = 1
            pcall(function() sz = it.stack_size or 1 end)
            if sz < ((s.stacks or {})[iid] or sz) then gone = true end

            -- ---- A DRAINED DIMENSION IS A CONSUME ----
            -- The liquid twin of the stack rule above, and it belongs
            -- HERE for the same reason the drain's contents witness
            -- does: untouched() decides a CYCLE BOUNDARY, this decides
            -- the VERDICT, and wiring a witness into the first while
            -- the second cannot see it looks right and does nothing.
            -- That is the note directly below, made a second time.
            --
            -- MEASURED, BOIL_PITCH job 12 over three cycles: tar #1535
            -- read dim 2400, then 2250, then 2100, exactly 150 drawn
            -- per cycle, and every verdict was NOT CONSUMED because
            -- none of the three tests above could see it.
            --
            -- This slept until the jugs were filled. A jug holding one
            -- unit was DESTROYED by a 150 draw, so the tar vanished
            -- and the first test caught it; a jug holding sixteen
            -- survives at 2250 and leaves the dimension as the only
            -- surviving evidence.
            local dm = nil
            pcall(function() dm = it.dimension end)
            if dm and dm < ((s.dims or {})[iid] or dm) then
                gone = true
            end

            -- ---- A FILLED VESSEL IS A FIRED CYCLE ----
            -- The drain's witness, and it belongs HERE rather than in
            -- untouched(). untouched decides a CYCLE BOUNDARY inside
            -- handle_ghosted; this function decides the VERDICT, and
            -- they are not the same test. I wired the witness into
            -- untouched first, which looked right and did nothing: a
            -- drain poured real liquid and settle refused to debit it,
            -- which is R2, a free payout.
            --
            -- s.contents is populated for PROFILE_DRAIN only, so for
            -- every other reaction the lookup is nil and this can
            -- never fire. A vessel that gained an item was poured
            -- into, and that is the cycle completing.
            local cn = nil
            pcall(function()
                cn = #(dfhack.items.getContainedItems(it) or {})
            end)
            local was = (s.contents or {})[iid]
            if cn and was and cn > was then gone = true end
        end
    end

    -- ---- ITEM DESTRUCTION IS THE TEST ----
    -- job.flags.working used to be ORed in here and that was wrong. A
    -- job cancelled BEFORE it started never sets the flag, which is
    -- what the original evidence showed, but a job cancelled DURING
    -- the burn has it set and consumed nothing. So worked credited
    -- every mid-burn cancellation.
    --
    -- Gone means consumed. Still present means the job released them.
    --
    -- One retry, because DF may not free a consumed reagent in the
    -- same frame the job completes. Guessing there would trade this
    -- bug for the opposite one, losing value on completed jobs. Only a
    -- cycle that looked like it worked earns the retry; one that never
    -- worked is already a cancellation.
    if not gone and s.worked and not s.recheck and not force then
        s.recheck = true
        s.seen    = audit_tick
        return false
    end

    local burned = gone

    -- ---- LEDGER BLOCK ----
    -- Reads top to bottom as one transaction: what went in, what the
    -- bank held before, what came out, what is left. The old format
    -- printed a running total with no statement of what was produced,
    -- which made a payout that fired indistinguishable from one that
    -- did not.
    local short = tostring(s.base):gsub('^' .. MODULE_PREFIX, '')
    -- YIELD when the job burned: this line and the out line below are
    -- what Normal shows of each finished job.
    log(burned and 'YIELD' or 'DETAIL', string.format('%s  job %d  %s', short, id,
        burned and 'BURNED' or 'NOT CONSUMED'), 'LEDGER')

    local tally, order = {}, {}
    for _, d in ipairs(s.detail or {}) do
        if not tally[d] then table.insert(order, d) end
        tally[d] = (tally[d] or 0) + 1
    end
    for _, d in ipairs(order) do
        log('DETAIL', string.format('  in    %dx %s', tally[d], d), 'LEDGER')
    end

    -- ---- ONE LINE PER CURRENCY ----
    -- A char job reads charcoal and ash; an ash job reads ash and
    -- charcoal. Each line is that currency's transaction: what the
    -- bank held, what this job added, what the slots were written
    -- from.
    local streams = s.streams or {}
    for _, st in ipairs(streams) do
        log('DETAIL', string.format('  bank  %-8s %.6f held + %.6f in = %.6f',
            string.lower(st.currency or '?'),
            st.bank_in or 0, st.haul or 0, st.sum or 0), 'LEDGER')
    end

    -- ---- WHAT THE PRODUCTS WERE SET TO ----
    -- The line whose absence made this whole run unreadable. These are
    -- the numbers written into the ghost, so if the workshop produced
    -- something different the fault is downstream of this file.
    local parts = {}
    for _, o in ipairs(s.out or {}) do
        table.insert(parts, string.format('%d %s', o.n, o.name))
    end
    if #parts == 0 then parts = { 'nothing' } end
    local costs = {}
    for _, st in ipairs(streams) do
        table.insert(costs, string.format('%s %.6f',
            string.lower(st.currency or '?'), st.paid or 0))
    end
    if #costs == 0 then costs = { '0' } end
    log(burned and 'YIELD' or 'DETAIL', string.format('  out   %s   (costing %s)',
        table.concat(parts, ', '), table.concat(costs, ', ')), 'LEDGER')

    if not burned then
        for _, st in ipairs(streams) do
            log('DETAIL', string.format(
                '  bank  %-8s unchanged at %.6f, nothing was consumed',
                string.lower(st.currency or '?'),
                yield_bank[st.bank] or 0), 'LEDGER')
        end
        return true
    end

    -- ---- CARRY, PER BANK ----
    -- Each currency settles into its own pool. What this job burned
    -- minus what its slots paid is what waits for the next job in
    -- that currency, whichever reaction or vanilla job that turns
    -- out to be.
    for _, st in ipairs(streams) do
        local carry = (st.sum or 0) - (st.paid or 0)
        if carry < 0 then carry = 0 end
        if not st.bank then goto next_stream end
        yield_bank[st.bank] = carry
        log('DETAIL', string.format('  bank  %-8s %.6f carried in %s',
            string.lower(st.currency or '?'), carry, tostring(st.bank)), 'LEDGER')
        ::next_stream::
    end
    return true
end

-- ==========================================
-- AUDIT SWEEP
-- ==========================================
-- Any snapshot not refreshed for two ticks belongs to a cycle that is
-- over with nothing replacing it. Settle and drop it.
-- ==========================================
local function audit_sweep()
    for id, s in pairs(audit_state) do
        if s.seen < audit_tick - 1 then
            if live_jobs[id] then
                -- Still in the job list, so it has not been cancelled.
                -- Re-arm and say nothing.
                s.seen = audit_tick
            elseif settle(id, s) then
                audit_state[id] = nil
            end
        end
    end
end

-- ==========================================
-- NULL LIQUID REAPER
-- ==========================================
-- DF mints a to_container liquid product even when its count is
-- zero. The item arrives with the authored dimension and
-- stack_size 0, and nothing in the game can consume it. It is not a
-- malformed item, it is how DF marks a product that did not fire.
--
-- Two measurements make this safe, and it is safe ONLY because of
-- them:
--
--   THE DISCRIMINATOR. Job 22 held OIL_BONE at count 1 and AMMONIA
--   at count 0 on adjacent slots in the same poll, and produced
--   #1162 at stack 1 and #1163 at stack 0. Across ten further mints
--   the pairing never broke. stack_size mirrors the product count,
--   so stack 0 means unpaid and nothing else.
--
--   THE REMOVAL. dfhack.items.remove on a null inside a jug frees
--   the jug at once: #1113 in container #979, contents 1 before and
--   0 after. The item stays findable until DF collects it, so do not
--   judge occupancy by scanning the world; ask the container.
--
-- WHY IT MATTERS. An unreaped null holds its jug, the vessel
-- reagents demand empty, and the next job pulls two more. Measured
-- at two aluminium jugs per run, and one buffalo bone stack drained
-- roughly twenty eight and ran the fort dry mid job. This is not a
-- bone problem: RETORT_WOOD minted a TAR and a VINEGAR_WOOD
-- null on a perfectly correct unpaid run.
--
-- WHY IT LIVES IN THE POLL. It needs to know nothing about jobs,
-- cycles or burn verdicts. Putting it in settle would chain it to
-- cycle detection, which is currently unreliable, and a jug would
-- stay hostage whenever a cycle failed to settle.
--
-- NEVER INVERT THIS. Stamping a null up to stack 1 turns every
-- unpaid product into real consumable fluid. That shipped once from
-- this file and minted counterfeit tar and bone oil. Removing a null
-- destroys nothing, because nothing was ever paid for it.
-- ==========================================
local function reap_null_liquids()
    -- Typed vector first, indexed form as the older API shape.
    -- Neither working is a named fault rather than a silent skip.
    local vec = nil
    pcall(function() vec = df.global.world.items.other.LIQUID_MISC end)
    if not vec then
        pcall(function()
            vec = df.global.world.items.other[df.items_other_id.LIQUID_MISC]
        end)
    end
    if not vec then
        log_once('reaper_vec', 'ERROR',
            'LIQUID_MISC item vector unreachable, unpaid liquids'
            .. ' cannot be reaped and jugs will stay occupied.', 'REAPER')
        return
    end

    -- Collect first, remove second. Removing while iterating the
    -- vector DF is also mutating is asking for a skipped entry.
    local doomed = {}
    for _, it in ipairs(vec) do
        local sz = nil
        pcall(function() sz = it.stack_size end)
        if sz ~= nil and sz < 1 then
            local tok = nil
            pcall(function()
                local mi = dfhack.matinfo.decode(it)
                if mi then tok = tostring(mi:getToken()):upper() end
            end)
            -- This module's liquids only. A dwarf's booze in a
            -- borrowed jug is not this module's business.
            if tok and tok:find('MAKING_FUEL_', 1, true) then
                table.insert(doomed, { item = it, id = it.id, tok = tok })
            end
        end
    end

    for _, d in ipairs(doomed) do
        local freed = nil
        pcall(function()
            local c = dfhack.items.getContainer(d.item)
            if c then freed = c.id end
        end)
        local ok = pcall(function() dfhack.items.remove(d.item) end)
        if ok then
            log('DETAIL', string.format(
                'REAPED unpaid %s #%d%s', d.tok, d.id,
                freed and (', jug #' .. freed .. ' freed') or ''), 'REAPER')
        else
            log('ERROR', string.format(
                'could not remove unpaid liquid #%d, its jug'
                .. ' stays occupied.', d.id), 'REAPER')
        end
    end
end

-- ==========================================
-- WATCHER LOOP
-- ==========================================
local err_reported = false

local function poll()
    if not dfhack.isMapLoaded() or not _G.refinish_active then return end

    -- ---- PAUSE GATE ----
    -- The poll is scheduled on frames, which keep advancing while the
    -- game is paused. Nothing here needs to run then: no items move
    -- and no jobs progress. Letting the audit tick advance while
    -- paused would also age snapshots out and settle banks for jobs
    -- that are simply frozen.
    if dfhack.world.ReadPauseState() then return end

    local ram_loaded = _G.refinish_ram_loaded
    if ram_loaded ~= last_ram_loaded then
        -- Ghosts must not be held across a RAM transition. They become
        -- dangling the moment clear_module_assets() runs.
                -- yield_bank is NOT cleared here. See its declaration: it
        -- holds no pointers, and a RAM transition fires on every
        -- save.
        ghost_cache     = {}
        audit_state     = {}
        seen            = {}
        last_ram_loaded = ram_loaded
    end
    if not ram_loaded then return end

    local ok, err = pcall(function()
        audit_tick = audit_tick + 1

        -- Clear unpaid liquids out of the jugs before anything
        -- else touches them. Independent of jobs and cycles by
        -- design; see NULL LIQUID REAPER above.
        reap_null_liquids()
        vessel_poll = vessel_poll + 1

        -- ---- WHO IS ALIVE THIS POLL ----
        -- live_jobs was declared and read and NEVER WRITTEN TO. It has
        -- been empty on every poll since it was added, so the branch
        -- in audit_sweep that re-arms a still running job could never
        -- be taken, and the sweep settled live jobs mid cycle. Its own
        -- comment describes the bug it was meant to prevent, and that
        -- bug has been live the whole time.
        --
        -- Cleared and refilled rather than accumulated: a job id that
        -- has left the list must stop being alive, and the sweep runs
        -- after this loop so it always sees a complete set.
        for k in pairs(live_jobs) do live_jobs[k] = nil end

        for _, job in utils.listpairs(df.global.world.jobs.list) do
            live_jobs[job.id] = true
            if job.job_type == df.job_type.CustomReaction then
                local rname = tostring(job.reaction_name)

                -- ---- ALREADY GHOSTED ----
                -- After the swap rname is the ghost code, so the
                -- direct config lookup misses. Recover the base code
                -- from the ghost code to keep tracking it.
                local ghost_base = string.match(rname,
                    '^(' .. MODULE_PREFIX .. '.-)_GHOST_')

                if ghost_base and JIT_CONFIG[ghost_base] then
                    if #job.items > 0 then
                        -- Mark that this cycle actually held something,
                        -- so the empty list below is the END of a cycle
                        -- and not the pre haul window a job opens with.
                        local es = expand_state[job.id]
                        if es then es.held = true end
                        handle_ghosted(job, ghost_base)
                    else
                        -- ---- BETWEEN CYCLES ----
                        -- The item set emptying is DF's own cycle
                        -- boundary, and nothing is attached, so no
                        -- job_item_idx can be pointing at a slot being
                        -- removed. Extras come off here so the next
                        -- cycle is born at the reaction's own shape and
                        -- never demands a jug it does not need.
                        local es = expand_state[job.id]
                        if es and es.held and es.n > 0 then
                            local g = ghost_cache[tostring(job.reaction_name)]
                            if g then collapse_vessels(job, g) end
                        end

                        -- ---- AND SETTLE HERE ----
                        -- This is where a cycle actually ends, so this
                        -- is where it gets its verdict. Until now the
                        -- only thing settling a repeat cycle was the
                        -- audit sweep firing through the dead
                        -- live_jobs guard, two ticks after the
                        -- snapshot went stale. That is why six
                        -- consumptions produced four ledger lines: the
                        -- sweep fired when the empty window happened
                        -- to last two ticks and not otherwise.
                        --
                        -- It also fired MID cycle, while the reagent
                        -- was still sitting there, which is why every
                        -- one of those verdicts read NOT CONSUMED.
                        -- Here the reagent has either gone or it has
                        -- not, so the burn test means something.
                        --
                        -- Not forced, so the one retry still applies:
                        -- DF does not always free a consumed reagent
                        -- in the same frame the cycle closes.
                        local s = audit_state[job.id]
                        if s and s.ids and #s.ids > 0 then
                            if settle(job.id, s) then
                                audit_state[job.id] = nil
                            end
                        end
                    end
                else
                    -- ---- NOT YET GHOSTED ----
                    -- Wait for at least one item: the ghost is keyed
                    -- on what walked in and there is nothing to read
                    -- until something has.
                    -- A runtime clone reaches this lookup under its
                    -- OWN code and is adopted only if its maker
                    -- registered it. An unadopted clone is named once
                    -- rather than silently completing on its own
                    -- counts, which is what a per retort drain did:
                    -- two jugs filled, nothing debited, and the only
                    -- trace was the reaper clearing liquids that were
                    -- never paid for.
                    --
                    -- AUTHORED IS THE GUARD, NOT THE CONFIG. Missing
                    -- config used to be the whole test, which made
                    -- this fire at level 0 for every deliberately flat
                    -- reaction in the module. A reaction the module
                    -- declared is doing what it was told; only a code
                    -- the module never declared can be an unadopted
                    -- clone. Putting a false fault in the fault
                    -- channel is how a real one gets missed.
                    local config = JIT_CONFIG[rname]
                    if config and #job.items > 0 then
                        swap_to_ghost(job, rname, config)
                    elseif not config and #job.items > 0
                           and not AUTHORED[rname]
                           and rname:sub(1, #MODULE_PREFIX) == MODULE_PREFIX
                           and not rname:find('_GHOST_', 1, true) then
                        -- ERROR: an unadopted clone completes on its own counts and banks
                        -- nothing, the same fault drain-key reports for its drains.
                        log_once('unadopted:' .. rname, 'ERROR', string.format(
                            'Job %d runs %s, which the module never'
                            .. ' declared and which has no config. That'
                            .. ' makes it a runtime clone whose maker'
                            .. ' did not call register_alias. It will'
                            .. ' complete on its own counts and bank'
                            .. ' nothing.', job.id, rname), 'ALIAS')
                    end
                end
            end
            ::next_job::
        end

        audit_sweep()
    end)

    if not ok then
        if not err_reported then
            log('ERROR', 'ERROR in poll: ' .. tostring(err), 'POLL')
            err_reported = true
        end
    else
        if err_reported then log('INFO', 'Poll recovered after previous error.', 'POLL') end
        err_reported = false
    end
end

-- ==========================================
-- ORPHAN SWEEP AND LIFECYCLE
-- ==========================================
-- A job left pointing at a ghost code from a previous session names a
-- reaction that no longer exists, so it can never run. Point it back
-- at its base and let the swap happen again cleanly.
-- ==========================================
local function sweep_orphans()
    local reverted = 0
    pcall(function()
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            if job.job_type == df.job_type.CustomReaction then
                local rname = tostring(job.reaction_name)
                local base = string.match(rname,
                    '^(' .. MODULE_PREFIX .. '.-)_GHOST_')
                if base and JIT_CONFIG[base] then
                    job.reaction_name = base
                    reverted = reverted + 1
                end
            end
        end
    end)
    if reverted > 0 then
        log('INFO', 'Reverted ' .. reverted .. ' orphaned ghost job(s).', 'ORPHANS')
    end
end

-- ==========================================
-- RUNTIME CLONES OF A MANAGED REACTION
-- ==========================================
-- JIT_CONFIG is keyed on the reaction key the module DECLARED, so a
-- reaction cloned into the raws at runtime is invisible to this engine
-- however well formed it is. Its jobs fall through the swap, keep the
-- authored product counts, and DF mints liquids nothing ever paid for,
-- which the reaper then clears. Every symptom of that is downstream
-- and none of them names the cause.
--
-- The per retort drains are exactly this: making-fuel-drain-key.lua
-- cuts one RETORT_DRAIN clone per furnace so each can be gated on its
-- own key material.
--
-- The clone's maker declares what it is rather than this engine
-- guessing from the name. A name test would make the engine know a
-- watcher's private naming scheme, and would break the day a declared
-- reaction key happened to look like one.
--
-- The alias points at the SAME cfg table, not a copy, so a clone can
-- never drift from the base it was cut from. Aliases are not counted
-- in the startup banner because they are added by later polls, after
-- start() has already counted, and every one of them is discarded when
-- derive_config rebuilds JIT_CONFIG on the next data cycle.
function register_alias(clone_code, base_code)
    local cfg = JIT_CONFIG[base_code]
    if not cfg then
        -- A base the module DECLARED but which has no config is
        -- deliberately flat: a watcher does its work and there is
        -- nothing here to pay, so there is no config to share. Its
        -- clones are declared by extension all the same, so they
        -- inherit AUTHORED rather than being named in the fault
        -- channel as unadopted. The orphan check's own rule is that
        -- AUTHORED is the guard, not the config.
        --
        -- Without this, a per building FILL_TANK_B<id> clone meets
        -- every condition of that check: no config, the module
        -- prefix, no _GHOST_, and AUTHORED keyed on the declared code
        -- only, never on a clone of it.
        --
        -- Re-asserted by the caller every poll like everything else
        -- here, because derive_config rebuilds AUTHORED on each data
        -- cycle. A vanilla base is in neither table, so it still
        -- returns false, and false still means unmanaged.
        if AUTHORED[base_code] then
            AUTHORED[clone_code] = true
            return true
        end
        return false
    end
    if JIT_CONFIG[clone_code] == cfg then return true end
    JIT_CONFIG[clone_code] = cfg
    log('DETAIL', 'Adopted runtime clone ' .. tostring(clone_code)
        .. ' as ' .. tostring(base_code), 'ALIAS')
    return true
end

-- ==========================================
-- ORPHAN SWEEP, RE RUNNABLE
-- ==========================================
-- start() sweeps orphans before any alias can exist, so a job left
-- mid drain across a data cycle is still pointing at a ghost code cut
-- from a clone this engine has not been told about yet, and the sweep
-- passes it over. The clone's maker calls this once its aliases are
-- back, and the same revert then fires. Idempotent: a reverted job no
-- longer matches the ghost pattern.
function resweep_orphans()
    sweep_orphans()
end

function start(rxn_data)
    -- The reactions table arrives from making_fuel.lua at boot and
    -- is cached in this script's environment, so a bare console
    -- restart reuses the last handoff instead of going dark.
    if rxn_data then cached_rxns = rxn_data end
    if not cached_rxns then
        log('ERROR', 'no reaction data. making_fuel.lua hands the'
            .. ' reactions table to start(); until it does, nothing'
            .. ' is adaptive and every zero count reaction pays'
            .. ' nothing.', 'START')
        return
    end
    local skipped, no_secondary, bad_layout = derive_config(cached_rxns)
    if #skipped > 0 then
        log('WARNING', 'adaptive but recognizable by no chain,'
            .. ' paying nothing: ' .. table.concat(skipped, ', '), 'START')
    end
    if #bad_layout > 0 then
        log('WARNING', 'secondary slot declares the wrong product,'
            .. ' secondary NOT paid: ' .. table.concat(bad_layout, ', '),
            'START')
    end
    if #no_secondary > 0 then
        log('DETAIL', 'no secondary slot, primary only: '
            .. table.concat(no_secondary, ', '), 'START')
    end

    seen         = {}
    ghost_cache  = {}
    audit_state  = {}
    err_reported = false

    -- Both of these validate themselves on read, so this is belt and
    -- braces rather than the load bearing fix. It is here because it
    -- is deterministic: start() runs on every data cycle, so the
    -- common case never reaches the validation path at all.
    --
    -- Deliberately NOT added to the RAM transition block in poll().
    -- poll() returns early while the game is paused and the whole
    -- silent cycle completes inside the ESC handler in about a
    -- second, so that block is not reliably reached and putting the
    -- clear there would read as coverage it does not provide.
    base_cache      = {}
    drain_mat_cache = nil

    -- ---- EVERYTHING KEYED BY JOB ID, OR IT OUTLIVES THE WORLD ----
    -- These three were missing, and the omission corrupts working
    -- retorts rather than merely leaking.
    --
    -- MEASURED: leave to the main menu, re-enter an earlier save
    -- without recycling, and the first whale dies on arrival. DF hands
    -- out low job ids again after a reload, so a fresh job 10 inherits
    -- the expand_state of a whale that expanded in the PREVIOUS
    -- session, `held = true` and `n = 2` and all.
    --
    -- The between cycles branch then reads that stale record and calls
    -- collapse_vessels, which erases n slots from the END of
    -- job.job_items and of the ghost's reagents and products. On a job
    -- that appended nothing, those are its REAL base vessel slots. A
    -- retort missing its vessel filters cannot run, and no amount of
    -- collection_open helps because the damage lands before collection
    -- matters.
    --
    -- It is also why a recycle always worked and a reload never did: a
    -- recycle rebuilds this environment, a reload does not.
    --
    -- vessel_poll goes with them because expand_state records it as
    -- `tick`, and a cleared table beside a running counter is only
    -- half a reset. The container cache is keyed on the same counter.
    expand_state      = {}
    live_jobs         = {}
    vessel_poll       = 0
    pool_room_cache   = { poll = -1, cap = nil }
    -- Re-point at the global rather than replacing it, so a world
    -- reload does not discard a balance the previous fort accrued.
    _G.refinish_fuel_bank = _G.refinish_fuel_bank or {}
    yield_bank = _G.refinish_fuel_bank
    sweep_orphans()

    local n_char, n_ash, n_split, n_retort = 0, 0, 0, 0
    for _, c in pairs(JIT_CONFIG) do
        if     c.profile == PROFILE_KINDLING then n_split  = n_split  + 1
        elseif c.profile == PROFILE_ASH      then n_ash    = n_ash    + 1
        elseif c.liquid_slots                then n_retort = n_retort + 1
        else                                       n_char   = n_char   + 1 end
    end

    repeatUtil.scheduleEvery(REPEAT_KEY, POLL_FRAMES, 'frames', poll)

    -- The banner reads T, so a tuning table that is nil or missing a
    -- field throws HERE, at the end of start, after the poll is already
    -- scheduled. Guarded so a cosmetic line can never be what stops
    -- the module, and so the field that is actually missing gets named.
    local ok_banner, err_banner = pcall(function()
        log('DETAIL', string.format(
            'Started. %d char, %d ash, %d retort and %d split reactions'
            .. ' adaptive. Anchor %d volume = %.2f charcoal or ash,'
            .. ' %.2f liquid units in the retort at %.2f of the'
            .. ' charcoal. Charring leaves %.3f ash per charcoal,'
            .. ' ashing leaves %.3f charcoal per ash.',
            n_char, n_ash, n_retort, n_split, T.ANCHOR_VOLUME,
            T.ANCHOR_YIELD, dial('FLUID_ANCHOR_UNITS'),
            dial('RETORT_CHARCOAL_SHARE'),
            dial('ASH_FROM_CHARRING'), dial('CHARCOAL_FROM_ASHING')),
            'START')
    end)
    if not ok_banner then
        -- ERROR: the tuning table is missing a field, and whatever else
        -- reads it will be wrong as well. This used to print to the
        -- console at every load it happened on.
        log('ERROR', 'started, but the banner failed: '
            .. tostring(err_banner) .. '. The tuning table is missing a'
            .. ' field. The watcher is running; yields may be wrong.',
            'START')
    end
end

function stop()
    repeatUtil.cancel(REPEAT_KEY)
    log('DETAIL', 'Stopped.', 'STOP')
end