--@ module = true
-- refinish-panel-help.lua

local gui = require('gui')
local widgets = require('gui.widgets')
local dialogs = require('gui.dialogs')

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
-- SUBJECT is the correlation slot: the panel action a line is
-- about. Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'HELP'
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
-- TEXT WRAPPING HELPER (With Paragraph Support)
-- Splits text into display lines that fit within max_width.
-- Blank lines in the source text produce blank separator lines.
-- ==========================================
local function wrap_help_text(text, max_width)
    local lines = {}
    if not text or text == "" then return lines end
    
    for paragraph in string.gmatch(text .. "\n", "(.-)\n") do
        if paragraph == "" then
            table.insert(lines, "") 
        else
            local current_line = ""
            for word in paragraph:gmatch("%S+") do
                if current_line == "" then
                    current_line = word
                elseif #current_line + 1 + #word <= max_width then
                    current_line = current_line .. " " .. word
                else
                    table.insert(lines, current_line)
                    current_line = word
                end
            end
            if current_line ~= "" then
                table.insert(lines, current_line)
            end
        end
    end
    return lines
end

-- ==========================================
-- HELP SYSTEM DATA DICTIONARY
-- Each topic has: id, title, keywords[], text
-- Keywords drive search; include synonyms and alternate phrasings.
-- Text uses \n for line breaks and \n\n for paragraph spacing.
-- ==========================================
local HELP_TOPICS = {

    -- ----------------------------------------
    -- OVERVIEW
    -- ----------------------------------------
    {
        id       = "overview",
        title    = "Overview",
        keywords = {"overview", "about", "what", "features", "summary", "introduction", "rawless"},
        text     =
            "Refinish Metal is a rawless DFHack mod that adds a material finishing " ..
            "system to Dwarf Fortress. Dust ground from valid stone, gem, or metal " ..
            "reagents is combined with a base metal at a Smelter to produce finished " ..
            "bars, a new material that shares the base metal's physical properties " ..
            "but takes its color and a portion of its value from the reagent.\n\n" ..
            "Steel is the default base metal, but any sufficiently craftable metal " ..
            "in your world can be configured as a base. Each active base generates " ..
            "its own independent set of reactions and finished materials.\n\n" ..
            "All custom data is hotloaded into RAM after map load and fully purged " ..
            "before any save. Save files remain 100% vanilla-compatible. Archived " ..
            "finish data is stored in a JSON payload embedded in site data and " ..
            "restored automatically on every reload.\n\n" ..
            "KEY FEATURES\n" ..
            "- Configurable base metals: finish any qualifying metal, not just steel.\n" ..
            "- Grind validated stone, gem, or metal reagents into dust.\n" ..
            "- Combine dust + base metal bars at a Smelter to produce finished bars.\n" ..
            "- Three finish tiers: Colour, Special, and Material (1:1 per-reagent).\n" ..
            "- Reagent validation filters unsuitable inorganics automatically.\n" ..
            "- Reads live world data and economy on every load; modpack-compatible.\n" ..
            "- Safe autosave system replaces vanilla autosave entirely.\n" ..
            "- Status dashboard, live event log, and object inspector for diagnostics."
    },

    -- ----------------------------------------
    -- GETTING STARTED
    -- ----------------------------------------
    {
        id       = "getting_started",
        title    = "Getting Started",
        keywords = {"start", "begin", "new", "first time", "install", "welcome", "setup", "how to"},
        text     =
            "FIRST LOAD\n" ..
            "On first install, a welcome prompt will appear advising you to review " ..
            "your settings (Ctrl-Shift-C). At minimum, check your autosave interval " ..
            "and Menu-Bound Data Cycling setting before playing.\n\n" ..
            "DATA LOADS ON UNPAUSE\n" ..
            "After loading a save, mod data is not injected immediately. It loads " ..
            "the first time you unpause the game. This ensures the engine is fully " ..
            "stable before any RAM writes occur.\n\n" ..
            "BASIC WORKFLOW\n" ..
            "1. Configure your base metals in the Base Metals panel (see 'Base Metals').\n" ..
            "   Steel is active by default.\n" ..
            "2. Order a Grind job at a Mason's Workshop, Jeweler's Workshop, or Forge.\n" ..
            "   A bag must be available; all grinding requires one empty bag.\n" ..
            "3. The dwarf grinds the reagent into dust, stored in the bag.\n" ..
            "4. At any Smelter, order a finishing reaction using the dust + base bars.\n" ..
            "   Each unit of dust in the bag finishes 3 bars.\n\n" ..
            "SAVING\n" ..
            "Use the mod's autosave (Ctrl-Shift-S) or leave Menu-Bound Cycling on " ..
            "AUTO. Do not use vanilla Save & Continue while mod data is active. " ..
            "See 'Saving Safely' for full details."
    },

    -- ----------------------------------------
    -- BASE METALS
    -- ----------------------------------------
    {
        id       = "base_metals",
        title    = "Base Metals",
        keywords = {"base", "bases", "metal", "steel", "mithril", "iron", "configure", "select", "activate", "valid", "crafting path", "smelting"},
        text     =
            "The base metal is what gets finished. Dust is applied to bars of the " ..
            "base metal at the Smelter, producing finished bars that share the base " ..
            "metal's physical and combat properties, with their color, name, and " ..
            "material value overwritten by the reagent combination.\n\n" ..
            "Steel is active by default. Any metal in your world that passes the " ..
            "validation criteria can be added as a base.\n\n" ..
            "VALIDATION CRITERIA FOR BASE METALS\n" ..
            "A metal must meet all of the following to qualify:\n" ..
            "- Carries the IS_METAL flag.\n" ..
            "- Has a valid crafting or smelting path (ghost metals with no production " ..
            "  route are excluded).\n" ..
            "- Thermally stable: melting point is 0 or above 10015.\n" ..
            "- Non-negative material value.\n" ..
            "- Carries at least one usability flag (ITEMS_METAL, ITEMS_WEAPON, " ..
            "  ITEMS_ARMOR, ITEMS_HARD, etc.).\n" ..
            "- Not flagged DIVINE or MYTHICAL (excluded by default).\n\n" ..
            "CONFIGURING BASE METALS\n" ..
            "Open the Base Metals panel from the main nav. The list shows all valid " ..
            "bases in your world. Hover any entry to view its raw inorganic data. " ..
            "Select metals and press G to save. Changing the selection cancels " ..
            "active Refinish Metal jobs and triggers a full data cycle.\n\n" ..
            "Each active base generates its own independent category tree and " ..
            "reaction set in the workshop menus. Multiple active bases multiply " ..
            "the total reaction and material count. Keep this in mind for " ..
            "performance when Material Finishes is enabled."
    },

    -- ----------------------------------------
    -- GRINDING DUST
    -- ----------------------------------------
    {
        id       = "grinding",
        title    = "Grinding Dust",
        keywords = {"grind", "dust", "powder", "bag", "mason", "jeweler", "forge", "stone", "gem", "metal", "yield", "reagent"},
        text     =
            "Dust is the reagent that determines the color and nomenclature of the " ..
            "finished bar. Every grinding job requires one empty bag. The workshop " ..
            "and skill used depend on the source material.\n\n" ..
            "STONE  |  Mason's Workshop  |  Masonry skill\n" ..
            "- 'Grind common stone': processes non-economic boulders.\n" ..
            "- 'Grind any stone': same, but also allows economic stones without " ..
            "  adjusting the economic stone menu.\n" ..
            "- Yield: 1 boulder -> 4 units of dust, stored in 1 bag.\n\n" ..
            "GEMS  |  Jeweler's Workshop  |  Gem Cutting skill\n" ..
            "- Processes rough gems only.\n" ..
            "- Yield: 3 rough gems -> 1 unit of dust, stored in 1 bag.\n\n" ..
            "METALS  |  Any Forge or Magma Forge  |  Metalcraft skill\n" ..
            "- Processes metal bars.\n" ..
            "- Yield: 1 bar -> 1 unit of dust, stored in 1 bag.\n\n" ..
            "REAGENT VALIDATION\n" ..
            "Not every inorganic qualifies. The scanner evaluates all world " ..
            "inorganics at startup and rejects any that fail the following:\n" ..
            "- Must be typed IS_STONE, IS_METAL, IS_GEM, SOIL_ANY, or SOIL_SAND.\n" ..
            "- IS_METAL reagents must also have a valid production path " ..
            "  (ghost metals are excluded).\n" ..
            "- Must be thermally stable (not liquid or gaseous at normal temps).\n" ..
            "- Powder state name must not already describe a granular material " ..
            "  ('sand', 'dust', 'powder', 'ash', 'dirt').\n" ..
            "SAFETY PROTOCOLS\n" ..
            "Dwarves will refuse to grind bars of any active base metal " ..
            "(configurable) and will never grind already-finished bars (hardcoded). " ..
            "Either results in job cancellation and an announcement."
    },

    -- ----------------------------------------
    -- FINISHING BARS
    -- ----------------------------------------
    {
        id       = "finishing",
        title    = "Finishing Bars",
        keywords = {"finish", "smelter", "combine", "coat", "bar", "reaction", "refine", "produce", "output"},
        text     =
            "All finishing reactions take place at a standard Smelter or Magma " ..
            "Smelter. The output is a finished bar; a clone of the base metal " ..
            "with its color, name, and material value overwritten.\n\n" ..
            "REACTION INPUTS\n" ..
            "- 1 unit of dust (from a bag)\n" ..
            "- 3 bars of the relevant base metal\n\n" ..
            "REACTION OUTPUT\n" ..
            "- 3 finished bars\n\n" ..
            "FINISH TIERS\n" ..
            "1. Colour Finish: always available. Groups reagents by color and " ..
            "   value tier. Two reagents with the same color and similar value " ..
            "   may produce the same finish (e.g. 'red steel'). Minimizes RAM.\n\n" ..
            "2. Special Finish: always available. Hardcoded overrides for " ..
            "   significant materials. Examples:\n" ..
            "   gold -> 'gilded [base]', iron -> 'ironclad [base]',\n" ..
            "   zinc -> 'galvanized [base]', adamantine -> 'adamantinized [base]'.\n" ..
            "   40+ prefixes defined. Always generated regardless of the Material " ..
            "   Finishes toggle.\n\n" ..
            "3. Material Finish: toggleable in settings. A strict 1:1 named finish " ..
            "   per validated reagent (e.g. 'obsidian steel'). Most diverse and " ..
            "   most memory-intensive. Toggling off preserves archived data in JSON."
    },

    -- ----------------------------------------
    -- VALUE & ECONOMICS
    -- ----------------------------------------
    {
        id       = "economics",
        title    = "Value & Economics",
        keywords = {"value", "worth", "economics", "wealth", "math", "price", "conservation", "material value", "mv"},
        text     =
            "The value of a finished bar is the base metal's material value plus " ..
            "a weighted contribution from the reagent. The base metal's value is " ..
            "the floor. It is not replaced, only added to.\n\n" ..
            "All values are read from your world's live data on every load, so " ..
            "economy-altering mods are automatically reflected.\n\n" ..
            "REAGENT VALUE CONTRIBUTION\n" ..
            "One dust unit finishes 3 bars, so each bar absorbs a share:\n\n" ..
            "- Stone:  +floor(boulder value / 12) per bar\n" ..
            "  (1 boulder -> 4 dust units; each finishes 3 bars)\n\n" ..
            "- Metal:  +floor(bar value / 3) per bar\n" ..
            "  (1 bar -> 1 dust unit; finishes 3 bars)\n\n" ..
            "- Gem:    +full rough gem value per bar\n" ..
            "  (3 gems -> 1 dust unit; finishes 3 bars)\n\n" ..
            "This preserves value conservation: the total economic contribution " ..
            "of the input reagents is fully distributed across the output bars.\n\n" ..
            "Note: because the base metal's own value forms the floor, higher-value " ..
            "bases (e.g. platinum, adamantine) produce inherently more valuable " ..
            "finished bars than lower-value bases for the same reagent."
    },

    -- ----------------------------------------
    -- SAVING SAFELY
    -- ----------------------------------------
    {
        id       = "saving",
        title    = "Saving Safely",
        keywords = {"save", "saving", "corrupt", "corruption", "manual", "esc", "options", "overlay", "red", "green", "continue", "quit", "race"},
        text     =
            "Refinish Metal data must be purged from RAM before the engine writes " ..
            "to disk. Saving with active mod data in memory will corrupt the save.\n\n" ..
            "THE WARNING OVERLAY\n" ..
            "When you open the ESC/Options menu, an overlay shows current state:\n" ..
            "- RED:   Data is active in RAM. Do NOT save.\n" ..
            "- GREEN: Memory is washed. Safe to save.\n\n" ..
            "SAFE SAVE METHODS\n" ..
            "- Autosave (automatic): fully managed, always safe.\n" ..
            "- Quicksave hotkey (Ctrl-Shift-S): triggers the full autosave routine.\n" ..
            "- Manual save: with Menu-Bound Cycling on AUTO, open ESC and wait for " ..
            "  GREEN, then save. Or manually purge (Ctrl-Shift-X), wait for GREEN.\n\n" ..
            "RISKY METHODS\n" ..
            "- Save & Continue: NEVER use while RED. The engine does not trigger " ..
            "  a map unload, so the mod's automatic shutdown does not fire. " ..
            "  Corruption is guaranteed.\n" ..
            "- Save & Quit: triggers a map unload and fires the shutdown sequence, " ..
            "  but a race condition between the engine write and the RAM purge " ..
            "  makes this unreliable. Not recommended.\n\n" ..
            "GOLDEN RULE: always wait for GREEN before any manual save."
    },

    -- ----------------------------------------
    -- AUTOSAVE ROUTINE
    -- ----------------------------------------
    {
        id       = "autosave",
        title    = "Autosave Routine",
        keywords = {"autosave", "quicksave", "routine", "cycle", "pause", "purge", "buffer", "telemetry", "interval"},
        text     =
            "Refinish Metal fully replaces the vanilla autosave. The vanilla " ..
            "autosave is disabled (set to -1) at boot.\n\n" ..
            "AUTOSAVE SEQUENCE\n" ..
            "1. Interval reached (or Ctrl-Shift-S pressed).\n" ..
            "2. Game is paused (configurable, recommended to leave enabled).\n" ..
            "3. All custom-finish items and buildings are reverted to their base " ..
            "   metal; IDs and finish data are written to the JSON payload.\n" ..
            "4. Custom materials, reactions, and permissions are deleted from RAM.\n" ..
            "5. Physical scan confirms memory is 100% clear before proceeding. " ..
            "   Re-scans every 10 frames until clean (the 'Reality Check' buffer). " ..
            "   The save will not issue until this passes.\n" ..
            "6. Native quicksave is issued.\n" ..
            "7. Mod stays dormant. On the player's next unpause, the full startup " ..
            "   sequence runs and restores all finishes from the payload.\n\n" ..
            "AUTOSAVE INTERVALS\n" ..
            "Configurable in System Settings (Ctrl-Shift-C): Seasonal, Semi-Annual, " ..
            "Yearly, or real-time intervals (15, 30, 60 min). Can be disabled.\n\n" ..
            "TELEMETRY\n" ..
            "In Guided or Debug mode, a post-save report shows exact timing and " ..
            "item/building counts per phase of the cycle."
    },

    -- ----------------------------------------
    -- SYSTEM CONFIGURATION
    -- ----------------------------------------
    {
        id       = "configuration",
        title    = "System Configuration",
        keywords = {"config", "settings", "options", "hotkey", "rebind", "invasiveness", "delay", "performance", "material finishes", "menu bound", "cycling", "protect steel", "defaults"},
        text     =
            "Open System Settings with Ctrl-Shift-C (default).\n\n" ..
            "AUTOSAVE\n" ..
            "- Interval: Seasonal / Semi-Annual / Yearly / 15min / 30min / 60min / Off.\n" ..
            "- Pause on autosave: toggle. Recommended ON.\n\n" ..
            "MENU-BOUND DATA CYCLING\n" ..
            "- AUTO: purges mod data when ESC menu opens; reloads on close. Safest.\n" ..
            "- MANUAL: data stays loaded. Faster for developed forts with large " ..
            "  finish counts, but requires manual purge before any vanilla save.\n\n" ..
            "STARTUP LOAD DELAY\n" ..
            "- Tick (default): injects data after the first unpause. Safest.\n" ..
            "- Frames / Instant: injects while paused. Use only if needed.\n\n" ..
            "MATERIAL FINISHES\n" ..
            "- ON: generates a 1:1 named finish for every validated reagent.\n" ..
            "- OFF: colour and special finishes only. Significantly lower RAM usage.\n" ..
            "  Toggling mid-game cancels active jobs and triggers a full data cycle. " ..
            "  Existing material finish data is preserved in the JSON payload.\n\n" ..
            "SYSTEM INVASIVENESS\n" ..
            "- Guided: confirmation prompts and guardrails (default).\n" ..
            "- Passive: announcements only, no interruptions.\n" ..
            "- Silent: suppresses non-critical notifications.\n" ..
            "- Debug: adds timing data and diagnostic output.\n\n" ..
            "PROTECT BASE METAL FROM GRINDERS\n" ..
            "- Prevents dwarves from grinding bars of any active base metal.\n\n" ..
            "HOTKEYS\n" ..
            "All seven global hotkeys are rebindable from this panel. A 'Restore " ..
            "Defaults' button reverts all settings and bindings instantly."
    },

    -- ----------------------------------------
    -- MANUAL SHUTDOWN & HARD SHUTDOWN
    -- ----------------------------------------
    {
        id       = "shutdown",
        title    = "Shutdown Commands",
        keywords = {"shutdown", "wipe", "purge", "unload", "manual", "hard", "mem wipe", "cancel jobs", "ghosting", "ctrl shift x", "ctrl shift q"},
        text     =
            "MANUAL SHUTDOWN  (Ctrl-Shift-X default)\n" ..
            "Purges all mod data from RAM: reverts finished items to their base " ..
            "metal, writes the JSON payload, and clears custom materials, reactions, " ..
            "and entity permissions from the engine arrays. Use before any manual save.\n\n" ..
            "HARD SHUTDOWN  (Ctrl-Shift-Q default)\n" ..
            "Same purge as Manual Shutdown, but first sweeps the map for active " ..
            "Refinish Metal workshop jobs and forcefully cancels them.\n\n" ..
            "WHY USE HARD SHUTDOWN?\n" ..
            "Deleting reaction arrays while a dwarf is mid-task on a grinding or " ..
            "finishing job can leave the engine in an inconsistent state. Canceling " ..
            "those jobs first lets the engine reset the dwarf's AI cleanly. " ..
            "Use Hard Shutdown when:\n" ..
            "- Dwarves are actively working grinding or finishing orders.\n" ..
            "- You are purging during unpaused gameplay.\n\n" ..
            "Hard Shutdown is also triggered automatically when the Material Finishes " ..
            "setting or the active Base Metals selection is changed mid-game."
    },

    -- ----------------------------------------
    -- COMPATIBILITY
    -- ----------------------------------------
    {
        id       = "compatibility",
        title    = "Compatibility",
        keywords = {"compatible", "compatibility", "modpack", "mods", "load order", "rawless", "argmod", "aaco", "metallic", "caldfir", "amnesia", "architecture", "wall", "floor", "jit", "menu clutter"},
        text     =
            "Refinish Metal is rawless and hotloads after all raw mods finish their " ..
            "load order. Because it reads live world data, it is compatible with " ..
            "mods that add materials, alter values, or change colors.\n\n" ..
            "KNOWN COMPATIBLE\n" ..
            "- ArgMOD (new materials, value/property changes)\n" ..
            "- AACO (economy alterations)\n" ..
            "- Caldfir's Metallic (color changes and additions)\n" ..
            "- Any mod that does not trigger its own save routines and does not " ..
            "  alter inorganic array index order after the world has loaded.\n\n" ..
            "KNOWN INCOMPATIBLE\n" ..
            "- Mods that run their own autosave or manual save routines. These write " ..
            "  to disk without cycling Refinish Metal data out, causing corruption. " ..
            "  No workaround unless those mods call the Refinish Metal shutdown first.\n\n" ..
            "AMNESIA SYNC\n" ..
            "If a dwarf builds a wall using a finished bar while mod data is dormant " ..
            "(e.g. during a Menu-Bound purge session), the wall defaults to the base " ..
            "metal. On next reload, the Amnesia Sync protocol cross-references the " ..
            "JSON payload and force-syncs affected walls and auto-generated floors " ..
            "to the correct finish.\n\n" ..
            "MENU CLUTTER (JIT)\n" ..
            "Grinding reactions are compiled Just-In-Time. A background watcher " ..
            "intercepts each dwarf as they begin a generic grind order, identifies " ..
            "the specific item in hand, and injects a correctly named ghost reaction " ..
            "on the fly. Workshop menus stay clean regardless of how many reagents " ..
            "or base metals are active."
    },

    -- ----------------------------------------
    -- STATUS DASHBOARD
    -- ----------------------------------------
    {
        id       = "status",
        title    = "Status Dashboard",
        keywords = {"status", "dashboard", "monitor", "health", "memory", "ram", "blueprint", "background", "tripwire", "watcher", "ping"},
        text     =
            "Open the Status Dashboard with Ctrl-Shift-I (default).\n\n" ..
            "SYSTEM STATE\n" ..
            "Shows whether mod data is currently active in RAM or washed. Displays " ..
            "live timestamps from the three background monitors: UI Tripwire, " ..
            "Autosave Loop, and JIT Job Watcher.\n\n" ..
            "LIVE MEMORY COUNTS\n" ..
            "Real-time counts of injected custom materials, reactions, UI category " ..
            "groups, and civilization workshop permissions in the engine's C++ arrays. " ..
            "Also shows whether the Blueprint cache is live or cleared.\n\n" ..
            "OBJECT INSPECTOR  (experimental)\n" ..
            "Search any game object by ID, name, or map coordinates " ..
            "(e.g. 'STEEL', 'SWORD', 'GRIND', '142,45,1'). Scans inorganics, " ..
            "reactions, entities, items, buildings, constructions, and active jobs. " ..
            "Currently most useful for materials and reactions.\n\n" ..
            "MEMORY SHEETS\n" ..
            "Selecting a result attempts to generate a stat sheet from live C++ " ..
            "memory. Materials show base properties, temperature data, active flags, " ..
            "and full combat physics (yield/fracture/strain across all force types). " ..
            "Reactions show workshop permissions, reagents, and products. Map objects " ..
            "show coordinates and active material composition.\n" ..
            "A hotkey bridge to DFHack's native gm-editor is available per object.\n\n" ..
            "Note: memory sheet reads are experimental and wrapped in protected calls. " ..
            "Failed reads fail silently rather than crashing."
    },

    -- ----------------------------------------
    -- CIVILIZATION DASHBOARD
    -- ----------------------------------------
    {
        id       = "civilizations",
        title    = "Civilization Dashboard",
        keywords = {"civ", "civilization", "tech", "roster", "forge", "mason", "gem", "smelting", "alloying", "known metals", "entity", "race"},
        text     =
            "The Civilization Dashboard is accessible from the main panel nav. " ..
            "It shows tech capability and Refinish Metal access data for every " ..
            "civilization in the world, derived from the blueprint's civ tech cache.\n\n" ..
            "CIV LIST\n" ..
            "- LOCAL: your active fortress civilization, shown first.\n" ..
            "- GLOBAL: a summary roster of all currently filtered civs.\n" ..
            "- Individual civs: listed alphabetically. Entries matching your civ's " ..
            "  entity class are highlighted.\n\n" ..
            "DOSSIER PANEL\n" ..
            "Selecting a civ shows its tech flags (forging, stoneworking, gem-cutting), " ..
            "its approved smelting and alloying metals, and the count of Refinish " ..
            "Metal finishing reactions available to that civilization.\n\n" ..
            "FILTERS\n" ..
            "- Toggle unskilled civs (no forge/mason/gem tech) on/off.\n" ..
            "- Toggle unknown civs (unresolved name or raw code) on/off.\n" ..
            "- Search by name, race adjective, or entity class.\n\n" ..
            "BASE METALS PANEL\n" ..
            "The Base Metals panel lists every metal in your world that passes " ..
            "validation. Hover any entry to view its raw inorganic data. Select " ..
            "metals and press G to save; this triggers a full data cycle."
    },

    -- ----------------------------------------
    -- LOGGING & DIAGNOSTICS
    -- ----------------------------------------
    {
        id       = "logging",
        title    = "Logging & Diagnostics",
        keywords = {"log", "event", "debug", "dump", "export", "session", "troubleshoot", "telemetry", "diagnostic", "txt", "file"},
        text     =
            "LIVE EVENT LOG\n" ..
            "Accessible from the main panel. Displays the in-memory event log, " ..
            "newest events at the bottom. Capped at 5,000 lines.\n" ..
            "- C: clear the live feed (RAM only; the disk log is unaffected).\n" ..
            "- E: export a timestamped snapshot to a permanent file.\n\n" ..
            "SESSION LOG FILES\n" ..
            "All events are written in real time to 'refinish_session.log' in the " ..
            "DF directory. On each new DF launch, the previous session log is " ..
            "renamed to 'refinish_last_session.log'. You always have the current " ..
            "session and one prior on disk.\n\n" ..
            "MASTER DIAGNOSTIC DUMP\n" ..
            "Exports 'refinish_debug.txt': a structural snapshot of the mod's " ..
            "memory state at the moment of export. Covers:\n" ..
            "- System state and all configuration values.\n" ..
            "- Raw inorganic sweep: accepted reagents and reasons for rejections.\n" ..
            "- Blueprint RAM dump: the full material and reaction cache.\n" ..
            "- JSON payload audit: item/building counts and archived finish data.\n" ..
            "- Civ tech permission cache: per-race tech and metal access data.\n\n" ..
            "Use the dump when verifying load order behavior, investigating economy " ..
            "discrepancies, or reporting issues."
    },

    -- ----------------------------------------
    -- DEFAULT HOTKEYS
    -- ----------------------------------------
    {
        id       = "hotkeys",
        title    = "Default Hotkeys",
        keywords = {"hotkey", "keybind", "shortcut", "ctrl", "shift", "key", "binding", "rebind"},
        text     =
            "All hotkeys are rebindable in System Settings (Ctrl-Shift-C).\n\n" ..
            "Ctrl-Shift-C  |  Open System Settings / Config\n" ..
            "Ctrl-Shift-I  |  Open Status Dashboard & Inspector\n" ..
            "Ctrl-Shift-S  |  Quicksave (full autosave routine)\n" ..
            "Ctrl-Shift-X  |  Manual Shutdown (purge RAM)\n" ..
            "Ctrl-Shift-Q  |  Hard Shutdown (cancel jobs, then purge RAM)\n" ..
            "Ctrl-Shift-R  |  Manual Startup (reinject data)\n" ..
            "Ctrl-Shift-H  |  Open Help / Search Documentation\n\n" ..
            "Within the Help panel, pressing Ctrl-Shift-H opens the search prompt. " ..
            "Enter any keyword or topic name to filter the topic list. " ..
            "Leave the field blank and press Enter to clear the filter."
    }

}

