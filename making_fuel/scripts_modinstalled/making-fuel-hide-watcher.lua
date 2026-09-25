--@ module = true
-- making-fuel-hide-watcher.lua
-- ==========================================
-- MAKING FUEL: BUTCHER HIDE WATCHER
-- ==========================================
-- Vanilla butchery pays ONE skin per animal, flat, whatever its size.
-- A groundhog and a sperm whale hand over the same hide. This watches
-- for that skin, removes it, and pays a currency GLOB whose DIMENSION
-- scales with the animal instead.
--
-- Nothing here tans anything. The glob is an intermediate. A separate
-- reaction converts it into real CREATURE:X:SKIN corpsepieces, which
-- read "rawhide" and go to the tanner exactly as vanilla hides always
-- have.
--
-- ==========================================
-- WHY A GLOB AND NOT A BIGGER SKIN
-- ==========================================
-- MEASURED, in this order:
--
--   material_amount.Leather IS live on a skin. Setting it to 4 renders
--   "water buffalo cow skin [4]", the same way a bone with Bone(3)=16
--   renders "llama bone [16]".
--
--   TanAHide IGNORES it. It ate the whole [4] item and returned one
--   leather. So the count renders but does not pay.
--
--   Butchery writes a resource flag AND a count for bone, horn, hoof
--   and wool. For skin it writes NEITHER. That is the actual defect.
--
-- So the quantity cannot ride on one hide. Of every item class DF has,
-- item_globst is the only one carrying a rot_timer AND a dimension AND
-- no race field, which is what makes it the only viable currency:
--
--   item_globst          rot_timer  dimension
--   item_meatst          rot_timer
--   item_remainsst       race caste rot_timer   <- race, cannot create
--   item_toolst          (neither)
--
-- dimension is a native quantity DF tracks and consumes proportionally.
-- It is what material_amount failed to be.
--
-- ==========================================
-- WHY THE CURRENCY IS SAFE FROM VANILLA
-- ==========================================
-- Both gates are vanilla's own reagent lines, not anything we built:
--
--   tan a hide   [USE_BODY_COMPONENT]   a glob is not a body component
--   render fat   [REACTION_CLASS:FAT]   our material declares none
--
-- and skin carries no EDIBLE token, so no cook takes it either. The
-- only thing that can consume the currency is our own reaction, which
-- is the processing step the whole design wanted.
--
-- ==========================================
-- THE CURVE
-- ==========================================
--     dimension = (adult_size / HIDE_ANCHOR) ^ (2/3) * PER_SKIN
--
-- The exponent is NOT a tuning dial. Hide is a SURFACE and mass is a
-- VOLUME, and surface scales as mass to the two thirds. Bone and meat
-- would take a different exponent because they are volumes.
--
-- HIDE_ANCHOR is the dial: the adult_size that yields exactly one
-- skin's worth. At 30000 that is roughly a sheep.
--
--   creature            adult_size   skins   dimension
--   RAT                        100    0.02           3
--   GROUNDHOG                  300    0.05           7
--   WOLF                      4000    0.26          39
--   GIANT_COPPERHEAD         20350    0.77         116
--   HORSE                    50000    1.41         211
--   WATER_BUFFALO           100000    2.23         335
--   DRAGON                 2500000   19.08        2862
--   GIANT_SPERM_WHALE     20000000   76.31       11445
--
-- adult_size lives on the CASTE. It is not the item's volume:
-- getVolume returns 350 for every corpse whatever the animal was.
--
-- ==========================================
-- KNOWN UNKNOWN
-- ==========================================
-- Whether two globs of the same material MERGE when stockpiled. If
-- they do, small animals accumulate into usable hides on their own and
-- nothing further is needed. If they do not, a rat's 3 is permanently
-- below the reaction's minimum and simply rots, which may be the right
-- outcome or may need a combining step.
--
-- This file is correct either way. It is flagged because the answer
-- changes whether anything ELSE has to be built, not whether this
-- works.
-- ==========================================

local repeatUtil = require('repeat-util')

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
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'HIDE_WATCHER'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)
local MOD_PREFIX = 'MAKING_FUEL_'
local MOD_NAME   = 'Making Fuel'
local REPEAT_KEY = 'making_fuel_hide_watch'

