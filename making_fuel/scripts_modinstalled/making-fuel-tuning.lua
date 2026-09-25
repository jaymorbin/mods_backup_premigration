--@ module = true
-- making-fuel-tuning.lua
-- ==========================================
-- MAKING FUEL: YIELD TUNING
-- ==========================================
-- Every number that decides what a char, ash or split reaction produces
-- lives in this file and nowhere else. Nothing downstream carries its
-- own copy of any of it.
--
-- HOW TO USE THIS FILE
--   1. Change a number in the TUNABLES block below.
--   2. Run  making-fuel-curve  to see the whole curve and the
--      invariant checks. No world needs to be loaded and no recycle is
--      needed, it is pure arithmetic.
--   3. If the checks pass, recycle and play.
--
-- PLAYER SETTINGS. Some keys in T are also offered on the Making Fuel
-- page of the RM HUD (see making-fuel-settings.lua for which). For
-- those, the value here is the SHIPPED DEFAULT: a player's choice is
-- written over it for their fort at every token call. Changing one
-- here changes the default for every fort that never chose otherwise.
--
-- The checks are the point. They catch the class of mistake where a
-- change looks fine in isolation and quietly opens an exploit three
-- reactions away.
--
-- THE CONTRACT
--   Per reference log: split then char pays 2.5, charring the log
--   pays 2.0, and every processed route pays less than 2.0. Only
--   splitting beats the log, ever. Processing wood loses material,
--   and recovery returns a bounded fraction of the LOSS, never
--   enough to reach the log again. Fixed conversions between
--   adaptive items equate VALUES, not volumes. The currency ladder
--   of cinder, charcoal, char boulder and hunk never scales, and
--   its items never enter adaptive reactions. Sources are the map's
--   endowment and scale linearly with the data: fell forensics
--   proved vanilla pays trunk tiles only, so a completed fell drops
--   the rest of the tree in kind, limb logs and branches, twig
--   wood bundled into the branch count, at per tile counts. The
--   value law governs conversions and recovery; it does not ration 
--   what the world grows.
--
-- MODULE CONVENTION, DO NOT UNDO
--   dfhack.reqscript returns a script's ENVIRONMENT, meaning its table
--   of GLOBAL functions and variables. It ignores any return value and
--   it cannot see file locals. So T and the four functions below are
--   deliberately globals with no local keyword. Adding local to any of
--   them makes this file load cleanly and then hand back an empty
--   table, and the consumer dies on a nil index somewhere unrelated.
--   Verified against Lua_API.txt, dfhack.reqscript.
-- ==========================================