-- ==========================================
-- UI: HELP PANEL (LEFT ROUTER MODULAR PAGE)
-- ==========================================
RefinishPanelHelp = defclass(RefinishPanelHelp, widgets.Panel)
RefinishPanelHelp.ATTRS = { theme = DEFAULT_NIL }

function RefinishPanelHelp:init()
    self.theme = self.theme or reqscript('refinish-theme').get_current_theme()
    
    -- Panel init log removed: init() fires on every HUD construction,
    -- not just when the user navigates to this panel.

    local function make_key_label(key_token, label_text, pen_label)
        local key_str = dfhack.screen.getKeyDisplay(df.interface_key[key_token])
        return {
            {text = key_str, pen = self.theme.PRI},
            {text = ": " .. label_text, pen = pen_label}
        }
    end

    self.actions = {
        CUSTOM_CTRL_I = function() self:prompt_search() end
    }
    
    self.active_choices = self:build_list_choices("") 

    self.content_list = widgets.List{
        frame = {t = 0, l = 0, r = 0, b = 0},
        choices = {"Loading..."},
        text_pen = self.theme.PRI,
        cursor_pen = self.theme.PRI, 
    }

    self.topic_list = widgets.List{
        frame = {t = 0, l = 0, r = 0, b = 0},
        choices = self.active_choices,
        text_pen = self.theme.SEC,
        cursor_pen = self.theme.PRI,
        on_select = function(idx, choice)
            if choice and choice.data and self.content_list then
                -- Width set to 46 to prevent text from overlapping the scrollbar margin
                local wrapped_lines = wrap_help_text(choice.data.text, 46)
                self.content_list:setChoices(wrapped_lines)
            end
        end
    }

    self.btn_search = widgets.Label{
        frame = {b = 0, l = 0},
        text = make_key_label('CUSTOM_CTRL_I', 'Search Help', self.theme.SEC),
        on_click = self.actions.CUSTOM_CTRL_I
    }

    self:addviews{
        widgets.Label{ frame = {t = 0, l = 0}, text = "SYSTEM DOCUMENTATION", text_pen = self.theme.PRI },
        
        widgets.Panel{
            frame = {t = 2, l = 0, w = 22, b = 2},
            subviews = { self.topic_list }
        },

        widgets.Label{ 
            frame = {t = 2, l = 23, w = 1, b = 2},
            text = "", 
            frame_background = self.theme.PRI
        },
        
        widgets.Panel{
            frame = {t = 2, l = 25, r = 0, b = 2},
            subviews = { self.content_list }
        },
        
        widgets.Panel{
            frame = {b = 0, l = 0, r = 0, h = 1, w = 19},
            subviews = { self.btn_search }
        }
    }

    if #self.active_choices > 0 then
        self.topic_list:setSelected(1)
        local initial_wrapped = wrap_help_text(self.active_choices[1].data.text, 46)
        self.content_list:setChoices(initial_wrapped)
    end
