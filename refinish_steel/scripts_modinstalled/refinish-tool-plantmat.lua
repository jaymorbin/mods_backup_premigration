--@ module = true
-- refinish-tool-plantmat.lua
-- ==========================================
-- PLANT MATERIAL INSPECTOR
-- The inorganic tools cannot see plant-hosted materials, which is
-- where the coal host, the twins, and every WOOD live. This prints
-- a plant's whole material vector: index, id, the 419+mi mat_type,
-- density, and every reaction class BY VALUE, the rc[i].value
-- lesson made into a tool. Usage:
--   refinish-tool-plantmat cedar        (name fragment)
--   refinish-tool-plantmat              (item selected in the UI)
-- ==========================================
local function say(s) print('PLANTMAT: ' .. s) end

local function dump_plant(pi, plant)
    say(('plant %d  [%s]  %s'):format(pi, plant.id,
        plant.name or ''))
    for mi, mat in ipairs(plant.material) do
        local classes = {}
        pcall(function()
            local rc = mat.reaction_class
            for i = 0, #rc - 1 do
                table.insert(classes, rc[i].value)
            end
        end)
        say(('  mi=%-3d mat_type=%-4d id=%-22s density=%-6s classes=[%s]')
            :format(mi, 419 + mi, tostring(mat.id),
                    tostring(mat.solid_density),
                    table.concat(classes, ',')))
    end
end

function scan(frag)
    local ok, err = pcall(function()
        if not frag or frag == '' then
            local it = dfhack.gui.getSelectedItem(true)
            if not it then say('no fragment and no item selected.') return end
            local mi = dfhack.matinfo.decode(it)
            if mi and mi.plant then
                dump_plant(mi.index, mi.plant) return
            end
            say('selected item is not plant-material.') return
        end
        frag = frag:lower()
        local hits = 0
        for pi, plant in ipairs(df.global.world.raws.plants.all) do
            if tostring(plant.id):lower():find(frag, 1, true) then
                dump_plant(pi, plant); hits = hits + 1
            end
        end
        if hits == 0 then say('no plant id contains "' .. frag .. '".') end
    end)
    if not ok then say('errored: ' .. tostring(err)) end
end

if not dfhack_flags or not dfhack_flags.module then
    scan(({...})[1])
end