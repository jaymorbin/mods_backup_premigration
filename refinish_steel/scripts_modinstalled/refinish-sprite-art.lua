-- refinish-sprite-art.lua
-- =====================================================================
-- MANUFACTURED TINTING
-- =====================================================================
-- A material slot does not adapt. Confirmed in play: green coke and
-- coke breeze were set to RED and their sprites did not move. DF applies
-- no colour to a texpos we hand it, and there is no flag reachable from
-- Lua that asks it to.
--
-- A TOOL is different. Its texpos lives on the itemdef, shared by every
-- material the tool can be made of, so DF has to tint it and does.
-- Nothing here is needed for tools; they stay on the PNG sheet.
--
-- So for material slots we do the tint ourselves: read the material's
-- own colour, multiply the grey art in Lua, and hand DF a texture that
-- is ALREADY the right colour. One grey source, every material, no hand
-- mixing.
--
-- WHY THE ART IS DATA AND NOT A PNG. loadTileset returns TexposHandles,
-- not pixels, and there is no way to read a PNG's pixels back out of DF.
-- Anything we intend to tint has to exist as a char map here. That
-- splits the module's sprites permanently:
--
--   tool sprites      making_fuel_byproducts.png, DF tints them
--   material sprites  char maps registered here, we tint them
--
-- Modules register their own art. This file owns the mechanism only.
--
--   local art = reqscript('refinish-sprite-art')
--   art.register('coal', { '   0123   ', ... })
--   local texpos, err = art.texpos_for(material, 'coal')
--   art.release_all()                     -- on shutdown, keeps them
-- =====================================================================

--@ module = true

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
-- SUBJECT is the correlation slot: TINT for a knob change, RELEASE for
-- the shutdown count.
--
-- This replaces a log() that PRINTED to the console and never reached
-- the log, under the system name 'REFINISH', which the log panel does
-- not recognise as RM. Both of its lines are run by other scripts, not
-- typed, so neither is a print.
--
-- Every line reaches the log on disk. Filtering is the panel's job
-- alone, so there is no level check here.
-- ==========================================
local LOG_SYS, LOG_SUB = 'REFINISH_METAL', 'SPRITE_ART'
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
-- THE RAMP
-- ==========================================
-- The vanilla neutral ramp, measured off ITEM_CONSTRUCTION 2:3 and 1:1.
-- '.' is '0' at half alpha, which is the vanilla soft edge convention.
-- Art for tinting belongs on THIS ramp, 56 to 199, never on the dark
-- charcoal ramp: multiplying already dark art by an already dark
-- descriptor leaves a flat blob with no readable form. The darkness is
-- the descriptor's job.
-- ==========================================
local RAMP = {
    ['.'] = { 0x2F, 0x30, 0x38, 128 },
    ['0'] = { 0x2F, 0x30, 0x38, 255 },
    ['1'] = { 0x3C, 0x3E, 0x46, 255 },
    ['2'] = { 0x49, 0x4C, 0x54, 255 },
    ['3'] = { 0x5A, 0x5E, 0x65, 255 },
    ['4'] = { 0x6B, 0x70, 0x76, 255 },
    ['5'] = { 0x8A, 0x90, 0x91, 255 },
    ['6'] = { 0xA5, 0xA6, 0xA5, 255 },
    ['7'] = { 0xC7, 0xC4, 0xB4, 255 },
    ['8'] = { 0xFF, 0xFF, 0xFF, 255 },
}

local CELL_PX = 32

