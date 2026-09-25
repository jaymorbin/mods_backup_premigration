-- refinish-tool-inspect.lua
-- ==========================================
-- TOOL ITEMDEF INSPECTOR
-- ==========================================
-- Dumps the live structure of an itemdef_toolst so the field map in
-- refinish-module-inject-tool.lua can be confirmed against the actual
-- game rather than assumed.
--
-- Run this once, read the output file, correct the FIELD MAP in the
-- injector if anything differs. Everything else in the tool system is
-- driven off that one table, so this is the only place struct layout
-- knowledge lives.
--
-- Usage from the DFHack console:
--     refinish-tool-inspect
--     refinish-tool-inspect ITEM_TOOL_LARGE_POT
--
-- Writes to  refinish_tool_inspect.txt  in the DF root folder. Written
-- to a file rather than printed because a struct listing is something
-- you read carefully, and the console cannot be read while the game
-- runs anyway.
-- ==========================================

local args = {...}

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body.
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
-- SUBJECT is the correlation slot: FILE when the output could not be
-- written, DUMP when it was.
--
-- This replaces a bare untagged line under the TOOL INSPECT prefix,
-- which printed only when the log was not loaded.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- This file is only ever typed at the console, so its answer is also
-- printed: that print is the direct response to what was typed. See
-- answer() below.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'TOOL_INSPECT'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

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

-- ---- THE ANSWER TO A TYPED COMMAND ----
-- Printed, because it is the direct response to what was typed, and
-- logged, because everything goes in the log.
local function answer(typ, msg, subject)
    print('refinish-tool-inspect: ' .. tostring(msg))
    log(typ, msg, subject)
end

-- Which tool to dissect. The jug is the best default: it is a liquid
-- container with a capacity, which is exactly the shape the module
-- containers need, so every field that matters is populated.
local TARGET = args[1] or "ITEM_TOOL_JUG"

local OUTFILE = "refinish_tool_inspect.txt"


-- ==========================================
-- OUTPUT BUFFER
-- ==========================================
-- Collected in memory and written once at the end, so a crash midway
-- leaves no half file to mistake for a complete one.
-- ==========================================

local out = {}

local function w(fmt, ...)
    if select('#', ...) > 0 then
        table.insert(out, string.format(fmt, ...))
    else
        table.insert(out, fmt)
    end
end

local function rule(title)
    w("")
    w("==================================================================")
    w(title)
    w("==================================================================")
end


-- ==========================================
-- SAFE FIELD READ
-- ==========================================
-- Reading an unknown field on a DFHack struct wrapper throws rather
-- than returning nil, so every read is guarded. Returns a printable
-- description of the value and its type.
-- ==========================================