-- ---- POLL CADENCE ----
-- The fast path costs the number of items created since the last
-- look, which is nearly always zero, so one frame is affordable.
-- SLOW_EVERY counts fast polls between full sweeps: 120 of them at one
-- frame each preserves the old 120 frame guarantee exactly.
local POLL_FRAMES = 1
local SLOW_EVERY  = 120

-- ==========================================
-- TUNING
-- ==========================================

-- adult_size that yields exactly one skin's worth of currency.
-- Raise it to make leather scarcer, lower it to make leather common.
-- It is the only number here that is a judgement rather than a
-- measurement.
-- MEASURED against the world's own creature list. A sheep is
-- adult_size 5000, so anchoring here makes a sheep exactly one hide
-- and NOTHING a fort farms comes out worse than vanilla:
--
--   SHEEP 5000 = 1    PIG 6000 = 1     LLAMA 18000 = 2
--   HORSE 50000 = 4   COW 60000 = 5    BUFFALO 100000 = 7
--
-- At 30000 every one of those paid zero whole hides, which was the
-- same lockout rejected earlier wearing a partial glob.
--
-- Raising the anchor scales EVERYTHING, including the top: the ratio
-- between a sheep and a whale is set by their sizes, not by this
-- number. Sheep to giant sperm whale is 4000x, and 4000^(2/3) is 252.
-- There is no anchor that pins a sheep at 1 and keeps a whale small.
local HIDE_ANCHOR = 5000

-- Surface over volume. Do not turn this into a dial. If hides feel
-- wrong, move HIDE_ANCHOR. Changing this changes the SHAPE of the
-- curve, which is a physical claim rather than a balance one.
local HIDE_EXPONENT = 2 / 3

-- Dimension units in one skin's worth. 150 matches DF's own glob unit,
-- which is what vanilla's RENDER_FAT asks for:
--   [REAGENT:A:150:GLOB:NONE:NONE:NONE]
local PER_SKIN = 150

-- Backstop against a raws mod with an absurd adult_size. Not a balance
-- figure. A sperm whale wants 11445.
local SANE_MAX = 400000

-- Hides per whole glob. A giant sperm whale pays 251, which at five a
-- glob is 52 items rather than one lump that rots before anyone can
-- work through it. Pure play feel, no physics behind it.
-- 10 hides, 1500 dimension, 1000% on the item. A giant sperm whale
-- goes from 51 globs to 26.
local CAP_HIDES = 10

-- Remainders below this fraction of a hide are discarded rather than
-- minted as a partial. Zero keeps everything.
local FLOOR_FRAC = 0.0

-- false leaves vanilla's skin alone and only ADDS the glob, so the
-- small end stays broken and a rat still hands over a full hide. True
-- is the design. False exists for testing without any item removal.
local CONSUME_VANILLA_SKIN = true

-- ==========================================
-- STATE
-- ==========================================
local armed   = false   -- false means preview: report, change nothing
local running = false
local seen    = {}      -- corpsepiece id -> true, already handled

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
-- SUBJECT is the correlation slot: INJECT for the per species hide
-- materials, SKIN for a single butchered skin, START and STOP. The
-- status, curve and usage output answers commands typed at the console,
-- so it prints.
--
-- A skin's payout is a YIELD: the player butchered the animal and this
-- is what it paid. A skin left unpaid because its material could not
-- be made is an ERROR at the cause, and DETAIL at the consequence.
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
-- HANDS OFF THIS ONE
-- ==========================================
-- PROCESS_SKIN spawns a real rawhide corpsepiece, and a rawhide is
-- exactly what this watcher hunts. MEASURED: at 16:20:49 the reaction
-- made #3390 "cow rawhide" and at 16:20:50 this watcher ate it and
-- paid a fresh 500% glob plus a 24% partial, so a finished hide turned
-- straight back into currency and the loop never closed.
--
-- making-fuel-hide-chain calls this the instant it creates one,
-- in the same synchronous call, so no poll can slip in between.
function ignore(item_id)
    seen[item_id] = true
end

local function hide_mats()
    return reqscript('making-fuel-hide-mats')
end

