--@ module = true
-- refinish-panel-metals.lua
-- ==========================================
-- BASE METALS EVALUATION 
-- ==========================================
local gui = require('gui')
local widgets = require('gui.widgets')
local dialogs = require('gui.dialogs')
local json = require('json')
local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt

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
-- SUBJECT is the correlation slot: what about the base metals a line
-- concerns. Nil renders as a dash.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
--
-- No console prints. A print only appears as the direct answer to a
-- command typed into the DFHack console, and nowhere else, so
-- anything this file needs to say lives in the log alone.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'BASE_METALS'
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

RefinishPanelMetals = defclass(RefinishPanelMetals, widgets.Panel)
RefinishPanelMetals.ATTRS = { theme = DEFAULT_NIL }

function RefinishPanelMetals:init()
    self.theme = self.theme or reqscript('refinish-theme').get_current_theme()
    self.last_hover_idx = -1 

    local function make_key_label(key_token, label_text, pen_label)
        local key_str = dfhack.screen.getKeyDisplay(df.interface_key[key_token])
        return {
            {text = key_str, pen = self.theme.PRI},
            {text = function() 
                local text_val = type(label_text) == 'function' and label_text() or label_text
                return ": " .. text_val 
            end, pen = pen_label}
        }
    end

    self.actions = {
        CUSTOM_SHIFT_B = function()
            dialogs.showInputPrompt(
                "SEARCH BASE METALS",
                "Enter metal name or ID. Leave blank and press Enter to clear:",
                self.theme.SEC, "", 
                function(text)
                    self.search_text = string.lower(text)
                    self:refresh_list()
                end
            )
        end,
        CUSTOM_SHIFT_A = function()
            for _, base in ipairs(self.current_filtered_list) do 
                if base.has_reaction then
                    self.active_bases[base.id] = true 
                end
            end
            self:refresh_list()
        end,
        CUSTOM_SHIFT_C = function()
            for _, base in ipairs(self.current_filtered_list) do self.active_bases[base.id] = nil end
            self:refresh_list()
        end,
        CUSTOM_SHIFT_H = function()
            self.hide_unavailable = not self.hide_unavailable
            self:refresh_list()
        end,
        CUSTOM_SHIFT_S = function()
            local current_str = json.encode(self.active_bases)
            local disk_str = dfhack.persistent.getSiteData('refinish_config_bases') or ""
            
            if current_str == self.initial_bases_str and current_str == disk_str then
                if _G.refinish_hud_view then _G.refinish_hud_view:dismiss() end
                dfhack.run_script('refinish-hud', 'show', 'metals')
                return
            end

            RefinishPrompt{
                text = "Changing Base Metals will cancel all active jobs involving Refinish Metal materials and trigger a full data cycle.\n\nAre you sure you want to proceed?",
                text_pen = self.theme.PRI,
                on_yes = function()
                    dfhack.persistent.saveSiteData('refinish_config_bases', current_str)
                    self.initial_bases_str = current_str
                    -- INFO: a setting the player changed, and why the data
                    -- cycle that follows ran.
                    log('INFO', 'Base metals updated and saved. Triggering a'
                        .. ' data cycle.', 'SELECTION')
                    
                    dfhack.run_script('refinish-hard-shutdown', 'SILENT')
                    dfhack.run_script('refinish-startup', 'SILENT')
                    
                    local jobs_killed = _G.refinish_last_jobs_canceled or 0
                    _G.refinish_last_jobs_canceled = nil
                    
                    local msg_setting = dfhack.persistent.getSiteData('refinish_config_msg')
                    if not msg_setting or msg_setting == "" then msg_setting = 'GUIDED' end
                    
                    if msg_setting == 'GUIDED' or msg_setting == 'DEBUG' then
                        local debug_txt = ""
                        local prompt_h = 10
                        if msg_setting == 'DEBUG' then
                            debug_txt = "\n\n[DEBUG: Hard shutdown and startup scripts executed silently. " .. jobs_killed .. " jobs canceled.]"
                            prompt_h = 14
                        end
                        RefinishPrompt{
                            frame_h = prompt_h,
                            text = "Base metal parameters updated.\n\nRAM has been successfully cycled and new materials injected." .. debug_txt,
                            text_pen = self.theme.PRI,
                            on_ok = function() 
                                if _G.refinish_hud_view then 
                                    _G.refinish_hud_view:dismiss() 
                                    _G.refinish_hud_view = nil -- THE FIX: Force instant death of the singleton
                                end
                                dfhack.run_script('refinish-hud', 'show', 'metals')
                            end
                        }:show()
                    else
                        if msg_setting == 'PASSIVE' then
                            dfhack.gui.showAnnouncement('Refinish Metal: RAM cycled successfully.', self.theme.PRI, true)
                        end
                        if _G.refinish_hud_view then 
                            _G.refinish_hud_view:dismiss() 
                            _G.refinish_hud_view = nil -- THE FIX: Force instant death of the singleton
                        end
                        dfhack.run_script('refinish-hud', 'show', 'metals')
                    end
                end,
                on_no = function() end
            }:show()
        end,
        CUSTOM_SHIFT_D = function()
            self.active_bases = json.decode(self.initial_bases_str)
            self:refresh_list()
        end
    }

    -- ==========================================
    -- BASE METALS EVALUATION 
    -- ==========================================
    local valid_bases = _G.refinish_valid_bases
    if not valid_bases then
        local eval_bases = reqscript('refinish-bases')
        valid_bases = eval_bases.get_valid_bases()
        _G.refinish_valid_bases = valid_bases
    end

    -- THE FIX: Heavy lifting completely removed. It just reads the launcher's global cache instantly.
    self.known_metals = _G.refinish_known_metals_cache or {}

    local saved_bases_str = dfhack.persistent.getSiteData('refinish_config_bases')
    self.active_bases = {}
    if saved_bases_str and saved_bases_str ~= "" then
        pcall(function() self.active_bases = json.decode(saved_bases_str) end)
    else
        self.active_bases["STEEL"] = true 
    end
    
    self.initial_bases_str = json.encode(self.active_bases)

    self.search_text = ""
    self.hide_unavailable = true
    self.current_filtered_list = {}

