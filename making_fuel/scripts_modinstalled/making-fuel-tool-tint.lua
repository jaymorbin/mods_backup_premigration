-- making-fuel-tool-tint.lua
-- =====================================================================
-- TOOL TINT: OUR COLOUR IN DF'S CACHE
-- =====================================================================
-- MEASURED, the whole reason this file exists. A tool itemdef holds one
-- texpos per material CLASS, not per material, so DF does its own per
-- material tint and files the result in itemdef.graphics_info. Dumped
-- on MAKING_FUEL_GRAVEL:
--
--   flags: material 1, quality 0, variant 0, damage_level 0,
--          color_index 31, localdef_shape_index 0
--   texpos 167916
--
-- While an entry exists DF draws THAT texpos and never reads
-- texpos_item or texpos_stone. Proved twice in play: pointing every
-- texpos field at another tool's cell changed nothing on screen, and
-- writing this entry's texpos changed it instantly. DF also rebuilds
-- the entry when it is cleared, so the vector cannot be emptied to
-- force the flat fields back.
--
-- DF's tint is weaker than ours, which is the pale stippled gravel:
-- same descriptor colour reads strong on a boulder we tinted and washed
-- out on a tool DF tinted. So this file manufactures the texture in the
-- material's colour, the way the boulder art already is, and writes it
-- into DF's own cache entry.
--
-- ART LIVES IN LUA, NOT ON THE SHEET. Nothing can read a PNG's pixels
-- back out of DF, so only char map art can be tinted. The maps are in
-- making-fuel-sprite-art-tools.lua, converted from the sheet.
--
-- THE COLOUR KEY IS A HYPOTHESIS, AND IS TREATED AS ONE. Oil shale
-- carries state_color.Solid 30 and its gravel entry read color_index
-- 31, so the entry's key looks like the descriptor index plus one. One
-- observation is not a rule, so the match below tries that first, falls
-- back to dressing every entry when only one colour is in play, and
-- logs what it saw when neither works. The log is what settles it.
-- =====================================================================

--@ module = true

local eventful   = require('plugins.eventful')
local repeatUtil = require('repeat-util')
local REPEAT_KEY = 'making_fuel_tool_tint'

-- Every tool whose items should wear our tint, and the char map they
-- wear. Add a pair here and the watcher covers it; nothing else in this
-- file needs to know how many there are.
-- GRAVEL ONLY, and it stays that way unless a tool is actually broken.
-- Every other tool on that sheet renders correctly under DF's own tint.
-- Dressing them all cost nothing but damage: converted art with shifted
-- shapes, stray flecks, and blown out contrast that our stronger tint
-- turned neon. A tool belongs here when DF's tint demonstrably fails on
-- it, not because its art happens to be convertible.
local TOOL_ART = {
    MAKING_FUEL_GRAVEL  = 'gravel',
    MAKING_FUEL_CINDER  = 'cinders',
    MAKING_FUEL_SAWDUST = 'sawdust',
}

-- ---- LOG IDENTITY, DECLARED HERE ----
-- RM core does not know this module exists and must never have to, so
-- the module states its own system and subsystem. Guarded reqscript: a
-- bare top level one is a hard load time dependency.
--
-- Declared ABOVE release_others(), which is the first function that
-- logs. It used to sit below it, so that call compiled to a global
-- log, which is nil: handing back a dressed tool would have thrown
-- inside start() and left the tint unstarted for the session.
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'TOOL_TINT'
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
-- SUBJECT is the correlation slot: the art a line is about (gravel,
-- cinders, sawdust), RELEASE for tools handed back to DF, START and
-- STOP.
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

-- Tools this file dressed before and must hand back. Clearing the cache
-- vector makes DF rebuild its own entry, which is how they return to
-- what they looked like before I touched them. Runs once per start.
local RELEASE_TOOLS = {
    'MAKING_FUEL_BRANCH', 'MAKING_FUEL_KINDLING', 'MAKING_FUEL_SCRAP',
    'MAKING_FUEL_CULLET', 'MAKING_FUEL_TINDER',
    'MAKING_FUEL_CRUST', 'MAKING_FUEL_WASTE', 'MAKING_FUEL_BRIQUETTE',
}

local function release_others()
    local want, n = {}, 0
    for _, id in ipairs(RELEASE_TOOLS) do want[id] = true end
    pcall(function()
        for _, td in ipairs(df.global.world.raws.itemdefs.tools) do
            if want[tostring(td.id)] and #td.graphics_info > 0 then
                td.graphics_info:resize(0)
                n = n + 1
            end
        end
    end)
    if n > 0 then
        log('DETAIL', ('%d tool(s) handed back to DF: cache cleared, DF rebuilds '
             .. 'its own entry.'):format(n), 'RELEASE')
    end
end

-- The offset between a material's descriptor index and the entry's
-- color_index, from the one dump we have. Read from here so a
-- correction is one number.
local COLOR_INDEX_OFFSET = 1

-- Every 10 frames. The work is a walk of the TOOL vector and a handful
-- of integer writes; the textures themselves are cached after first
-- manufacture, per art and colour pair.
local POLL_FRAMES = 10

-- One line per fault, not per poll. A tool that cannot be dressed says
-- so once and then stays quiet.
local said = {}
local function log_once(key, typ, msg, subject)
    if said[key] then return end
    said[key] = true
    log(typ, msg, subject)
end

-- ==========================================
-- SUBTYPE RESOLUTION
-- ==========================================
-- Rebuilt by start(), because injection moves subtypes between
-- sessions. subtype integer -> art name.
local by_subtype = nil

