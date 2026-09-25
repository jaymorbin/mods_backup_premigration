-- refinish-tool-graphics.lua
-- ==========================================
-- TOOL GRAPHICS PROBE AND DONOR COPY
-- ==========================================
-- Vanilla tool sprites are declared in the graphics raws keyed by code:
--
--     [TOOL_GRAPHICS:CONTAINERS:4:3:ITEM_TOOL_LARGE_POT]
--         [TOOL_GRAPHICS_WOOD:ALL:CONTAINERS:0:10]
--         [TOOL_GRAPHICS_STONE:ALL:CONTAINERS:1:10]
--
-- DF resolves those at raw load into texture positions. An injected
-- tool never goes through raw load, so it has none, and draws nothing.
-- A cleared one falls back to a real tool and draws that tool's sprite,
-- which is why a cask turns into a clay pot WITH an image on shutdown.
--
-- Rather than assume where those values live, this diffs an injected
-- tool against a vanilla tool that works. Whatever differs is the
-- graphics state, and it can then be copied.
--
-- USAGE
--
--     refinish-tool-graphics probe MAKING_FUEL_SMALL_CASK ITEM_TOOL_LARGE_POT
--     refinish-tool-graphics copy  MAKING_FUEL_SMALL_CASK ITEM_TOOL_LARGE_POT
--     refinish-tool-graphics copyall MAKING_FUEL_
--
-- probe   reports every field that differs, and nothing else.
-- copy    copies the graphics shaped fields from donor to target.
-- copyall applies the built in DONOR_MAP to every injected tool.
--
-- probe and copy answer a command typed at the console, so they print.
-- copyall is also run by the module engine on every injection
-- (refinish-module-engine.lua, SPRITES), which nobody typed, so it
-- reports to the log only, typed or not.
--
-- Run probe FIRST. It tells you whether the graphics state is even on
-- this struct. If probe reports no differences beyond id, name and
-- subtype, then sprites live somewhere else entirely and copying here
-- will not help, which is worth knowing before spending a recycle.
-- ==========================================

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- RM's own, and peripheral rather than pipeline. Every log line this
-- file writes goes through log(), in the one grammar the log panel
-- reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body.
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
-- SUBJECT is the correlation slot: COPY for one tool, COPYALL for the
-- run.
--
-- This replaces a log() that took the subsystem as an argument and
-- let refinish-log guess TYPE from the words (read_type) unless a call
-- site said otherwise.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here. The prints that remain in
-- this file answer probe and copy, typed at the console (see USAGE).
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'TOOL_GRAPHICS'
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

local args = {...}
local MODE   = args[1] or "probe"
local TARGET = args[2]
local DONOR  = args[3]


-- ==========================================
-- DONOR MAP
-- ==========================================
-- Which vanilla tool each injected tool borrows its sprite from, used
-- by copyall. Chosen so the borrowed art is at least plausible: bottles
-- take the jug, casks take the large pot.
--
-- This is the rudimentary system. Point a tool at vanilla art by code,
-- no graphics raws involved. Swapping to your own art later is the same
-- mechanism with a donor that is your own tool.
-- ==========================================

local DONOR_MAP = {
    SMALL_BOTTLE = "ITEM_TOOL_JUG",
    LARGE_BOTTLE = "ITEM_TOOL_JUG",
    SMALL_CASK   = "ITEM_TOOL_LARGE_POT",
    LARGE_CASK   = "ITEM_TOOL_LARGE_POT",
    KINDLING     = "ITEM_TOOL_BRANCH_DUMMY",
    BRANCH       = "ITEM_TOOL_BRANCH_DUMMY",
    CINDER       = "ITEM_TOOL_CINDER_DUMMY",
    DUNG         = "ITEM_TOOL_DUNG_DUMMY",
    STRAW        = "ITEM_TOOL_STRAW_DUMMY",
    SAWDUST      = "ITEM_TOOL_SAWDUST_DUMMY",
    BARK         = "ITEM_TOOL_BARK_DUMMY"
}


-- ==========================================
-- FIELDS NEVER COPIED
-- ==========================================
-- Identity. Copying any of these would turn the target INTO the donor.
-- ==========================================

local NEVER_COPY = {
    id = true, subtype = true,
    name = true, name_plural = true, adjective = true,
}


-- ==========================================
-- HELPERS
-- ==========================================

local defs = df.global.world.raws.itemdefs.tools

local function find_tool(code)
    for i, td in ipairs(defs) do
        local ok, id = pcall(function() return td.id end)
        if ok and id == code then return td, i end
    end
    return nil, nil
end

