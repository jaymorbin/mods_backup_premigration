-- making-fuel-tinder-mat.lua
-- =====================================================================
-- FUEL WOOD TWIN PUSH
-- Every tree's WOOD gets a TWIN material appended to its plant: a
-- full clone of the wood, same species names and colors and thermals
-- and density, PLUS the fuel classes. Every module fuel TOOL made of
-- wood is hopped onto this twin after minting, so 'oak tinder' and
-- 'oak kindling' read and burn like oak while real oak never carries
-- FUEL and furniture stays clean. The container doctrine ruling
-- survives by construction.
--
-- THE TWIN IS A MATERIAL, NOT A TOOL. It is a plant material sitting
-- beside WOOD on the same plant. The tools that wear it keep their
-- own itemdefs and their own names; nothing about wearing this
-- material makes one tool into another. The id used to be
-- MAKING_FUEL_TINDER, which collided by name with the TINDER itemdef
-- and read as though kindling had become tinder. It has not, and the
-- id no longer says it does.
--
-- APPEND ONLY, never insert: existing mat_index arithmetic on every
-- plant (bark dye's 419+mi included) depends on positions never
-- shifting. Pop scans by our id, LIFO like everything else, same
-- lifecycle contract as the bark dye push. The species map for the
-- product router lands in _G.making_fuel_fuelwood_twin as
-- plant_index -> { mat_type, mat_index } for the watcher to read.
-- =====================================================================

--@ module = true

local TWIN_ID = 'MAKING_FUEL_FUELWOOD'

-- Ids this push used to write. They exist ONLY so a twin left behind
-- by a session that ran the old name still gets popped. Once no such
-- session can exist, delete the list and the loop that reads it.
local LEGACY_IDS = { 'MAKING_FUEL_TINDER' }

-- FUEL only. Smelting grade heat demands charcoal; wood in this
-- family is fire starting and bulk grade, and the ladder earns
-- FUEL_SMELTING by being charred, never by carrying it raw.
local CLASSES = { 'FUEL', 'FUEL_BULK' }

local function new_string_ptr(s)
    local p = df.new('string'); p.value = s; return p
end

-- ---- LOG IDENTITY, DECLARED HERE ----
-- RM core does not know this module exists and must never have to, so
-- the module states its own system and subsystem. Guarded reqscript: a
-- bare top level one is a hard load time dependency.
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'TINDER_MAT'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed
-- by refinish-log. The identity above is declared by the module, not
-- inferred anywhere: RM core does not know this module exists.
--
-- The panel filters on TYPE and nothing else, so each call site states
-- its own:
--   DETAIL   debugging material, shown in Debug only
--   INFO     what a player might check during play, Normal and up
--   YIELD    the module made something, Normal and up
--   faults, and the few confirmations a player wants at a glance
--   (COMPLETE, SYSTEM, ONLINE and the like), show in Quiet as well
-- TYPE comes first so no call site can drop it unnoticed: a nil TYPE
-- still renders, as UNTYPED, which shows at every Log Detail level
-- instead of being guessed at.
--
-- SUBJECT is the correlation slot: PUSH and POP for the two halves of
-- the lifecycle, TWIN for a single plant.
--
-- This replaces a log() that let refinish-log guess TYPE from the
-- words (read_type), and PRINTED every line to the console at every
-- start and stop.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else.
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

-- True when this material id is one the push owns, current or past.
local function is_ours(id)
    if id == TWIN_ID then return true end
    for _, legacy in ipairs(LEGACY_IDS) do
        if id == legacy then return true end
    end
    return false
end

function start()
    _G.making_fuel_fuelwood_twin = {}
    local made, had = 0, 0
    for pi, plant in ipairs(df.global.world.raws.plants.all) do
        local wood, exists = nil, false
        for _, mat in ipairs(plant.material) do
            if mat.id == 'WOOD' then wood = mat end
            if is_ours(mat.id) then exists = true end
        end
        if wood and exists then
            had = had + 1
        elseif wood then
            local ok, err = pcall(function()
                local twin = df.material:new()
                -- Deep copy: names, colors, all seven thermals,
                -- density, flags, the lot. One call, cannot drift
                -- from the species it mirrors.
                twin:assign(wood)
                twin.id = TWIN_ID
                for _, c in ipairs(CLASSES) do
                    twin.reaction_class:insert('#', new_string_ptr(c))
                end
                plant.material:insert('#', twin)   -- APPEND: '#' is end
                local mi = #plant.material - 1
                _G.making_fuel_fuelwood_twin[pi] =
                    { mat_type = 419 + mi, mat_index = pi }
            end)
            if ok then made = made + 1
            else
                -- ERROR: this tree's tinder and kindling stay on real wood,
                -- which carries no fuel class, so they will not burn.
                log('ERROR', ('fuel wood twin FAILED on plant %d: %s')
                    :format(pi, tostring(err)), 'TWIN')
            end
        end
    end
    if made == 0 and had == 0 then
        log('ERROR', 'Fuel wood twin push wrote NOTHING with trees present. '
            .. 'That is a bug, report it.', 'PUSH')
    else
        log('DETAIL', ('Fuel wood twin push: %d twins made, %d already present.')
            :format(made, had), 'PUSH')
    end
end

function stop()
    local popped = 0
    for _, plant in ipairs(df.global.world.raws.plants.all) do
        for i = #plant.material - 1, 0, -1 do
            if is_ours(plant.material[i].id) then
                local m = plant.material[i]
                plant.material:erase(i)
                df.delete(m)
                popped = popped + 1
            end
        end
    end
    _G.making_fuel_fuelwood_twin = nil
    log('DETAIL', ('Fuel wood twin pop, %d cleared.'):format(popped), 'POP')
end

return _ENV