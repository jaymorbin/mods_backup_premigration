#!/usr/bin/env python3
# =========================================================
# MAKING FUEL: REACTION DESCRIPTION GENERATOR
# =========================================================
# Writes a "description" onto every visible reaction, derived from
# the reaction's own structure so the prose can never drift from the
# data. Plain english, vanilla register, decision-first: what goes
# in, what comes out, and anything that might surprise.
#
# CAUTIONS ARE COMPUTED, NOT REMEMBERED. A furniture wildcard gets
# its barrels-and-buckets warning because the flag is on the
# reagent, not because someone recalled it. Hand knowledge lives in
# OVERRIDES and CAUTIONS below, keyed by reaction key, and only for
# what structure cannot know.
#
# USAGE:  python3 describe.py [part.json ...]
#         No arguments processes the five family files in loader
#         order. Each part writes its own *_described.json (never
#         the input); the manifest and the review file are shared
#         across the whole set, so provenance follows a key
#         wherever its block lives.
# Writes  <part>_described.json                 per input file
# and     descriptions_review.txt               (key<TAB>text, for eyeballing)
# Existing hand-written descriptions in the input are KEPT verbatim.
# =========================================================
import json, sys, os, re

# The reaction set is split across family files. Loader order, for a
# review file that reads in the same sequence as the menus.
SRCS = sys.argv[1:] if len(sys.argv) > 1 else [
    'making_fuel_reactions_split.json',
    'making_fuel_reactions_char.json',
    'making_fuel_reactions_ash.json',
    'making_fuel_reactions_boil.json',
    'making_fuel_reactions_coke.json',
    'making_fuel_reactions_hide.json',
    'making_fuel_reactions_retort.json',
    'making_fuel_reactions_other.json',
    "making_fuel_reactions_distil.json",
]

# ---------------------------------------------------------
# VOCABULARY: structure -> plain english
# ---------------------------------------------------------
# mat_id state words. Base material name reads as the raw state.
def state_word(mat_id):
    if not mat_id: return None
    if mat_id.endswith('_DRIED'): return 'dried'
    if mat_id in ('MAKING_FUEL_DUNG', 'MAKING_FUEL_MASH',
                  'MAKING_FUEL_STRAW', 'PEAT'): return 'fresh'
    return None

def is_adaptive(r):
    p = r.get('products') or []
    return bool(p) and all(x.get('count') == 0 for x in p if 'count' in x)

# ---------------------------------------------------------
# HAND KNOWLEDGE: overrides replace, cautions append.
# ---------------------------------------------------------
OVERRIDES = {
    'CHAR_CINDERS':      'Four cinders make one charcoal.',
    'CHAR_CHAR_BOULDER': 'One char makes four charcoal.',

    # Coal's ladder, the same three rungs as wood's. Green coke is
    # coal's char, worth four coke; breeze is coal's cinder, worth a
    # quarter. These say the arithmetic because Produces and Requires
    # cannot: a bar is a bar on the screen whatever it is worth.
    'CALCINE_GREEN_COKE':       'One green coke makes four coke.',
    'GRIND_COKE_BREEZE':        'One coke makes four coke breeze.',
    'PRESS_BREEZE_BRIQUETTES':  'Four coke breeze and a lump of pitch '
                                'press into one coal.',
}

# Appended AFTER the generated text, so the reaction keeps its yield
# and vessel sentences and gains one fact on the end.
CAUTIONS = {
    'RETORT_LIGNITE_FLUXED':
        'Flux takes the sulphur out as gypsum and brimstone.',
    'RETORT_BITUMINOUS_FLUXED':
        'Flux takes the sulphur out as gypsum and brimstone.',
}

