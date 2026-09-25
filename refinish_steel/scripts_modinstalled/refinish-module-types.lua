--@ module = true
-- refinish-module-types.lua
-- ==========================================
-- RM MODULE TYPE DICTIONARY
-- ==========================================
-- Pure data tables that map friendly schema names to DF internal
-- values. Every other module engine file imports this. No side
-- effects, no globals, no runtime state — just lookups.
--
-- ADDING NEW TYPES:
--   1. Add an entry to the appropriate table below.
--   2. The engine files that consume these tables will pick it
--      up automatically — no wiring needed.
--   3. Update the schema reference JSON so modders know it exists.
--
-- NAMING CONVENTION:
--   Table keys are UPPERCASE strings matching the schema values
--   that modders write in their JSON data files. The engine does
--   a direct key lookup — no fuzzy matching, no case folding.
-- ==========================================


-- ==========================================
-- REAGENT TYPES
-- ==========================================
-- Maps schema reagent type names to the DF fields needed to
-- construct a reaction_reagent_itemst. The reaction builder
-- reads these to populate item_type, mat_type, mat_index,
-- reaction_class, and the needs_mat_id flag.
--
-- Fields:
--   item_type      — DF item_type enum value
--   mat_type       — Material type. 0=INORGANIC, 7=COAL, -1=any
--   mat_index      — Material index. -1=any (wildcard)
--   reaction_class — String for reaction_class matching. ""=none
--   needs_mat_id   — If true, the engine resolves mat_id from
--                     the reagent spec to an inorganic index
--   needs_metal_id — If true, the engine resolves metal_id to
--                     an inorganic index and sets reagent.metal_ore
--   has_material_reaction_product — Default value for this field.
--                     Can be overridden per-reagent in the spec.
-- ==========================================
REAGENT_TYPES = {

    -- Everything. Flags MUST filter or this matches every item in the
    -- fortress. For cross-cutting filters no single item type can
    -- express, such as furniture combined with a wood material.
    ANY = { 
        item_type = -1,         -- ANY ITEM TYPE       
        mat_type = -1,          -- ANY MAT_TYPE (NO MAGNIFYING GLASS)
        mat_index = -1,         -- ANY MAT_INDEX
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- ----- BARS -----
    -- Inorganic bar resolved by mat_id
    BAR = {
        item_type      = df.item_type.BAR,      --  0, no subtypes
        mat_type       = 0,     -- INORGANIC
        mat_index      = nil,    -- resolved from mat_id at build time
        reaction_class = "",
        needs_mat_id   = true,
        needs_metal_id = false,
    },

    -- Any bar (no material restriction)
    BAR_ANY = {
        item_type      = df.item_type.BAR,      --  0, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Ash and pearlash bars. Same shape as COAL and BAR_POTASH above,
    -- but the builtin index is resolved by name rather than written as
    -- a literal: being off by one here silently swaps the material for
    -- its neighbour in the builtin table, which is the same reasoning
    -- JUG gives for using df.item_type symbolically.
    --
    -- ASH is verified as 9 from the GLAZE_CRAFT_ASH path map.
    BAR_ASH = {
        item_type      = df.item_type.BAR,      --  0, no subtypes
        mat_type       = 9,      -- df.builtin_mats.ASH
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    BAR_PEARLASH = {
        item_type      = df.item_type.BAR,      --  0, no subtypes
        mat_type       = 10,     -- df.builtin_mats.PEARLASH
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A potash bar. mat_type 8 is the builtin POTASH material —
    -- confirmed against the builtin index list (6=WATER, 7=COAL,
    -- 8=POTASH, 9=ASH, 10=PEARLASH, 11=LYE).
    BAR_POTASH = {
        item_type      = df.item_type.BAR,      --  0, no subtypes
        mat_type       = 8,      -- df.builtin_mats.POTASH
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Coal wildcard reagent
    BAR_COAL = {
        item_type      = df.item_type.BAR,      --  0, no subtypes
        mat_type       = 7,      -- COAL material class
        mat_index      = -1,     -- Coal reagent wildcard (does not require refined coal)
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Charcoal bars
    BAR_CHARCOAL = {
        item_type      = df.item_type.BAR,      --  0, no subtypes
        mat_type       = 7,      -- COAL material class
        mat_index      = 1,      -- CHARCOAL
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Coke bars
    BAR_COKE = {
        item_type      = df.item_type.BAR,      --  0, no subtypes
        mat_type       = 7,      -- COAL material class
        mat_index      = 0,      -- COKE
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },


    -- ----- BLOCKS -----
    -- Inorganic blocks resolved by mat_id
    BLOCKS = {
        item_type      = df.item_type.BLOCKS,         --  2, no subtypes
        mat_type       = 0,         -- INORGANIC
        mat_index      = nil,       -- resolved from mat_id, -1 for magnifying glass
        reaction_class = "",
        needs_mat_id   = true,
        needs_metal_id = false,
    },

    -- Blocks of any material. BLOCKS above requires a mat_id; this is
    -- the wildcard form, used where the block material is whatever the
    -- reaction happens to consume.
    BLOCKS_ANY = {
        item_type      = df.item_type.BLOCKS,         --  2, no subtypes
        mat_type       = -1,        -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- ----- BOULDERS -----
    -- A boulder of a specific inorganic material
    BOULDER = {
        item_type      = df.item_type.BOULDER,      --  4, no subtypes
        mat_type       = 0,      -- INORGANIC
        mat_index      = nil,    -- resolved from mat_id, -1 for magnifying glass
        reaction_class = "",
        needs_mat_id   = true,
        needs_metal_id = false,
    },

    -- Any inorganic boulder (INORGANIC:NONE). The magnifying glass
    -- material selector ONLY appears when mat_type=0 (INORGANIC)
    -- and mat_index=-1 (NONE). Using mat_type=-1 makes the reagent
    -- a full wildcard across all material types, which suppresses
    -- the selector entirely. Source: DF wiki material token table.
    BOULDER_ANY = {
        item_type      = df.item_type.BOULDER,      --  4, no subtypes
        mat_type       = 0,      -- INORGANIC (required for magnifying glass)
        mat_index      = -1,     -- NONE (wildcard within inorganics)
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A boulder of no declared material class, narrowed by
    -- reaction_class instead. Distinct from BOULDER_ANY, which pins
    -- mat_type to INORGANIC on purpose for the magnifying glass case.
    -- Verified against MAKE_EARTHENWARE_TYPE_CRAFTS, where
    -- [REAGENT:clay:1:BOULDER:NONE:NONE:NONE] stores mat_type -1.
    BOULDER_UNTYPED = {
        item_type      = 4,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Any flux-bearing boulder (limestone, marble, etc.)
    -- DF matches via reaction_class on the reagent material
    FLUX = {
        item_type      = df.item_type.BOULDER,      --  4, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "FLUX",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Any ore boulder that smelts to a specific metal.
    -- Engine resolves metal_id to an inorganic index and sets
    -- the reagent.metal_ore field. DF then matches any boulder
    -- whose metal_ore table contains that metal.
    -- Pattern source: BRASS_MAKING [REAGENT:A:1:METAL_ORE:ZINC]
    ORE_OF = {
        item_type      = df.item_type.BOULDER,      --  4, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = true,   -- resolves metal_id -> reagent.metal_ore
    },

    -- ----- ROCKS -----
    -- A rock item (knapping, sharp rocks)
    ROCK = {
        item_type      = df.item_type.ROCK,     --  76, no subtypes
        mat_type       = 0,      -- INORGANIC
        mat_index      = nil,    -- resolve from mat_id, -1 for magnifying glass
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    ROCK_ANY = {
        item_type      = df.item_type.ROCK,     --  76, no subtypes
        mat_type       = -1,     -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- ----- WOOD -----
    -- A standard wooden log.
    WOOD = {
        item_type      = df.item_type.WOOD,      --  5, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Item type 91, distinct from WOOD at 5, and nothing in vanilla 
    -- consumes it. Vanilla branch does not stockpile. MAKING_FUEL does
    -- not use this, it injects MAKING_FUEL_BRANCH instead.
    BRANCH = { 
        item_type = df.item_type.BRANCH,         --  91, no subtypes      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- ----- GEMS -----
    SMALLGEM = {
        item_type      = df.item_type.SMALLGEM,      --  1, no subtypes
        mat_type       = 0,      -- INORGANIC
        mat_index      = nil,    --- resolve from mat_id, -1 for magnifying glass
        reaction_class = "",
        needs_mat_id   = true,
        needs_metal_id = false,
    },

    SMALLGEM_ANY = {
        item_type      = df.item_type.SMALLGEM,      --  1, no subtypes
        mat_type       = -1,     -- Any mat_type (no magnifying glass)
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A rough gemstone or uncut glass piece
    ROUGH = {
        item_type      = df.item_type.ROUGH,      --  3, no subtypes
        mat_type       = 0,      -- INORGANIC
        mat_index      = nil,    --- resolve from mat_id, -1 for magnifying glass
        reaction_class = "",
        needs_mat_id   = true,
        needs_metal_id = false,
    },

    ROUGH_ANY = {
        item_type      = df.item_type.ROUGH,      --  3, no subtypes
        mat_type       = -1,     -- no magnifying glass
        mat_index      = nil,    --- resolve from mat_id, -1 for magnifying glass
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    GEM = {
        item_type      = df.item_type.GEM,      --  44, no subtypes
        mat_type       = 0,      -- INORGANIC
        mat_index      = nil,    --- resolve from mat_id, -1 for magnifying glass
        reaction_class = "",
        needs_mat_id   = true,
        needs_metal_id = false,
    },

    GEM_ANY = {
        item_type      = df.item_type.GEM,      --  3, no subtypes
        mat_type       = -1,     -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- ----- POWDERS -----
    -- A powder (sand, plaster, etc.). Usually paired with a BAG
    -- via the container/contents linkage.
    -- "POWDER" has hardcoded entries in refinish-module-react.lua to handle special cases like sand
    -- DO NOT RENAME OR CHANGE WITHOUT CHECKING THAT
    POWDER = {
        item_type      = df.item_type.POWDER_MISC,     --  70, no subtypes
        mat_type       = nil,    -- resolved from mat_id if given, else -1
        mat_index      = nil,    -- resolved from mat_id if given, else -1
        reaction_class = "",
        needs_mat_id   = false,  -- optional: if mat_id given, resolve it
        needs_metal_id = false,
    },

    -- Any powder — magnifying glass attempt. Wiki says POWDER_MISC
    -- uses NONE:NONE, but that didn't work. Trying INORGANIC:NONE
    -- since runtime injection bypassed raws limitations for BOULDER.
    POWDER_ANY = {
        item_type      = df.item_type.POWDER_MISC,     --  70, no subtypes
        mat_type       = 0,      -- INORGANIC:NONE attempt
        mat_index      = -1,     -- NONE
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- ----- CONTAINERS (NON-TOOL) -----
    -- A generic container (any item). Too broad for practical use —
    -- DF will grab bars, weapons, etc. as "containers." Prefer
    -- BUCKET or BARREL for liquid reactions.
    -- Pattern source: MAKE_SOAP_FROM_TALLOW reagents[1] ("lye container")
    CONTAINER = {
        item_type      = -1,     -- any item that can contain liquid
        mat_type       = -1,     -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    ANIMALTRAP = {
        item_type      = df.item_type.ANIMALTRAP,     --  19, no subtypes
        mat_type       = -1,     -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    ARMORSTAND = {
        item_type      = df.item_type.ARMORSTAND,     --  33, no subtypes
        mat_type       = -1,     -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    BACKPACK = {
        item_type      = df.item_type.BACKPACK,     --  61, no subtypes
        mat_type       = -1,     -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- An empty bag. Used as a container for powders.
    BAG = {
        item_type      = df.item_type.BAG,     --  31, no subtypes
        mat_type       = -1,     -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A barrel. Alternative liquid container, larger capacity.
    -- item_type 17 = df.item_type.BARREL
    BARREL = {
        item_type      = df.item_type.BARREL,     --  17, no subtypes
        mat_type       = -1,     -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    BOX = {
        item_type      = df.item_type.BOX,     --  30, no subtypes
        mat_type       = -1,     -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    BIN = {
        item_type      = df.item_type.BIN,     --  32, no subtypes
        mat_type       = -1,     -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A bucket. The standard liquid container for workshop reactions.
    -- item_type 18 = df.item_type.BUCKET
    BUCKET = {
        item_type      = df.item_type.BUCKET,     --  18, no subtypes
        mat_type       = -1,     -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    CABINET = {
        item_type      = df.item_type.CABINET,     --  35, no subtypes
        mat_type       = -1,     -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    CAGE = {
        item_type      = df.item_type.CAGE,     --  16, no subtypes
        mat_type       = -1,     -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    COFFIN = {
        item_type      = df.item_type.COFFIN,     --  21, no subtypes
        mat_type       = -1,     -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A vial or flask. 1800 capacity = 45 dim = 3 vials/unit
    FLASK = {
        item_type      = df.item_type.FLASK,     --  11, no subtypes
        mat_type       = -1,     -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    QUIVER = {
        item_type      = df.item_type.QUIVER,     --  62, no subtypes
        mat_type       = -1,     -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    WEAPONRACK = {
        item_type      = df.item_type.WEAPONRACK,     --  34, no subtypes
        mat_type       = -1,     -- no magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- ----- LIQUIDS -----
    -- A liquid (lye, water, milk, etc.) stored in a container.
    -- Must be paired with a CONTAINER reagent via contains linkage.
    -- The liquid reagent gets IN_CONTAINER=true; the container gets
    -- PRESERVE_REAGENT=true and contains pointing to the liquid.
    -- Pattern source: MAKE_SOAP_FROM_TALLOW reagents[0] ("lye")

    -- Water specifically. mat_type=6 is the builtin water material.
    -- Discovered via: dfhack.matinfo.find('WATER') -> <material 6:-1>
    WATER = {
        item_type      = df.item_type.LIQUID_MISC,     --  73, no subtypes
        mat_type       = 6,      -- builtin water material type
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Lye in a container. Vanilla writes this reagent as
    -- LIQUID_MISC:NONE:LYE (soap, reaction_other.txt): the builtin
    -- LYE material in a LIQUID_MISC item. Pair it with a container
    -- reagent that CONTAINS it, exactly like WATER above. Used by
    -- the pulp reactions: lye is vanilla's alkali, made from the ash
    -- this module produces.
    LYE = {
        item_type      = df.item_type.LIQUID_MISC,     --  73, no subtypes
        mat_type       = df.builtin_mats.LYE,          --  11, builtin lye
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Generic liquid. mat_type resolved from mat_id if given.
    -- For non-inorganic liquids (lye=11, milk, etc.) the mat_type
    -- must be specified directly since they aren't in the inorganic
    -- array. Currently only supports builtin material types.
    LIQUID = {
        item_type      = df.item_type.LIQUID_MISC,     --  73, no subtypes
        mat_type       = nil,    -- resolved from context
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Extracts, oils, syrups. Dimensioned and container-bound, so a
    -- reagent needs in_container plus a matching container reagent.
    LIQUID_MISC = { 
        item_type = df.item_type.LIQUID_MISC,         --  73, no subtypes
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- An inorganic liquid: acids, alkalis, solutions. Unlike WATER
    -- (a builtin material at mat_type 6) these live in the inorganic
    -- array, so mat_type is 0 and the index is resolved from mat_id.
    -- Pairs with a BUCKET/BARREL/JUG reagent via contains linkage,
    -- exactly like WATER does.
    LIQUID_INORGANIC = {
        item_type      = df.item_type.LIQUID_MISC,     --  73, no subtypes
        mat_type       = 0,      -- INORGANIC
        mat_index      = nil,    -- resolved from mat_id
        reaction_class = "",
        needs_mat_id   = true,
        needs_metal_id = false,
    },

    -- Any inorganic liquid, narrowed by reaction_class rather than by a
    -- specific material — the liquid counterpart to POWDER_ANY.
    -- ArgMOD writes [LIQUID_MISC:NONE:INORGANIC:NONE] with a
    -- [REACTION_CLASS:...] filter, e.g. "any strong base" for caustics.
    -- Kept separate from LIQUID_INORGANIC so that type stays strict and
    -- still catches a forgotten mat_id.
    LIQUID_INORGANIC_ANY = {
        item_type      = df.item_type.LIQUID_MISC,     --  73, no subtypes
        mat_type       = 0,      -- INORGANIC
        mat_index      = -1,     -- NONE
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- ----- TOOLS -----
    -- A jug. Vanilla liquid/food container, used across ArgMOD's
    -- chemistry chain to hold acids and solutions.
    --
    -- item_type is symbolic rather than a literal: TOOL is the one
    -- category where being off by one silently grabs a completely
    -- different item class, so we let DFHack resolve it.
    --
    -- item_subtype holds the itemdef CODE, not a number. Tool indices
    -- shift with mod load order, so the reaction builder resolves the
    -- code at build time — same principle as custom workshops. 10,000
    -- capacity = 66.67 dim = 2.25 units


    -- "TOOL": Any tool, named by the reagent rather than by the type. JUG and
    -- LARGE_POT hardcode their itemdef code because they are
    -- fixed vanilla tools. This entry is the general case: the reagent
    -- definition carries tool_id, so any tool including an injected one
    -- can be required without adding a type entry per tool.
    --
    --     { "code": "vessel", "type": "TOOL",
    --       "tool_id": "MAKING_FUEL_SMALL_CASK", "quantity": 1 }
    --
    -- needs_tool_id follows the needs_mat_id pattern: the type declares
    -- that the value comes from the reagent, and build_reagent reads it.
    -- Leaving tool_id out resolves to -1, which matches any tool at all.
    --
    -- This is what makes tools generally useful in reactions rather
    -- than only as containers: a reaction can demand a specific tool be
    -- present instead of needing a whole new workshop to gate on.
    TOOL = {
        item_type      = df.item_type.TOOL,        --  86
        mat_type       = -1,        -- no magnifying glass?
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
        needs_tool_id  = true,
    },


    -- ----- SUBTYPE-SPECIFIC TOOLS -----

    CAULDRON = {
        item_type      = df.item_type.TOOL,                  --  86
        item_subtype   = "ITEM_TOOL_CAULDRON",                   -- 0
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    LADLE = {
        item_type      = df.item_type.TOOL,                  --  86
        item_subtype   = "ITEM_TOOL_LADLE",                   -- 1
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    BOWL = {
        item_type      = df.item_type.TOOL,                  --  86
        item_subtype   = "ITEM_TOOL_BOWL",                   -- 2
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    MORTAR = {
        item_type      = df.item_type.TOOL,                  --  86
        item_subtype   = "ITEM_TOOL_MORTAR",                   -- 3
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    PESTLE = {
        item_type      = df.item_type.TOOL,                  --  86
        item_subtype   = "ITEM_TOOL_PESTLE",                   -- 4
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    KNIFE_CARVING = {
        item_type      = df.item_type.TOOL,                  --  86
        item_subtype   = "ITEM_TOOL_KNIFE_CARVING",                   -- 5
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    KNIFE_BONING = {
        item_type      = df.item_type.TOOL,                  --  86
        item_subtype   = "ITEM_TOOL_KNIFE_BONING",                   -- 6
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    KNIFE_SLICING = {
        item_type      = df.item_type.TOOL,                  --  86
        item_subtype   = "ITEM_TOOL_KNIFE_SLICING",                   -- 7
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    KNIFE_MEAT_CLEAVER = {
        item_type      = df.item_type.TOOL,                  --  86
        item_subtype   = "ITEM_TOOL_MEAT_CLEAVER",                   -- 8
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    FORK_CARVING = {
        item_type      = df.item_type.TOOL,                  --  86
        item_subtype   = "ITEM_TOOL_FORK_CARVING",                   -- 9
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    NEST_BOX = {
        item_type      = df.item_type.TOOL,                  --  86
        item_subtype   = "ITEM_TOOL_NEST_BOX",                   -- 10
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    JUG = {
        item_type      = df.item_type.TOOL,                  --  86
        item_subtype   = "ITEM_TOOL_JUG",                  -- 11
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A large pot. Same tool-itemdef pattern as JUG above: the subtype
    -- is a CODE, resolved at build time because tool indices shift with
    -- mod load order. 60,000 capacity = 1500 dim = 10 units
    LARGE_POT = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_LARGE_POT",                    -- 12
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HIVE = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_HIVE",                    -- 13
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HONEYCOMB = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_HONEYCOMB",                    -- 14
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    POUCH = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_POUCH",                    -- 15
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    MINECART = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_MINECART",                    -- 16
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    WHEELBARROW = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_WHEELBARROW",                    -- 17
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    STEPLADDER = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_STEPLADDER",                    -- 18
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    SCROLL_ROLLERS = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_SCROLL_ROLLERS",                    -- 19
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    BOOK_BINDING = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_BOOK_BINDING",                    -- 20
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    SCROLL = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_SCROLL",                    -- 21
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    QUIRE = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_QUIRE",                    -- 22
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    BOOKCASE = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_BOOKCASE",                    -- 23
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HELVE = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_HELVE",                    -- 24
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    STONE_AXE = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_STONE_AXE",                    -- 25
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    PEDESTAL = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_PEDESTAL",                    -- 26
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    DISPLAY_CASE = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_DISPLAY_CASE",                    -- 27
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    ALTAR = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_ALTAR",                    -- 28
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    DIE = {
        item_type      = df.item_type.TOOL,                    --  86
        item_subtype   = "ITEM_TOOL_DIE",                    -- 29
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- ---- TOOL USES -----

    --LIQUID_COOKING = 0
    --LIQUID_SCOOP = 1
    --GRIND_POWDER_RECEPTACLE = 2
    --GRIND_POWDER_GRINDER = 3
    --MEAT_CARVING = 4
    --MEAT_BONING = 5
    --MEAT_SLICING = 6
    --MEAT_CLEAVING = 7
    --HOLD_MEAT_FOR_CARVING = 8
    --MEAL_CONTAINER = 9
    --LIQUID_CONTAINER = 10
    --FOOD_STORAGE = 11
    --HIVE = 12
    --NEST_BOX = 13
    --SMALL_OBJECT_STORAGE = 14
    --TRACK_CART = 15
    --HEAVY_OBJECT_HAULING = 16
    --STAND_AND_WORK_ABOVE = 17
    --ROLL_UP_SHEET = 18
    --PROTECT_FOLDED_SHEETS = 19
    --CONTAIN_WRITING = 20
    --BOOKCASE = 21
    --DISPLAY_OBJECT = 22
    --PLACE_OFFERING = 23
    --DIVINATION = 24
    --GAMES_OF_CHANCE = 25

    HAS_LIQUID_COOKING = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.LIQUID_COOKING,                   -- 0
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_LIQUID_SCOOP = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.LIQUID_SCOOP,                   -- 1
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_GRIND_POWDER_RECEPTACLE = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.GRIND_POWDER_RECEPTACLE,                   -- 2
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_MEAT_CARVING = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.MEAT_CARVING,                   -- 4
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_MEAT_BONING = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.MEAT_BONING,                   -- 5
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_MEAT_SLICING = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.MEAT_SLICING,                   -- 6
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_MEAT_CLEAVING = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.MEAT_CLEAVING,                   -- 7
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_HOLD_MEAT_FOR_CARVING = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.HOLD_MEAT_FOR_CARVING,                   -- 8
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_MEAL_CONTAINER = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.MEAL_CONTAINER,                   -- 9
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_LIQUID_CONTAINER = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.LIQUID_CONTAINER,                  -- 10
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_FOOD_STORAGE = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.FOOD_STORAGE,                  -- 11
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_HIVE = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.HIVE,                  -- 12
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_NEST_BOX = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.NEST_BOX,                  -- 13
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_SMALL_OBJECT_STORAGE = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.SMALL_OBJECT_STORAGE,                  -- 14
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_TRACK_CART = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.TRACK_CART,                  -- 15
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_HEAVY_OBJECT_HAULING = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.HEAVY_OBJECT_HAULING,                  -- 16
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_STAND_AND_WORK_ABOVE = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.STAND_AND_WORK_ABOVE,                  -- 17
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_ROLL_UP_SHEET = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.ROLL_UP_SHEET,                  -- 18
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_PROTECT_FOLDED_SHEETS = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.PROTECT_FOLDED_SHEETS,                  -- 19
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_CONTAIN_WRITING = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.CONTAIN_WRITING,                  -- 20
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_BOOKCASE = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.BOOKCASE,                  -- 21
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_DISPLAY_OBJECT = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.DISPLAY_OBJECT,                  -- 22
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_PLACE_OFFERING = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.PLACE_OFFERING,                  -- 23
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_DIVINATION = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.DIVINATION,                  -- 24
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HAS_GAMES_OF_CHANCE = {
        item_type      = df.item_type.TOOL,                  --  86
        has_tool_use   = df.tool_uses.GAMES_OF_CHANCE,                  -- 25
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- ----- FURNITURE & ARCHITECHTURE -----
    DOOR = {
        item_type      = df.item_type.DOOR,     --  6, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    FLOODGATE = {
        item_type      = df.item_type.FLOODGATE,     --  7, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    BED = {
        item_type      = df.item_type.BED,     --  8, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    CHAIR = {
        item_type      = df.item_type.CHAIR,     --  9, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    WINDOW = {
        item_type      = df.item_type.WINDOW,     --  15, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    TABLE = {
        item_type      = df.item_type.TABLE,     --  20, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A statue. No subtype: STATUE is a plain item type.
    STATUE = {
        item_type      = df.item_type.STATUE,    --  22, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    PIPE_SECTION = {
        item_type      = df.item_type.PIPE_SECTION,     --  77, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    HATCH_COVER = {
        item_type      = df.item_type.HATCH_COVER,     --  78, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    GRATE = {
        item_type      = df.item_type.GRATE,     --  79, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    SLAB = {
        item_type      = df.item_type.SLAB,     --  87, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },


    -- ----- FINISHED GOODS & CRAFTS -----
    -- Any craft item. Verified against GLAZE_CRAFT_ASH: DF stores this
    -- as item_type -1 with flags3.any_craft set, so the flag does all
    -- the filtering and the item type matches anything.
    --
    -- Like BODY_PART above, this is only safe when the reagent also
    -- carries a reaction_class or equivalent narrowing. Argendauss uses
    -- reaction_class CAN_GLAZE on every one of them.
    --
    -- flags3 is applied by build_reagent after the neutral reset. It is
    -- a type-level property, not a modder choice, which is why it lives
    -- here rather than in the schema's flags block.
    CRAFT_ANY = {
        item_type      = -1,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
        flags3         = { any_craft = true },
    },

    GOBLET = {
        item_type      = df.item_type.GOBLET,     --  12, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- remember to catalogue instrument parts later
    -- instruments have subtypes but they're weird
    INSTRUMENT = {
        item_type      = df.item_type.INSTRUMENT,     --  13
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },


    -- ----- TOYS -----
    -- any toy
    TOY = {
        item_type      = df.item_type.TOY,     --  14
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    TOY_PUZZLEBOX = {
        item_type      = df.item_type.TOY,     --  14
        item_subtype   = 0,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    TOY_BOAT = {
        item_type      = df.item_type.TOY,     --  14
        item_subtype   = 1,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    TOY_HAMMER = {
        item_type      = df.item_type.TOY,     --  14
        item_subtype   = 2,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    TOY_AXE = {
        item_type      = df.item_type.TOY,     --  14
        item_subtype   = 3,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    TOY_MINIFORGE = {
        item_type      = df.item_type.TOY,     --  14
        item_subtype   = 4,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },


    FIGURINE = {
        item_type      = df.item_type.FIGURINE,     --  36, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    AMULET = {
        item_type      = df.item_type.AMULET,     --  37, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    SCEPTER = {
        item_type      = df.item_type.SCEPTER,     --  38, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    CROWN = {
        item_type      = df.item_type.CROWN,     --  40, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    RING = {
        item_type      = df.item_type.RING,     --  41, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    EARRING = {
        item_type      = df.item_type.EARRING,     --  42, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    BRACELET = {
        item_type      = df.item_type.BRACELET,     --  43, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A skull mounted as a totem. Item type 59, no longer a corpse
    -- piece, so no body_part reagent will reach one.
    TOTEM = { 
        item_type = df.item_type.TOTEM,         --  59, no subtypes       
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    COIN = { 
        item_type = df.item_type.COIN,         --  74, no subtypes    
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- ----- WEAPONS -----
    WEAPON = { 
        item_type = df.item_type.WEAPON,         --  24
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    WHIP = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_WHIP",        -- 0
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    AXE_BATTLE = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_AXE_BATTLE", -- 1
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    HAMMER_WAR = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_HAMMER_WAR", -- 2
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SWORD_SHORT = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_SWORD_SHORT", -- 3
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SPEAR = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_SPEAR", -- 4
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    MACE = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_MACE", -- 5
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    CROSSBOW = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_CROSSBOW", -- 6
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    PICK = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_PICK", -- 7
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    BOW = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_BOW", -- 8
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    BLOWGUN = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_BLOWGUN", -- 9
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    PIKE = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_PIKE", -- 10
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    HALBERD = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_HALBERD", -- 11
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- two handed sword
    SWORD_2H = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_SWORD_2H", -- 12
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SWORD_LONG = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_SWORD_LONG", -- 13
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    MAUL = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_MAUL", -- 14
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    AXE_GREAT = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_AXE_GREAT", -- 15
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    DAGGER_LARGE = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_DAGGER_LARGE", -- 16
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SCOURGE = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_SCOURGE", -- 17
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    FLAIL = { 
        item_type = df.item_type.WEAPON,         --  18
        item_subtype = "ITEM_WEAPON_FLAIL", -- 4
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    MORNINGSTAR = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_MORNINGSTAR", -- 19
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SCIMITAR = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_SCIMITAR", -- 20
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    AXE_TRAINING = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_AXE_TRAINING", -- 21
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SWORD_SHORT_TRAINING = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_SWORD_SHORT_TRAINING", -- 22
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SPEAR_TRAINING = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_SPEAR_TRAINING", -- 23
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    PICK_GREAT = { 
        item_type = df.item_type.WEAPON,         --  24
        item_subtype = "ITEM_WEAPON_PICK_GREAT", -- 24
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- ----- ARMOUR -----
    -- should match any torso armour
    ARMOR = { 
        item_type = df.item_type.ARMOR,         --  25
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    BREASTPLATE = { 
        item_type = df.item_type.ARMOR,         --  25
        item_subtype = "ITEM_ARMOR_BREASTPLATE", -- 0
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    MAIL_SHIRT = { 
        item_type = df.item_type.ARMOR,         --  25
        item_subtype = "ITEM_ARMOR_MAIL_SHIRT", -- 1
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    LEATHER_ARMOR = { 
        item_type = df.item_type.ARMOR,         --  25
        item_subtype = "ITEM_ARMOR_LEATHER_ARMOR", -- 2
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    COAT = { 
        item_type = df.item_type.ARMOR,         --  25
        item_subtype = "ITEM_ARMOR_COAT", -- 3
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SHIRT = { 
        item_type = df.item_type.ARMOR,         --  25
        item_subtype = "ITEM_ARMOR_SHIRT", -- 4
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    CLOAK = { 
        item_type = df.item_type.ARMOR,         --  25
        item_subtype = "ITEM_ARMOR_CLOAK", -- 5
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    TUNIC = { 
        item_type = df.item_type.ARMOR,         --  25
        item_subtype = "ITEM_ARMOR_TUNIC", -- 6
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    TOGA = { 
        item_type = df.item_type.ARMOR,         --  25
        item_subtype = "ITEM_ARMOR_TOGA", -- 7
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    CAPE = { 
        item_type = df.item_type.ARMOR,         --  25
        item_subtype = "ITEM_ARMOR_CAPE", -- 8
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    VEST = { 
        item_type = df.item_type.ARMOR,         --  25
        item_subtype = "ITEM_ARMOR_VEST", -- 9
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    DRESS = { 
        item_type = df.item_type.ARMOR,         --  25
        item_subtype = "ITEM_ARMOR_DRESS", -- 10
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    ROBE = { 
        item_type = df.item_type.ARMOR,         --  25
        item_subtype = "ITEM_ARMOR_ROBE", -- 11
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- ----- SHIELDS -----
    -- matches any shield including bucklers
    SHIELD_ANY = { 
        item_type = df.item_type.SHIELD,         --  27
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- shield subtype only, no bucklers
    SHIELD = { 
        item_type = df.item_type.SHIELD,         --  27
        item_subtype = "ITEM_SHIELD_SHIELD",     -- 0     
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SHIELD_BUCKLER = { 
        item_type = df.item_type.SHIELD,         --  27
        item_subtype = "ITEM_SHIELD_BUCKLER",    -- 1       
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- ----- AMMO -----
    -- any ammo
    AMMO = { 
        item_type = df.item_type.AMMO,         --  39
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    BOLTS = { 
        item_type = df.item_type.AMMO,         --  39
        item_subtype = "ITEM_AMMO_BOLTS",      -- 0      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    ARROWS = { 
        item_type = df.item_type.AMMO,         --  39
        item_subtype = "ITEM_AMMO_ARROWS",     -- 1      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    BLOWDARTS = { 
        item_type = df.item_type.AMMO,         --  39
        item_subtype = "ITEM_AMMO_BLOWDARTS",  -- 2      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- ----- FOOTWEAR -----
    -- any footwear
    FOOTWEAR_ANY = { 
        item_type = df.item_type.SHOES,         --  26
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- shoe subtype only
    SHOES = { 
        item_type = df.item_type.SHOES,         --  26
        item_subtype = 0,      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- high boots
    BOOTS = { 
        item_type = df.item_type.SHOES,         --  26
        item_subtype = "ITEM_SHOES_BOOTS", -- 1      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    BOOTS_LOW = { 
        item_type = df.item_type.SHOES,         --  26
        item_subtype = "ITEM_SHOES_BOOTS_LOW", -- 2      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SANDAL = { 
        item_type = df.item_type.SHOES,         --  26
        item_subtype = "ITEM_SHOES_SANDAL", -- 3      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    CHAUSSE = { 
        item_type = df.item_type.SHOES,         --  26
        item_subtype = "ITEM_SHOES_CHAUSSE", -- 4      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SOCKS = { 
        item_type = df.item_type.SHOES,         --  26
        item_subtype = "ITEM_SHOES_SOCKS", -- 5      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- ----- HEADWEAR -----
    -- match any headwear
    HEADWEAR_ANY = { 
        item_type = df.item_type.HELM,         --  28
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false
    },

    -- helm subtype only
    HELM = { 
        item_type = df.item_type.HELM,         --  28
        item_subtype = "ITEM_HELM_HELM", -- 0      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    CAP = { 
        item_type = df.item_type.HELM,         --  28
        item_subtype = "ITEM_HELM_CAP", -- 1      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    HOOD = { 
        item_type = df.item_type.HELM,         --  28
        item_subtype = "ITEM_HELM_HOOD", -- 2      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    TURBAN = { 
        item_type = df.item_type.HELM,         --  28
        item_subtype = "ITEM_HELM_TURBAN", -- 3      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    MASK = { 
        item_type = df.item_type.HELM,         --  28
        item_subtype = "ITEM_HELM_MASK", -- 4      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    VEIL_HEAD = { 
        item_type = df.item_type.HELM,         --  28
        item_subtype = "ITEM_HELM_VEIL_HEAD", -- 5      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    VEIL_FACE = { 
        item_type = df.item_type.HELM,         --  28
        item_subtype = "ITEM_HELM_VEIL_FACE", -- 6      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SCARF_HEAD = { 
        item_type = df.item_type.HELM,         --  28
        item_subtype = "ITEM_HELM_SCARF_HEAD", -- 7      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- ----- HANDWEAR -----
    -- match any handwear
    HANDWEAR_ANY = { 
        item_type = df.item_type.GLOVES,         --  29
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    GAUNTLETS = { 
        item_type = df.item_type.GLOVES,         --  29
        item_subtype = "ITEM_GLOVES_GAUNTLETS", -- 0      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- glove subtype only
    GLOVES = { 
        item_type = df.item_type.GLOVES,         --  29
        item_subtype = "ITEM_GLOVES_GLOVES", -- 1      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    MITTENS = { 
        item_type = df.item_type.GLOVES,         --  29
        item_subtype = "ITEM_GLOVES_MITTENS", -- 2      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- ----- LEGWEAR -----
    LEGWEAR_ANY = { 
        item_type = df.item_type.PANTS,         --  60
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- pants subtype only
    PANTS = { 
        item_type = df.item_type.PANTS,         --  60
        item_subtype = 0,   
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    GREAVES = { 
        item_type = df.item_type.PANTS,         --  60
        item_subtype = "ITEM_PANTS_GREAVES", -- 1   
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    LEGGINGS = { 
        item_type = df.item_type.PANTS,         --  60
        item_subtype = "ITEM_PANTS_LEGGINGS", -- 2   
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    LOINCLOTH = { 
        item_type = df.item_type.PANTS,         --  60
        item_subtype = "ITEM_PANTS_LOINCLOTH", -- 3   
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    THONG = { 
        item_type = df.item_type.PANTS,         --  60
        item_subtype = "ITEM_PANTS_THONG", -- 4   
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SKIRT = { 
        item_type = df.item_type.PANTS,         --  60
        item_subtype = "ITEM_PANTS_SKIRT", -- 5   
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SKIRT_SHORT = { 
        item_type = df.item_type.PANTS,         --  60
        item_subtype = "ITEM_PANTS_SKIRT_SHORT", -- 6   
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SKIRT_LONG = { 
        item_type = df.item_type.PANTS,         --  60
        item_subtype = "ITEM_PANTS_SKIRT_LONG", -- 7   
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    BRAIES = { 
        item_type = df.item_type.PANTS,         --  60
        item_subtype = "ITEM_PANTS_BRAIES", -- 8   
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- ----- WORKSHOP & LOCATION OBJECTS -----
    QUERN = { 
        item_type = df.item_type.QUERN,         --  80, no subtypes     
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    MILLSTONE = { 
        item_type = df.item_type.MILLSTONE,         --  81, no subtypes       
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    ANVIL = { 
        item_type = df.item_type.ANVIL,         --  45, no subtypes      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    TRACTION_BENCH = { 
        item_type = df.item_type.TRACTION_BENCH,         --  84, no subtypes       
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    ORTHOPEDIC_CAST = { 
        item_type = df.item_type.ORTHOPEDIC_CAST,         --  85, no subtypes     
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SPLINT = { 
        item_type = df.item_type.SPLINT,         --  82, no subtypes     
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    CRUTCH = { 
        item_type = df.item_type.CRUTCH,         --  83, no subtypes       
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- ----- SIEGES & TRAPS -----
    CATAPULTPARTS = { 
        item_type = df.item_type.CATAPULTPARTS,         --  63, no subtypes      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    BALLISTAPARTS = { 
        item_type = df.item_type.BALLISTAPARTS,         --  64, no subtypes      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- ----- SIEGE AMMUNITION -----
    SIEGEAMMO = { 
        item_type = df.item_type.SIEGEAMMO,         --  65
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SIEGEAMMO_BALLISTA = { 
        item_type = df.item_type.SIEGEAMMO,         --  65
        item_subtype = "ITEM_SIEGEAMMO_BALLISTA",   -- 0
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    BALLISTAARROWHEAD = { 
        item_type = df.item_type.BALLISTAARROWHEAD,         --  66, no subtypes       
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    BOLT_THROWER_PARTS = { 
        item_type = df.item_type.BOLT_THROWER_PARTS,         --  92, no subtypes        
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    TRAPPARTS = { 
        item_type = df.item_type.TRAPPARTS,         --  67, no subtypes      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- ----- TRAP COMPONENTS -----
    TRAPCOMP = { 
        item_type = df.item_type.TRAPCOMP,         --  68
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    GIANTAXEBLADE = { 
        item_type = df.item_type.TRAPCOMP,         --  68
        item_subtype = "ITEM_TRAPCOMP_GIANTAXEBLADE", -- 0   
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    ENORMOUSCORKSCREW = { 
        item_type = df.item_type.TRAPCOMP,         --  68
        item_subtype = "ITEM_TRAPCOMP_ENORMOUSCORKSCREW", -- 1   
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    SPIKEDBALL = { 
        item_type = df.item_type.TRAPCOMP,         --  68
        item_subtype = "ITEM_TRAPCOMP_SPIKEDBALL", -- 2   
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    LARGESERRATEDDISC = { 
        item_type = df.item_type.TRAPCOMP,         --  68
        item_subtype = "ITEM_TRAPCOMP_LARGESERRATEDDISC", -- 3   
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    MENACINGSPIKE = { 
        item_type = df.item_type.TRAPCOMP,         --  68
        item_subtype = "ITEM_TRAPCOMP_MENACINGSPIKE", -- 4   
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- ----- ORGANIC INTAKE -----
    -- All of these wildcard the material deliberately. Organic mat_type
    -- is computed per species (plant = 419 + that plant's own local
    -- material index, creature = 19 + its own), and those local indices
    -- are NOT stable across species. Olive proves it: its local material
    -- 1 is frozen olive oil where nearly every other tree has wood, so a
    -- fixed mat_type of 420 would quietly accept oil in a wood reaction.
    --
    -- Filtering therefore happens entirely through flags in the JSON.
    -- Vanilla does the same: the gukil strings reagent is THREAD at
    -- mat -1/-1 carrying nothing but ANY_PLANT_MATERIAL.
    --
    -- Named rather than numbered: an off by one in the item enum
    -- silently swaps the item kind.


    -- ----- ORGANIC INTAKE -----
    -- Item types a reaction can consume organic matter through.
    --
    -- Every one of them wildcards the material, and that is deliberate
    -- rather than lazy. Organic mat_type is computed per species: a
    -- plant material is 419 plus that plant's own local material index,
    -- a creature material is 19 plus its own. Those local indices are
    -- NOT stable across species. Olive proves it, since its local
    -- material 1 is frozen olive oil while almost every other tree has
    -- wood there, so a fixed mat_type of 420 would quietly accept oil
    -- in a wood reaction.
    --
    -- So filtering happens entirely through flags in the JSON. That is
    -- what vanilla does too: the gukil strings reagent is THREAD at
    -- mat -1/-1 carrying nothing but ANY_PLANT_MATERIAL, and the soap
    -- reagent is GLOB at mat -1/-1 carrying a reaction class.
    --
    -- Named rather than numbered for the reason JUG gives: an off by
    -- one in the item enum silently swaps the item kind.

    -- Everything. Flags MUST do the filtering or this matches every
    -- item in the fortress, including furniture, bars and artifacts.
    -- Use it for cross-cutting filters that no single item type can
    -- express, such as furniture combined with a wood material.

    -- ----- PETS & RESTRAINTS -----
    PET = {
        item_type      = df.item_type.PET,    --  52, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    CHAIN = { 
        item_type = df.item_type.CHAIN,         --  10, no subtypes
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- ----- RAW CREATURE MATERIALS -----
    -- An untyped reagent slot filtered entirely by flags rather than by
    -- item type — bones, shells, horns. item_type -1 matches anything,
    -- so this type is ONLY safe when paired with body_part plus one of
    -- the bone/shell/horn flags. Used by CALCINE_BONES, GRIND_SHELLS
    -- and the two hartshorn reactions.

    -- any body part
    -- found corpse flags in body parts data, look into that later
    BODY_PART = {
        item_type      = -1,     -- any item; the flags do the filtering
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A whole body. Distinct from CORPSEPIECE, which is a part.
    CORPSE = {
        item_type      = df.item_type.CORPSE,    --  23, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Bones, skulls, hides, teeth, shells. BODY_PART above reaches the
    -- same items through flags at item_type -1; this one pins the type
    -- instead, which is safer where no other filter is wanted.
    CORPSEPIECE = {
        item_type      = df.item_type.CORPSEPIECE,    --  46, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Vermin remains. Its own stockpile category, so its own type.
    REMAINS = { 
        item_type = df.item_type.REMAINS,         --  47, no subtypes  
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- ----- FOOD -----
    -- Prepared meals and raw food. FOOD is 72, DRINK is 69.
    FOOD = { 
        item_type = df.item_type.FOOD,         --  72, no subtypes      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    DRINK = { 
        item_type = df.item_type.DRINK,         --  69, no subtypes       
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false
    },

    MEAT = { 
        item_type = df.item_type.MEAT,         --  48, no subtypes      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    EGG = { 
        item_type = df.item_type.EGG,         --  88, no subtypes        
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    CHEESE = { 
        item_type = df.item_type.CHEESE,         --  71, no subtypes      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- Prepared fish, distinct from FISH_RAW.
    FISH = { 
        item_type = df.item_type.FISH,         --  49, no subtypes      
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    FISH_RAW = { 
        item_type = df.item_type.FISH_RAW,         --  50, no subtypes 
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    -- Fat and tallow. Dimensioned, so quantity counts units, not items.
    GLOB = {
        item_type      = df.item_type.GLOB,    --  75, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },


    -- ----- PLANTS -----
    -- A harvested plant, the thing a farm plot yields.
    PLANT = {
        item_type      = df.item_type.PLANT,    --  54, no subtypes
        mat_type       = -1,    -- gets glitched magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Leaves, fruit, nuts. Anything a plant grows rather than is.
    PLANT_GROWTH = {
        item_type      = df.item_type.PLANT_GROWTH,    --  56, no subtypes
        mat_type       = -1,    -- gets glitched magnifying glass
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    SEEDS = {
        item_type      = df.item_type.SEEDS,    --  53, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },


    -- ----- PROCESSED PLANT & ANIMAL MATERIALS -----

    -- Tanned leather, not the raw hide. Raw hides are CORPSEPIECE.
    SKIN_TANNED = {
        item_type      = df.item_type.SKIN_TANNED,    --  55, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Spun thread. Plant, silk and yarn all arrive as this item type,
    -- separated by flags2.plant, flags2.silk and flags2.yarn.
    THREAD = {
        item_type      = df.item_type.THREAD,    --  57, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    CLOTH = {
        item_type      = df.item_type.CLOTH,    --  58, no subtypes
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Paper. SHEET is 90, BOOK is 89. Both carry flags3.written_on,
    -- which is how a reaction avoids consuming a written work.
    SHEET = { 
        item_type = df.item_type.SHEET,         --  90, no subtypes
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },

    BOOK = { 
        item_type = df.item_type.BOOK,         --  89, no subtypes
        mat_type = -1, 
        mat_index = -1, 
        reaction_class = "", 
        needs_mat_id = false, 
        needs_metal_id = false 
    },
}


-- ==========================================
-- PRODUCT TYPES
-- ==========================================
-- Maps schema product type names to DF item_type values.
-- The reaction builder uses these when constructing products.
-- mat_type is included because some product types have a
-- fixed material class (e.g. bars are always INORGANIC for
-- our purposes, but could be COAL for fuel products).
-- ==========================================
PRODUCT_TYPES = {
    BAR         = { item_type = 0,  mat_type = 0  },  -- INORGANIC bar
    -- BAR_COAL carries mat_subtypes. See the builtin bars note below.
    BAR_COAL    = { item_type = 0,  mat_type = df.builtin_mats.COAL,
                    mat_subtypes = { COKE = 0, CHARCOAL = 1, COAL = -1 } },
    BLOCKS      = { item_type = 2,  mat_type = 0  },  -- Stone/ceramic blocks
    ROUGH       = { item_type = 3,  mat_type = 0  },  -- Raw gem / uncut glass
    BOULDER     = { item_type = 4,  mat_type = 0  },  -- Boulder
    LIQUID_MISC = { item_type = 73, mat_type = 6  },  -- Liquid (water=mat_type 6)
    POWDER_MISC = { item_type = 70, mat_type = 0  },  -- Powder
    ROCK        = { item_type = 76, mat_type = -1 },  -- Rock item
    LIQUID_MISC_INORGANIC = { item_type = 73, mat_type = 0 },  -- acid/alkali output
    BAR_POTASH            = { item_type = 0,  mat_type = 8 },  -- potash bar output

    -- A glob of an inorganic material. Dimensioned like fat and wax,
    -- so counts are units of 150. Paper pulp and paraffin wax are
    -- produced as globs because vanilla's screw press (PAPER_SLURRY)
    -- and wax crafting (WAX) consume globs by reaction class, which
    -- is how those products reach vanilla with no further reactions.
    GLOB        = { item_type = 75, mat_type = 0  },  -- Glob (paper pulp, wax)

    -- Builtin-material bars. The material lives in mat_type and there
    -- is no inorganic to look up, so mat_index stays -1 and the product
    -- names no material of its own.
    --
    -- BAR_POTASH above is this shape too, and it works because POTASH
    -- has no subtypes: its mat_id misses the inorganic lookup, the miss
    -- returns -1, and -1 is correct for a material with one form.
    --
    -- BAR_COAL is NOT that shape, and reading it as though it were was
    -- the bug. The builtin COAL material is a single object whose
    -- state_name.Solid is just "coal". Coke and charcoal are not
    -- separate materials in the raws. mat_index is a pure discriminator
    -- that DF's item naming and stockpile code reads:
    --
    --     0   coke      (vanilla LIGNITE_TO_COKE writes this)
    --     1   charcoal  (the wood furnace's built-in job writes this)
    --    -1   neither, so DF falls back to a generic label
    --
    -- Confirmed two ways. The vanilla reaction's product carries
    -- mat_type 7 with mat_index 0, and dfhack.matinfo.find resolves
    -- 'COAL:COKE' to 7/0 and 'COAL:CHARCOAL' to 7/1.
    --
    -- So BAR_COAL carries mat_subtypes, mapping the schema's mat_id
    -- string onto that index. Before it existed, mat_id fell through to
    -- the inorganic lookup, missed, and every coal bar RM built was
    -- written as -1.
    --
    -- ASH and PEARLASH resolve by name for the reason JUG gives: off by
    -- one in the builtin table silently swaps the material.
    BAR_ASH      = { item_type = 0, mat_type = df.builtin_mats.ASH,      builtin = true },
    BAR_PEARLASH = { item_type = 0, mat_type = df.builtin_mats.PEARLASH, builtin = true },

    -- A tool. The subtype names which one, as an itemdef CODE, and
    -- build_product resolves it at build time through
    -- resolve_item_subtype. That resolution is by code rather than by
    -- position, so an injected tool works here with no further change.
    --
    -- mat_type 0 is the inorganic default, used when the product names
    -- a mat_id directly. A tool made from clay wants mode 3 instead:
    -- get_material_product pointing at the clay reagent and FIRED_MAT,
    -- which is exactly how vanilla builds a large pot
    -- (reaction_other.txt:125). A wooden cask wants mode 2,
    -- get_material_same against the log.
    --
    -- Without this entry the engine can consume a tool as a reagent
    -- but can never produce one, which is why containers had nowhere
    -- to come from.
    TOOL = { item_type = df.item_type.TOOL, mat_type = 0 },

    -- A random craft item. Verified against MAKE_EARTHENWARE_TYPE_CRAFTS:
    -- DF stores this as item_type -1 with the CRAFTS product flag set,
    -- and picks the actual craft itself. The flag is applied in
    -- build_product because the neutral reset clears it first.
    CRAFTS = { item_type = -1, mat_type = -1, crafts = true },

    -- Not an item product at all. This is a sentinel: build_product
    -- hands anything with this type to build_improvement_product, which
    -- constructs a reaction_product_item_improvementst instead.
    IMPROVEMENT = { improvement = true },
}


-- ==========================================
-- BUILDING TYPES
-- ==========================================
-- Maps schema building names to DF building type/subtype pairs.
-- Most furnace-class buildings have two entries: normal + magma.
-- Custom workshops have a single entry with a custom index.
--
-- Structure:
--   type[]    — Building type values (one per variant)
--   subtype[] — Building subtype values (parallel to type[])
--   custom[]  — Custom workshop index (-1 = not custom)
--
-- Pattern source: Reaction path maps for STEEL_MAKING,
-- MAKE_PLASTER_POWDER, MAKE_COBALT_GLASS, MAKE_SOAP_FROM_TALLOW
-- ==========================================
BUILDING_TYPES = {
    -- ---- FURNACES (building_type 5) ----
    -- All furnaces have normal + magma variants.

    -- Wood Furnace (type 5 is furnace, subtype 0 is wood furnace)
    WOOD_FURNACE = {
        type    = { 5 },
        subtype = { 0 },
        custom  = { -1 },
    },

    -- Smelter (1) + Magma Smelter (4)
    SMELTER = {
        type    = { 5, 5 },
        subtype = { 1, 4 },
        custom  = { -1, -1 },
    },

    -- Glass Furnace (2) + Magma Glass Furnace (5)
    GLASS_FURNACE = {
        type    = { 5, 5 },
        subtype = { 2, 5 },
        custom  = { -1, -1 },
    },

    -- Kiln (3) + Magma Kiln (6)
    KILN = {
        type    = { 5, 5 },
        subtype = { 3, 6 },
        custom  = { -1, -1 },
    },

    -- ---- WORKSHOPS (building_type 13) ----
    -- Subtypes from df.workshop_type enum.

    -- Mason's Workshop (2) — make blocks, stone furniture
    MASON = {
        type    = { 13 },
        subtype = { 2 },
        custom  = { -1 },
    },

    -- Craftsdwarf's Workshop (3) — stone/bone/shell crafts
    -- NOTE: subtype 3, NOT 0. Subtype 0 is Carpenter's Workshop.
    CRAFTSMAN = {
        type    = { 13 },
        subtype = { 3 },
        custom  = { -1 },
    },

    -- Jeweler's Workshop (4) — cut/encrust gems
    JEWELER = {
        type    = { 13 },
        subtype = { 4 },
        custom  = { -1 },
    },

    -- Metalsmith's Forge (5) + Magma Forge (6)
    FORGE = {
        type    = { 13, 13 },
        subtype = { 5, 6 },
        custom  = { -1, -1 },
    },

    -- Mechanic's Workshop (8). workshop_type 8 is Mechanics in the live
    -- enum dump (df_data_reference, building_types_and_subtypes_and_
    -- skills_numbers.txt), and workshops are building_type 13, as MASON
    -- and CRAFTSMAN above. First used by Making Fuel's fuel burner.
    MECHANIC = {
        type    = { 13 },
        subtype = { 8 },
        custom  = { -1 },
    },

    -- The still is workshop subtype 15 in the same enum dump, and a
    -- workshop, building_type 13. First used by Making Fuel's spirit
    -- distillation.
    STILL = {
        type    = { 13 },
        subtype = { 15 },
        custom  = { -1 },
    },

    -- The kitchen is workshop subtype 19 in the same enum dump, and a
    -- workshop, building_type 13. First used by Making Fuel's boiling
    -- reactions: pitch, glue and oil sand.
    KITCHEN = {
        type    = { 13 },
        subtype = { 19 },
        custom  = { -1 },
    },

    -- Quern (17) + Millstone (22) — the two milling workshops.
    -- ArgMOD lists BOTH on all 41 of his grinding reactions so the
    -- player can use either, which is structurally identical to the
    -- normal+magma furnace pairs above.
    MILL = {
        type    = { 13, 13 },
        subtype = { 17, 22 },
        custom  = { -1, -1 },
    },

    -- Ashery (20) — potash, lye, and ash processing.
    ASHERY = {
        type    = { 13 },
        subtype = { 20 },
        custom  = { -1 },
    },

    -- Dyer's Shop (21). Measured, not inferred: the ACACIA_BARK_DYE
    -- path map stores building.type 13 with building.subtype 21, and
    -- that reaction carries [BUILDING:DYER:NONE] in its raw strings.
    --
    -- Needed by anything producing a POWDER_MISC material flagged
    -- IS_DYE. All 71 vanilla dyes are made here, so it is the only
    -- place a player will look for the job.
    DYER = {
        type    = { 13 },
        subtype = { 21 },
        custom  = { -1 },
    },

    -- Tanner's Shop. Workshop (13), subtype 12.
    -- Added for the hide chain: raw skin globs are combined and worked
    -- into rawhide here, and the tanner then takes that rawhide through
    -- vanilla's own TAN_A_HIDE with nothing hijacked.
    TANNER = {
        type    = { 13 },
        subtype = { 12 },
        custom  = { -1 },
    },

    -- ---- CUSTOM WORKSHOPS (type 13, subtype 23 = workshop_type.Custom) ----
    -- These are raw objects, NOT entries in the df.workshop_type enum.
    -- A reaction points at one by storing the workshop's runtime index
    -- in building.custom. That index depends on raw load order, so it
    -- CANNOT be a constant here — `custom_code` names the workshop and
    -- the reaction builder resolves it at build time.
    --
    -- Note SOAP_MAKER is vanilla content that happens to be implemented
    -- as a custom workshop (vanilla building_custom.txt), so it goes
    -- through exactly the same path as a modded one.

    SOAP_MAKER = {
        type        = { 13 },
        subtype     = { 23 },
        custom      = { -1 },        -- filled in at runtime
        custom_code = "SOAP_MAKER",
    },

    SCREW_PRESS = {
        type        = { 13 },
        subtype     = { 23 },
        custom      = { -1 },
        custom_code = "SCREW_PRESS",
    },

    -- ArgMOD's Chemist (building_arg_chemist.txt). Stays in raws —
    -- we only need to find it, never to create it.
    CHEMIST = {
        type        = { 13 },
        subtype     = { 23 },
        custom      = { -1 },
        custom_code = "CHEMIST",
    },

    -- ArgMOD's Compounder (building_arg_compounder.txt). Same deal as
    -- CHEMIST: a raws workshop we only ever need to find, never build.
    -- Its runtime index depends on raw load order, so custom_code names
    -- it and the reaction builder resolves it at build time.
    COMPOUNDER = {
        type        = { 13 },
        subtype     = { 23 },
        custom      = { -1 },
        custom_code = "COMPOUNDER",
    },

    -- Furnace class: building_type.Furnace (5) with
    -- furnace_type.Custom (7), not Workshop (13) / Custom (23).
    -- Must match the "class" the building was injected under or
    -- the reaction is sent to a building class that does not
    -- contain it.
    RETORT = {
        type        = { 5 },
        subtype     = { 7 },
        custom      = { -1 },
        custom_code = "MAKING_FUEL_RETORT",
    },

    -- No building (adventure mode reactions)
    NONE = {
        type    = {},
        subtype = {},
        custom  = {},
    },
}


-- ==========================================
-- JOB ITEM VECTORS
-- ==========================================
-- DF keeps 136 separate item vectors and a reagent's vector_id says
-- which one it searches. Several are gates nothing else in this schema
-- can express: ANY_DEAD_DWARF is every corpse a butcher will refuse,
-- ANY_MURDERED is exactly what it says, ANY_BUTCHERABLE is the
-- complement, and there are ANY_CAN_ROT, ANY_MELT_DESIGNATED and
-- ANY_RECENTLY_DROPPED besides.
--
-- THIS TABLE IS NOT THE AUTHORITY. The engine resolves a name through
-- df.job_item_vector_id at build time and reports a miss loudly. This
-- list exists so preflight can catch a typo offline, hours before the
-- game would. If DF adds a vector tomorrow the engine finds it and
-- this list does not need to know.
--
-- Enumerated from a live game on 2026-09-09 with refinish-corpse-probe,
-- walking the enum by index from _first_item to _last_item. pairs() on
-- a DFHack enum returns its metatable rather than its values, which is
-- how an earlier build of that probe reported eleven entries with
-- names like _complex and sizeof.
JOB_ITEM_VECTORS = {
        'ANY', 'IN_PLAY', 'ANY_ARTIFACT', 'WEAPON', 'ANY_WEAPON',
        'ANY_SPIKE', 'ANY_TRUE_ARMOR', 'ANY_ARMOR_HELM',
        'ANY_ARMOR_SHOES', 'SHIELD', 'ANY_ARMOR_GLOVES',
        'ANY_ARMOR_PANTS', 'QUIVER', 'SPLINT', 'ORTHOPEDIC_CAST',
        'CRUTCH', 'BACKPACK', 'AMMO', 'WOOD', 'BOULDER', 'ROCK',
        'ANY_REFUSE', 'ANY_GOOD_FOOD', 'ANY_AUTO_CLEAN',
        'ANY_EXTRACTABLE', 'ANY_BUTCHERABLE', 'ANY_FURNITURE',
        'ANY_CAGE_OR_TRAP', 'ANY_EDIBLE_RAW', 'ANY_EDIBLE_CARNIVORE',
        'ANY_EDIBLE_BONECARN', 'ANY_EDIBLE_VERMIN',
        'ANY_EDIBLE_VERMIN_BOX', 'ANY_CAN_ROT', 'ANY_MURDERED',
        'ANY_DEAD_DWARF', 'ANY_GOES_IN_CHEST', 'ANY_GOES_IN_CABINET',
        'ANY_GOES_IN_WEAPONRACK', 'ANY_GOES_IN_ARMORSTAND', 'DOOR',
        'FLOODGATE', 'HATCH_COVER', 'GRATE', 'CAGE', 'FLASK',
        'WINDOW', 'GOBLET', 'INSTRUMENT', 'TOY', 'BUCKET', 'BARREL',
        'CHAIN', 'ANIMALTRAP', 'BED', 'TRACTION_BENCH', 'CHAIR',
        'COFFIN', 'TABLE', 'STATUE', 'QUERN', 'MILLSTONE', 'BOX',
        'BIN', 'ARMORSTAND', 'WEAPONRACK', 'CABINET', 'ANVIL',
        'CATAPULTPARTS', 'BALLISTAPARTS', 'SIEGEAMMO', 'TRAPPARTS',
        'ANY_WEBS', 'PIPE_SECTION', 'ANY_ENCASED',
        'ANY_IN_CONSTRUCTION', 'DRINK', 'ANY_DRINK', 'LIQUID_MISC',
        'POWDER_MISC', 'ANY_COOKABLE', 'ANY_GLASSABLE', 'VERMIN',
        'PET', 'ANY_CRITTER', 'COIN', 'GLOB', 'ANY_RECENTLY_DROPPED',
        'ANY_MELT_DESIGNATED', 'TRAPCOMP', 'BAR', 'SMALLGEM',
        'BLOCKS', 'ROUGH', 'CORPSE', 'FIGURINE', 'AMULET', 'SCEPTER',
        'CROWN', 'RING', 'EARRING', 'BRACELET', 'GEM', 'CORPSEPIECE',
        'REMAINS', 'MEAT', 'FISH', 'FISH_RAW', 'SEEDS', 'PLANT',
        'SKIN_TANNED', 'PLANT_GROWTH', 'THREAD', 'CLOTH', 'TOTEM',
        'PANTS', 'CHEESE', 'FOOD', 'BALLISTAARROWHEAD', 'ARMOR',
        'SHOES', 'HELM', 'GLOVES', 'TOOL', 'SLAB', 'EGG',
        'POSSIBLE_CONTAINER', 'ANY_CORPSE', 'BOOK', 'FOOD_STORAGE',
        'INSTRUMENT_STATIONARY', 'SHEET', 'BRANCH', 'BAG', 'MAGICAL',
        'BOLT_THROWER_PARTS',
}


-- ==========================================
-- TOOL USES
-- ==========================================
-- has_tool_use is resolved by name through df.tool_uses, and until now
-- nothing checked the name. A miss used to fall to -1, the WILDCARD,
-- so a typo opened the filter rather than narrowing it. The engine now
-- announces a miss; this list is what lets preflight catch it first.
--
-- Same doctrine as JOB_ITEM_VECTORS: NOT the authority. The engine
-- resolves against the live enum, so a tool use DF adds tomorrow still
-- works. This exists so a typo fails offline instead of quietly
-- widening a filter in a running fort.
--
-- Enumerated from a live game on 2026-09-09 with
-- refinish-corpse-probe audit, by index from _first_item to
-- _last_item. All 27, NONE included, because NONE is a legal value
-- meaning the item must have no tool use at all.
TOOL_USES = {
        'NONE', 'LIQUID_COOKING', 'LIQUID_SCOOP',
        'GRIND_POWDER_RECEPTACLE', 'GRIND_POWDER_GRINDER',
        'MEAT_CARVING', 'MEAT_BONING', 'MEAT_SLICING',
        'MEAT_CLEAVING', 'HOLD_MEAT_FOR_CARVING', 'MEAL_CONTAINER',
        'LIQUID_CONTAINER', 'FOOD_STORAGE', 'HIVE', 'NEST_BOX',
        'SMALL_OBJECT_STORAGE', 'TRACK_CART', 'HEAVY_OBJECT_HAULING',
        'STAND_AND_WORK_ABOVE', 'ROLL_UP_SHEET',
        'PROTECT_FOLDED_SHEETS', 'CONTAIN_WRITING', 'BOOKCASE',
        'DISPLAY_OBJECT', 'PLACE_OFFERING', 'DIVINATION',
        'GAMES_OF_CHANCE',
}


-- ==========================================
-- BUILDING CAPABILITY GATES
-- ==========================================
-- Maps each BUILDING_TYPES key to the job capability required for
-- a civilization to use that workshop. The module permission
-- evaluator checks these gates against each civ's permitted_job
-- array before injecting reaction permissions.
--
-- Gate types (mixed in a single list):
--   - "StrangeMoodForge", "StrangeMoodMagmaForge", etc:
--       Checked via numeric df.job_type enum iteration
--       (same pattern as boot Pass 3). These represent deep
--       cultural capabilities that encompass entire material
--       classes, not just individual job skills.
--
--   - "GLASSMAKER", "POTTER", etc:
--       Checked as direct boolean keys on permitted_job.
--       These represent specific workshop operator skills.
--
-- A civ passes the gate if ANY entry in the list is true.
-- (e.g., a smelter gate passes if the civ has EITHER
-- StrangeMoodForge OR StrangeMoodMagmaForge.)
--
-- ADDING NEW BUILDINGS:
--   1. Add the building to BUILDING_TYPES above.
--   2. Add its gate entry here.
--   3. The evaluator picks it up automatically.
-- ==========================================
BUILDING_CAPABILITY_GATES = {
    -- ---- FURNACES ----

    -- ---- WHY NONE OF THESE ARE MOOD GATES ANY MORE ----
    --
    -- entity_raw.jobs.permitted_job is indexed by df.profession, not
    -- df.job_type. Verified: the live array is 135 slots and
    -- df.profession has exactly 135 entries, and reads by name agree
    -- with reads by df.profession index on every civ tested.
    --
    -- The mood gates indexed it with df.job_type values, which landed
    -- on unrelated professions:
    --
    --   StrangeMoodForge      = 55 -> LYE_MAKER
    --   StrangeMoodMagmaForge = 56 -> WOOD_BURNER
    --   StrangeMoodMason      = 60 -> BEEKEEPER
    --
    -- So the smelter gate asked whether a civ made lye or burned
    -- wood, and the kiln gate asked whether it kept bees. Both looked
    -- plausible because civs with broad profession lists tend to have
    -- those slots set as well.
    --
    -- Beyond the wrong read, a mood is the wrong QUESTION. A strange
    -- mood is about artifact creation, not about whether a civ has the
    -- profession that operates a building. Goblins have MASON and
    -- STONECRAFTER but never take mason moods.
    --
    -- Each gate now names the profession that actually runs the
    -- building. All names verified present in df.profession.

    -- Wood Furnace: requires the wood burner profession
    WOOD_FURNACE = {
        gate_type = "permitted_job",
        jobs = { "WOOD_BURNER" },
    },

    -- Dyer's Shop: requires the dyer profession.
    --
    -- A building added to BUILDING_TYPES needs an entry here as well.
    -- check_building_capability fails CLOSED on a name it does not
    -- recognise, so a missing gate is silent: the reaction builds,
    -- resolves to the right workshop, and is then rejected for every
    -- civ with nothing in the log to say so. That is how the first
    -- four dye reactions came out permitted for nobody.
    DYER = {
        gate_type = "permitted_job",
        jobs = { "DYER" },
    },

    -- job 12, TANNER
    TANNER = {
        gate_type = "permitted_job",
        jobs = { "TANNER" },
    },

    -- Smelter: FURNACE_OPERATOR (17) is what runs a smelter, and the
    -- smelter is the only building that produces metal bars, whether
    -- from ore or by alloying.
    SMELTER = {
        gate_type = "permitted_job",
        jobs = { "FURNACE_OPERATOR" },
    },

    -- Kiln: POTTER (33) and GLAZER (34). Both verified by name and by
    -- df.profession index on MOUNTAIN, which has each of them.
    KILN = {
        gate_type = "permitted_job",
        jobs = { "POTTER", "GLAZER" },
    },

    -- Glass Furnace: direct job check, not a mood
    GLASS_FURNACE = {
        gate_type = "permitted_job",
        jobs = { "GLASSMAKER" },
    },

    -- ---- WORKSHOPS ----

    -- Mason's Workshop: masonry skill
    MASON = {
        gate_type = "permitted_job",
        jobs = { "MASON" },
    },

    -- Craftsdwarf's Workshop: any craft skill
    CRAFTSMAN = {
        gate_type = "permitted_job",
        jobs = { "STONECRAFTER", "WOODCRAFTER", "BONE_CARVER" },
    },

    -- Jeweler's Workshop: gem working skills
    JEWELER = {
        gate_type = "permitted_job",
        jobs = { "JEWELER", "GEM_CUTTER", "GEM_SETTER" },
    },

    -- Metalsmith's Forge: the smith professions, 16 and 18 to 21.
    --
    -- This is deliberately NOT the same test as the smelter. The old
    -- comment claimed smelting and forging were one capability; they
    -- are not. Metal bars come only from a smelter. A forge governs
    -- working existing bars, which for RM means grinding them to dust.
    --
    -- Kobolds are the case that proves the distinction: they have
    -- FURNACE_OPERATOR but none of the smith professions. They can
    -- smelt and they cannot forge.
    FORGE = {
        gate_type = "permitted_job",
        jobs = { "METALSMITH", "WEAPONSMITH", "ARMORER",
                 "BLACKSMITH", "METALCRAFTER" },
    },

    -- Mechanic's Workshop: the mechanic profession. Verified present on
    -- live entity raws as jobs.permitted_job.MECHANIC, set by
    -- [PERMITTED_JOB:MECHANIC] (df_data_reference, the entities path
    -- maps). Missing at first, which is exactly the silent failure the
    -- DYER note describes: the fuel burner recipe built, resolved to the
    -- right workshop, and was refused for every civ.
    MECHANIC = {
        gate_type = "permitted_job",
        jobs = { "MECHANIC" },
    },

    -- The still: [PERMITTED_JOB:BREWER] in the vanilla dwarven entity,
    -- and permitted_job.BREWER in the entities path map. Added together
    -- with the first recipe that needs it, so the silent refusal the
    -- MECHANIC note records cannot happen here.
    STILL = {
        gate_type = "permitted_job",
        jobs = { "BREWER" },
    },

    -- The kitchen: [PERMITTED_JOB:COOK] in the vanilla dwarven entity,
    -- and permitted_job.COOK in the entities path map. Added together
    -- with the first recipes that need it, as the still's was.
    KITCHEN = {
        gate_type = "permitted_job",
        jobs = { "COOK" },
    },

    -- Mill, Ashery, and the two custom workshops: no capability gate.
    --
    -- This is deliberate. The existing gates guard against handing a
    -- smelting reaction to a civ with no metalworking culture. But a
    -- module using ENTITY_CODE permissions has already named its civs
    -- explicitly, and a speculative gate on top can only SUBTRACT from
    -- what the module author asked for — silently, since an unknown
    -- permitted_job name fails closed via pcall.
    --
    -- ArgMOD names MOUNTAIN, PLAINS and EVIL by hand, and further
    -- restricts the Chemist with [PERMITTED_BUILDING:CHEMIST] on
    -- MOUNTAIN only. That list is authoritative; second-guessing it
    -- would change his work. Tighten these later if a module ever
    -- needs AUTO mode on these workshops.
    MILL        = { gate_type = "none", jobs = {} },
    ASHERY      = { gate_type = "none", jobs = {} },
    SOAP_MAKER  = { gate_type = "none", jobs = {} },
    SCREW_PRESS  = { gate_type = "none", jobs = {} },
    CHEMIST     = { gate_type = "none", jobs = {} },
    COMPOUNDER  = { gate_type = "none", jobs = {} },
    RETORT      = { gate_type = "none", jobs = {} },
    ARC_FURNACE = { gate_type = "none", jobs = {} },
    

    -- No building: no capability gate (adventure mode, always passes)
    NONE = {
        gate_type = "none",
        jobs = {},
    },
}


-- ==========================================
-- SKILL MAP
-- ==========================================
-- Maps schema skill names to DF job_skill enum values.
-- Sourced from: :lua for i,v in ipairs(df.job_skill) do print(i,v) end
-- Only includes skills relevant to workshop reactions.
--
-- IMPORTANT: These are df.job_skill indexes, NOT df.job_type.
-- The reaction's .skill field takes a job_skill value.
-- ==========================================
SKILL_MAP = {
    -- Furnace skills
    WOOD_BURNING    = 63,   -- Wood Furnace Operation
    SMELT           = 24,   -- Furnace Operating (smelter reactions)
    GLASSMAKER      = 34,   -- Glassmaking
    POTTERY         = 109,  -- Pottery (kiln reactions)
    CHEMISTRY       = 127,  -- Chemistry (retort, chemist, etc)

    -- Workshop skills: stone/masonry
    MASONRY         = 4,    -- Masonry (mason's workshop)
    STONECRAFT      = 32,   -- Stone Crafting (craftsdwarf's workshop)
    KNAPPING        = 105,  -- Knapping
    CUT_STONE       = 135,  -- Stone Cutting
    CARVE_STONE     = 136,  -- Stone Carving

    -- Workshop skills: metalworking
    FORGE_WEAPON    = 26,   -- Weaponsmithing (forge)
    FORGE_ARMOR     = 27,   -- Armorsmithing (forge)
    FORGE_FURNITURE = 28,   -- Blacksmithing / furniture (forge)
    METALCRAFT      = 33,   -- Metal Crafting (craftsdwarf's workshop)

    -- Workshop skills: gems
    GEM_CUTTING     = 29,   -- Gem Cutting (jeweler's workshop)
    GEM_SETTING     = 30,   -- Gem Setting (jeweler's workshop)

    -- Workshop skills: organic
    WOODCRAFT       = 31,   -- Wood Crafting
    BONECARVE       = 36,   -- Bone Carving
    LEATHERWORK     = 35,   -- Leatherworking
    TANNER          = 12,   -- Tanning, the tanner's shop skill
    CARPENTRY       = 2,    -- Carpentry
    MECHANICS       = 54,   -- Mechanics (mechanic's workshop)
    BREWING         = 14,   -- Brewing (still)
    COOK            = 20,   -- Cooking (kitchen)

    -- Workshop skills: textiles and misc
    WEAVING         = 13,   -- Weaving (loom)
    CLOTHESMAKING   = 15,   -- Clothes Making
    STRAND_EXTRACT  = 25,   -- Strand Extraction
    SOAP_MAKING     = 65,   -- Soap Making
    MILLING         = 16,   -- Milling (quern/millstone)
    LYE_MAKING      = 64,   -- Lye Making (ashery, chemist)
    PRESSING        = 111,  -- Pressing (screw press)

    -- Papermaking. The pulp reactions run at the quern and millstone
    -- with the same skill vanilla's slurry reaction uses. Resolved
    -- from the enum rather than hardcoded so the number cannot
    -- drift; the constants above predate this entry and stay as
    -- their measured values.
    PAPERMAKING     = df.job_skill.PAPERMAKING,

    -- Glazing. Verified as 110 from the GLAZE_CRAFT_ASH path map,
    -- not inferred: that reaction carries [SKILL:GLAZING] in raws and
    -- stores skill = 110.
    GLAZING         = 110,  -- Glazing (kiln)
    POTASH_MAKING   = 66,   -- Potash Making (ashery, kiln, chemist)

    -- Plant Processing (17). Measured from the ACACIA_BARK_DYE path
    -- map, which stores skill 17 against [SKILL:PROCESSPLANTS].
    -- This is the dyer's shop skill. Match it to DYER or the job
    -- goes to the wrong dwarves.
    PROCESSPLANTS   = 17,   -- Plant Processing (dyer's shop)
}


-- ==========================================
-- MATERIAL CLASS PRESETS
-- ==========================================
-- Maps schema material_class names to the material.flags that
-- the engine force-sets after cloning. The engine:
--   1. Deep-copies the auto-selected clone source (all flags come along)
--   2. Applies the preset below (force-sets listed flags to true)
--   3. Applies any material_flags overrides from the definition
--
-- The "clear" list is flags that get force-set to FALSE before
-- the preset is applied. This ensures a clean slate when
-- crossing material boundaries (e.g. cloning from a metal to
-- make a stone — we need to clear the metal flags first).
--
-- RAW class applies no preset and no clearing — clone flags
-- are preserved exactly as-is.
-- ==========================================
MATERIAL_CLASS_PRESETS = {

    METAL = {
        clear = {
            "IS_STONE", "IS_GEM", "IS_GLASS", "IS_CERAMIC",
        },
        set = {
            "IS_METAL", "ITEMS_METAL", "ITEMS_HARD",
            "ITEMS_BARRED", "ITEMS_SCALED",
            "ITEMS_WEAPON", "ITEMS_WEAPON_RANGED",
            "ITEMS_AMMO", "ITEMS_DIGGER",
            "ITEMS_ARMOR", "ITEMS_ANVIL",
        },
    },

    STONE = {
        clear = {
            "IS_METAL", "IS_GEM", "IS_GLASS", "IS_CERAMIC",
            "ITEMS_METAL", "ITEMS_BARRED", "ITEMS_SCALED",
            "ITEMS_WEAPON", "ITEMS_WEAPON_RANGED",
            "ITEMS_AMMO", "ITEMS_DIGGER",
            "ITEMS_ARMOR", "ITEMS_ANVIL",
        },
        set = {
            "IS_STONE", "ITEMS_HARD", "ITEMS_QUERN",
        },
    },

    GEM = {
        clear = {
            "IS_METAL", "IS_STONE", "IS_GLASS", "IS_CERAMIC",
            "ITEMS_METAL", "ITEMS_BARRED", "ITEMS_SCALED",
            "ITEMS_WEAPON", "ITEMS_WEAPON_RANGED",
            "ITEMS_AMMO", "ITEMS_DIGGER",
            "ITEMS_ARMOR", "ITEMS_ANVIL",
        },
        set = {
            "IS_GEM",
        },
    },

    CERAMIC = {
        clear = {
            "IS_METAL", "IS_GEM", "IS_GLASS",
            "ITEMS_METAL", "ITEMS_BARRED", "ITEMS_SCALED",
            "ITEMS_WEAPON", "ITEMS_WEAPON_RANGED",
            "ITEMS_AMMO", "ITEMS_DIGGER",
            "ITEMS_ARMOR", "ITEMS_ANVIL",
        },
        set = {
            "IS_CERAMIC", "ITEMS_HARD",
        },
    },

    -- Glass: produced at glass furnace. Buildable (windows, blocks).
    -- Flags match the modded cobalt glass inorganic pattern:
    -- IS_GLASS + ITEMS_HARD, everything else cleared.
    -- Vanilla glass types (GREEN_GLASS, CLEAR_GLASS, CRYSTAL_GLASS)
    -- are NOT inorganic definitions — they're engine-side. A modded
    -- glass defined as an inorganic with IS_GLASS behaves like glass
    -- in gameplay (windows, crafts, etc.). Source: cobalt glass mod
    -- path map (modded_cobalt_glass_inorganic_path_map.txt).
    GLASS = {
        clear = {
            "IS_METAL", "IS_GEM", "IS_STONE", "IS_CERAMIC",
            "ITEMS_METAL", "ITEMS_BARRED", "ITEMS_SCALED",
            "ITEMS_WEAPON", "ITEMS_WEAPON_RANGED",
            "ITEMS_AMMO", "ITEMS_DIGGER",
            "ITEMS_ARMOR", "ITEMS_ANVIL",
            "ITEMS_QUERN",
        },
        set = {
            "IS_GLASS", "ITEMS_HARD",
        },
    },

    SOIL = {
        clear = {
            "IS_METAL", "IS_GEM", "IS_STONE", "IS_CERAMIC", "IS_GLASS",
            "ITEMS_METAL", "ITEMS_BARRED", "ITEMS_SCALED", "ITEMS_HARD",
            "ITEMS_WEAPON", "ITEMS_WEAPON_RANGED",
            "ITEMS_AMMO", "ITEMS_DIGGER",
            "ITEMS_ARMOR", "ITEMS_ANVIL",
            "ITEMS_QUERN",
        },
        set = {
            "IS_STONE",
        },
    },

    -- Liquids kept in containers: tars, oils, spirits, ammonia.
    --
    -- Vanilla's own inorganic liquid carries LIQUID_MISC_OTHER and
    -- nothing stone-like; see inorganic_other.txt line 121. That one
    -- flag is what marks a material as a misc liquid.
    --
    -- WHY THIS EXISTS. Before it, every liquid in a module fell to
    -- RAW, which preserves the donor's flags, and the RAW donor is
    -- plaster. A bucket of coal tar was therefore IS_STONE,
    -- ITEMS_HARD and ITEMS_QUERN: a hard stone you could carve a
    -- quern from, showing up in stone stockpile settings and craft
    -- menus. The clear list mirrors SOIL's; only the set differs.
    LIQUID = {
        clear = {
            "IS_METAL", "IS_GEM", "IS_STONE", "IS_CERAMIC", "IS_GLASS",
            "ITEMS_METAL", "ITEMS_BARRED", "ITEMS_SCALED", "ITEMS_HARD",
            "ITEMS_WEAPON", "ITEMS_WEAPON_RANGED",
            "ITEMS_AMMO", "ITEMS_DIGGER",
            "ITEMS_ARMOR", "ITEMS_ANVIL",
            "ITEMS_QUERN",
        },
        set = {
            "LIQUID_MISC_OTHER",
        },
    },

    -- Dyes: powders DF's hardcoded dye jobs will accept.
    --
    -- MixDye, DyeThread, DyeCloth and DyeLeather are built in job
    -- types with no reaction behind them. DF finds their inputs by
    -- scanning for POWDER_MISC items whose material has IS_DYE set,
    -- and matches colour jobs on the material's powder_dye, which
    -- apply_dye_color (refinish-module-inject.lua) writes after this
    -- preset. IS_DYE alone takes a dye into plain dye jobs, where it
    -- dyes nothing (measured).
    --
    -- DECLARE DYES ON A PLANT HOST, not as inorganics. Measured
    -- 2026-09-23: DF stores an inorganic powder as its bag, under
    -- Furniture as Bags, listed nowhere (vanilla plaster does the
    -- same). Registered under Milled Plants it is listed by name and
    -- never hauled there. As a plant material it lists and hauls under
    -- Milled Plants like every vanilla dye. The two powder flags set
    -- below are the plant powder claim, true only on a plant.
    --
    -- WHY THIS EXISTS, beyond the flag. Two reasons, same shape as
    -- the LIQUID case above.
    --
    -- First, a dye falling to RAW inherits plaster and becomes a
    -- carveable stone, exactly the bug LIQUID was added to kill.
    --
    -- Second, and specific to powders: refinish-scan.lua renames
    -- every powder to "[solid name] dust", and its only exclusion
    -- is a word search on the powder name. That word list would not
    -- catch a colour word, so a dye named for its colour would come
    -- out as "mauve dust". The rename is gated on IS_STONE, IS_METAL,
    -- IS_GEM, SOIL_ANY or SOIL_SAND, so a material carrying none of
    -- them is never reached and keeps the powder name it was given.
    -- The clear list below is what buys that, not an accident of it.
    DYE = {
        clear = {
            "IS_METAL", "IS_GEM", "IS_STONE", "IS_CERAMIC", "IS_GLASS",
            "ITEMS_METAL", "ITEMS_BARRED", "ITEMS_SCALED", "ITEMS_HARD",
            "ITEMS_WEAPON", "ITEMS_WEAPON_RANGED",
            "ITEMS_AMMO", "ITEMS_DIGGER",
            "ITEMS_ARMOR", "ITEMS_ANVIL",
            "ITEMS_QUERN",
        },
        set = {
            "IS_DYE",
            -- Vanilla parity: every vanilla dye carries both (measured
            -- by making-fuel-dye-probe). POWDER_MISC_PLANT names the
            -- Milled Plants storage category the module registers its
            -- dyes into (making-fuel-dye-stock.lua).
            "POWDER_MISC",
            "POWDER_MISC_PLANT",
        },
    },

    -- RAW: No clearing, no setting. Clone's flags are preserved
    -- exactly as-is. Use when the clone source already has the
    -- right flags, or when you want full manual control via
    -- material_flags overrides in the definition.
    RAW = {
        clear = {},
        set = {},
    },
}


-- ==========================================
-- CLONE SOURCE SCORING — CLASS SIGNATURES
-- ==========================================
-- For auto-clone selection, the engine needs to know what flag
-- signature identifies a "good donor" for each material class.
-- These are the flags the engine checks when scanning the
-- inorganic array for clone candidates.
--
-- The engine walks inorganics.all, checks each entry against the
-- required flags, and scores candidates by how cleanly they match.
-- The best scorer becomes the clone source for all materials of
-- that class in the current module pipeline run.
--
-- Fields:
--   require_true  — These material.flags must be true
--   require_false — These material.flags must be false
--   prefer        — Bonus score for these being true (soft preference)
-- ==========================================
CLONE_SIGNATURES = {

    METAL = {
        require_true  = { "IS_METAL" },
        require_false = { "IS_GEM", "IS_GLASS", "IS_CERAMIC" },
        -- Prefer common, clean metals over exotic ones
        prefer        = { "ITEMS_WEAPON", "ITEMS_ARMOR" },
    },

    STONE = {
        require_true  = { "IS_STONE" },
        require_false = { "IS_METAL", "IS_GEM", "IS_GLASS" },
        prefer        = {},
    },

    GEM = {
        require_true  = { "IS_GEM" },
        require_false = { "IS_METAL", "IS_GLASS" },
        prefer        = {},
    },

    CERAMIC = {
        require_true  = { "IS_CERAMIC" },
        require_false = { "IS_METAL", "IS_GEM", "IS_GLASS" },
        prefer        = {},
    },

    -- Soil: scored against stones, not against vanilla soils.
    --
    -- The donor here is structural only. reset_to_neutral blanks
    -- every material AND inorganic flag before the preset runs, and
    -- the SOIL preset clears its list and sets nothing, so the
    -- finished material carries no flags at all regardless of what
    -- was cloned. Nothing a real soil donor has would survive the
    -- reset, so there is no reason to hunt for one.
    --
    -- Stones are the most structurally neutral inorganic and the
    -- signature is already proven, so this mirrors STONE.
    SOIL = {
        require_true  = { "IS_STONE" },
        require_false = { "IS_METAL", "IS_GEM", "IS_GLASS" },
        prefer        = {},
    },

    -- Glass: look for IS_GLASS inorganics (modded worlds may have
    -- them, e.g. cobalt glass). In vanilla worlds, no IS_GLASS
    -- inorganic exists — the evaluator will fail to find a donor.
    -- The engine handles this via fallback to CERAMIC donor (see
    -- refinish-evaluate-clone-source.lua fallback logic).
    GLASS = {
        require_true  = { "IS_GLASS" },
        require_false = { "IS_METAL", "IS_GEM", "IS_STONE" },
        prefer        = { "ITEMS_HARD" },
    },

    -- Liquid: scored against stones, for the same reason SOIL is.
    --
    -- The donor is structural only. reset_to_neutral blanks every
    -- flag before the preset runs, and the LIQUID preset then clears
    -- its list and sets LIQUID_MISC_OTHER, so nothing a donor
    -- carried survives either way. No vanilla inorganic is a good
    -- liquid donor anyway: the one that exists is water ice, which
    -- is a stone by flags.
    LIQUID = {
        require_true  = { "IS_STONE" },
        require_false = { "IS_METAL", "IS_GEM", "IS_GLASS" },
        prefer        = {},
    },

    -- Dye: scored against stones, for the same reason SOIL and
    -- LIQUID are. The donor is structural only. reset_to_neutral
    -- blanks every flag before the preset runs, and the DYE preset
    -- then clears its list and sets IS_DYE, so nothing a donor
    -- carried survives either way.
    --
    -- Scoring against vanilla dyes is not an option even though they
    -- exist: every one of them is a PLANT material, and this table
    -- scores inorganics.
    DYE = {
        require_true  = { "IS_STONE" },
        require_false = { "IS_METAL", "IS_GEM", "IS_GLASS" },
        prefer        = {},
    },

    -- RAW: No signature — the modder must accept whatever the
    -- engine picks. In practice, RAW falls back to the STONE
    -- signature since stones are the most structurally neutral
    -- inorganic type. This fallback is handled in the injection
    -- logic, not here.
    RAW = {
        require_true  = {},
        require_false = {},
        prefer        = {},
    },
    -- ==========================================
    -- CLONE SOURCE SCORING — PLANTS
    -- ==========================================
    PLANT_CLONE_SIGNATURES = {
        BASIC_CROP = {
            require_true  = { "SEED", "DRINK" },
            require_false = { "TREE", "SAPLING" },
            prefer        = { "SUMMER" }
        },
        TREE_TYPE = {
            require_true  = { "TREE", "SAPLING" },
            require_false = { "SEED" },
            prefer        = {}
        }
    }
}


-- ==========================================
-- EXPORTS
-- ==========================================
-- All tables above are global (non-local) so they export
-- through _ENV when loaded via reqscript/script_environment.
-- ==========================================
return _ENV