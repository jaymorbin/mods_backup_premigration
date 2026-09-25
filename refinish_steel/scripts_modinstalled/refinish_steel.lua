--@ module = true
-- refinish_steel.lua
-- ==========================================
-- REFINISH METAL: MASTER COORDINATION SCRIPT
-- ==========================================
-- This is the top-level entry point. It handles:
--   - Application boot (logging, session rotation)
--   - Map load (evaluators, boot scan, state detection)
--   - Delayed startup (triggers the pipeline)
--   - Runtime monitors (reaction watcher, UI tripwire, autosave)
--   - Map unload (shutdown, cleanup)
--
-- _G KEY REGISTRY:
-- Every _G.refinish_ key used across the mod is listed here.
-- All per-map keys are nil'd in the shutdown block (PRIORITY 4).
--
-- SESSION STATE (per-map lifecycle)
--   active                  - bool: is the mod running on this map?
--   menu_locked             - bool: is the ESC menu open?
--   silent_load             - bool: suppress prompts on next startup?
--   autosave_in_progress    - bool: is an autosave cycle running?
--   version                 - string: mod version (e.g. "v3.2")
--
-- PIPELINE STATE (what's been injected into RAM)
--   ram_loaded              - bool: are RM materials in the inorganics array?
--   reactions_loaded        - bool: are RM reactions in the reactions array?
--   entity_loaded           - bool: are RM permissions in civ entity_raws?
--   data_loaded             - bool: do any items carry RM material indexes?
--
-- BOOT CACHES (derived from static raws, computed once on map load)
--   valid_bases             - array: all physically valid metals (from boot Pass 2)
--   known_metals_cache      - set: metals the player civ can access (boot Pass 3)
--   reaction_traits         - dict: scored traits per reaction index (boot Pass 1)
--   evaluated_reactions     - dict: all scored metal-making reactions (evaluator)
--   best_metal_template     - table: highest-scoring metal reaction + indexes
--   best_dust_template      - table: highest-scoring powder reaction + indexes
--   civ_tech                - dict: per-civ mood/tech/known_metals (boot Pass 4)
--
-- BLUEPRINT (scan output, rebuilt each data cycle)
--   blueprint               - table: materials, reactions, categories, civ_tech,
--                              ui_dict, original_names
--
-- MONITOR TIMESTAMPS (polled by runtime loops)
--   last_ui_ping            - string: last UI tripwire check time
--   last_cal_ping           - string: last calendar check time
--   last_watch_ping         - string: last reaction watcher check time
--   last_real_save          - number: os.time() of last real-time save
--   last_jobs_canceled      - number: count for panel display
--
-- ERROR THROTTLES (prevent log spam from polling loops)
--   err_spam_watcher        - bool: suppress repeated watcher errors
--   err_spam_ui             - bool: suppress repeated UI errors
--   err_spam_cal            - bool: suppress repeated calendar errors
--
-- HUD STATE
--   hud_view                - string: current panel name
--   hud_restore_left        - string: panel to restore on left nav
--   hud_restore_right       - string: panel to restore on right nav
--
-- HOTKEYS
--   hk_cache                - table: keybinding strings by function name
--
-- TELEMETRY (persistent for the full map session)
--   telemetry               - table: structured timing data with sub-tables:
--                              .boot     - map-load boot timings
--                              .startup  - pipeline rebuild timings
--                              .last_save; most recent autosave cycle timings
--                              .counts   - asset counts from latest pipeline run
--
-- AUTOSAVE CONFIG
--   original_autosave       - int: vanilla autosave setting, restored on unload
--
-- LOGGING (persists across full DF session, NOT per-map)
--   log                     - array: in-memory log lines (capped at 5000)
--   log_event               - function: the logging function itself
--   app_boot_rotation_done  - bool: has the session log been rotated?
--
-- MODULE ENGINE (manages its own lifecycle, NOT cleaned per-map)
--   module_registry         - dict: registered module payloads by prefix
--   module_listeners        - dict: listener callbacks by module name
--   modules_injected        - bool: has the module pipeline run this cycle?
--   module_clone_cache      - dict: best clone donor per material class (from evaluator)
-- ==========================================

local scriptmanager = require('script-manager')
local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt
local utils = require('utils')
local eval_bases = reqscript('refinish-bases')
local eval_metal = reqscript('refinish-evaluate-metal-making')
local eval_dust = reqscript('refinish-evaluate-dust-making')

-- ==========================================
-- APPLICATION BOOT: UNIVERSAL LOGGING ENGINE
-- ==========================================
_G.refinish_log = _G.refinish_log or {}

_G.refinish_log_event = function(msg)
    local timestamp = os.date("%H:%M:%S")
    local formatted_msg = string.format("[%s] %s", timestamp, msg)
    
    -- RAM Array (Capped at 5000 lines)
    table.insert(_G.refinish_log, 1, formatted_msg)
    -- ---- THREE ROWS PER ENTRY NOW ----
    -- A tagged entry renders as two header lines plus its body, so
    -- 5000 stored lines is closer to 1700 readable entries than it
    -- used to be. The table costs nothing until the log is opened.
    --
    -- Trim this if the HUD hangs on open: the cost is in building the
    -- rendered list, not in holding the strings.
    if #_G.refinish_log > 15000 then table.remove(_G.refinish_log) end
    
    -- Hard Drive Live Append
    pcall(function()
        local log_file = io.open("refinish_session.log", "a")
        if log_file then
            log_file:write(formatted_msg .. "\n")
            log_file:close()
        end
    end)
end

-- ==========================================
-- LOG FUNNELS
-- ==========================================
-- Every line this file writes goes through one of these, in the one
-- grammar the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body.
-- The panel filters on TYPE and nothing else, so each call site
-- states its own:
--   DETAIL   debugging material, shown in Debug only
--   INFO     what a player might check during play, Normal and up
--   faults, and the few confirmations a player wants at a glance
--   (COMPLETE, SYSTEM, ONLINE and the like), show in Quiet as well
-- TYPE comes first so no call site can drop it unnoticed: a nil TYPE
-- still renders, as UNTYPED, which shows at every Log Detail level
-- instead of being guessed at.
--
-- This file coordinates several subsystems, so it keeps one funnel
-- per subsystem rather than naming one at every call site. Each has
-- the same (typ, msg, subject) shape as every other file's log().
-- SUBJECT is the correlation slot: a map event, a job id, a step.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, and
-- nothing in this file answers a typed command: it runs on game
-- events and its own loops. Anything it needs to say lives in the
-- log alone.
-- ==========================================
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

local function make_log(sub)
    return function(typ, msg, subject)
        if not _G.refinish_log_event then return end
        local line
        if rlog then
            line = rlog.compose('REFINISH_METAL', sub, subject, typ, msg)
        else
            -- The composer failed to load. Same grammar, unsanitised.
            line = string.format('REFINISH_METAL %s %s %s | %s', sub,
                tostring(subject or '-'), tostring(typ or 'UNTYPED'),
                tostring(msg))
        end
        _G.refinish_log_event(line)
    end
end

local log_session = make_log('SESSION')     -- the executable and the map
local log_boot    = make_log('BOOT')        -- map load state check
local log_system  = make_log('SYSTEM')      -- first run, hotkeys, monitors
local log_watcher = make_log('WATCHER')     -- grinder reaction watcher
local log_ui      = make_log('UI_MONITOR')  -- ESC menu tripwire
local log_cal     = make_log('CALENDAR')    -- autosave timer

-- ---- VERSION, AT LOAD ----
-- Was assigned inside the SC_MAP_LOADED handler, which meant it was
-- nil for the whole span between launch and a map being loaded. The
-- launch banner below reads it, so the banner threw the moment it
-- stopped being a hardcoded string.
--
-- It is a constant. It belongs where the file loads, not where a
-- world event fires. Every consumer still guards with `or "?"`, which
-- was the existing signal that nil was reachable.
_G.refinish_version = "v3.4.0"

-- The Session Rotator: Cycle the logs ONLY ONCE per Dwarf Fortress launch
if not _G.refinish_app_boot_rotation_done then
    pcall(function()
        os.remove("refinish_last_session.log")
        os.rename("refinish_session.log", "refinish_last_session.log")
    end)
    _G.refinish_app_boot_rotation_done = true
    
    -- Immediately log the application boot. SESSION is the subsystem
    -- because these two belong to the executable rather than to the
    -- mod.
    log_session('SYSTEM', 'Dwarf Fortress executable launched.', 'LAUNCH')
    log_session('SYSTEM', string.format(
        'Core module %s loaded into system memory.',
        tostring(_G.refinish_version or '?')), 'BOOT')
end
-- ==========================================

dfhack.onStateChange['refinish_steel_system'] = function(sc)
    
    if sc == SC_MAP_LOADED then
        if not dfhack.isMapLoaded() then return end

        if df.global.gamemode ~= df.game_mode.DWARF then return end

        local mod_is_active = false
        for _, mod in ipairs(scriptmanager.get_active_mods()) do
            if mod.id == 'refinish_steel' then mod_is_active = true break end
        end

        if not mod_is_active then return end
        if _G.refinish_active then return end
        
        local current_save = dfhack.getSavePath() or "Unknown_Save_Dir"
        
        log_session('SYSTEM', 'Map loaded from ' .. current_save
            .. '. Initializing session.', 'MAP_LOADED')

        _G.refinish_active = true
        _G.refinish_menu_locked = false
        _G.refinish_original_autosave = _G.refinish_original_autosave or df.global.d_init.feature.autosave

        -- ==========================================
        -- PERSISTENT TELEMETRY TABLE
        -- ==========================================
        -- Created once at session start and kept alive for the entire
        -- map session. Unlike the old approach (created per-autosave,
        -- nil'd at the end), this table persists so the status panel,
        -- log, debug prompts, and dump can all read historical timing
        -- data at any time.
        --
        -- Structure:
        --   boot.*       - Map-load boot timings (set here, never overwritten)
        --   startup.*    - Pipeline rebuild timings (set by refinish-startup)
        --   last_save.*  - Most recent autosave cycle timings (set by refinish-autosave)
        --   counts.*     - Asset counts from the most recent pipeline run
        -- ==========================================
        _G.refinish_telemetry = {
            -- Boot timings: populated immediately below
            boot = {
                t_modules   = 0,  -- Module pipeline
                t_eval      = 0,  -- Reaction evaluators (metal + dust templates)
                t_boot_scan = 0,  -- Unified boot scanner (all passes)
                t_state     = 0,  -- State detection (existing RM assets in RAM)
                t_total     = 0,  -- Total boot wall time
            },
            -- Startup timings: populated by refinish-startup.lua
            startup = {
                t_sweep     = 0,  -- Ghost job sweep
                t_modules   = 0,  -- Module pipeline (rebuild)
                t_scan      = 0,  -- Blueprint scan
                t_idx_mat   = 0,  -- Material injection
                t_idx_rxn   = 0,  -- Reaction injection
                t_mod_perms = 0,  -- Module permission evaluation (Step 5.5)
                t_idx_ent   = 0,  -- Entity permission injection
                t_load      = 0,  -- JSON payload restore (autosave protocol only)
                t_total     = 0,  -- Total startup wall time
            },
            -- Last save cycle timings: populated by refinish-autosave.lua
            last_save = {
                protocol    = "N/A",  -- "HOTSAVE" or "AUTOSAVE"
                timestamp   = "N/A",  -- Human-readable time of last save
                t_save      = 0,      -- JSON payload write (autosave only)
                t_clr_ent   = 0,      -- Entity permission clear
                t_clr_rxn   = 0,      -- Reaction clear
                t_clr_mat   = 0,      -- Material clear
                t_engine    = 0,      -- DF quicksave execution
                t_restore   = 0,      -- Full pipeline restore (sweep+scan+index)
                t_active    = 0,      -- Total active processing (excludes wait time)
                items       = 0,      -- Items saved/washed (autosave only)
                buildings   = 0,      -- Buildings saved/washed (autosave only)
                constructions = 0,    -- Constructions saved/washed (autosave only)
            },
            -- Asset counts: populated by boot + startup, refreshed each cycle
            counts = {
                -- Boot cache (set during boot, static for session)
                valid_metals    = 0,
                known_metals    = 0,
                reaction_traits = 0,
                civ_techs       = 0,
                -- Baseline game state (set during boot, before injection)
                base_inorganics = 0,  -- Total inorganics in the world BEFORE RM injection
                base_reactions  = 0,  -- Total reactions in the world BEFORE RM injection
                -- Blueprint (set by startup after scan)
                bp_materials    = 0,
                bp_reactions    = 0,
                bp_categories   = 0,
                active_bases    = 0,
                -- Injected (set by startup after index scripts run)
                inj_materials   = 0,  -- RM inorganics added to RAM
                inj_reactions   = 0,  -- RM reactions added to RAM
                inj_categories  = 0,  -- RM categories added to RAM
                inj_permissions = 0,  -- RM civ permission entries added
                civs_unlocked   = 0,  -- Number of civs that received permissions
            },
        }

        -- ==========================================
        -- MASTER CACHE BUILDER (Runs ONCE per save)
        -- ==========================================
        -- Every step is timed and logged. The os.clock() timer
        -- measures CPU time, not wall time; it won't include
        -- time spent waiting for user input or DF rendering.
        -- ==========================================
        local boot_clock = os.clock()
        local t = boot_clock

        -- Steps 1, 2 and 3 (module pipeline, reaction evaluators,
        -- unified boot scan) now run in refinish-startup, as Step 2
        -- and Step 2.5.
        --
        -- WHY THEY LEFT: the module pipeline WRITES to the inorganics
        -- array. Running it here put the module band into RAM at
        -- SC_MAP_LOADED, before the pause protocol and before
        -- refinish-index sets _G.refinish_ram_loaded. Every check in
        -- RM that answers "is it safe to write to disk" reads that
        -- flag or tests only the REFINISH_STEEL_ prefix, so all of
        -- them reported clean while module materials were live. The
        -- autosave baseline check then wrote saves with injected data
        -- still in the array.
        --
        -- The evaluators and the boot scan followed it because both
        -- read the array it writes, so all three moved together. In
        -- startup they are guarded to build once per loaded world,
        -- while the module pipeline keeps its own per-cycle guard.
        --
        -- Counts formerly snapshotted here (valid_metals,
        -- known_metals, reaction_traits, civ_techs) moved with them,
        -- since they describe caches that no longer exist at boot.
        --
        -- boot_clock and t above are deliberately kept: t_state and
        -- t_total below still measure against them. t is reset here so
        -- t_state covers only the state check, as before.
        t = os.clock()

        -- Snapshot baseline game state BEFORE any RM injection happens.
        -- These numbers are the vanilla totals (plus any other mods).
        -- After startup injects RM assets, the live arrays will be larger.
        _G.refinish_telemetry.counts.base_inorganics = #df.global.world.raws.inorganics.all
        _G.refinish_telemetry.counts.base_reactions = #df.global.world.raws.reactions.reactions

        _G.refinish_last_ui_ping = "Initializing..."
        _G.refinish_last_cal_ping = "Initializing..."
        _G.refinish_last_watch_ping = "Initializing..."
        _G.refinish_last_real_save = os.time()

        -- FIRST TIME INSTALL CHECK
        local first_run = dfhack.persistent.getSiteData('refinish_installed')
        if not first_run or first_run == "" then
            dfhack.persistent.saveSiteData('refinish_installed', 'TRUE')
            log_system('SYSTEM', 'First time install detected. Guided prompt'
                .. ' triggered.', 'FIRST_RUN')
            local THEME = reqscript('refinish-theme').get_current_theme()
            -- The config panel opens from this prompt's OK button.
            --
            -- It was deferred to execute_startup for a while, because
            -- the panel reaches refinish-panel-metals, which calls
            -- get_valid_bases and would run the unified scan before
            -- the module pipeline had injected anything, caching a
            -- base metal list with no module content for the whole
            -- session.
            --
            -- That hazard is gone. on_ok does not fire until the
            -- player presses OK, which is many frames after this
            -- handler returns, and the pipeline now completes inside
            -- this same handler. The scan cannot run early.
            --
            -- It also fixes the stacking. The panel used to be pushed
            -- onto the viewscreen while this prompt was still on it,
            -- so the player met the panel first and found the prompt
            -- buried underneath.
            RefinishPrompt{
                frame_h = 14,
                text = "Refinish Metal is online. Press OK to review your configuration settings.",
                text_pen = THEME.PRI,
                on_ok = function()
                    log_system('INFO', 'First run; opening the configuration'
                        .. ' panel.', 'FIRST_RUN')
                    dfhack.run_script('refinish-hud', 'show', 'config')
                end,
                }:show()
        else
            local msg_setting = dfhack.persistent.getSiteData('refinish_config_msg')
            if not msg_setting or msg_setting == "" then msg_setting = 'GUIDED' end
            
            if msg_setting == 'DEBUG' then
                -- DEBUG prompt: show actual boot telemetry
                local bt = _G.refinish_telemetry.boot
                local ct = _G.refinish_telemetry.counts
                local debug_txt = string.format(
                    "Refinish Metal is online.\n\n" ..
                    "--- BOOT TELEMETRY ---\n" ..
                    "Modules: %.3fs  |  Evaluators: %.3fs\n" ..
                    "Boot Scan: %.3fs  |  State Check: %.3fs\n" ..
                    "Total Boot: %.3fs\n\n" ..
                    "--- BOOT CACHE ---\n" ..
                    "Valid Metals: %d  |  Known Metals: %d\n" ..
                    "Reaction Traits: %d  |  Civ Techs: %d",
                    bt.t_modules, bt.t_eval, bt.t_boot_scan, bt.t_state, bt.t_total,
                    ct.valid_metals, ct.known_metals, ct.reaction_traits, ct.civ_techs
                )
                RefinishPrompt{
                    frame_h = 20,
                    frame_w = 60,
                    text = debug_txt,
                    on_ok = function() end
                }:show()
            elseif msg_setting == 'GUIDED' then
                RefinishPrompt{
                    frame_h = 10,
                    text = "Refinish Metal is online.",
                    on_ok = function() end
                }:show()
            end
        end

        -- ==========================================
        -- UNIVERSAL STATE MANAGER
        -- ==========================================
        -- Detect whether RM assets already exist in RAM from a
        -- previous session (e.g. hotsave left items with mat_index
        -- pointing at RM inorganics). This runs ONCE at boot.
        -- ==========================================
        _G.refinish_ram_loaded = false
        _G.refinish_reactions_loaded = false
        _G.refinish_entity_loaded = false
        _G.refinish_data_loaded = false

        local inorganics = df.global.world.raws.inorganics.all
        for _, mat in ipairs(inorganics) do
            if string.find(mat.id, "REFINISH_STEEL_MAT_") then
                _G.refinish_ram_loaded = true
                break
            end
        end

        local custom_rxn_indexes = {}
        local reactions = df.global.world.raws.reactions.reactions
        for _, rxn in ipairs(reactions) do
            if string.find(rxn.code, "REFINISH_STEEL_RXN_") then
                _G.refinish_reactions_loaded = true
                custom_rxn_indexes[rxn.index] = true
            end
        end

        if _G.refinish_reactions_loaded then
            local player_civ = df.historical_entity.find(df.global.plotinfo.civ_id)
            if player_civ and player_civ.entity_raw then
                for _, pid in ipairs(player_civ.entity_raw.workshops.permitted_reaction_id) do
                    if custom_rxn_indexes[pid] then
                        _G.refinish_entity_loaded = true
                        break
                    end
                end
            end
        end

        if _G.refinish_ram_loaded then
            for _, item in ipairs(df.global.world.items.all) do
                local ok, m_idx = pcall(function() return item.mat_index end)
                if ok and type(m_idx) == 'number' and m_idx >= 0 and m_idx < #inorganics then
                    if string.find(inorganics[m_idx].id, "REFINISH_STEEL_MAT_") then
                        _G.refinish_data_loaded = true
                        break
                    end
                end
            end
        end

        -- Finalize state check timing
        _G.refinish_telemetry.boot.t_state = os.clock() - t
        _G.refinish_telemetry.boot.t_total = os.clock() - boot_clock

        -- Both boot lines are DETAIL. What a player reads at map load
        -- is the startup summary and the ONLINE line after it.
        log_boot('DETAIL', string.format(
            'State check complete (%.3fs); MATS:%s | RXNS:%s | UI:%s | ITEMS:%s',
            _G.refinish_telemetry.boot.t_state,
            tostring(_G.refinish_ram_loaded), tostring(_G.refinish_reactions_loaded),
            tostring(_G.refinish_entity_loaded), tostring(_G.refinish_data_loaded)
        ), 'STATE_CHECK')
        log_boot('DETAIL', string.format('Boot complete (%.3fs).',
            _G.refinish_telemetry.boot.t_total), 'TOTAL')

        -- ==========================================
        -- DELAYED STARTUP LOGIC
        -- ==========================================
        -- Default is NONE. The pipeline runs synchronously, right
        -- here, before DF's first tick. The delay branches below are
        -- kept for diagnosis but every one of them is unsafe on a save
        -- that contains module material items.
        --
        -- WHY (measured 2026-08-26)
        --
        -- Items store mat_index, never material names. Module items go
        -- to disk holding an index that only exists while RM is
        -- injected, and core RM items do the same under HOTSAVE. On
        -- load, before injection, those indices sit past the end of
        -- raws.inorganics.all, and what DF does with them depends
        -- entirely on the item class:
        --
        --   solids (BAR, BLOCKS, BOULDER, TOOL)
        --       resolve to a generic rock. Inert. These have ridden
        --       through this window on every reload since the module
        --       engine existed, which is why the delay looked safe.
        --
        --   LIQUID_MISC
        --       resolves to MAGMA. An inorganic liquid with no
        --       material IS magma by DF's definition. It is sitting in
        --       a wooden bucket, being carried by a dwarf.
        --
        -- On a test save with 24 out of range items, 21 solids read as
        -- "rock bars", "rock blocks", "rock jug", "rock", and the 3
        -- liquids read as "magma". The fort burned down on unpause.
        --
        -- Running the pipeline while still paused repaired all 24, so
        -- DF settles item material at first service rather than at
        -- load. This handler runs before any tick, which makes it the
        -- last safe moment.
        --
        -- The old reason for delaying was a save safety check that
        -- read _G.refinish_ram_loaded, a flag that knew about core RM
        -- but not modules. That check is now ram_is_at_baseline() in
        -- refinish-autosave.lua, which walks the arrays directly
        -- through rm_owned(). The reason retired; the delay outlived
        -- it.
        --
        -- If this default is ever changed back, change it in
        -- refinish-panel-config.lua as well, in BOTH the widget
        -- default and the restore-defaults list.
        -- ==========================================
        -- The config option was removed from the panel, so the site
        -- data read is commented out rather than deleted. It must not
        -- run while there is no UI to set it: a save that stored TICK
        -- before removal would keep it permanently and silently.
        --
        -- To re-enable, uncomment these two lines and uncomment the
        -- four blocks marked LOAD DELAY OPTION in
        -- refinish-panel-config.lua. The dispatch chain below is
        -- untouched and all four branches still work.
        -- local delay_setting = dfhack.persistent.getSiteData('refinish_config_delay')
        -- if not delay_setting or delay_setting == "" then delay_setting = 'NONE' end
        local delay_setting = 'NONE'

        local function execute_startup()
            if _G.refinish_active then
                log_system('DETAIL', 'Executing refinish-startup (delay: '
                    .. tostring(delay_setting) .. ').', 'STARTUP')
                dfhack.run_script('refinish-startup', 'SILENT')

                -- The first run config panel used to open here, gated
                -- by _G.refinish_first_run_pending. It now opens from
                -- the on_ok of the first time install prompt above, so
                -- the player sees the prompt first and the panel
                -- second. The flag is no longer set or read anywhere.
            end
        end

        if delay_setting == 'TICK' then
            dfhack.timeout(1, 'ticks', execute_startup)
        elseif delay_setting == 'FRAMES_20' then
            dfhack.timeout(20, 'frames', execute_startup)
        elseif delay_setting == 'FRAMES_100' then
            dfhack.timeout(100, 'frames', execute_startup)
        elseif delay_setting == 'NONE' then
            execute_startup()
        end
        
        -- HOTKEYS (DYNAMIC FETCH & CACHE)
        local function get_hk(id, default)
            local hk = dfhack.persistent.getSiteData(id)
            return (hk and hk ~= "") and hk or default
        end
        
        -- THE FIX: Removed '@dwarfmode' to enforce global UI routing
        _G.refinish_hk_cache = {
            autosave = get_hk('refinish_hk_autosave', 'Ctrl-Shift-S'),
            wipe = get_hk('refinish_hk_wipe', 'Ctrl-Shift-X'),
            startup = get_hk('refinish_hk_startup', 'Ctrl-Alt-X'),
            hardwipe = get_hk('refinish_hk_hardwipe', 'Ctrl-Shift-Q'),
            
            config   = get_hk('refinish_hk_config',  'Ctrl-Shift-C'),
            metals   = get_hk('refinish_hk_metals',  'Ctrl-Shift-M'),
            civs     = get_hk('refinish_hk_civs',    'Ctrl-Shift-V'),
            status   = get_hk('refinish_hk_status',  'Ctrl-Shift-I'),
            log      = get_hk('refinish_hk_log',     'Ctrl-Shift-L'),
            inspect  = get_hk('refinish_hk_inspect', 'Ctrl-Shift-E'),
            help     = get_hk('refinish_hk_help',    'Ctrl-Shift-H')
        }
        
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.autosave, 'refinish-autosave')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.wipe, 'refinish-shutdown')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.startup, 'refinish-startup')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.hardwipe, 'refinish-hard-shutdown')
        
        -- THE BYPASS: We pass 'show' FIRST so DFHack doesn't intercept the reserved engine strings
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.config,  'refinish-hud show config')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.metals,  'refinish-hud show metals')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.civs,    'refinish-hud show civs')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.status,  'refinish-hud show status')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.log,     'refinish-hud show log')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.inspect, 'refinish-hud show inspect')
        dfhack.run_command('keybinding', 'add', _G.refinish_hk_cache.help,    'refinish-hud show help')

        df.global.d_init.feature.autosave = -1
        log_system('DETAIL', 'Hotkeys bound and vanilla autosave suspended.',
            'HOTKEYS')

        -- ==========================================
        -- POLLING RATE HELPER
        -- ==========================================
        -- Reads the config once per loop iteration to pick up live
        -- changes from the config panel without needing a restart.
        -- Returns the frame count for dfhack.timeout().
        -- ==========================================
        local POLL_RATES = { FAST = 10, NORMAL = 25, RELAXED = 50 }

        local function get_poll_frames()
            local setting = dfhack.persistent.getSiteData('refinish_config_poll_rate')
            return POLL_RATES[setting] or POLL_RATES.FAST
        end

        -- ==========================================
        -- 1.5. THE JIT REACTION WATCHER (Bait-and-Switch)
        -- ==========================================
        local JIT_CONFIG = {
            ["REFINISH_STEEL_RXN_LUA_GRIND_GEMS"] =   { qty = 3,   prod = 1, worthless = false, itype = df.item_type.ROUGH },
            ["REFINISH_STEEL_RXN_LUA_GRIND_COMMON"] = { qty = 1,   prod = 4, worthless = true,  itype = df.item_type.BOULDER },
            ["REFINISH_STEEL_RXN_LUA_GRIND_ANY"] =    { qty = 1,   prod = 4, worthless = false, itype = df.item_type.BOULDER },
            ["REFINISH_STEEL_RXN_LUA_GRIND_METAL"] =  { qty = 150, prod = 1, worthless = false, itype = df.item_type.BAR }
        }

        local plaster_template = nil

        local function build_ghost_grinder_jit(ghost_code, mat_index, mat_name, config)
            if not plaster_template then
                for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
                    if rxn.code == "MAKE_PLASTER_POWDER" then
                        plaster_template = rxn
                        break
                    end
                end
            end
            if not plaster_template then return false end

            local reactions_array = df.global.world.raws.reactions.reactions
            local nice_name = "grind " .. string.lower(mat_name) .. " into dust"

            local rxn = df.reaction:new()
            rxn:assign(plaster_template)
            
            rxn.code = ghost_code
            rxn.name = nice_name
            rxn.skill = df.job_skill.NONE
            rxn.category = "" 
            pcall(function() rxn.flags.FORTRESS_MODE_ENABLED = true end)

            rxn.building.type:resize(0)
            rxn.building.subtype:resize(0)
            rxn.building.custom:resize(0)

            rxn.reagents:resize(0)
            local r_in = df.reaction_reagent_itemst:new()
            r_in:assign(plaster_template.reagents[0])
            r_in.code = "input"
            r_in.quantity = config.qty
            r_in.item_type = config.itype
            r_in.item_subtype = -1
            r_in.mat_type = 0         
            r_in.mat_index = mat_index 
            r_in.reaction_class = ""
            rxn.reagents:insert('#', r_in)

            local r_bag = df.reaction_reagent_itemst:new()
            r_bag:assign(plaster_template.reagents[1])
            r_bag.code = "bag"
            rxn.reagents:insert('#', r_bag)

            rxn.products:resize(0)
            local p_out = df.reaction_product_itemst:new()
            p_out:assign(plaster_template.products[0])
            p_out.count = config.prod
            p_out.mat_type = -1
            p_out.mat_index = -1
            p_out.product_to_container = "bag"
            p_out.flags.GET_MATERIAL_SAME = true
            p_out.get_material.reagent_code = "input"
            rxn.products:insert('#', p_out)

            rxn.index = #reactions_array
            reactions_array:insert('#', rxn)
            reactions_array[#reactions_array - 1].reagents[0].flags2.non_economic = config.worthless
            
            return true
        end

        local function reaction_watcher_loop()
            if not dfhack.isMapLoaded() or not _G.refinish_active then return end

            local ok, err = pcall(function()
                _G.refinish_last_watch_ping = os.date("%H:%M:%S")
                local protect_bases = dfhack.persistent.getSiteData('refinish_config_protect')
                if not protect_bases or protect_bases == "" then protect_bases = 'YES' end

                -- Build a fast lookup of active base metals for the protect check
                local protected_bases = {}
                if protect_bases == 'YES' then
                    local json = require('json')
                    local bases_str = dfhack.persistent.getSiteData('refinish_config_bases')
                    if bases_str and bases_str ~= "" then
                        pcall(function() protected_bases = json.decode(bases_str) end)
                    else
                        protected_bases["STEEL"] = true
                    end
                end

                for _, job in utils.listpairs(df.global.world.jobs.list) do
                    if job.job_type == df.job_type.CustomReaction then
                        local r_name = tostring(job.reaction_name) 
                        
                        if string.find(r_name, "^REFINISH_STEEL_RXN_LUA_GRIND_") then
                            local base_r_name = string.match(r_name, "^(REFINISH_STEEL_RXN_LUA_GRIND_[%a]+)")
                            local config = JIT_CONFIG[base_r_name]
                            
                            if config then
                                for _, job_item_ref in ipairs(job.items) do
                                    local actual_item = job_item_ref.item
                                    if actual_item then
                                        local itype = tonumber(actual_item:getType())
                                        if itype == tonumber(config.itype) then
                                            local mat_info = dfhack.matinfo.decode(actual_item)
                                            if mat_info and mat_info.inorganic then
                                                local specific_mat_id = mat_info.inorganic.id
                                                
                                                -- TRAP DOOR: Prevent Paradox & Respect Config
                                                local is_custom_finish = string.find(specific_mat_id, "REFINISH_STEEL_")
                                                local is_protected_base = protected_bases[specific_mat_id]

                                                if is_custom_finish or is_protected_base then
                                                    -- Human-readable name, computed once so BOTH
                                                    -- message branches below can use it.
                                                    -- Prefer the material's real solid-state display
                                                    -- name (e.g. "specific steel cinnabar"); fall back
                                                    -- to a de-underscored raw ID only if that name is
                                                    -- somehow missing.
                                                    local mat_name = mat_info.inorganic.material.state_name[0]
                                                    if not mat_name or mat_name == "" then
                                                        mat_name = string.lower(specific_mat_id):gsub("_", " ")
                                                    end

                                                    local msg
                                                    if is_protected_base then
                                                        -- Refusing a vanilla/base bar (e.g. plain steel)
                                                        msg = "A dwarf realized they were about to grind unfinished " .. mat_name .. " and canceled the job."
                                                    else
                                                        -- Refusing an already-finished RM bar
                                                        msg = "A dwarf realized they were about to grind finished " .. mat_name .. " and canceled the job."
                                                    end
                                                    local THEME = reqscript('refinish-theme').get_current_theme()
                                                    dfhack.gui.showAnnouncement(msg, THEME.RISK_L, true)
                                                    -- WARNING, matching the yellow announcement:
                                                    -- the player queued a grind the watcher had
                                                    -- to refuse.
                                                    log_watcher('WARNING', msg, 'JOB_' .. tostring(job.id))
                                                    dfhack.job.removeJob(job)
                                                    break 
                                                end

                                                local expected_ghost_id = base_r_name .. "_" .. specific_mat_id
                                                
                                                if r_name ~= expected_ghost_id then
                                                    local ghost_exists = false
                                                    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
                                                        if rxn.code == expected_ghost_id then ghost_exists = true break end
                                                    end
                                                    
                                                    if not ghost_exists then
                                                        local solid_name = mat_info.inorganic.material.state_name[0]
                                                        local built = build_ghost_grinder_jit(expected_ghost_id, actual_item:getMaterialIndex(), solid_name, config)
                                                        if built then
                                                            log_watcher('DETAIL', 'JIT compiled ' .. expected_ghost_id .. '.',
                                                                'JOB_' .. tostring(job.id))
                                                        end
                                                    end
                                                    
                                                    job.reaction_name = expected_ghost_id
                                                    -- DETAIL: one per grinding job, chatter in
                                                    -- ordinary play.
                                                    log_watcher('DETAIL', 'Ghost swap to ' .. specific_mat_id .. '.',
                                                        'JOB_' .. tostring(job.id))
                                                end
                                                break 
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end)

            if not ok then 
                if not _G.refinish_err_spam_watcher then
                    log_watcher('ERROR', 'Watcher loop error: ' .. tostring(err))
                    _G.refinish_err_spam_watcher = true
                end
            else
                _G.refinish_err_spam_watcher = false
            end
            dfhack.timeout(get_poll_frames(), 'frames', reaction_watcher_loop) 
        end

        -- ==========================================
        -- 1. THE UI TRIPWIRE (Fast Polling)
        -- ==========================================
        local function ui_monitor_loop()
            if not dfhack.isMapLoaded() or not _G.refinish_active then return end

            local ok, err = pcall(function()
                _G.refinish_last_ui_ping = os.date("%H:%M:%S")
                local focus = dfhack.gui.getCurFocus()
                
                local focus_str = ""
                if type(focus) == 'table' then
                    focus_str = focus[1] or ""
                elseif type(focus) == 'string' then
                    focus_str = focus
                end

                if string.find(focus_str, "^dfhack/") then return end

                local is_safe_menu = false
                if string.find(focus_str, 'dwarfmode/Options') or string.find(focus_str, 'dwarfmode/Save') then
                    is_safe_menu = true
                end

                if is_safe_menu and not _G.refinish_menu_locked then
                    _G.refinish_menu_locked = true
                    local esc_mode = dfhack.persistent.getSiteData('refinish_config_esc')
                    if not esc_mode or esc_mode == "" then esc_mode = 'AUTO' end

                    if esc_mode == 'AUTO' then
                        log_ui('DETAIL', 'ESC menu entered. Initiating SILENT shutdown.',
                            'ESC_MENU')
                        dfhack.run_script('refinish-shutdown', 'SILENT')
                    end
                
                elseif not is_safe_menu and _G.refinish_menu_locked then
                
                    _G.refinish_menu_locked = false
                    local esc_mode = dfhack.persistent.getSiteData('refinish_config_esc')
                    if not esc_mode or esc_mode == "" then esc_mode = 'AUTO' end

                    if esc_mode == 'AUTO' then
                
                        log_ui('DETAIL', 'ESC menu exited. Initiating SILENT startup.',
                            'ESC_MENU')
                        _G.refinish_silent_load = true
                        dfhack.run_script('refinish-startup', 'SILENT', 'NOPROMPT')
                    end
              
                end

                -- THE FIX: Catch retroactive AUTO swaps while parked in the ESC menu
                if is_safe_menu and _G.refinish_menu_locked and (_G.refinish_ram_loaded or _G.refinish_data_loaded) then
                    local esc_mode = dfhack.persistent.getSiteData('refinish_config_esc')
                    if not esc_mode or esc_mode == "" then esc_mode = 'AUTO' end
                    if esc_mode == 'AUTO' then
                        log_ui('DETAIL', 'Retroactive AUTO mode detected. Initiating'
                            .. ' SILENT shutdown.', 'ESC_MENU')
                        dfhack.run_script('refinish-shutdown', 'SILENT')
                    end
                end
            end)

            if not ok then 
                if not _G.refinish_err_spam_ui then
                    log_ui('ERROR', 'UI monitor loop error: ' .. tostring(err))
                    _G.refinish_err_spam_ui = true
                end
            else
                _G.refinish_err_spam_ui = false
            end
            dfhack.timeout(get_poll_frames(), 'frames', ui_monitor_loop)
        end

        -- ==========================================
        -- 2. SEASONAL AUTOSAVE LOGIC (Slow Polling)
        -- ==========================================
        local last_season = -1
        local last_year = -1

        local function calendar_loop()
            if not dfhack.isMapLoaded() or not _G.refinish_active then return end

            local ok, err = pcall(function()
                _G.refinish_last_cal_ping = os.date("%H:%M:%S")
                
                if not _G.refinish_menu_locked and not _G.refinish_autosave_in_progress then
                    df.global.d_init.feature.autosave = -1
                    local cur_year = df.global.cur_year
                    local cur_tick = df.global.cur_year_tick
                    local cur_season = math.floor(cur_tick / 100800) 
                    local now = os.time()

                    if last_season == -1 then last_season = cur_season last_year = cur_year end

                    local interval = dfhack.persistent.getSiteData('refinish_config_interval')
                    if not interval or interval == "" then interval = 'SEASONAL' end
                    local trigger = false

                    if cur_season ~= last_season or cur_year ~= last_year then
                        if interval == 'SEASONAL' then trigger = true
                        elseif interval == 'SEMIANNUAL' then if cur_season == 0 or cur_season == 2 then trigger = true end
                        elseif interval == 'YEARLY' then if cur_year ~= last_year then trigger = true end
                        end
                        last_season = cur_season
                        last_year = cur_year
                    end

                    if interval == 'REAL_15' and (now - _G.refinish_last_real_save) >= 900 then trigger = true
                    elseif interval == 'REAL_30' and (now - _G.refinish_last_real_save) >= 1800 then trigger = true
                    elseif interval == 'REAL_60' and (now - _G.refinish_last_real_save) >= 3600 then trigger = true
                    end

                    if trigger and interval ~= 'NONE' then
                        log_cal('INFO', 'Autosave timer triggered (' .. interval .. ').',
                            'AUTOSAVE_TIMER')
                        _G.refinish_last_real_save = now
                        dfhack.run_script('refinish-autosave')
                    end
                end
            end)

            if not ok then 
                if not _G.refinish_err_spam_cal then
                    log_cal('ERROR', 'Calendar loop error: ' .. tostring(err))
                    _G.refinish_err_spam_cal = true
                end
            else
                _G.refinish_err_spam_cal = false
            end
            dfhack.timeout(1000, 'frames', calendar_loop)
        end
        
        reaction_watcher_loop()
        ui_monitor_loop()
        calendar_loop()

        -- Build menu icon stamper. Poll gated like the loops
        -- above; restamps owned and adopted building icons
        -- whenever DF rebuilds the construction menu pages.
        pcall(function()
            dfhack.reqscript('refinish-menu-icons').start_stamper()
        end)

        -- Live loop timing for the telemetry panel's LOOP COST section.
        -- Every scheduled loop in the session, ours and other mods', so
        -- a slow game shows whose loop it is; see LIVE MODE in
        -- refinish-tool-profiler. The profiler stops itself on map
        -- unload. Guarded like the stamper: timing that fails should
        -- cost the telemetry, never the session.
        pcall(function()
            dfhack.reqscript('refinish-tool-profiler').live_start()
        end)

        log_system('ONLINE', 'Monitors and loops successfully started.',
            'STARTUP')

-- ==========================================
    -- SHUTDOWN SEQUENCE
    -- ==========================================
    elseif sc == SC_MAP_UNLOADED then
        if _G.refinish_active then
            -- PRIORITY 1: THE KILLSWITCH
            pcall(function()
                log_session('SYSTEM', 'Map unloaded. Executing memory wipe.',
                    'MAP_UNLOADED')
                _G.refinish_active = false
            end)

            -- Menu icon stamper down before the scrubbers run.
            -- Clearing the running flag here is what lets the next
            -- map's start_stamper succeed; the session stamp
            -- already kills any in flight timeout closure.
            pcall(function()
                dfhack.reqscript('refinish-menu-icons').stop_stamper()
            end)
            
            -- PRIORITY 2: THE SCRUBBERS (Absolute highest priority)
            -- THE FIX: Check state managers BEFORE calling dfhack.run_script.
            -- This perfectly guarantees the failsafe runs if needed, but prevents 
            -- the engine from redundantly loading/compiling scripts, which stops queue bleed.
            pcall(function()
                if _G.refinish_entity_loaded then dfhack.run_script('refinish-clear-entity') end
            end)
            pcall(function()
                if _G.refinish_reactions_loaded then dfhack.run_script('refinish-clear-reaction') end
            end)
            pcall(function()
                if _G.refinish_ram_loaded then dfhack.run_script('refinish-clear') end
            end)

            pcall(function()
                local mod_engine = dfhack.script_environment('refinish-module-engine')
                if mod_engine and mod_engine.clear_module_assets then
                    mod_engine.clear_module_assets()
                end
            end)
            
            -- PRIORITY 3: SECONDARY TEARDOWN (Hotkeys & Config Restores)
            pcall(function()
                if _G.refinish_original_autosave then df.global.d_init.feature.autosave = _G.refinish_original_autosave end
            end)

            pcall(function()
                -- We use the RAM cache here instead of getSiteData to prevent the database crash!
                if _G.refinish_hk_cache then
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.autosave)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.wipe)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.startup)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.hardwipe)
                    
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.config)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.metals)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.civs)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.status)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.log)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.inspect)
                    dfhack.run_command('keybinding', 'clear', _G.refinish_hk_cache.help)
                end
            end)
            
            -- PRIORITY 4: GARBAGE COLLECTION
            -- Every _G.refinish_ key set during the session must be
            -- nil'd here to prevent stale data leaking across map loads.
            -- Module engine keys (module_registry, module_listeners,
            -- modules_injected) are NOT cleaned here; they manage
            -- their own lifecycle across data cycles.
            -- Logging keys (log, log_event) persist across the full
            -- DF session, not just per-map.

            -- Pipeline state
            _G.refinish_blueprint = nil
            _G.refinish_ram_loaded = nil
            _G.refinish_reactions_loaded = nil
            _G.refinish_entity_loaded = nil
            _G.refinish_data_loaded = nil

            -- Session state
            _G.refinish_active = nil
            _G.refinish_menu_locked = nil
            _G.refinish_silent_load = nil
            _G.refinish_autosave_in_progress = nil
            _G.refinish_version = nil

            -- Boot caches
            _G.refinish_valid_bases = nil
            _G.refinish_known_metals_cache = nil
            _G.refinish_reaction_traits = nil
            _G.refinish_evaluated_reactions = nil
            _G.refinish_best_metal_template = nil
            _G.refinish_best_dust_template = nil
            _G.refinish_civ_tech = nil

            -- Hotkeys
            _G.refinish_hk_cache = nil

            -- HUD state
            _G.refinish_hud_view = nil
            _G.refinish_hud_restore_left = nil
            _G.refinish_hud_restore_right = nil

            -- Monitor timestamps
            _G.refinish_last_ui_ping = nil
            _G.refinish_last_cal_ping = nil
            _G.refinish_last_watch_ping = nil
            _G.refinish_last_real_save = nil
            _G.refinish_last_jobs_canceled = nil

            -- Telemetry
            _G.refinish_telemetry = nil

            -- Module Dependency
            _G.refinish_dependency_cache = nil
            
            pcall(function()
                log_system('OFFLINE', 'Memory successfully terminated.', 'SHUTDOWN')
            end)
            
            _G.refinish_err_spam_watcher = nil
            _G.refinish_err_spam_ui = nil
            _G.refinish_err_spam_cal = nil
        end
    end
end