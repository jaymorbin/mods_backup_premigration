#!/usr/bin/env python3
"""
preflight.py - offline schema check for RM module JSON files.

Mirrors every rejection branch in refinish-module-validate.lua so you can
catch a bad file without launching Dwarf Fortress.

WHAT IT READS
    refinish-module-types.lua   The engine's type dictionary. Reagent types,
                                product types, buildings, skills and material
                                classes are all parsed OUT OF IT rather than
                                hardcoded here, so this script cannot drift
                                from the engine. Re-copy it from your live RM
                                install whenever RM updates.
    <name>_materials.json       Your module's materials file.
    <name>_reactions.json       Your module's reactions file.

USAGE
    python3 preflight.py                          auto-discover in this folder
    python3 preflight.py mats.json rxns.json      explicit files
    python3 preflight.py --types /path/types.lua mats.json rxns.json

EXIT CODES
    0   passed (warnings may still have been printed)
    1   failed, at least one error
    2   could not find or read an input file

ERRORS vs WARNINGS
    An ERROR is something refinish-module-validate.lua will reject, which
    takes the whole module down. Fix these.

    A WARNING is something this script cannot verify offline, or something
    that is legal but is a known way to shoot yourself. It does not fail
    the run.
"""

import argparse
import glob
import json
import os
import re
import sys


