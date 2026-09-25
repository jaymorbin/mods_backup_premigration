-- refinish-find.lua
-- ==========================================
-- QUICK INDEX LOOKUP FOR INORGANICS & REACTIONS
-- ==========================================
-- Searches the live inorganic and reaction arrays for entries
-- whose ID or name contains the given search string. Returns
-- the index you need to feed into refinish-path-mapper.
--
-- USAGE (from DFHack console):
--   refinish-find marble
--   refinish-find "green glass"
--   refinish-find potash
--
-- The search is case-insensitive and matches against both
-- the ID field and the display name. Partial matches work:
--   "ite" will find MAGNETITE, HEMATITE, GRANITE, etc.
-- ==========================================

local args = {...}
local search = args[1]

if not search or search == "" then
    print("Usage: refinish-find <search_string>")
    print("Example: refinish-find marble")
    return
end

-- Normalize to uppercase for ID matching, lowercase for name matching
local search_upper = string.upper(search)
local search_lower = string.lower(search)

-- ==========================================
-- INORGANIC SEARCH
-- ==========================================
local inorganics = df.global.world.raws.inorganics.all
local inorg_hits = {}

for i, mat in ipairs(inorganics) do
    local id = mat.id or ""
    -- The solid-state display name (what the player sees)
    local name = mat.material.state_name.Solid or ""

    if string.find(string.upper(id), search_upper, 1, true)
    or string.find(string.lower(name), search_lower, 1, true) then
        table.insert(inorg_hits, {
            index = i,
            id    = id,
            name  = name,
        })
    end
end

-- ==========================================
-- REACTION SEARCH
-- ==========================================
local reactions = df.global.world.raws.reactions.reactions
local rxn_hits = {}

for i, rxn in ipairs(reactions) do
    local code = rxn.code or ""
    local name = rxn.name or ""

    if string.find(string.upper(code), search_upper, 1, true)
    or string.find(string.lower(name), search_lower, 1, true) then
        table.insert(rxn_hits, {
            index = i,
            code  = code,
            name  = name,
        })
    end
end

-- ==========================================
-- OUTPUT
-- ==========================================
print("==================================================")
print(string.format("SEARCH: \"%s\"", search))
print("==================================================")

if #inorg_hits > 0 then
    print(string.format("\n--- INORGANICS (%d hits) ---", #inorg_hits))
    for _, hit in ipairs(inorg_hits) do
        print(string.format("  [%d]  %-30s  \"%s\"", hit.index, hit.id, hit.name))
    end
else
    print("\n--- INORGANICS: No matches ---")
end

if #rxn_hits > 0 then
    print(string.format("\n--- REACTIONS (%d hits) ---", #rxn_hits))
    for _, hit in ipairs(rxn_hits) do
        print(string.format("  [%d]  %-40s  \"%s\"", hit.index, hit.code, hit.name))
    end
else
    print("\n--- REACTIONS: No matches ---")
end

print("\n==================================================")
print(string.format("Total: %d inorganics, %d reactions", #inorg_hits, #rxn_hits))
print("==================================================")