-- ==========================================
-- TUNABLES
-- ==========================================
-- Edit anything in this block. Nothing below it is a magic number.
-- ==========================================
T = {

    -- ---- THE ANCHOR ----
    -- One log of reference wood, and what it is worth. Every other
    -- yield in the mod is measured against this pair, so moving either
    -- one moves the entire fuel economy together and keeps every
    -- relative value intact.
    --
    -- ANCHOR_YIELD is 2.0, from making_fuel_planning.txt: the
    -- air-dried wood breakdown puts 20 to 28 percent of a log by
    -- weight into combustible charcoal, landing a 5000 log at 1.67 to
    -- 2.33 bar units.
    --
    -- It also decides how hard the whole adaptive rollout lands. Every
    -- single item reaction gives a flat 1 charcoal today regardless of
    -- size. Going adaptive at 1.0 averages 0.42 across the furniture
    -- family, a 58 percent cut. At 2.0 it averages 0.84, near parity,
    -- with the size spread doing the work instead of a blanket nerf.
    --
    -- Lower it if fuel turns out too plentiful: every solid relative
    -- value is untouched and the solid economy just scales. NOT BELOW
    -- 1.45. Liquid fuel has its own anchor (FLUID_ANCHOR_UNITS) and does
    -- not scale with this, so lowering it raises the retort and tank
    -- route against charring. MEASURED with check(): 1.45 and up pass
    -- every check; 1.40 and below fail "retort route stays under its
    -- ceiling", and 1.0 returns 1.453 of the log against a ceiling of
    -- 1.25. The settings page offers 1.5 to 3.0 for that reason.
    ANCHOR_VOLUME    = 5000,
    ANCHOR_YIELD     = 2.0,

    -- ---- SIZE CURVE ----
    -- Compresses the input size range. Creature sizes span roughly
    -- 3000x, from a rat to a sperm whale, and without compression one
    -- whale out-fuels a fortress.
    --
    -- 1.0 is linear and perfectly additive.
    -- 0.5 is square root, which is what is tested and in game.
    --
    -- BELOW 1.0 THIS IS SUB ADDITIVE: n equal pieces of one whole are
    -- worth n^(1-exponent) times the whole. At 0.5 that is 2x for four
    -- pieces and 7x for fifty. Anywhere a reaction turns one item into
    -- several, that gap is an exploit unless the piece count is
    -- derived from yield rather than from volume. split_count() below
    -- is derived from yield precisely so this exponent cannot open
    -- one. Do not add a reaction that splits by a fixed count.
    SIZE_EXPONENT    = 0.5,

    -- ---- MATERIAL DENSITY ----
    -- DF wood density runs 100 for feather tree to 1250 for blood
    -- thorn, a 12.5x spread across 70 species, so this is the knob
    -- that makes species matter.
    --
    -- REF_DENSITY 600 is deliberate, not arbitrary. Mean across all 70
    -- vanilla woods is 604.8 and the median is 590, so at 600 the
    -- AVERAGE log still yields exactly ANCHOR_YIELD and only the
    -- spread around it changes. Dropping to 500 inflates the whole
    -- economy 21 percent.
    --
    -- DENSITY_EXPONENT 1.0 is linear, which is physically right:
    -- charcoal per unit volume really is proportional to density.
    -- Set 0.5 to compress the spread if blood thorn feels too strong.
    --
    -- The clamp is for coal at 1346 and plant thread at 1520, which
    -- would otherwise run away above the intended band.
    REF_DENSITY      = 600,
    DENSITY_EXPONENT = 1.0,
    DENSITY_MIN      = 0.10,
    DENSITY_MAX      = 2.50,

    -- ---- MATERIAL CLASS ----
    -- Applied OUTSIDE the size curve, so these read as plain
    -- percentages of the wood yield for the same volume. FLESH at
    -- 0.125 means a corpse is worth an eighth of a log of the same
    -- size, and changing it to 0.25 exactly doubles corpse output.
    --
    -- That is the whole reason the class factor sits outside the
    -- exponent. Inside it, a factor of 0.125 in yield would have
    -- needed a constant of 0.0156, and nobody can tune against that.
    --
    -- FLESH 0.125 comes from making_fuel_planning.txt, which puts
    -- corpses at 80 to 93 percent less charcoal than logs per cm3.
    -- The doc's own bar unit figures work out at 0.3 charcoal per
    -- 6000 corpse against 2.0 per 5000 log, which is 0.125.
    --
    -- The others are starting positions from real charcoal chemistry,
    -- not measurements. Bone char is roughly a tenth carbon by weight
    -- against wood's quarter, hence the low figure. Move them freely.
    --
    -- NOT MODELLED: the doc also records corpses producing 14 to 120
    -- percent MORE char than logs while producing far less charcoal.
    -- One scalar per class cannot express that asymmetry. It would
    -- need a second per class number splitting the charcoal side from
    -- the cinder side, and a second bank to hold it.
    --
    -- ---- INERT IS A BACKSTOP, NOT A GAMEPLAY PATH ----
    -- A wood furnace cannot consume something that does not burn, so
    -- an inert item must never reach one in the first place. That is
    -- enforced UPSTREAM by the reagent, not here: the wood flag on the
    -- reagent maps to WOOD_MATERIAL and DF simply never selects a
    -- stone or metal item for the job.
    --
    -- Runtime refusal cannot be the primary defence. Preserving the
    -- reagent and producing nothing releases the item, the repeat job
    -- re-posts, and the same stone chair gets picked again forever.
    -- Only the reagent gate breaks that loop, because the item is
    -- never a candidate.
    --
    -- INERT therefore exists solely to catch a material that slipped
    -- through, which would mean a reagent is missing its gate. The
    -- watcher must refuse and suspend that job rather than burn the
    -- item for nothing. If you ever see a suspended char job, a
    -- reagent needs fixing, not this number.
    INERT_SUSPENDS_JOB = true,
    --
    -- CHARRED is the mod's own char, already carbonised once. It is
    -- 1.000 because charring char is the packing ladder, and the three
    -- ladder reactions are excluded from adaptive yield anyway, so
    -- this exists to keep the classifier total rather than to be used.
    --
    -- MINERAL is real mineral fuel: lignite, bituminous, cannel,
    -- vanilla charcoal, and the carbon-bearing diamonds. NO CHAR
    -- REACTION ACCEPTS ANY OF THEM. Coal belongs to the retort and
    -- coke path. If MINERAL ever appears in a live yield log, a
    -- reagent is missing a material gate.
    --
    -- Dung, straw and mash are NOT here. They are digested or dried
    -- plant matter and take PLANT, even though DF files them as
    -- inorganic because an injected material has nowhere else to go.
    -- ---- DISABLED FACTOR DIALS ----
-- Every one of these is installed and neutral. The machinery to use
-- them exists; nothing is turned on. See THE FACTOR PIPELINE.
--
-- SKILL: linear from FLOOR at level 0 to CEILING at SKILL_CAP. Both
-- at 1.0 means skill is measured and ignored, which is what shipping
-- disabled amounts to. Set FLOOR 0.8 and CEILING 1.2 for a modest
-- twenty percent spread across the whole skill range.
SKILL_CAP     = 20,
SKILL_FLOOR   = 1.0,
SKILL_CEILING = 1.0,

-- WEAR: indexed by item.wear, 1 to 3. Index 0 is unworn and never
-- looked up. All 1.0 until someone decides what a battered barrel
-- should be worth.
WEAR_STEPS = { [1] = 1.0, [2] = 1.0, [3] = 1.0 },

-- QUALITY: indexed by item.quality, 0 to 5. More useful as a gate
-- than a scale, since a masterwork chair is not more wood than a
-- plain one. A zero here lets a caller refuse the job instead.
QUALITY_STEPS = { [0] = 1.0, [1] = 1.0, [2] = 1.0,
                  [3] = 1.0, [4] = 1.0, [5] = 1.0 },

    CLASS = {
        WOOD    = 1.000,
        CHARRED = 1.000,
        MINERAL = 1.000,
        -- Peat is not a mineral. It is partly decayed sphagnum,
        -- sedge and reed compressed under waterlogged anoxic
        -- ground, the first rung of the coalification ladder below
        -- lignite: biogenic, no crystal structure, no fixed
        -- composition. MINERAL was only ever an artefact of IS_STONE
        -- being the lever that makes it drop a boulder.
        --
        -- PLANT at 0.300 is equally wrong the other way, because
        -- that factor is calibrated for straw and leaves: airy and
        -- barely carbonised. Peat has been compressing for
        -- millennia and sits between them.
        --
        -- 0.600 is measured, not picked. Peat runs 50 to 60 percent
        -- carbon dry against wood's 50, but yields 15 to 17 MJ/kg
        -- against wood's 19, and DF's own density comment admits
        -- the 850 still holds water, roughly 25 percent air dried.
        -- Dry fraction 0.75 times energy ratio 0.85 gives 0.64, and
        -- 0.600 is the round number under it.
        --
        -- 0.600 was those TWO numbers multiplied: 0.75 dry fraction
        -- times 0.85 energy ratio. That worked while peat only ever
        -- entered the curve air dried, because the reagents are gated
        -- to PEAT_DRIED. It cannot work for dung, straw and mash,
        -- which enter WET and DRY through the same reagent, so the
        -- moisture half has moved out to DRY_FRACTION below and this
        -- constant is now the energy ratio alone.
        --
        -- 0.85 rounded down to 0.80, keeping the original's habit of
        -- taking the round number under. 0.80 times the 0.75 dry
        -- fraction is 0.600 exactly, so dried peat lands on the same
        -- net it shipped with and its rung does not move.
        --
        -- At that net a 10000 boulder pays 1.20 against a log's 1.00:
        -- 8.5 kg of real but unglamorous fuel, beating a log
        -- without being the free doubling the old fixed 2 was.
        PEAT    = 0.800,
        FAT     = 0.600,
        LEATHER = 0.500,
        BONE    = 0.350,
        PLANT   = 0.300,
        HAIR    = 0.300,
        FLESH   = 0.125,
        INERT   = 0.000,

        -- ---- THE COALS ----
        -- ENERGY PER UNIT DRY MASS, relative to wood, exactly as
        -- PEAT above is. Not a conversion yield: how much of the
        -- feedstock survives carbonisation lives in CARBON_RECOVERY,
        -- and how much of it is water lives in DRY_FRACTION. Three
        -- separate facts, three separate tables, so moving one does
        -- not silently move the others.
        --
        -- Wood is 19 MJ/kg dry and is the 1.000. Bituminous coal is
        -- 30, which is 1.58, taken down to 1.550 on the same habit
        -- that took peat's 0.85 down to 0.80. Lignite dry is 25,
        -- which is 1.32, taken down to 1.300. Those are dry figures
        -- on purpose; lignite's water is a different table.
        --
        -- DF CANNOT TELL THESE TWO APART. Their raws are identical
        -- except the name, the colour and the density: same 409
        -- spec heat, same 11440 ignite point, same NONE melting
        -- point, same 16708 boiling point, same environment. 1250
        -- against 1346 is a 7.7 percent spread carrying an 80
        -- percent difference in vanilla's own yields, and the
        -- lignite density line has a vanilla comment admitting the
        -- number was nudged rather than derived. So rank is
        -- DECLARED here, because there is nothing to measure.
        COAL_LIGNITE    = 1.300,
        COAL_BITUMINOUS = 1.550,

        -- Anthracite runs about 32 MJ/kg on the same dry footing,
        -- which is 1.68, taken down to 1.650 on the same habit. Its
        -- real lead over bituminous is carbon, not energy per
        -- kilogram, and that lives in CARBON_RECOVERY (0.90 against
        -- 0.75), so this sits only one step above it. Without this
        -- row factor_class reports the class unknown and falls back
        -- to 1.0, wood's figure, under even lignite's 1.300.
        COAL_ANTHRACITE = 1.650,
    },

    -- ---- MOISTURE ----
    -- How much of the material is NOT water. Read by factor_moisture.
    --
    -- WHY THIS EXISTS. solid_density is honest physics and has to stay
    -- honest, because DF weighs items with it. But wet material is
    -- dense with WATER, and the yield curve reads density as a proxy
    -- for CARBON. Fresh dung at 700 was out-yielding its own dried
    -- cake at 400 by 1.75x, and wet mash beat dried mash by 1.94x,
    -- which made every DRY reaction in the module value destroying.
    --
    -- The curve wants dry mass. density times volume is wet mass.
    -- This is the correction, and it is the same derivation the PEAT
    -- class factor was already doing in its head.
    --
    -- Anything absent is 1.0, meaning bone dry. Wood, bone, leather
    -- and the charred materials are all already dry by the time they
    -- reach a furnace, so only the wet feedstocks are listed.
    --
    -- MATCHED LONGEST KEY FIRST, substring, like the ghost's MOD_MAT.
    -- Order in this list IS the precedence and must not be sorted,
    -- because MAKING_FUEL_DUNG is a substring of
    -- MAKING_FUEL_DUNG_DRIED and would swallow it.
    --
    -- Figures are solids content, measured, not picked:
    --   fresh dung          15 to 25 percent solids
    --   spent brewer grain  20 to 25 percent solids
    --   threshed straw      already field dry, 85 to 90 percent
    --   cut peat            90 percent water in the ground
    --   air dried anything  a tenth or so of water left in it
    DRY_FRACTION = {
        { 'MAKING_FUEL_DUNG_DRIED',  0.90 },
        { 'MAKING_FUEL_MASH_DRIED',  0.90 },
        { 'MAKING_FUEL_STRAW_DRIED', 0.93 },
        { 'MAKING_FUEL_PEAT_DRIED',  0.75 },
        { 'MAKING_FUEL_DUNG',        0.20 },
        { 'MAKING_FUEL_MASH',        0.22 },
        { 'MAKING_FUEL_STRAW',       0.87 },
        { 'PEAT',                    0.10 },
        -- Coal as mined. Lignite is brown coal and genuinely runs 25
        -- to 35 percent water, which is most of why it is the poor
        -- relation; bituminous is 2 to 8. Neither key is a substring
        -- of another, so these sit at the end without disturbing the
        -- order the peat rows depend on.
        --
        -- JET IS NOT HERE AND IS NOT COMING. Measured live: ignite
        -- 60001, melting 11500, boiling 14000. It fails the
        -- classifier's ignite gate outright and behaves like glass,
        -- not coal, so it is out of the fuel family entirely.
        { 'LIGNITE',                 0.70 },
        { 'COAL_BITUMINOUS',         0.95 },
    },

    -- ---- CARBONISATION RECOVERY ----
    -- What FRACTION OF DRY MASS survives carbonisation as solid
    -- fuel. The third of the three facts CLASS used to be asked to
    -- carry alone, and the one that actually separates coal from
    -- wood.
    --
    -- Wood is the reference at 0.25: charring dry wood returns 20 to
    -- 30 percent of its mass as charcoal, and everything above and
    -- below is expressed against that, so WOOD is exactly 1.000 by
    -- construction and the whole table is a ratio.
    --
    -- Bituminous of coking rank returns 70 to 78 percent of its dry
    -- mass as coke. That is the entire reason coke exists and the
    -- entire reason coal displaced charcoal: three times the solid
    -- fuel out of the same mass in.
    --
    -- Lignite DOES NOT MAKE METALLURGICAL COKE. Low temperature
    -- carbonisation leaves 50 to 55 percent crumbling semi coke. It
    -- is not a worse bituminous, it is a different material, and the
    -- liquid side is where it wins.
    --
    -- THIS IS THE BALANCE LEVER. Every coal yield scales linearly
    -- with WOOD, so if coal lands too strong against wood the honest
    -- fix is one number here, not a fudge inside a reaction.
    CARBON_RECOVERY = {
        WOOD            = 0.25,
        COAL_LIGNITE    = 0.50,
        COAL_BITUMINOUS = 0.75,

        -- Kerogen leaves as oil and gas rather than staying behind as
        -- carbon, so spent shale is almost pure mineral. The lowest
        -- recovery in the table by a wide margin, and the reason a
        -- boulder of it pays about 2.8 solid against bituminous at
        -- 29.5. It is not a fuel rock, it is an oil rock.
        SHALE_OIL       = 0.10,

        -- The top of the ladder. Anthracite is already most of the
        -- way to pure carbon, so almost all of it survives.
        COAL_ANTHRACITE = 0.90,
    },

    -- ---- SPLITTING ----
    -- KINDLING_VOLUME must match the declared size of
    -- MAKING_FUEL_KINDLING in making_fuel_tools.json. They are two
    -- separate files and nothing enforces agreement, so the curve
    -- check prints both for eyeballing.
    --
    -- SPLIT_EFFICIENCY is what fraction of an item's char value
    -- survives being split into kindling first. It is EXACT and size
    -- independent: split then char always returns precisely this
    -- fraction of charring the item directly, whatever the item is.
    -- 0.98 reproduces the current 1 log to 8 kindling.
    --
    -- Must stay below 1.0. At or above it, splitting becomes free
    -- value and every wooden item in the fort turns into a kindling
    -- mine. The curve check refuses to pass if it is not.
        -- 78 is chosen, not inherited. It makes one kindling worth exactly
    -- a quarter charcoal, which puts kindling on the same base-4
    -- ladder as the rest of the fuel tree:
    --
    --   4 kindling = 1 charcoal = 4 cinder,  4 charcoal = 1 boulder
    --
    -- A log then breaks even at exactly 8 kindling, which is the
    -- number the profit has to be read against.
    --
    -- It only decides GRANULARITY. It cancels out of the round trip
    -- entirely: split then char is EFF * direct char regardless of
    -- what this is, because the count is derived from yield. Bigger
    -- kindling means fewer, chunkier pieces of the same total value.
    --
    -- MUST match the declared size of KINDLING in
    -- making_fuel_tools.json. Two files, nothing enforcing agreement.
    KINDLING_VOLUME  = 78,

    -- How much char value SURVIVES being split into kindling first,
    -- and deliberately above 1.0. Splitting is meant to pay: it is the
    -- reward for the extra job, and it is the whole reason a split
    -- tree exists at all.
    --
    -- 5/4 against a break-even of 8 means a log yields 10 kindling
    -- when 8 would have matched charring it whole. The player is never
    -- told this; they notice the 2 spare. Splitting furniture alone
    -- hides it, because there is no whole-log figure to compare
    -- against, which is what makes the log the teaching case.
    --
    -- Exact fraction, not 1.25. Rounded decimals are what put a dwarf
    -- corpse at 0.99980 and floored a whole charcoal to nothing.
    --
    -- Higher than about 3/2 makes splitting mandatory rather than
    -- optional. Lower than about 9/8 is too subtle to be noticed and
    -- the split tree becomes dead content.
    SPLIT_EFFICIENCY = 5 / 4,

    -- ---- PACKING LADDER ----
    -- Char mirrors charcoal on both sides, so the ladder steps by
    -- four in each direction:
    --
    --   4 cinder = 1 charcoal = 4 kindling,  4 charcoal = 1 boulder
    --   1 boulder = 4 hunks at the mason, vanilla's own number
    --   1 hunk = 1 charcoal by CHAR_CHAR_BLOCKS, no constant needed
    --
    -- CINDERS_PER_CHARCOAL is live in both payout paths, ghost and
    -- hijacker, deciding how sub charcoal remainders pay out. It
    -- must match the reagent quantity on CHAR_CINDERS, and
    -- CHARCOAL_PER_BOULDER must match the product count on
    -- CHAR_CHAR_BOULDER, or char is either free money or a silent
    -- loss.
    --
    -- Nothing reads BLOCKS_PER_CHARCOAL any more. The ghost, the
    -- hijacker and the curve all speak the true name, and the
    -- alias died the round the last of them migrated.
    CINDERS_PER_CHARCOAL = 4,
    CHARCOAL_PER_BOULDER = 4,

    -- ---- THE COAL LADDER ----
    -- Rung for rung with the wood ladder above, because a player who
    -- has learned one has learned the other:
    --
    --   4 breeze = 1 coke,  4 coke = 1 green coke
    --
    -- GREEN COKE is the coal side's char: the raw, unfinished article
    -- that low temperature carbonisation leaves and that has to be
    -- fired again before it burns. Real term, and the real process:
    -- green coke is calcined into usable coke. It carries no fuel
    -- class at all, exactly as char and cinder do not, so it cannot
    -- be shovelled into a furnace to skip the second firing.
    --
    -- COKE BREEZE is the coal side's cinder: the fines screened off
    -- coke, too small for a furnace to draw through, worth something
    -- only once it is bound back into a briquette.
    --
    -- SEPARATE CONSTANTS RATHER THAN REUSING THE WOOD PAIR, so coal
    -- can be re-tuned without dragging charcoal with it. They are
    -- both 4 today and check 5.5 says so out loud, so a drift is
    -- visible the moment somebody means it and never silent.
    COKE_PER_GREEN_COKE  = 4,
    BREEZE_PER_COKE      = 4,

    -- ---- THE TWO BURNS ----
    -- MakeCharcoal and MakeAsh are the same job with the damper in
    -- a different position. A closed kiln pyrolyses: most of the
    -- wood comes out as charcoal and what the fire ate to keep
    -- itself hot is left as ash. An open burn does the opposite:
    -- nearly everything goes to ash and whatever smothered before
    -- it finished is char. Vanilla pays one bar of either per log,
    -- so both PRIMARIES sit on the same curve at the same
    -- ANCHOR_YIELD, and these two dials are the SECONDARIES: the
    -- other product each burn leaves behind, as a fraction of the
    -- primary value.
    --
    -- Both on the quarter ladder. A reference log charred pays 2.0
    -- charcoal and banks 0.5 ash, so every second log lands an ash
    -- bar; ashed it pays 2.0 ash and exactly 2 cinders. Symmetric
    -- because nothing yet says the two burns should differ; the
    -- dials are separate so that can change without touching the
    -- other one.
    --
    -- Read by the ghost for every char and ash reaction and by the
    -- hijacker for the two vanilla jobs. Exact fractions, per the
    -- corpse-at-0.99980 lesson above.
    --
    -- Neither is a loop. Ash enters no char reaction and charcoal
    -- enters no ash reaction, so no fraction of a fraction ever
    -- comes back round; check 12 holds both under 1.0 regardless,
    -- because at 1.0 the byproduct is the product and MakeAsh
    -- becomes a charcoal route the contract never priced.
    ASH_FROM_CHARRING    = 1 / 4,

    -- Coal ash per unit of coke. Coal's incombustible mineral matter
    -- runs 5 to 15 percent by mass against wood's 1 to 3, but coking
    -- leaves most of it locked in the coke rather than freeing it,
    -- so the fraction that actually falls out lands under charring's
    -- quarter rather than over it. An eighth is the dial; move it
    -- here and both the retort and the smelter follow.
    ASH_FROM_COKING      = 1 / 8,
    CHARCOAL_FROM_ASHING = 1 / 4,

    -- ---- THE RETORT ----
    -- A retort is a closed vessel heated from outside: nothing in it
    -- burns, so the volatiles the furnace sends up the chimney are
    -- condensed and kept. That is the whole trade. On the SAME item
    -- it pays a reduced share of the furnace's charcoal, and the
    -- difference comes back as liquid.
    --
    -- RETORT_CHARCOAL_SHARE scales the charcoal stream, and the ash
    -- secondary with it, on any adaptive reaction that declares a
    -- liquid product. Below 1.0 so that the retort can never be a
    -- better charcoal source than the furnace; check 13 holds the
    -- whole route, liquid turned back into fuel included, under the
    -- furnace.
    RETORT_CHARCOAL_SHARE = 3 / 4,

    -- Liquid is its own curve, not a fraction of the charcoal value,
    -- because the two come apart by class: a corpse is nearly all
    -- fluid and almost no char, a log is the reverse. Same size
    -- exponent and density factor as charcoal; FLUID_ANCHOR_UNITS is
    -- what a reference log condenses to, in LIQUID_UNIT-sized units.
    --
    -- THE MASS SCALE
    --
    -- ANCHOR_YIELD is 2.0 charcoal, and charcoal is a quarter of a
    -- log by weight. So ONE UNIT IS 12.5 PERCENT OF THE ANCHOR MASS,
    -- solid or liquid. That conversion is the only thing needed to
    -- judge any yield in this file, and it is what the numbers below
    -- are built from.
    --
    -- WHY THIS WAS 1/2 AND IS NOW 1
    --
    -- The old value was justified as tar being about a tenth of dry
    -- wood by mass. But a tenth is 0.8 units, not 0.5, and this dial
    -- is the budget for ALL liquid off the item, which FLUID_SPLIT
    -- then handed to tar entirely. The total condensate was sized as
    -- though it were only the tar, and then all of it was called tar.
    -- Both too little liquid and too much of it tar, at once.
    --
    -- 1.0 is the real breakdown:
    --     tar                      10 percent of mass   0.8 units
    --     wood vinegar, condensed  2.5 percent          0.2 units
    --     gas and water            the rest             vented
    --
    -- Raw pyroligneous acid is nearer 35 percent of a log, but it is
    -- roughly 90 percent water. Modelling it neat would put 2.8 units
    -- of vinegar against 0.8 of tar and hand DYE_MAGENTA a bucket of
    -- 1500. This models usable product, not raw distilate, which is
    -- also what a real charcoal burner sold.
    --
    -- THE CEILING THAT SIZES THIS
    --
    -- A reaction declares ONE output container per liquid slot, so the
    -- ghost can pay at most one package per job. A currency accruing
    -- more per run than its package holds banks the surplus forever
    -- and never drains, which is not smoothing, it is mass quietly
    -- disappearing.
    --
    -- So per-run accrual must sit UNDER one package. At 1.0 with the
    -- split below, one log gives 0.8 tar against a 1 unit package:
    -- pays four runs in five, bank oscillates, nothing lost. The empty
    -- fifth run still pays 2 charcoal plus char, cinder and ash, so it
    -- never reads as failure.
    --
    -- KNOWN BOUND: a fort retorting only very dense wood, above about
    -- density 750, accrues over 1.0 per log and would bank without
    -- draining. Mixed feedstock stays clear of it. The same bound
    -- applies to large corpses through FLUID_CLASS.FLESH at 2.5.
    FLUID_ANCHOR_UNITS = 1.0,
    LIQUID_UNIT        = 150,

    -- ---- PACKAGE SIZE, PER CURRENCY ----
    -- How many LIQUID_UNITs one container of this currency holds.
    -- Producers mint exactly this and consumers ask exactly this.
    -- Keys are material keys WITHOUT the module prefix, same as
    -- FLUID_SPLIT.
    --
    -- WHY SIZES MUST AGREE
    --
    -- DF fills a reagent slot from ONE container and picks without
    -- regard to size. Three 150 buckets never satisfy a 450 ask, and a
    -- 450 job that reaches a 150 bucket first just fails. Partial
    -- consumption is not a way out either: taking 150 from a 450
    -- bucket leaves a 300 bucket, which is a container nothing can
    -- use. A consumer takes the whole package or the currency is
    -- broken.
    --
    -- HOW FAR THAT SPREADS: THE GROUP RULE
    --
    -- Only materials that can reach the SAME reagent slot must agree.
    -- That set is the transitive closure over consumed reaction
    -- classes, not the whole module. Today there are six such groups
    -- and five of them hold one material each, so those are free.
    --
    -- The exception is the tar group. BURN_CARBON_BLACK consumes the
    -- umbrella class TAR, which wood tar, coal tar, shale oil and bone
    -- oil all carry, so a slot asking TAR can be handed any of the
    -- four and all four must share a size. If that is ever unwanted,
    -- point BURN_CARBON_BLACK at TAR, TAR_COAL, TAR_SHALE and
    -- TAR_BONE explicitly; the group dissolves and each can size
    -- itself.
    --
    -- WHY EVERY LIQUID PACKAGE IS 1 UNIT
    --
    -- The boil takes its tar as two whole jugs, written as two
    -- reagent pairs. DF fills one slot from one container and never
    -- aggregates liquid across jugs, so cost is expressed as pair
    -- count, never as a larger quantity on one slot. Packages stay
    -- at 1 unit so charring payouts land at a visible cadence.
    --
    -- COUPLED CONSTANT
    --
    -- TAR_UNITS_PER_PITCH must equal pairs times package size for
    -- the boil (currently 2 x 1). Check 13 prices the tar round
    -- trip off it, so moving the JSON without this constant, or the
    -- reverse, mis-prices the curve silently.
    LIQUID_STANDARD = {
        -- TAR is the single organic tar. Wood, plant and peat tar
        -- were three names for one liquid with one behaviour, and
        -- the player paid for the distinction in menu clutter and
        -- stockpile noise without getting anything back. The source
        -- is still visible: it is the reaction that made it.
        TAR          = 1,
        TAR_COAL     = 1,
        OIL_CRUDE    = 1,
        OIL_BONE     = 1,
        AMMONIA      = 1,
        VINEGAR_WOOD = 1,
        OIL_TALLOW   = 1,
        VINEGAR_PLANT = 1,
        ANILINE      = 1,
        BENZENE       = 1,
        CREOSOTE     = 1,

        -- The three crude fractions. One unit each, same as every
        -- other liquid, so a fraction can share a reagent slot with
        -- anything else without the group rule above being violated.
        NAPHTHA      = 1,
        KEROSENE     = 1,
        OIL_LUBRICANT     = 1,

        -- Tar's light fraction, missing until the drain reached the
        -- still. Payouts never needed it, since the ghost falls back to
        -- LIQUID_STANDARD_DEFAULT, but this table is also the drain's
        -- whitelist, so turpentine could be banked and never drained.
        TURPENTINE   = 1,
    },
    LIQUID_STANDARD_DEFAULT = 1,

    -- Fluid per class, as a multiple of wood at the same size. Flesh
    -- renders, so it is fluid heavy where it is charcoal poor. Starting
    -- positions, like CLASS above; move them freely.
    --
    -- FLESH sits at 3/4 so the reference dwarf corpse, size 6000,
    -- accrues 0.82 a job, the log's own cadence. A buffalo still
    -- lands over one package and banks; the surplus drains through
    -- smaller corpse jobs, the same known bound as very dense wood.
    --
    -- PEAT at 1.0 funds its own split row: a dried peat boulder
    -- accrues 0.71 a job, wet peat 0.20 after the moisture cut. At
    -- the old 0.000 both peat retorts bottled nothing while their
    -- vessels still hauled, which read in game as a dead reaction.
    FLUID_CLASS = {
        WOOD    = 1.000,
        PLANT   = 2.000,
        FLESH   = 3 / 4,
        FAT     = 3.000,
        BONE    = 1.000,
        LEATHER = 0.500,
        HAIR    = 0.250,
        PEAT    = 1.000,
        CHARRED = 0.000,

        -- ---- THE COALS, AND THE INVERSION ----
        -- Wood is the 1.000 because real wood tar runs about a tenth
        -- of dry mass. Coal is measured against that and comes apart
        -- in the OPPOSITE direction from the solid side:
        --
        --   bituminous  3 to 4.5 percent tar   ->  0.400
        --   lignite     8 to 15 percent tar    ->  1.100
        --
        -- Lignite gives HALF the solid fuel and nearly THREE TIMES
        -- the liquid. That is not a balance choice, it is the whole
        -- difference between the two coals: bituminous is the coking
        -- coal and lignite is the tar coal. The German brown coal tar
        -- industry ran on exactly that, and it is what gives the coal
        -- tar branch, benzene through aniline, a feedstock worth
        -- mining rather than a trickle off the good coal.
        --
        -- MINERAL STAYS 0.000 and now means something narrower. It
        -- was the reason R11 listed this table as a prerequisite: a
        -- coal classified MINERAL would have bottled nothing while
        -- its vessels still hauled, which is the dead reaction peat
        -- used to be. Ranking coal at L2 moved it off MINERAL
        -- entirely, so the zero here is no longer in the coal path
        -- and is once again just the fallback for unranked stone.
        COAL_BITUMINOUS = 0.400,
        COAL_LIGNITE    = 1.100,

        -- Oil shale sits UNDER lignite on purpose. By mass its oil
        -- fraction is comparable, but a boulder is 2200 dense against
        -- lignite's 1250, so equal weights here would make the
        -- fallback rock beat the tar coal at its own job.
        SHALE_OIL       = 0.700,

        -- The inverse of lignite, and the reason anthracite is a
        -- burning coal rather than a chemical feedstock. Two to
        -- five percent volatile matter against lignite's forty.
        COAL_ANTHRACITE = 0.100,

        MINERAL = 0.000,
        INERT   = 0.000,
    },

    -- Which liquid a class condenses to, and in what proportion. Keys
    -- are material keys WITHOUT the module prefix; the ghost matches
    -- them against the reaction's liquid product slots by mat_id.
    -- Botanical feed gives wood tar; animal feed renders oil and the
    -- ammonia that nitrogenous matter throws. A class whose liquid
    -- has no slot on the running reaction still banks it, to be paid
    -- by one that does.
    FLUID_SPLIT = {
        -- 4:1 is the mass ratio of tar to condensed wood vinegar, and
        -- it is what finally gives bucket_2 on the wood retorts
        -- something to pay. That slot has never once paid out, because
        -- wood credited vinegar nothing. It is also the module's only
        -- source of ACID, which MAKE_ANILINE and DYE_MAGENTA consume.
        WOOD    = { TAR = 4 / 5, VINEGAR_WOOD = 1 / 5 },
        -- Each feed names its own liquids now; crediting plant tar
        -- as wood's was the wrong pocket. Peat is nitrogenous, so
        -- its row funds the ammonia its retorts bottle. Fat renders
        -- tallow oil. Keratin throws Dippel's oil, which IS bone
        -- oil, so HAIR paying a quarter into that pool is the
        -- chemistry, not a substitution.
        PLANT   = { TAR = 4 / 5, VINEGAR_PLANT = 1 / 5 },
        PEAT    = { TAR = 3 / 5, VINEGAR_PLANT = 1 / 5,
                    AMMONIA = 1 / 5 },
        FLESH   = { OIL_BONE = 3 / 4, AMMONIA = 1 / 4 },
        FAT     = { OIL_TALLOW = 1 },
        BONE    = { OIL_BONE = 1 / 2, AMMONIA = 1 / 2 },
        LEATHER = { OIL_BONE = 1 / 2, AMMONIA = 1 / 2 },
        HAIR    = { AMMONIA = 3 / 4, OIL_BONE = 1 / 4 },

        -- ---- THE COALS ----
        -- Coal tar and ammonia liquor, which is what a coke oven
        -- actually condenses. Coal was the world's nitrogen supply
        -- before Haber and the liquor is the reason, so ammonia is a
        -- real share here and not a garnish.
        --
        -- BY NH3 MASS the true ratio is nearer twelve to one, and
        -- these rows deliberately do not model it. Ammonia arrives as
        -- a DILUTE AQUEOUS liquor, so by bottled volume, which is
        -- what a jug measures, it is a large fraction. Same reasoning
        -- that put condensed wood vinegar at a fifth rather than at
        -- raw pyroligneous acid's share.
        --
        -- LIGNITE THROWS MORE LIQUOR AND A BIGGER SHARE OF IT,
        -- because a third of it is water before it ever sees a
        -- retort. It still out-tars bituminous two to one on the
        -- strength of its FLUID_CLASS, so the smaller tar share here
        -- does not undo the inversion.
        COAL_BITUMINOUS = { TAR_COAL = 4 / 5, AMMONIA = 1 / 5 },
        COAL_LIGNITE    = { TAR_COAL = 3 / 5, AMMONIA = 2 / 5 },

        -- Retorting shale gives oil and an ammonia bearing water,
        -- same two stream shape as bituminous. OIL_CRUDE must appear
        -- in the readout's LIQUIDS the moment this line exists or it
        -- banks where nobody can see it, which is the bug coal tar
        -- sat in for a week.
        SHALE_OIL       = { OIL_CRUDE = 4 / 5, AMMONIA = 1 / 5 },

        -- What little comes off is nearly all ammonia liquor. The
        -- tar fraction of anthracite is close to nothing, which is
        -- the whole reason it was never a coal tar feedstock.
        COAL_ANTHRACITE = { AMMONIA = 3 / 4, TAR_COAL = 1 / 4 },
    },

    -- Tar packages per pitch boulder: the ghost's PITCH profile credits
    -- a tar's purse one over this for every package a boil or a
    -- distillation takes (making-fuel-ghost.lua, PITCH). It no longer
    -- prices check 13, whose tar, pitch and coke round trip went with
    -- the COKE_PITCH reaction; check 13 now prices the tank route.
    -- One, because one is the size the proportions were already
    -- asking for. Real tar fractions run 5 to 15 percent of feed,
    -- which against a 12 unit coal boulder and an 8 unit log lands
    -- every feedstock in the module near a single unit. A 3 unit
    -- package could only be filled by inflating yields threefold above
    -- their real fractions, or by paying nothing two runs in three.
    --
    -- Mass loss lives in the choice of reaction rather than here: a
    -- boil keeps only the pitch and vents the light ends, while a
    -- distillation such as DISTIL_TAR recovers them as fractions and
    -- credits the same pitch (FRACTION SPLIT below).
    TAR_UNITS_PER_PITCH = 3,
        -- ---- FRACTION SPLIT ----
    -- What a distillation actually separates a package into. Keyed by
    -- REACTION, not by feedstock, so two reactions working the same
    -- liquid can separate it differently.
    --
    -- CONSERVATION IS THE WHOLE POINT. These reactions used to pay a
    -- flat one of every fraction per cycle, so DISTIL_TAR_COAL turned
    -- ONE package of coal tar into three fractions plus a third of a
    -- pitch: 3.33 out of 1.00 in. A still separates a liquid into its
    -- parts. It cannot make more liquid than went in.
    --
    -- TAR_UNITS_PER_PITCH fixes the residue at a third of a package,
    -- so every set below sums to 2/3 and the whole thing lands on
    -- exactly 1.000. Shares are real cut yields normalised into that
    -- budget: crude runs naphtha 30, middle distillate 30 and lubricant 25
    -- by volume; coal tar runs light oil 5, middle 10 and heavy 10;
    -- wood tar runs turpentine 10 and creosote 30.
    --
    -- A fraction slot with no entry here falls back to paying one per
    -- cycle, which is the old behaviour, so an unlisted reaction is
    -- wrong rather than broken.
    FRACTION_SPLIT = {
        DISTIL_OIL = {
            NAPHTHA         = 0.235,
            KEROSENE        = 0.235,
            OIL_LUBRICANT        = 0.196,
        },
        DISTIL_TAR_COAL = {
            BENZENE      = 0.133,
            NAPHTHALENE = 0.267,
            CREOSOTE    = 0.167,
            ANTHRACENE  = 0.267,
        },
        DISTIL_TAR = {
            TURPENTINE = 0.167,
            CREOSOTE   = 0.500,
        },
    },
    -- ---- CHECK 13: THE TANK ROUTE ----
    -- What the retort's liquids are worth as tank fuel, so check 13
    -- prices the route the tanks actually pay. The three energies are
    -- MIRRORED from making-fuel-tank-fuel.lua's FUEL_MJ_PER_L and MUST
    -- match it. Kerosene is its anchor, one unit worth one job, so a
    -- unit of any fuel is worth its MJ per litre over kerosene's, in
    -- jobs. Mirrored rather than read, the way the bank readout mirrors
    -- its constants: the tank script loads this file, not the reverse.
    KEROSENE_MJ_PER_L    = 36.96,
    TAR_MJ_PER_L         = 30.24,
    METHANOL_MJ_PER_L    = 17.94,
    -- DISTIL_METHANOL takes two packages of vinegar for one of
    -- methanol. MUST match the JSON.
    METHANOL_PER_VINEGAR = 1 / 2,
    -- How far the retort may out-fuel the furnace (check 13). It is
    -- allowed to win: a closed retort keeps the liquids an open burn
    -- throws away, and pays for that in plant: jugs, tanks, an atomiser
    -- and a still. Past this ceiling the furnace has no reason to exist.
    RETORT_ROUTE_CEILING = 1.25,

    -- ---- CANOPY, THE COMPLETED FELL ----
    -- Fell forensics, three species, exact to the tile: vanilla
    -- pays one log per TRUNK tile and deletes everything else the
    -- grower placed. The completed fell drops the rest IN KIND,
    -- because a source is the map's endowment, not a conversion:
    -- quantities are LINEAR in the tree's own tiles and the value
    -- law never rations them. Rich forest, rich wood. Scrag map,
    -- you struggle. The shape restrictions live downstream, on
    -- conversions and recovery, exactly where the exploits live.
    --
    -- Each pin is the wood physically in one tile of that kind,
    -- expressed as the item it drops as. All three are feel dials
    -- as much as physics; retuning them moves abundance, never the
    -- relationships between forms.
    --
    -- A heavy limb tile holds a quarter of a trunk tile's wood, so
    -- four heavy tiles land one extra log of the tree's own species.
    HEAVY_TILE_LOGS = 1 / 4,

    -- A light branch tile is one armful of branchwood: one branch
    -- item. Halve it if big broadleafs drown the ground in items.
    LIGHT_TILE_BRANCHES = 1,

    -- Twig wood is measured, kept, and denominated as BRANCHES:
    -- four twig tiles bundle into one branch item, and whatever
    -- falls short of four is lost to the forest floor, floored on
    -- purpose, no bank. A fell is species pure and unloopable, so
    -- the scraps cannot be farmed, and a forest floor that keeps
    -- the odd armful of twigs is the honest picture.
    --
    -- Four is the ladder clean bundle: it prices a twig tile at
    -- 312 / 4 = 78 volume, within seven percent of the original
    -- 1/60 log estimate, and the difference is smaller than the
    -- question of what a twig tile even weighs.
    TWIG_TILES_PER_BRANCH = 4,

    -- Counts round to nearest per tier per tree, no bank. A fell is
    -- species pure and unloopable, so half an item of error per
    -- tier per tree cannot be farmed, and banking across fells
    -- would mix species into a material-less balance.
    --
    -- Must match the declared size of MAKING_FUEL_BRANCH in
    -- making_fuel_tools.json, and now does. 312 is 4 x 78: one
    -- branch is exactly two kindling in value, half a charcoal at
    -- reference wood, on the quarter ladder, and two branches
    -- split to exactly five kindling.
    BRANCH_ITEM_VOLUME = 312,

    -- Mushroom cap species overload the branch tile bits with cap
    -- wall, ramp and floor, so their counts are cap anatomy, not
    -- branch wood. They mint nothing until cap flesh becomes its
    -- own material. The spawner checks TREE_HAS_MUSHROOM_CAP.
    CAP_TREES_MINT_BRANCHES = false,

    -- ---- PAYOUT GRANULARITY ----
    -- true  pays a cinder as soon as the bank can afford one.
    -- false pays only whole charcoal and banks everything below it,
    --       which restores the old output shape.
    -- Neither loses value. It only changes the form.
    PAY_CINDERS = true,

    -- ---- ROUNDING ----
    -- Tolerance on the whole product test. Float arithmetic lands
    -- values a hair under a whole number and floor turns any
    -- shortfall into a lost product.
    EPSILON = 0.01,

    -- ---- MEASURED WASTE ----
    -- DF models material loss on every carpentry and masonry job and
    -- never gives any of it back. A log is 5000 and a door is 3000, so
    -- 2000 goes nowhere. Scroll rollers lose 4990 of a 5000 log.
    --
    -- WASTE_RECOVERY is the fraction of that loss which returns as a
    -- byproduct, and it is LOW for a reason that is NOT clutter.
    --
    -- THE SIZE CURVE IS SUB ADDITIVE. A door keeps 60 percent of a log's
    -- volume but 77 percent of its VALUE, because many small things are
    -- worth more than one big thing of the same total volume. Handing
    -- back true waste therefore inflates rather than conserves:
    --
    --   recovery 1.00 -> door plus sawdust is 303 percent of the log
    --   recovery 0.50 -> 181 percent
    --   recovery 0.25 -> 129 percent
    --   recovery 0.12 ->  95 percent
    --
    -- So this is the brake on sub additive gain. Clutter is a side
    -- effect, not the reason. Raising it past about 0.20 makes furniture
    -- a better fuel source than splitting, which inverts the whole
    -- intended ordering. The curve check enforces that.
    --
    -- At SIZE_EXPONENT 1.0 the curve is perfectly additive and 1.0 here
    -- would be exactly conserving. That is the only setting where full
    -- recovery is honest.
    WASTE_RECOVERY = 0.12,

    -- Clutter ceiling per job. Excess banks and comes out later, so
    -- nothing is lost. Value is controlled by WASTE_RECOVERY, not here.
    --
    -- RAISED FROM 4, because at 4 it was not a ceiling, it was a
    -- governor. MEASURED: one MakeTool on granite wanted 5 gravel,
    -- took 4, and left 888 banked against a 750 unit, so the purse was
    -- holding more than a whole item it was not allowed to pay. Every
    -- job after that adds more than the cap can clear and the declared
    -- recovery quietly stops being the real one.
    --
    -- The real output sets the number now. This only catches a runaway,
    -- and it says so in the log when it bites. Per class override is
    -- max_items inside a LOSS_STREAMS entry.
    WASTE_MAX_ITEMS = 12,

    -- ---- BYPRODUCT VALUE RECOVERY, REPLACES THE VOLUME MINT ----
    -- WASTE_RECOVERY above is the LEGACY knob: the hijacker still
    -- mints byproducts by VOLUME, and 0.12 was tuned to compensate
    -- for the sub additive inflation that method causes. The
    -- compensation only holds at door sized losses; the true value
    -- recovery drifts with loss size and with unit size.
    --
    -- These are the honest replacement, live once the hijacker
    -- round lands, after which WASTE_RECOVERY retires. The recovery
    -- is a fraction of the VALUE lost:
    --
    --   recovered = BYPRODUCT_RECOVERY * yield(lost volume)
    --
    -- One meaning at every loss size, and unit sizes become pure
    -- granularity: halving the sawdust size doubles the pieces at
    -- identical value, so clutter and balance finally separate.
    -- Check 10 computes the structural ceiling from the curve
    -- itself; 0.12 keeps the processing tax obvious.
    BYPRODUCT_RECOVERY = 0.12,

    -- How the recovered value splits: this fraction arrives as
    -- bark, the rest as sawdust. Debarking happens during working,
    -- so bark belongs to the loss stream, not a separate mint, and
    -- the old two list divergence between bark jobs and sawdust
    -- jobs dissolves in the hijacker round.
    BYPRODUCT_BARK_SHARE = 1 / 2,

    -- Must match the declared sizes in making_fuel_tools.json.
    -- Both sit at 78, the kindling size, so one sawdust and one
    -- bark are one kindling of value each, a quarter charcoal at
    -- reference wood: the whole wood byproduct family speaks in
    -- quarters and the banks barely carry dust.
    SAWDUST_VOLUME = 78,
    BARK_VOLUME    = 78,

    -- ---- LOSS STREAMS BY FEEDSTOCK CLASS ----
    -- What a job destroys and does not put into its product has to go
    -- somewhere. Vanilla drops it. This says what falls in the
    -- workshop instead, per class of feedstock.
    --
    -- The measuring is already general: the hijacker reads total input
    -- volume, reads output volume, and the difference is the loss.
    -- Only WHAT the loss becomes and HOW it is priced were pinned to
    -- wood. This table is both.
    --
    -- ---- FORM VERSUS SUBSTANCE ----
    -- A stream with no mat key INHERITS the feedstock's material, the
    -- way bark and sawdust already do. The tool names the form and the
    -- material names the substance, so one DUST tool is microcline
    -- dust, ruby dust and bone dust depending on what went in, and the
    -- species carries through to whatever consumes it later.
    --
    -- A stream WITH a mat key is a substance the input was not. Scale
    -- is iron oxide, not iron, and slag is the gangue rather than the
    -- ore, so neither can inherit and both name their material.
    --
    -- ---- TWO PRICING MODES, AND THEY MUST NOT SHARE A BANK ----
    --
    --   VALUE   the loss goes through yield() on the material class,
    --           so a dense hardwood pays more than a softwood, and the
    --           bank holds CHARCOAL VALUE. Correct only for things
    --           that burn, because yield() is the fuel curve and
    --           nothing else.
    --
    --   VOLUME  the loss is counted as raw volume and the bank holds
    --           volume. Correct for everything recovered as mass.
    --           Pricing a rock on the fuel curve would mint free fuel,
    --           which is the exact trap the old BANK_WASTE keys fell
    --           into, so the two modes get separate bank prefixes.
    --
    -- recovery is a fraction of the LOSS, not of the input: the share
    -- that lands somewhere collectable rather than becoming heat,
    -- smoke or sweepings. Setting it to 0 turns a whole class off
    -- without touching the per kind switches.
    --
    -- vol must match the declared size in the tools JSON. It is pure
    -- granularity: halving it doubles the pieces at identical worth.
    --
    -- FIRST PASS RATES. The structure is the deliverable; the numbers
    -- are a starting point and are meant to be argued with once there
    -- is a fort to watch.
    LOSS_STREAMS = {
        -- Unchanged behaviour, moved here so there is one source of
        -- truth. BYPRODUCT_RECOVERY, BYPRODUCT_BARK_SHARE,
        -- SAWDUST_VOLUME and BARK_VOLUME above become legacy the way
        -- WASTE_RECOVERY did, read by nothing once the hijacker lands.
        WOOD = {
            mode = 'VALUE', recovery = 0.12,
            streams = {
                { kind = 'BARK',    share = 0.50, vol = 78 },
                { kind = 'SAWDUST', share = 0.50, vol = 78 },
            },
        },

        -- The largest loss in the game. A 10000 boulder becomes four
        -- blocks and the rest stops existing. Dressing stone makes
        -- both coarse spalls and fine dust and all of it is still on
        -- the floor, so recovery is high and the split is two ways.
        STONE = {
            mode = 'VOLUME', recovery = 0.60,
            streams = {
                { kind = 'GRAVEL', share = 0.65, vol = 750 },
                { kind = 'DUST',   share = 0.35, vol = 400 },
            },
        },

        -- Cutting rough throws away most of the stone and every bit
        -- of it is abrasive. Nothing burns or evaporates, so recovery
        -- is high and it is all fines.
        GEM = {
            mode = 'VOLUME', recovery = 0.60,
            streams = {
                { kind = 'DUST', share = 1.00, vol = 400 },
            },
        },

        -- Smelting. Slag is the gangue and the spent flux fused
        -- together, and it is the honest answer to where the rest of
        -- an ore boulder went. Named rather than inherited: it is not
        -- the ore any more.
        -- INHERITS THE ORE. Named slag was a substance with no
        -- properties, and tetrahedrite slag tells you what the heap
        -- came out of, which is the whole point of recovering it.
        -- ---- NAMED, NOT INHERITED, AND THE REASON IS A LIVE FILTER ----
        -- Inheriting reads better: tetrahedrite slag says what the
        -- heap came out of. It also costs the material's reaction
        -- classes, because a tool made of tetrahedrite carries
        -- TETRAHEDRITE's classes and not SLAG, AGGREGATE, POZZOLAN.
        --
        -- That is not hypothetical. A reaction in
        -- making_fuel_reactions_other.json already filters
        -- { type = BOULDER_ANY, reaction_class = POZZOLAN } beside a
        -- FLUX boulder, and GRAVEL and VOLCANIC_SAND both carry
        -- AGGREGATE on the concrete side. Inherited slag silently
        -- stops matching all of it.
        --
        -- SLAG IS THE ONE FORM WHERE INHERITING COSTS FUNCTION.
        -- Scrap and dust need it: blue steel scrap goes back to the
        -- smelter AS blue steel, and bone meal is not stone dust.
        -- None of slag's uses, aggregate, pozzolan, fuel feedstock,
        -- silica source, care which ore it came from. So it buys
        -- flavour and pays in the only thing that made it reachable.
        --
        -- The TOOL is WASTE and the MATERIAL is SLAG, so it reads
        -- "slag waste": the same trick as "fresh" plus mash, with the
        -- substance on the material where the classes live and a
        -- reusable form on the tool.
        ORE = {
            mode = 'VOLUME', recovery = 0.50,
            streams = {
                { kind = 'WASTE', share = 1.00, vol = 1200,
                  mat = 'INORGANIC:MAKING_FUEL_SLAG' },
            },
        },

        -- Forging. Three wastes, ALL INHERITING THE METAL, because a
        -- byproduct that throws away what it came from throws away the
        -- only information worth having. Blue steel scrap is worth
        -- knowing about; a generic flake is not.
        --
        -- Scrap is trimmed stock and goes back to the smelter whole.
        -- Dust is the fine loss off grinding and the oxide off hot
        -- metal under the hammer, which is why a smithy floor is
        -- black. Slag is what the forge fire leaves behind.
        --
        -- The fixed SCALE material is gone. It was a substance with no
        -- properties worth reading, and DUST carrying the real metal
        -- says strictly more.
        -- RECOVERY RAISED FROM 0.25, weighted hard toward scrap. Not a
        -- fudge to make the numbers look nicer: metal and stone waste
        -- do not behave the same way. Dressed stone becomes dust and
        -- spall that stays on the floor, which is why STONE sits at
        -- 0.60. Trimmed metal is stock a smith keeps, sorts and sends
        -- back to the smelter, so its recoverable fraction is HIGHER
        -- than stone's, not lower.
        --
        -- The weighting follows the same logic. Offcuts are nearly all
        -- recoverable so scrap takes the bulk. Scale is a genuine but
        -- thin oxide layer. Forge slag comes off the fuel rather than
        -- the stock and is mostly ash, which is why a forge is a poor
        -- slag source and a smelter is a good one.
        --
        -- At 520 lost on a battle axe that is about one scrap per
        -- weapon, dust every sixth, slag every fiftieth.
        -- ---- FORGING, AND SLAG IS NOT ONE OF ITS PRODUCTS ----
        -- Slag is what separates from ORE during smelting. A forge does
        -- not smelt. Its fire leaves clinker, which is fused fuel ash
        -- rather than worked stock, so slag here was wrong and is gone.
        --
        -- DUST IS THE BULK, not scrap. Forging is forming rather than
        -- cutting: a smith moves a billet into shape instead of
        -- machining it down, so offcuts amount to a tang end or a
        -- sprue. The real losses are scale flaking off at every heating
        -- cycle, which is the black on a smithy floor, and grinding and
        -- filing swarf during finishing. Both are fine particulate.
        --
        -- Recovery is 0.55, higher than stone's 0.60 might suggest it
        -- should be, and deliberately so: trimmed metal is stock a
        -- smith keeps, sorts and sends back to the smelter, while
        -- dressed stone gets swept up. Both fractions here are
        -- genuinely collectable.
        --
        -- Scrap still appears as ITEMS slightly more often than dust
        -- despite taking less of the volume, because its unit is 150
        -- against dust's 400. That is granularity, not weighting.
        --
        -- NOT ACCURATE FOR MeltMetalObject, which shares this class.
        -- Remelting yields dross skimmed off the melt, with no swarf
        -- and no offcuts at all. Its own class when that matters.
        METAL = {
            mode = 'VOLUME', recovery = 0.55,
            streams = {
                { kind = 'DUST',  share = 0.60, vol = 400 },
                { kind = 'SCRAP', share = 0.40, vol = 150 },
            },
        },

        -- Cutting and blowing both leave trim, and remelting cullet
        -- predates the industry, so this feeds the glass furnace back.
        -- Inherited, because broken green glass is still green glass.
        GLASS = {
            mode = 'VOLUME', recovery = 0.35,
            streams = {
                { kind = 'CULLET', share = 1.00, vol = 150 },
            },
        },

        -- VALUE mode from here down: all three burn, so the fuel
        -- curve is the right measure and the bank can hold charcoal
        -- value like the wood streams do.
        --
        -- Trimmings off cutting a hide to shape. The hook is hide
        -- glue, and GLUE is already a declared material here.
        LEATHER = {
            mode = 'VALUE', recovery = 0.30,
            streams = {
                { kind = 'SCRAP', share = 1.00, vol = 150 },
            },
        },

        -- Thrums are the waste ends left on the loom, lint is the fly
        -- off spinning. One form covers both, and the material says
        -- which cloth it was. The hook is tinder, which exists.
        CLOTH = {
            mode = 'VALUE', recovery = 0.25,
            streams = {
                { kind = 'SCRAP', share = 1.00, vol = 150 },
            },
        },

        -- Carving bone, shell and horn to shape. Bone meal is
        -- literally bone dust, so it is the DUST form inheriting the
        -- bone. The hook is bone char, which is carbon and ours, and
        -- bone ash for cupellation later.
        BONE = {
            mode = 'VALUE', recovery = 0.40,
            streams = {
                { kind = 'DUST', share = 1.00, vol = 400 },
            },
        },
    },

    -- ---- BYPRODUCT SWITCHES ----
    -- Per byproduct, off means the value is simply not recovered. Nothing
    -- redirects and nothing breaks: a log still yields what a log yields,
    -- you just stop collecting the shavings. Turning sawdust off drops
    -- furniture recovery from 95 percent of a log to 77.
    --
    -- These exist because "I hate sawdust piles" is a reasonable
    -- preference and a mod that cannot accommodate it gets uninstalled
    -- instead of adjusted.
    -- ---- UNIVERSAL FUEL ACCESS ----
    -- Off returns the module to vanilla behaviour: fuels must be
    -- charred to charcoal before any furnace accepts them.
    FUEL_ACCESS_ENABLED = true,

    -- The PRIMARY fuel class: the tag for furnaces that accept
    -- anything that burns. Every fuel material in the ecosystem
    -- carries it, and it is pushed onto builtin COAL at startup so
    -- vanilla charcoal and coke stay first class, then popped again
    -- at shutdown.
    --
    -- Deliberately NOT FUEL_MINERAL. That is a TIER, meaning coal,
    -- peat, oil shale and bitumen specifically, and a furnace
    -- widened to it would refuse wood, dung and everything else this
    -- module makes. Tiers narrow; the primary tag admits.
    --
    -- Any module that tags a material FUEL makes it burnable in
    -- every vanilla furnace. That is the whole cross module
    -- contract, and it needs no mat_id anywhere.
    FUEL_CLASS = 'FUEL',

    -- Per building overrides, for furnaces that should accept only
    -- part of the fuel economy. Keyed by the furnace_type or
    -- workshop_type NAME as DF spells it. Empty means every furnace
    -- takes the primary class.
    --
    -- Each entry may set a reaction class, an item type, or both.
    -- item_type is the EXACT gate: WOOD takes logs and nothing else,
    -- and furniture is a different item type so a bed can never be
    -- fed to the fire. The flags3.wood approach was tried and does
    -- not narrow a widened filter at all: it grabbed a dung pile.
    --
    -- Leave item_type nil for the universal slot. Fuel spans BOULDER
    -- (peat, char), BAR (charcoal, coke) and TOOL (dung, cinder),
    -- and one filter holds one item type, so anything meant to take
    -- all of them must stay open and gate on class instead.
    FUEL_CLASS_BY_BUILDING = {
        -- A wood furnace burns wood. Nothing else, by definition.
        FURNACE_WOOD = { item_type = 'WOOD' },

        -- Example tiers, off until wanted:
        -- SMELTER = { class = 'FUEL_MINERAL' },
        -- KILN    = { class = 'FUEL' },
    },

    -- Which item vector DF searches when filling a widened fuel
    -- filter. This is the field that decides whether the search can
    -- see anything but bars: left at BAR, peat boulders are invisible
    -- no matter how open the other fields are. IN_PLAY covers
    -- boulders, tools and bars. ANY drops the restriction entirely.
    FUEL_VECTOR = 'IN_PLAY',

    -- ---- BURN TIERS, FROM PHYSICS ----
    -- Two tiers, set by what temperature a fire of that fuel can
    -- reach, not by preference. Dung and straw fires run 700 to 900
    -- degrees: pottery, lime, ash. Iron wants 1300 sustained, which
    -- only carbonised fuel delivers; that gap is WHY charcoal
    -- exists. FUEL_MINERAL is not a tier: it stays the feedstock
    -- class for retorts, which is a different fact about a material
    -- than what its fire can do.
    FUEL_SMITH_CLASS = 'FUEL_SMELTING',

    -- Per building demands. An entry may set a class, an item type
    -- floor, or both; unlisted buildings take the primary FUEL
    -- class with no floor, which is the KILN's tier by omission:
    -- dung piles and peat boulders must both fit, so its item type
    -- stays open on purpose.
    --
    -- Two axes. The class says how hot the fuel's fire gets; the
    -- item type says whether the furnace can physically take it.
    -- The smith tier sets BAR because a forge is hand fed solid
    -- fuel: it keeps liquids, powders and furniture out no matter
    -- what class a future material carries. Where a fuel has the
    -- heat but the wrong form, add PROCESSING rather than widening
    -- the filter. Char finishes into charcoal bars through
    -- CHAR_CHAR_BOULDER, four per boulder, at the wood furnace.
    --
    -- The WOOD FURNACE is absent, correctly. Its reagents ARE the
    -- grade zero fuels, so it is tiered by construction, and none
    -- of its jobs post a coal filter to widen anyway.
    -- Keys are what DF's own enums return, verified live:
    --   furnace_type   Smelter, WoodFurnace, Kiln, GlassFurnace
    --   workshop_type  MetalsmithsForge
    -- Mixed case, not the all caps XML token names. Reading them
    -- out of df-structures gave SMELTER and GLASS, every lookup
    -- missed, and every furnace silently fell through to the
    -- primary class with no item floor. That is how a smelter ended
    -- up burning dung.
    --
    -- Kiln and WoodFurnace are absent on purpose: the kiln takes the
    -- primary tier by omission, and the wood furnace posts no fuel
    -- filter at all.
    -- Keys: vanilla buildings by the mixed case names DF's enums
    -- return, custom buildings by their RAW CODE, from any module
    -- (e.g. SOME_MODULE_SOME_FURNACE). No building is required to
    -- appear here: anything unlisted takes the primary class with
    -- no item floor, which is the universal kiln grade default.
    -- Entries exist only where physics demands a hotter fire or a
    -- specific form.
    -- ---- THE BULK TIER ----
    -- A filter demands one class and charcoal carries FUEL as well
    -- as FUEL_SMELTING, so the low grades need a name of their own
    -- or four fuel slots eat four charcoal bars. FUEL stays the
    -- union the menu key scans.
    FUEL_BULK_CLASS = 'FUEL_BULK',

    -- How many bulk fuels buy what one finished fuel buys. DERIVED,
    -- not chosen: the whole tree is base four. CINDERS_PER_CHARCOAL
    -- is 4, CHARCOAL_PER_BOULDER is 4, and KINDLING_VOLUME is picked
    -- precisely to make one kindling a quarter charcoal.
    --
    -- At four the kiln is exactly indifferent between burning four
    -- kindling and charring them into one charcoal and burning that,
    -- so charring stays the road to smelting grade rather than an
    -- efficiency play. At three, burning raw BEATS packing and
    -- CHAR_CINDERS becomes a loss the player is rewarded for
    -- skipping. Check 9 binds the two.
    FUEL_BULK_PER_SMELTING = 4,

    FUEL_TIERS = {
        Smelter          = { class = 'FUEL_SMELTING',
                             item_type = 'BAR' },
        GlassFurnace     = { class = 'FUEL_SMELTING',
                             item_type = 'BAR' },
        MetalsmithsForge = { class = 'FUEL_SMELTING',
                             item_type = 'BAR' },
    },

    BYPRODUCTS = {
        SAWDUST    = true,
        BARK       = true,
        BRANCH     = true,
        STRAW      = true,
        MASH       = true,
        CINDER     = true,
        -- Coal ash off the vanilla smelter coke jobs. Carries POZZOLAN,
        -- so it is also what Making Concrete sees; off means the
        -- smelter simply leaves nothing behind, as vanilla does.
        COAL_ASH   = true,

        -- ---- LOSS_STREAMS FORMS ----
        -- One switch per FORM, not per source, because the form is
        -- what the tool is: DUST off silences stone dust, gem dust and
        -- bone meal together. To silence one source rather than one
        -- form, set that class's recovery to 0 in LOSS_STREAMS.
        --
        -- Same contract as the wood pair above. Off means the value or
        -- volume is simply not recovered and nothing else changes: a
        -- player who does not want slag heaps still smelts exactly as
        -- before.
        DUST    = true,
        GRAVEL  = true,
        SCRAP   = true,
        CULLET  = true,
        WASTE   = true,

        -- Glass gall, the alkali scum skimmed off a melt before the
        -- glass is worked. Not a LOSS_STREAMS form: it is a spawn,
        -- because a glass job destroys nothing and there is no loss
        -- to take a share of. Off means a clear or crystal job simply
        -- leaves nothing behind, as vanilla does.
        GALL    = true,
        SCALE   = true,
        CLINKER = true,
    },

    -- Master switch for measured waste. Off returns the module to fixed
    -- byproduct counts, which is what it did before volumes were read.
    WASTE_ENABLED = true,

    -- ==========================================
    -- PACING AND SUBSYSTEMS
    -- ==========================================
    -- Not yields. These are here because they are player settings (see
    -- PLAYER SETTINGS at the top), and T is where the settings page
    -- writes a fort's choices. Each script reads its value from T at
    -- use; the reasoning behind each default stays in that script,
    -- beside the code it governs.

    -- Days before an untanned hide or scrap spoils. Reasoning in
    -- making-fuel-hide-rot.lua, THE ONE BALANCE NUMBER.
    HIDE_SPOIL_DAYS = 21,

    -- Days wet fuel takes to air dry. making-fuel-air-dry.lua.
    DRY_DAYS = 14,

    -- Average days between droppings per grazing animal, and the most
    -- dung items allowed on the map at once. Reasoning in
    -- making-fuel-pooper.lua, TUNING. POOP_DAYS must stay above the
    -- pooper's POLL_DAYS (3), or every animal drops on every poll.
    POOP_DAYS = 20,
    MAX_DUNG  = 240,

    -- Subsystems a player may switch off. making_fuel.lua starts each
    -- only when its switch is on, and the settings page starts or stops
    -- it on the spot.
    POOPER_ENABLED         = true,   -- dung from grazing animals
    AIR_DRY_ENABLED        = true,   -- wet fuel drying with time
    BRANCH_SPAWNER_ENABLED = true,   -- a felled tree's limb logs and branches
}