# ===============================================================
# PARSE THE ENGINE'S TYPE TABLES
# ===============================================================
# Everything the validator checks a name against lives in
# refinish-module-types.lua. Parsing it means this script stays
# correct when the engine gains a new reagent type or building.
#
# An early version hardcoded these lists, drifted from the engine,
# and missed the needs_mat_id class of failure entirely. Do not
# reintroduce hardcoded copies.
# ===============================================================
def _capture_lua_table(text, name):
    """Return a match-like object holding the full body of a top level
    Lua table, counting braces so nested entries do not end it early."""
    start = re.search(r'^' + name + r'\s*=\s*\{', text, re.M)
    if not start:
        return None
    i = start.end()
    depth = 1
    while i < len(text) and depth:
        c = text[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
        i += 1

    class _M:
        def __init__(self, body):
            self._body = body
        def group(self, _n):
            return self._body

    return _M(text[start.end():i - 1])

def load_engine_types(path):
    text = open(path, encoding='utf-8', errors='replace').read().replace('\r', '')

    def table_keys(name):
        m = re.search(r'^' + name + r' = \{(.*?)^\}', text, re.S | re.M)
        if not m:
            return set()
        return set(re.findall(r'^[ \t]{4}([A-Z_0-9]+)\s*=', m.group(1), re.M))

    # Reagent types, with the two per-type requirements the validator
    # enforces. Value is (needs_mat_id, needs_metal_id).
    reagents = {}
    # Brace-match the table rather than regex to the first line that
    # starts with a closing brace. Multi-line entries such as COKE
    # contain their own column-zero-ish closers, and CRLF endings put a
    # stray \r before them, so a non-greedy ^\} cuts the table short and
    # silently hides every type defined after the first nested entry.
    m = _capture_lua_table(text, 'REAGENT_TYPES')
    if m:
        # Two entry shapes exist in the engine table and both are valid:
        #
        #   COKE = {              multi-line, closes on its own line
        #       item_type = 0,
        #   },
        #
        #   MEAT   = { item_type = ..., needs_mat_id = false },
        #                         single line, aligned padding on =
        #
        # Matching only the first shape silently dropped every one-liner,
        # which is most of the organic intake block, and reported them
        # back as unrecognized reagent types.
        for entry in re.finditer(
                r'^[ \t]+([A-Z_0-9]+)\s*=\s*\{(.*?)\}\s*,?\s*$',
                m.group(1), re.S | re.M):
            body = entry.group(2)
            reagents[entry.group(1)] = (
                bool(re.search(r'needs_mat_id\s*=\s*true', body)),
                bool(re.search(r'needs_metal_id\s*=\s*true', body)),
            )

    # Product types, flagging the ones that carry a builtin material.
    # Those name no material of their own and are exempt from the
    # exactly-one-material-source rule.
    products = {}
    m = re.search(r'^PRODUCT_TYPES = \{(.*?)^\}', text, re.S | re.M)
    if m:
        for line in m.group(1).splitlines():
            entry = re.match(r'\s*([A-Z_0-9]+)\s*=\s*\{(.*)', line)
            if entry:
                products[entry.group(1)] = bool(
                    re.search(r'builtin\s*=\s*true', entry.group(2)))

    skills = set()
    m = re.search(r'SKILL_MAP = \{(.*?)^\}', text, re.S | re.M)
    if m:
        skills = set(re.findall(r'^\s+([A-Z_0-9]+)\s*=\s*\S', m.group(1), re.M))

    # JOB_ITEM_VECTORS is a LIST of quoted names, not key = value
    # entries, so table_keys cannot read it. Its own extractor rather
    # than loosening that one, because a pattern matching both shapes
    # would also match half the file.
    vectors = set()
    mv = re.search(r'^JOB_ITEM_VECTORS = \{(.*?)^\}', text, re.S | re.M)
    if mv:
        vectors = set(re.findall(r"'([A-Z_0-9]+)'", mv.group(1)))

    # Same shape, same reason: a list of quoted names rather than
    # key = value entries.
    tool_uses = set()
    mt = re.search(r'^TOOL_USES = \{(.*?)^\}', text, re.S | re.M)
    if mt:
        tool_uses = set(re.findall(r"'([A-Z_0-9]+)'", mt.group(1)))

    return {
        'reagents':  reagents,
        'products':  products,
        'classes':   table_keys('MATERIAL_CLASS_PRESETS'),
        'buildings': table_keys('BUILDING_TYPES'),
        'skills':    skills,
        'vectors':   vectors,
        'tool_uses': tool_uses,
    }


# ===============================================================
# REPORTING
# ===============================================================
ERRORS = []
WARNINGS = []


def err(msg):
    ERRORS.append(msg)


def warn(kind, msg):
    """kind groups repetitive warnings in the report so a 900-reaction
    module does not print 700 near-identical lines."""
    WARNINGS.append((kind, msg))


# ===============================================================
# df.item_type NAMES
# ===============================================================
# A product type not listed in PRODUCT_TYPES is still valid if
# df.item_type knows the name, and the reaction builder resolves it
# that way. This script cannot read the DF enum, so it carries a copy.
#
# The list is ADVISORY and is only consulted to suppress a warning.
# Being incomplete costs a spurious warning. Being wrong costs a
# missing warning. Neither can turn an error into a pass, because
# an unrecognised product type was never an error here in the first
# place. If a name you use is missing, add it.
# ===============================================================
DF_ITEM_TYPES = {
    'BAR', 'SMALLGEM', 'BLOCKS', 'ROUGH', 'BOULDER', 'WOOD', 'DOOR',
    'FLOODGATE', 'BED', 'CHAIR', 'CHAIN', 'FLASK', 'GOBLET', 'INSTRUMENT',
    'TOY', 'WINDOW', 'CAGE', 'BARREL', 'BUCKET', 'ANIMALTRAP', 'TABLE',
    'COFFIN', 'STATUE', 'CORPSE', 'WEAPON', 'ARMOR', 'SHOES', 'SHIELD',
    'HELM', 'GLOVES', 'BOX', 'BIN', 'ARMORSTAND', 'WEAPONRACK', 'CABINET',
    'FIGURINE', 'AMULET', 'SCEPTER', 'AMMO', 'CROWN', 'RING', 'EARRING',
    'BRACELET', 'GEM', 'ANVIL', 'CORPSEPIECE', 'REMAINS', 'MEAT', 'FISH',
    'FISH_RAW', 'VERMIN', 'IS_PET', 'SEEDS', 'PLANT', 'SKIN_TANNED',
    'PLANT_GROWTH', 'THREAD', 'CLOTH', 'TOTEM', 'PANTS', 'BACKPACK',
    'QUIVER', 'CATAPULTPARTS', 'BALLISTAPARTS', 'SIEGEAMMO',
    'BALLISTAARROWHEAD', 'TRAPPARTS', 'TRAPCOMP', 'DRINK', 'POWDER_MISC',
    'CHEESE', 'FOOD', 'LIQUID_MISC', 'COIN', 'GLOB', 'ROCK', 'PIPE_SECTION',
    'HATCH_COVER', 'GRATE', 'QUERN', 'MILLSTONE', 'SPLINT', 'CRUTCH',
    'TRACTION_BENCH', 'ORTHOPEDIC_CAST', 'TOOL', 'SLAB', 'EGG', 'BOOK',
    'SHEET', 'BRANCH',
}


# ===============================================================
# RUNTIME SENTINELS
# ===============================================================
# A module Lua file may write an explicit null into mat_id or metal_id
# as a sentinel meaning "resolve this against the loaded world before
# handing the data to RM." The sand pattern is the standard case.
#
# JSON distinguishes a key that is absent from one that is present and
# null, and that distinction is the whole signal. Absent means the
# modder forgot. Present-and-null means they meant it.
#
# The engine never sees these, so flagging them as errors would fail
# every module that resolves anything at load time.
# ===============================================================
def is_sentinel(d, field):
    return isinstance(d, dict) and field in d and d[field] is None


# ===============================================================
# SHARED TYPE PREDICATES
# ===============================================================
# The validator's helpers, translated. The bool exclusion matters:
# Python treats True as an int, Lua does not treat true as a number,
# so a JSON true in a numeric field must fail here as it would there.
# ===============================================================
def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def is_nil_or_num(v):
    return v is None or is_num(v)


def is_str(v):
    return isinstance(v, str)


def is_nonempty_str(v):
    return isinstance(v, str) and v != ''


def is_nil_or_str(v):
    return v is None or isinstance(v, str)


def is_table(v):
    return isinstance(v, (dict, list))


# ===============================================================
# MODULE IDENTITY
# ===============================================================
# Checked per file, then cross-checked between them. The engine
# rejects the module if the two prefixes disagree.
# ===============================================================
def check_module_block(doc, label):
    m = doc.get('module')
    if not isinstance(m, dict):
        err("%s: missing 'module' block" % label)
        return None

    prefix = m.get('prefix')
    if not is_nonempty_str(prefix):
        err("%s: module.prefix must be a non-empty string" % label)
    else:
        if not prefix.endswith('_'):
            err("%s: module.prefix must end with an underscore: %r" % (label, prefix))
        if 'REFINISH_STEEL_' in prefix:
            err("%s: module.prefix collides with RM core: %r" % (label, prefix))

    if not is_nonempty_str(m.get('name')):
        err("%s: module.name must be a non-empty string" % label)
    if not is_nonempty_str(m.get('version')):
        err("%s: module.version must be a non-empty string" % label)

    deps = m.get('depends_on')
    if deps is not None:
        if not isinstance(deps, list):
            err("%s: module.depends_on must be an array of prefix strings" % label)
        else:
            for i, dep in enumerate(deps, 1):
                if not is_nonempty_str(dep):
                    err("%s: module.depends_on[%d] must be a non-empty string" % (label, i))
                elif not dep.endswith('_'):
                    err("%s: module.depends_on[%d] must end with an underscore: %r"
                        % (label, i, dep))
                elif dep == prefix:
                    err("%s: module.depends_on[%d] cannot be this module's own prefix"
                        % (label, i))
    return prefix


# ===============================================================
# MATERIALS
# ===============================================================
def check_materials(doc, engine, label):
    mats = doc.get('materials')
    if not isinstance(mats, list):
        err("%s: missing 'materials' array" % label)
        return []
    if not mats:
        err("%s: 'materials' array is empty" % label)
        return []

    stress_fields = ('IMPACT', 'COMPRESSIVE', 'TENSILE', 'TORSION', 'SHEAR', 'BENDING')
    heat_fields = ('spec_heat', 'melting_point', 'boiling_point', 'ignite_point',
                   'heatdam_point', 'colddam_point', 'mat_fixed_temp')

    seen = set()
    for i, x in enumerate(mats):
        t = "materials[%d] (%s)" % (i, x.get('key'))

        # ---- key ----
        k = x.get('key')
        if not is_nonempty_str(k):
            err("%s.key must be a non-empty string" % t)
            k = ''
        else:
            if re.search(r'\s', k):
                err("%s.key must not contain whitespace" % t)
            if k != k.upper():
                err("%s.key must be UPPERCASE" % t)
            if k in seen:
                err("%s.key is duplicated" % t)
            seen.add(k)

        if not is_nonempty_str(x.get('name')):
            err("%s.name must be a non-empty string" % t)

        # ---- class ----
        cls = x.get('material_class')
        if not is_nonempty_str(cls):
            err("%s.material_class is required" % t)
        elif cls not in engine['classes']:
            err("%s.material_class %r is not a recognized class" % (t, cls))

        # ---- appearance ----
        if x.get('color') is not None and not is_str(x['color']):
            err("%s.color must be a string or null" % t)
        fb = x.get('fallback_colors')
        if fb is not None:
            if not isinstance(fb, list):
                err("%s.fallback_colors must be an array or null" % t)
            else:
                for j, c in enumerate(fb, 1):
                    if not is_str(c):
                        err("%s.fallback_colors[%d] must be a string" % (t, j))
        if x.get('color') is None:
            warn('color',
             "%s: no color set. The material takes whatever colour the "
                 "clone donor had." % t)
        elif not fb:
            warn('color',
             "%s: color %r has no fallback_colors. If that descriptor is "
                 "not loaded the material renders grey with no error."
                 % (t, x.get('color')))

        # ---- dye colour override ----
        # Read by RM only on a dye (IS_DYE from the DYE class or a
        # material_flags override). Anywhere else it does nothing.
        dc = x.get('dye_color')
        if dc is not None and not is_str(dc):
            err("%s.dye_color must be a string or null" % t)
        elif dc is not None and cls != 'DYE' \
                and not (x.get('material_flags') or {}).get('IS_DYE'):
            warn('dye_color',
             "%s: dye_color is set but the material is not a dye (class "
                 "%r, no IS_DYE flag). RM ignores it." % (t, cls))

        # ---- a dye declared as an inorganic ----
        # Measured 2026-09-23: DF stores an inorganic powder as its bag,
        # under Furniture as Bags, with no listing by material (vanilla
        # plaster does the same). Registered under Milled Plants anyway,
        # it is listed by name and never hauled there. A dye declared on
        # a plant host lists and hauls under Milled Plants like vanilla.
        if cls == 'DYE' or (x.get('material_flags') or {}).get('IS_DYE'):
            warn('inorganic_dye',
             "%s: a dye declared as an inorganic. DF stores its bag under "
                 "Furniture with no listing by name, so players cannot find "
                 "it. Declare dyes on a plant host in the plants file." % t)

        # ---- numbers ----
        for f in ('value', 'solid_density', 'liquid_density', 'molar_mass'):
            if not is_nil_or_num(x.get(f)):
                err("%s.%s must be a number or null" % (t, f))

        heat = x.get('heat')
        if heat is not None:
            if not isinstance(heat, dict):
                err("%s.heat must be a table or null" % t)
            else:
                for f in heat_fields:
                    if not is_nil_or_num(heat.get(f)):
                        err("%s.heat.%s must be a number or null" % (t, f))

        st = x.get('strength')
        if st is not None:
            if not isinstance(st, dict):
                err("%s.strength must be a table or null" % t)
            else:
                for group in ('yield', 'fracture', 'strain_at_yield'):
                    g = st.get(group)
                    if g is None:
                        continue
                    if not isinstance(g, dict):
                        err("%s.strength.%s must be a table or null" % (t, group))
                        continue
                    for f in stress_fields:
                        if not is_nil_or_num(g.get(f)):
                            err("%s.strength.%s.%s must be a number or null"
                                % (t, group, f))
                if not is_nil_or_num(st.get('max_edge')):
                    err("%s.strength.max_edge must be a number or null" % t)

        # ---- gem names ----
        g = x.get('gem_names')
        if g is not None:
            if not isinstance(g, list) or len(g) != 2:
                err("%s.gem_names must be an array of exactly 2 strings or null" % t)
            elif not (is_str(g[0]) and is_str(g[1])):
                err("%s.gem_names entries must be strings" % t)
        if cls == 'GEM' and g is None:
            err("%s: material_class GEM requires gem_names" % t)

        # ---- item type name overrides ----
        # block_name is a {singular, plural} pair suffixed onto the
        # material name. stone_name is one already-plural string that
        # replaces the name outright. Different shapes, same purpose.
        bn = x.get('block_name')
        if bn is not None:
            if not isinstance(bn, list) or len(bn) != 2:
                err("%s.block_name must be an array of exactly 2 strings or null" % t)
            elif not (is_str(bn[0]) and is_str(bn[1])):
                err("%s.block_name entries must be strings" % t)

        sn = x.get('stone_name')
        if sn is not None and not is_str(sn):
            err("%s.stone_name must be a single string or null, not a pair" % t)

        # ---- classes and products ----
        rc = x.get('reaction_classes')
        if rc is not None:
            if not isinstance(rc, list):
                err("%s.reaction_classes must be an array or null" % t)
            else:
                for j, c in enumerate(rc, 1):
                    if not is_str(c):
                        err("%s.reaction_classes[%d] must be a string" % (t, j))

        gfx = x.get('graphics')
        if gfx is not None:
            if not isinstance(gfx, dict):
                err("%s.graphics must be a table or null" % t)
            else:
                slots = ('bar', 'boulder', 'wood', 'rough',
                         'cheese', 'texflag')
                for slot, entry in gfx.items():
                    if slot not in slots:
                        err("%s.graphics has unknown slot '%s'"
                            % (t, slot))
                    elif is_str(entry):
                        pass
                    elif isinstance(entry, dict):
                        if not is_nonempty_str(entry.get('donor')):
                            err("%s.graphics.%s.donor must be a string"
                                % (t, slot))
                        if entry.get('offset') is not None and \
                           not isinstance(entry['offset'], (int, float)):
                            err("%s.graphics.%s.offset must be a number"
                                % (t, slot))
                    else:
                        err("%s.graphics.%s must be a donor string"
                            " or a table" % (t, slot))

        rp = x.get('reaction_products')
        if rp is not None:
            if not isinstance(rp, list):
                err("%s.reaction_products must be an array or null" % t)
            else:
                for j, p in enumerate(rp, 1):
                    if not isinstance(p, dict):
                        err("%s.reaction_products[%d] must be a table" % (t, j))
                        continue
                    if not is_nonempty_str(p.get('id')):
                        err("%s.reaction_products[%d].id is required" % (t, j))
                    if not is_nonempty_str(p.get('mat_id')):
                        err("%s.reaction_products[%d].mat_id is required" % (t, j))

        for f in ('material_flags', 'inorganic_flags'):
            if x.get(f) is not None and not isinstance(x[f], dict):
                err("%s.%s must be a table or null" % (t, f))

    return mats


# ===============================================================
# REAGENTS
# ===============================================================
def check_reagent(g, j, tag, engine):
    t = "%s.reagents[%d] (%s)" % (tag, j, g.get('code'))

    if not is_nonempty_str(g.get('code')):
        err("%s.code is required" % t)

    ty = g.get('type')
    if not is_nonempty_str(ty):
        err("%s.type is required" % t)
    elif ty not in engine['reagents']:
        err("%s.type %r is not a recognized reagent type" % (t, ty))
    else:
        needs_mat, needs_metal = engine['reagents'][ty]
        # mat_token is the other way to name the material: any material
        # by full token, a plant's above all (a log's PLANT_MAT:<tree>:WOOD).
        tok = g.get('mat_token')
        if tok is not None and not is_nonempty_str(tok):
            err("%s.mat_token must be a non-empty string" % t)
        if needs_mat and not is_nonempty_str(g.get('mat_id')) \
           and not is_nonempty_str(tok):
            if is_sentinel(g, 'mat_id'):
                warn('sentinel',
                     "%s: mat_id is explicitly null. Your module Lua must fill "
                     "it in before returning the data, or the engine rejects "
                     "this reagent." % t)
            else:
                err("%s: type %r requires mat_id or mat_token" % (t, ty))
        if needs_metal and not is_nonempty_str(g.get('metal_id')):
            if is_sentinel(g, 'metal_id'):
                warn('sentinel',
                     "%s: metal_id is explicitly null. Your module Lua must "
                     "fill it in before returning the data." % t)
            else:
                err("%s: type %r requires metal_id" % (t, ty))

    if not is_num(g.get('quantity')):
        err("%s.quantity must be a number" % t)

    if g.get('flags') is not None and not isinstance(g['flags'], dict):
        err("%s.flags must be a table or null" % t)

    for f in ('contains', 'contains_in'):
        if g.get(f) is not None and not is_str(g[f]):
            err("%s.%s must be a string or null" % (t, f))

    for f in ('has_material_reaction_product', 'reaction_class'):
        if not is_nil_or_str(g.get(f)):
            err("%s.%s must be a string or null" % (t, f))

    # vector_id names one of DF's 136 item vectors. The engine resolves
    # it against the live enum and leaves the field alone on a miss, so
    # a typo cannot open the filter, but it does mean the gate the
    # author wanted silently is not there. Caught here instead, hours
    # earlier and without a game running.
    # has_tool_use resolves by name through df.tool_uses. A miss no
    # longer silently reaches -1, the wildcard, but the engine can only
    # say so once the game is running. Said here first.
    tu = g.get('has_tool_use')
    if tu is not None:
        if not is_nonempty_str(tu):
            err("%s.has_tool_use must be a string or null" % t)
        elif engine.get('tool_uses') and tu not in engine['tool_uses']:
            err("%s.has_tool_use %r is not a df.tool_uses value. "
                "See TOOL_USES in the types file." % (t, tu))

    vid = g.get('vector_id')
    if vid is not None:
        if not is_nonempty_str(vid):
            err("%s.vector_id must be a string or null" % t)
        elif engine.get('vectors') and vid not in engine['vectors']:
            err("%s.vector_id %r is not a df.job_item_vector_id value. "
                "See JOB_ITEM_VECTORS in the types file." % (t, vid))

    # ---- warnings the validator does not raise ----
    flags = g.get('flags') or {}

    # A flag name react.lua does not recognise is silently discarded.
    # Nothing errors, the reagent just quietly matches more than it was
    # meant to. Catching typos here is the only place it gets caught.
    #
    # Mirrors refinish-module-react.lua: the explicit mappings in
    # build_reagent plus every entry in REAGENT_FLAG_MAP. Re-copy this
    # set whenever that file gains flags.
    for name in flags:
        if name not in KNOWN_REAGENT_FLAGS:
            err("%s.flags.%s is not a recognized flag name. The reaction "
                "builder ignores unknown flags, so the filter you intended "
                "will not be applied." % (t, name))

    # unrotten is a positive requirement. Setting it false does not mean
    # "must be rotten", it means no rot requirement at all, which is the
    # default. DF has no filter for requiring rot.
    if flags.get('unrotten') is False:
        warn('dead_field',
             "%s: unrotten false is a no-op, not an inverse. DF cannot "
             "require an item be rotten. Omit the flag." % t)

    # The two flags that can consume something irreplaceable.
    if flags.get('allow_artifact'):
        warn('artifact_risk',
             "%s: allow_artifact lets this reagent take an artifact. If the "
             "reaction consumes its input the artifact is gone. Pair with "
             "non_artifact instead unless this is deliberate." % t)
    if flags.get('crafted_artifact'):
        warn('artifact_risk',
             "%s: crafted_artifact REQUIRES an artifact rather than "
             "permitting one. This reagent will seek out exactly the items "
             "most players never want consumed." % t)

    # contains_in is accepted by the validator but the reaction builder
    # never reads it. It does nothing.
    if g.get('contains_in') is not None:
        warn('dead_field',
         "%s: contains_in is validated but the reaction builder ignores it. "
             "Put contains on the container instead." % t)

    # sand_bearing sits at the reagent root, not in flags. Inside flags
    # it is silently discarded.
    if 'sand_bearing' in flags:
        err("%s: sand_bearing belongs at the root of the reagent, not inside "
            "flags. Inside flags it is silently ignored." % t)

    if g.get('sand_bearing') and g.get('mat_id'):
        warn('redundant_filter',
             "%s: sand_bearing plus mat_id means an item must satisfy both. "
             "Once the material is known the flag is redundant and is one more "
             "filter that can reject a valid bag." % t)

    # Item type -1 reagents match everything until narrowed.
    if ty == 'ANY_CRAFT' and not g.get('reaction_class'):
        warn('wildcard_reagent',
             "%s: ANY_CRAFT is item type -1. Without a reaction_class it "
             "matches every craft in the fortress." % t)
    if ty == 'BODY_PART':
        # body_part alone is sufficient. Verified live: a reagent
        # carrying only body_part took raw hides and left coal bars and
        # pitch buckets alone. The narrowing flags are optional.
        if not flags.get('body_part'):
            warn('wildcard_reagent',
                 "%s: BODY_PART is item type -1 and the flags do all the "
                 "filtering. Without flags.body_part it matches every item "
                 "in the fortress, including bars, buckets and furniture." % t)
    if ty == 'ANY':
        # ANY has no item type at all, so an empty flags block is a
        # reagent that matches literally everything.
        narrowing = [f for f in flags
                     if f not in ('preserve', 'non_artifact', 'unrotten', 'solid')
                     and flags.get(f)]
        if not narrowing:
            warn('wildcard_reagent',
                 "%s: ANY is item type -1 with nothing pinning it. It "
                 "needs at least one filtering flag or it matches every item "
                 "in the fortress." % t)
        if flags.get('furniture') and not flags.get('not_bin'):
            warn('wildcard_reagent',
                 "%s: the furniture category includes containers. Without "
                 "not_bin this reagent will take barrels and bins off the "
                 "stockpile floor." % t)
        if not flags.get('non_artifact'):
            warn('artifact_risk',
                 "%s: an item type -1 reagent without non_artifact will "
                 "eventually reach an artifact." % t)
    if ty == 'CONTAINER':
        warn('wildcard_reagent',
             "%s: CONTAINER is item type -1 and DF will accept a metal bar or a "
             "weapon as a container. Use BUCKET or BARREL." % t)

    if flags.get('in_container') and not g.get('contains'):
        pass  # the container side is checked at reaction level


# ===============================================================
# REAGENT FLAG VOCABULARY
# ===============================================================
# Every flag name refinish-module-react.lua acts on. Anything else in a
# flags block is discarded by the reaction builder without complaint.
#
# Grouped the way react.lua handles them, not the way DF groups them by
# bitfield, so the two files can be diffed against each other.
KNOWN_REAGENT_FLAGS = frozenset((
    # reagent-level, not job item filter bits. does_not_determine_
    # product_amount is real: build_reagent maps it directly onto the
    # reagent flags (refinish-module-react.lua), it was just never
    # copied into this set, so preflight called nine healthy reagents
    # broken.
    'preserve', 'in_container', 'does_not_determine_product_amount',

    # mapped explicitly in build_reagent
    'empty', 'glass_material', 'unrotten',
    'non_economic', 'building_material', 'fire_safe', 'magma_safe',
    'allow_melt_dump',
    'body_part', 'bone', 'shell', 'horn', 'pearl', 'ivory_tooth',
    'totemable', 'leather', 'silk', 'yarn', 'hair_wool', 'soap', 'plant',
    'furniture', 'finished_goods', 'ammo', 'not_bin', 'solid',
    'unimproved', 'any_raw_material',
    'wood', 'stone', 'metal', 'hard', 'woven', 'grown_not_crafted',
    'non_artifact',

    # REAGENT_FLAG_MAP flags1
    'improvable', 'butcherable', 'millable', 'allow_buryable',
    'undisturbed', 'collected', 'sharpenable', 'murdered', 'processable',
    'cookable', 'extract_bearing_plant', 'extract_bearing_fish',
    'extract_bearing_vermin', 'processable_to_vial',
    'processable_to_barrel', 'tameable_vermin', 'nearby', 'milk',
    'milkable', 'lye_bearing',

    # REAGENT_FLAG_MAP flags2
    'dye', 'dyeable', 'dyed', 'sewn_imageless', 'glass_making', 'screw',
    'deep_material', 'melt_designated', 'allow_artifact',
    'plaster_containing', 'lye_milk_free', 'blunt', 'unengraved',

    # REAGENT_FLAG_MAP flags3
    'non_absorbent', 'non_pressed', 'allow_liquid_powder', 'any_craft',
    'food_storage', 'sand', 'can_use_location_reserved', 'written_on',
    'edged', 'on_ground', 'divine', 'crafted_artifact', 'gem',
    'empty_or_water',
))


# ===============================================================
# PRODUCTS
# ===============================================================
def check_product(p, j, tag, codes, engine):
    t = "%s.products[%d]" % (tag, j)

    ptype = p.get('type')
    if not is_nonempty_str(ptype):
        err("%s.type is required" % t)
        return

    if ptype not in engine['products'] and ptype not in DF_ITEM_TYPES:
        # The validator accepts any df.item_type name too. This script
        # checks its own advisory copy of that enum and flags anything in
        # neither list, rather than failing it.
        warn('unnamed_product_type',
             "%s.type %r is neither a named product type nor a df.item_type "
             "name this script knows. The engine accepts it only if the DF enum "
             "has it, otherwise the product is skipped with a console message."
             % (t, ptype))

    # ---- improvement products: different class, different rules ----
    if ptype == 'IMPROVEMENT':
        if not is_nonempty_str(p.get('improvement_type')):
            err("%s.improvement_type is required for IMPROVEMENT products" % t)
        if not is_nonempty_str(p.get('target_reagent')):
            err("%s.target_reagent is required for IMPROVEMENT products" % t)
        gmp = p.get('get_material_product')
        if (not isinstance(gmp, dict)
                or not is_nonempty_str(gmp.get('reagent_code'))
                or not is_nonempty_str(gmp.get('product_code'))):
            err("%s: IMPROVEMENT products require get_material_product with "
                "reagent_code and product_code" % t)
        elif gmp['reagent_code'] not in codes:
            err("%s.get_material_product.reagent_code references unknown code %r"
                % (t, gmp['reagent_code']))
        if p.get('mat_id') is not None or p.get('get_material_same') is not None:
            err("%s: IMPROVEMENT products cannot use mat_id or get_material_same" % t)
        if p.get('target_reagent') and p['target_reagent'] not in codes:
            err("%s.target_reagent references unknown code %r"
                % (t, p['target_reagent']))
        return

    # ---- builtin-material products name no material ----
    builtin = engine['products'].get(ptype, False)
    # mat_token is the fourth material mode: a full token resolved
    # live at build time, for plant materials whose mat_type is 419
    # plus the host plant's own index and so cannot live in a table.
    sources = sum(1 for f in ('mat_id', 'mat_token', 'get_material_same',
                              'get_material_product')
                  if p.get(f) is not None)

    if not (builtin and sources == 0):
        if sources == 0 and is_sentinel(p, 'mat_id'):
            warn('sentinel',
                 "%s: mat_id is explicitly null. Your module Lua must fill it "
                 "in before returning the data, or the engine rejects this "
                 "product." % t)
        elif sources == 0:
            err("%s: must specify exactly one of mat_id, get_material_same, or "
                "get_material_product" % t)
        elif sources > 1:
            err("%s: only one of mat_id, get_material_same, or "
                "get_material_product allowed" % t)

    gmp = p.get('get_material_product')
    if gmp is not None:
        if not isinstance(gmp, dict):
            err("%s.get_material_product must be a table" % t)
        else:
            if not is_nonempty_str(gmp.get('reagent_code')):
                err("%s.get_material_product.reagent_code is required" % t)
            elif gmp['reagent_code'] not in codes:
                err("%s.get_material_product.reagent_code references unknown "
                    "code %r" % (t, gmp['reagent_code']))
            if not is_nonempty_str(gmp.get('product_code')):
                err("%s.get_material_product.product_code is required" % t)

    gms = p.get('get_material_same')
    if gms is not None and gms not in codes:
        err("%s.get_material_same references unknown code %r" % (t, gms))

    tc = p.get('to_container')
    if tc is not None and tc not in codes:
        err("%s.to_container references unknown code %r" % (t, tc))

    for f in ('count', 'dimension', 'probability'):
        if p.get(f) is not None and not is_num(p[f]):
            err("%s.%s must be a number or null" % (t, f))


# ===============================================================
# REACTIONS
# ===============================================================
VALID_PERM_MODES = {'AUTO', 'ENTITY_CODE', 'NONE'}


def check_reactions(doc, engine, label):
    rxns = doc.get('reactions')
    if not isinstance(rxns, list):
        err("%s: missing 'reactions' array" % label)
        return []
    if not rxns:
        err("%s: 'reactions' array is empty" % label)
        return []

    seen = set()
    for i, r in enumerate(rxns):
        t = "reactions[%d] (%s)" % (i, r.get('key'))

        k = r.get('key')
        if not is_nonempty_str(k):
            err("%s.key must be a non-empty string" % t)
        elif k in seen:
            err("%s.key is duplicated" % t)
        else:
            seen.add(k)

        if not is_nonempty_str(r.get('name')):
            err("%s.name must be a non-empty string" % t)

        b = r.get('building')
        if not is_nonempty_str(b):
            err("%s.building is required" % t)
        elif b not in engine['buildings']:
            err("%s.building %r is not a recognized building type" % (t, b))

        s = r.get('skill')
        if s is not None:
            if not is_str(s):
                err("%s.skill must be a string or null" % t)
            elif engine['skills'] and s not in engine['skills']:
                err("%s.skill %r is not a recognized skill" % (t, s))
        else:
            warn('no_skill',
                 "%s: no skill set. The reaction inherits whichever skill the "
                 "cloned structural template happened to carry." % t)

        if r.get('fuel') is not None and not isinstance(r['fuel'], bool):
            err("%s.fuel must be true, false, or null" % t)
        if not is_nil_or_str(r.get('category')):
            err("%s.category must be a string or null" % t)
        if not is_nil_or_str(r.get('fallback_template')):
            err("%s.fallback_template must be a string or null" % t)

        # ---- permissions ----
        perm = r.get('permissions')
        if perm is not None:
            if not isinstance(perm, dict):
                err("%s.permissions must be a table or null" % t)
                perm = {}
            mode = perm.get('mode')
            if mode is not None:
                if not is_str(mode):
                    err("%s.permissions.mode must be a string or null" % t)
                elif mode not in VALID_PERM_MODES:
                    err("%s.permissions.mode %r is not recognized "
                        "(valid: AUTO, ENTITY_CODE, NONE)" % (t, mode))
            if mode == 'ENTITY_CODE':
                ents = perm.get('entities')
                if not isinstance(ents, list) or not ents:
                    err("%s.permissions: ENTITY_CODE mode requires a non-empty "
                        "'entities' array" % t)
                else:
                    for j, e in enumerate(ents, 1):
                        if not is_nonempty_str(e):
                            err("%s.permissions.entities[%d] must be a non-empty "
                                "string" % (t, j))
            elif perm.get('entities') is not None:
                err("%s.permissions: 'entities' should only be set with "
                    "ENTITY_CODE mode" % t)

        # ---- reaction flags ----
        rf = r.get('reaction_flags')
        if rf is not None:
            if not isinstance(rf, dict):
                err("%s.reaction_flags must be a table or null" % t)
            elif (rf.get('fortress_mode') is not None
                  and not isinstance(rf['fortress_mode'], bool)):
                err("%s.reaction_flags.fortress_mode must be true, false, or null" % t)

        # NONE permissions with no fortress_mode bypass makes a reaction
        # nobody can run. Legal, and almost never intended.
        mode = (perm or {}).get('mode')
        fort = (rf or {}).get('fortress_mode')
        if mode == 'NONE' and not fort:
            warn('unreachable',
                 "%s: permissions NONE with fortress_mode false or unset. No "
                 "civilization gets this reaction and the player cannot bypass, "
                 "so nobody can run it." % t)

        # ---- reagents ----
        rgts = r.get('reagents')
        if not isinstance(rgts, list) or not rgts:
            err("%s.reagents must be a non-empty array" % t)
            rgts = []

        codes = set()
        for j, g in enumerate(rgts, 1):
            if not isinstance(g, dict):
                err("%s.reagents[%d] must be a table" % (t, j))
                continue
            check_reagent(g, j, t, engine)
            c = g.get('code')
            if c in codes:
                err("%s.reagents[%d].code %r is duplicated" % (t, j, c))
            if is_nonempty_str(c):
                codes.add(c)

        for j, g in enumerate(rgts, 1):
            if not isinstance(g, dict):
                continue
            for f in ('contains', 'contains_in'):
                v = g.get(f)
                if v is not None and v not in codes:
                    err("%s.reagents[%d].%s references unknown code %r"
                        % (t, j, f, v))

        # Container pairing. A slot marked in_container with nothing
        # declaring that it contains it will never be filled.
        contained = {g.get('contains') for g in rgts
                     if isinstance(g, dict) and g.get('contains')}
        for g in rgts:
            if not isinstance(g, dict):
                continue
            if (g.get('flags') or {}).get('in_container') and g.get('code') not in contained:
                warn('container_pairing',
                     "%s: reagent %r is flagged in_container but no other "
                     "reagent declares 'contains' pointing at it. The slot will "
                     "never be filled." % (t, g.get('code')))

        # ---- products ----
        prods = r.get('products')
        if not isinstance(prods, list) or not prods:
            err("%s.products must be a non-empty array" % t)
            prods = []
        for j, p in enumerate(prods, 1):
            if not isinstance(p, dict):
                err("%s.products[%d] must be a table" % (t, j))
                continue
            check_product(p, j, t, codes, engine)

        # A container that receives output should be preserved and empty.
        for p in prods:
            if not isinstance(p, dict):
                continue
            tc = p.get('to_container')
            if not tc:
                continue
            for g in rgts:
                if isinstance(g, dict) and g.get('code') == tc:
                    f = g.get('flags') or {}
                    if not f.get('preserve'):
                        warn('container_pairing',
                             "%s: reagent %r receives output via to_container "
                             "but is not flagged preserve, so it is consumed."
                             % (t, tc))
                    if not f.get('empty'):
                        warn('container_pairing',
                             "%s: reagent %r receives output via to_container "
                             "but is not flagged empty, so a full bag can be "
                             "chosen." % (t, tc))

    return rxns


# ===============================================================
# CATEGORIES
# ===============================================================
def check_categories(doc, label):
    cats = doc.get('categories')
    if cats is None:
        return []
    if not isinstance(cats, list):
        err("%s: 'categories' must be an array" % label)
        return []

    seen = set()
    for i, c in enumerate(cats):
        t = "categories[%d] (%s)" % (i, c.get('key'))
        if not is_nonempty_str(c.get('key')):
            err("%s.key must be a non-empty string" % t)
        elif c['key'] in seen:
            err("%s.key is duplicated" % t)
        else:
            seen.add(c['key'])

        if not is_nonempty_str(c.get('name')):
            err("%s.name must be a non-empty string" % t)
        if not is_str(c.get('parent', '')):
            err("%s.parent must be a string (empty for top-level)" % t)
        if not is_nil_or_str(c.get('description')):
            err("%s.description must be a string or null" % t)
        if not is_nil_or_str(c.get('hotkey')):
            err("%s.hotkey must be a string or null" % t)

    return cats


# ===============================================================
# CROSS-REFERENCE CHECKS
# ===============================================================
# Not in the validator. These catch the failures that pass validation
# and then go wrong silently in game: a mat_id that resolves to -1 and
# matches nothing, a category ID written without its prefix.
# ===============================================================
def check_cross_references(prefix, mats, rxns, cats):
    own_ids = {prefix + m['key'] for m in mats
               if is_nonempty_str(m.get('key'))}
    cat_ids = {prefix + 'CAT_' + c['key'] for c in cats
               if is_nonempty_str(c.get('key'))}

    def check_id(value, where):
        """A prefixed ID must be one this module actually declares.
        Anything unprefixed is vanilla or another module and cannot be
        resolved offline."""
        if not is_nonempty_str(value):
            return
        if value.startswith(prefix) and value not in own_ids:
            err("%s references %r, which this module's prefix claims but no "
                "material declares" % (where, value))

    for m in mats:
        for rp in m.get('reaction_products') or []:
            if isinstance(rp, dict):
                check_id(rp.get('mat_id'),
                         "materials (%s).reaction_products" % m.get('key'))

    for r in rxns:
        tag = "reactions (%s)" % r.get('key')
        for g in r.get('reagents') or []:
            if isinstance(g, dict):
                check_id(g.get('mat_id'), tag + " reagent %r" % g.get('code'))
                check_id(g.get('metal_id'), tag + " reagent %r" % g.get('code'))
        for p in r.get('products') or []:
            if isinstance(p, dict):
                check_id(p.get('mat_id'), tag + " product")

        cat = r.get('category')
        if is_nonempty_str(cat):
            if cat in cat_ids:
                continue
            bare = [c['key'] for c in cats if c.get('key') == cat]
            if bare:
                err("%s.category is %r, the bare key. A reaction needs the full "
                    "ID: %r" % (tag, cat, prefix + 'CAT_' + cat))
            elif cat.startswith(prefix):
                err("%s.category %r is not declared in the categories array"
                    % (tag, cat))
            else:
                warn('external_category',
                     "%s.category %r is not declared here. That is legal if it "
                     "names a category some other module already injected."
                     % (tag, cat))

    # Category parents name a bare key, unlike reaction categories.
    declared = {c['key'] for c in cats if is_nonempty_str(c.get('key'))}
    for c in cats:
        p = c.get('parent')
        if is_nonempty_str(p) and p not in declared:
            if p.startswith(prefix + 'CAT_'):
                warn('category_parent',
                     "categories (%s).parent is %r, the full prefixed ID. This "
                     "works, because an unrecognised parent is passed through "
                     "unchanged, but the documented form is the bare key."
                     % (c.get('key'), p))
            else:
                warn('category_parent',
                     "categories (%s).parent %r is not declared here. Legal if "
                     "it names a category that already exists. Note parent "
                     "takes the BARE key, unlike a reaction's category field."
                     % (c.get('key'), p))


# ===============================================================
# PLANTS
# ===============================================================
# A plant is a HOST: a shell whose own materials a module addresses
# as PLANT_MAT:<PLANT ID>:<KEY>. It exists because a bar of an
# inorganic material displays "charcoal bars" while the same bar of a
# plant material displays "charcoal", and material mode is the only
# lever on that suffix.
#
# The file is OPTIONAL. A module without one is the normal case and
# is not warned about.
# ===============================================================
def check_plants(doc, engine, label):
    """Validate the plants array. Returns the list of plant dicts."""
    if not is_table(doc):
        err("%s is not a JSON object" % label)
        return []

    plants = doc.get('plants')
    if plants is None:
        return []
    if not isinstance(plants, list):
        err("%s: 'plants' must be an array" % label)
        return []

    seen = set()
    for i, pl in enumerate(plants):
        t = "%s plants[%d]" % (label, i)
        if not is_table(pl):
            err("%s is not an object" % t)
            continue

        key = pl.get('key')
        if not is_nonempty_str(key):
            err("%s.key is required" % t)
        elif key in seen:
            err("%s.key %r is duplicated" % (t, key))
        else:
            seen.add(key)
            t = "%s plants (%s)" % (label, key)

        if not is_nonempty_str(pl.get('name')):
            err("%s.name is required" % t)

        # donor_plant names a plant in the RAWS, not in this file, so
        # it cannot be resolved offline. Only its shape is checked.
        if not is_nil_or_str(pl.get('donor_plant')):
            err("%s.donor_plant must be a string" % t)

        mats = pl.get('materials')
        if mats is None:
            warn('plant_no_materials',
                 "%s declares no materials, so it keeps the donor's as "
                 "placeholders. Legal, but nothing can address it." % t)
            continue
        if not isinstance(mats, list) or not mats:
            err("%s.materials must be a non-empty array" % t)
            continue

        mseen = set()
        for j, md in enumerate(mats):
            mt = "%s.materials[%d]" % (t, j)
            if not is_table(md):
                err("%s is not an object" % mt)
                continue

            mkey = md.get('key')
            if not is_nonempty_str(mkey):
                err("%s.key is required" % mt)
            elif mkey in mseen:
                err("%s.key %r is duplicated on this plant" % (mt, mkey))
            else:
                mseen.add(mkey)
                mt = "%s.materials (%s)" % (t, mkey)

            # The key must NOT repeat the module prefix: the plant's own
            # id already carries it, and the token is built from both.
            if is_nonempty_str(mkey) and is_nonempty_str(doc.get('module', {}).get('prefix')) \
               and mkey.startswith(doc['module']['prefix']):
                err("%s.key repeats the module prefix. The token is built as "
                    "PLANT_MAT:<prefixed plant id>:<key>, so the key is bare."
                    % mt)

            if not is_nonempty_str(md.get('name')):
                err("%s.name is required, and it is what the item displays "
                    "as: a blank name renders a leading space." % mt)

            cls = md.get('material_class')
            if is_nonempty_str(cls) and cls not in engine['classes']:
                err("%s.material_class %r is not a recognized class" % (mt, cls))

            # Same rule as the inorganic check: read only on a dye, and
            # on this path only the DYE class makes one (plant materials
            # take no material_flags overrides).
            dc = md.get('dye_color')
            if dc is not None and not is_str(dc):
                err("%s.dye_color must be a string or null" % mt)
            elif dc is not None and cls != 'DYE':
                warn('dye_color',
                     "%s: dye_color is set but the material is not a dye (class "
                     "%r). RM ignores it." % (mt, cls))

            rcs = md.get('reaction_classes')
            if rcs is not None:
                if not isinstance(rcs, list):
                    err("%s.reaction_classes must be an array" % mt)
                else:
                    for rc in rcs:
                        if not is_nonempty_str(rc):
                            err("%s.reaction_classes holds a non-string" % mt)

            for numf in ('solid_density', 'value'):
                if not is_nil_or_num(md.get(numf)):
                    err("%s.%s must be a number" % (mt, numf))

    return plants


def check_plant_tokens(prefix, plants, rxns):
    """Every mat_token naming this module's own plant host must name a
    plant and a material that exist.

    This is the check that would have caught a cinder pointed at a
    material nobody declared: the engine resolves a token live and
    logs a warning, but the reaction is already injected by then and
    the product silently makes nothing."""
    known = set()
    for pl in plants:
        pkey = pl.get('key')
        if not is_nonempty_str(pkey):
            continue
        pid = prefix + pkey
        for md in pl.get('materials') or []:
            if is_table(md) and is_nonempty_str(md.get('key')):
                known.add('PLANT_MAT:%s:%s' % (pid, md['key']))

    for r in rxns:
        tag = "reactions (%s)" % r.get('key')
        # Reagents name materials by token too (a log's
        # PLANT_MAT:<tree>:WOOD), so both halves get the same check.
        slots = [('product', x) for x in (r.get('products') or [])] + \
                [('reagent', x) for x in (r.get('reagents') or [])]
        for kind, p in slots:
            if not is_table(p):
                continue
            tok = p.get('mat_token')
            if not is_nonempty_str(tok):
                continue

            parts = tok.split(':')
            if len(parts) != 3:
                err("%s %s mat_token %r is malformed. The form is "
                    "PLANT_MAT:<plant id>:<material key>." % (tag, kind, tok))
                continue
            if parts[0] != 'PLANT_MAT':
                # INORGANIC, CREATURE_MAT and the rest are legal and
                # cannot be resolved offline.
                continue
            if not parts[1].startswith(prefix):
                # A vanilla or other mod's plant, resolved at build time.
                continue
            if tok not in known:
                err("%s %s mat_token %r names this module's prefix but "
                    "no plant material declares it. Check the plants file "
                    "for that plant key and material key." % (tag, kind, tok))


# ===============================================================
# TOOLS
# ===============================================================
# Injected itemdefs. A reaction addresses one by its FULL id, prefix
# and all, in a reagent's tool_id or in a product's subtype.
#
# The file is OPTIONAL. What is not optional, once a reaction names a
# tool, is that the tool exists: an unknown itemdef leaves the slot
# UNRESTRICTED, so the reaction still injects and then accepts any
# tool at all, which is worse than failing.
# ===============================================================
def check_tools(doc, label):
    """Validate the tools array. Returns the list of tool dicts."""
    if not is_table(doc):
        err("%s is not a JSON object" % label)
        return []
    tools = doc.get('tools')
    if tools is None:
        return []
    if not isinstance(tools, list):
        err("%s: 'tools' must be an array" % label)
        return []

    seen = set()
    for i, td in enumerate(tools):
        t = "%s tools[%d]" % (label, i)
        if not is_table(td):
            err("%s is not an object" % t)
            continue

        key = td.get('key')
        if not is_nonempty_str(key):
            err("%s.key is required" % t)
        elif key in seen:
            err("%s.key %r is duplicated" % (t, key))
        else:
            seen.add(key)
            t = "%s tools (%s)" % (label, key)

        for f in ('name', 'name_plural'):
            if not is_nonempty_str(td.get(f)):
                err("%s.%s is required" % (t, f))

        for f in ('value', 'tile', 'size', 'material_size', 'capacity'):
            if not is_nil_or_num(td.get(f)):
                err("%s.%s must be a number" % (t, f))

        tu = td.get('tool_use')
        if tu is not None:
            if not isinstance(tu, list):
                err("%s.tool_use must be an array" % t)
            else:
                for u in tu:
                    if not is_nonempty_str(u):
                        err("%s.tool_use holds a non-string" % t)

        fl = td.get('flags')
        if fl is not None and not is_table(fl):
            err("%s.flags must be an object" % t)

    return tools


# ===============================================================
# BUILDINGS
# ===============================================================
# Injected workshops and furnaces. A reaction names one by its BARE
# key, unlike a tool: "RETORT", not "MAKING_FUEL_RETORT". A reaction
# may equally name a vanilla building, so an unrecognised code is an
# error only when it is neither vanilla nor declared here.
# ===============================================================
def check_buildings(doc, engine, label):
    """Validate the buildings array. Returns the list of dicts."""
    if not is_table(doc):
        err("%s is not a JSON object" % label)
        return []
    blds = doc.get('buildings')
    if blds is None:
        return []
    if not isinstance(blds, list):
        err("%s: 'buildings' must be an array" % label)
        return []

    seen = set()
    for i, bd in enumerate(blds):
        t = "%s buildings[%d]" % (label, i)
        if not is_table(bd):
            err("%s is not an object" % t)
            continue

        key = bd.get('key')
        if not is_nonempty_str(key):
            err("%s.key is required" % t)
        elif key in seen:
            err("%s.key %r is duplicated" % (t, key))
        else:
            seen.add(key)
            t = "%s buildings (%s)" % (label, key)

        cls = bd.get('class')
        if cls not in ('WORKSHOP', 'FURNACE'):
            err("%s.class must be WORKSHOP or FURNACE, got %r" % (t, cls))

        if not is_nonempty_str(bd.get('name')):
            err("%s.name is required" % t)

        # dim, workloc and block have to agree. A work tile outside the
        # footprint is a building nobody can use, and a block grid of
        # the wrong shape is read row by row into the wrong cells.
        dim = bd.get('dim')
        if not (isinstance(dim, list) and len(dim) == 2
                and all(is_num(v) and v > 0 for v in dim)):
            err("%s.dim must be two positive numbers" % t)
        else:
            wl = bd.get('workloc')
            if wl is not None:
                if not (isinstance(wl, list) and len(wl) == 2
                        and all(is_num(v) for v in wl)):
                    err("%s.workloc must be two numbers" % t)
                elif not (0 <= wl[0] < dim[0] and 0 <= wl[1] < dim[1]):
                    err("%s.workloc %r is outside dim %r, so the building "
                        "would have no reachable work tile" % (t, wl, dim))

            blk = bd.get('block')
            if blk is not None:
                if not isinstance(blk, list) or len(blk) != dim[1]:
                    err("%s.block must have one row per dim height (%d)"
                        % (t, dim[1]))
                else:
                    for ri, row in enumerate(blk):
                        if not isinstance(row, list) or len(row) != dim[0]:
                            err("%s.block row %d must have %d entries"
                                % (t, ri, dim[0]))

        if not is_nil_or_num(bd.get('build_stages')):
            err("%s.build_stages must be a number" % t)

        # build_items reuse the reagent item types.
        bi = bd.get('build_items')
        if bi is not None:
            if not isinstance(bi, list) or not bi:
                err("%s.build_items must be a non-empty array" % t)
            else:
                for j, it in enumerate(bi):
                    it_t = "%s.build_items[%d]" % (t, j)
                    if not is_table(it):
                        err("%s is not an object" % it_t)
                        continue
                    ty = it.get('type')
                    if not is_nonempty_str(ty):
                        err("%s.type is required" % it_t)
                    elif ty not in engine['reagents']:
                        err("%s.type %r is not a recognized item type"
                            % (it_t, ty))
                    if not is_nil_or_num(it.get('quantity')):
                        err("%s.quantity must be a number" % it_t)

    return blds


def check_asset_references(prefix, tools, blds, rxns, engine):
    """Every tool a reaction names must be declared, and every building
    must be either declared here or known to the engine.

    The tool half is the check that would have caught MAKING_FUEL_TWIG:
    the engine logs 'itemdef not found, slot left unrestricted' and
    injects the reaction anyway, so it silently accepts any tool."""
    own_tools = set()
    for t in tools:
        if is_nonempty_str(t.get('key')):
            own_tools.add(prefix + t['key'])
    own_blds = set()
    for b in blds:
        if is_nonempty_str(b.get('key')):
            own_blds.add(b['key'])

    def check_tool(value, where):
        if not is_nonempty_str(value):
            return
        # ITEM_TOOL_* names a vanilla itemdef, resolved by DF itself.
        if value.startswith('ITEM_TOOL_'):
            return
        if value.startswith(prefix) and value not in own_tools:
            err("%s names tool %r, which this module's prefix claims but no "
                "tool declares. The engine leaves the slot UNRESTRICTED, so "
                "the reaction injects and then accepts any tool."
                % (where, value))

    for r in rxns:
        tag = "reactions (%s)" % r.get('key')
        for g in r.get('reagents') or []:
            if is_table(g):
                check_tool(g.get('tool_id'),
                           tag + " reagent %r" % g.get('code'))
                check_tool(g.get('subtype'),
                           tag + " reagent %r" % g.get('code'))
        for p in r.get('products') or []:
            if is_table(p):
                check_tool(p.get('subtype'), tag + " product")

        b = r.get('building')
        if is_nonempty_str(b) and b not in engine['buildings'] \
           and b not in own_blds:
            err("%s.building %r is neither a known building nor declared in "
                "this module's buildings file. A reaction names a building by "
                "its BARE key, without the module prefix." % (tag, b))


# ===============================================================
# FILE DISCOVERY
# ===============================================================
def autodiscover(folder):
    """Find one module's materials file and all of its reaction files.

    Reactions are either a single <module>_reactions.json or a split set
    of <module>_reactions_<part>.json. Both shapes are ONE module, so the
    set comes back as a list and validates merged, the same shape the
    loader hands the engine.

    Files are grouped by the module prefix, the part before _reactions.
    Two modules sharing a folder is an error rather than a guess, for the
    same reason the optional companions refuse to guess."""
    mats = sorted(glob.glob(os.path.join(folder, '*_materials.json')))
    rxns = sorted(glob.glob(os.path.join(folder, '*_reactions.json'))
                  + glob.glob(os.path.join(folder, '*_reactions_*.json')))
    by_mod = {}
    for p in rxns:
        prefix = os.path.basename(p).split('_reactions')[0]
        by_mod.setdefault(prefix, []).append(p)
    if len(mats) != 1 or len(by_mod) != 1:
        return None, None, (
            "Found %d materials file(s) and %d module(s) of reaction files "
            "in %s.\n"
            "Expected exactly one of each, named <module>_materials.json and\n"
            "either <module>_reactions.json or <module>_reactions_<part>.json,\n"
            "or pass the paths as arguments."
            % (len(mats), len(by_mod), os.path.abspath(folder)))
    return mats[0], sorted(next(iter(by_mod.values()))), None


def autodiscover_optional(folder, suffix, flag):
    """Optional companion file. At most one: more than one is an error
    the caller reports, because guessing which one a module meant is
    the kind of guess that costs a session."""
    found = sorted(glob.glob(os.path.join(folder, '*_%s.json' % suffix)))
    if len(found) == 1:
        return found[0], None
    if not found:
        return None, None
    return None, ("Found %d %s file(s) in %s. Expected at most one named "
                  "<something>_%s.json, or pass %s with its path."
                  % (len(found), suffix, os.path.abspath(folder), suffix, flag))


def autodiscover_plants(folder):
    """Optional. Returns a path or None; more than one is an error the
    caller reports, because guessing which host a module meant is
    exactly the kind of guess that costs a session."""
    found = sorted(glob.glob(os.path.join(folder, '*_plants.json')))
    if len(found) == 1:
        return found[0], None
    if not found:
        return None, None
    return None, ("Found %d plants file(s) in %s. Expected at most one named "
                  "<something>_plants.json, or pass --plants with its path."
                  % (len(found), os.path.abspath(folder)))


def load(path, what):
    if not os.path.exists(path):
        print("Cannot find %s: %s" % (path, what))
        sys.exit(2)
    try:
        return json.load(open(path, encoding='utf-8'))
    except json.JSONDecodeError as e:
        print("%s is not valid JSON: %s" % (path, e))
        print("Fix the syntax error before running preflight again.")
        sys.exit(2)


# ===============================================================
# MAIN
# ===============================================================
def main():
    ap = argparse.ArgumentParser(
        description="Offline schema check for RM module JSON files.")
    ap.add_argument('materials', nargs='?',
                    help="materials JSON (auto-discovered if omitted)")
    ap.add_argument('reactions', nargs='*',
                    help="reactions JSON file(s); pass every part of a "
                         "split set (auto-discovered if omitted)")
    ap.add_argument('--plants',
                    help="plants JSON (auto-discovered if omitted; optional)")
    ap.add_argument('--tools',
                    help="tools JSON (auto-discovered if omitted; optional)")
    ap.add_argument('--buildings',
                    help="buildings JSON (auto-discovered if omitted; optional)")
    ap.add_argument('--types', default='refinish-module-types.lua',
                    help="path to refinish-module-types.lua from your RM install")
    ap.add_argument('--verbose', action='store_true',
                    help="print every warning instead of the first few per group")
    ap.add_argument('--strict', action='store_true',
                    help="treat warnings as failures")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))

    types_path = args.types
    if not os.path.exists(types_path):
        alt = os.path.join(here, os.path.basename(types_path))
        if os.path.exists(alt):
            types_path = alt
        else:
            print("Cannot find %s." % args.types)
            print("Copy refinish-module-types.lua from your Refinish Metal install")
            print("into this folder, or pass --types with its path.")
            sys.exit(2)

    # 'reactions' is now a list so a split set validates as one merged
    # module, the same shape the loader hands the engine.
    mats_path, rxns_paths = args.materials, args.reactions
    if not mats_path or not rxns_paths:
        mats_path, found_rxns, problem = autodiscover(here)
        if problem:
            print(problem)
            sys.exit(2)
        rxns_paths = rxns_paths or found_rxns

    engine = load_engine_types(types_path)
    if not engine['reagents'] or not engine['buildings']:
        print("Parsed %s but found no type tables in it." % types_path)
        print("Check that it is a complete, current copy from your RM install.")
        sys.exit(2)

    plants_path = args.plants
    if not plants_path:
        plants_path, problem = autodiscover_plants(here)
        if problem:
            print(problem)
            sys.exit(2)

    mats_doc = load(mats_path, "this module's materials file")
    # Merge the reaction parts exactly the way the loader does:
    # module from the first file, categories and reactions
    # concatenated in argument order, duplicate keys a hard failure
    # with both files named. Argument order matters for the same
    # reason the loader's list order does: category order is menu
    # tab order.
    rxns_doc = None
    seen_rxn, seen_cat = {}, {}
    for rp in rxns_paths:
        part = load(rp, "this module's reactions file")
        if rxns_doc is None:
            rxns_doc = {'module': part.get('module'),
                        'categories': [], 'reactions': []}
        for cat in part.get('categories') or []:
            k = cat.get('key')
            if k in seen_cat:
                print("Category [%s] defined in both %s and %s."
                      % (k, seen_cat[k], rp))
                sys.exit(2)
            seen_cat[k] = rp
            rxns_doc['categories'].append(cat)
        for rxn in part.get('reactions') or []:
            k = rxn.get('key')
            if k in seen_rxn:
                print("Reaction [%s] defined in both %s and %s."
                      % (k, seen_rxn[k], rp))
                sys.exit(2)
            seen_rxn[k] = rp
            rxns_doc['reactions'].append(rxn)
    rxns_path = ' + '.join(rxns_paths)
    plants_doc = load(plants_path, "this module's plants file") \
        if plants_path else None

    tools_path = args.tools
    if not tools_path:
        tools_path, problem = autodiscover_optional(here, 'tools', '--tools')
        if problem:
            print(problem)
            sys.exit(2)
    blds_path = args.buildings
    if not blds_path:
        blds_path, problem = autodiscover_optional(here, 'buildings',
                                                   '--buildings')
        if problem:
            print(problem)
            sys.exit(2)

    tools_doc = load(tools_path, "this module's tools file") \
        if tools_path else None
    blds_doc = load(blds_path, "this module's buildings file") \
        if blds_path else None

    mats_label = os.path.basename(mats_path)
    rxns_label = os.path.basename(rxns_path)

    # ---- module identity, per file then cross-checked ----
    mats_prefix = check_module_block(mats_doc, mats_label)
    rxns_prefix = check_module_block(rxns_doc, rxns_label)
    if mats_prefix and rxns_prefix and mats_prefix != rxns_prefix:
        err("module.prefix disagrees between files: %s has %r, %s has %r. "
            "The engine rejects the module on this."
            % (mats_label, mats_prefix, rxns_label, rxns_prefix))

    # ---- content ----
    mats = check_materials(mats_doc, engine, mats_label)
    rxns = check_reactions(rxns_doc, engine, rxns_label)
    cats = check_categories(rxns_doc, rxns_label)

    plants = []
    if plants_doc is not None:
        plants_label = os.path.basename(plants_path)
        plants_prefix = check_module_block(plants_doc, plants_label)
        if mats_prefix and plants_prefix and mats_prefix != plants_prefix:
            err("module.prefix disagrees between files: %s has %r, %s has %r."
                % (mats_label, mats_prefix, plants_label, plants_prefix))
        plants = check_plants(plants_doc, engine, plants_label)

    tools, blds = [], []
    if tools_doc is not None:
        tools = check_tools(tools_doc, os.path.basename(tools_path))
    if blds_doc is not None:
        blds = check_buildings(blds_doc, engine, os.path.basename(blds_path))

    if mats_prefix:
        check_cross_references(mats_prefix, mats, rxns, cats)
        check_plant_tokens(mats_prefix, plants, rxns)
        check_asset_references(mats_prefix, tools, blds, rxns, engine)

    # ---- report ----
    print("engine tables from %s: %d reagent types, %d product types, "
          "%d buildings, %d skills, %d material classes"
          % (os.path.basename(types_path), len(engine['reagents']),
             len(engine['products']), len(engine['buildings']),
             len(engine['skills']), len(engine['classes'])))
    checked = [mats_label, rxns_label]
    for pth in (plants_path, tools_path, blds_path):
        if pth:
            checked.append(os.path.basename(pth))
    print("checked " + ", ".join(checked))

    if WARNINGS:
        # Group by kind. A 950-reaction module can produce hundreds of the
        # same warning, and a flat dump buries the one that matters.
        groups = {}
        for kind, msg in WARNINGS:
            groups.setdefault(kind, []).append(msg)

        print("\n%d warning(s) in %d group(s). Warnings do not fail the run."
              % (len(WARNINGS), len(groups)))
        for kind in sorted(groups):
            msgs = groups[kind]
            print("\n  [%s] %d" % (kind, len(msgs)))
            shown = msgs if args.verbose else msgs[:3]
            for m in shown:
                print("    - " + m)
            if len(msgs) > len(shown):
                print("    ... and %d more (run with --verbose to see all)"
                      % (len(msgs) - len(shown)))

    if ERRORS:
        print("\nPREFLIGHT FAILED: %d error(s):\n" % len(ERRORS))
        for e in ERRORS[:40]:
            print("  " + e)
        if len(ERRORS) > 40:
            print("  ... and %d more" % (len(ERRORS) - 40))
        sys.exit(1)

    if WARNINGS and args.strict:
        print("\nPREFLIGHT FAILED: warnings treated as errors (--strict).")
        sys.exit(1)

    n_plant_mats = sum(len(pl.get('materials') or []) for pl in plants)
    print("\nPREFLIGHT PASSED: %d materials, %d reactions, %d categories, "
          "%d plant(s) carrying %d material(s), %d tool(s), %d building(s)"
          % (len(mats), len(rxns), len(cats), len(plants), n_plant_mats,
             len(tools), len(blds)))
    sys.exit(0)


if __name__ == '__main__':
    main()