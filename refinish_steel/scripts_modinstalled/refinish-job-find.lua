-- refinish-job-find.lua
-- ==========================================
-- JOB FINDER
-- ==========================================
-- Lists all active jobs in the global job list with
-- key identifying information so you can pick the one
-- you want to inspect or path-map.
--
-- Usage:
--   refinish-job-find              (list all active jobs)
--   refinish-job-find CollectSand  (filter by job type name)
--   refinish-job-find sand         (partial match, case-insensitive)
--
-- Output columns:
--   ID        - the job's numeric id
--   TYPE      - numeric job_type + enum name
--   BUILDING  - building_id from the holder ref (if any)
--   WORKER    - unit_id from the worker ref (if any)
--   ITEMS     - count of attached item refs
--   JOB_ITEMS - count of job_item requirement entries
--   TIMER     - completion_timer (-1 = not started)
--   STATUS    - flags summary (working, fetching, etc.)
--
-- Once you find the job you want, inspect it with:
--   refinish-job-inspect <job_id> [depth]
-- ==========================================

local args = {...}
local filter = args[1] and args[1]:lower() or nil

print("==========================================")
print("ACTIVE JOBS" .. (filter and (" matching '" .. args[1] .. "'") or ""))
print("==========================================")

local count = 0
local shown = 0
local link = df.global.world.jobs.list.next

while link do
    local j = link.item
    count = count + 1

    -- Resolve the job type name
    local type_name = df.job_type[j.job_type] or "???"

    -- Apply filter if provided (case-insensitive partial match)
    local dominated = true
    if filter then
        if not type_name:lower():find(filter, 1, true) then
            dominated = false
        end
    end

    if dominated then
        shown = shown + 1

        -- Find building holder ref (if any)
        local building_id = "-"
        local worker_id = "-"
        for i = 0, #j.general_refs - 1 do
            local ref = j.general_refs[i]
            local ref_type = tostring(ref)
            if ref_type:find("building_holder") then
                local ok, bid = pcall(function() return ref.building_id end)
                if ok then building_id = tostring(bid) end
            elseif ref_type:find("unit_worker") then
                local ok, uid = pcall(function() return ref.unit_id end)
                if ok then worker_id = tostring(uid) end
            end
        end

        -- Build a flags summary showing which are active
        local flags_parts = {}
        if j.flags.working then table.insert(flags_parts, "WORKING") end
        if j.flags.fetching then table.insert(flags_parts, "FETCHING") end
        if j.flags.bringing then table.insert(flags_parts, "BRINGING") end
        if j.flags.suspend then table.insert(flags_parts, "SUSPEND") end
        if j.flags['repeat'] then table.insert(flags_parts, "REPEAT") end
        if j.flags.special then table.insert(flags_parts, "SPECIAL") end
        if j.flags.do_now then table.insert(flags_parts, "DO_NOW") end
        if j.flags.item_lost then table.insert(flags_parts, "ITEM_LOST") end
        local flags_str = #flags_parts > 0 and table.concat(flags_parts, ",") or "-"

        -- Item summary: list the type of each attached item
        local item_parts = {}
        for i = 0, #j.items - 1 do
            local ok, item_str = pcall(function()
                return tostring(j.items[i].item):match("^<(%S+):")
            end)
            if ok and item_str then
                table.insert(item_parts, item_str)
            end
        end
        local items_str = #item_parts > 0 and table.concat(item_parts, ", ") or "-"

        -- Print the job summary
        print(string.format(
            "  ID:%-6d  TYPE:%d (%s)  BLDG:%s  WORKER:%s  TIMER:%d",
            j.id, j.job_type, type_name, building_id, worker_id, j.completion_timer
        ))
        print(string.format(
            "             ITEMS:%d [%s]  JOB_ITEMS:%d  FLAGS:%s",
            #j.items, items_str, #j.job_items.elements, flags_str
        ))

        -- If reaction-based, show the reaction name
        if j.reaction_name ~= "" then
            print("             REACTION: " .. j.reaction_name)
        end

        print("")
    end

    link = link.next
end

print("==========================================")
print(shown .. " jobs shown" .. (count ~= shown and (" (of " .. count .. " total)") or ""))
print("==========================================")
