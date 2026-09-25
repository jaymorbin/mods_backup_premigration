-- refinish-tool-wash.lua
-- ==========================================
-- TOOL SUBTYPE WASH AND RESTORE
-- ==========================================
-- WHAT THIS IS FOR
--
-- item_toolst.subtype holds a pointer to the itemdef, not an index.
-- Confirmed empirically: .subtype reads as userdata with its own .id
-- and .subtype fields.
--
-- clear_tools() unlinks the itemdef from the array but does not call
-- :delete() on it, so within a session the pointer stays valid and
-- nothing crashes. The exposure is at save and load. DF serialises the
-- itemdef's own subtype number, and on reload that number is resolved
-- against an array built from raws alone. An injected tool sat above
-- the vanilla count, so its number is out of range on the way back in.
--
-- WHETHER YOU NEED THIS
--
-- Unknown until tested. Make one container, quicksave, reload, look at
-- the item. If it survives, DF is defaulting gracefully and this file
-- is dead weight. If it does not, this is the fix.
--
-- Written to cost nothing when unnecessary. wash() checks the itemdef
-- array first and returns before touching world.items.all if no owned
-- tool is present. On a fort with no containers that is one loop over
-- 321 itemdefs and out, not a walk of every item in the fortress.
--
-- CALL ORDER
--
--   save     wash(prefix)   BEFORE clear_tools(prefix)
--   load     restore()      AFTER inject_tools has run
--
-- The ordering is the same rule materials follow and for the same
-- reason: wash while the injected itemdefs are still addressable,
-- restore once they are addressable again.
-- ==========================================

local json = require('json')


-- ==========================================
-- CONFIGURATION
-- ==========================================

-- Site data key. Sits alongside REFINISH_STEEL_PAYLOAD and
-- REFINISH_STEEL_TOOL_LEDGER.
local PAYLOAD_KEY = "REFINISH_STEEL_TOOL_WASH"

-- What washed items are repointed to while the injected tool is gone.
--
-- A jug rather than the first itemdef in the array, deliberately. If a
-- restore ever fails, the player is left holding a liquid container
-- instead of a scroll or a minecart, so the item still does roughly its
-- job and the failure degrades rather than becoming nonsense.
local FALLBACK_CODE = "ITEM_TOOL_JUG"


-- ==========================================
-- HELPERS
-- ==========================================