-- ==========================================
-- THE FUEL SLOT, DEFINED ONCE
-- ==========================================
-- A job filter is a FUEL SLOT when it serves no reagent AND looks like
-- fuel: DF's untouched BAR of builtin COAL, or one of the three fuel
-- tier classes a widened or surcharged slot carries.
--
-- Both halves are needed. Shape and class alone cannot tell the fuel
-- slot from a reagent that IS coal, and vanilla has two:
-- PIG_IRON_MAKING and STEEL_MAKING. MEASURED, making-fuel-filter-probe
-- build F1, pig iron job 10109 at smelter 5: the carbon reagent read
-- owner 2 and the fuel slot beside it owner -1, both BAR, both
-- FUEL_SMELTING once widened. reagent_index is DF's own record of which
-- reagent a filter serves, and a fuel slot serves none. Register L21.
--
-- Defined once because two scripts ask this question, the fuel access
-- layer and the ghost, and a second copy is how a fix lands in one and
-- not the other. Both call this. The widener in access.lua does not:
-- widen_coal_reagents takes every builtin coal filter that DOES name a
-- reagent first and swaps it for the module's coals, then the tier loop
-- widens what is left, the fuel slot, by shape: register L15.
--
-- Global, like everything else this file exports: reqscript hands back
-- the environment, and a local here would be invisible to both callers.
function is_fuel_slot(e)
    local hit = false
    pcall(function()
        if e.reagent_index >= 0 then return end
        if e.item_type == df.item_type.BAR
           and e.mat_type == df.builtin_mats.COAL then
            hit = true
            return
        end
        local rc = tostring(e.reaction_class)
        hit = (rc == T.FUEL_CLASS) or (rc == T.FUEL_SMITH_CLASS)
            or (rc == T.FUEL_BULK_CLASS)
    end)
    return hit
