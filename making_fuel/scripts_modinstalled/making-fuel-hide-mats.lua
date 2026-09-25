--@ module = true
-- making-fuel-hide-mats.lua
-- ==========================================
-- MAKING FUEL: HIDE CURRENCY MATERIALS
-- ==========================================
-- Butchery pays one skin per animal, flat, whatever its size. The fix
-- pays a GLOB whose dimension scales with the animal, and this file
-- supplies the materials those globs are made of.
--
-- Two naming jobs, and they are opposites:
--
--   OURS    an injected inorganic per creature, displayed "llama skin"
--   THEIRS  vanilla CREATURE:LLAMA:SKIN, renamed to "llama rawhide"
--
-- So the butcher's output keeps the plain word, and the tannable hide
-- that our process reaction produces takes the correct term for a
-- dehaired untanned hide. Both names end up true, which is not
-- something the earlier drafts of this managed.
--
-- ==========================================
-- WHY AN INORGANIC AND NOT A CREATURE MATERIAL
-- ==========================================
-- MEASURED, not assumed. The creature name is a field on the MATERIAL,
-- not looked up from the creature at display time:
--
--   CREATURE:LLAMA:SKIN   prefix="llama"  state_name.Solid="skin"
--   INORGANIC:IRON        prefix=""       state_name.Solid="iron"
--
-- And writing that field on an injected inorganic works. A boulder of
-- an RM material with prefix set to "llama" rendered:
--
--   "llama frozen ammonia"
--
-- So an inorganic can carry a creature's name. That kills the need for
-- a host creature, and it means creature raws are never written to,
-- which is the part that would have needed cleaning up.
--
-- ==========================================
-- WHY THE VANILLA RENAME IS SAFE
-- ==========================================
-- id and state_name are DIFFERENT FIELDS. Reagents, reactions and
-- matinfo all match on id. state_name is display only. Measured:
--
--   BEFORE  id="SKIN"  state_name.Solid="skin"
--   AFTER   id="SKIN"  state_name.Solid="rawhide"
--   matinfo still resolves: true
--
-- Nothing mechanical keys off the word. Vanilla tanning still binds,
-- because its reagent asks for a body component carrying TAN_MAT, and
-- both of those are untouched.
--
-- It also allocates nothing. A rename writes into a string that already
-- exists, so a missed restore leaks no memory and leaves no dangling
-- reference. That is why it does not need to ride the save cycle the
-- way an injected material does.
--
-- ==========================================
-- THE ROSTER, AND WHY IT IS APPEND ONLY
-- ==========================================
-- We cannot inject a material for all seven hundred creatures at boot,
-- and we do not need to. A fort butchers a dozen species. So the
-- roster grows just in time: the first llama butchered adds LLAMA.
--
-- It is an ARRAY, never a hash, and entries are never removed. Two
-- reasons, both learned the hard way elsewhere in this module:
--
--   pairs() over a table gives non-deterministic order, so a hash
--   roster would inject in a different order every load.
--
--   Removing an entry would shuffle every creature behind it.
--
-- Correctness does not actually depend on positions holding still,
-- because RM records item materials by TOKEN and rebinds them after
-- injection. But deterministic order costs nothing and means the logs
-- from two sessions can be compared.
-- ==========================================

local json = require('json')

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
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'HIDE_MATS'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)
local MODULE_ID  = 'making_fuel'
local ROSTER_KEY = 'MAKING_FUEL_HIDE_ROSTER'

-- Key suffix per creature. Full id becomes <module prefix>HIDE_<CREATURE>.
local KEY_PREFIX = 'HIDE_'

-- ==========================================
-- THE PARTIAL TIER
-- ==========================================
-- A second material per creature, for payouts under one whole hide.
--
-- It exists because a glob reagent's quantity is DIMENSION, not item
-- count, so a reaction cannot ask for "150 across two globs". What it
-- CAN do is take two separate reagent SLOTS, one item each, and let
-- the completion handler add their dimensions together. That is what
-- the combine reaction does, and it works only if partials are
-- distinguishable from whole skins, which is what this material is for.
--
-- Both tiers are the same stuff physically. The only differences are
-- the display prefix and the reaction class the combine reaction
-- selects on.
local PARTIAL_KEY_PREFIX = 'HIDEPART_'

