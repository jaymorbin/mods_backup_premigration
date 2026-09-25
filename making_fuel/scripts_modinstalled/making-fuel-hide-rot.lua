--@ module = true
-- making-fuel-hide-rot.lua
-- ==========================================
-- MAKING FUEL: HIDE SPOILAGE
-- ==========================================
-- DF does not rot globs. Our hides have to rot themselves.
--
-- ==========================================
-- WHY THIS FILE EXISTS, MEASURED
-- ==========================================
-- The materials carry ROTS and GENERATES_MIASMA, item_globst carries a
-- rot_timer, and the timer does climb. It just never arrives. On a
-- vanilla llama fat glob, loose on the ground, in a fort where corpses
-- and food rot normally:
--
--   ROT RESET  199 -> 0   (peak seen 199)
--       age          8138 -> 8140
--       rot_timer    199 -> 0
--
-- Nothing else on the item moved. The counter recycles at 200 and
-- flags.rotten is never set. Ours does exactly the same, so this is
-- DF's behaviour for the item class and not anything about an injected
-- inorganic. rot_timer on a GLOB is a counter that wraps, not a clock
-- that expires.
--
-- The clock that does work is `age`: ticks since the item was created,
-- monotonic, never reset, and already trusted by
-- making-fuel-air-dry.lua for exactly this reason. This file spoils on
-- age and sets flags.rotten itself, which is what every other system
-- in the game reads.
--
-- ==========================================
-- WHAT SETTING rotten BUYS
-- ==========================================
-- The item renames itself rotten, GENERATES_MIASMA on the material
-- starts doing its job, and making-fuel-rot-watcher picks it up for
-- "burn rotten refuse" without needing to know hides exist. All three
-- are vanilla mechanisms reacting to a vanilla flag; nothing here
-- special cases anything.
--
-- The pressure is the point. A hide that never spoils is a hide the
-- player can hoard, and hoarding is the behaviour the currency exists
-- to price.
-- ==========================================

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
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'HIDE_ROT'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

local repeatUtil = require('repeat-util')
local REPEAT_KEY = 'making_fuel_hide_rot'

-- ---- BODY IDENTITY ----
-- A fresh table per execution of this file body. reqscript re-executes
-- the body and makes a new one; a world load does not.
--
-- It exists because the two obvious ways to guard start() both fail,
-- in opposite directions. A file-local running flag resets on a new
-- body, so start() proceeds and rebinds correctly, but it knows
-- nothing about the world and can run against dead state. A _G flag
-- gets the world right and then refuses to rebind, so repeatUtil keeps
-- calling the PREVIOUS body's closure and the reloaded code never runs
-- while manual commands run the new code. Tracking both distinguishes
-- "already running in this same body" from "reloaded, needs rebinding".
local BODY = {}

-- ---- THE ONE BALANCE NUMBER ----
-- Days before an untanned hide or scrap spoils.
--
-- A PLAYER SETTING NOW. The number lives in making-fuel-tuning's T as
-- HIDE_SPOIL_DAYS, where the Making Fuel page of the RM HUD writes each
-- fort's choice over the shipped default, and spoil_days() below reads
-- it at every use, so a change lands on the next poll. The reasoning
-- for the default stays here, with the code it governs.
--
-- 21 is three quarters of a month. Rationale, so it can be moved
-- knowingly: a tannery working a normal butchery queue clears a hide
-- well inside three weeks, so a player who processes as they go never
-- sees a rotten one. A player who stockpiles hides against a future
-- project loses them before the season turns. That is the line the
-- number is drawn on, and it is the only thing to change if the
-- pressure feels wrong.
--
-- For comparison, wet fuel air dries in 14 days in this module.
--
-- Guarded like the log composer. If the tuning file will not load
-- there is no spoil time at all, and the poll says so and does nothing
-- rather than rot hides on a number nobody chose.
local tuning = nil
pcall(function() tuning = reqscript('making-fuel-tuning') end)
local function spoil_days()
    return tuning and tuning.T and tuning.T.HIDE_SPOIL_DAYS
end
-- True once the missing spoil time has been logged, so a fort without
-- one hears it once rather than every day.
local spoil_missing_said = false

