-- refinish-sprite-art-vanilla.lua
-- =====================================================================
-- VANILLA TINT MAPS
-- =====================================================================
-- The vanilla default sprite for every material texpos slot, copied
-- pixel for pixel and retoned onto the neutral ramp so it can be tinted.
--
-- WHY THESE EXIST. A material slot left at 0 falls through to DF's own
-- default item sprite, which DF tints. The moment you write ANY texpos
-- into that slot you lose the tint and own the colour yourself. These
-- maps are the escape: they are the same pictures DF would have drawn,
-- so pointing a slot at TINT:vanilla_bar gets you back exactly what
-- falling through would have given you, except now RM controls it and
-- can vary it per material.
--
-- Use them as a baseline, a fallback when a module has no art of its
-- own, and as a reference for what a tintable sprite should look like.
--
-- CORE, not module. These are shared vanilla shapes, not any one
-- module's assets, which is why they live beside the mechanism while
-- making-fuel-sprite-art.lua keeps its own coal pile and cokes. The
-- vanilla_ prefix keeps the two sets from colliding in the registry.
--
-- SOURCES, so they can be re-derived:
--   [TILE_GRAPHICS:BOULDERS:0:1:ITEM_BOULDER]
--   [TILE_GRAPHICS:BOULDERS:0:10:ITEM_ROUGH_GEM]
--   [TILE_GRAPHICS:ITEM_CONSTRUCTION:0:1:ITEM_BARS]
--   [TILE_GRAPHICS:ITEM_CONSTRUCTION:0:0:ITEM_BLOCKS]
--   [TILE_GRAPHICS:ITEM_CONSTRUCTION:0:2:ITEM_WOOD]
--   [TILE_GRAPHICS:ITEM_CONSTRUCTION:1:1:ITEM_BARS_SOAP]
--   [TILE_GRAPHICS:ITEM_FOOD:0:1:ITEM_CHEESE]
--   the powder pile is ITEM_CONSTRUCTION 2:3
--
-- RETONING. Sources carry between 7 and 18 distinct values and some sit
-- off the neutral ramp entirely: the boulder reaches down to 0 and the
-- log is on the warm wood ramp. Each was mapped by RANK rather than by
-- value, spread proportionally across the nine neutral steps, so the
-- relative shading survives whatever the source count was. All eight
-- now span 56 to 255, which is the range a tint needs to work on.
--
-- Untinted they look like pale grey rubble. That is correct. The colour
-- is supposed to arrive from the material.
-- =====================================================================

--@ module = true

local art = reqscript('refinish-sprite-art')