local function describe(value)
    local t = type(value)

    if t == "userdata" then
        -- Vectors, bitfields and nested structs all arrive as userdata.
        -- _kind tells them apart when DFHack exposes it.
        local ok, kind = pcall(function() return value._kind end)
        local ok2, len = pcall(function() return #value end)
        if ok and kind then
            if ok2 then
                return string.format("userdata (%s, length %d)", tostring(kind), len)
            end
            return string.format("userdata (%s)", tostring(kind))
        end
        if ok2 then
            return string.format("userdata (length %d)", len)
        end
        return "userdata"
    end

    if t == "table" then
        local n = 0
        for _ in pairs(value) do n = n + 1 end
        return string.format("table (%d keys)", n)
    end

    if t == "string" then
        return string.format("string  %q", value)
    end

    return string.format("%s  %s", t, tostring(value))
end

local function read_field(struct, name)
    local ok, value = pcall(function() return struct[name] end)
    if not ok then
        return nil, "NOT PRESENT"
    end
    return value, describe(value)
end


-- ==========================================
-- STEP 1: LOCATE THE ITEMDEF CONTAINERS
-- ==========================================
-- world.raws.itemdefs holds one vector per subtype-carrying item type,
-- plus an "all" vector that spans every one of them. An injected tool
-- has to land in both, so both are confirmed here.
-- ==========================================

rule("STEP 1: ITEMDEF CONTAINERS")

local itemdefs = df.global.world.raws.itemdefs

local CONTAINER_NAMES = {
    "all", "tools", "trapcomps", "weapons", "armor", "shoes", "shields",
    "helms", "gloves", "pants", "toys", "instruments", "ammo",
    "siege_ammo", "food",
}

for _, name in ipairs(CONTAINER_NAMES) do
    local ok, vec = pcall(function() return itemdefs[name] end)
    if ok and vec then
        local ok2, len = pcall(function() return #vec end)
        w("  %-14s present, %s entries", name, ok2 and tostring(len) or "unknown")
    else
        w("  %-14s NOT PRESENT", name)
    end
end


-- ==========================================
-- STEP 2: FIND THE TARGET TOOL
-- ==========================================

rule("STEP 2: TARGET TOOL  " .. TARGET)

local target_def = nil
local target_pos = nil

for i, td in ipairs(itemdefs.tools) do
    local ok, id = pcall(function() return td.id end)
    if ok and id == TARGET then
        target_def = td
        target_pos = i
        break
    end
end

if not target_def then
    w("  NOT FOUND. Tools currently loaded:")
    for i, td in ipairs(itemdefs.tools) do
        local ok, id = pcall(function() return td.id end)
        w("    [%3d] %s", i, ok and tostring(id) or "unreadable")
    end
else
    w("  Found at array position %d", target_pos)

    -- The critical relationship for injection: does the subtype field
    -- equal the array position? If it does, an injected tool must set
    -- subtype to its own insert index, and every existing item stack
    -- referencing a subtype breaks if the array ever reorders.
    local sub = read_field(target_def, "subtype")
    w("  subtype field value: %s", tostring(sub))
    if sub == target_pos then
        w("  subtype MATCHES array position. Injection must set it.")
    else
        w("  subtype DIFFERS from array position (%d vs %d). Investigate.",
            tostring(sub) ~= "nil" and sub or -1, target_pos)
    end
end


-- ==========================================
-- STEP 3: FIELD BY FIELD DUMP
-- ==========================================
-- Every field the injector might want to write. Names come from the
-- raw tokens in item_tool.txt, translated to the likely struct spelling.
-- Anything reported NOT PRESENT needs its real name found in step 4.
-- ==========================================

rule("STEP 3: CANDIDATE FIELDS")

local CANDIDATES = {
    -- identity
    "id", "subtype",
    -- display names, from NAME and ADJECTIVE
    "name", "name_plural", "adjective",
    -- economics and appearance, from VALUE and TILE
    "value", "tile",
    -- bulk, from SIZE and MATERIAL_SIZE
    "size", "material_size",
    -- the one that matters most here, from CONTAINER_CAPACITY
    "container_capacity",
    -- TOOL_USE list
    "tool_use",
    -- token flags: FURNITURE, NO_DEFAULT_JOB, UNIMPROVABLE and friends
    "flags",
    -- material class tokens: HARD_MAT, METAL_MAT, SOFT_MAT and so on
    "material_placeholder", "mat_class",
    -- shape and skill, present on some tools
    "shape", "shape_category", "skill_use",
    -- weapon-ish fields, only on tools that carry ATTACK
    "attacks", "two_handed", "minimum_size",
}

if target_def then
    for _, name in ipairs(CANDIDATES) do
        local _, desc = read_field(target_def, name)
        w("  %-22s %s", name, desc)
    end
end


-- ==========================================
-- STEP 4: EVERY REAL FIELD
-- ==========================================
-- Authoritative list, straight off the wrapper. If step 3 reported a
-- field NOT PRESENT, its real name is somewhere in here.
-- ==========================================

rule("STEP 4: ACTUAL FIELD LIST")

if target_def then
    local ok, fields = pcall(function()
        local t = {}
        for k, v in pairs(target_def) do
            table.insert(t, k)
        end
        return t
    end)

    if ok and fields and #fields > 0 then
        table.sort(fields)
        for _, name in ipairs(fields) do
            local _, desc = read_field(target_def, name)
            w("  %-22s %s", name, desc)
        end
    else
        w("  Could not iterate the wrapper directly.")
        w("  Fall back to:  printall(df.itemdef_toolst)")
    end
end


-- ==========================================
-- STEP 5: TOOL USE ENUM
-- ==========================================
-- TOOL_USE tokens in the raws become entries in this enum. The module
-- schema takes the token string, so the injector needs the mapping.
-- ==========================================

rule("STEP 5: df.tool_uses ENUM")

local ok_enum, enum = pcall(function() return df.tool_uses end)
if ok_enum and enum then
    local entries = {}
    for k, v in pairs(enum) do
        if type(k) == "string" and type(v) == "number" then
            table.insert(entries, { name = k, value = v })
        end
    end
    table.sort(entries, function(a, b) return a.value < b.value end)
    for _, e in ipairs(entries) do
        w("  %3d  %s", e.value, e.name)
    end
    w("")
    w("  %d tool uses total.", #entries)
else
    w("  df.tool_uses not reachable. Try:  printall(df.tool_uses)")
end


-- ==========================================
-- STEP 6: FLAG BITFIELD
-- ==========================================
-- Whichever field step 4 showed as the flags bitfield, list its members
-- so the schema can name them.
-- ==========================================

rule("STEP 6: FLAG MEMBERS")

if target_def then
    local flags, desc = read_field(target_def, "flags")
    if flags and type(flags) == "userdata" then
        local ok, members = pcall(function()
            local t = {}
            for k, v in pairs(flags) do
                table.insert(t, string.format("  %-28s %s", tostring(k), tostring(v)))
            end
            return t
        end)
        if ok and members and #members > 0 then
            table.sort(members)
            for _, line in ipairs(members) do w(line) end
        else
            w("  flags present but not iterable: %s", desc)
        end
    else
        w("  no flags field: %s", tostring(desc))
    end
end


-- ==========================================
-- WRITE OUT
-- ==========================================

local f, err = io.open(OUTFILE, "w")
if not f then
    answer('ERROR', "could not open " .. OUTFILE .. ": " .. tostring(err),
        'FILE')
    return
end

f:write(table.concat(out, "\n"))
f:write("\n")
f:close()

answer('INFO', string.format("dumped %s to %s (%d lines)", TARGET, OUTFILE,
    #out), 'DUMP')