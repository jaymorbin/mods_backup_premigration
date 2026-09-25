-- refinish-job-inspect.lua
-- ==========================================
-- JOB INSPECTOR (file output)
-- ==========================================
-- Usage: refinish-job-inspect <job_id> [depth]
--
-- Finds a job by its numeric id in the global job list
-- and dumps all fields to a file. Safer than console
-- output for deep inspections - no crash from flooding.
--
-- Output file: <DF directory>/job_inspect_<id>.txt
--
-- Default depth is 3. Use higher for deeper sub-objects.
--
-- Find job ids first:
--   refinish-job-find
--   refinish-job-find sand
--
-- Then inspect:
--   refinish-job-inspect 481
--   refinish-job-inspect 481 6
-- ==========================================

local args = {...}
local target_id = tonumber(args[1])
local max_depth = tonumber(args[2]) or 3

if not target_id then
    print("Usage: refinish-job-inspect <job_id> [depth]")
    print("  job_id: numeric job id (required)")
    print("  depth:  how deep to recurse (default 3)")
    print("")
    print("Find job ids with: refinish-job-find")
    return
end

-- ==========================================
-- Walk the global job linked list to find our target
-- ==========================================
local target_job = nil
local link = df.global.world.jobs.list.next
while link do
    if link.item.id == target_id then
        target_job = link.item
        break
    end
    link = link.next
end

if not target_job then
    print("Job " .. target_id .. " not found in active job list.")
    return
end

-- ==========================================
-- Open output file
-- ==========================================
local filename = "job_inspect_" .. target_id .. ".txt"
local f = io.open(filename, "w")
if not f then
    print("ERROR: Could not open " .. filename .. " for writing.")
    return
end

local function out(line)
    f:write(line .. "\n")
end

local type_name = df.job_type[target_job.job_type] or "???"
out("==========================================")
out("JOB INSPECTOR: job id " .. target_id)
out("job_type: " .. tostring(target_job.job_type) .. " (" .. type_name .. ")")
out("depth: " .. max_depth)
out("==========================================")

-- ==========================================
-- Fields to skip during recursion
-- ==========================================
-- These fields cause infinite loops or massive dumps
-- because they traverse linked lists or circular refs.
-- ==========================================
local SKIP_FIELDS = {
    list_link = true,
    prev = true,
    next = true,
}

-- ==========================================
-- Circular reference tracking
-- ==========================================
-- Keeps track of objects we've already visited so we
-- don't recurse into the same struct twice.
-- ==========================================
local visited = {}

-- ==========================================
-- Recursive field dumper
-- ==========================================
-- Walks every field on a DF object, writing name = value
-- to the output file. Recurses into sub-objects up to
-- max_depth. Skips linked list fields and circular refs.
-- ==========================================
local function dump_fields(obj, prefix, depth)
    if depth > max_depth then return end
    local indent = string.rep("  ", depth)

    -- Mark this object as visited (by pointer string)
    local ptr = tostring(obj)
    if visited[ptr] then
        out(indent .. prefix .. " = [CIRCULAR REF: " .. ptr .. "]")
        return
    end
    visited[ptr] = true

    -- Collect field names from the DF struct
    local fields = {}
    local ok, meta = pcall(function() return obj._fields end)
    if ok and meta then
        for fname, _ in pairs(meta) do
            table.insert(fields, fname)
        end
        table.sort(fields)
    else
        -- Fallback: try pairs
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
        -- Skip internal/meta fields and linked list traversal
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
                    -- Check if it's a vector
                    local is_vec, vec_len = pcall(function() return #val end)
                    if is_vec and vec_len ~= nil then
                        out(indent .. path .. " [vector size " .. vec_len .. "]")
                        -- Show all elements
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
                        -- Sub-object: recurse
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
dump_fields(target_job, "job", 0)

out("==========================================")
out("END OF JOB INSPECTION")
out("==========================================")

f:close()
print("Job " .. target_id .. " (" .. type_name .. ") dumped to: " .. filename)
print("Depth: " .. max_depth .. " | Fields skipped: list_link, prev, next")