-- ==========================================
-- PIXEL PACKING
-- ==========================================
-- ABGR. Confirmed by test card on a live peat boulder: a flat
-- 200,100,50 at full alpha rendered RED-PINK and semi transparent,
-- which is alpha taking the red byte and red taking the alpha byte.
--
-- The Lua_API doc says "packed RBGA format (for example, #0022FF11)"
-- and that is its only mention anywhere. It describes the BYTE layout,
-- not the integer, so the obvious 0xRRGGBBAA is wrong.
--
-- Signature of getting this wrong, so it is recognised rather than
-- rediscovered: sprites render as ghostly semi transparent negatives,
-- because alpha ends up tracking the red channel. Dark dominant art
-- goes INVISIBLE on the map while pale art survives looking washed out.
-- ==========================================
local function pack(r, g, b, a)
    return (a << 24) | (b << 16) | (g << 8) | r
end

-- ==========================================
-- THE BLEND
-- ==========================================
-- Tuned in play against vanilla boulders.
--
-- DESAT pulls the DESCRIPTOR toward its own luminance before
-- multiplying. It exists because a descriptor with a zeroed channel,
-- and MAROON at 128:0:0 is exactly that, leaves nothing for the shading
-- to carry and collapses the sprite onto one channel. At 0 it is off,
-- which is where it settled: the lift below turned out to do the work
-- on its own.
--
-- STRENGTH lerps from the untinted art toward the fully multiplied
-- result. 1.0 is a pure multiply and goes very dark under a dark
-- descriptor. 0.75 matches vanilla closely.
-- ==========================================
--
-- VALUE is the third knob, and it exists because the other two cannot
-- do what it does. A multiply can only DARKEN: out = p * c / 255, and c
-- is at most 255, so every tint costs brightness before STRENGTH is
-- even consulted. MEASURED on the ramp: art 138 under DARK_BROWN keeps
-- 46 per cent of its luminance at STRENGTH 0.75 and 28 per cent at 1.0,
-- and even a plain GRAY descriptor halves it. That is why fading with
-- STRENGTH feels like the only brightness control there is, and why it
-- costs colour to use: the two were welded together.
--
-- VALUE unwelds them by restoring the pixel's own luminance after the
-- blend. 1.00 means the tinted pixel is exactly as light as the art
-- pixel was, so STRENGTH sets how much hue, DESAT sets how pure it is,
-- and this sets how light it lands. Below 1 darkens, above 1 lightens
-- and starts clipping, which desaturates highlights. 0 turns the
-- restore off and gives the old darkening behaviour exactly.
-- ==========================================
-- Parked on _G so a script reload keeps whatever was tuned, and so the
-- values can be changed while the game runs. blend() reads them on
-- every pixel, so a change takes effect on the next manufacture; what
-- is already cached is not repainted, which is what tint() below deals
-- with.
_G.refinish_sprite_art_tint = _G.refinish_sprite_art_tint or {
    desat = 0.7, strength = 0.95, value = 0.65,
}
local KNOBS = _G.refinish_sprite_art_tint

local function blend(p, rgb)
    local DESAT, STRENGTH, VALUE = KNOBS.desat, KNOBS.strength, KNOBS.value
    local L = (30 * rgb[1] + 59 * rgb[2] + 11 * rgb[3]) // 100
    local c = {
        math.floor(rgb[1] * (1 - DESAT) + L * DESAT),
        math.floor(rgb[2] * (1 - DESAT) + L * DESAT),
        math.floor(rgb[3] * (1 - DESAT) + L * DESAT),
    }
    local out = {}
    for i = 1, 3 do
        local m = (p[i] * c[i]) // 255
        out[i] = math.floor(p[i] + (m - p[i]) * STRENGTH)
    end

    -- ---- BRIGHTNESS, PUT BACK ----
    -- Scaling all three channels by the same factor moves the value
    -- and leaves the ratios between them alone, so the hue and the
    -- saturation the knobs above decided are untouched.
    if VALUE > 0 then
        local lp = (30 * p[1] + 59 * p[2] + 11 * p[3]) // 100
        local lo = (30 * out[1] + 59 * out[2] + 11 * out[3]) // 100
        if lo > 0 then
            local k = (lp / lo) * VALUE
            for i = 1, 3 do
                out[i] = math.min(255, math.floor(out[i] * k))
            end
        end
    end

    return out[1], out[2], out[3]
