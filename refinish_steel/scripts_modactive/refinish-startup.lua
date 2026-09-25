-- refinish-startup.lua
-- ==========================================
-- REFINISH METAL: PIPELINE STARTUP
-- ==========================================
-- Rebuilds the full asset pipeline: sweep -> modules -> scan ->
-- index -> index-reaction -> index-entity -> load (autosave only).
--
-- PROMPT RULES (simple, no flag combinations):
--   No args  = manual invocation (hotkey/console).
--              Show prompts based on msg_setting (DEBUG/GUIDED/PASSIVE).
--   'SILENT' = automatic invocation (boot, autosave, tripwire, config).
--              No prompts ever. Pipeline runs, telemetry is written,
--              caller owns the user-facing output.
--
-- Every step is timed and written to _G.refinish_telemetry.startup
-- regardless of prompt mode. The data is always available for the
-- status panel, log, and debug dump.
-- ==========================================

local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt
local THEME = reqscript('refinish-theme').get_current_theme()
local utils = require('utils')

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
-- SUBJECT is the correlation slot, here the step a line belongs to.
-- Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'STARTUP'
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

-- ---- WHICH LINES POP ----
-- Quiet is for faults and the few confirmations a player wants at a
-- glance, not every subsystem finishing. The pipeline summary is the
-- only line here that can reach it, and only when a player ran this
-- by hand (see summary_type). Every step's own line is DETAIL:
-- debugging material the summary already carries in its timings.

local args = {...}
local silent = (args[1] == 'SILENT')

-- ---- HOW LOUD THE SUMMARY IS ----
-- COMPLETE when a player ran this by hand. DETAIL inside a save
-- cycle, where the cycle's own summary is the one that pops. INFO for
-- the automatic runs (map load, the ESC menu, a panel rebuild), which
-- Normal still shows.
local function summary_type()
    if not silent then return 'COMPLETE' end
    if _G.refinish_autosave_in_progress then return 'DETAIL' end
    return 'INFO'
end

local msg_setting = dfhack.persistent.getSiteData('refinish_config_msg')
if not msg_setting or msg_setting == "" then msg_setting = 'GUIDED' end

-- ==========================================
-- TELEMETRY HELPER
-- ==========================================
-- Writes to _G.refinish_telemetry.startup if the table exists.
-- If it doesn't (e.g. manual console invocation before boot),
-- timing still works locally; just isn't persisted.
-- ==========================================
local function tset(key, value)
    if _G.refinish_telemetry and _G.refinish_telemetry.startup then
        _G.refinish_telemetry.startup[key] = value
    end
end


