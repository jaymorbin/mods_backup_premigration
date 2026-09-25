--@ module = true
-- refinish-panel-civs.lua

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
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'CIV_DASH'
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
-- SAFE NAME TRANSLATION
-- ==========================================
local function safe_translate_name(name_obj)
    if not name_obj then return "" end
    if dfhack.translation and dfhack.translation.translateName then
        return dfhack.translation.translateName(name_obj)
    elseif dfhack.TranslateName then
        return dfhack.TranslateName(name_obj)
    end
    return ""
end

-- ==========================================
-- DATA EXTRACTION ENGINE (PURE CACHE)
-- ==========================================
local function format_race_name(race_str)
    if not race_str or race_str == "" then return "Unknown", false end
    
    -- Convert to Title Case (e.g. "cave swallow man" -> "Cave Swallow Man")
    local title_cased = race_str:gsub("(%a)([%w_']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end)
    
    local is_animal_person = false
    -- If it ends in "man" (and isn't the Human race), make it plural and flag it
    if title_cased:lower():match("man$") and title_cased:lower() ~= "human" then
        title_cased = title_cased:gsub("man$", "men"):gsub("Man$", "Men")
        is_animal_person = true
    end
    
    return title_cased, is_animal_person
end

local function get_civ_data(civ, valid_bases, ui_dict)
    local data = {
        id = civ.id,
        name = "Unknown",
        class = civ.entity_raw and civ.entity_raw.code or "UNKNOWN",
        race_adj = "Unknown",
        is_animal_person = false,
        has_smelter = false,
        has_forge = false,
        has_mason = false,
        has_gem = false,
        rs_finishes = 0,
        rs_stone = false,
        rs_gem = false,
        rs_metal = false,
        rs_grind_metal = false,
        smelting_list = {},
        alloying_list = {},
        rs_list = {}
    }

    if civ.name and civ.name.has_name then
        local translated = safe_translate_name(civ.name)
        if translated and translated ~= "" then
            data.name = translated
        else
            data.name = "Civ ID: " .. tostring(civ.id)
        end
    end

    -- PULL DIRECTLY FROM THE MASTER SCAN CACHE
    local civ_cache = nil
    if _G.refinish_blueprint and _G.refinish_blueprint.civ_tech and civ.entity_raw then
        civ_cache = _G.refinish_blueprint and _G.refinish_blueprint.civ_tech and _G.refinish_blueprint.civ_tech[civ.entity_raw and civ.entity_raw.code]
    end
    
    if civ_cache then
        data.race_adj, data.is_animal_person = format_race_name(civ_cache.race_adj)
        data.has_smelter = civ_cache.has_smelter
        data.has_forge = civ_cache.has_forge
        data.has_mason = civ_cache.has_mason
        data.has_gem   = civ_cache.has_gem
        
        -- The three grinding capabilities, and the one production
        -- capability, are separate questions and must not share a
        -- field.
        --
        --   rs_stone        can grind stone to dust   (MASON)
        --   rs_gem          can grind gems to dust    (JEWELER family)
        --   rs_grind_metal  can grind metal to dust   (METALSMITH family)
        --
        --   rs_metal        can PRODUCE metal bars at all, which
        --                   requires a smelter. This gates the finish
        --                   count further down, and nothing else.
        --
        -- rs_metal used to drive the "Grind metal" line as well, back
        -- when has_forge was what opened the known_metals build. It no
        -- longer is. The result was a civ with a smelter but no smiths
        -- being offered metal grinding while the same panel reported
        -- it had no forging technology. Kobolds are exactly that case.
        data.rs_stone       = civ_cache.stone_tech
        data.rs_gem         = civ_cache.gem_tech
        data.rs_metal       = civ_cache.metal_tech
        data.rs_grind_metal = civ_cache.has_forge
        
        local known_metals = civ_cache.known_metals or {}
        
        for metal_id, _ in pairs(known_metals) do
            if valid_bases[metal_id] then
                local nice_name = ui_dict.metal_names[metal_id] or metal_id
                
                if ui_dict.ore_map[metal_id] then
                    table.insert(data.smelting_list, nice_name)
                else
                    table.insert(data.alloying_list, nice_name)
                end
            end
        end
        
        -- THE FIX: Perfectly mirror the indexer's base-metal-only requirement. 
        if data.rs_metal then
            for base_id, finish_total in pairs(ui_dict.finish_counts) do
                if known_metals[base_id] then
                    local nice_name = ui_dict.metal_names[base_id] or base_id
                    table.insert(data.rs_list, nice_name)
                    data.rs_finishes = data.rs_finishes + finish_total
                end
            end
        end
    end

    table.sort(data.smelting_list)
    table.sort(data.alloying_list)
    table.sort(data.rs_list)

    return data
end

    local function get_global_roster_data(all_civs, theme, hide_unskilled, hide_unknown)
    local tokens = {}
    
    local function pad_right(str, len)
        str = tostring(str)
        if #str > len then 
            -- Truncate back to leave room for '...' and an extra space
            return string.sub(str, 1, len - 4) .. "... " 
        end
        return str .. string.rep(" ", len - #str)
    end

    -- Header Row
    table.insert(tokens, {text = pad_right("CIVILIZATION", 16), pen = theme.NEUTRAL_B})
    table.insert(tokens, {text = pad_right("RACE", 14), pen = theme.NEUTRAL_B})
    table.insert(tokens, {text = pad_right("GRIND", 7), pen = theme.NEUTRAL_B})
    table.insert(tokens, {text = pad_right("SMELT", 7), pen = theme.NEUTRAL_B})
    table.insert(tokens, {text = pad_right("REFINE", 8), pen = theme.NEUTRAL_B})
    table.insert(tokens, {text = pad_right("LIVE", 4), pen = theme.NEUTRAL_B})
    table.insert(tokens, NEWLINE)
    
    -- Divider
    table.insert(tokens, {text = string.rep("-", 84), pen = theme.SEC})
    table.insert(tokens, NEWLINE)
    
    -- Apply UI Filters perfectly matching the navigation list
    local active_civs = {}
    for _, d in ipairs(all_civs) do
        local is_unskilled = not (d.has_forge or d.has_mason or d.has_gem)
        local is_unknown = (d.name == "Unknown" or string.find(d.name, "^Civ ID:"))
        
        if (not hide_unskilled or not is_unskilled) and (not hide_unknown or not is_unknown) then
            table.insert(active_civs, d)
        end
    end
    
    -- Populate the Grid (No truncation)
    for i, d in ipairs(active_civs) do
        local smelt = tostring(#d.smelting_list)
        local alloy = tostring(#d.alloying_list)
        local finishes = d.rs_finishes > 0 and tostring(d.rs_finishes) or "-"
        
        table.insert(tokens, {text = pad_right(d.name, 16), pen = theme.PRI})
        table.insert(tokens, {text = pad_right(d.race_adj, 14), pen = theme.SEC})
        
        table.insert(tokens, {text = (d.has_forge and "M" or "-"), pen = (d.has_forge and theme.PRI or theme.SEC)})
        table.insert(tokens, {text = " ", pen = theme.NEUTRAL_B})
        table.insert(tokens, {text = (d.has_mason and "S" or "-"), pen = (d.has_mason and theme.PRI or theme.SEC)})
        table.insert(tokens, {text = " ", pen = theme.NEUTRAL_B})
        table.insert(tokens, {text = pad_right((d.has_gem and "G" or "-"), 5), pen = (d.has_gem and theme.PRI or theme.SEC)})
        
        table.insert(tokens, {text = pad_right(smelt, 7), pen = (smelt == "0" and theme.SEC or theme.PRI)})
        table.insert(tokens, {text = pad_right(alloy, 6), pen = (alloy == "0" and theme.SEC or theme.PRI)})
        table.insert(tokens, {text = pad_right(finishes, 7), pen = (finishes == "-" and theme.SEC or theme.PRI)})
        table.insert(tokens, NEWLINE)
    end
    
    return tokens
end

-- ==========================================
-- UI: CIV DASHBOARD PANEL
-- ==========================================
RefinishPanelCivs = defclass(RefinishPanelCivs, widgets.Panel)
RefinishPanelCivs.ATTRS = { theme = DEFAULT_NIL }

function RefinishPanelCivs:init()
    self.theme = self.theme or reqscript('refinish-theme').get_current_theme()
    
    -- Panel init log removed: init() fires on every HUD construction,
    -- not just when the user navigates to this panel.
    
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
        CUSTOM_SHIFT_P = function()
            self.hide_unskilled = not self.hide_unskilled
            self:update_list(self.search_text)
        end,
        CUSTOM_SHIFT_U = function()
            self.hide_unknown = not self.hide_unknown
            self:update_list(self.search_text)
        end,
        CUSTOM_SHIFT_L = function() self:prompt_search() end
    }

    self.all_civ_data = {}
    self.local_civ_id = df.global.plotinfo and df.global.plotinfo.civ_id or -1

    local bases_array = reqscript('refinish-bases').get_valid_bases()
    local valid_bases = {}
    for _, b in ipairs(bases_array) do
        valid_bases[b.id] = true
    end

    -- STRICT CACHE PULL
    local ui_dict = _G.refinish_blueprint and _G.refinish_blueprint.ui_dict or { metal_names = {}, ore_map = {}, finish_counts = {} }

    -- Sweep the civs instantly to pull their cache entries
    for _, civ in ipairs(df.global.world.entities.all) do
        if civ.type == df.historical_entity_type.Civilization and civ.entity_raw then
            table.insert(self.all_civ_data, get_civ_data(civ, valid_bases, ui_dict))
        end
    end
    
    table.sort(self.all_civ_data, function(a, b) return a.name < b.name end)

    self.local_civ_class = "UNKNOWN"
    for _, d in ipairs(self.all_civ_data) do
        if d.id == self.local_civ_id then
            self.local_civ_class = d.class
            break
        end
    end

    self.search_text = ""
    self.hide_unskilled = false
    self.hide_unknown = true

    self.active_choices = self:build_list_choices(self.search_text)

    local function make_vert_tokens(str_list, pen_color)
        local tokens = {}
        if not str_list or #str_list == 0 then return {{text = "None", pen = self.theme.SEC}} end
        for i, v in ipairs(str_list) do
            table.insert(tokens, {text = v, pen = pen_color})
            if i < #str_list then table.insert(tokens, NEWLINE) end
        end
        return tokens
    end

    self.topic_list = widgets.List{
        frame = {t = 0, l = 0, r = 0, b = 0},
        choices = self.active_choices,
        text_pen = self.theme.SEC,
        cursor_pen = self.theme.PRI,
        on_select = function(idx, choice)
            if choice and choice.data and self.dossier_panel then
                local p = self.dossier_panel.subviews
                
                if choice.data.id then
                    p.val_title:setText({{text = choice.data.name or "UNKNOWN CIV", pen = self.theme.PRI}})
                    
                    local sub_text = choice.data.race_adj or "Unknown"
                    if not choice.data.is_animal_person then
                        sub_text = sub_text .. " Civilization"
                    end
                    sub_text = sub_text .. " [" .. (choice.data.class or "UNKNOWN") .. "]"
                    
                    p.val_subtitle:setText({{text = sub_text, pen = self.theme.SEC}})
                    
                    p.val_smelt:setText({{text = choice.data.has_smelter and choice.data.name .. " has smelting technology." or choice.data.name .. " has no smelting technology.", pen = choice.data.has_smelter and self.theme.PRI or self.theme.SEC}})
                    p.val_forge:setText({{text = choice.data.has_forge and choice.data.name .. " has forging technology." or choice.data.name .. " has no forging technology.", pen = choice.data.has_forge and self.theme.PRI or self.theme.SEC}})
                    p.val_mason:setText({{text = choice.data.has_mason and choice.data.name .. " has stoneworking technology." or choice.data.name .. " has no stoneworking technology.", pen = choice.data.has_mason and self.theme.PRI or self.theme.SEC}})
                    p.val_gem:setText({{text = choice.data.has_gem and choice.data.name .. " has gem-cutting technology." or choice.data.name .. " has no gem-cutting technology.", pen = choice.data.has_gem and self.theme.PRI or self.theme.SEC}})
                    
                    p.hdr_smelt:setText({{text="SMELTED METALS", pen=self.theme.SEC}})
                    p.hdr_alloy:setText({{text="REFINED METALS", pen=self.theme.SEC}})
                    
                    p.hdr_extra:setText({{text="APPROVED METALS", pen=self.theme.SEC}})
                    p.col_extra:setText(make_vert_tokens(choice.data.rs_list, self.theme.PRI))
                    
                    p.col_smelt:setText(make_vert_tokens(choice.data.smelting_list, self.theme.PRI))
                    p.col_alloy:setText(make_vert_tokens(choice.data.alloying_list, self.theme.PRI))
                    
                    local rs_lines = {}
                    if choice.data.rs_finishes and choice.data.rs_finishes > 0 then table.insert(rs_lines, choice.data.rs_finishes .. " Finishes") end
                    if choice.data.rs_stone then table.insert(rs_lines, "Grind stone") end
                    if choice.data.rs_gem then table.insert(rs_lines, "Grind gems") end
                    if choice.data.rs_grind_metal then table.insert(rs_lines, "Grind metal") end
                    
                    local rs_str = (#rs_lines > 0) and table.concat(rs_lines, "   ") or "None"
                    local rs_pen = (#rs_lines > 0) and self.theme.PRI or self.theme.SEC
                    
                    p.civ_rs_title:setText({{text="", pen=self.theme.SEC}})
                    p.civ_rs_body:setText({{text=rs_str, pen=rs_pen}})

                    p.global_title_1:setText("")
                    p.global_body_1:setText("")
                    p.global_title_2:setText("")
                    p.global_body_2:setText("")
                    p.fallback_dump:setText("")
                    
                elseif choice.data.is_global then
                    p.val_title:setText({{text = "GLOBAL TECHNOLOGY", pen = self.theme.PRI}})
                    p.val_subtitle:setText({{text = "Civilization Summary", pen = self.theme.SEC}})
                    
                    p.val_smelt:setText("")
                    p.val_forge:setText("")
                    p.val_mason:setText("")
                    p.val_gem:setText("")
                    p.hdr_smelt:setText("")
                    p.hdr_alloy:setText("")
                    p.hdr_extra:setText("")
                    p.col_smelt:setText("")
                    p.col_alloy:setText("")
                    p.col_extra:setText("")
                    p.civ_rs_title:setText("")
                    p.civ_rs_body:setText("")
                    
                    p.global_title_1:setText({{text = "", pen = self.theme.SEC}})
                    p.global_body_1:setText(choice.data.roster_tokens)
                    
                    p.global_title_2:setText("")
                    p.global_body_2:setText("")
                    p.fallback_dump:setText("")
                    
                else
                    p.val_title:setText({{text = "", pen = self.theme.PRI}})
                    p.val_subtitle:setText("")
                    p.val_smelt:setText("")
                    p.val_forge:setText("")
                    p.val_mason:setText("")
                    p.val_gem:setText("")
                    
                    p.hdr_smelt:setText("")
                    p.hdr_alloy:setText("")
                    p.hdr_extra:setText("")
                    p.col_smelt:setText("")
                    p.col_alloy:setText("")
                    p.col_extra:setText("")
                    p.civ_rs_title:setText("")
                    p.civ_rs_body:setText("")
                    
                    p.global_title_1:setText("")
                    p.global_body_1:setText("")
                    p.global_title_2:setText("")
                    p.global_body_2:setText("")
                    
                    p.fallback_dump:setText({{text = choice.data.text or "Select a civilization.", pen = self.theme.SEC}})
                end
                
                if self.frame_body then
                    self.dossier_panel:updateLayout()
                end
            end
        end
    }

    self.btn_toggle_avail = widgets.Label{
        frame = {t = 1, l = 17, w = 17},
        text = make_key_label('CUSTOM_SHIFT_P', function() return self.hide_unskilled and "Show Unskilled" or "Hide Unskilled" end, self.theme.SEC),
        on_click = self.actions.CUSTOM_SHIFT_P
    }

    self.btn_toggle_unknown = widgets.Label{
        frame = {t = 1, l = 37, w = 15},
        text = make_key_label('CUSTOM_SHIFT_U', function() return self.hide_unknown and "Show Unknown" or "Hide Unknown" end, self.theme.SEC),
        on_click = self.actions.CUSTOM_SHIFT_U
    }

    self.btn_search = widgets.Label{
        frame = {t = 1, l = 0, w = 14},
        text = make_key_label('CUSTOM_SHIFT_L', 'Search Civs', self.theme.SEC),
        on_click = self.actions.CUSTOM_SHIFT_L
    }

    self.dossier_panel = widgets.Panel{
        frame = {t = 2, l = 19, r = 0, b = 2},
        autoarrange_subviews = false,
        subviews = {

            -- HEADERS
            widgets.Label{ view_id = 'val_title', frame = {t = 0, l = 0}, text = "SELECT A CIVILIZATION", text_pen = self.theme.PRI },
            widgets.Label{ view_id = 'val_subtitle', frame = {t = 1, l = 0}, text = "", text_pen = self.theme.SEC },

            -- QUICK STATS
            --
            -- Smelting leads because it is the gate everything else
            -- depends on: no smelter means no metal bars by any route,
            -- so no refinishing regardless of what else a civ has. The
            -- three below it are the grinding capabilities.
            --
            -- Rows shifted down one to make room. t=6 was already free
            -- between the old gem row and civ_rs_title at t=7, so
            -- nothing below this block moved.
            widgets.Label{ frame = {t = 3, l = 0}, text = "", text_pen = self.theme.NEUTRAL_B },
            widgets.Label{ view_id = 'val_smelt', frame = {t = 3, l = 0}, text = "", text_pen = self.theme.PRI },
            widgets.Label{ frame = {t = 4, l = 0}, text = "", text_pen = self.theme.NEUTRAL_B },
            widgets.Label{ view_id = 'val_forge', frame = {t = 4, l = 0}, text = "", text_pen = self.theme.PRI },
            widgets.Label{ frame = {t = 5, l = 0}, text = "", text_pen = self.theme.NEUTRAL_B },
            widgets.Label{ view_id = 'val_mason', frame = {t = 5, l = 0}, text = "", text_pen = self.theme.PRI },
            widgets.Label{ frame = {t = 6, l = 0}, text = "", text_pen = self.theme.NEUTRAL_B },
            widgets.Label{ view_id = 'val_gem', frame = {t = 6, l = 0}, text = "", text_pen = self.theme.PRI },


            -- ==================================================
            -- THE CIV BOXES
            -- ==================================================
            -- The New Horizontal RS Assets
            widgets.Label{ view_id = 'civ_rs_title', frame = {t = 7, l = 0}, text = "", text_pen = self.theme.SEC },
            widgets.Label{ view_id = 'civ_rs_body', frame = {t = 9, l = 0, r = 0}, text = "", text_pen = self.theme.PRI },

            widgets.Label{ view_id = 'hdr_smelt', frame = {t = 12, l = 0}, text = "SMELTED METALS", text_pen = self.theme.SEC },
            widgets.Label{ view_id = 'col_smelt', frame = {t = 14, l = 0, w = 15}, text = "", text_pen = self.theme.PRI },

            widgets.Label{ view_id = 'hdr_alloy', frame = {t = 12, l = 17}, text = "REFINED METALS", text_pen = self.theme.SEC },
            widgets.Label{ view_id = 'col_alloy', frame = {t = 14, l = 17, w = 21}, text = "", text_pen = self.theme.PRI },

            widgets.Label{ view_id = 'hdr_extra', frame = {t = 12, l = 40}, text = "APPROVED METALS", text_pen = self.theme.SEC },
            widgets.Label{ view_id = 'col_extra', frame = {t = 14, l = 40, w = 21}, text = "", text_pen = self.theme.PRI },


            -- ==================================================
            -- THE GLOBAL BOXES (Full Width)
            -- ==================================================
            widgets.Label{ view_id = 'global_title_1', frame = {t = 0, l = 0}, text = "", text_pen = self.theme.SEC },
            widgets.Label{ view_id = 'global_body_1', frame = {t = 3, l = 0, r = 0}, text = "", text_pen = self.theme.PRI },

            widgets.Label{ view_id = 'global_title_2', frame = {t = 15, l = 0}, text = "", text_pen = self.theme.SEC },
            widgets.Label{ view_id = 'global_body_2', frame = {t = 16, l = 0, r = 0}, text = "", text_pen = self.theme.PRI },

            -- FALLBACK DUMP
            widgets.Label{ view_id = 'fallback_dump', frame = {t = 3, l = 0, r = 0}, text = "", text_pen = self.theme.PRI }
        }
    }

    -- ==================================================
    -- CIV SELECTION SUBPANEL
    -- ==================================================
    self:addviews{
        widgets.Label{ frame = {t = 0, l = 0}, text = "CIVILIZATION & TECHNOLOGY", text_pen = self.theme.PRI },
        widgets.Panel{ frame = {t = 2, l = 0, w = 18, b = 2}, subviews = { self.topic_list } },
        self.dossier_panel,
        widgets.Panel{ frame = {b = 0, l = 0, r = 0, h = 2}, subviews = { self.btn_toggle_avail, self.btn_toggle_unknown, self.btn_search } }
    }

    if #self.active_choices > 0 then self.topic_list:setSelected(1) end
    -- Mark whether data was available at construction time.
    -- If not, onRenderBody will rebuild once the blueprint arrives.
    self.data_ready = (_G.refinish_blueprint and _G.refinish_blueprint.civ_tech) ~= nil
end

-- ==========================================
-- LIVE DATA REFRESH
-- ==========================================
-- The civs panel is constructed when the HUD opens, which may
-- be before the boot pipeline has finished populating
-- _G.refinish_blueprint. This check runs each frame and
-- rebuilds the civ data once the blueprint cache appears.
-- After one successful rebuild, the flag is cleared so we
-- stop checking.
-- ==========================================
function RefinishPanelCivs:onRenderBody(painter)
    if not self.data_ready and _G.refinish_blueprint and _G.refinish_blueprint.civ_tech then
        -- Blueprint has arrived since we were constructed; rebuild
        local bases_array = reqscript('refinish-bases').get_valid_bases()
        local valid_bases = {}
        for _, b in ipairs(bases_array) do valid_bases[b.id] = true end

        local ui_dict = _G.refinish_blueprint.ui_dict or { metal_names = {}, ore_map = {}, finish_counts = {} }

        self.all_civ_data = {}
        for _, civ in ipairs(df.global.world.entities.all) do
            if civ.type == df.historical_entity_type.Civilization and civ.entity_raw then
                table.insert(self.all_civ_data, get_civ_data(civ, valid_bases, ui_dict))
            end
        end
        table.sort(self.all_civ_data, function(a, b) return a.name < b.name end)

        -- Re-identify local civ class after rebuild
        self.local_civ_class = "UNKNOWN"
        for _, d in ipairs(self.all_civ_data) do
            if d.id == self.local_civ_id then self.local_civ_class = d.class; break end
        end

        self:update_list(self.search_text)
        self.data_ready = true
    end
    RefinishPanelCivs.super.onRenderBody(self, painter)
end

function RefinishPanelCivs:onInput(keys)
    for key_name, action in pairs(self.actions) do
        if keys[key_name] then
            action()
            return true
        end
    end
    return RefinishPanelCivs.super.onInput(self, keys)
end

-- ==========================================
-- SEARCH & FILTER LOGIC
-- ==========================================
function RefinishPanelCivs:build_list_choices(query)
    local choices = {}
    local q_lower = query and string.lower(query) or ""

    if q_lower == "" then
        local local_data = nil
        for _, d in ipairs(self.all_civ_data) do
            if d.id == self.local_civ_id then local_data = d; break end
        end
        if local_data then
            table.insert(choices, { text = {{text = "LOCAL", pen = self.theme.PRI}}, data = local_data })
        end
        table.insert(choices, { 
            text = {{text = "GLOBAL", pen = self.theme.SEC}}, 
            data = { is_global = true, roster_tokens = get_global_roster_data(self.all_civ_data, self.theme, self.hide_unskilled, self.hide_unknown) } 
        })
        table.insert(choices, { text = "", data = { text = "Select a civilization to view its tech data." } })
    end

    for _, data in ipairs(self.all_civ_data) do
        local is_unskilled = not (data.has_forge or data.has_mason or data.has_gem)
        local is_unknown = (data.name == "Unknown" or string.find(data.name, "^Civ ID:"))
        if (not self.hide_unskilled or not is_unskilled) and (not self.hide_unknown or not is_unknown) then
            local match_str = string.lower(data.name .. " " .. data.class .. " " .. data.race_adj)
            if q_lower == "" or string.find(match_str, q_lower) then
                local color = (data.class == self.local_civ_class) and self.theme.PRI or self.theme.SEC
                table.insert(choices, { text = { {text = string.sub(data.name, 1, 26), pen = color} }, data = data })
            end
        end
    end

    if #choices == 0 then table.insert(choices, { text = "No results", data = { text = "No civilizations match your search query." } }) end
    return choices
end

function RefinishPanelCivs:update_list(query)
    -- Remember what was selected before we rebuild
    local selected_idx = self.topic_list:getSelected()
    local selected_choice = self.active_choices[selected_idx]

    self.search_text = query or ""
    self.active_choices = self:build_list_choices(self.search_text)
    self.topic_list:setChoices(self.active_choices)
    
    if #self.active_choices > 0 then
        -- Default to the top of the list
        local new_idx = 1
        
        -- Hunt for the previously selected item in the newly rebuilt list
        if selected_choice and selected_choice.data then
            for i, choice in ipairs(self.active_choices) do
                if choice.data.is_global == selected_choice.data.is_global and choice.data.id == selected_choice.data.id then
                    new_idx = i
                    break
                end
            end
        end
        
        self.topic_list:setSelected(new_idx)
    end
end

function RefinishPanelCivs:prompt_search()
    dialogs.showInputPrompt(
        "Search Civilizations", 
        "Enter a name, class, or race (e.g. DWARVEN). Leave blank & hit Enter to clear:", 
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