-- Field values are compared as printable strings, because vectors and
-- bitfields arrive as userdata and cannot be compared directly.
local function snapshot(value)
    local t = type(value)
    if t == "userdata" then
        local ok, len = pcall(function() return #value end)
        if ok then
            -- Include contents for short vectors, since a texpos vector
            -- of the same length but different values is exactly the
            -- difference being looked for.
            if len > 0 and len <= 12 then
                local parts = {}
                for i = 0, len - 1 do
                    local ok2, v = pcall(function() return value[i] end)
                    table.insert(parts, ok2 and tostring(v) or "?")
                end
                return string.format("[%d: %s]", len, table.concat(parts, ","))
            end
            return string.format("[%d entries]", len)
        end
        return "userdata"
    end
    return tostring(value)
end

local function field_names(struct)
    local names = {}
    local ok = pcall(function()
        for k, _ in pairs(struct) do
            if type(k) == "string" then table.insert(names, k) end
        end
    end)
    if not ok then return nil end
    table.sort(names)
    return names
end


-- ==========================================
-- PROBE
-- ==========================================
-- Reports only the fields that differ. Identity fields are expected to
-- differ and are marked as such so they can be ignored at a glance.
-- ==========================================

local function probe(target_code, donor_code)
    local target = find_tool(target_code)
    local donor  = find_tool(donor_code)

    if not target then print("  target not found: " .. tostring(target_code)); return end
    if not donor  then print("  donor not found: "  .. tostring(donor_code));  return end

    local names = field_names(donor)
    if not names then
        print("  Could not iterate the struct. Fall back to:")
        print("    printall(df.global.world.raws.itemdefs.tools[N])")
        return
    end

    print("")
    print(string.format("=== %s  vs  %s ===", target_code, donor_code))

    local diffs = 0
    for _, name in ipairs(names) do
        local ok_t, tv = pcall(function() return target[name] end)
        local ok_d, dv = pcall(function() return donor[name] end)
        if ok_t and ok_d then
            local st, sd = snapshot(tv), snapshot(dv)
            if st ~= sd then
                diffs = diffs + 1
                print(string.format("  %-24s %-28s %s%s",
                    name, st, sd,
                    NEVER_COPY[name] and "   (identity, ignore)" or ""))
            end
        end
    end

    print("")
    print(string.format("  %d fields differ. Columns are: field, target, donor.", diffs))
    print("  Anything not marked identity is a copy candidate.")
    print("  If only identity fields differ, sprites are NOT on this")
    print("  struct and live in a separate graphics table instead.")
end


-- ==========================================
-- COPY
-- ==========================================
-- Copies every non identity field whose name looks graphics shaped.
--
-- Discovery by name pattern rather than a fixed list, because the point
-- of the probe is that the field names are not known in advance. Run
-- probe first and widen PATTERNS if it shows a field that matters and
-- is not being caught.
-- ==========================================

local PATTERNS = { "texpos", "tile", "graphic", "sprite", "color" }

local function looks_graphical(name)
    local lower = string.lower(name)
    for _, p in ipairs(PATTERNS) do
        if string.find(lower, p, 1, true) then return true end
    end
    return false
end

-- to_log is true for copyall (see USAGE): its reports go to the log
-- instead of the console. A typed copy leaves it nil and prints.
local function copy(target_code, donor_code, to_log)
    local target = find_tool(target_code)
    local donor  = find_tool(donor_code)

    -- A copy that cannot happen. WARNING in the log, since that tool
    -- then draws no borrowed sprite this session.
    local function refuse(msg)
        if to_log then log('WARNING', msg, 'COPY') else print("  " .. msg) end
        return 0
    end
    if not target then return refuse("target not found: " .. tostring(target_code)) end
    if not donor  then return refuse("donor not found: "  .. tostring(donor_code))  end

    local names = field_names(donor)
    if not names then return refuse("could not iterate donor " .. tostring(donor_code)) end

    local copied = 0

    for _, name in ipairs(names) do
        if not NEVER_COPY[name] and looks_graphical(name) then
            local ok_d, dv = pcall(function() return donor[name] end)
            if ok_d then
                if type(dv) == "userdata" then
                    -- Vector or bitfield. Copy element by element rather
                    -- than assigning the object, because assigning would
                    -- alias the donor's storage and a later write to one
                    -- tool would change the other.
                    local ok_len, len = pcall(function() return #dv end)
                    if ok_len then
                        local ok_w = pcall(function()
                            local tv = target[name]
                            tv:resize(len)
                            for i = 0, len - 1 do tv[i] = dv[i] end
                        end)
                        if ok_w then copied = copied + 1 end
                    end
                else
                    local ok_w = pcall(function() target[name] = dv end)
                    if ok_w then copied = copied + 1 end
                end
            end
        end
    end

    local done = string.format("%s <- %s : %d fields copied", target_code, donor_code, copied)
    if to_log then log('DETAIL', done, 'COPY') else print("  " .. done) end
    return copied
end


-- ==========================================
-- DISPATCH
-- ==========================================

if MODE == "probe" then
    if not TARGET or not DONOR then
        print("  usage: refinish-tool-graphics probe <target_code> <donor_code>")
        return
    end
    probe(TARGET, DONOR)

elseif MODE == "copy" then
    if not TARGET or not DONOR then
        print("  usage: refinish-tool-graphics copy <target_code> <donor_code>")
        return
    end
    copy(TARGET, DONOR)

elseif MODE == "copyall" then
    local prefix = TARGET or "MAKING_FUEL_"
    local n = 0
    for key, donor_code in pairs(DONOR_MAP) do
        local target_code = prefix .. key
        if find_tool(target_code) then
            n = n + copy(target_code, donor_code, true)
        end
    end
    -- DETAIL: runs on every injection, inside the module pipeline.
    log('DETAIL', string.format(
        "donor copy applied for %s (%d fields).", prefix, n), 'COPYALL')

else
    print("  modes: probe | copy | copyall")
end