end

-- ==========================================
-- THE FACTOR PIPELINE
-- ==========================================
-- A valuation is a measured BASE multiplied by an ordered list of
-- FACTORS. Nothing more.
--
--   value = base * f1 * f2 * f3 ...
--
-- Every factor is a named function taking one context table and
-- returning a multiplier. A factor that has nothing to say returns
-- 1.0 and is invisible. A factor that is disabled is not called.
--
-- WHY THIS SHAPE
--
-- The old form hardcoded three factors into one expression, so adding
-- a fourth meant editing an expression four call sites depended on.
-- Skill, wear, quality, worker mood, workshop condition and anything
-- else DF tracks and ignores are all the same shape: read a property,
-- return a multiplier. As a list they cost one entry each and the
-- machine underneath never changes.
--
-- EVERY FACTOR BELOW EXCEPT class AND density SHIPS DISABLED. The
-- dials are installed and set to zero. Turning one on is a boolean,
-- not a build.
--
-- BUILT FOR RM
--
-- Nothing here knows what charcoal is. A module hands over a context
-- and gets back a number and a breakdown. What makes this Making Fuel
-- is the CLASS table and which property the caller measured, both of
-- which are data the caller supplies. When this moves to RM the
-- pipeline goes as is and the constants stay behind.
--
-- CONTEXT KEYS, all optional. A factor reads what it needs and
-- returns 1.0 when the key is absent, so a caller that cannot supply
-- something is never punished for it.
--
--   base      the measured quantity, already in anchor units
--   class     key into T.CLASS
--   density   solid_density of the material
--   skill     effective skill level of the worker, 0 to 20 or so
--   wear      item wear, 0 to 3
--   quality   item quality, 0 to 5
-- ==========================================