end

-- ==========================================
-- REGISTRY
-- ==========================================
-- Modules put their char maps here. Parked on _G so a module reload
-- does not lose art the engine is already pointing at.
-- ==========================================
_G.refinish_sprite_art_registry = _G.refinish_sprite_art_registry or {}
local ART = _G.refinish_sprite_art_registry

function register(name, charmap)
    if type(name) ~= 'string' or type(charmap) ~= 'table' then
        return false, 'register(name, charmap) wants a string and a table'
    end
    ART[name] = charmap
    return true
end

function registered()
    local out = {}
    for k in pairs(ART) do table.insert(out, k) end
    table.sort(out)
    return out
end

-- ==========================================
-- COLOUR
-- ==========================================
local function material_rgb(m)
    local idx = nil
    pcall(function() idx = m.state_color.Solid end)
    if not idx or idx < 0 then return nil, 'no solid state colour' end
    local c = df.global.world.raws.descriptors.colors[idx]
    if not c then return nil, 'state colour ' .. tostring(idx) .. ' does not resolve' end
    return { c.orig_rgb[0], c.orig_rgb[1], c.orig_rgb[2] }, c.id
end

-- ==========================================
-- BUILD
-- ==========================================
-- RESERVED, not dynamic. The dynamic range is periodically wiped and
-- the handle exists so you can re-resolve afterwards. We cannot: a
-- material slot holds a RAW INTEGER, not a handle, so once the vector is
-- wiped that integer points at whatever now occupies the index and the
-- material silently wears somebody else's sprite.
--
-- The reserved range is never wiped. The catch is that it is a fixed
-- size buffer and DFHack falls back to dynamic SILENTLY when full, with
-- no way to ask which you got. Right for a handful of material sprites,
-- wrong as a habit. If sprites start swapping themselves after a long
-- session, a full reserved buffer is the first suspect.
-- ==========================================
_G.refinish_sprite_art_handles = _G.refinish_sprite_art_handles or {}
_G.refinish_sprite_art_cache   = _G.refinish_sprite_art_cache   or {}
local HANDLES = _G.refinish_sprite_art_handles
local CACHE   = _G.refinish_sprite_art_cache