-- ==========================================
    -- WIDGET INSTANTIATION
    -- ==========================================
    self.search_widget = widgets.Label{
        frame = {t = 2, l = 0, w = 25},
        text = make_key_label('CUSTOM_SHIFT_B', function() return "Search" .. (self.search_text == "" and "" or ": " .. self.search_text) end, self.theme.SEC),
        on_click = self.actions.CUSTOM_SHIFT_B
    }

    self.list_widget = widgets.List{
        frame = {t = 4, l = 0, w = 25, b = 2},
        text_pen = self.theme.SEC,
        on_submit = function(idx, choice)
            local id = choice.data.id
            if not choice.data.has_reaction then return end 
            self.active_bases[id] = not self.active_bases[id]
            self:refresh_list()
        end,
    }

    self.btn_select_all = widgets.Label{
        frame = {b = 0, l = 0, w = 13},
        text = make_key_label('CUSTOM_SHIFT_A', 'Select All', self.theme.SEC),
        on_click = self.actions.CUSTOM_SHIFT_A
    }

    self.btn_clear_all = widgets.Label{
        frame = {b = 0, l = 16, w = 12},
        text = make_key_label('CUSTOM_SHIFT_C', 'Clear All', self.theme.SEC),
        on_click = self.actions.CUSTOM_SHIFT_C
    }

    self.btn_toggle_avail = widgets.Label{
        frame = {b = 0, l = 31, w = 8},
        text = make_key_label('CUSTOM_SHIFT_H', function() return self.hide_unavailable and "Show*" or "Hide*" end, self.theme.SEC),
        on_click = self.actions.CUSTOM_SHIFT_H
    }

    self.btn_save = widgets.Label{
        frame = {b = 0, l = 57, w = 7},
        text = make_key_label('CUSTOM_SHIFT_S', 'Save', self.theme.SEC),
        on_click = self.actions.CUSTOM_SHIFT_S
    }

    self.btn_discard = widgets.Label{
        frame = {b = 0, l = 67, w = 10},
        text = make_key_label('CUSTOM_SHIFT_D', 'Discard', self.theme.SEC),
        on_click = self.actions.CUSTOM_SHIFT_D
    }

    self.default_info_text = "GLOBAL BASE METAL CONFIGURATION\n\nChoose which metals Refinish Metal will recognize as valid base materials.\n\nHover over a metal in the list to view its raw data.]"
    
    self.info_panel = widgets.Panel{
        frame = {t = 0, l = 26, r = 1},
        subviews = {
            widgets.Label{ view_id = 'tt_header', frame = {t=0, l=0}, text_pen = self.theme.PRI, text = self.default_info_text },
            
            -- CORE
            widgets.Label{ view_id = 'c_val',   frame = {t=2, l=0},  text = "" },
            widgets.Label{ view_id = 'c_col',   frame = {t=2, l=20}, text = "" },
            widgets.Label{ view_id = 'c_sdens', frame = {t=3, l=0},  text = "" },
            widgets.Label{ view_id = 'c_ldens', frame = {t=3, l=20}, text = "" },
            widgets.Label{ view_id = 'c_molar', frame = {t=4, l=0},  text = "" },
            widgets.Label{ view_id = 'c_edge',  frame = {t=4, l=20}, text = "" },
            
            -- HEAT
            widgets.Label{ view_id = 'h_hdr',   frame = {t=6, l=0},  text = "", text_pen = self.theme.NEUTRAL_B },
            widgets.Label{ view_id = 'h_spec',  frame = {t=8, l=0},  text = "" },
            widgets.Label{ view_id = 'h_ign',   frame = {t=8, l=20}, text = "" },
            widgets.Label{ view_id = 'h_melt',  frame = {t=9, l=0},  text = "" },
            widgets.Label{ view_id = 'h_boil',  frame = {t=9, l=20}, text = "" },
            widgets.Label{ view_id = 'h_hdam',  frame = {t=10, l=0},  text = "" },
            widgets.Label{ view_id = 'h_cdam',  frame = {t=10, l=20}, text = "" },
            widgets.Label{ view_id = 'h_fix',   frame = {t=11, l=0}, text = "" },

            -- YIELD
            widgets.Label{ view_id = 'y_hdr',   frame = {t=13, l=0}, text = "", text_pen = self.theme.NEUTRAL_B },
            widgets.Label{ view_id = 'y_imp',   frame = {t=15, l=0}, text = "" },
            widgets.Label{ view_id = 'y_cmp',   frame = {t=15, l=20}, text = "" },
            widgets.Label{ view_id = 'y_ten',   frame = {t=16, l=0}, text = "" },
            widgets.Label{ view_id = 'y_tor',   frame = {t=16, l=20}, text = "" },
            widgets.Label{ view_id = 'y_shr',   frame = {t=17, l=0}, text = "" },
            widgets.Label{ view_id = 'y_bnd',   frame = {t=17, l=20}, text = "" },

            -- FRACTURE
            widgets.Label{ view_id = 'f_hdr',   frame = {t=19, l=0}, text = "", text_pen = self.theme.NEUTRAL_B },
            widgets.Label{ view_id = 'f_imp',   frame = {t=21, l=0}, text = "" },
            widgets.Label{ view_id = 'f_cmp',   frame = {t=21, l=20}, text = "" },
            widgets.Label{ view_id = 'f_ten',   frame = {t=22, l=0}, text = "" },
            widgets.Label{ view_id = 'f_tor',   frame = {t=22, l=20}, text = "" },
            widgets.Label{ view_id = 'f_shr',   frame = {t=23, l=0}, text = "" },
            widgets.Label{ view_id = 'f_bnd',   frame = {t=23, l=20}, text = "" },

            -- STRAIN
            widgets.Label{ view_id = 's_hdr',   frame = {t=25, l=0}, text = "", text_pen = self.theme.NEUTRAL_B },
            widgets.Label{ view_id = 's_imp',   frame = {t=27, l=0}, text = "" },
            widgets.Label{ view_id = 's_cmp',   frame = {t=27, l=20}, text = "" },
            widgets.Label{ view_id = 's_ten',   frame = {t=28, l=0}, text = "" },
            widgets.Label{ view_id = 's_tor',   frame = {t=28, l=20}, text = "" },
            widgets.Label{ view_id = 's_shr',   frame = {t=29, l=0}, text = "" },
            widgets.Label{ view_id = 's_bnd',   frame = {t=29, l=20}, text = "" },

            -- FLAGS
            widgets.Label{ view_id = 'fl_hdr',  frame = {t=32, l=0}, text = "", text_pen = self.theme.NEUTRAL_B },
            widgets.Label{ view_id = 'fl_txt',  frame = {t=34, l=0}, text = "", text_pen = self.theme.PRI },
        }
    }

    self:addviews{
        widgets.Label{ frame = {t = 0, l = 0}, text = "BASE METALS", text_pen = self.theme.PRI },
        self.search_widget, self.list_widget,
        self.btn_select_all, self.btn_clear_all, self.btn_toggle_avail,
        self.btn_save, self.btn_discard,
        self.info_panel
    }

    self:refresh_list()
