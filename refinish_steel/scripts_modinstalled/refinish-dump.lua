--@ module = true
-- refinish-dump.lua
-- ==========================================
-- REFINISH METAL: DIAGNOSTIC DUMP
-- ==========================================
-- Exports a comprehensive diagnostic file for debugging and
-- user support. Designed to be readable: summaries and counts
-- first, full-scale ID listings at the end.
--
-- STRUCTURE:
--   1. SYSTEM          - Versions, world, config, state flags
--   2. TELEMETRY       - Boot, startup, last save timing snapshots
--   3. ASSET SUMMARY   - Counts from all caches and live arrays
--   4. CIVILIZATION    - Tech evaluation from civ_tech cache
--   5. JSON PAYLOAD    - Archived finish data summary
--   6. EVENT LOG       - Recent log entries
--   --- FULL LISTINGS (searchable, at the end) ---
--   A. INORGANIC SWEEP; Every inorganic: accepted/excluded + reason
--   B. BLUEPRINT DUMP  - Every material, reaction, category in blueprint
--   C. PAYLOAD DUMP    - Every item/building/construction in JSON
--
-- FILE NAMING:
--   refinish_dump_YYYYMMDD_HHMMSS.txt
--   (Consistent with trace and log exports via refinish-debug)
-- ==========================================

local json = require('json')
local dialogs = require('gui.dialogs')
local dbg = reqscript('refinish-debug')

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body.
--
-- The panel filters on TYPE and nothing else, so each call site states
-- its own:
--   DETAIL   debugging material, shown in Debug only
--   INFO     what a player might check during play, Normal and up
--   faults, and the few confirmations a player wants at a glance
--   (COMPLETE, SYSTEM, ONLINE and the like), show in Quiet as well
-- TYPE comes first so no call site can drop it unnoticed: a nil TYPE
-- still renders, as UNTYPED, which shows at every Log Detail level
-- instead of being guessed at.
--
-- SUBJECT is the correlation slot: EXPORT for the run, FILE for the
-- file it writes.
--
-- This replaces bare untagged lines under the DIAGNOSTIC DUMP prefix.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else. The dump's outcome also shows in a dialog,
-- since the log panel's dump button is what runs it.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'DIAGNOSTIC_DUMP'
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


-- ==========================================
-- SHARED UTILITIES
-- ==========================================
local function get_sorted_keys(t)
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys)
    return keys
end

local function tcount(t)
    if not t then return 0 end
    local n = 0; for _ in pairs(t) do n = n + 1 end; return n
end

local function safe_translate_name(name_obj)
    if not name_obj then return "" end
    if dfhack.translation and dfhack.translation.translateName then
        return dfhack.translation.translateName(name_obj)
    elseif dfhack.TranslateName then
        return dfhack.TranslateName(name_obj)
    end
    return ""
end

local function get_pref(id, default)
    local state = dfhack.persistent.getSiteData(id)
    return (state and state ~= "") and state or default
end

local function bfmt(val)
    if val == true then return "Yes"
    elseif val == false then return "No"
    else return "-" end
end

-- Consistent section divider
local function section(file, num, title)
    file:write("\n\n")
    file:write("##########################################################\n")
    file:write(string.format("## %s. %s\n", num, title))
    file:write("##########################################################\n\n")
end

local function subsection(file, title)
    file:write(string.format("\n--- %s ---\n", title))
end


