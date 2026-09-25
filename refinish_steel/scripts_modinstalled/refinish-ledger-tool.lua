-- refinish-ledger-tool.lua
-- ==========================================
-- TOOL SUBTYPE LEDGER
-- ==========================================
-- THE PROBLEM
--
-- The same problem refinish-ledger.lua solves for materials, in a
-- second array. A tool item stores its subtype, which is a position
-- in world.raws.itemdefs.tools. It does not store the tool's name.
-- A subtype is only meaningful against the exact array that produced
-- it.
--
-- The array is rebuilt every load, in two bands:
--
--   [0 .. V-1]    vanilla, read from the save's raw folder
--   [V .. ]       injected tools, appended at module injection
--
-- Vanilla never moves. The injected band shifts whenever a module is
-- installed, removed, or updated with a different tool count.
--
-- HOW THIS DIFFERS FROM THE MATERIAL LEDGER
--
-- Smaller surface. Only items of type TOOL carry a subtype into this
-- array. Buildings hold placed tools by item reference rather than by
-- subtype, and constructions never involve tools at all, so neither
-- pass from the material ledger has an equivalent here. Items are the
-- single point of truth.
--
-- Larger uncertainty. A material index on an item is a plain number.
-- A tool subtype may be a pointer to the itemdef rather than an index,
-- in which case clearing tools before a save leaves every affected
-- item dangling, and the save protocol has to wash items onto a
-- vanilla subtype the way refinish-save washes materials to a vanilla
-- index. read_subtype and write_subtype below handle both shapes and
-- log which one is live, so the first run answers the question.
--
-- CALL ORDER (refinish-startup), mirroring the material ledger
--
--   Step 2    tool injection, subtypes become final
--   Step 6.5  remap()   must run BEFORE refinish-load
--   Step 7    refinish-load, payload restore
--   Step 8    write()   snapshot for the next session
-- ==========================================

local json = require('json')


-- ==========================================
-- CONFIGURATION
-- ==========================================

-- Site data key. Sits alongside REFINISH_STEEL_LEDGER.
local LEDGER_KEY = "REFINISH_STEEL_TOOL_LEDGER"

-- Core RM tool id prefix, matching the material ledger's CORE_PREFIX.
-- Module prefixes come from the live registry at runtime.
local CORE_PREFIX = "REFINISH_STEEL_"


-- ==========================================
-- HELPERS
-- ==========================================
-- Deliberately identical to refinish-ledger.lua:76-101. Kept local
-- rather than shared so the two ledgers can diverge without one
-- breaking the other.
-- ==========================================

