-- making-fuel-sprite-art.lua
-- =====================================================================
-- MAKING FUEL CHAR MAPS
-- =====================================================================
-- The art for every material slot that has to take its material's
-- colour. One character per pixel, space transparent, ramp characters
-- documented in refinish-sprite-art.lua.
--
-- These are NOT on making_fuel_byproducts.png in any load bearing way.
-- The sheet carries reference copies so both routes show the same
-- picture, but nothing reads pixels back out of a PNG, so when the two
-- disagree THIS FILE WINS. Edit here, mirror to the sheet if you care
-- about the sheet staying honest.
--
-- All four sit on the neutral ramp at 56 to 199. The coke pair used to
-- live on the dark charcoal ramp, which was right when the art had to
-- look like coal unaided and wrong the moment a tint arrived.
--
--   coal        the vanilla charcoal pile, ramp stretched into the
--               adaptive band. Worn by peat and dried peat.
--   green_coke  coarse unbroken lumps
--   breeze      fine dust, flat and wide
--   powder      the vanilla powder pile, ITEM_CONSTRUCTION 2:3, copied
--               pixel for pixel. Worn by coal ash, which declares
--               TAUPE_GRAY at 139:133:137 and so lands a medium grey,
--               visibly apart from plain ash on the same shape.
-- =====================================================================

--@ module = true

local art = reqscript('refinish-sprite-art')

local ART = {
    -- The gritty bar. Copied from the vanilla metal bar at
    -- ITEM_CONSTRUCTION 0:1, silhouette and shading structure left
    -- alone so it still reads as a bar, interior broken up, specular
    -- whites removed because a pressed brick has no polish.
    --
    -- This is the module's own coal bar. It is also on
    -- making_fuel_byproducts.png at 1:3, but that copy is reference
    -- only: nothing can read a PNG's pixels back out of DF, so THIS is
    -- the source and the sheet is the mirror.
    briquette = {
        '',
        '',
        '',
        '',
        '',
        '',
        '                  00',
        '                007600',
        '              0066455500',
        '            00754555436600',
        '          00763356565555560',
        '        0075566535744576340',
        '      007546456465567623322.',
        '    007755645456537764211210',
        '   0674566445545654113121231.',
        '   0337766354447433221322321.',
        '   3444374444543434123423220..',
        '  0523533475612323322224200...',
        '  03555343574342233221200.....',
        '  054545445343222434400.....',
        '  .002343345322332300.....',
        '    .00422445212400.....',
        '      .0034445300.....',
        '        .002500.....',
        '          .00.....',
        '            ....',
        '',
        '',
        '',
        '',
        '',
        '',
    },
    coal = {
        '',
        '',
        '',
        '',
        '',
        '                       .0',
        '            0100      0620',
        '           026410000  0320',
        '           0352027530  01.',
        '         0010001012400',
        '        047146741001320',
        '       026412322472024600    ..',
        '       0321022102662123520  043.',
        '       0110010102352012230  1220',
        '      02652102010332101220 ..0..',
        '     034421046321032010101020.',
        '     01111012235010010...02420',
        '     .011010122210..0.. 010120.',
        '      .0010.0100010...  .0....',
        '      02441..0...0.',
        '     .232220...0.',
        '      01000.  0420.',
        '              03522.',
        '              00120.',
        '              ...0.',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
    },
    green_coke = {
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
        '              6652.',
        '          76666552551.',
        '          266655525444331.',
        '          .66555441443321.',
        '           65554442433221.',
        '           25542222111221.',
        '        44432225555441111.',
        '      4444333115554441....',
        '      14433331.55444331.',
        '      .4333321.54443331221.',
        '       3333221114431432221.',
        '       133111...111.122211.',
        '       4433221. .....11111.',
        '       1332211.      ......',
        '       .1111111.',
        '        ........',
        '',
        '',
        '',
        '',
        '',
        '',
    },
    breeze = {
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
        '               665',
        '          7774 630776',
        '       666741555555776',
        '       636661777520741',
        '     7766630774100011165',
        '     7463555411101100060',
        '     110052011..63076300',
        '        000000  0001000  3',
        '         .....  ......',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
    },
    powder = {
        '',
        '',
        '',
        '',
        '',
        '          .00.',
        '          068200',
        '          0568480',
        '        .02445552.',
        '        0425754440   .00',
        '        .268444574. 02870',
        '       .155674588620755540',
        '      037445454655424644550',
        '    0 .0654545545454224520.',
        '   050..0552545642226821..',
        '    .272.022434524758642.',
        '    03452..1225485655445.',
        '     .00..1885645644232200',
        '         0565525444520.286.',
        '         .02332154322218640.',
        '           .00..01222.244360',
        '             .. ..1682.2100.',
        '                .1245281...',
        '                040122460.00.',
        '                .0....00.0530.',
        '                    .......0..',
        '                          ...',
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

-- Exposed so a probe or the panel can list what this module contributed
-- without reaching into the shared registry.
function names()
    local out = {}
    for k in pairs(ART) do table.insert(out, k) end
    table.sort(out)
    return out
end
