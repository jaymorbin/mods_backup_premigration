--@ module = true
-- refinish-module-react.lua
-- ==========================================
-- RM MODULE REACTION BUILDER
-- ==========================================
-- Takes validated reaction definitions and constructs live DF
-- reactions in RAM. For each reaction:
--   1. Find a template reaction (auto-score + fallback)
--   2. Deep-copy the template
--   3. Set identity, building, skill, fuel, category
--   4. Build reagents from the definition's type specs
--   5. Build products with material resolution / derivation
--   6. Inject into the live reactions array
--
-- Also handles:
--   - Category injection (menu structure)
--   - Entity permission injection (civ workshop access)
--
-- DEPENDENCIES:
--   refinish-module-types.lua - Reagent types, product types,
--                                building types, skill map
--
-- CALLED FROM:
--   refinish-module-engine.lua (pipeline steps)
-- ==========================================

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- RM's own, and peripheral rather than pipeline. Every line this file
-- writes goes through log(), in the one grammar the log panel reads:
-- SYSTEM SUBSYSTEM SUBJECT TYPE | body.
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
-- A reaction or product this file could not build, or built wrong, is
-- an ERROR: the player meets it in play. A declaration that fell back
-- to something wider or to a default, while the reaction still works,
-- is a WARNING.
--
-- SUBJECT is the correlation slot: the part of the reaction a line is
-- about, or the module it concerns.
--
-- This replaces a log() that took the subsystem as an argument and
-- let refinish-log guess TYPE from the words (read_type) unless a call
-- site said otherwise.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'MODULE_REACT'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

-- A reaction class no material carries. A reagent whose mat_token did
-- not resolve is given it, so the slot matches nothing (see build_reagent,
-- A MISS CLOSES THE GATE).
local UNRESOLVED_TOKEN_CLASS = 'RM_UNRESOLVED_MAT_TOKEN'

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

local types = reqscript('refinish-module-types')