local function build(charmap, rgb)
    local pixels = {}
    for y = 1, CELL_PX do
        local line = charmap[y] or ''
        for x = 1, CELL_PX do
            local p = RAMP[line:sub(x, x)]
            if p then
                local r, g, b = blend(p, rgb)
                pixels[#pixels + 1] = pack(r, g, b, p[4])
            else
                pixels[#pixels + 1] = 0
            end
        end
    end
    return dfhack.textures.createTileset(pixels, CELL_PX, CELL_PX,
                                         CELL_PX, CELL_PX, true)
end

-- ==========================================
-- THE ONE CALL THE ENGINE MAKES
-- ==========================================
-- Cached per material colour and art name, because the same pairing
-- resolves once per slot and a material with two boulder slots would
-- otherwise burn two reserved textures on one picture.
-- ==========================================
function texpos_for(m, art_name)
    local charmap = ART[art_name]
    if not charmap then
        return nil, 'no art registered as "' .. tostring(art_name) .. '"'
    end
    local rgb, cname = material_rgb(m)
    if not rgb then return nil, cname end

    local key = string.format('%s:%d:%d:%d', art_name, rgb[1], rgb[2], rgb[3])
    if CACHE[key] then return CACHE[key], nil end

    local handles = build(charmap, rgb)
    if not handles or not handles[1] then
        return nil, 'createTileset returned nothing'
    end
    local texpos = dfhack.textures.getTexposByHandle(handles[1])
    if not texpos or texpos <= 0 then
        -- Not deleted either. This is the same call that took the
        -- process down at shutdown, and a handle that just failed to
        -- resolve is the least trustworthy one to hand back to it. The
        -- cost is one unused texture per failed manufacture, which is a
        -- fault that should be read in the log and fixed, not swept up.
        return nil, 'handle did not resolve to a texpos'
    end
    table.insert(HANDLES, handles)
    CACHE[key] = texpos
    return texpos, nil
end

-- ==========================================
-- TEARDOWN: KEPT, NOT FREED
-- ==========================================
-- MEASURED, twice, 2026-09-22 at 16:55:52 and 17:10:18: deleting these
-- on the way out of a world took DF down with it. The stack is
-- Core::onStateChange, into Lua, into DFHack::Textures::deleteHandle,
-- into SDL. Both sessions stop at the same point of the teardown, the
-- line before this call, and neither ever printed the count below.
--
-- pcall is no guard here. A crash inside DFHack's own texture code is
-- native, and Lua never gets the chance to catch it. The old body had
-- every delete in a pcall and still took the process down.
--
-- It began crashing when the count grew. One pairing (peat) survived
-- this for months; anthracite, oil shale, bitumen, pitch, char,
-- naphthalene and anthracene took it to eight.
--
-- So nothing is deleted. These are RESERVED range textures, which are
-- never wiped, so the texpos a handle resolved to stays good for the
-- life of the process. The CACHE is kept for the same reason: the next
-- start asks for the same art and colour pairings and gets the same
-- textures back instead of manufacturing a second set, so keeping them
-- costs nothing that freeing them saved.
--
-- One cost, and it is a development one: editing an art entry needs a
-- full DF restart to see the change, because the pairing is cached.
--
-- The symptom to watch, from RM_Adaptive_Sprites: the reserved buffer
-- is a fixed size and DFHack falls back to the dynamic range silently
-- when it is full. If a sprite ever comes back wearing another
-- material's picture after many reloads, that is the buffer filling,
-- not this.
-- ==========================================
-- ==========================================
-- LIVE TUNING
-- ==========================================
-- Set any of the three knobs while the game runs. The cache is keyed by
-- art name and colour, not by the knobs, so a stale entry would hand
-- back the OLD texture for ever: wiping it is the whole trick. The
-- textures themselves are left alone, because deleting a handle takes
-- the process down (see the note above), so a tuning session leaks one
-- texture per art and colour pairing per change. That is fine for
-- tuning and is why this is not something to call on a cadence.
--
-- Nothing is repainted by this call. A consumer has to ASK for its
-- texpos again: the tool tint watcher does that every poll, ash sprite
-- has refresh(), and slots written from module JSON are resolved at
-- injection, so those need the module stopped and started. None of it
-- needs DF restarted, which is what the cache used to force.
--
--   tint{ value = 0.9 }               one knob
--   tint{ strength = 1.0, desat = 0.2 }
--   tint()                            report only, nothing wiped
function tint(opts)
    if type(opts) == 'table' then
        local touched = false
        for _, k in ipairs({ 'desat', 'strength', 'value' }) do
            local v = opts[k]
            if type(v) == 'number' then KNOBS[k] = v; touched = true end
        end
        if touched then
            local n = 0
            for k in pairs(CACHE) do CACHE[k] = nil; n = n + 1 end
            -- DETAIL: refinish-tint reports the change itself. This is
            -- the cache beneath it.
            log('DETAIL', ('tint set to desat %.2f strength %.2f value %.2f, '
                 .. '%d cached pairing(s) dropped')
                :format(KNOBS.desat, KNOBS.strength, KNOBS.value, n), 'TINT')
        end
    end
    return KNOBS.desat, KNOBS.strength, KNOBS.value
end

function release_all()
    local n = #HANDLES
    if n > 0 then
        -- DETAIL: runs at every shutdown and data cycle.
        log('DETAIL', 'kept ' .. n .. ' manufactured texture(s) for reuse.',
            'RELEASE')
    end
    return n
end