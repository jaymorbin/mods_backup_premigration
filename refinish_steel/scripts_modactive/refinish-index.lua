-- refinish-index.lua
-- Builds core RM's finish materials from the blueprint and appends
-- them to the inorganics array.

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
-- SUBJECT is the correlation slot: the step or thing a line is
-- about. Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'INDEX_MATERIALS'
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

-- STATE MANAGER: Deep RAM Verification
if _G.refinish_ram_loaded == nil or _G.refinish_ram_loaded == false then
    for _, mat in ipairs(df.global.world.raws.inorganics.all) do
        if string.find(mat.id, "REFINISH_STEEL_MAT_") then
            _G.refinish_ram_loaded = true
            break
        end
    end
end

if _G.refinish_ram_loaded then
    log('DETAIL', 'Materials already indexed. Skipping.')
    return
end

-- ==========================================
-- SCRIPT LOGIC: MATERIAL BUILDER
-- ==========================================
if not _G.refinish_blueprint or not _G.refinish_blueprint.materials then
    log('ERROR', 'Blueprint not found in memory, so no finish materials'
        .. ' were built. refinish-scan has to run first.')
    return
end

local raws = df.global.world.raws.inorganics.all

-- 1. Build a high-speed lookup dictionary of all vanilla metals
-- This prevents an O(N^2) lag spike when generating hundreds of materials
local source_metals = {}
for _, mat in ipairs(raws) do
    source_metals[mat.id] = mat
end

local count = 0

-- 2. Build from the Blueprint

-- Build a sorted injection list so mat_index positions are identical
-- every cycle. pairs() gives no order guarantee: without this,
-- items point at wrong materials after a hotsave rebuild.
local sorted_mats = {}
for mat_id, data in pairs(_G.refinish_blueprint.materials) do
    table.insert(sorted_mats, { id = mat_id, data = data })
end
table.sort(sorted_mats, function(a, b) return a.id < b.id end)

for _, entry in ipairs(sorted_mats) do
    local mat_id = entry.id
    local data = entry.data
    -- rest of the existing loop body unchanged
    
    -- 3. Dynamically fetch the correct base metal to clone using our blueprint breadcrumb
    local source_metal = source_metals[data.base_metal_id]
    
    if not source_metal then
        log('ERROR', 'Base metal ' .. tostring(data.base_metal_id)
            .. ' not found, so ' .. mat_id .. ' was not built.',
            tostring(data.base_metal_id))
    else
        -- Create a blank object and deep-copy the base metal's integers into it
        local m = df.inorganic_raw:new()
        m:assign(source_metal) 

        -- 4. The Critical Missing Pointers
        m.id = mat_id
        m.material.id = mat_id

        -- 5. Manually Re-Inject the BitArray Flags (Fixes the forge/anvil issue)
        m.material.flags.IS_METAL = true
        m.material.flags.ITEMS_METAL = true
        m.material.flags.ITEMS_HARD = true
        m.material.flags.ITEMS_BARRED = true
        m.material.flags.ITEMS_SCALED = true
        m.material.flags.ITEMS_WEAPON = true
        m.material.flags.ITEMS_WEAPON_RANGED = true
        m.material.flags.ITEMS_AMMO = true
        m.material.flags.ITEMS_DIGGER = true
        m.material.flags.ITEMS_ARMOR = true
        m.material.flags.ITEMS_ANVIL = true

        -- 6. Overwrite Colors and Names
        m.material.state_name.Solid = data.adj_name
        m.material.state_adj.Solid = data.adj_name
        m.material.state_name.Liquid = "molten " .. data.adj_name
        m.material.state_adj.Liquid = "molten " .. data.adj_name
        m.material.state_name.Gas = "boiling " .. data.adj_name
        m.material.state_adj.Gas = "boiling " .. data.adj_name

        -- Push the Steam Graphics State Colors
        m.material.state_color.Solid = data.color_idx
        m.material.state_color.Liquid = data.color_idx
        m.material.state_color.Gas = data.color_idx

        -- Push the Classic ASCII fallback colors (using color_idx as the basic_id)
        m.material.build_color[0] = data.color_idx 
        m.material.build_color[1] = 0        
        m.material.build_color[2] = 1        
        m.material.basic_color[0] = data.color_idx
        m.material.basic_color[1] = 1

        -- Visual Hints for the Graphics Engine
        m.material.tile_color[0] = data.color_idx 
        m.material.tile_color[1] = 0        
        m.material.tile_color[2] = 1 
        m.material.tile = 219
        m.material.item_symbol = 7

        -- Final Material Value Math
        m.material.material_value = data.mat_value

        -- 7. Dynamically Inject into the absolute end of the raws
        raws:insert(#raws, m)
        count = count + 1
    end
end

log('DETAIL', 'Built and injected ' .. count .. ' custom materials into RAM.')

-- Toggle state manager at the absolute end of the file
_G.refinish_ram_loaded = true