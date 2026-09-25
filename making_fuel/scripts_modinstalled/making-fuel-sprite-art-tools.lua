-- making-fuel-sprite-art-tools.lua
-- =====================================================================
-- MAKING FUEL CHAR MAPS: THE TOOL SHEET
-- =====================================================================
-- Art for the module's own tools that has to take the material's
-- colour. A PNG cell can be handed to DF but its pixels can never be
-- read back, so anything WE tint has to live here as char map data.
--
-- GRAVEL is converted from making_fuel_byproducts.png, cell 0:1. The
-- sheet is 128 by 128 RGBA on a transparent background, so cells are 32
-- by 32 and the silhouette comes straight off the alpha channel.
-- Conversion rules, for the next cell brought over:
--   alpha 128 or more is art, below that is not;
--   1:1 pixels, no resampling, no smoothing, no re-ranking. A median
--       pass smears a pile into a blob and rank matching against
--       another sprite's histogram throws the local shading away;
--   values are the artist's own, nearest ramp step, capped at 199;
--   disconnected clusters under 12 pixels are splatter and go;
--   '.' is the CAST SHADOW, under the mass only. Measured on
--       boulders_0_3: never around the silhouette. Ringing a sprite
--       with it makes the shadow wear the material's colour.
--
-- CINDERS and SAWDUST are drawn here rather than converted, because
-- what they replace was a boulder and a smooth hill. Built the way the
-- vanilla powder pile at ITEM_CONSTRUCTION 2:3 is built: a heap made of
-- many small grains, each with a lit crown, a body and a dark
-- underside, a dark seam wherever a grain meets a gap, and loose grains
-- around the base. That structure is what reads as powder; a shaded
-- mound reads as a hill whatever colour it takes.
--
--   cinders   coarse angular fines, grains of 1 and 2, mid dark body
--   sawdust   flakes rather than grains (diamonds, not discs), lighter
--             body, a looser heap
--
-- The matching breeze map lives in making-fuel-sprite-art.lua beside
-- the other material art, since breeze wears a material slot.
-- =====================================================================

--@ module = true

local art = reqscript('refinish-sprite-art')

local ART = {
    gravel = {
        '',
        '',
        '',
        '',
        '',
        '',
        '            6655410',
        '            6554410  330',
        '            13444310 400',
        '           5544411144310',
        '        1555411154443310',
        '        05544441144332210',
        '         5244431043311110',
        '         1444111111100000',
        '         5111055544410',
        '      355441155544441044310',
        '    15554441255442454443310',
        '    05544431054444344433210',
        '     5444131114411114332210',
        '     14411100011000033211140',
        '   305341310 .000...11100030',
        '   001433310 ...... 0000  00',
        '     01111110 ...   .30',
        '      0000000        030',
        '       ......        .00',
        '            .         ..',
        '',
        '',
        '',
        '',
        '',
        '',
    },
    cinders = {
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '            665',
        '          66660   776',
        '          633333 74443',
        '          666601 7446665',
        '          363006677763072',
        '        77700033334100011',
        '       744445633304555110',
        '       766615333301520554',
        '       3630122000410002221',
        '        0005550111252522201',
        '        111520002220022220',
        '           ............',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
    },
    sawdust = {
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '           6       6  6',
        '          665  6 7555665',
        '         7766275275552662',
        '         5755 726655566662',
        '        76662774175256322',
        '        6666355163554.2',
        '         566555267613',
        '        4 355556741.. 46',
        '            .......',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
    },
}

for name, charmap in pairs(ART) do
    art.register(name, charmap)
end

-- Exposed so a probe or the panel can list what this file contributed
-- without reaching into the shared registry.
function names()
    local out = {}
    for k in pairs(ART) do table.insert(out, k) end
    table.sort(out)
    return out
end