def one_description(r):
    """Only what Produces and Requires cannot say. Empty is legal.
    One payout fragment, chosen by a specificity ladder, so no
    reaction ever explains its yield twice in different words.
    Container and protection facts appear only where a flag on the
    reagent makes them true."""
    key = r.get('key', '')
    if key in OVERRIDES: return OVERRIDES[key]
    name = r.get('name', '')
    frags = []
    rgs = r.get('reagents') or []
    flags_all = [g.get('flags') or {} for g in rgs]
    mats = [g.get('mat_id') or '' for g in rgs]

    # Wet and dried economics, the module's own arithmetic.
    if name.startswith('dry'):
        frags.append('The sun does the same for free in a fortnight.')
    elif any(state_word(m) == 'fresh' for m in mats):
        frags.append('Dried pays two to three times more.')

    # Payout shape: ONE fragment, most specific wins. Creature jobs
    # used to say this twice in different words; the ladder is why
    # they cannot any more.
    prods = r.get('products') or []
    kinds = [p.get('type', '') for p in prods]
    if any(g.get('type') in ('CORPSE', 'CORPSEPIECE', 'REMAINS')
           for g in rgs):
        frags.append('Yield follows the creature: size and build '
                     'decide the take, and remainders bank.')
    elif any('target_reagent' in p for p in prods):
        # Improvement reactions treat an item rather than consuming
        # it; a yield sentence would be a lie of emphasis here.
        frags.append('The item is preserved; it comes back treated.')
    elif key.startswith('SPLIT'):
        frags.append('Kindling retains the wood material it was split from; '
                     'yield follows size, and remainders bank.')
    elif is_adaptive(r):
        if any('LIQUID' in k for k in kinds):
            frags.append('Yield follows what goes in; liquid banks '
                         'until a container fills.')
        else:
            frags.append('Yield follows the size and material of '
                         'what goes in; remainders bank.')

    # Containers, spoken only where a flag makes it true. The
    # wildcard speaks for its whole category; a typed container
    # reagent speaks only for itself. A wildcard is furniture AND
    # type ANY together: a stray furniture flag on a typed reagent
    # (found live on a chest) must not steal the category prose.
    if any(f.get('furniture') and g.get('type') == 'ANY'
           for g, f in zip(rgs, flags_all)):
        frags.append('Any wooden furnishing qualifies, containers '
                     'only when empty'
                     + ('; bins are never taken.'
                        if any(f.get('not_bin') for f in flags_all)
                        else ', bins included.'))
    elif any(f.get('empty') and not f.get('preserve')
             for f in flags_all):
        frags.append('Only empty ones are taken; anything holding '
                     'cargo is left where it stands.')

    # Vessels, told apart by their flags: contains-vessels arrive
    # full and are drained, empty+preserve vessels are borrowed for
    # the output. Both come back.
    working = any('contains' in g for g in rgs)
    borrowed = any(f.get('preserve') and f.get('empty')
                   for f in flags_all)
    if working and borrowed:
        frags.append('All vessels are returned: spent ones empty, '
                     'borrowed ones filled.')
    elif working:
        frags.append('The vessel is returned; only its contents '
                     'are spent.')
    elif borrowed:
        frags.append('Borrowed vessels come back filled.')

    # Your dead are safe. CANUSEBURY is an opt-in this module never
    # takes, so anything flagged for burial is refused.
    if any(g.get('type') in ('CORPSE', 'CORPSEPIECE') for g in rgs):
        frags.append('Citizens and pets are never taken.')

    # Preserved reagents that are not vessels: the copper plate in
    # the dye vat, scraped and returned. Without this the player
    # reads an expensive bar in Requires and assumes it is spent.
    if not any('target_reagent' in pp for pp in prods):
        for g, f in zip(rgs, flags_all):
            if f.get('preserve') and not f.get('empty') \
                    and 'contains' not in g \
                    and g.get('has_tool_use') != 'LIQUID_CONTAINER':
                frags.append('Durable inputs are returned unspent.')
                break
 
    if key in CAUTIONS: frags.append(CAUTIONS[key])
    return ' '.join(frags).strip()

# ---------------------------------------------------------
# RUN: SURGICAL WRITER
# ---------------------------------------------------------
# The source JSON is HAND FORMATTED and that formatting is work.
# So this writer never re-serialises: it parses only to decide,
# and edits the raw text by inserting one description line after
# each reaction's key line, matching the file's own indentation.
# Every byte outside those insertions survives identically.
#
# PROVENANCE. descriptions_manifest.json remembers what THIS tool
# wrote per key. On rerun: matching text is ours to replace with a
# fresh generation; differing text was hand-edited and is kept,
# forever. Delete the manifest to adopt everything as hand-written.
# ---------------------------------------------------------
import hashlib