end

function RefinishPanelMetals:onInput(keys)
    for key_name, action in pairs(self.actions) do
        if keys[key_name] then
            action()
            return true
        end
    end
    return RefinishPanelMetals.super.onInput(self, keys)
end

function RefinishPanelMetals:update_tooltip(base)
    local p = self.info_panel.subviews
    if not base then
        -- Clear all sub-labels first to give us a blank canvas
        for k, v in pairs(p) do
            v:setText("")
        end
        
        -- Default Empty State: Title (SEC) and Body (PRI)
        p.tt_header:setText({ {text = "GLOBAL BASE METAL CONFIGURATION", pen = self.theme.PRI} })
        
        -- Use gui.NEWLINE to correctly break lines without printing ASCII 10 characters
        p.c_val:setText({ 
            {text = "  Selections to the left activate base metals for", pen = self.theme.SEC}, gui.NEWLINE,
            {text = "finishing asset generation and permissions worldwide.", pen = self.theme.SEC}, gui.NEWLINE, gui.NEWLINE,

            {text = "  Hover over any metal in the list to view its raw", pen = self.theme.SEC}, gui.NEWLINE,
            {text = "data. Be advised, the higher the quantity of base", pen = self.theme.SEC}, gui.NEWLINE,
            {text = "metals you have loaded, the more processing is", pen = self.theme.SEC}, gui.NEWLINE,
            {text = "required to generate and inject assets during the", pen = self.theme.SEC}, gui.NEWLINE,
            {text = "data cycle (while saving, with menu-bound data", pen = self.theme.SEC}, gui.NEWLINE,
            {text = "cycling config active, etc). This can lead to", pen = self.theme.SEC}, gui.NEWLINE,
            {text = "increased load times.", pen = self.theme.SEC}, gui.NEWLINE, gui.NEWLINE,

            {text = "  Selected items will be highlighted, but selections", pen = self.theme.SEC}, gui.NEWLINE,
            {text = "will not be saved and processed into ram until you", pen = self.theme.SEC}, gui.NEWLINE,
            {text = "save your settings using the button or hotkey (G)", pen = self.theme.SEC}, gui.NEWLINE,
            {text = "found below (this will trigger a data cycle).", pen = self.theme.SEC}, gui.NEWLINE, gui.NEWLINE,

            {text = "  Selections which are available globally but not", pen = self.theme.SEC}, gui.NEWLINE,
            {text = " available to your current civilization will be", pen = self.theme.SEC}, gui.NEWLINE,
            {text = "found at the bottom of your selection list in a", pen = self.theme.SEC}, gui.NEWLINE,
            {text = "different colour.", pen = self.theme.SEC}, gui.NEWLINE, gui.NEWLINE, 

            {text = "  You can also click on the Show* button (F) to reveal", pen = self.theme.SEC}, gui.NEWLINE,
            {text = "any valid metals Refinish Metal evaluations determined", pen = self.theme.SEC}, gui.NEWLINE,
            {text = "are impossible for any civilization to make. These", pen = self.theme.SEC}, gui.NEWLINE,
            {text = "unavailable metals can't be selected but can be viewed", pen = self.theme.SEC}, gui.NEWLINE,
            {text = "there if needed.", pen = self.theme.SEC},
        })
        return
    end

    -- Active Hover State: Override the title color back to PRI
    p.tt_header:setText({ {text = string.format("%s (%s)", base.name, base.id), pen = self.theme.PRI} })

    local function fmt(lbl, val)
        return { {text = lbl, pen = self.theme.SEC}, {text = val, pen = self.theme.PRI} }
    end

    -- Core
    p.c_val:setText(fmt("Value ", base.value))
    p.c_col:setText(fmt("Color ", base.color_name))
    p.c_sdens:setText(fmt("Solid Dens ", base.solid_dens))
    p.c_ldens:setText(fmt("Liq Dens ", base.liq_dens))
    p.c_molar:setText(fmt("Molar Mass ", base.molar_mass))
    p.c_edge:setText(fmt("Max Edge ", base.max_edge))

    -- Heat
    p.h_hdr:setText("THERMAL")
    p.h_spec:setText(fmt("Spec Heat ", base.heat.spec))
    p.h_ign:setText(fmt("Ignite ", base.heat.ignite))
    p.h_melt:setText(fmt("Melt Pt ", base.heat.melt))
    p.h_boil:setText(fmt("Boil Pt ", base.heat.boil))
    p.h_hdam:setText(fmt("Heat Dam ", base.heat.h_dam))
    p.h_cdam:setText(fmt("Cold Dam ", base.heat.c_dam))
    p.h_fix:setText(fmt("Fixed Tmp ", base.heat.fixed))

    -- Yield
    p.y_hdr:setText("YIELD")
    p.y_imp:setText(fmt("Impact ", base.yield.imp))
    p.y_cmp:setText(fmt("Compress ", base.yield.comp))
    p.y_ten:setText(fmt("Tensile ", base.yield.tens))
    p.y_tor:setText(fmt("Torsion ", base.yield.tors))
    p.y_shr:setText(fmt("Shearing ", base.yield.shear))
    p.y_bnd:setText(fmt("Bending ", base.yield.bend))

    -- Fracture
    p.f_hdr:setText("FRACTURE")
    p.f_imp:setText(fmt("Impact ", base.fracture.imp))
    p.f_cmp:setText(fmt("Compress ", base.fracture.comp))
    p.f_ten:setText(fmt("Tensile ", base.fracture.tens))
    p.f_tor:setText(fmt("Torsion ", base.fracture.tors))
    p.f_shr:setText(fmt("Shearing", base.fracture.shear))
    p.f_bnd:setText(fmt("Bending ", base.fracture.bend))

    -- Strain
    p.s_hdr:setText("STRAIN AT YIELD")
    p.s_imp:setText(fmt("Impact ", base.strain.imp))
    p.s_cmp:setText(fmt("Compress ", base.strain.comp))
    p.s_ten:setText(fmt("Tensile ", base.strain.tens))
    p.s_tor:setText(fmt("Torsion ", base.strain.tors))
    p.s_shr:setText(fmt("Shearing ", base.strain.shear))
    p.s_bnd:setText(fmt("Bending ", base.strain.bend))

    -- Flags
    p.fl_hdr:setText("ACTIVE FLAGS")
    
    local flag_tokens = {}
    for _, line in ipairs(base.flags_lines) do
        table.insert(flag_tokens, {text = line, pen = self.theme.PRI})
        table.insert(flag_tokens, gui.NEWLINE)
    end
    p.fl_txt:setText(flag_tokens)