-- What the currency is called. The creature name is prepended from the
-- material's prefix field, so this is only the second half.
-- The PREFIX is where the tier shows: "llama skin" against
-- "partial llama skin". Prefix is free text on the material, which is
-- why the partial tier needs no new mechanism.
local CURRENCY_NAME  = 'skin'
local PARTIAL_PREFIX = 'scrap '

-- What vanilla's skin is renamed to.
local VANILLA_NAME = 'rawhide'

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
-- SUBJECT is the correlation slot: ROSTER, FLAGS, RENAME, RESTORE and
-- ENSURE, the part of the job a line is about. The output of the typed
-- commands at the bottom prints, since it answers what was typed.
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
-- ROSTER
-- ==========================================
-- Stored as a JSON array of creature_id strings in injection order.
-- Tokens rather than race indices on purpose: race indices are world
-- specific, and a roster written in one world would silently address
-- different animals in another.
-- ==========================================

local roster_cache = nil

-- ==========================================
-- WHY A BLANK READ IS NOT CACHED
-- ==========================================
-- This is now read during the engine's token call, which is far
-- earlier in the load than anything that used to call it.
--
-- The old version cached whatever the first read produced. If that
-- read happened before site data was reachable it cached an empty
-- table for the session, and the damage compounds: the payload
-- injects no hides, then the butcher watcher re-adds species to a
-- roster it believes is blank, then roster_save writes that short
-- roster over the real one. One early read, and the fort's history
-- of butchered species is gone.
--
-- So the cache is only taken when a world is actually loaded, which
-- is the condition under which a blank answer means "genuinely
-- empty" rather than "asked too early". Otherwise the blank is
-- returned and forgotten, and the next call asks again.
-- ==========================================
function roster_get()
    if roster_cache then return roster_cache end

    local loaded = nil
    local read_ok = pcall(function()
        local raw = dfhack.persistent.getSiteData(ROSTER_KEY)
        if not raw or raw == '' then return end
        local ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == 'table' then loaded = decoded end
    end)

    local world_up = false
    pcall(function() world_up = dfhack.isWorldLoaded() end)

    if read_ok and world_up then
        roster_cache = loaded or {}
        return roster_cache
    end
    return loaded or {}
end

function roster_save()
    pcall(function()
        dfhack.persistent.saveSiteData(ROSTER_KEY, json.encode(roster_get()))
    end)
end

-- Position in the roster, or nil. Linear scan is fine: a fort roster
-- is a dozen entries, and this runs once per butchered animal.
function roster_index(creature_id)
    for i, v in ipairs(roster_get()) do
        if v == creature_id then return i end
    end
    return nil
end