MAN  = 'descriptions_manifest.json'
manifest = json.load(open(MAN)) if os.path.exists(MAN) else {}
if not manifest:
    # Said out loud because it reads like a malfunction otherwise:
    # with no manifest there is no provenance, so every existing
    # description is adopted as hand-written THIS RUN and kept
    # forever after. That is the documented delete-to-adopt lever.
    # If adoption was not the intent, stop now and put the manifest
    # back before this run's rewrite of it makes the adoption stick.
    print('NO MANIFEST: adopting every existing description as'
          ' hand-written. Restore %s first if that was not the'
          ' intent.' % MAN)

# Totals across the whole set; the review file accumulates in file
# order so it reads in the same sequence as the menus.
n_new, n_upd, n_kept, n_skip, n_fail = 0, 0, 0, 0, 0
review = []

for SRC in SRCS:
    data = json.load(open(SRC))
    raw  = open(SRC, newline='').read()
    EOL  = '\r\n' if '\r\n' in raw else '\n'
    # Anchor searches live ONLY inside the reactions array; every
    # part file carries a categories block with "key" lines of its
    # own, so the base offset is found per file. Offsets below are
    # absolute, built from region-relative matches plus this base.
    r_base = raw.index('"reactions"')

    f_new, f_upd, f_kept, f_skip, f_fail = 0, 0, 0, 0, 0
    for r in data.get('reactions', []):
        key = r.get('key', '')
        if r.get('building') == 'NONE':
            f_skip += 1; continue
        gen = one_description(r)
        cur = r.get('description')
        anchor = re.search(
            r'^([ \t]*)"key": %s,[^\n]*\n' % re.escape(json.dumps(key)),
            raw[r_base:], re.M)
        if not anchor:
            # Counted in the console summary, not only the review
            # file: a reaction the writer cannot find is exactly the
            # kind of thing that reads as "did nothing" otherwise.
            review.append(key + '\tANCHOR NOT FOUND, untouched')
            f_fail += 1
            continue
        indent = anchor.group(1)
        a_end = r_base + anchor.end()
        if cur is None:
            if gen:
                raw = (raw[:a_end]
                       + indent + '"description": ' + json.dumps(gen) + ',' + EOL
                       + raw[a_end:])
                manifest[key] = gen
                f_new += 1
            review.append(key + '\t' + gen)
        elif manifest.get(key) == cur:
            if gen != cur:
                # Replace the description line AT THIS KEY'S ANCHOR,
                # by offset, never by text search: hundreds of
                # reactions share identical generated blurbs, and a
                # text replace stabs the first twin it finds in the
                # file. Found live the first time two twins shared a
                # part file; fixed by never searching at all.
                m2 = re.match(
                    r'%s"description": [^\n]*\n' % re.escape(indent),
                    raw[a_end:])
                if not m2:
                    review.append(key + '\tDESCRIPTION NOT AT ANCHOR, untouched')
                    continue
                raw = (raw[:a_end]
                       + indent + '"description": ' + json.dumps(gen) + ',' + EOL
                       + raw[a_end + m2.end():])
                manifest[key] = gen
                f_upd += 1
            review.append(key + '\t' + gen)
        else:
            f_kept += 1
            review.append(key + '\t' + str(cur) + '\t[hand]')

    out = os.path.basename(os.path.splitext(SRC)[0]) + '_described.json'
    open(out, 'w', newline='').write(raw)
    print('%s: inserted %d, updated %d, kept %d hand-written, skipped %d hidden,'
          ' %d ANCHOR FAILURES -> %s'
          % (SRC, f_new, f_upd, f_kept, f_skip, f_fail, out))
    n_new += f_new; n_upd += f_upd; n_kept += f_kept; n_skip += f_skip
    n_fail += f_fail

json.dump(manifest, open(MAN, 'w'), indent=1, sort_keys=True)
open('descriptions_review.txt', 'w').write('\n'.join(review))
print('total: inserted %d, updated %d, kept %d hand-written, skipped %d hidden,'
      ' %d anchor failure(s) across %d file(s)'
      % (n_new, n_upd, n_kept, n_skip, n_fail, len(SRCS)))