-- ==========================================
-- PIPELINE EXECUTION
-- ==========================================
-- This is the actual work. Always runs the same way regardless
-- of prompt mode. Returns a table of timing results so the
-- prompt section can read them without touching _G.
-- ==========================================
local function run_pipeline()
    log('DETAIL', 'Pipeline initiated (silent: ' .. tostring(silent) .. ').',
        'PIPELINE')

    local startup_clock = os.clock()
    local t = startup_clock

    -- ==========================================
    -- STEP 1: ORPHANED GHOST SWEEPER
    -- ==========================================
    -- After a save/reload, JIT-compiled ghost grinder reactions
    -- may have stale suffixes on their job names. This sweep
    -- strips them back to the base reaction code so the watcher
    -- can re-resolve them cleanly.
    -- ==========================================
    local orphaned_jobs_fixed = 0
    local ok, err = pcall(function()
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            if job.job_type == df.job_type.CustomReaction then
                local r_name = tostring(job.reaction_name)
                if string.find(r_name, "^REFINISH_STEEL_RXN_LUA_GRIND_") then
                    local base_name = string.match(r_name, "^(REFINISH_STEEL_RXN_LUA_GRIND_[%a]+)")
                    if base_name and r_name ~= base_name then
                        job.reaction_name = base_name
                        orphaned_jobs_fixed = orphaned_jobs_fixed + 1
                    end
                end
            end
        end
    end)
    if not ok then
        log('WARNING', 'Ghost sweep failed: ' .. tostring(err), 'GHOST_SWEEP')
    end

    local t_sweep = os.clock() - t
    tset('t_sweep', t_sweep)
    log('DETAIL', string.format('Ghost sweep complete (%.3fs); %d orphans fixed.',
        t_sweep, orphaned_jobs_fixed), 'GHOST_SWEEP')
    t = os.clock()

    -- ==========================================
    -- STEP 2: MODULE PIPELINE
    -- ==========================================
    dfhack.script_environment('refinish-module-engine').run_module_pipeline()
    local t_modules = os.clock() - t
    tset('t_modules', t_modules)
    log('DETAIL', string.format('Module pipeline complete (%.3fs).', t_modules),
        'MODULE_PIPELINE')
    t = os.clock()

    -- ==========================================
    -- STEP 2.5: BOOT CACHE BUILDER
    -- ==========================================
    -- Evaluators plus the unified boot scan. Builds the _G caches
    -- that later steps consume:
    --
    --   evaluators -> refinish_evaluated_reactions
    --                 refinish_best_metal_template   (Steps 5 and 6)
    --                 refinish_best_dust_template    (Steps 5 and 6)
    --   boot scan  -> refinish_valid_bases, refinish_known_metals_cache
    --                 refinish_reaction_traits
    --                 refinish_civ_tech              (Step 3 and Step 5.5)
    --
    -- ORDER IS LOAD BEARING IN THREE PLACES:
    --
    --   1. AFTER Step 2. The evaluators read
    --      _G.refinish_module_registry to exclude module reactions
    --      from scoring (evaluate-metal-making:195-211,
    --      evaluate-dust-making:164-177). With an empty registry a
    --      module reaction could win, and the cached .reaction is a
    --      live df.reaction pointer that clear_module_assets frees on
    --      the next wash. This ordering is memory safety, not taste.
    --
    --   2. Evaluators BEFORE the scan. Pass 3 Source B2 consumes
    --      refinish_evaluated_reactions (refinish_steel:245-248).
    --
    --   3. BEFORE Step 3. refinish-scan reads refinish_civ_tech at
    --      :395 with a silent "or {}" fallback, and calls
    --      get_valid_bases(true, true) at :107, which would trigger
    --      the scan itself with different allow_divine/allow_mythical
    --      arguments than boot uses. Populating first keeps that
    --      fallback dead.
    --
    -- GUARD LIFETIME: once per loaded world, NOT once per data cycle.
    -- These caches are nil'd only in the teardown block
    -- (refinish_steel:866-873) and never by a wash, so every later
    -- startup invocation skips this. That matters because
    -- refinish-startup runs on every ESC menu exit, every autosave
    -- restore and every config change.
    --
    -- Contrast Step 2 above: guarded by _G.refinish_modules_injected,
    -- which clear_module_assets resets, so modules DO rebuild every
    -- data cycle. Two adjacent blocks, two different lifetimes.
    -- ==========================================
    if not _G.refinish_civ_tech
       or not _G.refinish_best_metal_template
       or not _G.refinish_best_dust_template then

        local eval_metal = reqscript('refinish-evaluate-metal-making')
        local eval_dust  = reqscript('refinish-evaluate-dust-making')

        _G.refinish_evaluated_reactions = eval_metal.get_metal_making_reactions(true)
        _G.refinish_best_metal_template = eval_metal.get_best_metal_template(true)
        _G.refinish_best_dust_template  = eval_dust.get_best_dust_template(true)

        local metal_code = _G.refinish_best_metal_template and _G.refinish_best_metal_template.code or "NONE"
        local dust_code  = _G.refinish_best_dust_template and _G.refinish_best_dust_template.code or "NONE"
        log('DETAIL', string.format('Evaluators complete; Metal: [%s], Dust: [%s].',
            metal_code, dust_code), 'EVALUATORS')

        reqscript('refinish-boot').run_unified_scan()

        -- Cache counts move with the work that produces them. These
        -- were snapshotted at boot (refinish_steel:269-272); once the
        -- boot call site is removed they would read zero there.
        if _G.refinish_telemetry and _G.refinish_telemetry.counts then
            local function tcount(tbl)
                if not tbl then return 0 end
                local n = 0; for _ in pairs(tbl) do n = n + 1 end; return n
            end
            local c = _G.refinish_telemetry.counts
            c.valid_metals    = _G.refinish_valid_bases and #_G.refinish_valid_bases or 0
            c.known_metals    = tcount(_G.refinish_known_metals_cache)
            c.reaction_traits = tcount(_G.refinish_reaction_traits)
            c.civ_techs       = tcount(_G.refinish_civ_tech)
        end

        local t_boot_cache = os.clock() - t
        tset('t_boot_cache', t_boot_cache)
        log('DETAIL', string.format('Boot cache built (%.3fs).', t_boot_cache),
            'BOOT_CACHE')
        t = os.clock()
    end

    -- ==========================================
    -- STEP 3: BLUEPRINT SCAN
    -- ==========================================
    dfhack.run_script('refinish-scan')
    local t_scan = os.clock() - t
    tset('t_scan', t_scan)
    log('DETAIL', string.format('Blueprint scan complete (%.3fs).', t_scan),
        'BLUEPRINT_SCAN')
    t = os.clock()

    -- ==========================================
    -- STEP 4: MATERIAL INJECTION
    -- ==========================================
    dfhack.run_script('refinish-index')
    local t_idx_mat = os.clock() - t
    tset('t_idx_mat', t_idx_mat)
    log('DETAIL', string.format('Material injection complete (%.3fs).', t_idx_mat),
        'MATERIAL_INJECTION')
    t = os.clock()

    -- ==========================================
    -- STEP 5: REACTION INJECTION
    -- ==========================================
    dfhack.run_script('refinish-index-reaction')
    local t_idx_rxn = os.clock() - t
    tset('t_idx_rxn', t_idx_rxn)
    log('DETAIL', string.format('Reaction injection complete (%.3fs).', t_idx_rxn),
        'REACTION_INJECTION')
    t = os.clock()

    -- ==========================================
    -- STEP 5.5: MODULE PERMISSION EVALUATION
    -- ==========================================
    -- Runs AFTER boot (civ_tech exists) and AFTER reaction
    -- injection (module reaction indexes are resolved). Evaluates
    -- each module reaction against each civ's capabilities and
    -- metal knowledge, injecting permissions only where both
    -- gates pass. Also registers product metals as known, so
    -- core RM's index-entity (Step 6) can see module metals
    -- when gating Refinish permissions.
    -- ==========================================
    local t_mod_perms = 0
    if _G.refinish_module_registry and next(_G.refinish_module_registry) then
        local mod_perm_eval = dfhack.script_environment('refinish-module-evaluate-permissions')
        local mod_perms = mod_perm_eval.evaluate_and_inject()
        t_mod_perms = os.clock() - t
        tset('t_mod_perms', t_mod_perms)
        log('DETAIL', string.format(
            'Module permission evaluation complete (%.3fs); %d permissions.',
            t_mod_perms, mod_perms), 'MODULE_PERMISSIONS')
        t = os.clock()
        -- Refresh the metals panel if the HUD is open, so module
        -- product metals appear with correct availability colors.
        if _G.refinish_hud_view then
            local metals_panel = _G.refinish_hud_view.router_left.subviews[2]
            if metals_panel and metals_panel.refresh_list then
                metals_panel:refresh_list()
            end
        end
    end

    -- ==========================================
    -- STEP 6: ENTITY PERMISSION INJECTION
    -- ==========================================
    dfhack.run_script('refinish-index-entity')
    local t_idx_ent = os.clock() - t
    tset('t_idx_ent', t_idx_ent)
    log('DETAIL', string.format('Entity injection complete (%.3fs).', t_idx_ent),
        'ENTITY_INJECTION')
    t = os.clock()

    -- ==========================================
    -- STEP 7: JSON PAYLOAD RESTORE (Autosave only)
    -- ==========================================
    -- In HOTSAVE mode, items already carry their mat_index on the
    -- objects themselves. RAM restoration is sufficient.
    -- ==========================================
    local save_protocol = dfhack.persistent.getSiteData('refinish_config_save_protocol')
    if not save_protocol or save_protocol == "" then save_protocol = 'AUTOSAVE' end

    -- ==========================================
    -- LEGACY MIGRATION GATE
    -- ==========================================
    -- Detects v3.x -> v3.2 upgrade. Forces a one-time load to
    -- rewrite legacy IDs. See full explanation in previous versions.
    -- ==========================================
    local needs_legacy_load = false
    if save_protocol == 'HOTSAVE' then
        local json_peek = require('json')
        local raw_payload = dfhack.persistent.getSiteData("REFINISH_STEEL_PAYLOAD")
        if raw_payload and raw_payload ~= "" then
            local ok, peeked = pcall(json_peek.decode, raw_payload)
            if ok and peeked then
                local sample = nil
                for _, list_name in ipairs({"items", "buildings", "constructions"}) do
                    if peeked[list_name] and #peeked[list_name] > 0 then
                        sample = peeked[list_name][1].mat
                        break
                    end
                end
                if sample then
                    if string.find(sample, "_MAT_SPECIFIC_") then
                        needs_legacy_load = not string.find(sample, "_MAT_SPECIFIC_STEEL_")
                    end
                    -- A colour id carrying the old _MV value suffix
                    -- predates the collapse to one material per
                    -- colour, so its ids no longer exist. Presence of
                    -- _MV is now the legacy tell, which is the exact
                    -- inverse of the test this replaces: absence of
                    -- _MV used to mean legacy and now means current.
                    if string.match(sample, "_MV%d") then
                        needs_legacy_load = true
                    end
                end
            end
        end
    end

    -- ==========================================
    -- STEP 6.5: MATERIAL INDEX REMAP
    -- ==========================================
    -- Indices are final as of Step 4. Before anything reads a
    -- stored index, translate every object through last session's
    -- ledger: stored index -> material name -> current index.
    --
    -- Runs in BOTH protocols, outside the AUTOSAVE gate below.
    -- HOTSAVE writes no payload at all, so this is the only
    -- recovery it has.
    --
    -- Must run BEFORE refinish-load. The payload restore sets
    -- mat_index from names; remapping afterwards would take
    -- freshly correct indices and rewrite them against a stale
    -- ledger.
    -- ==========================================
    local ledger = dfhack.script_environment('refinish-ledger')
    local ok_rm, rm_err = pcall(function() return ledger.remap() end)
    -- ERROR, not WARNING: a failed remap leaves saved objects pointing
    -- at whatever material now sits at their old index.
    if not ok_rm then
        log('ERROR', 'Ledger remap failed: ' .. tostring(rm_err), 'LEDGER')
    end
    local t_remap = os.clock() - t
    tset('t_remap', t_remap)
    t = os.clock()

    local t_load = 0
    if save_protocol == 'AUTOSAVE' or needs_legacy_load then
        if needs_legacy_load then
            log('INFO', 'Legacy v3.x payload detected. Forcing migration.',
                'PAYLOAD_RESTORE')
        end
        dfhack.run_script('refinish-load')
        t_load = os.clock() - t
        tset('t_load', t_load)
        log('DETAIL', string.format('Payload restore complete (%.3fs).', t_load),
            'PAYLOAD_RESTORE')
    end

    -- ==========================================
    -- STEP 8: LEDGER WRITE
    -- ==========================================
    -- Snapshot id -> index for this session's injected materials.
    -- Runs after the restore so the remap above always reads the
    -- previous session's record, never one written this run.
    -- ==========================================
    -- ---- NOT WHEN STARTUP IS THE TAIL OF A SAVE ----
    -- An autosave cycle ends by running this whole script, so step 8
    -- fires with the array freshly rebuilt. The quicksave it just took
    -- holds the PRE rebuild indices, and the shutdown wrote a ledger
    -- describing exactly those. Writing again here replaces that with
    -- the rebuilt layout, the file and the ledger stop agreeing, and
    -- the next cold load remaps every object against a map of an array
    -- that was never saved.
    --
    -- MEASURED in the session log: Step 0 recorded 441, this line then
    -- recorded 442 in the same second. Two different layouts, one
    -- ledger, and the save file matched the one that got thrown away.
    --
    -- On a real load the flag is false and this runs as it always did.
    if _G.refinish_autosave_in_progress then
        log('DETAIL', 'Save cycle in progress; ledger left describing the'
            .. ' save just written.', 'LEDGER')
    else
        local ok_lw, lw_err = pcall(function() return ledger.write() end)
        -- ERROR for the same reason as the remap: the next load has no
        -- correct layout to move objects from.
        if not ok_lw then
            log('ERROR', 'Ledger write failed: ' .. tostring(lw_err), 'LEDGER')
        end
    end

    -- ==========================================
    -- FINALIZE TELEMETRY
    -- ==========================================
    local t_total = os.clock() - startup_clock
    tset('t_total', t_total)

    -- Update all asset counts from the freshly built pipeline
    if _G.refinish_telemetry and _G.refinish_telemetry.counts then
        local c = _G.refinish_telemetry.counts
        local function tcount(tbl) if not tbl then return 0 end; local n = 0; for _ in pairs(tbl) do n = n + 1 end; return n end

        -- Blueprint counts
        if _G.refinish_blueprint then
            c.bp_materials = tcount(_G.refinish_blueprint.materials)
            c.bp_reactions = tcount(_G.refinish_blueprint.reactions)
            c.bp_categories = tcount(_G.refinish_blueprint.categories)
        end

        -- Active base metals from config
        local json = require('json')
        local bases_raw = dfhack.persistent.getSiteData('refinish_config_bases')
        if bases_raw and bases_raw ~= "" then
            local ok, bases = pcall(json.decode, bases_raw)
            if ok and bases then c.active_bases = tcount(bases) end
        end

        -- Injection counts: compare live array sizes to baseline.
        -- Baseline was captured during boot (before any RM injection).
        local live_inorganics = #df.global.world.raws.inorganics.all
        local live_reactions = #df.global.world.raws.reactions.reactions
        c.inj_materials = live_inorganics - (c.base_inorganics or live_inorganics)
        c.inj_reactions = live_reactions - (c.base_reactions or live_reactions)

        -- Category count: walk the live array (small, fast)
        local cat_count = 0
        for _, cat in ipairs(df.global.world.raws.reactions.reaction_categories) do
            if string.find(cat.id, "REFINISH_STEEL_CAT_") then cat_count = cat_count + 1 end
        end
        c.inj_categories = cat_count

        -- Permission count: walk the player civ's permitted reactions
        -- to count RM entries. Also count total civs that received perms.
        local perm_count = 0
        local civs_unlocked = 0
        local rm_rxn_indexes = {}
        for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
            if string.find(rxn.code, "REFINISH_STEEL_") then
                rm_rxn_indexes[rxn.index] = true
            end
        end
        for _, civ in ipairs(df.global.world.entities.all) do
            if civ.type == df.historical_entity_type.Civilization and civ.entity_raw then
                local civ_has_rm = false
                for _, pid in ipairs(civ.entity_raw.workshops.permitted_reaction_id) do
                    if rm_rxn_indexes[pid] then
                        perm_count = perm_count + 1
                        civ_has_rm = true
                    end
                end
                if civ_has_rm then civs_unlocked = civs_unlocked + 1 end
            end
        end
        c.inj_permissions = perm_count
        c.civs_unlocked = civs_unlocked
    end

    -- Log the full summary
    log(summary_type(), string.format(
        'Pipeline complete (%.3fs); mod is active. Sweep:%.3f | Mod:%.3f | Scan:%.3f | Mat:%.3f | Rxn:%.3f | ModPerm:%.3f | Ent:%.3f | Load:%.3f',
        t_total, t_sweep, t_modules, t_scan, t_idx_mat, t_idx_rxn, t_mod_perms,
        t_idx_ent, t_load), 'PIPELINE')

    -- Return timing results for the prompt section to use
    return {
        t_total = t_total, t_sweep = t_sweep, t_modules = t_modules,
        t_scan = t_scan, t_idx_mat = t_idx_mat, t_idx_rxn = t_idx_rxn,
        t_mod_perms = t_mod_perms, t_idx_ent = t_idx_ent, t_load = t_load,
        save_protocol = save_protocol, orphaned_jobs_fixed = orphaned_jobs_fixed
    }