function factor_class(ctx)
    local k = ctx.class or 'WOOD'
    local m = T.CLASS[k]
    if not m then return 1.0, 'class ' .. tostring(k) .. ' unknown' end
    return m, 'class ' .. k
end

function factor_density(ctx)
    local d = ctx.density
    if not d or d <= 0 then return 1.0, 'no density' end
    local f = (d / T.REF_DENSITY) ^ T.DENSITY_EXPONENT
    if f < T.DENSITY_MIN then f = T.DENSITY_MIN end
    if f > T.DENSITY_MAX then f = T.DENSITY_MAX end
    return f, string.format('density %d', d)
end

-- ---- MOISTURE ----
-- ENABLED. Corrects density for water content.
--
-- Reads ctx.mat_token, the material token the caller resolved. No
-- token means no correction and a neutral 1.0, so any caller that
-- does not pass one gets exactly the old behaviour.
--
-- This is a separate stage rather than a tweak inside factor_density
-- on purpose. DENSITY_EXPONENT is 1.0, so scaling the density and
-- multiplying afterwards give the identical number today, but they
-- stop being identical the moment that exponent moves. Keeping it
-- separate means the breakdown says which correction did what, and
-- the exponent only ever applies to real density.
function factor_moisture(ctx)
    local tok = ctx.mat_token
    if not tok then return 1.0, 'no token' end

    -- First match wins, so the table's order is load bearing. See the
    -- warning on DRY_FRACTION: the dried keys must be tested before
    -- their wet stems or the stem swallows them.
    for _, row in ipairs(T.DRY_FRACTION) do
        if tok:find(row[1], 1, true) then
            return row[2], string.format('%.0f%% solids', row[2] * 100)
        end
    end

    return 1.0, 'dry'