local function resolve_subtypes()
    if by_subtype then return by_subtype end
    local found, n = {}, 0
    pcall(function()
        for _, td in ipairs(df.global.world.raws.itemdefs.tools) do
            local art_name = TOOL_ART[tostring(td.id)]
            if art_name then
                found[td.subtype] = { art = art_name, def = td }
                n = n + 1
            end
        end
    end)
    if n == 0 then return nil end
    by_subtype = found
    return by_subtype
end

-- ==========================================
-- THE PASS
-- ==========================================
-- One walk of the TOOL vector collects which materials are actually in
-- play per tool, so nothing is manufactured for a colour no item wears.
-- Then each tool's cache entries are dressed.
function pass()
    local subs = resolve_subtypes()
    if not subs then return 0 end
    local art = reqscript('refinish-sprite-art')

    -- subtype -> { [mat_key] = { mat = matinfo, colour = descriptor idx } }
    local seen = {}
    pcall(function()
        for _, it in ipairs(df.global.world.items.other.TOOL) do
            local st = nil
            pcall(function() st = it.subtype.subtype end)
            local entry = st and subs[st]
            if entry then
                pcall(function()
                    local mi = dfhack.matinfo.decode(it)
                    if not (mi and mi.material) then return end
                    local ci = mi.material.state_color.Solid
                    local key = tostring(it.mat_type) .. ':'
                              .. tostring(it.mat_index)
                    seen[st] = seen[st] or {}
                    seen[st][key] = { mat = mi.material, colour = ci }
                end)
            end
        end
    end)

    local dressed = 0
    for st, mats in pairs(seen) do
        local entry = subs[st]
        local wanted, n_colours = {}, 0     -- expected color_index -> texpos
        for _, m in pairs(mats) do
            local texpos, err = art.texpos_for(m.mat, entry.art)
            if texpos then
                wanted[m.colour + COLOR_INDEX_OFFSET] = texpos
                n_colours = n_colours + 1
            else
                log_once('mk:' .. entry.art, 'WARNING', ('could not manufacture %s: %s')
                    :format(entry.art, tostring(err)), tostring(entry.art))
            end
        end

        pcall(function()
            local gi = entry.def.graphics_info

            -- ---- NO CACHE ENTRY: DRESS THE FLAT FIELDS ----
            -- MEASURED: gravel carries entries and took our texture at
            -- once, while cinders carry none and kept their boulder
            -- art, because the loop below had nothing to write into.
            -- With the vector empty DF draws from texpos_item and the
            -- per class arrays, so those are what get written.
            --
            -- They are per material CLASS, not per material, so they
            -- hold ONE colour. With more than one material in play the
            -- last one wins, and it says so rather than looking right
            -- by accident.
            if #gi == 0 then
                local texpos = nil
                for _, t in pairs(wanted) do texpos = t end
                if texpos then
                    if n_colours > 1 then
                        log_once('flat:' .. entry.art, 'WARNING', ('%s has no cache '
                            .. 'entry and %d material(s) in play. The flat '
                            .. 'fields hold one colour, so every one of '
                            .. 'them wears the last.')
                            :format(entry.art, n_colours), tostring(entry.art))
                    end
                    if entry.def.texpos_item ~= texpos then
                        entry.def.texpos_item = texpos
                        dressed = dressed + 1
                    end
                    for _, field in ipairs({ 'texpos_stone', 'texpos_metal',
                                             'texpos_wood', 'texpos_glass' }) do
                        pcall(function()
                            local arr = entry.def[field]
                            for i = 0, #arr - 1 do arr[i] = texpos end
                        end)
                    end
                end
                return
            end

            for _, g in ipairs(gi) do
                local ci = g.flags.color_index
                local texpos = wanted[ci]
                -- Fallback while the key is unproven: one colour in
                -- play means every entry is that colour, whatever the
                -- number says.
                if not texpos and n_colours == 1 then
                    for _, t in pairs(wanted) do texpos = t end
                    log_once('key:' .. entry.art, 'WARNING', ('entry color_index %d '
                        .. 'did not match any material in play on %s; '
                        .. 'dressed anyway because only one colour is '
                        .. 'present. Expected one of the keys this file '
                        .. 'computes, so COLOR_INDEX_OFFSET is wrong.')
                        :format(ci, entry.art), tostring(entry.art))
                end
                if texpos and g.texpos ~= texpos then
                    g.texpos = texpos
                    dressed = dressed + 1
                end
            end
        end)
    end
    return dressed
end

-- ==========================================
-- LIFECYCLE
-- ==========================================
-- DF rebuilds a cache entry whenever it needs one, so this has to keep
-- running rather than dressing once at start. The created event is not
-- enough on its own: an entry appears when an item is first DRAWN, not
-- when it is made.
function start()
    by_subtype = nil
    said = {}
    release_others()
    repeatUtil.scheduleEvery(REPEAT_KEY, POLL_FRAMES, 'frames', function()
        pcall(pass)
    end)
    local n = pass()
    log('DETAIL', ('active. %d cache entr(ies) dressed on the first pass.')
        :format(n), 'START')
end

function stop()
    repeatUtil.cancel(REPEAT_KEY)
    by_subtype = nil
    -- The entries are DF's, not ours: left as they are. DF rewrites
    -- them itself the next time it needs one, and the textures they
    -- point at are kept for the life of the process anyway.
    log('DETAIL', 'stopped.', 'STOP')
end