end

function RefinishPanelHelp:onInput(keys)
    for key_name, action in pairs(self.actions) do
        if keys[key_name] then
            action()
            return true
        end
    end
    return RefinishPanelHelp.super.onInput(self, keys)
end

-- ==========================================
-- SEARCH & FILTER LOGIC
-- Matches query against topic title and all keywords (case-insensitive).
-- Empty query returns all topics.
-- ==========================================
function RefinishPanelHelp:build_list_choices(query)
    local choices = {}
    local q_lower = query and string.lower(query) or ""

    for _, topic in ipairs(HELP_TOPICS) do
        local match = false
        if q_lower == "" then
            match = true
        else
            if string.find(string.lower(topic.title), q_lower, 1, true) then
                match = true
            else
                for _, kw in ipairs(topic.keywords) do
                    if string.find(string.lower(kw), q_lower, 1, true) then
                        match = true
                        break
                    end
                end
            end
        end

        if match then
            table.insert(choices, { text = topic.title, data = topic })
        end
    end

    if #choices == 0 then
        table.insert(choices, { text = "No results", data = { title = "No Results", text = "No help topics match your search query." } })
    end

    return choices
end

function RefinishPanelHelp:update_list(query)
    self.active_choices = self:build_list_choices(query)
    self.topic_list:setChoices(self.active_choices)
    
    if #self.active_choices > 0 then
        self.topic_list:setSelected(1)
        local updated_wrapped = wrap_help_text(self.active_choices[1].data.text, 46)
        self.content_list:setChoices(updated_wrapped)
    end
end

function RefinishPanelHelp:prompt_search()
    dialogs.showInputPrompt(
        "Search Documentation", 
        "Enter a keyword or topic. Leave blank and press Enter to clear:", 
        self.theme.SEC, 
        "", 
        function(query)
            if not query or query == "" then
                -- DETAIL: search tracking is only useful when debugging
                -- the panel itself.
                log('DETAIL', 'Search cleared.', 'SEARCH')
                self:update_list("")
            else
                log('DETAIL', "Searched for '" .. tostring(query) .. "'.",
                    'SEARCH')
                self:update_list(query)
            end
        end
    )
end

return _ENV