local function has_prefix(str, prefix)
    return string.sub(str, 1, #prefix) == prefix
end

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
-- SUBJECT is the correlation slot: WRITE or REMAP, the half of the
-- ledger a line comes from, or SHAPE for the one-time layout report.
--
-- Typed the same way as refinish-ledger.lua: a failure that leaves
-- items unmoved is an ERROR, and items left behind because a module
-- was removed are a WARNING.
--
-- This replaces a log() that wrote bare untagged lines under the TOOL
-- LEDGER prefix.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'TOOL_LEDGER'
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

local function owned_prefixes()
    local list = { CORE_PREFIX }
    for prefix, _ in pairs(_G.refinish_module_registry or {}) do
        table.insert(list, prefix)
    end
    return list
end

local function is_owned(tool_id, prefixes)
    for _, p in ipairs(prefixes) do
        if has_prefix(tool_id, p) then return true end
    end
    return false
end


-- ==========================================
-- SUBTYPE ACCESS
-- ==========================================
-- item_toolst.subtype is either a number or a pointer to the itemdef,
-- and which one decides how much save protocol work tool injection
-- needs. Rather than assume, both are handled and the shape is logged
-- once per session.
--
-- Reading goes through getSubtype() where possible, because that is a
-- DFHack method that returns a number regardless of how the field is
-- stored underneath.
-- ==========================================

-- Set on first read so the log line appears once rather than per item.
local shape_reported = false

local function report_shape(shape)
    if shape_reported then return end
    shape_reported = true
    log('DETAIL', string.format(
        "item_toolst.subtype is stored as %s.", shape), 'SHAPE')
end

local function read_subtype(item)
    -- Preferred: the accessor, which normalises to a number.
    local ok, sub = pcall(function() return item:getSubtype() end)
    if ok and type(sub) == 'number' and sub >= 0 then
        return sub
    end

    -- Fallback: the raw field, which may be a number or a wrapper.
    local ok2, raw = pcall(function() return item.subtype end)
    if not ok2 or raw == nil then return nil end

    if type(raw) == 'number' then
        report_shape("a plain index")
        return raw >= 0 and raw or nil
    end

    -- Pointer. Its own subtype field is the position.
    local ok3, inner = pcall(function() return raw.subtype end)
    if ok3 and type(inner) == 'number' and inner >= 0 then
        report_shape("a pointer to the itemdef")
        return inner
    end

    return nil
end

-- Writing has to match the storage shape. When the field is a pointer,
-- the new value is the itemdef object at the target position, not the
-- number. Assigning a number into a pointer field would either throw
-- or write garbage, so it is attempted only after the field type is
-- known.
local function write_subtype(item, new_idx, defs)
    local ok, raw = pcall(function() return item.subtype end)
    if not ok then return false end

    if type(raw) == 'number' then
        local ok2 = pcall(function() item.subtype = new_idx end)
        return ok2
    end

    -- Pointer shape: hand it the itemdef that now sits at new_idx.
    local ok3 = pcall(function() item.subtype = defs[new_idx] end)
    return ok3
end


-- ==========================================
-- WRITE
-- ==========================================
-- Snapshots id -> current subtype for every injected tool.
--
-- Safe any time after injection, since nothing later in the pipeline
-- moves a tool.
--
-- Returns the number of tools recorded.
-- ==========================================
function write()
    local prefixes = owned_prefixes()
    local tools = {}
    local n = 0

    for i, td in ipairs(df.global.world.raws.itemdefs.tools) do
        local ok, id = pcall(function() return td.id end)
        if ok and type(id) == 'string' and is_owned(id, prefixes) then
            tools[id] = i
            n = n + 1
        end
    end

    -- Same refusal as the material ledger (refinish-ledger.lua:129).
    -- If injection failed this session, last session's record is the
    -- only thing that can still recover these items.
    if n == 0 then
        log('DETAIL', "No injected tools found. Existing ledger left intact.",
            'WRITE')
        return 0
    end

    dfhack.persistent.saveSiteData(LEDGER_KEY, json.encode({
        site_id = df.global.plotinfo.site_id,
        tools   = tools,
    }))

    log('DETAIL', string.format("Recorded %d tool subtypes.", n), 'WRITE')
    return n
end


-- ==========================================
-- REMAP
-- ==========================================
-- Rewrites every tool item whose stored subtype belonged to an
-- injected tool last session.
--
-- Returns moved, skipped.
-- ==========================================
function remap()
    -- ---- READ THE PREVIOUS SESSION'S LEDGER ----
    local raw = dfhack.persistent.getSiteData(LEDGER_KEY)
    if not raw or raw == "" then
        -- Never had a tool ledger on this save. Guessing at what the
        -- stored subtypes used to mean would corrupt items that are
        -- currently fine. write() runs later this session.
        log('DETAIL', "No previous ledger on this save. Remap skipped.", 'REMAP')
        return 0, 0
    end

    local ok, old = pcall(json.decode, raw)
    if not ok or type(old) ~= 'table' or type(old.tools) ~= 'table' then
        log('ERROR', "Ledger could not be decoded. Remap skipped.", 'REMAP')
        return 0, 0
    end

    -- ---- SITE ID GATE ----
    -- Same anti-ghosting rule as refinish-ledger.lua:174.
    local current_site = df.global.plotinfo.site_id
    if old.site_id and old.site_id ~= current_site then
        log('INFO', string.format(
            "Discarded a ledger from another world (site %s). Remap skipped.",
            tostring(old.site_id)), 'REMAP')
        return 0, 0
    end

    -- ---- BUILD BOTH DIRECTIONS ----
    -- Two lookups rather than a precomputed old to new pair map, for
    -- the reason the material ledger gives at line 185: a pair map
    -- breaks the moment two entries swap places. The id is the only
    -- stable identity.
    local defs = df.global.world.raws.itemdefs.tools

    local by_old_idx = {}
    for id, idx in pairs(old.tools) do
        by_old_idx[idx] = id
    end

    local by_id = {}
    for i, td in ipairs(defs) do
        local ok_id, id = pcall(function() return td.id end)
        if ok_id and type(id) == 'string' then
            by_id[id] = i
        end
    end

    local moved, skipped = 0, 0

    -- ---- THE DECISION, MADE ONCE PER ITEM ----
    -- Returns nil to mean "write nothing", covering the same two cases
    -- the material ledger documents at line 202:
    --
    --   not in the ledger    a vanilla tool. Untouched.
    --
    --   tool is gone         the module that provided it was removed.
    --                        No sentinel is written. The item keeps a
    --                        subtype that no longer resolves, which is
    --                        the same outcome the material path
    --                        produces and is handled downstream.
    local function resolve(old_idx)
        local id = by_old_idx[old_idx]
        if not id then return nil end

        local new_idx = by_id[id]
        if not new_idx then
            skipped = skipped + 1
            return nil
        end

        if new_idx ~= old_idx then moved = moved + 1 end
        return new_idx
    end

    -- ---- ITEMS ----
    -- Only TOOL items index this array. Everything else is skipped
    -- before its subtype is ever read, so an armour or weapon subtype
    -- can never be rewritten against the tools ledger by accident.
    local TOOL = df.item_type.TOOL

    for _, item in ipairs(df.global.world.items.all) do
        local ok_t, itype = pcall(function() return item:getType() end)
        if ok_t and itype == TOOL then
            local old_idx = read_subtype(item)
            if old_idx then
                local new_idx = resolve(old_idx)
                if new_idx and new_idx ~= old_idx then
                    write_subtype(item, new_idx, defs)
                end
            end
        end
    end

    -- ---- REPORT ----
    if moved > 0 then
        -- INFO: this only happens when a module was added, removed or
        -- changed, which a player may well want to confirm.
        log('INFO', string.format("Remapped %d items to new tool subtypes.",
            moved), 'REMAP')
    end

    if skipped > 0 then
        -- WARNING: the expected result of removing a module, not a fault
        -- in the remap itself.
        log('WARNING', string.format(
            "%d items left untouched; their tools are no longer present.",
            skipped), 'REMAP')
    end

    if moved == 0 and skipped == 0 then
        log('DETAIL', "No items needed remapping.", 'REMAP')
    end

    return moved, skipped
end


-- ==========================================
-- OWNED ITEM CENSUS
-- ==========================================
-- Counts items currently carrying an injected tool subtype.
--
-- This is what tells the save protocol whether clearing tools is safe.
-- If the count is above zero, those items have to be washed onto a
-- vanilla subtype and recorded in the payload before clear_tools()
-- runs, exactly as refinish-save washes materials.
--
-- Returns count, and a table of tool id -> item count for the log.
-- ==========================================
function census(prefix)
    local defs = df.global.world.raws.itemdefs.tools
    local TOOL = df.item_type.TOOL

    -- Which subtypes are ours, by position.
    local owned = {}
    for i, td in ipairs(defs) do
        local ok, id = pcall(function() return td.id end)
        if ok and type(id) == 'string' and has_prefix(id, prefix) then
            owned[i] = id
        end
    end

    local total = 0
    local by_tool = {}

    for _, item in ipairs(df.global.world.items.all) do
        local ok_t, itype = pcall(function() return item:getType() end)
        if ok_t and itype == TOOL then
            local sub = read_subtype(item)
            local id = sub and owned[sub]
            if id then
                total = total + 1
                by_tool[id] = (by_tool[id] or 0) + 1
            end
        end
    end

    return total, by_tool
end


return _ENV