end

-- ---- CARBONISATION RECOVERY ----
-- ENABLED. Corrects for how much of the dry feedstock survives as
-- solid fuel, which wood and coal do not do at remotely the same
-- rate.
--
-- Reads ctx.class, the same key CLASS reads, so a material the
-- classifier does not rank falls through to WOOD's rate and gets
-- exactly the old behaviour. Nothing had to change when this went
-- in for that reason.
--
-- Returns a RATIO against WOOD, not the raw fraction, because
-- ANCHOR_YIELD already has wood's recovery baked into it. Handing
-- back 0.25 would charge wood for its own anchor twice.
function factor_carbon(ctx)
    local tbl = T.CARBON_RECOVERY
    if not tbl then return 1.0, 'no recovery table' end
    local ref = tbl.WOOD
    if not ref or ref <= 0 then return 1.0, 'no wood reference' end
    local r = tbl[ctx.class or '']
    if not r then return 1.0, 'wood rate' end
    return r / ref, string.format('%.0f%% of dry mass', r * 100)
end

-- ---- SKILL ----
-- DISABLED. Installed because the data is there and unused: a
-- legendary wood burner and a dabbling one currently produce the same
-- charcoal from the same log.
--
-- Deliberately NOT hardwired to yield. This returns a multiplier, and
-- what a caller multiplies by it is the caller's business. The same
-- number could scale a yield, a byproduct chance, a job duration, or
-- nothing at all.
function factor_skill(ctx)
    local s = ctx.skill
    if not s then return 1.0, 'no worker' end
    local span = T.SKILL_CAP
    if span <= 0 then return 1.0, 'skill span zero' end
    local t = s / span
    if t < 0 then t = 0 end
    if t > 1 then t = 1 end
    local f = T.SKILL_FLOOR + (T.SKILL_CEILING - T.SKILL_FLOOR) * t
    return f, string.format('skill %d', s)