end


-- ==========================================
-- ENTRY POINT
-- ==========================================
-- SILENT: Run pipeline, no prompts, return immediately.
-- Manual: Run pipeline, then show result prompt.
--
-- For manual invocations, run_pipeline() is called directly
-- at the top level of the script; NOT inside a ZScreen
-- callback. This guarantees there is no parent modal on the
-- screen stack when the result prompt fires.
-- ==========================================
if silent then
    -- Automatic invocation: just run, caller owns the output.
    run_pipeline()
    return
end

-- Manual invocation: confirm before running. The pipeline and
-- its result prompt run on the next frame so the confirmation
-- dialog is fully off the screen stack first.
RefinishPrompt{
    text = "Initiate startup?\n\nThis will rebuild all materials, reactions, and entity permissions.",
    text_pen = THEME.PRI,
    on_yes = function()
        -- Deferred: let the confirmation prompt fully dismiss before
        -- the pipeline runs and potentially shows its own result prompt.
        dfhack.timeout(1, 'frames', function()
            local timing = run_pipeline()

            if msg_setting == 'DEBUG' then
                local bp_mats = _G.refinish_telemetry and _G.refinish_telemetry.counts and _G.refinish_telemetry.counts.bp_materials or 0
                local bp_rxns = _G.refinish_telemetry and _G.refinish_telemetry.counts and _G.refinish_telemetry.counts.bp_reactions or 0
                local bp_cats = _G.refinish_telemetry and _G.refinish_telemetry.counts and _G.refinish_telemetry.counts.bp_categories or 0

                local report = string.format(
                    "Startup Pipeline Complete (%.3fs)\n\n" ..
                    "--- PIPELINE TIMING ---\n" ..
                    "Ghost Sweep:      %.3fs\n" ..
                    "Module Pipeline:  %.3fs\n" ..
                    "Blueprint Scan:   %.3fs\n" ..
                    "Index Materials:  %.3fs\n" ..
                    "Index Reactions:  %.3fs\n" ..
                    "Module Perms:     %.3fs\n" ..
                    "Index Entities:   %.3fs\n" ..
                    "Restore Payload:  %.3fs\n\n" ..
                    "--- BLUEPRINT ---\n" ..
                    "Materials: %d  |  Reactions: %d  |  Categories: %d\n" ..
                    "Protocol: %s  |  Orphans Fixed: %d",
                    timing.t_total, timing.t_sweep, timing.t_modules, timing.t_scan,
                    timing.t_idx_mat, timing.t_idx_rxn, timing.t_mod_perms,
                    timing.t_idx_ent, timing.t_load,
                    bp_mats, bp_rxns, bp_cats,
                    timing.save_protocol, timing.orphaned_jobs_fixed
                )
                RefinishPrompt{
                    frame_h = 24,
                    frame_w = 60,
                    text = report,
                    on_ok = function() end
                }:show()

            elseif msg_setting == 'GUIDED' then
                RefinishPrompt{
                    frame_h = 10,
                    text = string.format("Refinish Metal is live. Startup completed in %.2fs.", timing.t_total),
                    on_ok = function() end
                }:show()

            elseif msg_setting == 'PASSIVE' then
                dfhack.gui.showAnnouncement(
                    string.format('Refinish Metal: Startup complete (%.2fs).', timing.t_total),
                    THEME.PRI, true
                )
            end
        end)
    end
}:show()