end

function RefinishPanelMetals:onRenderFrame(painter, rect)
    local current_hover_idx = self.list_widget:getIdxUnderMouse()
    if current_hover_idx ~= self.last_hover_idx then
        self.last_hover_idx = current_hover_idx
        if self.info_panel then
            if current_hover_idx then
                local choice = self.list_widget:getChoices()[current_hover_idx]
                if choice and choice.data then
                    self:update_tooltip(choice.data)
                else
                    self:update_tooltip(nil)
                end
            else
                self:update_tooltip(nil)
            end
            self.info_panel:updateLayout()
        end
    end
    RefinishPanelMetals.super.onRenderFrame(self, painter, rect)
end

function RefinishPanelMetals:refresh_list()
    local choices = {}
    self.current_filtered_list = {}
    local valid_bases = _G.refinish_valid_bases
    if not valid_bases then
        -- get_valid_bases (refinish-bases) returns nil until the
        -- module pipeline has run, so before unpause there is no base
        -- metal list to show. Returning silently leaves an empty box
        -- that reads as a fault. has_reaction is false, so on_submit
        -- at :165 ignores a click on this row.
        self.list_widget:setChoices({
            { text = "Unpause to finish loading", data = { id = "", has_reaction = false } }
        })
        return
    end
    
    for _, base in ipairs(valid_bases) do
        local is_native = self.known_metals[base.id]
        if not self.hide_unavailable or base.has_reaction then
            if self.search_text == "" or string.find(string.lower(base.name), self.search_text) or string.find(string.lower(base.id), self.search_text) then
                table.insert(self.current_filtered_list, base)
                
                local is_active = self.active_bases[base.id]
                local is_native = self.known_metals[base.id]
                
                local prefix = is_active and "[X]" or "[ ]"
                local display_name = base.name
                local color
                
                -- STATE 3: Dead / Physically Invalid (No reaction in the world)
                if not base.has_reaction then
                    prefix = "[-]"
                    color = self.theme.NEUTRAL_S
                    display_name = base.name .. "*"
                    self.active_bases[base.id] = nil 
                    
                -- STATE 2: Culturally Locked (Valid globally, but this civ doesn't know it)
                elseif not is_native then
                    color = is_active and self.theme.NEUTRAL_B or self.theme.NEUTRAL_S
                    
                -- STATE 1: Known and Valid (Your current civ can forge it)
                else
                    color = is_active and self.theme.PRI or self.theme.SEC
                end
                
                table.insert(choices, {
                    text = { {text = string.format("%s %-25s", prefix, display_name), pen = color } },
                    data = base,
                    search_key = string.lower(base.name .. " " .. base.id)
                })
            end
        end
    end
    
    table.sort(choices, function(a, b)
        local a_dead = not a.data.has_reaction
        local b_dead = not b.data.has_reaction
        
        -- 1. Push completely dead/invalid metals to the absolute bottom
        if a_dead and not b_dead then return false end
        if b_dead and not a_dead then return true end
        
        -- 2. Keep Native metals grouped above Non-Native ones
        local a_native = self.known_metals[a.data.id]
        local b_native = self.known_metals[b.data.id]
        if a_native and not b_native then return true end
        if b_native and not a_native then return false end
        
        -- 3. Alphabetical sort within those groups
        return a.data.name < b.data.name
    end)

    self.list_widget:setChoices(choices)
end

return _ENV