end

-- ---- WEAR ----
-- DISABLED. item.wear runs 0 to 3, fresh to falling apart. A barrel
-- coming to pieces holds less wood than a new one, and DF already
-- tracks exactly how far gone it is.
function factor_wear(ctx)
    local w = ctx.wear
    if not w or w <= 0 then return 1.0, 'unworn' end
    if w > 3 then w = 3 end
    local f = T.WEAR_STEPS[w] or 1.0
    return f, string.format('wear %d', w)
end

-- ---- QUALITY ----
-- DISABLED, and the one to think twice about. A masterwork chair is
-- not more wood than a plain one, so as a yield multiplier this is
-- wrong. It is installed because quality is more useful as a GATE
-- than a scale: a caller can read the multiplier, see it is zero, and
-- refuse the job rather than burn an artifact.
function factor_quality(ctx)
    local q = ctx.quality
    if not q then return 1.0, 'no quality' end
    if q < 0 then q = 0 end
    if q > 5 then q = 5 end
    local f = T.QUALITY_STEPS[q] or 1.0
    return f, string.format('quality %d', q)
end

-- ---- THE REGISTRY ----
-- Order is applied order. It does not matter for multiplication, but
-- it decides the order of the breakdown, so it is kept in the order a
-- reader would expect. A module adding its own factor appends here.
-- Nothing else changes.
FACTORS = {
    { name = 'class',   fn = factor_class,   enabled = true  },
    { name = 'density', fn = factor_density, enabled = true  },
    { name = 'moisture',fn = factor_moisture,enabled = true  },
    { name = 'carbon',  fn = factor_carbon,  enabled = true  },
    { name = 'skill',   fn = factor_skill,   enabled = false },
    { name = 'wear',    fn = factor_wear,    enabled = false },
    { name = 'quality', fn = factor_quality, enabled = false },
}

-- ==========================================
-- EVALUATE
-- ==========================================
-- The whole service. Takes a context, returns value and a breakdown.
--
-- The breakdown is a list of { name, mult, note } for every factor
-- that ran, which is what makes a wrong number diagnosable without
-- adding print statements to arithmetic.
--
-- base is the measured quantity in ANCHOR UNITS, meaning the caller
-- has already divided by the anchor and applied the size curve. That
-- split is deliberate: measuring belongs to whatever is being
-- measured, and a module measuring something other than volume should
-- not have to fight a wood-shaped exponent.
-- ==========================================
function evaluate(ctx)
    ctx = ctx or {}
    local value = ctx.base or 0
    local parts = {}

    for _, f in ipairs(FACTORS) do
        if f.enabled then
            local mult, note = 1.0, nil
            local ok = pcall(function() mult, note = f.fn(ctx) end)
            if not ok or type(mult) ~= 'number' then
                mult, note = 1.0, 'factor errored'
            end
            value = value * mult
            table.insert(parts,
                { name = f.name, mult = mult, note = note })
        end
    end

    return value, parts
end

-- Formats a breakdown for a log line. Kept here rather than in each
-- consumer so every module's output reads the same way.
function explain(parts)
    local out = {}
    for _, p in ipairs(parts or {}) do
        table.insert(out, string.format('%s x%.3f', p.name, p.mult))
    end
    return table.concat(out, ' ')
end

-- ==========================================
-- DENSITY FACTOR
-- ==========================================
-- Returns 1.0 for an unreadable density rather than nil, so a missing
-- field costs the reference yield instead of silently zeroing an item.
-- ==========================================
function density_factor(density)
    if not density or density <= 0 then return 1.0 end
    local f = (density / T.REF_DENSITY) ^ T.DENSITY_EXPONENT
    if f < T.DENSITY_MIN then f = T.DENSITY_MIN end
    if f > T.DENSITY_MAX then f = T.DENSITY_MAX end
    return f
end

-- ==========================================
-- YIELD
-- ==========================================
-- Charcoal value of one item, in charcoal bars.
--
--   volume   internal volume, one tenth of the wiki figure
--   class    key into T.CLASS
--   density  solid_density, or nil to skip the density factor
--
-- DENSITY IS OPTIONAL ON PURPOSE. The flesh path passes nil, because
-- a corpse's material is whichever tissue happens to dominate. The
-- same dwarf reads BONE on one corpse and SKIN on another, at 500 and
-- 1000, so applying density there would make identical creatures
-- differ by 2x on nothing but which tissue won.
-- ==========================================
function yield(volume, class, density, ctx)
    if not volume or volume <= 0 then return 0 end

    -- The size curve is applied here and the rest is handed to the
    -- pipeline. That split is the point: measuring belongs to the
    -- caller, factoring belongs to the pipeline, and a module
    -- measuring something other than volume does not inherit a
    -- wood-shaped exponent it never asked for.
    local base = T.ANCHOR_YIELD
                 * ((volume / T.ANCHOR_VOLUME) ^ T.SIZE_EXPONENT)

    -- ctx is optional and additive. Callers that pass nothing get
    -- exactly the old behaviour, which is why no consumer had to
    -- change when the pipeline went in.
    local c = { base = base, class = class, density = density }
    if ctx then
        for k, v in pairs(ctx) do
            if c[k] == nil then c[k] = v end
        end
    end

    return evaluate(c)
end

-- Same call, but hands back the breakdown as well. Used by anything
-- that wants to show its working.
function yield_explained(volume, class, density, ctx)
    if not volume or volume <= 0 then return 0, {} end
    local base = T.ANCHOR_YIELD
                 * ((volume / T.ANCHOR_VOLUME) ^ T.SIZE_EXPONENT)
    local c = { base = base, class = class, density = density }
    if ctx then
        for k, v in pairs(ctx) do
            if c[k] == nil then c[k] = v end
        end
    end
    return evaluate(c)
end

-- ==========================================
-- SPLIT COUNT
-- ==========================================
-- How many kindling one item splits into. Fractional; the caller
-- banks the remainder the same way charcoal is banked.
--
-- DERIVED FROM YIELD, NOT FROM VOLUME. This is the single line that
-- makes the split exploit structurally impossible rather than merely
-- tuned away.
--
-- Deriving from volume gives count = V * recovery / KINDLING_VOLUME,
-- which is linear in V while char yield is V^0.5, so the two come
-- apart at both ends: splitting a bucket returned 3x charring it and
-- an earring 15x, while anything above about 5200 volume gained in
-- the other direction.
--
-- Deriving from yield cancels the exponent outright:
--
--   count      = EFF * (V / KV)^E
--   split char = count * yield(KV) = EFF * (V/ANCHOR)^E = EFF * direct
--
-- The V terms cancel, so the ratio is EFF at every size, for every
-- material, at any exponent. Change SIZE_EXPONENT to anything you
-- like and this still holds.
-- ==========================================
function split_count(volume)
    if not volume or volume <= 0 then return 0 end
    return T.SPLIT_EFFICIENCY
           * ((volume / T.KINDLING_VOLUME) ^ T.SIZE_EXPONENT)
end

-- ==========================================
-- THE COMPLETED FELL
-- ==========================================
-- What one felled tree drops beyond its vanilla trunk logs, from
-- its measured tile counts. Linear on purpose: sources carry the
-- map, conversions carry the shape. Trunk tiles never appear here;
-- vanilla already paid those.
--
-- Returns limb logs (fractional), branches from light tiles
-- (fractional), and branches bundled from twig wood (whole, its
-- remainder already lost to the forest floor). The spawner rounds
-- the first two to nearest per tree, species pure, no bank,
-- nothing loopable. Callers wanting one branch number sum the
-- last two.
-- ==========================================
function fell_drops(heavy, light, twig)
    return (heavy or 0) * T.HEAVY_TILE_LOGS,
           (light or 0) * T.LIGHT_TILE_BRANCHES,
           math.floor((twig or 0) / T.TWIG_TILES_PER_BRANCH)
end

-- ==========================================
-- FLUID YIELD
-- ==========================================
-- Liquid value of one item, in LIQUID_UNIT-sized units. The same
-- size curve and density factor as charcoal; the class table is the
-- retort's own. Returns 0 for a class the retort gets nothing from.
-- ==========================================
function fluid_yield(volume, class, density, ctx)
    if not volume or volume <= 0 then return 0 end
    local f = T.FLUID_CLASS[class or 'WOOD'] or 0
    if f <= 0 then return 0 end
    local base = T.FLUID_ANCHOR_UNITS
                 * ((volume / T.ANCHOR_VOLUME) ^ T.SIZE_EXPONENT)
    -- Same correction the solid curve gets: density times volume is
    -- WET mass, and water condenses as steam up the flue, not as
    -- tar in the bucket. Without this a water-heavy feed out-pays
    -- its own dried form on the liquid limb, the same inversion the
    -- moisture factor closed on charcoal. ctx is optional; callers
    -- that pass nothing get the old behaviour exactly.
    local dry = 1.0
    local tok = ctx and ctx.mat_token or nil
    if tok then
        for _, row in ipairs(T.DRY_FRACTION) do
            if tok:find(row[1], 1, true) then dry = row[2]; break end
        end
    end
    return base * f * density_factor(density) * dry
end

-- The reference log's value, which every route is measured against.
function ANCHOR_LOG_VALUE()
    return yield(T.ANCHOR_VOLUME, 'WOOD', T.REF_DENSITY)
end

