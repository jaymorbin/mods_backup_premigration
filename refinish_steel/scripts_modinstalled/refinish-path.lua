--@ module = true
-- refinish-path.lua
-- Usage: refinish-path "<path>" [max_depth]
-- Example: refinish-path "df.global.world.raws.inorganics.all[0]" 2

local args = {...}
local root_path_str = args[1]
local max_depth = tonumber(args[2]) or 1

if not root_path_str then
    print("ERROR: Missing target path.")
    print("Usage: refinish-path \"<df_path>\" [max_depth]")
    print("Example: refinish-path \"df.global.world.raws.inorganics.all[0]\" 2")
    return
end

-- Safely evaluate the string path into an actual Lua object
local env = _ENV
local f, err = load("return " .. root_path_str, "env", "t", env)
if not f then
    print("Error parsing path: " .. err)
    return
end

local root_obj = f()
if root_obj == nil then
    print("Error: " .. root_path_str .. " evaluates to nil.")
    return
end

local file_name = "refinish_path_map.txt"
local file = io.open(dfhack.getDFPath() .. "/" .. file_name, "w")
file:write("PATH MAP FOR: " .. root_path_str .. "\n")
file:write("MAX DEPTH: " .. tostring(max_depth) .. "\n")
file:write("==================================================\n")

-- Keep track of visited memory addresses to prevent infinite loops from circular pointers
local seen = {}

local function dump_obj(obj, current_path, current_depth)
    if current_depth > max_depth then return end
    
    -- Generate 4 spaces of indentation per depth level
    local indent = string.rep("    ", current_depth - 1)
    
    local ptr_addr = tostring(obj)
    if seen[ptr_addr] then
        file:write(indent .. current_path .. " = [CIRCULAR REFERENCE]\n")
        return
    end
    
    if type(obj) == "userdata" or type(obj) == "table" then
        seen[ptr_addr] = true
    end

    local ok, err = pcall(function()
        for k, v in pairs(obj) do
            -- Format the key properly depending on whether it's an array index or dictionary key
            local key_str = type(k) == "number" and ("[" .. tostring(k) .. "]") or ("." .. tostring(k))
            local next_path = current_path .. key_str
            local v_type = type(v)

            if v_type == "table" or v_type == "userdata" then
                -- Try to forcefully read the string/number value hiding inside wrapped pointers
                local inner_val = nil
                pcall(function() inner_val = v.value end)
                
                if inner_val ~= nil and type(inner_val) ~= "userdata" and type(inner_val) ~= "table" then
                    local val_str = type(inner_val) == "string" and ('"' .. tostring(inner_val) .. '"') or tostring(inner_val)
                    file:write(indent .. next_path .. " = " .. val_str .. "  -- (Pointer)\n")
                else
                    file:write(indent .. next_path .. " = [" .. tostring(v) .. "]\n")
                    dump_obj(v, next_path, current_depth + 1)
                end
            else
                -- It's a primitive (string, number, boolean)
                local val_str = v_type == "string" and ('"' .. tostring(v) .. '"') or tostring(v)
                file:write(indent .. next_path .. " = " .. val_str .. "\n")
            end
        end
    end)

    if not ok then
        file:write(indent .. current_path .. " = [ITERATION ERROR: " .. tostring(err) .. "]\n")
    end
end

dump_obj(root_obj, root_path_str, 1)

file:write("==================================================\n")
file:close()
print("Path map generated successfully! Check " .. file_name .. " in your main DF folder.")