-- Returns index, added. `added` is false when it was already there.
function roster_add(creature_id)
    local at = roster_index(creature_id)
    if at then return at, false end
    local r = roster_get()
    r[#r + 1] = creature_id
    -- Pin the table we just mutated AS the cache. roster_get can hand
    -- back an uncached table when it was called before site data was
    -- reachable, and roster_save calling roster_get again would then
    -- get a second, empty one and write that instead.
    roster_cache = r
    roster_save()
    log('DETAIL', string.format('roster += %s (now %d entries)', creature_id, #r), 'ROSTER')
    return #r, true
end

-- ==========================================
-- LOOKUPS
-- ==========================================

-- creature_id string -> race index in THIS world, or nil.
function race_of(creature_id)
    local found = nil
    pcall(function()
        for i, cr in ipairs(df.global.world.raws.creatures.all) do
            if tostring(cr.creature_id) == creature_id then found = i return end
        end
    end)
    return found
end

-- The creature's own SKIN material, which is both the donor for
-- physical properties and the thing that gets renamed.
function skin_material_of(race)
    local mat = nil
    pcall(function()
        local cr = df.global.world.raws.creatures.all[race]
        if not cr then return end
        for _, m in ipairs(cr.material) do
            if tostring(m.id) == 'SKIN' then mat = m return end
        end
    end)
    return mat
end

-- The lowercase display name DF uses for a creature, which is what the
-- prefix has to be. Read off the creature's own name vector rather than
-- lowercasing the token, because "WATER_BUFFALO" is not "water buffalo".
function display_name_of(race)
    local n = nil
    pcall(function()
        local cr = df.global.world.raws.creatures.all[race]
        if cr and cr.name and #cr.name > 0 then n = tostring(cr.name[0]) end
    end)
    if not n or n == '' then
        pcall(function()
            n = tostring(df.global.world.raws.creatures.all[race].creature_id)
                :lower():gsub('_', ' ')
        end)
    end
    return n
end

-- ==========================================
-- PAYLOAD
-- ==========================================
-- Returns a materials array in the engine's schema, one entry per
-- rostered creature. The module's listener hands this straight to the
-- engine, which injects, clears and rebuilds it on the save cycle
-- exactly like the module's JSON-declared materials. Nothing here is
-- persisted separately, because the roster plus this function
-- regenerate it identically every load.
--
-- material_class RAW rather than STONE: the currency is not a rock, and
-- the class picks the clone donor and flag preset. ROTS is set
-- explicitly rather than inherited, because it is the one flag the
-- whole design depends on and inheriting it would mean trusting a
-- donor chosen at runtime.
--
-- Physical properties are NOT set here. They are copied per creature
-- from that animal's own skin in apply_runtime_fields, so a whale hide
-- does not end up with llama's density.
-- ==========================================
-- Two entries per creature, whole and partial. They differ ONLY in
-- key, reaction class and the prefix applied later; every physical
-- property is identical, because they are the same hide.
local function entry(key, cid, rclass)
    return {
            key            = key .. cid,
            name           = CURRENCY_NAME,

            -- ==========================================
            -- WHY SOIL AND NOT RAW
            -- ==========================================
            -- RAW looks like the honest answer and does not work.
            -- Its CLONE_SIGNATURES entry is empty by design, and the
            -- STONE fallback that rescues it only runs INSIDE a class
            -- evaluation. Classes are evaluated for the ones a module
            -- actually uses, and making_fuel's 54 materials use
            -- LIQUID, SOIL, STONE, DYE and CERAMIC. RAW is never
            -- warmed, so get_donor returns nil:
            --
            --   MODULE INJECT: No donor for class [RAW],
            --                  skipped [MAKING_FUEL_HIDE_LLAMA].
            --
            -- That matters more here than for a boot-time material,
            -- because this one is injected JUST IN TIME when a species
            -- is first butchered. There is no earlier pass to warm a
            -- class nothing else asks for.
            --
            -- SOIL carries the same require_true as STONE, so the
            -- donor is structurally identical, and the module already
            -- warms it eighteen times over. Everything that makes this
            -- material what it is gets overwritten from the creature's
            -- own skin in apply_runtime_fields regardless.
            -- ==========================================
            material_class = 'SOIL',

            -- All four solid states, because a glob can sit in any of
            -- them and ALL_SOLID in the raws means DF expects them to
            -- agree. Liquid and gas are never reachable for this.
            names = {
                solid   = CURRENCY_NAME,
                powder  = CURRENCY_NAME,
                paste   = CURRENCY_NAME,
                pressed = CURRENCY_NAME,
            },

            -- ==========================================
            -- FOUR FLAGS, AND THREE OF THEM WERE LEARNED
            -- THE HARD WAY
            -- ==========================================
            -- DO_NOT_CLEAN_GLOB is the one the currency cannot exist
            -- without, and it is not about rot at all.
            --
            -- MEASURED. Four globs spawned together, then unpause:
            --
            --   llama SKIN     ROTS, no clean flag        GONE
            --   llama FAT      ROTS, HAS clean flag       survived
            --   ours + ROTS    no clean flag              GONE
            --   ours, no ROTS  no clean flag              GONE
            --
            -- The one without ROTS died too, so rot was never what was
            -- removing them. DF was CLEANING them, the way it cleans
            -- blood and vomit off a floor, which is also why they drew
            -- with a liquid sprite instead of a glob one: DF was not
            -- treating them as items.
            --
            -- Isolated afterwards on three separate materials:
            -- DO_NOT_CLEAN_GLOB alone survived, STOCKPILE_GLOB alone
            -- did not. The flag does exactly what its name says.
            --
            -- STOCKPILE_GLOB does not keep the item alive, but it is
            -- what makes it a glob stockpile item, so dwarves haul and
            -- store it rather than leaving it where it was made. Fat
            -- carries it for the same reason.
            --
            -- GENERATES_MIASMA because anything that rots should
            -- stink. It is also the pressure the design depends on: a
            -- rotting hide that produces no smell is one the player
            -- can ignore, and ignoring it is the behaviour we are
            -- pricing.
            --
            -- ROTS is the spoilage itself. SKIN_TEMPLATE carries it,
            -- item_globst carries a rot_timer, and together they are
            -- what makes an unprocessed hide spoil.
            --
            -- NOT taken from fat, deliberately: REACTION_CLASS:FAT.
            -- That is what RENDER_FAT selects on, and copying fat's
            -- whole flag word to make the item work would have quietly
            -- handed our hides to the kitchen.
            -- ==========================================
            material_flags = {
                ROTS              = true,
                DO_NOT_CLEAN_GLOB = true,
                STOCKPILE_GLOB    = true,
                GENERATES_MIASMA  = true,

                -- IS_STONE off. Nobody chose it for a hide; it arrives
                -- with the clone class preset, because these materials
                -- clone through STONE and refinish-module-inject.lua
                -- blanks every flag and then rebuilds identity from the
                -- preset. A hide is not stone and should not answer any
                -- test that asks. Flag overrides are applied last by
                -- the engine precisely so a preset can be corrected.
                IS_STONE            = false,

                -- IMPLIES_ANIMAL_KILL on. Fat carries it and a hide has
                -- exactly the same provenance: it came off a dead
                -- animal. Dwarves with the relevant values object to
                -- owning it, which is correct and is a thing the
                -- currency should cost.
                IMPLIES_ANIMAL_KILL = true,
            },

            -- Deliberately empty. No TAN_MAT, so nothing can tan the
            -- currency directly. No REACTION_CLASS, so render fat
            -- cannot see it either. Both gates are vanilla's own:
            --   tan a hide   [USE_BODY_COMPONENT]   glob is not one
            --   render fat   [REACTION_CLASS:FAT]   we declare none
            reaction_products = {},
            reaction_classes  = { rclass },
    }
end

function build_payload()
    local mats = {}
    for _, cid in ipairs(roster_get()) do
        -- Reaction classes are UNPREFIXED here, like every other class
        -- in the module (PITCH, COKE, CHAR, ROTTEN, DRAIN_KEY). DF
        -- prints this string straight at the workshop as "Needs HIDE
        -- item", so a MAKING_FUEL_ prefix is a wart the player reads.
        -- The MATERIAL keys keep their prefix; only the class drops it.
        mats[#mats + 1] = entry(KEY_PREFIX,         cid, 'SKIN')
        mats[#mats + 1] = entry(PARTIAL_KEY_PREFIX, cid, 'PARTIAL_SKIN')
    end
    return mats
end

-- ==========================================
-- RUNTIME FIELDS
-- ==========================================
-- Two things the schema cannot express, applied after the engine has
-- injected. Idempotent, so running it twice is harmless.
--
--   prefix          the creature's display name. Not a schema field:
--                   the only "prefix" the schema knows is the module
--                   ID prefix, which is a different thing entirely.
--
--   physical props  copied from that creature's own skin, because
--                   density and colour are properties of the animal
--                   and picking one donor for all of them would be
--                   inventing numbers.
-- ==========================================
function apply_runtime_fields(module_prefix)
    local done, missed = 0, 0
    for _, cid in ipairs(roster_get()) do
      for _, tier in ipairs({ { KEY_PREFIX, '' },
                              { PARTIAL_KEY_PREFIX, PARTIAL_PREFIX } }) do
        local full = module_prefix .. tier[1] .. cid
        local ok = pcall(function()
            local mi = dfhack.matinfo.find('INORGANIC:' .. full)
            if not mi then missed = missed + 1 return end
            local mat = mi.material

            -- tier[2] is '' for whole and 'partial ' for the sub-hide
            -- tier, so the item reads "llama skin" or
            -- "partial llama skin" with no other change anywhere.
            mat.prefix = tier[2] .. (display_name_of(race_of(cid)) or '')

            -- ---- DECLARE THIS A GLOB MATERIAL ----
            -- The one structural field a material diff against vanilla
            -- fat left standing:
            --
            --   butcher_special_type   ours=-1   fat=75
            --
            -- 75 is df.item_type.GLOB. Fat's material states that
            -- butchery turns it into a glob item; ours states nothing.
            -- It is the only remaining field that says GLOB MATERIAL
            -- rather than material that happens to be inside a glob,
            -- and it is the standing candidate for why our globs haul
            -- but never get barrelled while fat in the same pile does.
            --
            -- Harmless if it is not the gate: nothing butchers our
            -- inorganic, so the field is read by whatever else consults
            -- it and by nothing that could produce an item.
            local glob_t = 75
            pcall(function() glob_t = df.item_type.GLOB end)
            mat.butcher_special_type = glob_t

            -- Copy what makes this animal's hide that animal's hide.
            local race = race_of(cid)
            local donor = race and skin_material_of(race) or nil
            if donor then
                -- ==========================================
                -- HEAT IS NOT COSMETIC. IT DECIDES EXISTENCE.
                -- ==========================================
                -- MEASURED. A test glob was built on an RM inorganic
                -- that melts at 9896 and boils at 10180. Fortress room
                -- temperature is 10040, which sits between them, so the
                -- material is a LIQUID at rest. The glob melted and was
                -- gone the moment the game unpaused.
                --
                --   donor 330    melt 9896    boil 10180
                --   room temp    10040
                --   llama skin   melt 60001   boil 60001
                --
                -- Skin never melts or boils, which is why the hide has
                -- to inherit the whole heat block rather than only
                -- density and colour. Leaving heat to the RAW clone
                -- donor means the currency's survival depends on
                -- whichever material the class preset happened to pick
                -- at runtime, and that is not a thing to leave to luck.
                --
                -- assign() rather than field by field because heat
                -- carries seven values and a missed one is a material
                -- that behaves correctly until the day it does not.
                -- ==========================================
                local heat_ok = pcall(function() mat.heat:assign(donor.heat) end)
                if not heat_ok then
                    for _, k in ipairs({'spec_heat', 'heatdam_point',
                                        'colddam_point', 'ignite_point',
                                        'melting_point', 'boiling_point',
                                        'mat_fixed_temp'}) do
                        pcall(function() mat.heat[k] = donor.heat[k] end)
                    end
                end

                -- ROTS comes from the payload, but the rest of skin's
                -- flag word is worth having too, and assign cannot make
                -- the currency tannable: TAN_MAT is a reaction PRODUCT,
                -- not a flag, and the payload leaves those empty.
                -- ==========================================
                -- ASSIGN, THEN PUT BACK WHAT THE PAYLOAD CHOSE
                -- ==========================================
                -- assign() copies skin's WHOLE flag word, which is
                -- worth having for the tissue properties but destroys
                -- the four flags build_payload picked on purpose. Skin
                -- is a tissue and carries none of them, so restoring
                -- only ROTS left the material with no glob identity at
                -- all: no STOCKPILE_GLOB so DF has no glob art to pick
                -- and no stockpile to file it under, no
                -- DO_NOT_CLEAN_GLOB so dwarves mop hides up as spills,
                -- and no GENERATES_MIASMA so the rot pressure the
                -- design leans on never arrives.
                --
                -- The list is written out rather than re-read from the
                -- payload because these four ARE the currency's
                -- identity, and a silent drift between the two places
                -- would show up as art and hauling bugs with nothing
                -- in the log. If build_payload's set changes, this
                -- changes with it.
                --
                -- Still NOT copying fat's word, for the reason
                -- build_payload gives: fat carries REACTION_CLASS:FAT
                -- and the kitchen flags, and that hands our hides to
                -- the cooks.
                -- ==========================================
                pcall(function() mat.flags:assign(donor.flags) end)
                for _, fl in ipairs({ 'ROTS', 'DO_NOT_CLEAN_GLOB',
                                      'STOCKPILE_GLOB',
                                      'GENERATES_MIASMA' }) do
                    local fok = pcall(function() mat.flags[fl] = true end)
                    if not fok then
                        log('WARNING', string.format('%s: could not set flag %s.',
                            full, fl), 'FLAGS')
                    end
                end

                pcall(function() mat.solid_density = donor.solid_density end)

                -- ==========================================
                -- NO ABSORBENCY
                -- ==========================================
                -- A material with absorption above zero soaks up
                -- whatever it is lying in, which is why globs come out
                -- of a wet workshop reading "cow skin laced with
                -- water" and carry the contaminant through every later
                -- job. Vanilla sets [ABSORPTION:0] on everything meant
                -- to stay dry and 100 on cloth and thread.
                --
                -- Written EXPLICITLY rather than inherited. Nothing
                -- above sets it: heat, density, colour and flags all
                -- come from the animal's skin, and absorption comes
                -- from whichever donor the RAW class preset happened
                -- to clone at runtime. That is the one property where
                -- both sources are wrong and a hard zero is right.
                --
                -- Reported by name on failure, because a silently
                -- skipped field here is a bug that only shows up as
                -- damp hides three sessions later.
                -- MEASURED and RETIRED: mat.absorption does not exist
                -- on this build. The write threw for every material on
                -- every inject and logged twice per animal. Vanilla's
                -- [ABSORPTION:n] token lands somewhere else, or is
                -- resolved at parse time and has no runtime field at
                -- all. Not chased further because the lacing is not
                -- the problem worth solving; the sprite is.
                pcall(function()
                    for _, st in ipairs({'Solid','Powder','Paste','Pressed'}) do
                        mat.state_color[st] = donor.state_color[st]
                    end
                end)
                pcall(function()
                    for i = 0, 2 do mat.tile_color[i] = donor.tile_color[i] end
                end)
            end
            done = done + 1
        end)
        if not ok then missed = missed + 1 end
      end
    end
    -- ERROR when any material missed: it goes without its name, heat or
    -- colour, which the player sees.
    log(missed > 0 and 'ERROR' or 'DETAIL', string.format('runtime fields applied to %d material(s), %d missed.',
        done, missed), 'FLAGS')
    return done, missed
end

-- ==========================================
-- VANILLA RENAME
-- ==========================================
-- skin -> rawhide on every creature that has a SKIN material.
--
-- Originals are kept so restore is exact rather than assuming every
-- creature said "skin". Some modded creatures will not.
--
-- Solid, Powder, Paste and Pressed only. [STATE_NAME:ALL_SOLID:skin]
-- in the raws fills exactly those four. Liquid and gas read "n/a" and
-- are left alone.
-- ==========================================

-- ==========================================
-- WHY THIS LIVES IN _G AND NOT A FILE LOCAL
-- ==========================================
-- DFHack RE-EXECUTES THE FILE BODY on every invocation. The globals
-- above survive because they are reassigned into the same script
-- environment, but a file local is rebuilt from scratch, so
-- `local original_names = nil` wiped the saved names between a
-- rename and the restore that followed it 19 seconds later.
--
-- That is not a testing artefact. Boot calling rename_vanilla and
-- shutdown calling restore_vanilla are separate executions too, so a
-- file local would have lost them in production the same way.
--
-- _G survives for the whole DF session, which is exactly the lifetime
-- this needs: names come back from the raws on every world load, so
-- nothing has to survive longer than that.
-- ==========================================
local NAMES_KEY = 'making_fuel_hide_original_names'

-- Answered by READING A MATERIAL, never by remembering that we did it.
--
-- The remembered version was wrong in a way worth keeping written
-- down: _G outlives a world load and material names do not. Names come
-- back from the raws every load, so after a reload the skins read
-- "skin" while the flag still said "renamed", and the rename refused.
--
-- The stale table is also keyed by RACE INDEX, which is world specific,
-- so restoring it against a different world would write one creature's
-- name onto another. Observing the live material cannot drift from the
-- world the way a remembered flag can.
local function already_renamed()
    local seen = false
    pcall(function()
        for race in ipairs(df.global.world.raws.creatures.all) do
            local mat = skin_material_of(race)
            if mat then
                seen = (tostring(mat.state_name.Solid) == VANILLA_NAME)
                return          -- first creature with a skin decides it
            end
        end
    end)
    return seen
end

function rename_vanilla()
    if already_renamed() then
        log('DETAIL', 'vanilla skins already read "' .. VANILLA_NAME
            .. '". Nothing to do.', 'RENAME')
        return 0
    end
    -- Dropped rather than merged. Anything left here is from a previous
    -- world, and its race keys do not mean the same animals now.
    _G[NAMES_KEY] = {}
    local original_names = _G[NAMES_KEY]
    local n = 0
    pcall(function()
        for race in ipairs(df.global.world.raws.creatures.all) do
            local mat = skin_material_of(race)
            if mat then
                -- A name already reading VANILLA_NAME is one of OURS
                -- from an earlier rename whose state was lost. Saving
                -- it as the original would make "rawhide" permanent,
                -- with no record of the real word anywhere. Skip the
                -- save and leave it alone; a stale rename costs a
                -- session, a poisoned original costs the world.
                local saved = {}
                for _, st in ipairs({'Solid','Powder','Paste','Pressed'}) do
                    local cur = tostring(mat.state_name[st])
                    if cur ~= VANILLA_NAME then
                        saved[st] = cur
                        mat.state_name[st] = VANILLA_NAME
                        mat.state_adj[st]  = VANILLA_NAME
                    end
                end
                original_names[race] = saved
                n = n + 1
            end
        end
    end)
    log('DETAIL', string.format('renamed %d vanilla skin material(s) to "%s".',
        n, VANILLA_NAME), 'RENAME')
    return n
end

function restore_vanilla()
    local original_names = _G[NAMES_KEY]
    if not original_names then
        -- Self-healing, so this is a notice and not a failure. Material
        -- names are re-read from the raws on every world load, so an
        -- unrestored rename lasts until the next load and no longer.
        log('DETAIL', 'no rename recorded this session. Nothing to restore.', 'RESTORE')
        return 0
    end
    local n = 0
    pcall(function()
        for race, saved in pairs(original_names) do
            local mat = skin_material_of(race)
            if mat then
                for st, v in pairs(saved) do
                    mat.state_name[st] = v
                    mat.state_adj[st]  = v
                end
                n = n + 1
            end
        end
    end)
    _G[NAMES_KEY] = nil
    log('DETAIL', string.format('restored %d vanilla skin material(s).', n), 'RESTORE')
    return n
end

-- ==========================================
-- JIT
-- ==========================================
-- Called by the butcher watcher the first time a species is butchered.
-- Adds to the roster so the material exists on every future load, and
-- reports whether the caller needs to trigger an injection for it to
-- exist THIS session.
--
-- Returns: full_material_id, needs_injection
-- ==========================================
function ensure(race, module_prefix)
    local cid = nil
    pcall(function()
        cid = tostring(df.global.world.raws.creatures.all[race].creature_id)
    end)
    if not cid then
        log('ERROR', 'ensure: could not read creature_id for race ' .. tostring(race), 'ENSURE')
        return nil, false
    end

    local _, added = roster_add(cid)
    local full = module_prefix .. KEY_PREFIX         .. cid
    local part = module_prefix .. PARTIAL_KEY_PREFIX .. cid

    -- Already live in RAM means nothing further is needed, whether or
    -- not this call is what added it.
    -- BOTH tiers must be live, not just the whole one. A butchered
    -- animal almost always leaves a remainder, so a session where the
    -- whole material injected and the partial did not would drop every
    -- fraction on the floor.
    local live = false
    pcall(function()
        live = dfhack.matinfo.find('INORGANIC:' .. full) ~= nil
           and dfhack.matinfo.find('INORGANIC:' .. part) ~= nil
    end)

    return full, (not live), part
end

-- ==========================================
-- CLI
-- ==========================================
-- Testing only. The module drives this file through the functions
-- above; nothing here runs on load.
--
-- THE GUARD IS NOT OPTIONAL. `--@ module = true` only makes the file
-- reqscript-able; it does NOT stop the body running. Without this
-- line, every reqscript of this file falls through to the usage
-- branch below. modtools/create-item carries the same guard for the
-- same reason, and its absence is what would make a module load
-- print noise on every cycle.
-- ==========================================
if dfhack_flags and dfhack_flags.module then return end

local cmd, a1 = ...
if cmd == 'roster' then
    local r = roster_get()
    print(string.format('%d entry(s):', #r))
    for i, v in ipairs(r) do
        local race = race_of(v)
        print(string.format('  %2d  %-24s race %s  name "%s"',
            i, v, tostring(race),
            race and tostring(display_name_of(race)) or '?'))
    end
elseif cmd == 'add' and a1 then
    local cid = a1:upper()
    if not race_of(cid) then
        print('no creature called ' .. cid .. ' in this world.')
    else
        roster_add(cid)
    end
elseif cmd == 'rename' then
    rename_vanilla()
elseif cmd == 'restore' then
    restore_vanilla()
elseif cmd == 'payload' then
    local p = build_payload()
    print(string.format('%d material(s) would be injected:', #p))
    for _, m in ipairs(p) do
        print(string.format('  %-32s name "%s"  ROTS %s',
            m.key, m.name, tostring(m.material_flags.ROTS)))
    end
elseif cmd then
    print('unknown command: ' .. tostring(cmd))
else
    print('usage: making-fuel-hide-mats roster | add CREATURE | payload'
        .. ' | rename | restore')
end