-- Anchored, plain-text prefix test. Local copy of the engine's helper,
-- kept here rather than shared so this file keeps its single require.
-- See the note in refinish-module-engine.lua for why string.find is
-- the wrong tool for this.
local function has_prefix(str, prefix)
    return string.sub(str, 1, #prefix) == prefix
end

-- ==========================================
-- INORGANIC LOOKUP BUILDER
-- ==========================================
-- Builds a name->index dictionary from the live inorganic array.
-- Called once before reaction building so mat_id references can
-- be resolved to numeric indices.
-- ==========================================
local function build_mat_lookup()
    local lookup = {}
    for i, mat in ipairs(df.global.world.raws.inorganics.all) do
        lookup[mat.id] = i
    end
    return lookup
end


-- ==========================================
-- TEMPLATE SCORING
-- ==========================================
-- Given a reaction definition and a candidate template reaction,
-- score how well the template matches the definition's shape.
-- Higher = better match. Used by find_template to pick the best
-- structural donor from the loaded reaction array.
--
-- Scoring criteria:
--   - Building type match (highest weight - wrong building = wrong
--     workshop entirely)
--   - Fuel flag match
--   - Reagent count similarity
--   - Product item_type match
--
-- This is a heuristic, not an exact matcher. The fallback_template
-- field exists as the safety net if scoring picks poorly.
-- ==========================================
local function score_template(sig, def)
    local score = 0
    local building_def = types.BUILDING_TYPES[def.building]

    if building_def and sig.has_building then
        for _, b_type_def in ipairs(building_def.type) do
            for _, b_type_rxn in ipairs(sig.building_types) do
                if b_type_def == b_type_rxn then
                    score = score + 30
                    goto building_matched
                end
            end
        end
        ::building_matched::

        if #building_def.subtype > 0 then
            for _, sub_def in ipairs(building_def.subtype) do
                for _, sub_rxn in ipairs(sig.building_subtypes) do
                    if sub_def == sub_rxn then
                        score = score + 10
                        goto subtype_matched
                    end
                end
            end
            ::subtype_matched::
        end
    end

    local def_fuel = def.fuel or false
    if sig.fuel == def_fuel then
        score = score + 10
    end

    if def.reagents then
        local diff = math.abs(sig.reagent_count - #def.reagents)
        if diff == 0 then
            score = score + 15
        elseif diff <= 2 then
            score = score + 5
        end
    end

    if def.products and #def.products > 0 then
        local want = def.products[1].type
        local wanted_type = types.PRODUCT_TYPES[want]
        local want_improvement = wanted_type and wanted_type.improvement

        local wanted_item_type = wanted_type and wanted_type.item_type
        if wanted_item_type == nil and not want_improvement then
            local resolved = df.item_type[want]
            if type(resolved) == "number" then
                wanted_item_type = resolved
            end
        end

        if want_improvement then
            if sig.has_improvement then
                score = score + 20
            end
        elseif wanted_item_type ~= nil then
            for _, ptype in ipairs(sig.product_item_types) do
                if ptype == wanted_item_type then
                    score = score + 20
                    break
                end
            end
        end
    end

    return score
end


-- ==========================================
-- FIND TEMPLATE REACTION
-- ==========================================
-- Scores every loaded reaction against the definition and returns
-- the best match. Falls back to a named reaction code if the
-- scorer finds nothing suitable.
--
-- Skips RM-injected and module-injected reactions - we only want
-- vanilla or raws-loaded reactions as structural donors.
-- ==========================================
local function find_template(def, fast_reactions_cache)
    local best_rxn = nil
    local best_score = -1

    for _, sig in ipairs(fast_reactions_cache.signatures) do
        local score = score_template(sig, def)
        if score > best_score then
            best_score = score
            best_rxn = sig.ptr
        end
    end

    if not best_rxn and def.fallback_template then
        best_rxn = fast_reactions_cache.by_code[def.fallback_template]
        best_score = 0 -- Fallbacks bypass scoring
    end

    return best_rxn, best_score
end

-- ==========================================
-- RESOLVE ITEM SUBTYPE
-- ==========================================
-- Tools, trapcomps and similar identify their item by an itemdef code
-- string. The reagent and product structs want a numeric subtype, and
-- that number is a position in the matching world.raws.itemdefs list,
-- which shifts whenever a mod adds or removes one.
--
-- So we look it up by code every time, exactly like custom workshops.
--
-- Returns the subtype index, or -1 if it isn't loaded. A -1 leaves the
-- slot unrestricted, which is wrong but far better than silently
-- pointing at whatever now occupies that position, hence the warning.
-- ==========================================

-- Which itemdefs list belongs to which item type. Only the types that
-- actually carry subtypes need an entry.
local ITEMDEF_LISTS = {
    [df.item_type.TOOL]     = "tools",
    [df.item_type.TRAPCOMP] = "trapcomps",
    [df.item_type.WEAPON]   = "weapons",
    [df.item_type.ARMOR]    = "armor",
    [df.item_type.TOY]      = "toys",
    [df.item_type.INSTRUMENT] = "instruments",
    [df.item_type.AMMO]     = "ammo",
    [df.item_type.SIEGEAMMO] = "siege_ammo",
    [df.item_type.SHIELD] = "shields",
    [df.item_type.SHOES] = "shoes",
    [df.item_type.HELM] = "helms",
    [df.item_type.GLOVES] = "gloves",
    [df.item_type.PANTS] = "pants",
}

local itemdef_cache = {}

local itemdef_cache = {}

-- ==========================================
-- ITEMDEF CACHE INVALIDATION
-- ==========================================
-- The cache maps itemdef code to array position and is built once per
-- list on first use. That was safe while every itemdef came from raws,
-- because raws never move within a session.
--
-- Injected tools break it. They are appended at startup and removed
-- again on the save protocol, so a cache built before a clear hands out
-- positions for tools that are no longer there. It does it silently,
-- because the miss branch below only fires when a code is ABSENT from
-- the cache, never when the cached number is stale. A stale hit looks
-- exactly like a good one.
--
-- Same failure shape as the ghost reaction cache use after free: a
-- lookup table built from array positions that outlived the array.
--
-- Two ways in. The tool injector calls this directly when it can reach
-- the module, and raises the global as a fallback for when it cannot.
-- resolve_item_subtype checks the global on every call, which costs one
-- table read and removes the ordering question entirely.
-- ==========================================

function invalidate_itemdef_cache()
    itemdef_cache = {}
    _G.refinish_itemdef_cache_dirty = false
end

-- quiet suppresses the not-found line only. The warning below is
-- correct when this is building a reagent and is nonsense when a key
-- watcher is polling before injection has landed, which it does once
-- a second until the itemdef arrives. Callers that pass quiet report
-- their own deferral through their own once/clear state instead.
local function resolve_item_subtype(item_type, code, quiet)
    -- Cheap gate, checked first. Anything that adds or removes an
    -- itemdef raises this flag, and one stale read here would write a
    -- wrong subtype into a reagent that then silently matches the
    -- wrong item for the rest of the session.
    if _G.refinish_itemdef_cache_dirty then
        invalidate_itemdef_cache()
    end

    local list_name = ITEMDEF_LISTS[item_type]
    if not list_name then
        return -1
    end

    -- JIT GATE: Build dictionary exactly once per item list type
    if not itemdef_cache[list_name] then
        local ok, defs = pcall(function() return df.global.world.raws.itemdefs[list_name] end)
        if not ok or not defs then return -1 end
        
        itemdef_cache[list_name] = {}
        for i, td in ipairs(defs) do
            local got, sub = pcall(function() return td.subtype end)
            if got and type(sub) == "number" then
                itemdef_cache[list_name][td.id] = sub
            else
                itemdef_cache[list_name][td.id] = i
            end
        end
    end

    -- O(1) Instant Lookup
    local subtype = itemdef_cache[list_name][code]
    if not subtype then
        if not quiet then
log('WARNING', string.format("itemdef '%s' not found in %s. slot left unrestricted.",
            tostring(code), list_name), 'ITEMDEF')
        end
        return -1
    end
    
    return subtype
end

-- Kept so existing callers do not change. Tools were the only consumer
-- before trapcomps arrived with the glass unit.
-- item_type decides which itemdefs list the code is looked up in.
-- This used to hardcode TOOL, so every subtype resolved against
-- itemdefs.tools no matter what the reagent's type was. Trapcomps,
-- weapons, armor, toys, instruments, ammo, shields, shoes, helms,
-- gloves and pants all missed, warned, and left the slot
-- unrestricted, which is why the three trapcomp char reactions each
-- accepted any trapcomp. ITEMDEF_LISTS already had every entry;
-- nothing was reaching them.
--
-- Defaults to TOOL so any caller that has not been updated behaves
-- exactly as before.
-- PUBLIC. refinish-resolve delegates here rather than keeping a
-- second cache of the same thing; the tool injector already calls
-- invalidate_itemdef_cache on both ends of every injection and every
-- clear, so this is the copy that is kept correct.
function resolve_tool_subtype(code, item_type, quiet)
    return resolve_item_subtype(item_type or df.item_type.TOOL, code,
                                quiet)
end

-- ---- PUBLISHED FOR THE HOT PATH ----
-- refinish-resolve is called once per poll by watchers running at
-- one frame. Reaching this function through reqscript there costs a
-- script name resolution on every call: measured at roughly 2 ms,
-- which was 407 ms of every wall second across two watchers and cost
-- the fort seven frames a second.
--
-- A GLOBAL, NOT A CACHED ENVIRONMENT, on the far side. A reload
-- builds a new environment holding a new itemdef_cache, so a held
-- reference would keep answering from the old cache while the tool
-- injector invalidates the new one. This line runs again on every
-- load of this file, so the published function is always the live
-- one.
_G.refinish_resolve_tool_subtype = resolve_tool_subtype


-- ==========================================
-- REAGENT FLAG MAP
-- ==========================================
-- The rest of the job item filter vocabulary, past the flags that
-- build_reagent maps by hand. Those are explicit because they carry an
-- alias (glass_material writes flags1.glass), read from outside the
-- flags block (sand_bearing reads rgt_def root), or needed the comment.
-- Everything here has a schema name identical to its struct field, so a
-- table beats another ninety if statements.
--
-- Most of these have no reaction raw token behind them. No raw file can
-- set them and no vanilla reaction exercises the path, so some will be
-- inert in a reaction context. Exposed anyway: an inert flag costs a
-- table row, and the only way to learn which ones bite is to set them.
-- flags1.furniture had no token either and DF rendered it correctly in
-- the reagent tooltip.
--
-- Bit numbers are from df.reaction_reagent_itemst, dumped live. The
-- UNUSED bits are omitted deliberately.
--
-- Module level rather than local to the function: build_reagent runs
-- once per reagent per reaction, and ArgMOD alone has thousands.
local REAGENT_FLAG_MAP = {

    -- Item state, origin and processing history.
    flags1 = {
        "improvable",             --  0  can still take decoration
        "butcherable",            --  1  a corpse a butcher would accept
        "millable",               --  2  goes in a quern
        "allow_buryable",         --  3  permits coffin-bound items
        "undisturbed",            --  5  vermin, not yet agitated
        "collected",              --  6  gathered rather than found
        "sharpenable",            --  7  knappable stone
        "murdered",               --  8  corpse of a murder victim
        "processable",            -- 11  plant with a process reaction
        "cookable",               -- 13  a kitchen would accept it
        "extract_bearing_plant",  -- 14
        "extract_bearing_fish",   -- 15
        "extract_bearing_vermin", -- 16
        "processable_to_vial",    -- 17
        "processable_to_barrel",  -- 19
        "tameable_vermin",        -- 21
        "nearby",                 -- 22  near the workshop specifically
        "milk",                   -- 25  the item is milk
        "milkable",               -- 26  a milkable creature
        "lye_bearing",            -- 31
    },

    -- Material families, decoration state and stockpile designations.
    flags2 = {
        "dye",                --  0  is a dye
        "dyeable",            --  1  can be dyed
        "dyed",               --  2  already dyed
        "sewn_imageless",     --  3  cloth with no image sewn into it
        "glass_making",       --  4  a glassmaking material
        "screw",              --  5  the mechanism part
        "deep_material",      --  9  adamantine and friends
        "melt_designated",    -- 10  flagged for melting
        "allow_artifact",     -- 13  DANGER: lets a reagent take an
                              --      artifact. non_artifact in flags3
                              --      is the one you almost always want.
        "plaster_containing", -- 22
        "lye_milk_free",      -- 27  container holds neither lye nor milk
        "blunt",              -- 28
        "unengraved",         -- 29
    },

    -- Material classes and item circumstance.
    flags3 = {
        "non_absorbent",              --  2
        "non_pressed",                --  3  not yet through a press
        "allow_liquid_powder",        --  4
        "any_craft",                  --  5  also set by the ANY_CRAFT
                                      --      reagent type's own defaults
        "food_storage",               --  7
        "sand",                       --  9  distinct from flags1
                                      --      sand_bearing, which is the
                                      --      one Collect Sand uses
        "can_use_location_reserved",  -- 10
        "written_on",                 -- 11
        "edged",                      -- 12
        "on_ground",                  -- 13  lying loose, not stored
        "divine",                     -- 14
        "crafted_artifact",           -- 15  DANGER: requires an artifact
        "gem",                        -- 20
        "empty_or_water",             -- 21
    },
}

-- ==========================================
-- BUILD REAGENT
-- ==========================================
-- Constructs a single reaction_reagent_itemst from a reagent
-- definition and a base reagent (cloned from the template).
--
-- The base reagent provides valid C++ internal state. After
-- cloning, we zero out ALL item filter flags (flags1-5) to
-- prevent stale template constraints from leaking through
-- (body_part, unrotten, bone, non_economic, etc.). Then we
-- rebuild only what the schema specifies.
--
-- This is the same neutral reset philosophy used for materials:
-- clone for structure, clear for semantics, rebuild from schema.
-- ==========================================
local function build_reagent(rgt_def, base_reagent, mat_lookup, all_reagent_defs)
    local r = df.reaction_reagent_itemst:new()
    r:assign(base_reagent)

    -- ---- NEUTRAL RESET: ITEM FILTER FLAGS ----
    -- Zero out ALL item filter flags inherited from the template.
    -- These flags control what items DF considers valid for this
    -- reagent slot. A creature-body-part template would have
    -- flags2.body_part=true, flags1.unrotten=true, etc. - leaving
    -- these set makes our boulder/bar/powder reagent reject
    -- everything except body parts.
    --
    -- flags1: empty, unrotten, body_part filters, sand_bearing, etc.
    -- flags2: non_economic, building_material, bone, shell, etc.
    -- flags3: metal, stone, gem, wood material-class filters, etc.
    -- flags4, flags5: additional filter integers
    --
    -- Bitfield structs use .whole to access the underlying integer.
    -- After zeroing, only flags explicitly set by the schema
    -- (via the flags block) will be active.
    r.flags1.whole = 0
    r.flags2.whole = 0
    r.flags3.whole = 0
    r.flags4 = 0
    r.flags5 = 0

    -- Also clear tool use and dye color filters
    r.has_tool_use = -1
    r.dye_color = -1

    -- Identity
    r.code = rgt_def.code

    -- Quantity
    r.quantity = rgt_def.quantity or 1
    r.min_dimension = -1

    -- Type resolution: pull field values from the types dictionary
    local rtype = types.REAGENT_TYPES[rgt_def.type]
    if rtype then
        r.item_type = rtype.item_type

        -- Tool reagents name their subtype by itemdef code (see
        -- resolve_tool_subtype). Everything else clears the subtype so
        -- the template's own subtype can't leak through.
        --
        -- Two sources, checked in this order:
        --
        --   rtype.item_subtype   fixed on the type. JUG and LARGE_POT
        --                        are always the same vanilla tool, so
        --                        the code lives in the type table.
        --
        --   rgt_def.tool_id      supplied by the reagent, for the
        --                        generic TOOL type. This is what lets a
        --                        reaction name an injected tool without
        --                        a type entry existing for it.
        --
        -- The type wins when both are present, so a fixed type can
        -- never be redirected by a stray tool_id in a module's JSON.
        -- Neither present means -1, which matches any tool at all.
        -- A numeric item_subtype in the types table IS the subtype
        -- index already, so it must not go through the code lookup.
        -- Five entries declare one that way and each produced a
        -- warning naming itemdef '0' through '4', with the slot left
        -- unrestricted.
        if rtype.item_subtype then
            if type(rtype.item_subtype) == "number" then
                r.item_subtype = rtype.item_subtype
            else
                r.item_subtype =
                    resolve_tool_subtype(rtype.item_subtype, rtype.item_type)
            end
        elseif rtype.needs_tool_id and rgt_def.tool_id then
            r.item_subtype =
                resolve_tool_subtype(rgt_def.tool_id, rtype.item_type)
        else
            r.item_subtype = -1
        end

        -- mat_type: use type default, but POWDER is special -
        -- if mat_id is given, resolve to INORGANIC (0), else wildcard (-1)
        if rgt_def.type == "POWDER" then
            if rgt_def.mat_id and mat_lookup[rgt_def.mat_id] then
                r.mat_type = 0  -- INORGANIC
                r.mat_index = mat_lookup[rgt_def.mat_id]
            else
                r.mat_type = -1
                r.mat_index = -1
            end
        else
            r.mat_type = rtype.mat_type or -1

            -- ---- mat_index resolution from mat_id ----
            -- mat_id present on the definition = the author wants a
            -- gate, REGARDLESS of the type's needs_mat_id flag. The
            -- old form had two silent failure modes, both proven in
            -- the field on the night the peat reaction grabbed the
            -- rot key:
            --   TOOL discarded mat_id outright (needs_mat_id false),
            --   which is how the wet and dried fines split never
            --   actually gated anything.
            --   A lookup miss fell to -1, the WILDCARD, so a gate
            --   that failed to resolve matched EVERY material. The
            --   lookup is built before module materials inject, so
            --   every module-owned mat_id missed it.
            -- The rescan below repairs the timing: on a miss, walk
            -- the live inorganic array once more, because by
            -- reaction-build time the module's materials are in RAM
            -- even though the cached lookup predates them. A miss
            -- AFTER rescan is a real authoring error and is logged
            -- loudly, never swallowed.
            if rgt_def.mat_id then
                local idx = mat_lookup[rgt_def.mat_id]
                if idx == nil then
                    for i, mat in ipairs(df.global.world.raws.inorganics.all) do
                        mat_lookup[mat.id] = i
                    end
                    idx = mat_lookup[rgt_def.mat_id]
                end
                if idx ~= nil then
                    -- A resolved gate must also pin the TYPE, or a
                    -- type of -1 (TOOL's default) leaves the index
                    -- meaningless and the gate open anyway.
                    r.mat_type  = 0
                    r.mat_index = idx
                else
                    r.mat_index = -1
                    -- WARNING: the reaction runs, but this slot takes any material.
                    log('WARNING', 'mat_id [' .. tostring(rgt_def.mat_id)
                        .. '] did not resolve; reagent ships UNGATED.', 'REAGENT')
                end
            elseif rtype.mat_index ~= nil then
                r.mat_index = rtype.mat_index
            else
                r.mat_index = -1
            end
        end

        -- metal_ore resolution from metal_id (ORE_OF type).
        -- For ORE_OF: resolve metal_id to an inorganic index.
        -- For everything else: force -1 to clear any stale value
        -- inherited from the base reagent (e.g. if the base was a
        -- boulder reagent from BRASS_MAKING with metal_ore pointing
        -- at zinc, and we're building a BAR reagent for copper,
        -- the leftover metal_ore would confuse DF).
        --
        -- ---- AND A MISS IS ANNOUNCED HERE TOO ----
        -- `or -1` was the last silent fallback in this function. -1 on
        -- metal_ore is no ore requirement at all, so an ORE_OF reagent
        -- whose metal_id was mistyped did not ask for ore of that
        -- metal, it accepted any boulder the rest of the filter let
        -- through.
        --
        -- Same shape as mat_id and tool_id, which both report, and as
        -- has_tool_use, which now does. It still ends at -1 because
        -- there is no other value to use; the line is what makes it
        -- visible.
        --
        -- No offline check for this one: metal_id resolves against the
        -- inorganic table, which preflight cannot see without the
        -- game's raws, the same reason a bad mat_id is only caught at
        -- injection.
        if rtype.needs_metal_id and rgt_def.metal_id then
            local ore = mat_lookup[rgt_def.metal_id]
            if ore ~= nil then
                r.metal_ore = ore
            else
                r.metal_ore = -1
                log('WARNING', string.format(
                    'metal_id %s did not'
                    .. ' resolve. metal_ore is -1, which is NO ore'
                    .. ' requirement, so this reagent takes any'
                    .. ' boulder the rest of its filter allows.',
                    tostring(rgt_def.metal_id)), 'REAGENT')
            end
        else
            r.metal_ore = -1
        end

        -- reaction_class: use definition override, else type default
        if rgt_def.reaction_class then
            r.reaction_class = rgt_def.reaction_class
        else
            r.reaction_class = rtype.reaction_class or ""
        end

        -- ---- mat_token: ANY MATERIAL, BY FULL TOKEN ----
        -- mat_id names an inorganic only. mat_token names any material
        -- dfhack.matinfo.find can read, a plant's above all:
        --   "mat_token": "PLANT_MAT:ACACIA:WOOD"
        -- which is exactly what a vanilla log reagent names
        -- ([REAGENT:log:1:WOOD:NONE:PLANT_MAT:ACACIA:WOOD],
        -- reaction_dyes.txt). Products have taken mat_token for a while;
        -- this is the reagent half.
        --
        -- Resolved here, at build time, when every module material and
        -- plant host is already in RAM, the moment products resolve
        -- theirs. It runs after the type defaults, mat_id and
        -- reaction_class above, so it wins: a token names both halves of
        -- the pair and pins them together, since an index without its
        -- type means nothing. Declaring both mat_token and mat_id is an
        -- authoring slip, reported, with the token winning, the same
        -- rule products follow.
        --
        -- ---- A MISS CLOSES THE GATE ----
        -- A token that does not resolve must not fall to -1, the
        -- wildcard: a slot meant for one tree's logs would then take
        -- every log in the fort and make that tree's product from them.
        -- Instead the slot is given a reaction class no material
        -- carries, so it matches nothing, the reaction shows and cannot
        -- run, and the log names the token. (mat_id's miss still ships
        -- ungated with a warning; that older rule is left as it was.)
        if rgt_def.mat_token then
            if rgt_def.mat_id then
                log('WARNING', string.format(
                    "reagent declares both mat_token '%s' and mat_id '%s'; the token wins.",
                    tostring(rgt_def.mat_token), tostring(rgt_def.mat_id)), 'REAGENT')
            end
            local info = nil
            pcall(function() info = dfhack.matinfo.find(rgt_def.mat_token) end)
            if info then
                r.mat_type  = info.type
                r.mat_index = info.index
            else
                r.reaction_class = UNRESOLVED_TOKEN_CLASS
                log('ERROR', string.format(
                    "reagent mat_token '%s' did not resolve; the slot is CLOSED"
                    .. " (reaction class %s), so the reaction shows and cannot run.",
                    tostring(rgt_def.mat_token), UNRESOLVED_TOKEN_CLASS), 'REAGENT')
            end
        end

        -- has_tool_use: definition override resolved from a string,
        -- else the type default, else wildcard (-1).
        --
        -- ---- A MISS IS ANNOUNCED, NOT SWALLOWED ----
        -- This used to read `df.tool_uses[name] or -1`, and -1 is the
        -- WILDCARD. So a mistyped tool use did not narrow the filter,
        -- it opened it completely, and nothing anywhere said so:
        -- preflight does not validate this field either.
        --
        -- Same disease the mat_id path was cured of, and the exact
        -- opposite of what vector_id does two blocks down. It still
        -- ends at the type default or -1 because there is no third
        -- value to fall to, but it now says which reagent and which
        -- name, so a wide open filter is a line in the log rather than
        -- a mystery in the fort.
        --
        -- Zero is a legal tool use, LIQUID_COOKING, and zero is truthy
        -- in Lua, so the nil test has to be explicit.
        if rgt_def.has_tool_use then
            local tu = df.tool_uses[rgt_def.has_tool_use]
            if tu ~= nil then
                r.has_tool_use = tu
            else
                r.has_tool_use = (rtype.has_tool_use ~= nil)
                    and rtype.has_tool_use or -1
                log('WARNING', string.format(
                    'has_tool_use %s is not a'
                    .. ' df.tool_uses value. The reagent falls back'
                    .. ' to %s, and -1 is the WILDCARD, so this'
                    .. ' filter is wider than intended.',
                    tostring(rgt_def.has_tool_use),
                    tostring(r.has_tool_use)), 'REAGENT')
            end
        elseif rtype.has_tool_use ~= nil then
            r.has_tool_use = rtype.has_tool_use
        else
            r.has_tool_use = -1
        end
    end

    -- ---- VECTOR ----
    -- DF keeps 136 separate item vectors and this field says which one
    -- the filter searches. It reaches gates nothing else in the schema
    -- can express: ANY_DEAD_DWARF is every corpse a butcher refuses,
    -- citizens, pets and sapient invaders alike, and ANY_MURDERED,
    -- ANY_CAN_ROT and ANY_MELT_DESIGNATED are the same kind of thing.
    --
    -- Resolved against the LIVE enum, never against the list in
    -- types.JOB_ITEM_VECTORS. That list is only there so preflight can
    -- catch a typo offline; if DF adds a vector the engine still finds
    -- it.
    --
    -- A MISS LEAVES THE FIELD ALONE and says so at volume. It does not
    -- fall to 0, which is ANY, and it does not fall to -1. Compare
    -- has_tool_use immediately above, which does fall to -1 on an
    -- unknown string: that is the wildcard, so a typo there silently
    -- opens the filter instead of narrowing it. Same disease the
    -- mat_id path was cured of, and worth curing there too.
    --
    -- Omitting vector_id leaves whatever the structural donor carried,
    -- which is DF's own default for the item type. This is opt in.
    if rgt_def.vector_id ~= nil then
        local vid = nil
        pcall(function() vid = df.job_item_vector_id[rgt_def.vector_id] end)
        if vid ~= nil then
            r.vector_id = vid
        else
            log('WARNING', string.format(
                'vector_id %s is not a'
                .. ' df.job_item_vector_id value. The reagent keeps its'
                .. ' default vector and searches wider than intended.',
                tostring(rgt_def.vector_id)), 'REAGENT')
        end
    end

    -- has_material_reaction_product (e.g. "FIRED_MAT" for clay matching)
    if rgt_def.has_material_reaction_product then
        r.has_material_reaction_product = rgt_def.has_material_reaction_product
    else
        r.has_material_reaction_product = ""
    end

    -- Reagent flags (reaction_reagent_flags level)
    local flags = rgt_def.flags or {}
    r.flags.PRESERVE_REAGENT = flags.preserve or false
    r.flags.IN_CONTAINER = flags.in_container or false
    r.flags.DOES_NOT_DETERMINE_PRODUCT_AMOUNT = flags.does_not_determine_product_amount or false

    -- ---- TYPE-LEVEL FLAGS ----
    -- Some reagent types are defined by a flag rather than an item
    -- type. ANY_CRAFT is item_type -1 plus flags3.any_craft, so the
    -- type dictionary carries the flag and it gets applied here, after
    -- the neutral reset and before the modder's own flags.
    local rtype_def = types.REAGENT_TYPES[rgt_def.type]
    if rtype_def and rtype_def.flags3 then
        for name, val in pairs(rtype_def.flags3) do
            r.flags3[name] = val
        end
    end

    -- flags3:
    --   unimproved  → [NOT_IMPROVED] item must carry no improvements.
    --                 Glazing reactions use it so a glazed craft cannot
    --                 be glazed a second time. Note the raw token and
    --                 the struct field disagree on naming.
    --   any_raw_material → [ANY_RAW_MATERIAL]
    if flags.unimproved ~= nil then
        r.flags3.unimproved = flags.unimproved
    end
    if flags.any_raw_material ~= nil then
        r.flags3.any_raw_material = flags.any_raw_material
    end

    -- flags3 material-class filters. These cut across item types: a
    -- wood filter matches a log, a bed and a wooden jug alike, so pair
    -- them with an item type or with a flags1 category below.
    --   wood   → [WOOD_MATERIAL]
    --   stone  → [STONE_MATERIAL]
    --   metal  → [METAL_MATERIAL]
    --   hard   → [ANY_HARD_MATERIAL]
    --   woven  → cloth that was woven, as opposed to felted or leather
    --
    --   grown_not_crafted → the item was harvested or grown rather than
    --                 built. This is what separates a plump helmet from
    --                 a wooden bed when both answer to flags2.plant.
    --
    --   non_artifact → excludes artifacts. Belongs on EVERY reagent
    --                 that consumes its input, and especially on any
    --                 reagent using item_type -1. Without it a wildcard
    --                 reagent will eventually eat a legendary artifact
    --                 and there is no way to get it back.
    if flags.wood              ~= nil then r.flags3.wood              = flags.wood              end
    if flags.stone             ~= nil then r.flags3.stone             = flags.stone             end
    if flags.metal             ~= nil then r.flags3.metal             = flags.metal             end
    if flags.hard              ~= nil then r.flags3.hard              = flags.hard              end
    if flags.woven             ~= nil then r.flags3.woven             = flags.woven             end
    if flags.grown_not_crafted ~= nil then r.flags3.grown_not_crafted = flags.grown_not_crafted end
    if flags.non_artifact      ~= nil then r.flags3.non_artifact      = flags.non_artifact      end
    -- Item filter flags (flags1/flags2 level)
    -- After neutral reset, all bits are zero. These are rebuilt
    -- only from explicit schema values. Each flag maps to a DF
    -- raw tag on the reagent.
    --
    -- flags1:
    --   empty          → [EMPTY] container must be empty
    --   sand_bearing   → [SAND_BEARING] material must have SOIL_SAND
    --                    (reads from rgt_def root, not flags block)
    -- flags2:
    --   non_economic   → [NON_ECONOMIC] accept non-economic stones
    --   building_material → [BUILDING_MATERIAL] accept building mats
    --   fire_safe      → [FIRE_SAFE] must be fire safe
    --   magma_safe     → [MAGMA_SAFE] must be magma safe
    --   allow_melt_dump → [ALLOW_MELT_DUMP] accept melt-designated items
    if flags.empty ~= nil then
        r.flags1.empty = flags.empty
    end
    if rgt_def.sand_bearing ~= nil then
        r.flags1.sand_bearing = rgt_def.sand_bearing
    end
    if flags.non_economic ~= nil then
        r.flags2.non_economic = flags.non_economic
    end
    if flags.building_material ~= nil then
        r.flags2.building_material = flags.building_material
    end
    if flags.fire_safe ~= nil then
        r.flags2.fire_safe = flags.fire_safe
    end
    if flags.magma_safe ~= nil then
        r.flags2.magma_safe = flags.magma_safe
    end
    if flags.allow_melt_dump ~= nil then
        r.flags2.allow_melt_dump = flags.allow_melt_dump
    end
    -- flags1 also carries two material filters:
    --   glass  → [GLASS_MATERIAL] item must be made of glass.
    --            ArgMOD puts this on 30 of his 38 jug reagents so the
    --            chemist takes glass jugs specifically - without it the
    --            reaction would grab ceramic and metal jugs too.
    if flags.glass_material ~= nil then
        r.flags1.glass = flags.glass_material
    end
    -- DF has no 'rotten' flag, only 'unrotten', and no inverse of it.
    -- A reagent either demands fresh material or accepts anything.
    -- Requiring rot specifically is not expressible.
    if flags.unrotten ~= nil then
        r.flags1.unrotten = flags.unrotten
    end

    -- flags2 carries the material-family filters. On an untyped reagent
    -- (item_type -1) these do ALL of the filtering, so dropping every
    -- one of them turns the reagent into a wildcard that matches every
    -- item in the fortress. Confirmed live: a BODY_PART reagent whose
    -- only flag was unrotten took a fuel bar and two pitch buckets.
    --
    -- Creature side:
    --   body_part   → [USE_BODY_COMPONENT] item is a body part. This
    --                 one is sufficient on its own; verified taking
    --                 raw hides while leaving bars and buckets alone.
    --   bone        → [ANY_BONE_MATERIAL]
    --   shell       → [ANY_SHELL_MATERIAL]
    --   horn        → [ANY_HORN_MATERIAL]
    --   pearl       → [ANY_PEARL_MATERIAL]
    --   ivory_tooth → [ANY_TOOTH_MATERIAL]
    --   totemable   → skull and similar, what a totem can be made from
    --   leather     → [ANY_LEATHER_MATERIAL] tanned hide only. A raw
    --                 hide is a body part and answers to body_part.
    --   silk        → [ANY_SILK_MATERIAL]
    --   yarn        → [ANY_YARN_MATERIAL]
    --   hair_wool   → hair and wool before spinning
    --   soap        → [ANY_SOAP_MATERIAL]
    --
    -- Plant side:
    --   plant       → [ANY_PLANT_MATERIAL] anything made of plant
    --                 material, which includes wooden furniture and
    --                 plant cloth, not just harvested plants. Vanilla
    --                 pairs it with an item type: the gukil strings
    --                 reagent is THREAD at mat -1/-1 carrying nothing
    --                 else. Narrow it with an item type or with
    --                 flags3.grown_not_crafted.
    if flags.body_part   ~= nil then r.flags2.body_part   = flags.body_part   end
    if flags.bone        ~= nil then r.flags2.bone        = flags.bone        end
    if flags.shell       ~= nil then r.flags2.shell       = flags.shell       end
    if flags.horn        ~= nil then r.flags2.horn        = flags.horn        end
    if flags.pearl       ~= nil then r.flags2.pearl       = flags.pearl       end
    if flags.ivory_tooth ~= nil then r.flags2.ivory_tooth = flags.ivory_tooth end
    if flags.totemable   ~= nil then r.flags2.totemable   = flags.totemable   end
    if flags.leather     ~= nil then r.flags2.leather     = flags.leather     end
    if flags.silk        ~= nil then r.flags2.silk        = flags.silk        end
    if flags.yarn        ~= nil then r.flags2.yarn        = flags.yarn        end
    if flags.hair_wool   ~= nil then r.flags2.hair_wool   = flags.hair_wool   end
    if flags.soap        ~= nil then r.flags2.soap        = flags.soap        end
    if flags.plant       ~= nil then r.flags2.plant       = flags.plant       end

    -- flags1 item categories. These are job item filter bits with no
    -- reaction raw token behind them, so no raw file can express them.
    -- Runtime injection can. Untested in a reaction context, which is
    -- exactly why the furniture intake is worth trying first.
    --   furniture      → item is furniture (bed, table, cabinet, door)
    --   finished_goods → item is a finished good
    --   ammo           → item is ammunition
    if flags.furniture      ~= nil then r.flags1.furniture      = flags.furniture      end
    if flags.finished_goods ~= nil then r.flags1.finished_goods = flags.finished_goods end
    if flags.ammo           ~= nil then r.flags1.ammo           = flags.ammo           end

    -- flags1 exclusions. Same story as the categories above: job item
    -- filter bits with no raw token, so no raw file can set them.
    --
    --   not_bin → UNRESOLVED semantics, two live measurements that
    --             disagree. On the furniture wildcard (item_type
    --             ANY + flags): a FILLED chest reds the menu with
    --             this set and burns with it removed, consistent
    --             with a container=false test plus no-bins. On the
    --             TYPED reagents (ASH_BOX etc): the SAME filled
    --             chest, SAME flag, gets fetched and consumed.
    --             DF applies this bit differently by reagent shape,
    --             mechanism unmeasured. Consequence that matters:
    --             this flag is NOT reliable cargo protection. The
    --             cargo watcher is the protection; this bit is at
    --             most a menu courtesy on wildcards.
    --
    --   solid   → item is in a solid state. Worth pairing with any
    --             item_type -1 reagent to keep liquids and powders out
    --             of a filter that was only ever meant for objects.
    if flags.not_bin ~= nil then r.flags1.not_bin = flags.not_bin end
    if flags.solid   ~= nil then r.flags1.solid   = flags.solid   end

    -- Everything else in the filter vocabulary. See REAGENT_FLAG_MAP
    -- above the function. A schema flag not listed there and not
    -- handled explicitly above is silently ignored, which is why
    -- preflight validates flag names against the same source.
    for bf_name, names in pairs(REAGENT_FLAG_MAP) do
        local bf = r[bf_name]
        for _, flag_name in ipairs(names) do
            if flags[flag_name] ~= nil then
                bf[flag_name] = flags[flag_name]
            end
        end
    end

    -- Container linkage: contains field.
    -- The "contains" array on a reagent holds the INDICES (positions)
    -- of the reagents it contains. We resolve the code name to an
    -- index by finding which position in the reaction's reagent list
    -- has that code.
    r.contains:resize(0)
    if rgt_def.contains then
        for idx, other_def in ipairs(all_reagent_defs) do
            if other_def.code == rgt_def.contains then
                -- DF uses 0-based indexing for the contains array
                r.contains:insert('#', idx - 1)
                break
            end
        end
    end

    return r
end

-- ==========================================
-- FIND IMPROVEMENT DONOR
-- ==========================================
-- Improvement products are a different C++ class from item products
-- (reaction_product_item_improvementst rather than
-- reaction_product_itemst), with different fields and its own flag
-- layout.
--
-- Rather than construct one from nothing, we clone a live one, exactly
-- as reagents and item products clone their template. Any glazing
-- reaction in the loaded raws will do as a donor.
--
-- Returns nil if the loaded raws contain no improvement product at all,
-- in which case the caller skips the reaction rather than injecting it
-- half-built.
-- ==========================================
local function find_improvement_donor()
    local fallback = nil
    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        for _, prod in ipairs(rxn.products) do
            if df.reaction_product_item_improvementst:is_instance(prod) then
                local ok, glazed = pcall(function() return prod.flags.GLAZED end)
                if ok and glazed then
                    return prod
                end
                fallback = fallback or prod
            end
        end
    end
    return fallback
end


-- ==========================================
-- BUILD IMPROVEMENT PRODUCT
-- ==========================================
-- Constructs a reaction_product_item_improvementst from a product
-- definition and a donor cloned from the live raws.
--
-- Only the fields we are certain of are overwritten. The donor's flag
-- bits are deliberately kept: every improvement in the schema uses
-- GET_MATERIAL_FROM_REAGENT, which is what any glazing donor already
-- has set. Validation rejects other material modes rather than letting
-- them inject against flags we did not set.
--
-- improvement_type is resolved by name through df.improvement_type so
-- there is no hardcoded enum value to drift.
-- ==========================================
local function build_improvement_product(prod_def, donor)
    local p = df.reaction_product_item_improvementst:new()
    p:assign(donor)

    -- ---- IDENTITY ----
    p.product_token        = ""
    p.product_to_container = ""
    p.part_token           = ""

    p.target_reagent = prod_def.target_reagent or ""

    -- ---- IMPROVEMENT TYPE ----
    -- GLAZED is not a member of df.improvement_type. The enum has 15
    -- entries and glaze is not one of them. A working vanilla glazing
    -- product is improvement_type COVERED with a GLAZED bit set in its
    -- flags, so glaze is a variety of covering rather than a type of
    -- its own.
    --
    -- The schema keeps saying GLAZED because that is the name the DF
    -- raws use and the name a modder will reach for. The translation
    -- to COVERED plus a flag happens here.
    --
    -- Read directly off GLAZE_JUG in a live install:
    --   improvement_type 1 (COVERED), flags {GET_MATERIAL_PRODUCT, GLAZED}
    local want_glazed = (prod_def.improvement_type == "GLAZED")
    local type_name   = want_glazed and "COVERED" or prod_def.improvement_type

    local itype = df.improvement_type[type_name]
    if type(itype) ~= "number" then
        -- ERROR: the reaction runs without this product, which the player will meet in play.
        log('ERROR', string.format(
            "unknown improvement_type '%s'. product skipped.",
            tostring(prod_def.improvement_type)), 'PRODUCT')
        return nil
    end
    p.improvement_type          = itype
    p.improvement_specific_type = prod_def.improvement_specific_type or 0

    p.probability = prod_def.probability or 100

    -- ---- NEUTRAL RESET: FLAGS ----
    -- Same rule build_product follows: clone for C++ structure, zero
    -- every semantic flag, rebuild from schema.
    --
    -- This used to keep the donor's flags on the assumption that any
    -- improvement donor would already be set for material-from-reagent.
    -- The donor is whatever comes first in raws order, so in practice
    -- that meant inheriting GET_MATERIAL_SAME from a scroll and no
    -- GLAZED bit at all.
    for bit, _ in pairs(p.flags) do
        p.flags[bit] = false
    end

    p.flags.GET_MATERIAL_PRODUCT = true
    if want_glazed then
        p.flags.GLAZED = true
    end

    -- ---- MATERIAL ----
    -- The improvement takes its material from a reagent's reaction
    -- product, e.g. the GLAZE_MAT of whatever is in the glaze slot.
    -- GET_MATERIAL_PRODUCT above is what makes DF read these two.
    p.mat_type  = -1
    p.mat_index = -1
    p.get_material.reagent_code = prod_def.get_material_product.reagent_code
    p.get_material.product_code = prod_def.get_material_product.product_code

    return p
end

-- ==========================================
-- BUILD PRODUCT
-- ==========================================
-- Constructs a single reaction_product_itemst from a product
-- definition and a base product (cloned from the template).
--
-- Same neutral reset philosophy as build_reagent: clone for
-- C++ structure, zero all semantic flags, rebuild from schema.
-- Without this, template flags like CRAFTS (random craft output)
-- or USE_REAGENT_ITEM leak through and override our product type.
-- ==========================================
local function build_product(prod_def, base_product, mat_lookup)
    local p = df.reaction_product_itemst:new()
    p:assign(base_product)

    -- ---- NEUTRAL RESET: PRODUCT FLAGS ----
    -- Zero all product flags inherited from the template.
    -- These flags control what DF produces and how it resolves
    -- the output material. A craft-making template would have
    -- CRAFTS=true, causing random craft items instead of our
    -- specified product type.
    --
    -- Known flags:
    --   GET_MATERIAL_SAME, GET_MATERIAL_PRODUCT - material resolution
    --   FORCE_EDGE - edged item (knapping)
    --   PASTE, PRESSED - material state overrides
    --   CRAFTS - random craft item generation (the crown/earring bug)
    --   USE_FULL_REACTION_PRODUCT_CLASS - advanced material derivation
    --   USE_REAGENT_ITEM - output uses reagent's item type
    --   TRANSFER_ARTIFACT_STATUS - artifact inheritance
    --
    -- All zeroed, then rebuilt from schema below.
    p.flags.GET_MATERIAL_SAME = false
    p.flags.GET_MATERIAL_PRODUCT = false
    p.flags.FORCE_EDGE = false
    p.flags.PASTE = false
    p.flags.PRESSED = false
    p.flags.CRAFTS = false
    p.flags.USE_FULL_REACTION_PRODUCT_CLASS = false
    p.flags.USE_REAGENT_ITEM = false
    p.flags.TRANSFER_ARTIFACT_STATUS = false

    -- Clear get_material linkage from template
    p.get_material.reagent_code = ""
    p.get_material.product_code = ""

    -- Clear container linkage from template
    p.product_to_container = ""

    -- ---- ITEM TYPE ----
    -- Named entries in PRODUCT_TYPES exist for the cases that need a
    -- non-default mat_type or a special flag. Anything else resolves by
    -- name straight out of df.item_type, which covers the whole item
    -- enum without a table row per kind.
    --
    -- Previously an unrecognised type left the template donor's
    -- item_type in place, which produced the wrong item silently.
    local ptype = types.PRODUCT_TYPES[prod_def.type]
    if ptype and ptype.item_type ~= nil then
        p.item_type = ptype.item_type
    else
        local resolved = df.item_type[prod_def.type]
        if type(resolved) == "number" then
            p.item_type = resolved
        else
            -- ERROR: the reaction runs without this product, which the player will meet in play.
            log('ERROR', string.format("unknown product type '%s'. product skipped.",
            tostring(prod_def.type)), 'PRODUCT')
            return nil
        end
    end

    -- CRAFTS is carried by a flag, not an item type. The neutral reset
    -- above cleared it, so set it back on for products that want it.
    if ptype and ptype.crafts then
        p.flags.CRAFTS = true
    end

    -- PASTE is the same story: cleared by the neutral reset, set back
    -- on when the schema asks for it. Vanilla marks paper slurry as a
    -- paste (PRODUCT_PASTE on MAKE_SLURRY_FROM_PLANT), so the pulp
    -- globs carry it to match. If the press turns out not to read the
    -- flag, it is inert and costs nothing.
    if prod_def.paste then
        p.flags.PASTE = true
    end

    -- ---- ITEM SUBTYPE ----
    -- Default -1, because template donors carry specific subtypes
    -- (an instrument subtype, say) that would contaminate the product.
    -- When the schema names one, resolve the itemdef code at build time
    -- since those indices shift with mod load order.
    p.item_subtype = -1
    if prod_def.subtype then
        p.item_subtype = resolve_item_subtype(p.item_type, prod_def.subtype)
    end

    -- Count and dimension
    p.count = prod_def.count or 1
    p.product_dimension = prod_def.dimension or 150
    p.probability = prod_def.probability or 100

    -- Material resolution: exactly one of FOUR modes
    --
    -- Mode 0: a full material TOKEN, resolved live at build time.
    --
    -- WHY THIS EXISTS. Every other mode resolves a material through a
    -- static table, and a PLANT material cannot be expressed that
    -- way: its mat_type is 419 plus the host plant's own index, which
    -- is not knowable until the host is injected. So a product that
    -- wants one names the whole token and this resolves it against
    -- the live raws.
    --
    -- ORDER MAKES IT SAFE. The engine injects plants before materials
    -- and reactions, so any host a module ships is already in
    -- world.raws.plants.all by the time products build. A token that
    -- does not resolve fails LOUD and skips the product, rather than
    -- falling through to a wildcard that would silently grab the
    -- wrong material.
    --
    -- MEASURED, not assumed: a reaction product carrying a plant
    -- material produces correctly. One live product slot was pointed
    -- at PLANT_MAT:MAKING_FUEL_COAL_HOST:CHARCOAL and the job dropped
    -- the bar. reaction_product_itemst::produce handles mat_type 419
    -- and above exactly as it handles an inorganic.
    --
    --   { "type": "BAR", "count": 1, "dimension": 150,
    --     "mat_token": "PLANT_MAT:MAKING_FUEL_COAL_HOST:CINDER" }
    --
    -- Takes precedence over mat_id, and a product declaring both is a
    -- contradiction: the token is used and the mat_id is named in the
    -- log so the schema gets fixed rather than quietly half read.
    if prod_def.mat_token then
        if prod_def.mat_id then
            log('WARNING', string.format(
                "product declares both mat_token '%s'"
                .. " and mat_id '%s'. The token wins; remove the mat_id.",
                tostring(prod_def.mat_token), tostring(prod_def.mat_id)), 'PRODUCT')
        end

        local mi = nil
        pcall(function() mi = dfhack.matinfo.find(prod_def.mat_token) end)
        if not mi then
            -- ERROR: the reaction runs without this product, which the player will meet in play.
            log('ERROR', string.format(
                "product mat_token '%s' does not"
                .. " resolve. If it names a plant host, the host must be"
                .. " injected before reactions build. product skipped.",
                tostring(prod_def.mat_token)), 'PRODUCT')
            return nil
        end

        p.mat_type  = mi.type
        p.mat_index = mi.index
        p.flags.GET_MATERIAL_SAME = false
        p.flags.GET_MATERIAL_PRODUCT = false
        p.get_material.reagent_code = ""
        p.get_material.product_code = ""

    -- Mode 1: Direct mat_id -> resolved inorganic index
    elseif prod_def.mat_id then
        p.mat_type = (ptype and ptype.mat_type) or 0  -- default INORGANIC
        -- A product type with mat_subtypes carries a builtin material
        -- whose index selects WHICH form of it. COAL is the only one so
        -- far: 0 is coke, 1 is charcoal. Neither is an inorganic, so the
        -- lookup below can never find them, and letting it miss wrote
        -- -1 into every coal bar RM has ever built.
        --
        -- An unmapped name fails hard rather than falling back. The
        -- reason this went unnoticed for so long is that the old path
        -- failed silently and produced a plausible looking item.
        if ptype and ptype.mat_subtypes then
            local sub = ptype.mat_subtypes[prod_def.mat_id]
            if sub == nil then
                local names = {}
                for k in pairs(ptype.mat_subtypes) do names[#names + 1] = k end
                table.sort(names)
                -- ERROR: the reaction runs without this product, which the player will meet in play.
                log('ERROR', string.format(
                    "product type '%s' has no mat_subtype '%s'. expected one of: %s. product skipped.",
                    tostring(prod_def.type), tostring(prod_def.mat_id),
                    table.concat(names, ", ")), 'PRODUCT')
                return nil
            end
            p.mat_index = sub

        -- A builtin-material product has no inorganic to find. Force
        -- -1 rather than leaning on the lookup missing.
        elseif ptype and ptype.builtin then
            p.mat_index = -1
        else
            -- Same disease the REAGENT side was cured of, found the
            -- hard way on the PRODUCT side: a lookup miss fell to
            -- -1, and a -1 product resolves to DF's builtin
            -- fallback. Scar refinement: for a BOULDER that
            -- fallback produced MAGMA, live, from press cork. The
            -- cure is the same cure: module materials inject after
            -- the lookup is built, so a miss rescans the live
            -- inorganic array once, and only a post-rescan miss is
            -- a real authoring error, logged loudly, never -1.
            local idx = mat_lookup[prod_def.mat_id]
            if idx == nil then
                for i, mat in ipairs(df.global.world.raws.inorganics.all) do
                    mat_lookup[mat.id] = i
                end
                idx = mat_lookup[prod_def.mat_id]
            end
            if idx == nil then
                idx = -1
                -- ERROR: the product comes out as the wrong material, which the player will meet in play.
                log('ERROR', 'PRODUCT mat_id ['
                    .. tostring(prod_def.mat_id)
                    .. '] did not resolve; product ships as '
                    .. 'builtin fallback. This is the magma bug.', 'PRODUCT')
            end
            p.mat_index = idx
        end
        p.flags.GET_MATERIAL_SAME = false
        p.flags.GET_MATERIAL_PRODUCT = false
        p.get_material.reagent_code = ""
        p.get_material.product_code = ""

    -- Mode 2: Inherit material from a reagent (sharp rock pattern)
    elseif prod_def.get_material_same then
        p.mat_type = -1
        p.mat_index = -1
        p.flags.GET_MATERIAL_SAME = true
        p.flags.GET_MATERIAL_PRODUCT = false
        p.get_material.reagent_code = prod_def.get_material_same
        p.get_material.product_code = ""

    -- Mode 3: Derive from reagent's reaction product (clay bricks, soap)
    elseif prod_def.get_material_product then
        p.mat_type = -1
        p.mat_index = -1
        p.flags.GET_MATERIAL_SAME = false
        p.flags.GET_MATERIAL_PRODUCT = true
        p.get_material.reagent_code = prod_def.get_material_product.reagent_code
        p.get_material.product_code = prod_def.get_material_product.product_code

    -- Mode 4: Builtin material carried by the product type itself.
    -- Ash, pearlash, coal and potash bars name no material, because the
    -- type already says which one it is.
    elseif ptype and ptype.builtin then
        p.mat_type  = ptype.mat_type
        p.mat_index = -1
        p.flags.GET_MATERIAL_SAME = false
        p.flags.GET_MATERIAL_PRODUCT = false
        p.get_material.reagent_code = ""
        p.get_material.product_code = ""
    end

    -- Product-to-container linkage
    if prod_def.to_container then
        p.product_to_container = prod_def.to_container
    else
        p.product_to_container = ""
    end

    -- Force edge flag (knapping pattern)
    p.flags.FORCE_EDGE = prod_def.force_edge or false

    return p
end

-- ==========================================
-- RESOLVE CUSTOM WORKSHOP
-- ==========================================
-- Custom workshops (ArgMOD's Chemist, vanilla's Soap Maker) are raw
-- objects rather than df.workshop_type enum entries. A reaction points
-- at one by storing the workshop's runtime index in building.custom.
--
-- That index depends on raw load order, so it can't be a constant in
-- the types dictionary - we look it up by code string at build time.
--
-- Returns the index, or nil if no workshop with that code is loaded
-- (i.e. the modder's building raws aren't installed).
-- ==========================================
local custom_workshop_cache = nil

local function resolve_custom_workshop(code)
    -- JIT GATE: Build dictionary exactly once
    if not custom_workshop_cache then
        -- BOTH custom building vectors. A FURNACE class definition
        -- registers in buildings.furnaces and never appears in
        -- buildings.workshops, so a workshops-only walk reports
        -- every furnace reaction's building as missing and leaves
        -- the template's building in place. The vectors share an
        -- id space, so one flat code -> id map covers both.
        local ok, raws = pcall(function() return df.global.world.raws.buildings end)
        if not ok or not raws then return nil end

        custom_workshop_cache = {}
        for _, vec in ipairs({ raws.workshops, raws.furnaces }) do
            for i, ws in ipairs(vec) do
                local got, id = pcall(function() return ws.id end)
                if got and type(id) == "number" then
                    custom_workshop_cache[ws.code] = id
                else
                    custom_workshop_cache[ws.code] = i
                end
            end
        end
    end
    
    -- O(1) Instant Lookup
    return custom_workshop_cache[code]
end

-- ==========================================
-- PUBLIC: INJECT REACTIONS
-- ==========================================
-- Main entry point for reaction building. Takes a list of
-- validated reaction definitions and injects each into the
-- live reactions array.
--
-- Parameters:
--   reactions - Array of reaction definition tables
--   prefix   - Module's ID prefix string
--   mod_name - Module's display name (for logging)
--   registry - The module registry (_G.refinish_module_registry)
--
-- Returns: count of reactions successfully injected
-- ==========================================
local function disable_fortress_mode(rxn) rxn.flags.FORTRESS_MODE_ENABLED = false end
local function set_fortress_mode(rxn, val) rxn.flags.FORTRESS_MODE_ENABLED = val end

function inject_reactions(reactions_defs, prefix, mod_name, registry)
    local debug_react = false
    -- FLUSH CACHES TO PREVENT DANGLING C++ POINTERS ON RESTART
    custom_workshop_cache = nil
    itemdef_cache = {}
    
    local reactions_array = df.global.world.raws.reactions.reactions
    local mat_lookup = build_mat_lookup()
    local count = 0

    -- Pull all C++ reactions into pure Lua signatures ONCE.
    -- This prevents 10,000,000+ C++ boundary crossings during template scoring.
    local fast_reactions_cache = { signatures = {}, by_code = {} }
    
    for _, rxn in ipairs(reactions_array) do
        fast_reactions_cache.by_code[rxn.code] = rxn
        
        -- Skip RM core reactions and procedural junk so we don't even cache them
        if not has_prefix(rxn.code, "REFINISH_STEEL_") and not rxn.flags.GENERATED then
            
            local is_module = false
            if registry then
                for prefix, _ in pairs(registry) do
                    if has_prefix(rxn.code, prefix) then 
                        is_module = true 
                        break 
                    end
                end
            end

            if not is_module then
                local sig = {
                    ptr = rxn,
                    code = rxn.code,
                    has_building = (rxn.building and rxn.building.type) and true or false,
                    building_types = {},
                    building_subtypes = {},
                    fuel = rxn.flags.FUEL,
                    reagent_count = rxn.reagents and #rxn.reagents or 0,
                    has_improvement = false,
                    product_item_types = {}
                }
                
                if sig.has_building then
                    for _, bt in ipairs(rxn.building.type) do table.insert(sig.building_types, bt) end
                    for _, bst in ipairs(rxn.building.subtype) do table.insert(sig.building_subtypes, bst) end
                end
                
                if rxn.products then
                    for _, prod in ipairs(rxn.products) do
                        if df.reaction_product_item_improvementst:is_instance(prod) then
                            sig.has_improvement = true
                        elseif df.reaction_product_itemst:is_instance(prod) then
                            table.insert(sig.product_item_types, prod.item_type)
                        end
                    end
                end
                
                table.insert(fast_reactions_cache.signatures, sig)
            end
        end
    end

    for _, def in ipairs(reactions_defs) do
        local full_id = prefix .. "RXN_" .. def.key

        -- ---- STEP 1: FIND TEMPLATE ----
        -- Pass the fast cache in to bypass the C++ boundary
        local template, template_score = find_template(def, fast_reactions_cache)
        if not template then
            -- ERROR: this reaction is not built, which the player will meet in play.
            log('ERROR', string.format(
                "No template could be found for [%s].", full_id
            ), 'TEMPLATE')
            goto continue
        end

        -- Log the template selection so the modder can verify
        -- the engine picked a sensible structural donor
        if debug_react then
            log('DETAIL', string.format(
                "[%s] -> template [%s] (score %d, building %s, skill %s).",
                full_id, template.code, template_score,
                def.building or "nil", def.skill or "inherited"
            ), 'TEMPLATE')
        end

        -- ---- STEP 2: DEEP COPY TEMPLATE ----
        local rxn = df.reaction:new()
        rxn:assign(template)

        -- ---- STEP 2.5: NEUTRAL RESET - REACTION FLAGS ----
        -- Zero all reaction-level flags inherited from the template.
        -- Same philosophy as reagent/product neutral resets: clone
        -- for C++ structure, zero semantics, rebuild from schema.
        -- Without this, template flags like GENERATED (procedural
        -- instrument reactions), AUTOMATIC, ADVENTURE_MODE_ENABLED,
        -- and WORLDGEN_ENABLED bleed through and contaminate the
        -- injected reaction's identity.
        rxn.flags.FUEL = false
        rxn.flags.AUTOMATIC = false
        rxn.flags.ADVENTURE_MODE_ENABLED = false
        rxn.flags.GENERATED = false
        rxn.flags.WORLDGEN_ENABLED = false
        pcall(disable_fortress_mode, rxn)

        -- Clear template identity baggage. Generated reactions carry
        -- raw_strings full of instrument tokens, descriptions with
        -- item references, and source entity/historical figure IDs
        -- that have no meaning for module reactions.
        rxn.raw_strings:resize(0)
        rxn.descriptions:resize(0)
        rxn.source_hfid = -1
        rxn.source_enid = -1

        -- Numeric fields that vary across template donors and have
        -- no schema override. Neutral values sourced from vanilla
        -- MAKE_PLASTER_POWDER / STEEL_MAKING as reference:
        --   max_multiplier = 1 (no output scaling)
        --   rand_range, skill_mult, attr_gain, exp_gain = 0
        -- Generated reactions carry non-zero values for these
        -- (e.g. rand_range=11, skill_mult=5) that would silently
        -- alter crafting behavior if left in place.
        rxn.max_multiplier = 1
        rxn.rand_range = 0
        rxn.skill_mult = 0
        rxn.attr_gain = 0
        rxn.exp_gain = 0

        -- ---- STEP 3: IDENTITY ----
        rxn.code = full_id
        rxn.name = def.name

        -- ---- STEP 3c: DESCRIPTIONS ----
        -- DF renders reaction.descriptions in the task pane, under
        -- its own Produces/Requires block, following the highlight
        -- natively. Proven live: struct is reaction_description with
        -- a text field, built with the same new-and-insert idiom the
        -- reaction classes use. The neutral reset above already
        -- wiped the template's vector, so what lands here is only
        -- what the schema says.
        --
        -- "description" on a reaction is optional: a string is one
        -- entry, an array is one entry per element for authors who
        -- want paragraphs. Ghost clones deep-copy the base, so
        -- swapped jobs keep their prose without a line of support.
        if def.description then
            local entries = def.description
            if type(entries) ~= "table" then entries = { entries } end
            for _, line in ipairs(entries) do
                if type(line) == "string" and line ~= "" then
                    local d = df.reaction_description:new()
                    d.text = line
                    rxn.descriptions:insert('#', d)
                end
            end
        end

        -- ---- STEP 4: CATEGORY ----
        rxn.category = def.category or ""

        -- ---- STEP 5: FUEL ----
        rxn.flags.FUEL = def.fuel or false

        -- ---- STEP 5.5: FORTRESS MODE FLAG ----
        -- Set FORTRESS_MODE_ENABLED explicitly from the schema.
        -- Default: false. Modder sets true when they intend the
        -- reaction to be available to the player regardless of civ
        -- permits. This is an intentional choice, never automatic.
        local rf = def.reaction_flags or {}
        pcall(set_fortress_mode, rxn, rf.fortress_mode or false)

        -- ---- STEP 6: BUILDING ----
        -- Overwrite the building type/subtype/custom arrays from
        -- the types dictionary. This ensures the reaction appears
        -- at the correct workshop regardless of what the template had.
        local building_def = types.BUILDING_TYPES[def.building]
        if building_def then
            -- Custom workshops need a runtime lookup. Resolve FIRST, so
            -- a failure leaves the template's building intact instead of
            -- writing a half-built one that points nowhere.
            local custom_idx = nil
            local custom_ok  = true
            if building_def.custom_code then
                custom_idx = resolve_custom_workshop(building_def.custom_code)
                if not custom_idx then
                    custom_ok = false
                    log('WARNING', string.format("[%s] needs custom workshop '%s', which is missing. Building left unchanged.",
                    tostring(def.id), building_def.custom_code), 'BUILDING')
                end
            end

            if custom_ok then
                -- Menu hotkey. DF stores one per building variant,
                -- parallel to type/subtype/custom, which is why it is
                -- inserted inside the loop rather than set once.
                -- Verified against MAKE_LEAD_GLASS_ENORMOUSCORKSCREW,
                -- where the vector runs alongside the other three.
                --
                -- Resolved by name so there is no interface_key value
                -- hardcoded here. Default 0 is "no hotkey", which is
                -- what every reaction got before this.
                local hotkey = 0
                if def.building_hotkey then
                    local k = df.interface_key[def.building_hotkey]
                    if type(k) == "number" then
                        hotkey = k
                    else
                        log('WARNING', string.format("[%s] has unknown building_hotkey '%s'. Ignored.",
                            tostring(def.key), tostring(def.building_hotkey)), 'HOTKEY')
                    end
                end

                rxn.building.type:resize(0)
                rxn.building.subtype:resize(0)
                rxn.building.custom:resize(0)
                rxn.building.hotkey:resize(0)

                for i, bt in ipairs(building_def.type) do
                    rxn.building.type:insert('#', bt)
                    rxn.building.subtype:insert('#', building_def.subtype[i])
                    rxn.building.custom:insert('#', custom_idx or building_def.custom[i])
                    rxn.building.hotkey:insert('#', hotkey)
                end
            end
        end

        -- ---- STEP 7: SKILL ----
        if def.skill and types.SKILL_MAP[def.skill] then
            rxn.skill = types.SKILL_MAP[def.skill]
        end

        -- ---- STEP 8: BUILD REAGENTS ----
        -- Find a base reagent from the template to clone as our
        -- structural starting point. This preserves internal C++
        -- fields we can't set from Lua.
        local base_reagent = nil
        for _, rgt in ipairs(template.reagents) do
            if df.reaction_reagent_itemst:is_instance(rgt) then
                base_reagent = rgt
                break
            end
        end

        if base_reagent and def.reagents then
            rxn.reagents:resize(0)
            for _, rgt_def in ipairs(def.reagents) do
                local r = build_reagent(rgt_def, base_reagent, mat_lookup, def.reagents)
                rxn.reagents:insert('#', r)
            end
        end

        -- ---- STEP 9: BUILD PRODUCTS ----
        -- Two product classes are possible. Item products clone a donor
        -- from this reaction's own template; improvement products clone
        -- one from anywhere in the loaded raws, since a structurally
        -- similar template is not guaranteed to carry one.
        local base_product = nil
        for _, prod in ipairs(template.products) do
            if df.reaction_product_itemst:is_instance(prod) then
                base_product = prod
                break
            end
        end

        if def.products then
            local wants_item = false
            local wants_improvement = false
            for _, prod_def in ipairs(def.products) do
                local pt = types.PRODUCT_TYPES[prod_def.type]
                if pt and pt.improvement then
                    wants_improvement = true
                else
                    wants_item = true
                end
            end

            -- Resolve donors up front so a failure skips the reaction
            -- cleanly instead of leaving it with a partial product list.
            local improvement_donor = nil
            if wants_improvement then
                improvement_donor = find_improvement_donor()
                if not improvement_donor then
                    -- ERROR: this reaction is not built, which the player
                    -- will meet in play. The two messages here used to be
                    -- swapped: this branch is the IMPROVEMENT donor.
                    log('ERROR', string.format("cannot find improvement product"
                        .. " clone required for [%s]. reaction skipped.",
                        tostring(def.key)), 'CLONE')
                    goto continue
                end
            end
            if wants_item and not base_product then
                -- ERROR: this reaction is not built, which the player will
                -- meet in play. This branch is the ITEM product.
                log('ERROR', string.format("cannot find item product clone"
                    .. " required for [%s]. reaction skipped.",
                    tostring(def.key)), 'CLONE')
                goto continue
            end

            rxn.products:resize(0)
            for _, prod_def in ipairs(def.products) do
                local pt = types.PRODUCT_TYPES[prod_def.type]
                local p
                if pt and pt.improvement then
                    p = build_improvement_product(prod_def, improvement_donor)
                else
                    p = build_product(prod_def, base_product, mat_lookup)
                end
                if p then
                    rxn.products:insert('#', p)
                end
            end
        end

        -- ---- STEP 10: INJECT ----
        reactions_array:insert('#', rxn)
        rxn.index = #reactions_array - 1
        
        -- Fallbacks can use newly injected reactions instantly
        fast_reactions_cache.by_code[rxn.code] = rxn
        
        count = count + 1

        ::continue::
    end

    log('DETAIL', string.format(
        "[%s] built %d reactions.", mod_name, count
    ), tostring(mod_name))

    return count
end


-- ==========================================
-- PUBLIC: INJECT CATEGORIES
-- ==========================================
-- Injects a module's category tree into the live
-- reaction_categories array. Categories provide the menu
-- structure players see at workshops.
--
-- Parameters:
--   categories - Array of category definitions from the JSON
--   prefix     - Module's ID prefix string
--
-- Returns: count of categories injected
-- ==========================================
function inject_categories(categories, prefix)
    if not categories or #categories == 0 then return 0 end

    local cat_array = df.global.world.raws.reactions.reaction_categories
    local count = 0

    -- Snapshot existing category IDs to avoid duplicates
    local existing = {}
    for _, c in ipairs(cat_array) do
        existing[c.id] = true
    end

    -- Build the full ID for each category and organize into a tree
    -- for depth-first injection (parents before children)
    local cat_map = {}
    local roots = {}

    for _, cat_def in ipairs(categories) do
        local full_id = prefix .. "CAT_" .. cat_def.key

        -- The parent must be prefixed too. cat_map is keyed by full_id,
        -- so an unprefixed parent could never match one of our own
        -- categories, and every entry fell through to the root list
        -- with a dangling parent string. An empty parent stays empty,
        -- and a parent naming a category this module does not declare
        -- is left alone so it can point at a pre-existing one.
        local parent_id = ""
        if cat_def.parent and cat_def.parent ~= "" then
            local prefixed = prefix .. "CAT_" .. cat_def.parent
            local declared = false
            for _, other in ipairs(categories) do
                if other.key == cat_def.parent then declared = true break end
            end
            parent_id = declared and prefixed or cat_def.parent
        end

        -- key is the menu hotkey, an interface_key value, 0 for none.
        -- Note it is NOT the schema's key field, which is the string
        -- identifier that becomes id above. Resolved by name so no
        -- interface_key number is hardcoded.
        local hotkey = 0
        if cat_def.hotkey then
            local k = df.interface_key[cat_def.hotkey]
            if type(k) == "number" then
                hotkey = k
            else
                log('WARNING', string.format("[%s] has unknown hotkey '%s'. ignored.",
                tostring(cat_def.key), tostring(cat_def.hotkey)), 'HOTKEY')
            end
        end

        local entry = {
            id          = full_id,
            name        = cat_def.name,
            parent      = parent_id,
            description = cat_def.description or "",
            hotkey      = hotkey,
            children    = {},
        }
        cat_map[full_id] = entry
    end

    -- Organize into tree: find each entry's parent
    for _, entry in pairs(cat_map) do
        if entry.parent == "" or not cat_map[entry.parent] then
            -- Top-level category (or parent is external)
            table.insert(roots, entry)
        else
            table.insert(cat_map[entry.parent].children, entry)
        end
    end

    -- Sort siblings alphabetically for deterministic order
    local function sort_children(node)
        table.sort(node.children, function(a, b) return a.id < b.id end)
        for _, child in ipairs(node.children) do sort_children(child) end
    end
    table.sort(roots, function(a, b) return a.id < b.id end)
    for _, root in ipairs(roots) do sort_children(root) end

    -- Depth-first injection: parents before children
    local function inject_node(node)
        if not existing[node.id] then
            local c = df.reaction_category:new()
            c.id          = node.id
            c.name        = node.name
            c.parent      = node.parent
            c.description = node.description
            c.key         = node.hotkey
            cat_array:insert('#', c)
            existing[node.id] = true
            count = count + 1
        end
        for _, child in ipairs(node.children) do
            inject_node(child)
        end
    end
    for _, root in ipairs(roots) do inject_node(root) end

    log('DETAIL', string.format(
        "Injected %d categories.", count
    ), 'CATEGORIES')

    return count
end




return _ENV