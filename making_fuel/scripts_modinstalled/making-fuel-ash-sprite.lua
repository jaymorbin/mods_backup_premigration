--@ module = true
-- making-fuel-ash-sprite.lua
-- ==========================================
-- MAKING FUEL: ASH BAR SPRITE
-- ==========================================
-- Gives vanilla's ash bar its own art from a PNG in this mod's own
-- images folder. No raws, no tile page, nothing declared anywhere.
-- The material stays builtin ASH, so potash, lye and every glaze
-- keep working; only what the bar LOOKS like changes.
--
-- WHERE THE ART COMES FROM
--   A cell of a vanilla graphics page, resolved through the live
--   page registry the raws parser fills. No file loading, no mod
--   path, nothing on disk: the page is already in memory because DF
--   parsed it at launch. Same mechanism the module's tools use.
--
-- PROVEN. The probe wrote vanilla pearlash's cell onto builtin ASH
-- and the bar changed on screen, so a runtime bar_texpos write on a
-- BUILTIN material is honoured by the renderer, exactly as it is for
-- the module's injected inorganics.
--
-- ==========================================
-- WHY THE COLOUR IS THE ART
-- ==========================================
-- DF draws a bar two ways, and setting bar_texpos switches between
-- them.
--
--   NO bar_texpos: the generic ITEM_BARS sprite, TINTED by the
--   material's colour. This is why every metal bar looks different
--   with no per metal art anywhere, and it is what an ash bar did
--   before this file: a grey generic bar.
--
--   WITH bar_texpos: that cell's art, as drawn, untinted.
--
-- So there is no colour dial. The colour is whatever is in the cell.
-- ==========================================

-- ---- LOG IDENTITY, DECLARED HERE ----
-- RM core does not know this module exists and must never have to.
-- The onus is on the module to hand RM correct information, so the
-- system and subsystem are stated here rather than inferred anywhere
-- else.
--
-- Guarded reqscript: a bare top level one is a hard load time
-- dependency and has taken a module down before. Without it the log
-- falls back to the same grammar, unsanitised, and the script still
-- loads.
local LOG_SYS, LOG_SUB = 'MAKING_FUEL', 'ASH_SPRITE'
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)
local MODULE_ID = 'making_fuel'

-- ==========================================
-- LOG FUNNEL
-- ==========================================
-- Every line this file writes goes through log(), in the one grammar
-- the log panel reads: SYSTEM SUBSYSTEM SUBJECT TYPE | body, composed
-- by refinish-log. The identity is declared by the module, not
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
-- SUBJECT is the correlation slot: OVERRIDE for a sprite this file
-- dresses, START for the engine check, TRY for the console helper.
--
-- This replaces a log() that let refinish-log guess TYPE from the
-- words (read_type) unless a call site said otherwise, and printed to
-- the console when RM was not loaded.
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

-- ==========================================
-- CONFIGURATION
-- ==========================================
-- SOURCE is any grammar the sprite engine speaks. PAGE is a cell of
-- a graphics page by token, x then y, both zero based, so 2:3 is the
-- third column and fourth row of vanilla's item_construction.png.
-- ITEM_CONSTRUCTION is 4 wide by 10 tall; row 3 is the bar row, with
-- potash at 0:3 and pearlash at 1:3.
--
-- TEXFLAG_DONOR is the material whose flag word is copied, so the
-- bar slot reads as live. COAL is the donor the module's charcoal
-- schema already uses.
local SOURCE        = 'PAGE:ITEM_CONSTRUCTION:2:3'
local TEXFLAG_DONOR = 'BUILTIN:COAL#texflag'

