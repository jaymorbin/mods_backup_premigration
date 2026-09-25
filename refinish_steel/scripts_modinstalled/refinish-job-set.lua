-- refinish-job-set.lua
-- ==========================================
-- JOB FIELD EDITOR
-- ==========================================
-- Usage: refinish-job-set <job_id> <field_path> <value>
--
-- Navigates to the specified field on the job and sets
-- it to the given value. The field path uses dots to
-- separate levels, and brackets for array indexes.
--
-- Examples:
--   refinish-job-set 481 item_type 18
--   refinish-job-set 481 mat_type 6
--   refinish-job-set 481 items[0].item.stack_size 4
--   refinish-job-set 481 items[0].item.dimension 600
--   refinish-job-set 481 specflag.whole 1
--   refinish-job-set 481 flags.repeat true
--
-- Values are auto-detected:
--   "true"/"false" → boolean
--   numbers         → number
--   anything else   → string
--
-- Find job ids with: refinish-job-find
-- Inspect fields with: refinish-job-inspect <id> <depth>
-- ==========================================

local args = {...}
local target_id = tonumber(args[1])
local field_path = args[2]
local raw_value = args[3]

if not target_id or not field_path or not raw_value then
    print("Usage: refinish-job-set <job_id> <field_path> <value>")
    print("")
    print("Examples:")
    print("  refinish-job-set 481 item_type 18")
    print("  refinish-job-set 481 items[0].item.stack_size 4")
    print("  refinish-job-set 481 items[0].item.dimension 600")
    print("  refinish-job-set 481 flags.repeat true")
    return
end

-- ==========================================
-- Find the job in the global job list
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
-- Parse the field path into segments
-- ==========================================
-- Splits "items[0].item.dimension" into:
--   {"items", 0, "item", "dimension"}
-- Each segment is either a string (field name)
-- or a number (array index).
-- ==========================================
local segments = {}
for part in field_path:gmatch("[^%.]+") do
    -- Check if this part has a bracket index like "items[0]"
    local name, idx = part:match("^(%a[%w_]*)%[(%d+)%]$")
    if name and idx then
        table.insert(segments, name)
        table.insert(segments, tonumber(idx))
    else
        -- Could be a plain field name or a bare number index
        local num = tonumber(part)
        if num then
            table.insert(segments, num)
        else
            table.insert(segments, part)
        end
    end
end

if #segments == 0 then
    print("ERROR: Could not parse field path: " .. field_path)
    return
end

-- ==========================================
-- Navigate to the parent object and final field
-- ==========================================
-- Walk all segments except the last one to reach
-- the parent. The last segment is the field to set.
-- ==========================================
local current = target_job
local nav_path = "job"

for i = 1, #segments - 1 do
    local seg = segments[i]
    nav_path = nav_path .. (type(seg) == "number" and ("[" .. seg .. "]") or ("." .. seg))

    local ok, next_obj = pcall(function() return current[seg] end)
    if not ok or next_obj == nil then
        print("ERROR: Could not navigate to " .. nav_path)
        print("  Failed at segment: " .. tostring(seg))
        return
    end
    current = next_obj
end

local final_field = segments[#segments]
local full_path = nav_path .. (type(final_field) == "number" and ("[" .. final_field .. "]") or ("." .. final_field))

-- ==========================================
-- Read the current value
-- ==========================================
local read_ok, old_value = pcall(function() return current[final_field] end)
if not read_ok then
    print("ERROR: Could not read " .. full_path)
    return
end

-- ==========================================
-- Parse and set the new value
-- ==========================================
-- Auto-detect type from the current value and the
-- provided string. Booleans, numbers, and strings
-- are supported.
-- ==========================================
local new_value
if raw_value == "true" then
    new_value = true
elseif raw_value == "false" then
    new_value = false
elseif tonumber(raw_value) then
    new_value = tonumber(raw_value)
else
    new_value = raw_value
end

local set_ok, set_err = pcall(function() current[final_field] = new_value end)
if not set_ok then
    print("ERROR: Could not set " .. full_path)
    print("  " .. tostring(set_err))
    return
end

-- ==========================================
-- Verify the write
-- ==========================================
local verify_ok, verify_val = pcall(function() return current[final_field] end)
local verify_str = verify_ok and tostring(verify_val) or "???"

print("SET " .. full_path)
print("  was: " .. tostring(old_value))
print("  now: " .. verify_str)