-- ---- AND HOW LONG THE ROTTEN ONE LINGERS ----
-- Days AFTER spoiling before the hide is destroyed outright. Total
-- life is HIDE_SPOIL_DAYS + GONE_DAYS.
--
-- This exists because DF will not do it. Destruction is the far end of
-- the same rot progression that measurably never runs on a glob, so a
-- rotten hide sits there forever, unlike a vanilla rawhide corpsepiece
-- which DF does remove. Measured: no disappearance and no miasma, both
-- predicted by the timer recycling at 200.
--
-- 21 is provisional and symmetric with HIDE_SPOIL_DAYS. The reasoning: once
-- rotten, a hide is feedstock for the rot wing, so the window has to be
-- long enough for a player to notice the miasma-less pile and queue
-- "make charcoal from rot", and short enough that ignoring it does not
-- leave hundreds of globs in the item list forever. Three weeks of
-- grace after three weeks of freshness.
--
-- To replace it with DF's own figure for a rawhide, point the recorder
-- at one and read the VANISHED line:
--   making-fuel-rot-recorder on <rawhide item id>
local GONE_DAYS = 21

-- ---- STORAGE DOES NOT PRESERVE ----
-- Design decision, recorded because the code below implements the
-- other answer and can be switched back to it with this one line.
--
-- DF sends a rawhide to a refuse pile and lets it rot there. We send a
-- hide glob to the Glob category of a food pile, which is where DF
-- puts every glob including vanilla fat, and we let it rot there. Same
-- treatment, different pile, and the pressure to process promptly
-- survives either way. A hide that keeps indefinitely once stored
-- removes the only thing making the player tan it.
--
-- true restores the hold: a stored hide's age is pushed back each poll
-- so its clock stands still while stored and resumes where it stopped.
-- The machinery for that is intact below and costs nothing switched
-- off.
local PRESERVE_IN_STORAGE = false

-- Age units per calendar day. UNVERIFIED, and deliberately the same
-- unverified value making-fuel-air-dry.lua uses, so one calibration
-- fixes both. If drying paces wrong there it paces wrong here by the
-- same factor. Do not fork this constant.
local AGE_PER_DAY = 120

local POLL_DAYS = 1

-- Every material this file is allowed to spoil. Both hide tiers share
-- the prefix, so one test covers whole skins and partials.
local OUR_PREFIX = 'MAKING_FUEL_HIDE'

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
-- SUBJECT is the correlation slot: POLL for the daily pass, SPOIL,
-- GONE and HOLD for a single hide, START and STOP. The status and usage
-- output at the bottom answers commands typed at the console, so it
-- prints.
--
-- This replaces a log() that let refinish-log guess TYPE from the
-- words (read_type). Three call sites still passed the level number of
-- an older log API (0 or 2), which landed in the subject slot and
-- showed as a subject of 0 or 2.
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

-- ---- FAULTS THE DAILY POLL WOULD REPEAT ----
-- The poll runs every in game day, about twelve real seconds, and both
-- of these fail the same way on every pass for as long as they last.
-- Each is logged once per session; start() clears them.
local remove_failed    = {}      -- item id -> true, a hide that would not go
local flag_failed_said = false   -- the rotten flag could not be written

local function try(fn, dflt)
    local ok, v = pcall(fn)
    if ok then return v end
    return dflt
end

-- In _G, not a file local. The body re-executes on every reqscript
-- while a world load does not, so a file local would report "already
-- running" against a world that no longer exists. Same lesson as
-- making-fuel-hide-sprite.lua records at length.
_G.making_fuel_hide_rot_running = _G.making_fuel_hide_rot_running or false

-- ---- THE HOLD TABLE ----
-- item id -> the age it had when it was last seen preserved.
--
-- age cannot be paused; it is DF's counter and it advances on every
-- item everywhere. It CAN be held: each poll, a preserved hide is
-- written back to the age it had last poll, so its clock stands still
-- while stored and resumes exactly where it stopped.
--
-- That makes the item's own age field the persistent decay counter.
-- Nothing goes in the JSON payload, it survives saves for free, and
-- mint_glob's carry already works on the same field.
--
-- Losing this table costs at most one poll of hold, because the game
-- clock does not advance while DF is closed and the first poll after a
-- load simply records the current age. It is deliberately not saved.
_G.making_fuel_hide_rot_hold = _G.making_fuel_hide_rot_hold or {}

-- ==========================================
-- IS THIS ONE OF OURS
-- ==========================================
local function ours(it)
    if try(function() return it:getType() end) ~= df.item_type.GLOB then
        return false
    end
    local info = try(function() return dfhack.matinfo.decode(it) end)
    local tok  = info and try(function() return info:getToken() end)
    return tok and tostring(tok):find(OUR_PREFIX, 1, true) ~= nil
end

