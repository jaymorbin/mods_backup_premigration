-- refinish-item-inspect.lua
-- ==========================================
-- ITEM INSPECTOR (file output)
-- ==========================================
-- Usage: refinish-item-inspect <item_id> [depth]
--
-- Finds an item by its numeric id in the global items
-- list and dumps all fields to a file.
--
-- Output file: <DF directory>/item_inspect_<id>.txt
--
-- Default depth is 3. Use higher for deeper sub-objects.
--
-- Examples:
--   refinish-item-inspect 267
--   refinish-item-inspect 267 6
-- ==========================================

local args = {...}
local target_id = tonumber(args[1])
local max_depth = tonumber(args[2]) or 3

if not target_id then
    print("Usage: refinish-item-inspect <item_id> [depth]")
    print("  item_id: numeric item id (required)")
    print("  depth:   how deep to recurse (default 3)")
    return
end

-- ==========================================
-- Find the item by id
-- ==========================================
local target_item = nil
for _, item in ipairs(df.global.world.items.all) do
    if item.id == target_id then
        target_item = item
        break
    end
end

if not target_item then
    print("Item " .. target_id .. " not found.")
    return
end

-- ==========================================
-- Open output file
-- ==========================================
local filename = "item_inspect_" .. target_id .. ".txt"
local f = io.open(filename, "w")
if not f then
    print("ERROR: Could not open " .. filename .. " for writing.")
    return
end

local function out(line)
    f:write(line .. "\n")
end

out("==========================================")
out("ITEM INSPECTOR: item id " .. target_id)
out("type: " .. tostring(target_item))
out("depth: " .. max_depth)
out("==========================================")

-- ==========================================
-- Fields to skip during recursion
-- ==========================================
local SKIP_FIELDS = {
    list_link = true,
    prev = true,
    next = true,
}

-- ==========================================
-- Circular reference tracking
-- ==========================================
local visited = {}

-- ==========================================
-- Recursive field dumper
-- ==========================================
local function dump_fields(obj, prefix, depth)
    if depth > max_depth then return end
    local indent = string.rep("  ", depth)

    local ptr = tostring(obj)
    if visited[ptr] then
        out(indent .. prefix .. " = [CIRCULAR REF: " .. ptr .. "]")
        return
    end
    visited[ptr] = true

    local fields = {}
    local ok, meta = pcall(function() return obj._fields end)
    if ok and meta then
        for fname, _ in pairs(meta) do
            table.insert(fields, fname)
        end
        table.sort(fields)
    else
        local pok, _ = pcall(function()
            for k, _ in pairs(obj) do
                table.insert(fields, k)
            end
        end)
        if pok then
            table.sort(fields)
        end
    end

    for _, fname in ipairs(fields) do
        if fname:sub(1,1) ~= '_' and not SKIP_FIELDS[fname] then
            local read_ok, val = pcall(function() return obj[fname] end)
            if read_ok then
                local path = prefix .. "." .. fname
                local vtype = type(val)

                if vtype == "number" or vtype == "boolean" or vtype == "string" then
                    out(indent .. path .. " = " .. tostring(val))
                elseif vtype == "nil" then
                    out(indent .. path .. " = nil")
                elseif vtype == "userdata" then
                    local is_vec, vec_len = pcall(function() return #val end)
                    if is_vec and vec_len ~= nil then
                        out(indent .. path .. " [vector size " .. vec_len .. "]")
                        for i = 0, vec_len - 1 do
                            local elem_ok, elem = pcall(function() return val[i] end)
                            if elem_ok then
                                local etype = type(elem)
                                if etype == "number" or etype == "boolean" or etype == "string" then
                                    out(indent .. "  " .. path .. "[" .. i .. "] = " .. tostring(elem))
                                elseif etype == "userdata" then
                                    out(indent .. "  " .. path .. "[" .. i .. "] = " .. tostring(elem))
                                    if depth + 2 <= max_depth then
                                        dump_fields(elem, path .. "[" .. i .. "]", depth + 2)
                                    end
                                end
                            end
                        end
                    else
                        out(indent .. path .. " = " .. tostring(val))
                        if depth + 1 <= max_depth then
                            dump_fields(val, path, depth + 1)
                        end
                    end
                else
                    out(indent .. path .. " = [" .. vtype .. "] " .. tostring(val))
                end
            end
        end
    end
end

-- ==========================================
-- Run the dump
-- ==========================================
dump_fields(target_item, "item", 0)

out("==========================================")
out("END OF ITEM INSPECTION")
out("==========================================")

f:close()
print("Item " .. target_id .. " (" .. tostring(target_item) .. ") dumped to: " .. filename)
print("Depth: " .. max_depth)