-- ==========================================
-- INVARIANT CHECKS
-- ==========================================
-- Run by making-fuel-curve after any edit. Each check is here
-- because breaking it has a specific consequence that is invisible in
-- game until someone notices infinite fuel.
--
-- Returns a list of { ok, name, detail }.
-- ==========================================
function check()
    local out = {}
    local function add(ok, name, detail)
        table.insert(out, { ok = ok, name = name, detail = detail })
    end

    -- 1. A reference log must be worth exactly ANCHOR_YIELD, or the
    --    anchor is not an anchor and nothing else can be read against
    --    it.
    local log = yield(T.ANCHOR_VOLUME, 'WOOD', T.REF_DENSITY)
    add(math.abs(log - T.ANCHOR_YIELD) < 1e-9,
        'reference log yields ANCHOR_YIELD',
        string.format('%.6f vs %.6f', log, T.ANCHOR_YIELD))

    -- 2. Splitting PAYS, by design, so there is no upper bound to
    --    check here. The bound that matters is elsewhere and cannot be
    --    checked from this file: NOTHING A SPLIT REACTION PRODUCES MAY
    --    BE A VALID INPUT TO A SPLIT REACTION.
    --
    --    Kindling is a wooden tool. Any SPLIT reagent that takes
    --    type TOOL with the wood flag and no tool_id will accept it,
    --    and kindling then splits into more kindling. Below 1.0 that
    --    is a slow drain nobody notices. Above 1.0 it is an infinite
    --    fuel generator. SPLIT_TOOL was exactly that shape.
    --
    --    All this can verify is that the number is sane.
    add(T.SPLIT_EFFICIENCY > 0 and T.SPLIT_EFFICIENCY < 3.0,
        'split efficiency is in a sane band',
        string.format('SPLIT_EFFICIENCY = %.4f  (above 1.0 means'
            .. ' splitting pays, which is intended)',
            T.SPLIT_EFFICIENCY))

    -- 3. The ratio must be size independent. If this ever drifts, the
    --    split count has been changed back to a volume derivation and
    --    the exploit is live again at one end of the range.
    local worst, worst_v = 0, nil
    for _, v in ipairs({ 3, 50, 200, 750, 2000, 5000, 6000, 30000 }) do
        local direct = yield(v, 'WOOD', T.REF_DENSITY)
        local split  = split_count(v)
                       * yield(T.KINDLING_VOLUME, 'WOOD', T.REF_DENSITY)
        local drift  = math.abs((split / direct) - T.SPLIT_EFFICIENCY)
        if drift > worst then worst, worst_v = drift, v end
    end
    add(worst < 1e-9,
        'split ratio is size independent',
        string.format('worst drift %.2e at volume %s',
            worst, tostring(worst_v)))

    -- 3.5 Carbonisation recovery must be a fraction, and WOOD must
    --     be present, because every other row is a ratio against it
    --     and a missing reference silently flattens the whole table
    --     to 1.0 with no symptom but quiet coal.
    local rec = T.CARBON_RECOVERY or {}
    add(type(rec.WOOD) == 'number' and rec.WOOD > 0 and rec.WOOD <= 1,
        'carbon recovery has a wood reference',
        'WOOD = ' .. tostring(rec.WOOD))
    local bad_rec = nil
    for k, v in pairs(rec) do
        if v <= 0 or v > 1 then bad_rec = k .. '=' .. tostring(v) end
    end
    add(bad_rec == nil, 'carbon recovery values are fractions',
        bad_rec or 'all in 0 to 1')

    -- 4. Class multipliers must be sane. A negative one produces
    --    negative fuel and a large one is almost always a typo.
    local bad = nil
    for k, v in pairs(T.CLASS) do
        if v < 0 or v > 2 then bad = k .. '=' .. tostring(v) end
    end
    add(bad == nil, 'class multipliers within 0 to 2',
        bad or 'all in range')

    -- 5.5 The coal ladder must be positive, and it should agree with
    --     the wood ladder. Disagreement is not an error, because coal
    --     is allowed its own economy, but it is never something to
    --     discover by accident, so the wood figures ride along in the
    --     detail whether they match or not.
    add(T.COKE_PER_GREEN_COKE >= 1 and T.BREEZE_PER_COKE >= 1,
        'coal ladder steps are positive',
        string.format('%d coke per green coke, %d breeze per coke'
            .. '  (wood: %d, %d)',
            T.COKE_PER_GREEN_COKE, T.BREEZE_PER_COKE,
            T.CHARCOAL_PER_BOULDER, T.CINDERS_PER_CHARCOAL))

    -- 5. The ladder must be consistent in both directions or char is
    --    a free money loop.
    add(T.CINDERS_PER_CHARCOAL >= 1 and T.CHARCOAL_PER_BOULDER >= 1,
        'packing ladder steps are positive',
        string.format('%d cinders per charcoal, %d charcoal per'
            .. ' boulder',
            T.CINDERS_PER_CHARCOAL, T.CHARCOAL_PER_BOULDER))

    -- 6. A log must still split to a whole number of kindling, or the
    --    most commonly seen reaction in the mod starts banking a
    --    fraction on every single job for no reason.
    local k = split_count(T.ANCHOR_VOLUME)
    add(math.abs(k - math.floor(k + 0.5)) < 0.05,
        'a log splits to a whole kindling count',
        string.format('%.4f kindling', k))

    -- 7. Density clamp must not be inverted, which would pin every
    --    material to a single factor without any obvious symptom.
    add(T.DENSITY_MIN > 0 and T.DENSITY_MIN < T.DENSITY_MAX,
        'density clamp band is ordered',
        string.format('%.2f to %.2f', T.DENSITY_MIN, T.DENSITY_MAX))

    -- 9. The bulk fuel slot count must equal the packing ladder step,
    --    or the kiln is an arbitrage against the char industry: below
    --    it, burning raw beats packing and nobody chars again.
    add(T.FUEL_BULK_PER_SMELTING == T.CINDERS_PER_CHARCOAL,
        'bulk fuel slots match the packing ladder',
        string.format('%d slots vs %d cinders per charcoal',
            T.FUEL_BULK_PER_SMELTING, T.CINDERS_PER_CHARCOAL))

    -- 8. NO ROUTE MAY BEAT SPLITTING.
    --
    -- A log can be charred, split then charred, made into furniture
    -- and charred, or made into furniture, split, and charred. The
    -- intended ordering is that splitting pays most, because that is
    -- the one bonus deliberately set above 1.0.
    --
    -- Sub additivity makes this easy to break by accident. Raising
    -- WASTE_RECOVERY, lowering SIZE_EXPONENT or shrinking the sawdust
    -- unit all push furniture routes upward, and none of those look
    -- dangerous on their own. Scanning the whole item volume range is
    -- the only way to catch the combination.
    local base = ANCHOR_LOG_VALUE()
    local worst_r, worst_v = 0, 0
    for _, V in ipairs({ 5000, 4000, 3000, 2000, 1000, 700, 400,
                         300, 200, 100, 50, 10 }) do
        local lost  = T.ANCHOR_VOLUME - V
        local n     = 0
        local waste = 0
        if T.WASTE_ENABLED and lost > 0 then
            -- The VALUE mint, as the hijacker actually runs it: a
            -- fraction of the value lost, both streams together,
            -- deliberately uncapped so the check bounds the most
            -- the pieces could ever sum to. The old body modelled
            -- the retired volume mint, and once units shrank to 78
            -- it invented a door route that never existed in game.
            waste = T.BYPRODUCT_RECOVERY
                * yield(lost, 'WOOD', T.REF_DENSITY)
        end
        local route = T.SPLIT_EFFICIENCY * yield(V, 'WOOD', T.REF_DENSITY)
                      + waste
        local ratio = route / base
        if ratio > worst_r then worst_r, worst_v = ratio, V end
    end
    add(worst_r <= T.SPLIT_EFFICIENCY + 1e-9,
        'no route beats splitting',
        string.format('worst %.4f at volume %d, split bonus %.4f',
            worst_r, worst_v, T.SPLIT_EFFICIENCY))

    -- 9. THE COMPLETED FELL MUST STAY INSIDE REALITY. Limb wood on
    --    the reference willow, 38 heavy tiles, must not out-log its
    --    own 18 tile trunk, a palm with no canopy drops nothing,
    --    and every pin is positive with heavy below a full trunk
    --    tile, or limbs would out-earn the trunk law itself.
    local lg, br, kd = fell_drops(38, 74, 64)
    local p_lg, p_br, p_kd = fell_drops(0, 0, 0)
    add(T.HEAVY_TILE_LOGS > 0 and T.HEAVY_TILE_LOGS < 1
            and T.LIGHT_TILE_BRANCHES > 0
            and T.TWIG_TILES_PER_BRANCH >= 1
            and lg < 18
            and p_lg == 0 and p_br == 0 and p_kd == 0,
        'completed fell inside reality',
        string.format('willow drops %.1f logs %.0f branches, %.0f'
            .. ' of them bundled twigs, palm drops nothing',
            lg, br + kd, kd))

    -- 10. VALUE RECOVERY MUST NEVER CLOSE THE PROCESSING TAX. The
    --     worst route is a product that keeps most of the log,
    --     charred later, plus recovery on what it lost. The exact
    --     bound for a door class product falls out of the curve;
    --     recovery at or past it makes carpentry a fuel source and
    --     inverts the ordering the contract promises.
    local v_door = 3000
    local bound = (T.ANCHOR_YIELD
        - yield(v_door, 'WOOD', T.REF_DENSITY))
        / yield(T.ANCHOR_VOLUME - v_door, 'WOOD', T.REF_DENSITY)
    add(T.BYPRODUCT_RECOVERY < bound,
        'byproduct recovery below the door class bound',
        string.format('%.3f against a bound of %.3f',
            T.BYPRODUCT_RECOVERY, bound))

    -- 11. The bark split must be a fraction of the recovery, not a
    --     second recovery on top of it.
    add(T.BYPRODUCT_BARK_SHARE >= 0 and T.BYPRODUCT_BARK_SHARE <= 1,
        'bark share is a fraction',
        string.format('%.2f of recovered value arrives as bark',
            T.BYPRODUCT_BARK_SHARE))

    -- 13. THE RETORT MAY BEAT THE FURNACE, BUT ONLY SO FAR. Its
    --     charcoal is a share of the furnace's, and its liquids come
    --     back as fuel through the liquid fuel tanks: the tar burned as
    --     it is, the wood vinegar distilled to methanol first. A closed
    --     retort really does keep what an open burn throws away, so it
    --     is allowed to win, and pays for that in plant. Priced in
    --     reference log units: the charcoal share, plus the log's
    --     liquids as tank jobs over the furnace's ANCHOR_YIELD jobs,
    --     must stay under RETORT_ROUTE_CEILING, or the furnace is dead
    --     content.
    --
    --     This used to price tar, pitch and a coke oven against a
    --     ceiling of 1.000. That route's reaction, COKE_PITCH, was
    --     removed, and the tank route that replaced it scored 1.077 on
    --     tar alone while the check still read 0.917 for the old one.
    local wood      = T.FLUID_SPLIT.WOOD or {}
    local per_job   = function(mjl) return mjl / T.KEROSENE_MJ_PER_L end
    local tar_jobs  = T.FLUID_ANCHOR_UNITS * (wood.TAR or 0)
                      * per_job(T.TAR_MJ_PER_L)
    local meth_jobs = T.FLUID_ANCHOR_UNITS * (wood.VINEGAR_WOOD or 0)
                      * T.METHANOL_PER_VINEGAR * per_job(T.METHANOL_MJ_PER_L)
    local retort_route = T.RETORT_CHARCOAL_SHARE
        + (tar_jobs + meth_jobs) / T.ANCHOR_YIELD
    add(T.RETORT_CHARCOAL_SHARE > 0 and T.RETORT_CHARCOAL_SHARE < 1
            and retort_route < T.RETORT_ROUTE_CEILING,
        'retort route stays under its ceiling',
        string.format('%.3f of the log as fuel via retort and liquid'
            .. ' fuel tanks, against 1.000 charred, ceiling %.2f',
            retort_route, T.RETORT_ROUTE_CEILING))

    -- 12. THE SECONDARIES MUST STAY SECONDARY. At or above 1.0 the
    --     byproduct outvalues the product: MakeAsh becomes a charcoal
    --     route worth as much as MakeCharcoal, and the reverse, and
    --     the ordering the contract promises no longer has a top.
    --     Negative is negative fuel.
    add(T.ASH_FROM_CHARRING >= 0 and T.ASH_FROM_CHARRING < 1
            and T.CHARCOAL_FROM_ASHING >= 0 and T.CHARCOAL_FROM_ASHING < 1,
        'burn secondaries are fractions below 1',
        string.format('%.3f ash per charcoal, %.3f charcoal per ash',
            T.ASH_FROM_CHARRING, T.CHARCOAL_FROM_ASHING))

    return out
end