-- ==========================================
-- MAIN EXPORT FUNCTION
-- ==========================================
local function export_diagnostic_dump()
    local file_path = dbg.make_filename("dump")
    local file = io.open(file_path, "w")

    if not file then
        -- DETAIL: execute() reports the failure as the ERROR. This is
        -- the path it could not write.
        log('DETAIL', 'Could not create ' .. tostring(file_path) .. '.', 'FILE')
        return false, "Could not create dump file."
    end

    -- ==========================================
    -- HEADER
    -- ==========================================
    file:write("##########################################################\n")
    file:write("##  REFINISH METAL: DIAGNOSTIC DUMP\n")
    file:write(string.format("##  Generated: %s\n", os.date("%Y-%m-%d %H:%M:%S")))
    file:write("##########################################################\n")


    -- ==========================================
    -- 1. SYSTEM
    -- ==========================================
    section(file, "1", "SYSTEM")

    subsection(file, "SOFTWARE")
    file:write(string.format("  %-22s %s\n", "Dwarf Fortress:", dfhack.getDFVersion()))
    file:write(string.format("  %-22s %s\n", "DFHack:", dfhack.getDFHackVersion()))
    file:write(string.format("  %-22s %s\n", "Refinish Metal:", _G.refinish_version or "Unknown"))

    subsection(file, "WORLD")
    local world_name = "Unknown"
    pcall(function()
        if df.global.world and df.global.world.world_data and df.global.world.world_data.name then
            local translated = safe_translate_name(df.global.world.world_data.name)
            if translated and translated ~= "" then world_name = translated end
        end
    end)
    local site_id = "Unknown"
    pcall(function() if df.global.plotinfo.site_id ~= -1 then site_id = tostring(df.global.plotinfo.site_id) end end)
    local civ_str = "Unknown"
    pcall(function()
        local civ = df.historical_entity.find(df.global.plotinfo.civ_id)
        if civ and civ.name and civ.name.has_name then
            local translated = safe_translate_name(civ.name)
            if translated ~= "" then civ_str = translated .. " (ID: " .. tostring(civ.id) .. ")" end
        end
    end)
    file:write(string.format("  %-22s %s\n", "World:", world_name))
    file:write(string.format("  %-22s %s\n", "Site ID:", site_id))
    file:write(string.format("  %-22s %s\n", "Player Civ:", civ_str))

    subsection(file, "CONFIGURATION")
    file:write(string.format("  %-22s %s\n", "Save Protocol:", get_pref('refinish_config_save_protocol', 'AUTOSAVE')))
    file:write(string.format("  %-22s %s\n", "Material Finishes:", get_pref('refinish_config_perf', 'ON')))
    file:write(string.format("  %-22s %s\n", "Protect Bases:", get_pref('refinish_config_protect', 'YES')))
    file:write(string.format("  %-22s %s\n", "Load Delay:", get_pref('refinish_config_delay', 'TICK')))
    file:write(string.format("  %-22s %s\n", "Autosave Interval:", get_pref('refinish_config_interval', 'SEASONAL')))
    file:write(string.format("  %-22s %s\n", "Pause on Autosave:", get_pref('refinish_config_pause', 'YES')))
    file:write(string.format("  %-22s %s\n", "Menu-Bound Data:", get_pref('refinish_config_esc', 'AUTO')))
    file:write(string.format("  %-22s %s\n", "Verbosity:", get_pref('refinish_config_msg', 'GUIDED')))

    subsection(file, "PIPELINE STATE")
    file:write(string.format("  %-22s %s\n", "Active:", bfmt(_G.refinish_active)))
    file:write(string.format("  %-22s %s\n", "Menu Locked:", bfmt(_G.refinish_menu_locked)))
    file:write(string.format("  %-22s %s\n", "Materials Loaded:", bfmt(_G.refinish_ram_loaded)))
    file:write(string.format("  %-22s %s\n", "Reactions Loaded:", bfmt(_G.refinish_reactions_loaded)))
    file:write(string.format("  %-22s %s\n", "Permissions Loaded:", bfmt(_G.refinish_entity_loaded)))
    file:write(string.format("  %-22s %s\n", "Payload Loaded:", bfmt(_G.refinish_data_loaded)))


    -- ==========================================
    -- 2. TELEMETRY
    -- ==========================================
    section(file, "2", "TELEMETRY")

    local tel = _G.refinish_telemetry or {}

    local function tfmt(s) if not s or s == 0 then return "-" end; return string.format("%.3fs", s) end

    subsection(file, "BOOT TIMING")
    local bt = tel.boot or {}
    file:write(string.format("  %-22s %s\n", "Total:", tfmt(bt.t_total)))
    file:write(string.format("  %-22s %s\n", "Modules:", tfmt(bt.t_modules)))
    file:write(string.format("  %-22s %s\n", "Evaluators:", tfmt(bt.t_eval)))
    file:write(string.format("  %-22s %s\n", "Boot Scan:", tfmt(bt.t_boot_scan)))
    file:write(string.format("  %-22s %s\n", "State Check:", tfmt(bt.t_state)))

    subsection(file, "STARTUP TIMING")
    local st = tel.startup or {}
    file:write(string.format("  %-22s %s\n", "Total:", tfmt(st.t_total)))
    file:write(string.format("  %-22s %s\n", "Ghost Sweep:", tfmt(st.t_sweep)))
    file:write(string.format("  %-22s %s\n", "Modules:", tfmt(st.t_modules)))
    file:write(string.format("  %-22s %s\n", "Scan:", tfmt(st.t_scan)))
    file:write(string.format("  %-22s %s\n", "Index Materials:", tfmt(st.t_idx_mat)))
    file:write(string.format("  %-22s %s\n", "Index Reactions:", tfmt(st.t_idx_rxn)))
    file:write(string.format("  %-22s %s\n", "Index Entities:", tfmt(st.t_idx_ent)))
    file:write(string.format("  %-22s %s\n", "Payload Load:", tfmt(st.t_load)))

    subsection(file, "LAST SAVE CYCLE")
    local ls = tel.last_save or {}
    file:write(string.format("  %-22s %s\n", "Protocol:", ls.protocol or "N/A"))
    file:write(string.format("  %-22s %s\n", "Timestamp:", ls.timestamp or "N/A"))
    file:write(string.format("  %-22s %s\n", "Active Time:", tfmt(ls.t_active)))
    file:write(string.format("  %-22s %s\n", "Clear Entities:", tfmt(ls.t_clr_ent)))
    file:write(string.format("  %-22s %s\n", "Clear Reactions:", tfmt(ls.t_clr_rxn)))
    file:write(string.format("  %-22s %s\n", "Clear Materials:", tfmt(ls.t_clr_mat)))
    file:write(string.format("  %-22s %s\n", "Engine Save:", tfmt(ls.t_engine)))
    file:write(string.format("  %-22s %s\n", "Restore:", tfmt(ls.t_restore)))


    -- ==========================================
    -- 3. ASSET SUMMARY
    -- ==========================================
    section(file, "3", "ASSET SUMMARY")

    local c = tel.counts or {}

    subsection(file, "BASELINE (before RM injection)")
    file:write(string.format("  %-22s %d\n", "Total Inorganics:", c.base_inorganics or 0))
    file:write(string.format("  %-22s %d\n", "Total Reactions:", c.base_reactions or 0))
    file:write(string.format("  %-22s %d\n", "Valid Metals:", c.valid_metals or 0))
    file:write(string.format("  %-22s %d\n", "Known Metals:", c.known_metals or 0))
    file:write(string.format("  %-22s %d\n", "Reaction Traits:", c.reaction_traits or 0))
    file:write(string.format("  %-22s %d\n", "Civ Techs:", c.civ_techs or 0))

    subsection(file, "BLUEPRINT (scanner output)")
    file:write(string.format("  %-22s %d\n", "Active Bases:", c.active_bases or 0))
    file:write(string.format("  %-22s %d\n", "Materials:", c.bp_materials or 0))
    file:write(string.format("  %-22s %d\n", "Reactions:", c.bp_reactions or 0))
    file:write(string.format("  %-22s %d\n", "Categories:", c.bp_categories or 0))

    subsection(file, "INJECTED (live in RAM)")
    file:write(string.format("  %-22s %d\n", "Materials:", c.inj_materials or 0))
    file:write(string.format("  %-22s %d\n", "Reactions:", c.inj_reactions or 0))
    file:write(string.format("  %-22s %d\n", "Categories:", c.inj_categories or 0))
    file:write(string.format("  %-22s %d\n", "Permissions:", c.inj_permissions or 0))
    file:write(string.format("  %-22s %d\n", "Civs Permitted:", c.civs_unlocked or 0))

    subsection(file, "LIVE ARRAY TOTALS (after injection)")
    if dfhack.isMapLoaded() then
        file:write(string.format("  %-22s %d\n", "Inorganics:", #df.global.world.raws.inorganics.all))
        file:write(string.format("  %-22s %d\n", "Reactions:", #df.global.world.raws.reactions.reactions))
        file:write(string.format("  %-22s %d\n", "Categories:", #df.global.world.raws.reactions.reaction_categories))
    else
        file:write("  (Map not loaded)\n")
    end


    -- ==========================================
    -- 4. CIVILIZATION TECH
    -- ==========================================
    section(file, "4", "CIVILIZATION TECH")

    -- Read from the boot cache instead of re-evaluating
    local civ_tech = _G.refinish_civ_tech
    if civ_tech then
        local sorted_codes = get_sorted_keys(civ_tech)
        file:write(string.format("Source: _G.refinish_civ_tech (%d unique entity raws)\n\n", #sorted_codes))

        for _, raw_code in ipairs(sorted_codes) do
            local entry = civ_tech[raw_code]
            file:write(string.format("  [%s] (%s)\n", raw_code, entry.race_adj or "Unknown"))
            file:write(string.format("    Capab. -> Smelt: %-5s  Forge: %-5s  Mason: %-5s  Gem: %-5s\n",
                bfmt(entry.has_smelter), bfmt(entry.has_forge),
                bfmt(entry.has_mason), bfmt(entry.has_gem)))
            file:write(string.format("    Tech   -> Metal: %-5s  Stone: %-5s  Gem: %-5s\n",
                bfmt(entry.metal_tech), bfmt(entry.stone_tech), bfmt(entry.gem_tech)))
            local km = tcount(entry.known_metals)
            file:write(string.format("    Known Metals: %d\n", km))
        end
    else
        file:write("  (civ_tech cache is nil; boot may not have completed)\n")
    end


    -- ==========================================
    -- 5. JSON PAYLOAD
    -- ==========================================
    section(file, "5", "JSON PAYLOAD")

    local payload_raw = dfhack.persistent.getSiteData("REFINISH_STEEL_PAYLOAD")
    if not payload_raw or payload_raw == "" then
        file:write("  Status: EMPTY (no archived finishes)\n")
    else
        local ok, data = pcall(json.decode, payload_raw)
        if not ok or not data then
            file:write("  Status: ERROR (payload exists but failed to decode)\n")
        else
            local p_site = data.site_id or "NONE (legacy)"
            local i_count = data.items and #data.items or 0
            local b_count = data.buildings and #data.buildings or 0
            local c_count = data.constructions and #data.constructions or 0

            file:write(string.format("  %-22s %s (current: %s)\n", "Payload Site ID:", tostring(p_site), tostring(df.global.plotinfo.site_id)))
            file:write(string.format("  %-22s %d\n", "Items:", i_count))
            file:write(string.format("  %-22s %d\n", "Buildings:", b_count))
            file:write(string.format("  %-22s %d\n", "Constructions:", c_count))
        end
    end


    -- ==========================================
    -- 6. EVENT LOG (last 100 entries)
    -- ==========================================
    section(file, "6", "EVENT LOG (last 100 entries)")

    if _G.refinish_log and #_G.refinish_log > 0 then
        local limit = math.min(#_G.refinish_log, 100)
        file:write(string.format("  Showing %d of %d total entries (newest first)\n\n", limit, #_G.refinish_log))
        for i = 1, limit do
            file:write("  " .. _G.refinish_log[i] .. "\n")
        end
    else
        file:write("  (Log is empty)\n")
    end


    -- ==========================================
    -- FULL LISTINGS DIVIDER
    -- ==========================================
    file:write("\n\n")
    file:write("##########################################################\n")
    file:write("##  FULL LISTINGS\n")
    file:write("##  Everything below is searchable line-by-line data.\n")
    file:write("##  This section can be hundreds of thousands of lines.\n")
    file:write("##########################################################\n")


    -- ==========================================
    -- A. INORGANIC SWEEP
    -- ==========================================
    section(file, "A", "INORGANIC SWEEP")

    local inorganics = df.global.world.raws.inorganics.all
    local accepted = {}
    local excluded = {}
    local acc_count, exc_count = 0, 0

    for _, mat in ipairs(inorganics) do
        local id = mat.id
        if string.find(id, "REFINISH_STEEL_") then
            excluded["Internal Mod Data"] = excluded["Internal Mod Data"] or {}
            table.insert(excluded["Internal Mod Data"], id)
            exc_count = exc_count + 1
        else
            local mat_flags = mat.material.flags
            local inorg_flags = mat.flags
            local melt_point = mat.material.heat.melting_point
            local reagent_val = mat.material.material_value

            local is_valid_type = mat_flags.IS_STONE or mat_flags.IS_METAL or mat_flags.IS_GEM or inorg_flags.SOIL_ANY or inorg_flags.SOIL_SAND
            local is_stable = (melt_point == 0 or melt_point > 10015)
            local is_valuable = (reagent_val >= 0)

            if not is_valid_type then
                local r = "Not Stone/Metal/Gem/Soil"
                excluded[r] = excluded[r] or {}
                table.insert(excluded[r], id)
                exc_count = exc_count + 1
            elseif not is_stable then
                local r = string.format("Unstable (Melt: %d)", melt_point)
                excluded[r] = excluded[r] or {}
                table.insert(excluded[r], id)
                exc_count = exc_count + 1
            elseif not is_valuable then
                local r = string.format("Invalid Value (%d)", reagent_val)
                excluded[r] = excluded[r] or {}
                table.insert(excluded[r], id)
                exc_count = exc_count + 1
            else
                local cat = "OTHER"
                if mat_flags.IS_GEM then cat = "GEM"
                elseif mat_flags.IS_METAL then cat = "METAL"
                elseif mat_flags.IS_STONE or inorg_flags.SOIL_ANY or inorg_flags.SOIL_SAND then cat = "STONE"
                end

                local powder_name = mat.material.state_name[3] or "?"
                accepted[cat] = accepted[cat] or {}
                table.insert(accepted[cat], string.format("  %-24s %s", id, powder_name))
                acc_count = acc_count + 1
            end
        end
    end

    file:write(string.format("  TOTALS: %d accepted, %d excluded, %d total\n", acc_count, exc_count, acc_count + exc_count))

    file:write("\n  ACCEPTED:\n")
    for _, cat in ipairs(get_sorted_keys(accepted)) do
        file:write(string.format("\n  [%s] (%d)\n", cat, #accepted[cat]))
        for _, entry in ipairs(accepted[cat]) do file:write(entry .. "\n") end
    end

    file:write("\n  EXCLUDED:\n")
    for _, reason in ipairs(get_sorted_keys(excluded)) do
        file:write(string.format("\n  [%s] (%d)\n", reason, #excluded[reason]))
        for _, id in ipairs(excluded[reason]) do file:write("    " .. id .. "\n") end
    end


    -- ==========================================
    -- B. BLUEPRINT DUMP
    -- ==========================================
    section(file, "B", "BLUEPRINT DUMP")

    if _G.refinish_blueprint then
        local bp = _G.refinish_blueprint

        for _, tbl_name in ipairs({"materials", "reactions", "categories", "original_names"}) do
            local tbl = bp[tbl_name]
            local count = tcount(tbl)
            subsection(file, string.upper(tbl_name) .. " (" .. count .. " entries)")

            if count == 0 then
                file:write("  (empty)\n")
            else
                local sorted = get_sorted_keys(tbl)
                for _, k in ipairs(sorted) do
                    local v = tbl[k]
                    if tbl_name == "materials" then
                        file:write(string.format("  %s -> base:%s val:%s adj:%s\n", k, v.base_metal_id or "?", tostring(v.mat_value), v.adj_name or "?"))
                    elseif tbl_name == "reactions" then
                        file:write(string.format("  %s -> %s\n", k, v.name or "?"))
                    elseif tbl_name == "categories" then
                        file:write(string.format("  %s -> parent:%s\n", k, v.parent or ""))
                    elseif tbl_name == "original_names" then
                        file:write(string.format("  %s -> name:%s adj:%s\n", k, v.name or "?", v.adj or "?"))
                    end
                end
            end
        end
    else
        file:write("  (Blueprint is nil; pipeline may not have run)\n")
    end


    -- ==========================================
    -- C. PAYLOAD DUMP
    -- ==========================================
    section(file, "C", "PAYLOAD DUMP")

    if payload_raw and payload_raw ~= "" then
        local ok, data = pcall(json.decode, payload_raw)
        if ok and data then
            local i_count = data.items and #data.items or 0
            local b_count = data.buildings and #data.buildings or 0
            local c_count = data.constructions and #data.constructions or 0

            if i_count > 0 then
                subsection(file, "ITEMS (" .. i_count .. ")")
                for _, item in ipairs(data.items) do
                    file:write(string.format("  ID:%-8d  %s\n", item.id, item.mat or "UNKNOWN"))
                end
            end
            if b_count > 0 then
                subsection(file, "BUILDINGS (" .. b_count .. ")")
                for _, bld in ipairs(data.buildings) do
                    file:write(string.format("  ID:%-8d  %s\n", bld.id, bld.mat or "UNKNOWN"))
                end
            end
            if c_count > 0 then
                subsection(file, "CONSTRUCTIONS (" .. c_count .. ")")
                for _, con in ipairs(data.constructions) do
                    file:write(string.format("  [%d,%d,%d]  %s\n", con.x, con.y, con.z, con.mat or "UNKNOWN"))
                end
            end
            if (i_count + b_count + c_count) == 0 then
                file:write("  (Payload exists but contains 0 entries)\n")
            end
        else
            file:write("  (Failed to decode payload)\n")
        end
    else
        file:write("  (No payload data)\n")
    end


    -- ==========================================
    -- FOOTER
    -- ==========================================
    file:write("\n\n##########################################################\n")
    file:write("##  END OF DUMP\n")
    file:write("##########################################################\n")
    file:close()

    return true, file_path
end


-- ==========================================
-- EXECUTION WRAPPER
-- ==========================================
function execute()
    local THEME = reqscript('refinish-theme').get_current_theme()
    log('DETAIL', 'Export initiated.', 'EXPORT')

    local ok, result = export_diagnostic_dump()
    if ok then
        -- INFO: a player asked for this and will want to know where it
        -- went.
        log('INFO', 'Saved to ' .. tostring(result) .. '.', 'EXPORT')
        dialogs.showMessage("Dump Successful",
            "Diagnostic dump saved to your Dwarf Fortress folder:\n\n" .. result,
            THEME.PRI)
    else
        log('ERROR', 'Dump failed: ' .. tostring(result), 'EXPORT')
        dialogs.showMessage("Dump Failed",
            "Error: " .. tostring(result),
            THEME.RISK_M)
    end
end

if dfhack_flags and dfhack_flags.module then return _ENV end
execute()