-- ---- THE TEXFLAG EXPERIMENT ----
-- Coal's texflag was copied onto every material write so the slot would
-- read as live. It is now the prime suspect for why peat did not take
-- its material colour while the tools did.
--
-- What points at it: all 22 materials dumped in df_data_reference carry
-- texflag 0; limestone and marble share one boulder texpos with texflag
-- 0 and still render in different colours, so a set texpos does NOT by
-- itself switch tinting off; and the only module materials that failed
-- to adapt are the ones carrying coal's flag.
--
-- Set true to put it back. If the peat sprite VANISHES rather than
-- staying grey, the flag was load bearing and true is the answer.
local COPY_TEXFLAG = false

-- ==========================================
-- OVERRIDES
-- ==========================================
-- Vanilla materials whose sprite this module replaces. Each entry is
-- a material token, one slot on it, and where the art comes from.
--
-- WHY A TABLE. Every one of these writes a DF-owned material, so
-- every one needs its prior value saved and put back on stop. Doing
-- that for a list is the same work as doing it for one material, and
-- the next one is then a line rather than a script.
--
-- PAIRED SLOTS. boulder1 and boulder2 are two variants DF chooses
-- between. Peat ships with 1 unset and 2 baked, so writing only one
-- leaves a coin flip between the new art and what was there.
--
-- FILE reads the mod's own images and needs nothing declared in any
-- raws file. Its fourth number is the page WIDTH in tiles, because a
-- full page is a grid and the slice is flat: making_fuel_boulders
-- mirrors vanilla BOULDERS at 2 wide, making_fuel_item_construction
-- mirrors ITEM_CONSTRUCTION at 4. With the width right, every cell
-- index is the one the original page used.
-- ==========================================
local OVERRIDES = {
    { token = 'BUILTIN:ASH', slot = 'bar',
      source = 'PAGE:ITEM_CONSTRUCTION:2:3' },

    -- ---- PEAT ON THE ADAPTIVE COAL CELL ----
    -- Was a forced colour on the module's item_construction sheet. This
    -- is the vanilla charcoal pile copied pixel for pixel with its ramp
    -- stretched into the adaptive band, so the colour now comes from the
    -- material instead of from the art.
    --
    -- WATCH THIS ONE. Vanilla peat declares STATE_COLOR MAROON, which is
    -- RGB 128:0:0: a pure hue with no green and no blue in it at all.
    -- Dried peat is RUSSET at 117:90:87 and lands brown, but maroon has
    -- nothing to mute it, so peat may come out red rather than peaty. If
    -- it does, the sprite is not the problem and 2:2, the capped copy,
    -- will not save it either. Going back to a forced colour is the
    -- honest fix.
    { token = 'INORGANIC:PEAT', slot = 'boulder1', source = 'TINT:coal' },
    { token = 'INORGANIC:PEAT', slot = 'boulder2', source = 'TINT:coal' },

    -- ---- THE RAWS INORGANICS, ON TINTED BOULDER CELLS ----
    -- These three live in inorganic_making_fuel.txt, so they cannot
    -- carry a graphics block in the materials JSON the way an injected
    -- material does. They are pointed here instead, by their raws ids,
    -- which carry the MKGFUEL_ prefix (see the raws file's header).
    --
    -- TINT, not PAGE. refinish-sprite-art-boulders.lua already holds
    -- every filled cell of the vanilla BOULDERS page, copied pixel for
    -- pixel and retoned onto the neutral ramp, named boulders_<x>_<y>
    -- after the cell. PAGE copies the vanilla cell as vanilla coloured
    -- it and the material's own descriptor never lands, which is what
    -- the first cut of these lines did.
    --
    -- The blend carries a dark descriptor: STRENGTH 0.75 keeps a
    -- quarter of the untinted art, so BLACK reads as a shaded black
    -- lump rather than the flat silhouette a full multiply would give.
    -- DESAT is the lever if one of these bites.
    --
    -- The cells, by what vanilla draws in them:
    --   boulders_0_3   the coal lump (COAL_BITUMINOUS, LIGNITE)
    --   boulders_1_13  obsidian, glassy
    --
    -- Coal rocks take the coal lump: anthracite IS coal, and oil shale
    -- is the same kind of dark fuel rock. Tar solids take obsidian's
    -- glassy shape: bitumen is coal tar pitch set hard, and the module
    -- materials PITCH and BITUMEN share that shape on purpose.
    { token = 'INORGANIC:MKGFUEL_ANTHRACITE', slot = 'boulder1',
      source = 'TINT:boulders_0_3' },
    { token = 'INORGANIC:MKGFUEL_ANTHRACITE', slot = 'boulder2',
      source = 'TINT:boulders_0_3' },
    { token = 'INORGANIC:MKGFUEL_SHALE_OIL', slot = 'boulder1',
      source = 'TINT:boulders_0_3' },
    { token = 'INORGANIC:MKGFUEL_SHALE_OIL', slot = 'boulder2',
      source = 'TINT:boulders_0_3' },
    { token = 'INORGANIC:MKGFUEL_BITUMEN', slot = 'boulder1',
      source = 'TINT:boulders_1_13' },
    { token = 'INORGANIC:MKGFUEL_BITUMEN', slot = 'boulder2',
      source = 'TINT:boulders_1_13' },
}

-- Slot name to the field it writes. The engine has its own copy of
-- this; ours exists to READ the field back, because the field is the
-- only honest test of whether a write landed.
local SLOT_FIELD = {
    bar      = 'bar_texpos',
    boulder1 = 'boulder_texpos1',
    boulder2 = 'boulder_texpos2',
    rough1   = 'rough_texpos1',
    rough2   = 'rough_texpos2',
    wood     = 'wood_texpos',
}

-- ==========================================
-- STATE
-- ==========================================
-- What each material carried before we wrote it, in write order, so
-- stop can walk it BACKWARDS. Reverse matters on a paired slot: the
-- last write is the one sitting on the field.
--
-- An entry is added only when a write actually landed, so a failed
-- source leaves nothing to restore and stop stays a no-op.
-- ==========================================
local written = {}

local function engine()
    local ok, e = pcall(reqscript, 'refinish-sprite-engine')
    if ok and e and e.apply_edits then return e end
    return nil
end

-- BUILTIN: is the SPRITE ENGINE's grammar, not matinfo's.
-- matinfo.find has never heard of "BUILTIN:ASH" and returns nil,
-- which is why the ash bar quietly stopped being dressed the moment
-- this script started looking materials up for itself. Builtins are
-- resolved the same way the engine resolves them, straight off the
-- builtin table; everything else goes to matinfo as before.
local function material_of(token)
    local b = token:match('^BUILTIN:(.+)$')
    if b then
        local m = nil
        pcall(function()
            local idx = df.builtin_mats[b]
            if idx then
                m = df.global.world.raws.mat_table.builtin[idx]
            end
        end)
        return m
    end
    local mi = nil
    pcall(function() mi = dfhack.matinfo.find(token) end)
    return mi and mi.material or nil
end

-- ==========================================
-- WRITE ONE
-- ==========================================
-- Returns true when the material actually changed. The test is the
-- FIELD, not the engine's return: a source that fails to resolve
-- leaves the slot exactly as it was, and that is the only signal
-- that cannot be argued with.
-- ==========================================
local function write_one(token, slot, source, remember)
    local m = material_of(token)
    local e = engine()
    if not m or not e then return false end

    local field = SLOT_FIELD[slot]
    if not field then return false end

    local before, flag_before = nil, nil
    pcall(function() before = m[field] end)
    pcall(function() flag_before = m.texflag end)

    local edits = {
        { target = 'MATERIAL:' .. token .. '#' .. slot, source = source },
    }
    if COPY_TEXFLAG then
        table.insert(edits,
            { target = 'MATERIAL:' .. token .. '#texflag', source = TEXFLAG_DONOR })
    end
    e.apply_edits(edits, 'ash_sprite')

    local after = nil
    pcall(function() after = m[field] end)
    if after ~= before and after and after > 0 then
        if remember then
            table.insert(written, {
                token = token, field = field,
                value = before, texflag = flag_before,
            })
        end
        return true
    end

    -- Nothing landed. Put the flag word back, so a failed attempt
    -- cannot leave a slot marked live over a texpos that is not.
    pcall(function() m.texflag = flag_before end)
    return false
end

-- ==========================================
-- LIVE TRY
-- ==========================================
-- Point any slot at any source, immediately, no recycle. For
-- choosing a cell by looking at it. Defaults to the ash bar.
--
--   try('FILE:images/making_fuel_boulders.png:0:12:2')
--   try('PAGE:ITEM_CONSTRUCTION:1:3')
--   try('FILE:images/x.png:0:4:4', 'INORGANIC:PEAT', 'boulder2')
--
-- A try IS remembered, so stop puts it back like any other write.
-- ==========================================
function try(source, token, slot)
    token = token or 'BUILTIN:ASH'
    slot  = slot  or 'bar'
    if not source then stop() log('INFO', 'back to vanilla.', 'TRY') return end
    if write_one(token, slot, source, true) then
        log('INFO', token .. ' ' .. slot .. ' now showing ' .. source
            .. '. Call try() with no argument to undo.', 'TRY')
    else
        log('WARNING', 'could not use ' .. source .. ' for ' .. token .. ' '
            .. slot .. '. Missing file, empty cell, or bad token.', 'TRY')
    end
end

-- ==========================================
-- LIFECYCLE
-- ==========================================
-- start() is called from making_fuel.lua alongside the other
-- background scripts. stop() washes, and is called EARLY in
-- teardown with the other things that mutate a DF object: these
-- materials belong to DF, and nothing of ours may still be sitting
-- on one when RAM is cleared.
-- ==========================================
function start()
    local e = engine()
    if not e then
        -- WARNING: vanilla's own sprites show instead, which is cosmetic.
        log('WARNING', 'sprite engine unavailable, nothing done.', 'START')
        return
    end

    -- ---- THE ROOT, SET HERE ----
    -- A FILE source in OVERRIDES is relative to this mod's data
    -- folder, the same root buildings use for images/retort.png. The
    -- module engine sets that root when it injects, but THIS script
    -- runs at the token call, before any injection, so the root is
    -- still empty and every relative path resolves against the
    -- working directory and fails.
    --
    -- Set it, use it, clear it. Cleared even on an early return path
    -- below, because a root left standing would follow the next
    -- module into its own injection.
    local root = nil
    pcall(function()
        local sm = require('script-manager')
        local p = sm.getModSourcePath('making_fuel')
        if p then root = tostring(p) .. 'data/' end
    end)
    if root and e.set_file_root then
        pcall(function() e.set_file_root(root) end)
    end

    for _, ov in ipairs(OVERRIDES) do
        if not material_of(ov.token) then
            log('DETAIL', ov.token .. ' unreachable, skipped.', 'OVERRIDE')
        elseif write_one(ov.token, ov.slot, ov.source, true) then
            log('DETAIL', ov.token .. ' ' .. ov.slot .. ' dressed from '
                .. ov.source .. '.', 'OVERRIDE')
        else
            -- Not a fault. An unresolved source leaves vanilla's own
            -- sprite, which is a perfectly good sprite.
            log('DETAIL', 'could not use ' .. ov.source .. ' for ' .. ov.token
                .. ' ' .. ov.slot .. ', left as is.', 'OVERRIDE')
        end
    end

    if e.set_file_root then
        pcall(function() e.set_file_root(nil) end)
    end
end

-- Re-resolve after DF resets its textures, which moves every texpos
-- while leaving the handles valid.
function refresh()
    start()
end

function stop()
    -- Backwards, so a paired slot unwinds in the order it was built.
    for i = #written, 1, -1 do
        local w = written[i]
        local m = material_of(w.token)
        if m then
            pcall(function()
                m[w.field] = w.value
                m.texflag  = w.texflag
            end)
        end
    end
    written = {}
end

return _ENV