local ART = {
    -- BOULDERS 0:1, boulder1/boulder2, the mined stone lump
    vanilla_boulder = {
        '',
        '',
        '                         .....',
        '',
        '',
        '',
        '',
        '              000000',
        '             07666660',
        '            0666667330',
        '          .06687883440.',
        '         00664465434450',
        '        06666556455534400',
        '       0765664655554455450',
        '      055856663645555546730',
        '      035578877465554567310',
        '      04533355554555433520.',
        '      .05543555444444355440',
        '      012153454443233433430',
        '     0223333535333233335350',
        '      01212334334335223550.',
        '      02221123343244213430.',
        '      .0112111331333112440.',
        '       011110110333311110..',
        '       .0000.00.00000000..',
        '         ................',
        '           ............',
        '',
        '',
        '',
        '',
        '',
    },
    -- BOULDERS 0:10, rough1/rough2, uncut gem
    vanilla_rough_gem = {
        '',
        '',
        '',
        '',
        '',
        '',
        '               00',
        '              0780',
        '             06855.',
        '             078550',
        '            0685550',
        '         00.0685551000.',
        '         08647555327880',
        '         05756554267850',
        '         05565453278550',
        '         .255534567650',
        '          03655325652.',
        '          05476465341.',
        '         0223423343230',
        '         0231113232220.',
        '         0221133232220.',
        '         0111232411210.',
        '         .01122231100..',
        '          .0000000.....',
        '            ..........',
        '              ......',
        '',
        '',
        '',
        '',
        '',
        '',
    },
    -- ITEM_CONSTRUCTION 0:1, bar, the metal bar every bar falls back to
    vanilla_bar = {
        '',
        '',
        '',
        '',
        '',
        '',
        '                  00',
        '                007700',
        '              0077557700',
        '            00775555557700',
        '          00775577555555750',
        '        0077575557755577530',
        '      007755557555777731331.',
        '    007755555557557753111310',
        '   0775555555555775133311331.',
        '   0547755555587533313311131.',
        '   3544478558853333313331130..',
        '  0544444488533333333133100...',
        '  05444444473333333331300.....',
        '  044444444533333333300.....',
        '  .003444445433333300.....',
        '    .00344445333300.....',
        '      .0034454300.....',
        '        .004500.....',
        '          .00.....',
        '            ....',
        '',
        '',
        '',
        '',
        '',
        '',
    },
    -- ITEM_CONSTRUCTION 0:0, construction blocks
    vanilla_block = {
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '                 00',
        '               007500',
        '             0077777500',
        '           00777777777500',
        '         00777777777777780',
        '       0087778777777787880',
        '      08777777777777788310',
        '      08877877777777833330',
        '      05588787777844333110',
        '      05555888888334333310',
        '      05555558843333313110.',
        '      04545555833333111310..',
        '      0445455583333131110...',
        '      03445555533333300....',
        '      .00445558333100....',
        '        .0045533110....',
        '          .001100....',
        '            .00....',
        '              ...',
        '',
        '',
        '',
        '',
        '',
        '',
    },
    -- ITEM_CONSTRUCTION 0:2, wood_texpos, the log
    vanilla_log = {
        '          0000   0000',
        '         0777500077750',
        '        076565427666540',
        '        066565425656540',
        '        058555425655540',
        '        058645425856540',
        '        068645425866540',
        '       006865542686554000',
        '      07268665426666540240',
        '     0762575654257545450440',
        '     0662574654258445502440',
        '     0582564554258445402440',
        '     0582665654268565402540.',
        '     0682665654267565402440..',
        '     0682665554266555402440..',
        '     0682566564256665402240..',
        '     0572644335263344502240..',
        '     0572344443234444302440..',
        '     0562444444234444402240..',
        '     0662354453235444312540..',
        '     0665234531223543122540..',
        '     06655111122121112422450.',
        '     0566554255543225555540..',
        '     0633334253334315333350..',
        '     0344445234444223444540...',
        '     0444443254444313445450..',
        '     0345453244444103444530..',
        '     .0435302054310.135330...',
        '      .0000...0000...0000....',
        '       .............. ......',
        '        .... .  ....   ....',
        '',
    },
    -- ITEM_CONSTRUCTION 1:1, small bar, soap sized
    vanilla_soap_bar = {
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
        '                  000',
        '               0016670',
        '            00166666660',
        '          01676667666760',
        '         076767666678651.',
        '        1767666677865550.',
        '        157767786555530..',
        '        03568865553210..',
        '        .05555553100...',
        '         .0355200....',
        '          .000....',
        '           ....',
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
    },
    -- ITEM_CONSTRUCTION 2:3, powder pile
    vanilla_powder = {
        '',
        '',
        '',
        '',
        '',
        '          .00.',
        '          068200',
        '          0468480',
        '        .02444442.',
        '        0424744440   .00',
        '        .268444474. 02870',
        '       .144674488620744440',
        '      037444444644424644440',
        '    0 .0644444444444224420.',
        '   050..0542444642226821..',
        '    .272.022434424748642.',
        '    03442..1224484644444.',
        '     .00..1884644644232200',
        '         0464424444420.286.',
        '         .02332154322218640.',
        '           .00..01222.244360',
        '             .. ..1682.2100.',
        '                .1244281...',
        '                040122460.00.',
        '                .0....00.0430.',
        '                    .......0..',
        '                          ...',
        '',
        '',
        '',
        '',
        '',
    },
    -- ITEM_FOOD 0:1, cheese1/cheese2
    vanilla_cheese = {
        '',
        '',
        '',
        '',
        '',
        '           .0000000.',
        '         0047787785300',
        '       00777777776768700',
        '      0467777776766676640',
        '     077767777777677776760',
        '    07767777776677777776670',
        '   .48677777767777777777763.',
        '   0587767776767777777776640',
        '   0587777667777777777766750',
        '   0578777767766777776677630.',
        '   0458777776667667667666520.',
        '   0445787677677777766775320.',
        '   0444456887776677776532220.',
        '   0344444577888878653222220.',
        '   .24444444455545322222221..',
        '    03444444444343223222220..',
        '    .044444444443232222220...',
        '     .0444444443432232220...',
        '      .02344444432322210....',
        '       ..0123443232210.....',
        '         ..000000000......',
        '           .............',
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

function names()
    local out = {}
    for k in pairs(ART) do table.insert(out, k) end
    table.sort(out)
    return out
end