-- ==========================================
-- CURVE
-- ==========================================
-- Returns: list of WHOLE glob dimensions, PARTIAL dimension, raw skins.
--
-- The split is what stops a whale being one unusable lump. 251 hides
-- becomes fifty globs of five and one of one, plus the remainder as a
-- single partial. Each glob is workable on its own, so a carcass is
-- processed as fast as the fort can manage and whatever spoils is only
-- what was not reached in time.
--
-- Whole globs are always exact multiples of PER_SKIN, so NO fraction
-- can ever hide inside one. Every fraction in the system lives in
-- exactly one place: the partial glob. That is what makes the combine
-- reaction the only thing that ever has to add dimensions together.
local function payout_for(adult_size)
    if not adult_size or adult_size <= 0 then return {}, 0, 0 end

    local skins = (adult_size / HIDE_ANCHOR) ^ HIDE_EXPONENT
    local whole = math.floor(skins)
    local frac  = skins - whole
    if frac < FLOOR_FRAC then frac = 0 end

    if whole * PER_SKIN > SANE_MAX then
        whole = math.floor(SANE_MAX / PER_SKIN)
    end

    local globs = {}
    local left = whole
    while left > 0 do
        local n = math.min(left, CAP_HIDES)
        globs[#globs + 1] = n * PER_SKIN
        left = left - n
    end

    -- Rounded, not floored: a 99% remainder is not 98%. Anything that
    -- rounds to zero dimension cannot exist as an item, so it is lost,
    -- which is the honest outcome for a fraction too small to hold.
    local partial = math.floor(frac * PER_SKIN + 0.5)
    if partial < 1 then partial = 0 end

    return globs, partial, skins
end

-- ==========================================
-- READING THE ANIMAL OFF THE HIDE
-- ==========================================
-- A corpsepiece carries its own race and caste. Confirmed on every
-- piece of a 50 item dump: "race 186 caste 0" on llama parts, "race
-- 182 caste 0" on water buffalo parts.
--
-- That is why this polls for skins instead of hooking the butcher job.
-- The hide knows what it came off, so there is no job timing to get
-- right and no consumed reagent to dig a unit out of.
-- ==========================================
local function animal_of(it)
    local race, caste = nil, nil
    pcall(function() race, caste = it.race, it.caste end)
    if not race or race < 0 then return nil end

    local cr = nil
    pcall(function() cr = df.global.world.raws.creatures.all[race] end)
    if not cr then return nil end

    if not caste or caste < 0 or caste >= #cr.caste then caste = 0 end

    local size = nil
    pcall(function() size = cr.caste[caste].misc.adult_size end)
    if not size then return nil end

    return { race = race, caste = caste,
             name = tostring(cr.creature_id), size = size }
end

-- Is this a raw hide we should act on?
--
-- Matched on the MATERIAL TOKEN, never on a flag. The central finding
-- of this work is that DF sets no resource flag on skin at all, so
-- there is no flag to match. The token stays ':SKIN' even after the
-- display rename to "rawhide", because id and state_name are different
-- fields.
local function is_raw_skin(it)
    local ok = false
    pcall(function()
        if it:getType() ~= df.item_type.CORPSEPIECE then return end
        if it.flags.rotten then return end
        if it.flags.in_job then return end
        local m = dfhack.matinfo.decode(it)
        if not m then return end
        if not tostring(m:getToken()):find(':SKIN$') then return end
        ok = true
    end)
    return ok
end

-- ==========================================
-- JIT MATERIAL
-- ==========================================
-- The first time a species is butchered its currency material may not
-- exist yet. ensure() adds it to the roster so every future load builds
-- it through the engine's normal listener; this injects it for THIS
-- session so the very first kill is not lost.
--
-- Injecting one material now puts it at the end of inorganics.all,
-- while the next load injects the whole roster sorted by key, so it
-- lands somewhere else. That is fine: RM records item materials by
-- TOKEN and rebinds after injection, which is what lets you add a
-- material to the module's JSON without breaking every save.
-- ==========================================
-- Returns: whole material id, partial material id. Nil on failure.
--
-- BOTH tiers, always. An earlier version took only the entry matching
-- `full` and returned only `full`, which injected one material where
-- the payload holds two and left every remainder homeless:
--
--   MODULE INJECT: [Making Fuel] injected 1 materials.
--   HIDE MATS: runtime fields applied to 1 material(s), 1 missed.
--   HIDE WATCH: nil did not resolve. Remainder will be lost.
--
-- The "1 missed" climbing by one per creature was the partial material
-- being looked for and never found.
local function ensure_material(race)
    local hm = hide_mats()
    local full, needs, part = hm.ensure(race, MOD_PREFIX)
    if not full then return nil end
    if not needs then return full, part end

    -- ensure() already put the creature on the roster, so build_payload
    -- includes both its entries. Take both and leave the rest of the
    -- roster alone.
    local mine = {}
    for _, def in ipairs(hm.build_payload()) do
        local id = MOD_PREFIX .. def.key
        if id == full or id == part then mine[#mine + 1] = def end
    end
    if #mine == 0 then
        log('ERROR', 'no payload entry for ' .. full .. ' after ensure. Not injected.', 'INJECT')
        return nil
    end
    if #mine < 2 then
        log('WARNING', 'only ' .. #mine .. ' of 2 tiers found in payload for '
            .. tostring(full) .. '. Remainders will be lost.', 'INJECT')
    end

    local ok, err = pcall(function()
        reqscript('refinish-module-inject').inject(mine, MOD_PREFIX, MOD_NAME)
        hm.apply_runtime_fields(MOD_PREFIX)
    end)
    if not ok then
        log('ERROR', 'JIT inject failed for ' .. full .. ': ' .. tostring(err), 'INJECT')
        return nil
    end

    -- ---- LEDGER SNAPSHOT ----
    -- A material that injected after startup is absent from the
    -- ledger written at startup step 8, so a save taken outside RM's
    -- own protocols would leave every glob of it pointing at an index
    -- nothing can recover. write() rescans the live array, so it
    -- records whatever actually injected rather than what was asked
    -- for, and it refuses to overwrite a good ledger with an empty
    -- one. One site data write per new species, a dozen times in a
    -- fort's life.
    pcall(function()
        dfhack.script_environment('refinish-ledger').write()
    end)

    local live = false
    pcall(function()
        live = dfhack.matinfo.find('INORGANIC:' .. full) ~= nil
    end)
    if not live then
        log('ERROR', 'JIT inject reported success but ' .. full .. ' does not resolve.', 'INJECT')
        return nil
    end

    -- The partial is checked separately and NOT fatal. A missing whole
    -- material means nothing can be paid; a missing partial means only
    -- the remainder is lost, and losing a remainder is better than
    -- refusing the hide and leaving vanilla's flat skin in place.
    local part_live = false
    pcall(function()
        part_live = dfhack.matinfo.find('INORGANIC:' .. tostring(part)) ~= nil
    end)
    log(part_live and 'DETAIL' or 'WARNING', string.format('JIT injected %s%s', full,
        part_live and (' and ' .. part) or ' (partial tier MISSING)'), 'INJECT')

    return full, (part_live and part or nil)
end

-- ==========================================
-- PAYING ONE HIDE
-- ==========================================
local function handle_skin(it)
    seen[it.id] = true

    local animal = animal_of(it)
    if not animal then
        log('WARNING', string.format('#%d: could not read race/caste. Left alone.', it.id), 'SKIN')
        return
    end

    local globs, partial, skins = payout_for(animal.size)
    log('DETAIL', string.format('%s size %d -> %.3f skins -> %d whole glob(s), partial %d',
        animal.name, animal.size, skins, #globs, partial), 'SKIN')

    if not armed then
        -- INFO: preview mode only runs when typed, and this is what it is
        -- run for.
        log('INFO', string.format('  PREVIEW: would pay %d glob(s) and would %s #%d.',
            #globs + (partial > 0 and 1 or 0),
            CONSUME_VANILLA_SKIN and 'remove' or 'keep', it.id), 'SKIN')
        return
    end

    -- ---- MATERIALS ----
    -- Both tiers resolved before anything is created, so a missing
    -- partial material cannot leave the whole hides paid and the
    -- remainder silently dropped.
    --
    -- TWO return values, not three. hm.ensure returns
    -- (full, needs, part); ensure_material collapses that to
    -- (full, part) because "needs" is its own business. Reading three
    -- here put the partial into the discard slot and left part nil,
    -- which is what produced "nil did not resolve" on every animal
    -- even after both materials injected cleanly.
    local full, part = ensure_material(animal.race)
    if not full then
        -- DETAIL: the cause is logged above; this is what it cost the player.
        log('DETAIL', '  no currency material. Vanilla skin left untouched.', 'SKIN')
        return
    end
    local mi_whole, mi_part = nil, nil
    pcall(function() mi_whole = dfhack.matinfo.find('INORGANIC:' .. full) end)
    pcall(function() mi_part  = dfhack.matinfo.find('INORGANIC:' .. part) end)
    if not mi_whole then
        log('ERROR', '  ' .. full .. ' did not resolve. Vanilla skin left untouched.', 'SKIN')
        return
    end
    if partial > 0 and not mi_part then
        log('WARNING', '  ' .. tostring(part) .. ' did not resolve. Remainder will be lost.', 'SKIN')
    end

    -- ---- WHERE ----
    -- A butchered hide usually sits INSIDE the butcher's shop rather
    -- than on the tile under it, and getPosition returns the tile
    -- either way. Ask what is holding it so the payout lands where
    -- vanilla would have left it.
    local holder = nil
    pcall(function() holder = dfhack.items.getHolderBuilding(it) end)

    local pos = nil
    pcall(function()
        local x, y, z = dfhack.items.getPosition(it)
        if x then pos = xyz2pos(x, y, z) end
    end)

    local unit = nil
    pcall(function()
        local cits = dfhack.units.getCitizens(true)
        if cits and cits[1] then unit = cits[1] end
    end)
    if not unit then
        log('WARNING', '  no citizen to create against. Vanilla skin left untouched.', 'SKIN')
        return
    end

    -- ---- ONE GLOB ----
    -- An inorganic glob: mat_type 0, mat_index the inorganic. Building
    -- first and ground as the fallback, because moveToBuilding returns
    -- false rather than throwing when it cannot.
    local function pay(mi, dim)
        local glob = nil
        local ok, err = pcall(function()
            local made = dfhack.items.createItem(
                unit, df.item_type.GLOB, -1, 0, mi.index)
            glob = made and made[1] or nil
        end)
        if not ok or not glob then
            log('ERROR', '  glob creation failed: ' .. tostring(err), 'SKIN')
            return nil
        end
        pcall(function() glob:setDimension(dim) end)

        local placed = false
        if holder then
            pcall(function()
                placed = dfhack.items.moveToBuilding(glob, holder) and true or false
            end)
        end
        if not placed and pos then
            pcall(function() dfhack.items.moveToGround(glob, pos) end)
        end
        return glob
    end

    -- ---- PAY ----
    local paid = 0
    for _, dim in ipairs(globs) do
        if pay(mi_whole, dim) then paid = paid + 1 end
    end
    if partial > 0 and mi_part then
        if pay(mi_part, partial) then paid = paid + 1 end
    end

    if paid == 0 then
        -- DETAIL: either a failure above says why, or the animal was too
        -- small to pay anything.
        log('DETAIL', '  nothing was paid. Vanilla skin left untouched.', 'SKIN')
        return
    end

    -- ---- TAKE ----
    -- Last, and only once something exists, so a failure above never
    -- leaves the player worse off than vanilla.
    local removed = false
    if CONSUME_VANILLA_SKIN then
        removed = pcall(function() dfhack.items.remove(it) end)
        if not removed then log('WARNING', '  could not remove the vanilla skin', 'SKIN') end
    end

    log('YIELD', string.format('  paid %d glob(s): %d whole at up to %d, partial %d.'
        .. ' Vanilla skin %s.',
        paid, #globs, CAP_HIDES * PER_SKIN, partial,
        removed and 'removed' or 'kept'), 'SKIN')
end

-- ==========================================
-- POLL
-- ==========================================
-- No self-tail risk here: the input is a CORPSEPIECE and the output is
-- a GLOB, so what this pays can never come back around as something to
-- pay for.
--
-- Candidates are collected before any are handled, because creating an
-- item inserts into world.items.all and mutating a vector while
-- iterating it is its own category of crash.
-- ==========================================
-- ==========================================
-- TWO SPEED SCAN
-- ==========================================
-- The old poll walked every item in the fort, so it had to run at 120
-- frames to stay cheap. That is long enough to watch a rawhide sit
-- there and then turn into a skin, which is a seam.
--
-- FAST PATH. New items land at the tail of world.items.all with
-- increasing ids, so walking backward until the id drops to the high
-- water mark visits only what was created since the last look.
--
-- SLOW PATH. The fast path bets on that ordering. The bet is not load
-- bearing: the full sweep still runs on the old cadence and `seen`
-- remains the authority on what has been handled, so a wrong bet costs
-- one slow catch rather than an unpaid hide.
-- ==========================================
local last_item_id  = -1
local slow_countdown = 0

local function scan_tail(todo)
    local items = df.global.world.items.all
    local high = last_item_id
    for i = #items - 1, 0, -1 do
        local it = items[i]
        if it.id <= last_item_id then break end
        if it.id > high then high = it.id end
        if not seen[it.id] and is_raw_skin(it) then
            table.insert(todo, it)
        end
    end
    last_item_id = high
end

local function scan_all(todo)
    for _, it in ipairs(df.global.world.items.all) do
        if it.id > last_item_id then last_item_id = it.id end
        if not seen[it.id] and is_raw_skin(it) then
            table.insert(todo, it)
        end
    end
end

local function poll()
    if not dfhack.isMapLoaded() then return end

    -- Candidates are collected before any are handled, because
    -- creating an item inserts into world.items.all and mutating a
    -- vector while iterating it is its own category of crash.
    local todo = {}

    slow_countdown = slow_countdown - 1
    local full = (slow_countdown <= 0)
    if full then slow_countdown = SLOW_EVERY end

    pcall(function()
        if full then scan_all(todo) else scan_tail(todo) end
    end)

    for _, it in ipairs(todo) do
        pcall(function() handle_skin(it) end)
    end
end

-- ==========================================
-- LIFECYCLE
-- ==========================================
function start(arm)
    armed = arm and true or false
    if not running then
        -- Everything already lying around is marked handled, so arming
        -- this in an established fort does not convert the whole
        -- stockpile at once.
        local n = 0
        pcall(function()
            for _, it in ipairs(df.global.world.items.all) do
                -- The same walk sets the high water mark, so the fast
                -- path starts from what is already here instead of
                -- re-walking the whole vector on its first pass.
                if it.id > last_item_id then last_item_id = it.id end
                if is_raw_skin(it) then seen[it.id] = true n = n + 1 end
            end
        end)
        repeatUtil.scheduleEvery(REPEAT_KEY, POLL_FRAMES, 'frames', poll)
        running = true
        log('DETAIL', string.format('%d existing hide(s) marked as already handled.', n), 'START')
    end
    -- INFO when started in preview, which is only ever typed.
    log(armed and 'DETAIL' or 'INFO', armed and 'ARMED. Butchered animals now pay currency.'
               or 'PREVIEW. Reporting only, nothing will change.', 'START')
end

function stop()
    repeatUtil.cancel(REPEAT_KEY)
    running = false
    armed   = false
    log('DETAIL', 'stopped.', 'STOP')
end

function status()
    print(string.format('running %s, armed %s, anchor %d, per skin %d',
        tostring(running), tostring(armed), HIDE_ANCHOR, PER_SKIN))
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    print(string.format('  %d hide(s) marked handled this session', n))
end

-- Preview the curve against the roster without touching the game.
function curve()
    local hm = hide_mats()
    for _, cid in ipairs(hm.roster_get()) do
        local race = hm.race_of(cid)
        local size = nil
        pcall(function()
            size = df.global.world.raws.creatures.all[race]
                     .caste[0].misc.adult_size
        end)
        if size then
            local globs, partial, skins = payout_for(size)
            print(string.format('  %-24s size %-10d %7.2f skins  %2d glob(s) + %d%%',
                cid, size, skins, #globs,
                math.floor(partial * 100 / PER_SKIN + 0.5)))
        else
            print(string.format('  %-24s (no adult_size readable)', cid))
        end
    end
end

-- ==========================================
-- CLI
-- ==========================================
-- The guard is not optional. `--@ module = true` only makes the file
-- reqscript-able; it does NOT stop the body running, so without this
-- every reqscript falls through to the usage branch.
-- ==========================================
if dfhack_flags and dfhack_flags.module then return end

local cmd = ...
if cmd == 'on' then
    start(true)
elseif cmd == 'preview' then
    start(false)
elseif cmd == 'off' then
    stop()
elseif cmd == 'status' then
    status()
elseif cmd == 'curve' then
    curve()
else
    print('usage: making-fuel-hide-watcher preview | on | off | status | curve')
end