-- ==========================================
-- POLL
-- ==========================================
-- One walk of the item list per day. Per item pcall, so one unreadable
-- reference cannot abort the rest of the scan; that failure mode has
-- cost this module a whole feature before.
local function poll()
    local all = try(function() return df.global.world.items.all end)
    if not all then
        log('WARNING', 'world.items.all unreadable this poll. Nothing spoiled.', 'POLL')
        return
    end

    -- Read once per poll, so a change on the settings page lands whole
    -- on the next one rather than halfway through this walk.
    local spoil = spoil_days()
    if not spoil then
        if not spoil_missing_said then
            spoil_missing_said = true
            -- ERROR: nothing spoils or rots away until this is fixed.
            log('ERROR', 'no HIDE_SPOIL_DAYS in making-fuel-tuning, so no hide'
                .. ' spoils. Check that the tuning file loads.', 'POLL')
        end
        return
    end

    local hold      = _G.making_fuel_hide_rot_hold
    local threshold = spoil * AGE_PER_DAY
    local gone_at   = (spoil + GONE_DAYS) * AGE_PER_DAY
    local seen, spoiled, oldest, gone = 0, 0, 0, 0

    local n = try(function() return #all end, 0)
    for i = 0, n - 1 do
        pcall(function()
            local it = all[i]
            if not it or not ours(it) then return end
            seen = seen + 1

            local age = try(function() return it.age end, 0) or 0
            local id  = try(function() return it.id end)

            -- ==========================================
            -- PRESERVED STORAGE HOLDS THE CLOCK
            -- ==========================================
            -- A hide in a stockpile, or in a container, does not
            -- decay. Checked before oldest is recorded so the
            -- heartbeat reports the held age rather than the moment
            -- before it was pushed back.
            --
            -- Both tests, because a barrelled hide is inside a
            -- container that is itself in a pile, and reading only the
            -- tile would decay it.
            local preserved = false
            if PRESERVE_IN_STORAGE then try(function()
                if dfhack.items.getContainer(it) then
                    preserved = true
                    return
                end
                local b = dfhack.buildings.findAtTile(
                    xyz2pos(dfhack.items.getPosition(it)))
                if b and df.building_stockpilest:is_instance(b) then
                    preserved = true
                end
            end) end

            if preserved and id then
                local held = hold[id]
                if held and held < age then
                    -- Push it back to where it was. Exact regardless of
                    -- how far apart the polls fell, which a fixed
                    -- subtraction of AGE_PER_DAY would not be.
                    if pcall(function() it.age = held end) then
                        age = held
                        log('DETAIL', string.format('   #%s held at age %d'
                            .. ' (stored).', tostring(id), held), 'HOLD')
                    end
                else
                    hold[id] = age
                end
            elseif id then
                -- Out of storage: drop the hold so the clock runs
                -- again from wherever it was frozen.
                hold[id] = nil
            end

            if age > oldest then oldest = age end

            -- ==========================================
            -- DESTRUCTION, BEFORE ANYTHING ELSE
            -- ==========================================
            -- Checked ahead of the spoil branch because an already
            -- rotten item returns early below and would never reach
            -- this.
            --
            -- in_job is skipped, and that is the whole safety of it:
            -- items.remove cancels any job attached to the item, so
            -- destroying one mid haul would cancel the very charcoal
            -- job the hide was on its way to feed. A hide being
            -- carried gets one more day and is caught next poll.
            --
            -- forbid is NOT respected here, matching the rot watcher's
            -- position that rot is garbage nobody meant to keep. The
            -- hide reactions respect forbid; disposal does not.
            --
            -- Removing inside the walk is safe: Lua_API.txt:2033 says
            -- items.remove marks for garbage collection and unlinks
            -- containers and inventories. It does not splice
            -- world.items.all, which is the vector being indexed here.
            if age >= gone_at then
                if try(function() return it.flags.in_job end) then
                    log('DETAIL', string.format('#%s is past %d days but in a job;'
                        .. ' left for next poll.',
                        tostring(try(function() return it.id end)),
                        spoil + GONE_DAYS), 'GONE')
                    return
                end
                local ok_rm = pcall(dfhack.items.remove, it)
                if id then hold[id] = nil end
                if ok_rm then
                    gone = gone + 1
                    log('DETAIL', string.format('#%s destroyed at age %d of %d.'
                        .. ' Rotted away unburned.', tostring(id), age,
                        gone_at), 'GONE')
                elseif not remove_failed[tostring(id)] then
                    -- ERROR, once per hide: it stays in the fort forever.
                    remove_failed[tostring(id)] = true
                    log('ERROR', string.format('#%s is past %d days and could'
                        .. ' not be removed.', tostring(id),
                        spoil + GONE_DAYS), 'GONE')
                end
                return
            end

            -- Already rotten: nothing to do, and re-setting the flag
            -- every day would re-trigger anything watching for the
            -- transition.
            if try(function() return it.flags.rotten end) then return end
            if age < threshold then return end

            -- A glob minted from two nearly dead partials inherits
            -- the older one's age through mint_glob, so it can be born
            -- past both thresholds and spoil or vanish on the next
            -- poll. That is the carry working, not a fault: combining
            -- two hides on their last week must not produce a fresh
            -- one.
            local ok = pcall(function() it.flags.rotten = true end)
            if ok then
                spoiled = spoiled + 1
                log('DETAIL', string.format('#%s spoiled at age %d of %d.',
                    tostring(try(function() return it.id end)),
                    age, threshold), 'SPOIL')
            elseif not flag_failed_said then
                -- ERROR, once per session: a missing field fails for
                -- every hide on every poll, and no hide will spoil.
                flag_failed_said = true
                log('ERROR', string.format('#%s could not be flagged rotten.'
                    .. ' Field missing or renamed in this DF build.',
                    tostring(try(function() return it.id end))), 'SPOIL')
            end
        end)
    end

    -- Heartbeat, same shape as the air dryer's, so the age unit can be
    -- calibrated by reading one line rather than by instrumenting.
    --
    -- INFO on a day something spoiled or rotted away, which is what a
    -- player checks when hides go missing, and DETAIL otherwise. The
    -- per hide lines are DETAIL, so a big stockpile turning is one
    -- Normal line rather than one per hide.
    if seen > 0 then
        log((spoiled + gone) > 0 and 'INFO' or 'DETAIL',
            string.format('poll: %d hide(s), %d spoiled, %d rotted away,'
            .. ' oldest age %d of %d.', seen, spoiled, gone, oldest,
            threshold), 'POLL')
    end
end

-- ==========================================
-- LIFECYCLE
-- ==========================================
function start(silent)
    remove_failed, flag_failed_said = {}, false
    if _G.making_fuel_hide_rot_running then
        if _G.making_fuel_hide_rot_body == BODY then
            log('DETAIL', 'already running.', 'START')
            return
        end
        -- Reloaded. Rebind the poll to this body's copy; scheduleEvery
        -- replaces the entry under the same key.
        _G.making_fuel_hide_rot_body = BODY
        repeatUtil.scheduleEvery(REPEAT_KEY, POLL_DAYS, 'days', poll)
        log('DETAIL', 'reloaded: poll rebound to the new body.', 'START')
        return
    end
    _G.making_fuel_hide_rot_body = BODY
    _G.making_fuel_hide_rot_running = true
    repeatUtil.scheduleEvery(REPEAT_KEY, POLL_DAYS, 'days', poll)
    if not silent then
        log('DETAIL', string.format('active. Untanned hides spoil after %s days,'
            .. ' polled every %d.', tostring(spoil_days() or '?'), POLL_DAYS),
            'START')
    end
end

function stop()
    pcall(function() repeatUtil.cancel(REPEAT_KEY) end)
    _G.making_fuel_hide_rot_running = false
    log('DETAIL', 'stopped.', 'STOP')
end

-- ==========================================
-- COMMAND: status
-- ==========================================
-- Every hide in the fort with its age against the threshold, so the
-- pacing can be judged without waiting for something to spoil.
function status()
    local all = try(function() return df.global.world.items.all end)
    if not all then print('world.items.all unreadable.') return end
    local spoil = spoil_days()
    if not spoil then print('No HIDE_SPOIL_DAYS in making-fuel-tuning.') return end
    local threshold = spoil * AGE_PER_DAY
    local n = try(function() return #all end, 0)
    local seen = 0
    for i = 0, n - 1 do
        pcall(function()
            local it = all[i]
            if not it or not ours(it) then return end
            seen = seen + 1
            local info = try(function() return dfhack.matinfo.decode(it) end)
            print(string.format('  #%-6s %-38s age %6d / %d  %s',
                tostring(try(function() return it.id end)),
                tostring(info and try(function() return info:getToken() end)),
                try(function() return it.age end, 0) or 0, threshold,
                try(function() return it.flags.rotten end) and 'ROTTEN' or ''))
        end)
    end
    print(string.format('%d hide(s). Spoil at %d days = %d age units.',
        seen, spoil, threshold))
end

-- ==========================================
-- CLI
-- ==========================================
if dfhack_flags and dfhack_flags.module then return end

local cmd = ...
if cmd == 'on' then start()
elseif cmd == 'off' then stop()
elseif cmd == 'status' then status()
elseif cmd == 'poll' then poll()
else print('usage: making-fuel-hide-rot on | off | status | poll') end