local function has_prefix(str, prefix)
    return string.sub(str, 1, #prefix) == prefix
end

-- ---- LOG IDENTITY, DECLARED HERE ----
-- RM's own, and peripheral rather than pipeline. One subsystem: every
-- call site here was already TOOL_WASH.
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'TOOL_WASH'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body. The
-- panel filters on TYPE and nothing else, so each call site states
-- its own:
--   DETAIL   debugging material, shown in Debug only
--   INFO     what a player might check during play, Normal and up
--   faults, and the few confirmations a player wants at a glance
--   (COMPLETE, SYSTEM, ONLINE and the like), show in Quiet as well
-- TYPE comes first so no call site can drop it unnoticed: a nil TYPE
-- still renders, as UNTYPED, which shows at every Log Detail level
-- instead of being guessed at.
--
-- SUBJECT is the correlation slot: WASH or RESTORE, the half of the
-- cycle a line comes from.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- This replaces a log() that took the subsystem as an argument and
-- let refinish-log guess TYPE from the words (read_type) unless a call
-- site said otherwise.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
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
-- OWNED ITEMDEF SET
-- ==========================================
-- Builds pointer identity to code for every owned tool.
--
-- Keyed on the itemdef's id string rather than on the wrapper object,
-- because DFHack returns a fresh Lua wrapper on every access and object
-- comparison fails. Same rule the entity dedup follows.
--
-- Returns the lookup and a count. A count of zero is the early-out
-- signal: nothing owned means nothing to wash.
-- ==========================================

local function owned_itemdefs(prefix)
    local defs = df.global.world.raws.itemdefs.tools
    local owned = {}
    local n = 0

    for _, td in ipairs(defs) do
        local ok, id = pcall(function() return td.id end)
        if ok and type(id) == "string" and has_prefix(id, prefix) then
            owned[id] = true
            n = n + 1
        end
    end

    return owned, n
end


-- ==========================================
-- FIND AN ITEMDEF BY CODE
-- ==========================================
-- Returns the itemdef object and its array position, or nil.
-- ==========================================

local function find_itemdef(code)
    local defs = df.global.world.raws.itemdefs.tools
    for i, td in ipairs(defs) do
        local ok, id = pcall(function() return td.id end)
        if ok and id == code then
            return td, i
        end
    end
    return nil, nil
end


-- ==========================================
-- READ AN ITEM'S TOOL CODE
-- ==========================================
-- Goes through the pointer to the id string, because the string is the
-- only stable identity. The numeric subtype is exactly the thing that
-- is about to stop meaning anything.
-- ==========================================

local function item_tool_code(item)
    local ok, raw = pcall(function() return item.subtype end)
    if not ok or raw == nil or type(raw) == "number" then return nil end

    local ok2, id = pcall(function() return raw.id end)
    if ok2 and type(id) == "string" then return id end
    return nil
end


-- ==========================================
-- WASH
-- ==========================================
-- Repoints every item carrying an owned tool onto the fallback itemdef,
-- recording what it was so restore() can put it back.
--
-- MUST run before clear_tools(prefix).
--
-- Returns the number of items washed.
-- ==========================================
function wash(prefix)
    -- ---- EARLY OUT ----
    -- The whole latency question lives here. If no owned tool is in the
    -- array there is nothing any item could be pointing at, so the item
    -- walk is skipped entirely. One pass over the itemdef array, which
    -- is a few hundred entries, against a pass over every item in the
    -- fortress, which is tens of thousands.
    local owned, owned_count = owned_itemdefs(prefix)
    if owned_count == 0 then
        return 0
    end

    local fallback, fallback_pos = find_itemdef(FALLBACK_CODE)
    if not fallback then
        -- Refusing is correct. Washing onto nothing would be worse than
        -- not washing: the item would be left in a state no restore
        -- could interpret.
        -- ERROR: owned tools are cleared anyway, and a save written now
        -- carries their subtype numbers, which are out of range on the
        -- next load (see WHAT THIS IS FOR above).
        log('ERROR', string.format(
            "fallback '%s' not found. Wash skipped, tools NOT safe to clear.",
            FALLBACK_CODE), 'WASH')
        return 0
    end

    local records = {}
    local count = 0

    for _, item in ipairs(df.global.world.items.all) do
        local code = item_tool_code(item)
        if code and owned[code] then
            -- Record before repointing. item.id is stable across the
            -- save cycle, which is what makes restore possible.
            local ok_id, item_id = pcall(function() return item.id end)
            if ok_id then
                table.insert(records, { id = item_id, code = code })

                -- Assign the itemdef object, not a number. The field is
                -- a pointer, so a number here would either throw or
                -- write something meaningless.
                pcall(function() item.subtype = fallback end)
                count = count + 1
            end
        end
    end

    if count > 0 then
        dfhack.persistent.saveSiteData(PAYLOAD_KEY, json.encode({
            site_id = df.global.plotinfo.site_id,
            items   = records,
        }))
        -- DETAIL: runs on every save cycle, and the cycle reports it.
        log('DETAIL', string.format(
            "%d items washed to %s and recorded.", count, FALLBACK_CODE), 'WASH')
    end

    return count
end


-- ==========================================
-- RESTORE
-- ==========================================
-- Puts every washed item back onto the tool it came from.
--
-- MUST run after inject_tools, because the itemdef has to be back in
-- the array before anything can point at it.
--
-- Returns restored, skipped.
-- ==========================================
function restore()
    local raw = dfhack.persistent.getSiteData(PAYLOAD_KEY)
    if not raw or raw == "" then
        return 0, 0
    end

    local ok, payload = pcall(json.decode, raw)
    if not ok or type(payload) ~= 'table' or type(payload.items) ~= 'table' then
        -- ERROR: every washed item stays a jug, which the player will
        -- notice.
        log('ERROR', "payload could not be decoded. Restore skipped.", 'RESTORE')
        return 0, 0
    end

    -- Same anti-ghosting gate the material payload and the ledger both
    -- use. A payload from another fortress describes other items.
    local current_site = df.global.plotinfo.site_id
    if payload.site_id and payload.site_id ~= current_site then
        log('INFO', string.format(
            "discarded payload from a different Site ID (%s). Restore skipped.",
            tostring(payload.site_id)), 'RESTORE')
        return 0, 0
    end

    if #payload.items == 0 then
        return 0, 0
    end

    -- ---- ITEM LOOKUP DICTIONARY ----
    -- Built once. df.item.find() inside the loop would be O(N times M)
    -- across every item in the fortress for every record, which is the
    -- same mistake the material restore already had to fix.
    local by_item_id = {}
    for _, item in ipairs(df.global.world.items.all) do
        local ok_id, id = pcall(function() return item.id end)
        if ok_id then by_item_id[id] = item end
    end

    -- ---- ITEMDEF LOOKUP ----
    -- Also built once, for the same reason.
    local by_code = {}
    for _, td in ipairs(df.global.world.raws.itemdefs.tools) do
        local ok_c, id = pcall(function() return td.id end)
        if ok_c and type(id) == "string" then by_code[id] = td end
    end

    local restored, skipped = 0, 0

    for _, rec in ipairs(payload.items) do
        local item = by_item_id[rec.id]
        local def  = by_code[rec.code]

        if item and def then
            local ok_w = pcall(function() item.subtype = def end)
            if ok_w then
                restored = restored + 1
            else
                skipped = skipped + 1
            end
        else
            -- Item destroyed since the save, or the module that owned
            -- the tool was uninstalled. Either way the item keeps the
            -- fallback, which is a working container rather than a
            -- broken reference. No sentinel is written, matching the
            -- material restore.
            skipped = skipped + 1
        end
    end

    -- Payload consumed. Leaving it would re-apply stale records on the
    -- next load against items that have since changed.
    dfhack.persistent.saveSiteData(PAYLOAD_KEY, "")

    -- DETAIL as a rule. WARNING when items were skipped: they keep the
    -- jug, the expected result of removing the module that owned their
    -- tool, as the ledger treats materials that are no longer present.
    log(skipped > 0 and 'WARNING' or 'DETAIL', string.format(
        "%d items restored, %d skipped.", restored, skipped), 'RESTORE')

    return restored, skipped
end


-- ==========================================
-- IS ANYTHING OUTSTANDING
-- ==========================================
-- True when a wash payload is sitting unconsumed, which means a restore
-- was expected and did not happen. Worth surfacing in the status panel:
-- it is the shape of bug that stays silent until a player notices their
-- containers turned into jugs.
-- ==========================================
function has_pending_payload()
    local raw = dfhack.persistent.getSiteData(PAYLOAD_KEY)
    return raw ~= nil and raw ~= ""
end


return _ENV