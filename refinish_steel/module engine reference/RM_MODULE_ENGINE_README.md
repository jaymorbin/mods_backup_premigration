# RM Module Guide

How to add materials and reactions to Dwarf Fortress using Refinish Metal's
module system.

---

## Contents

1. [What this system is](#1-what-this-system-is)
2. [Anatomy of a module](#2-anatomy-of-a-module)
3. [Your first module](#3-your-first-module)
4. [The materials file](#4-the-materials-file)
5. [The reactions file](#5-the-reactions-file)
6. [Reagents and products in depth](#6-reagents-and-products-in-depth)
7. [The advanced Lua shell](#7-the-advanced-lua-shell)
8. [Working with other modules](#8-working-with-other-modules)
9. [Troubleshooting](#9-troubleshooting)
10. [Rules and conventions](#10-rules-and-conventions)

---

## 1. What this system is

### The problem

Dwarf Fortress reads raw files once, when a world is generated. Materials and
reactions added afterwards do not exist in that world. Adding content to an
existing save means regenerating the world, and removing a mod from a save
corrupts it.

### What RM does instead

Refinish Metal writes content directly into the game's memory at load time,
after the world is already open, and sweeps it back out before the game saves.
No material, reaction, or category your module injects is written into the save.

That gives you two things raws cannot:

- **Content works on existing saves.** No regeneration.
- **Nothing has to be decided at worldgen.** Your module can read the loaded
  world and adapt to it.

### What this does not mean

**A module cannot be fully uninstalled from a save.** This is worth being
precise about, because the distinction is easy to overstate.

Your module is still a DF mod. Once it is active for a world, DF records it in
that save's mod list and keeps its `info.txt`, exactly as it does for RM itself.
Delete the mod from disk and the save loses a mod it expects to find.

What RM's approach actually buys is that **the injected content is not part of
the save**. That is what makes existing saves usable and what stops a
half-removed mod from corrupting one. It is not the same as leaving no trace.

The realistic lifecycle is **dormancy, not removal**. A module that stops
responding to RM's token call injects nothing, and the save continues to work
without its materials. The mod entry stays. Design for that: assume a player
may turn your content off, and make sure nothing you leave behind depends on it
coming back.

### What you write

A module is three files: two JSON data files and one small Lua file that points
RM at them. You do not write engine code. You describe materials and reactions
in a schema, and RM builds them.

### What this system is not for

RM adds content. It does not currently edit or remove content that already
exists. If you need to change a vanilla material or delete a vanilla reaction,
that still belongs in raw files.

---

## 2. Anatomy of a module

```
my_module/
  info.txt                          Standard DF mod metadata
  scripts_modinstalled/
    my_module.lua                   Registers with RM, points at the JSON
  data/
    my_module_materials.json        Material definitions
    my_module_reactions.json        Reaction and category definitions
```

### How the pieces connect at runtime

1. DF loads a world. DFHack runs every script in `scripts_modinstalled/`.
2. Your Lua file registers a **listener** with RM's module engine and returns
   immediately. Nothing else happens yet.
3. RM starts up and broadcasts a **token call** to every registered listener.
4. Your listener responds with your data, either as file paths or as already
   parsed tables.
5. RM validates the data, rejecting the whole module if anything is malformed.
6. RM injects materials, then categories, then reactions, then grants
   civilization permissions.
7. On shutdown or save, RM sweeps everything back out.

Registration is deliberately cheap. Your listener is a callback that is stored
and called later, once the world raws exist. That ordering is why you cannot
read `df.global.world` at the top of your Lua file.

### The prefix

Every module owns a **prefix**, a string ending in an underscore. RM stamps it
onto everything you inject.

| You write | RM creates |
|---|---|
| material key `GOLDBRONZE` | inorganic `MYMOD_GOLDBRONZE` |
| reaction key `MAKE_GOLDBRONZE` | reaction `MYMOD_RXN_MAKE_GOLDBRONZE` |
| category key `ALLOYS` | category `MYMOD_CAT_ALLOYS` |

The prefix is how RM tells your content apart from everyone else's, including
during cleanup. Two rules follow from that:

- **No two modules may have overlapping prefixes.** Not just identical ones.
  `THISMOD_` overlaps `THISMOD_TOO_`, because a sweep for the first also selects
  the second, and one module's shutdown would delete the other's materials.
  RM rejects the overlap at registration.
- **`REFINISH_STEEL_` is reserved** for RM's own core content.

Pick something specific. `MYMOD_` is fine. `METAL_` is asking for trouble.

---

## 3. Your first module

### Step 1: info.txt

Standard DF mod metadata. The `[ID:...]` value is the one that matters here,
because your Lua file uses it to find your own folder on disk.

```
[ID:my_module]
[NAME:My Module]
[DESCRIPTION:Adds a new alloy.]
[NUMERIC_VERSION:1]
[DISPLAYED_VERSION:1.0]
[EARLIEST_COMPATIBLE_NUMERIC_VERSION:1]
[EARLIEST_COMPATIBLE_DISPLAYED_VERSION:1.0]
[REQUIRES_ID:refinish_steel]
[STEAM_TITLE:My Module]
[STEAM_DESCRIPTION:Adds a new alloy.]
```

`[REQUIRES_ID:refinish_steel]` declares the dependency on Refinish Metal
itself. Every module needs this line. Your Lua file does nothing but register
a listener, so without RM there to call it, the mod loads and then sits inert
with no way for the player to tell why. Declaring the dependency puts that in
front of them instead.

### Step 2: the JSON files

Copy `rm-module-materials-template.json` and
`rm-module-reactions-template.json` into `data/`. Rename them. Change the
`module` block in **both** files to your own prefix, name, and version.

The two `module` blocks must be identical. RM cross-checks them and rejects
the module if they disagree.

### Step 3: the Lua file

Copy `rm-module-template.lua` into `scripts_modinstalled/`, rename it, and set
four values at the top:

```lua
local MODULE_ID      = "my_module"                   -- from info.txt
local MODULE_NAME    = "My Module"                   -- for log output
local MATERIALS_FILE = "my_module_materials.json"
local REACTIONS_FILE = "my_module_reactions.json"
```

That is the whole file. Everything below the configuration block is
boilerplate you should not need to touch.

Use `rm-module-template-advanced.lua` instead if you need to inspect or edit
your data before RM sees it. Section 7 covers when that applies.

### Step 4: preflight

`preflight.py` checks your JSON offline, without launching DF. It mirrors every
rejection branch in the engine's validator, so anything it calls an error is
something RM will reject.

Put three files in one folder and run it:

```
preflight.py
refinish-module-types.lua        copied from your RM install
my_module_materials.json
my_module_reactions.json
```

```
python3 preflight.py
```

It finds `*_materials.json` and `*_reactions.json` on its own. Pass paths
explicitly if you keep them elsewhere:

```
python3 preflight.py path/to/mats.json path/to/rxns.json --types path/to/types.lua
```

**Errors fail the run. Warnings do not.** An error is something the validator
rejects and it takes your whole module down. A warning is either something the
script cannot verify offline, or something legal that is a known way to shoot
yourself: a colour with no fallback, a reaction with no skill, an
`in_container` reagent with nothing declaring it contains it, a `to_container`
bag that is not preserved.

Warnings are grouped by kind with a count, because a large module can produce
hundreds of the same one. `--verbose` prints them all. `--strict` makes them
fail the run, which is useful in a build script.

Beyond the validator, it also cross-checks references the engine resolves
silently: a `mat_id` carrying your prefix that no material declares, a category
written as the bare key where the full ID is required. Those resolve to nothing
in game and produce a reaction that quietly matches no input, which is the
worst failure mode to debug from inside DF.

**One thing to know about nulls.** If you use the runtime resolution pattern
(section 7.4), write `"mat_id": null` explicitly rather than omitting the key.
Preflight treats an explicit null as a deliberate sentinel and warns; it treats
a missing key as a mistake and errors. That distinction is the only signal it
has.

Re-copy `refinish-module-types.lua` from your RM install whenever RM updates.
Preflight parses its type tables rather than carrying its own copies, which is
what stops it drifting from the engine, but only if the file is current.

### Step 5: test it

Enable the mod, load a save, and open the DFHack console. You are looking for a
line naming your module in RM's startup output. If validation failed, the
rejection message names the exact field.

Two things to know before you start iterating:

- **Restart fully between tests.** Quit DF, clear the cache, relaunch. A
  partially reloaded script environment produces failures that have nothing to
  do with your change.
- **`refinish-find` and `refinish-path`** are RM's diagnostic commands. Use
  them to confirm what actually landed in memory rather than assuming.

---

## 4. The materials file

A material is one inorganic: a metal, a stone, a gem, a ceramic, a glass.

```json
{
    "module": { "prefix": "MYMOD_", "name": "My Module", "version": "1.0" },
    "materials": [
        { "key": "GOLDBRONZE", "name": "gold bronze", "material_class": "METAL" }
    ]
}
```

Three fields are required: `key`, `name`, `material_class`. Everything else is
optional. The template file shows every optional field with its default.

### 4.1 Material classes

`material_class` does two things: it picks which flags your material gets, and
it tells RM what kind of existing material to clone for structure.

| Class | Produces | Capabilities |
|---|---|---|
| `METAL` | Bars | Weapons, armour, ammo, diggers, anvils, furniture |
| `STONE` | Boulders | Construction, furniture, quern stones |
| `CERAMIC` | Boulders | Construction, furniture, tools. No weapons or armour |
| `GEM` | Rough gems | Cutting, encrusting. Requires `gem_names` |
| `GLASS` | Rough glass | Construction, furniture, trap components, crafts. No weapons or armour |
| `DYE` | Powder (`POWDER_MISC`) | A dye every dye job takes. Declare it on a plant host, not as an inorganic (see 6.9) |
| `RAW` | Nothing by default | No preset at all. You set every flag yourself |

**On `GLASS`:** vanilla's green, clear and crystal glass are builtin material
types, not inorganics, so no vanilla world holds an `IS_GLASS` inorganic for RM
to clone. RM falls back to a ceramic donor, and the `GLASS` preset then clears
`IS_CERAMIC` and sets `IS_GLASS`. None of that is visible in play. The material
is glass.

Note that since glass is builtin, not inorganic, simply injecting a new glass material 
will not automatically populate the glass furnace with reactions, unlike inorganics such 
as smelted metals. Glass furnace reactions must be built individually the way vanilla 
builds glass: one reaction per material per item, at the glass furnace, taking sand 
straight through to the finished object. Vanilla has no green glass bar that gets worked 
afterwards, and your material does not need one either. ArgMOD's glass is written exactly 
this way and behaves like any other glass in the game. The cost is volume, not difficulty: 
a full item range runs to roughly three dozen reactions per material.

**On `DYE`:** the preset sets `IS_DYE` and the two plant powder flags every
vanilla dye carries, and RM writes the dye colour (`powder_dye`) from the
material's colour, or from `dye_color` when you set it. Declare dyes on a plant
host in your plants file. DF files a powder by the type of its material: an
inorganic dye is either stranded where it was made (with the plant flags) or
stored as an empty bag under Furniture and listed nowhere (without them).
Preflight warns when a dye is declared as an inorganic. The whole story is in
`RM_Dye_Integration.md`.

**On `RAW`:** no flags are cleared and none are set, so whatever RM cloned
carries through untouched and `material_flags` is your only control. It exists
for cases where the presets get in the way. If you are not sure you need it,
you do not.

### 4.2 Why "null" is not "zero"

Every optional field accepts `null`, and `null` means **do not write this
field**. The value from RM's clone donor stays in place.

That donor is chosen at runtime by scanning the loaded world, so it can differ
between worlds and between mod sets. A null density does not give you zero
density. It gives you an unpredictable one.

Write real numbers. The only field where null is routinely correct is `value`,
and only when you are computing it in Lua (section 7.3).

### 4.3 The two colour systems

DF stores material colour in two unrelated number spaces, and crossing them is
the most common cosmetic bug in module content.

| Field | What it controls | Values |
|---|---|---|
| `color` | The colour **word**, as in "a gold bronze-colored bar" | A descriptor name |
| `display_color` | The **on-screen** colour of items | ANSI triple, each 0 to 7 |
| `build_color` | The on-screen colour of built constructions | ANSI triple, each 0 to 7 |

```json
"color": "METALLIC_BRONZE",
"fallback_colors": ["BRONZE", "DARK_GOLD", "ORANGE"],
"display_color": [6, 0, 1],
"build_color": [6, 0, 1]
```

`color` resolves by name against the descriptors loaded in that world. **A name
that is not loaded fails silently and the material comes out grey**, with no
error printed anywhere. `fallback_colors` is tried in order when that happens,
and it is the only protection you get. Always supply at least one.

Descriptor names come from `descriptor_color_standard.txt`. If you use a name
your own raws half defines, verify it at load time. The advanced template has a
`color_exists` helper for this.

### 4.4 Temperatures

DF temperatures are in urists, not degrees. The scale is Fahrenheit offset by
9968, so 9968 U is 0 degrees F.

| Reference point | Urists |
|---|---|
| Water freezes and ice melts | 10000 |
| Comfortable room temperature | 10036 |
| Water boils | 10180 |
| Magma | 12000 |

The first row is the one to anchor on: 10000 is **freezing**, not room
temperature. Vanilla `WATER` carries `MELTING_POINT:10000` and
`BOILING_POINT:10180`, which is where those two numbers come from.

Magma sits at 12000, so a material needs a melting point **above** 12000 to
survive contact with it. Vanilla iron melts at 12718 and boils at 14877; those
are useful reference points for positioning a metal.

### 4.5 Reaction classes and reaction products

These two fields are what let materials participate in chains without anyone
hardcoding anything.

**`reaction_classes`** is a list of tags. A reagent can then say "accept
anything carrying tag X" instead of naming materials. This is the only
supported way for modules to interact. Section 8 covers it properly.

```json
"reaction_classes": ["THERMALLY_PROCESSED", "CALCIUM_SILICATE"]
```

An empty array is meaningful and worth writing: it explicitly clears anything
inherited from the clone donor.

**`reaction_products`** are named derivations. They answer the question "when a
reaction asks this material for product X, what does it hand back?"

```json
"reaction_products": [
    { "id": "FIRED_MAT", "mat_id": "MYMOD_STONEWARE" }
]
```

This is how vanilla fires clay. The reaction does not name any clay. It says
"any boulder that declares a FIRED_MAT product", and the output says "whatever
that material's FIRED_MAT is." One reaction then handles every clay in the
world, including clays from mods that have never heard of it.

`mat_id` must be the **full prefixed ID**. Cross-module references are resolved
in a final pass after every module has injected, so they work in either
direction, including between two modules that reference each other.

---

## 5. The reactions file

A reaction is one job: what it consumes, what it makes, where it appears, who
can do it.

```json
{
    "module": { "prefix": "MYMOD_", "name": "My Module", "version": "1.0" },
    "categories": [ ... ],
    "reactions": [ ... ]
}
```

### 5.1 Reaction fields

| Field | Required | Notes |
|---|---|---|
| `key` | Yes | Unique in this file. Gets the prefix. |
| `name` | Yes | What the player reads. Lowercase, verb first. |
| `building` | Yes | Where the job appears. |
| `skill` | No, but set it | What the worker trains. |
| `fuel` | No | Default false. Burns one fuel; magma buildings exempt. |
| `category` | No | The **full prefixed** category ID. |
| `permissions` | No | Default AUTO. Which civilizations get it. |
| `reaction_flags` | No | Currently just `fortress_mode`. |
| `fallback_template` | No | Override RM's structural donor choice. |
| `reagents` | Yes | At least one. |
| `products` | Yes | At least one. |

**Always set `skill`.** RM builds a reaction by cloning an existing one for its
C++ structure, then zeroing every semantic field and rebuilding from your
definition. If you omit `skill`, the donor's skill survives, and which donor
got picked is not something you control.

`fallback_template` exists to override that donor choice by naming a vanilla
reaction code. You almost certainly do not need it. The neutral reset means a
suboptimal donor is a cosmetic issue, not a functional one.

### 5.2 Buildings

All thirteen entries in `BUILDING_TYPES`:

| Name | Building | Notes |
|---|---|---|
| `SMELTER` | Smelter | Normal and magma |
| `KILN` | Kiln | Normal and magma |
| `GLASS_FURNACE` | Glass furnace | Normal and magma |
| `FORGE` | Metalsmith's forge | Normal and magma |
| `MASON` | Mason's workshop | |
| `CRAFTSMAN` | Craftsdwarf's workshop | |
| `JEWELER` | Jeweler's workshop | |
| `MILL` | Quern | And millstone |
| `ASHERY` | Ashery | |
| `SOAP_MAKER` | Soap maker | Vanilla, but built as a custom workshop |
| `CHEMIST` | ArgMOD's Chemist | Needs ArgMOD's raws installed |
| `COMPOUNDER` | ArgMOD's Compounder | Needs ArgMOD's raws installed |
| `NONE` | No building | Adventure mode |

Magma variants are automatic. You do not write two reactions.

The last three are custom workshops: raw objects rather than enum entries. RM
finds them by code at build time, because their indices shift with mod load
order. A reaction assigned to a workshop that is not installed has nowhere to
appear and vanishes without comment, so check for it (section 7.2).

To use a custom workshop of your own, add an entry to `BUILDING_TYPES` in
`refinish-module-types.lua` with a `custom_code` naming the workshop. RM
resolves the code to a runtime index at build time, because custom workshop
indices shift with mod load order and cannot be constants.

### 5.3 Skills

All twenty-six entries in `SKILL_MAP`:

| Group | Skills |
|---|---|
| Furnace | `SMELT`, `POTTERY`, `GLASSMAKER`, `GLAZING` |
| Stone | `MASONRY`, `STONECRAFT`, `KNAPPING`, `CUT_STONE`, `CARVE_STONE` |
| Metal | `FORGE_WEAPON`, `FORGE_ARMOR`, `FORGE_FURNITURE`, `METALCRAFT` |
| Gems | `GEM_CUTTING`, `GEM_SETTING` |
| Organic | `WOODCRAFT`, `BONECARVE`, `LEATHERWORK`, `CARPENTRY` |
| Textiles | `WEAVING`, `CLOTHESMAKING`, `STRAND_EXTRACT` |
| Chemical | `SOAP_MAKING`, `LYE_MAKING`, `POTASH_MAKING`, `MILLING` |

Match the skill to the building. A `SMELT` reaction at a mason's workshop will
inject and run, but the wrong dwarves will be assigned to it.

### 5.4 Categories

Categories are the collapsible headings in a workshop's job list. Optional.

```json
"categories": [
    { "key": "ALLOYS", "name": "Alloys", "parent": "" },
    { "key": "BRONZES", "name": "Bronzes", "parent": "ALLOYS" }
]
```

`parent` is required. An empty string means top level. A child names its
parent's **bare key**, unprefixed.

There is one asymmetry worth memorising: a reaction's `category` field takes
the **full prefixed ID**, not the bare key.

```json
"category": "MYMOD_CAT_BRONZES"
```

Naming a category your module does not declare leaves the string alone, which
is how you nest under a category that already exists.

### 5.5 Permissions

Permissions decide which **civilizations** know the reaction. This affects what
caravans bring, what invaders carry, and what other sites produce. It is not
about your fortress.

**`AUTO`** (the default) evaluates every civilization and grants the reaction to
any that can already work the reagent materials and operate the building. A civ
that cannot smelt does not receive smelting reactions. This is right for
ordinary content.

```json
"permissions": { "mode": "AUTO" }
```

**`ENTITY_CODE`** grants only to the entity codes you name. The same knowledge
gate still applies on top, so naming a civ that cannot use the building does
not force it through. Codes are whatever is loaded, vanilla or modded.

```json
"permissions": { "mode": "ENTITY_CODE", "entities": ["MOUNTAIN", "PLAINS"] }
```

**`NONE`** grants to nobody.

```json
"permissions": { "mode": "NONE" },
"reaction_flags": { "fortress_mode": true }
```

`fortress_mode` is easy to read backwards. It is a **bypass, not a
restriction**. True means the player's own civilization type can run the reaction
*without* an explicit permit. Combined with `NONE`, the result is a recipe the
player has and no other off-type civilization does, so it never shows up in 
off-type caravan stock or on a goblin's back.

Default is false, meaning the player needs a permit like everyone else.

---

## 6. Reagents and products in depth

### 6.1 Codes are local, material IDs are global

A reagent's `code` is a private label inside one reaction. It is how products
and container links point back at a slot. It never leaves the reaction and
never takes a prefix. Lowercase by convention. Two reagents in one reaction may
not share a code.

Anywhere you write `mat_id` or `metal_id`, you are naming a real loaded
inorganic. Vanilla materials use their bare ID (`IRON`, `GYPSUM`,
`QUICKLIME`). Module materials use the full prefixed ID (`MYMOD_GOLDBRONZE`).

### 6.2 Choosing a reagent type

All thirty-one entries in `REAGENT_TYPES`, grouped by what they match.

**Bars**

| Type | Matches | Also needs |
|---|---|---|
| `BAR` | One specific metal | `mat_id` |
| `BAR` | Any bar at all | |
| `COAL` | Charcoal or coke | |
| `BAR_POTASH` | A potash bar | |
| `BAR_ASH` | An ash bar | |
| `BAR_PEARLASH` | A pearlash bar | |

**Stones and ores**

| Type | Matches | Also needs |
|---|---|---|
| `BOULDER` | One specific stone | `mat_id` |
| `BOULDER_ANY` | Any inorganic, with material picker | usually `flags.non_economic` |
| `BOULDER_UNTYPED` | Any boulder, filtered by tag | `reaction_class` |
| `FLUX` | Any flux-bearing stone | |
| `ORE_OF` | Any ore that smelts to a metal | `metal_id` |
| `ROCK` | A rock item | |

**Powders, liquids, and their containers**

| Type | Matches | Also needs |
|---|---|---|
| `POWDER` | A powder | `mat_id` optional |
| `POWDER_ANY` | Any inorganic powder | no material picker; see 6.7 |
| `WATER` | Water | a container reagent |
| `LIQUID` | A non-water builtin liquid | |
| `LIQUID_INORGANIC` | A specific inorganic liquid | `mat_id` |
| `LIQUID_INORGANIC_ANY` | Any inorganic liquid, by tag | `reaction_class` |
| `BAG` | A bag | |
| `BUCKET` | A bucket | |
| `BARREL` | A barrel | |
| `JUG` | A jug | |
| `LARGE_POT` | A large pot | |
| `CONTAINER` | Anything at all. Do not use | |

**Worked items**

| Type | Matches | Also needs |
|---|---|---|
| `BLOCKS` | Blocks of one material | `mat_id` |
| `BLOCKS` | Blocks of anything | |
| `ROUGH` | A specific rough gem | `mat_id` |
| `ROUGH_ANY` | Any rough gem, by tag | `reaction_class` |
| `STATUE` | A statue | |
| `ANY_CRAFT` | Any craft item | a `reaction_class`, always |
| `BODY_PART` | Bone, shell, horn | the creature flags, always |

Three traps worth naming:

- **Never use `CONTAINER`.** It is item type -1 and DF will happily grab a
  metal bar or a weapon as a "container." Use `BUCKET` or `BARREL`.
- **`ORE_OF` takes the metal, not the ore.** `"metal_id": "COPPER"` matches
  malachite, tetrahedrite, and any modded copper ore without naming any of them.
- **`ANY_CRAFT` and `BODY_PART` are item type -1.** They match everything until
  something narrows them. `ANY_CRAFT` needs a `reaction_class`; `BODY_PART`
  needs `flags.body_part` plus at least one of `bone`, `shell`, `horn`.
  Dropping the narrowing turns the slot into a wildcard over every item in the
  fortress.

### 6.3 The container pattern

Powders and liquids always travel in something, so they are always two
reagents. Which flags go where depends on direction.

**Output into a container.** The bag is preserved and must be empty; the
product names it.

```json
"reagents": [
    { "code": "limestone", "type": "FLUX", "quantity": 2 },
    { "code": "bag", "type": "BAG", "quantity": 1,
      "flags": { "preserve": true, "empty": true } }
],
"products": [
    { "type": "POWDER_MISC", "mat_id": "MYMOD_LIME", "count": 4,
      "dimension": 150, "to_container": "bag" }
]
```

**Input from a container.** The powder is `in_container`; the bag is preserved
and `contains` the powder.

```json
"reagents": [
    { "code": "lime", "type": "POWDER", "mat_id": "MYMOD_LIME",
      "quantity": 150, "flags": { "in_container": true } },
    { "code": "bag", "type": "BAG", "quantity": 1,
      "flags": { "preserve": true }, "contains": "lime" }
]
```

Read the pairing as: the bag **contains** the powder, the powder is **in** a
container. Put `contains` on the container, pointing at the contents.

**A hard limit:** one slot must be satisfied by the contents of **one bag
alone**. DF will not aggregate several bags to fill a single slot. If you need
four bags' worth, that is four reagent slots.

`quantity` for powders and liquids counts in dimension units, where 150 is one
full bag or bucket.

### 6.4 The three ways a product picks its material

Exactly one. Not zero, not two.

**`mat_id`** names the output directly.

```json
{ "type": "BAR", "mat_id": "MYMOD_GOLDBRONZE", "count": 4 }
```

**`get_material_same`** copies the material of a reagent item straight through.
The knapping pattern: the sharp rock is made of whatever rock was knapped.

```json
{ "type": "ROCK", "get_material_same": "stone", "count": 2, "force_edge": true }
```

**`get_material_product`** asks a reagent's material what it derives into, using
a product code that material declared (section 4.5). This is the strongest of
the three, and the one most worth learning.

```json
"reagents": [
    { "code": "clay", "type": "BOULDER_ANY", "quantity": 1,
      "has_material_reaction_product": "FIRED_MAT" }
],
"products": [
    { "type": "BOULDER",
      "get_material_product": { "reagent_code": "clay", "product_code": "FIRED_MAT" },
      "count": 1, "dimension": 600 }
]
```

Nothing here names a clay. The reagent accepts anything that knows how to be
fired, and the product asks that same material what it fires into. One
reaction, every clay in the world, including ones added after you shipped.

### 6.5 Product options

| Field | Default | Notes |
|---|---|---|
| `count` | 1 | How many items |
| `dimension` | 150 | 150 for a bar or a bag of powder; 600 for a boulder |
| `probability` | 100 | Percent chance. Use it for byproducts |
| `to_container` | none | Names a reagent code |
| `subtype` | none | An itemdef code such as `ITEM_TOOL_JUG` |
| `force_edge` | false | Marks the output as edged |

Product types: `BAR`, `BAR_COAL`, `BAR_POTASH`, `BAR_ASH`, `BAR_PEARLASH`,
`BLOCKS`, `BOULDER`, `ROUGH`, `POWDER_MISC`, `LIQUID_MISC`,
`LIQUID_MISC_INORGANIC`, `ROCK`, `CRAFTS`, `IMPROVEMENT`, or any plain
`df.item_type` name such as `TABLE`, `ANVIL`, or `WINDOW`.

Two of those break the "exactly one material source" rule above:

- **`BAR_ASH` and `BAR_PEARLASH`** carry their material in the type itself, so
  they name none at all. `BAR_COAL` and `BAR_POTASH` behave the same way in
  practice, but still accept a `mat_id` for backward compatibility.
- **`IMPROVEMENT`** is not an item product. See below.

### 6.6 Improvement products

An improvement decorates an existing item rather than creating one. Glazing is
the vanilla case. It is a different C++ class with a different field set, so it
follows different rules:

```json
{
    "type": "IMPROVEMENT",
    "improvement_type": "GLAZED",
    "target_reagent": "pot",
    "get_material_product": { "reagent_code": "glaze", "product_code": "GLAZE_MAT" },
    "probability": 100
}
```

| Field | Required | Notes |
|---|---|---|
| `improvement_type` | Yes | A `df.improvement_type` name |
| `target_reagent` | Yes | The reagent code being decorated |
| `get_material_product` | Yes | Not optional here, unlike item products |
| `improvement_specific_type` | No | Default 0 |
| `probability` | No | Default 100 |

`mat_id` and `get_material_same` are **rejected** on an improvement product.
RM clones a live improvement for its structure and keeps that donor's material
mode flags, which are set for material-from-reagent. Any other mode would be
injecting against flags nobody set, so validation refuses it rather than
guessing.

The reagent being decorated normally wants `flags.unimproved` so a glazed pot
cannot be glazed a second time.

### 6.7 The magnifying glass

The magnifying glass icon lets the player choose which specific material a job
uses. It appears for `BAR`, `BLOCKS`, `BOULDER`, `ROUGH`, and `SMALLGEM`
reagents when the material is left as any inorganic. `BOULDER_ANY` is built for
exactly this.

It does **not** appear for `POWDER_MISC`, in any configuration. That is a hard
DF engine limit, not something runtime injection can work around. If your
design needs the player to pick a powder, it needs a different design.

### 6.8 One more trap: economic stone

`BOULDER_ANY` with `flags.non_economic` grabs every non-economic inorganic in
the world, and that includes processed materials your own module produced.
A grinding reaction meant for raw stone will happily eat your finished output.

The fix is to give processed materials a `reaction_class`. Carrying one makes a
material economic, which takes it out of the `non_economic` net.

### 6.9 Naming a plant material: `mat_token`

`mat_id` names an inorganic only. `mat_token` names any material by its full
token, the way the raws do, and it works on reagents as well as products:

```json
{ "code": "log", "type": "WOOD", "quantity": 1,
  "mat_token": "PLANT_MAT:ACACIA:WOOD" }
```

```json
{ "type": "POWDER_MISC", "mat_token": "PLANT_MAT:MYMOD_DYE_HOST:MY_DYE",
  "to_container": "bag", "count": 1, "dimension": 150 }
```

A material on your own host plant is `PLANT_MAT:<prefix + plant key>:<material
key>`. Preflight checks those against your plants file; tokens for vanilla or
another mod's plants resolve when the reaction is built.

A reagent token that does not resolve closes the slot: the reaction shows and
cannot run, and the log names the token. It never falls back to "any
material", which would let a slot meant for one tree's logs take every log in
the fort. Give a token or a `mat_id`, not both; if both are there, the token
wins and the log says so.

---

## 7. The advanced Lua shell

The basic template hands RM two file paths. That is correct whenever your JSON
is complete on disk and nothing in it depends on the world that just loaded.

The advanced template loads the JSON itself, edits the parsed tables in memory,
and hands RM finished data. Use it when you need to ask a question your JSON
cannot answer:

- Which sand does this world have?
- Is my raws half actually installed?
- What should this alloy be worth, given local metal prices?

Every system in that template is independent. Delete what you do not need.

### 7.1 The listener contract

RM calls your listener once, after world raws are loaded, before injection.
Return either paths:

```lua
return { materials_json = path1, reactions_json = path2 }
```

Or finished tables:

```lua
return {
    materials  = mat_data.materials,
    reactions  = rxn_data.reactions,
    categories = rxn_data.categories,
    module     = mat_data.module,
}
```

Return `nil` to skip the module. Do that on any failure that would otherwise
inject partial content.

### 7.2 Raw dependency checks

Injection is forgiving in the worst possible way. A missing material resolves
to index -1 and the reaction silently accepts nothing. A missing colour resolves
to grey. The player gets a half-working mod and no way to find out why.

The template has three checks: `inorganic_exists`, `color_exists`,
`workshop_exists`. Fill in the lists, and a missing dependency becomes one
clear console message instead of a mystery.

Two notes on how to use them:

- **Pick sentinels, not exhaustive lists.** One material that only your raws
  half defines proves the whole file loaded. Checking all twenty-six just makes
  a longer message.
- **Report, do not gate.** A missing dependency degrades the module; it does
  not disable it. Say what is wrong and load anyway.

### 7.3 Computing values

A hardcoded alloy value is a guess about a world you have not seen. Metal
prices shift with the mods installed, and an alloy priced against vanilla iron
can end up worth less than its own ingredients.

```json
"value": null,
"value_from_reaction": "MAKE_GOLDBRONZE"
```

`value_from_reaction` is not part of RM's schema. RM ignores unknown fields, so
it passes through untouched and your Lua file reads it. The template's
`calculate_weighted_value` averages the live material values of the reaction's
`BAR` reagents, weighted by quantity.

### 7.4 Resolving materials at runtime

Sand is the standard case. Vanilla ships five sand materials and mods add or
remove more, so your JSON cannot name one. But it cannot leave the slot as a
wildcard either: a `POWDER` reagent with no material matches *any* powder in a
bag, and once two such slots sit in one reaction, DF has nothing to tell them
apart and reagent matching goes non-deterministic.

The pattern:

1. Write `"mat_id": null` as a sentinel meaning "resolve at load time."
2. Scan the live raws for something matching a property, such as the
   `SOIL_SAND` flag.
3. Write the real ID into the parsed table before returning it.
4. If nothing matches, **remove the affected content** so the module degrades
   cleanly instead of injecting jobs that can never start.

The engine never sees the null.

Nothing in `resolve_target_id` is sand-specific except the flag it tests. Swap
that test and reuse the shape.

### 7.5 Helper scripts and shutdown

Some things the schema cannot express: injecting a button into a workshop's
order list, hooking job completion, fixing up created items. Those go in
companion scripts exposing `start()` and `stop()`, listed in `HELPER_SCRIPTS`.

**Do not remove the shutdown hook.** A polling callback that survives a map
unload is reading world data that has been freed, and the crash it causes will
appear to come from somewhere else entirely.

```lua
dfhack.onStateChange.my_module_unload = function(code)
    if code == SC_MAP_UNLOADED then
        stop_helpers()
    end
end
```

The table key must be unique across all of DFHack. Use your module ID.

---

## 8. Working with other modules

### The rule

**Avoid direct reference to another module's material by `mat_id`.**

If that module is not installed, your reagent resolves to nothing and the
reaction silently accepts no input. The player sees a job that never starts.

### The mechanism

Modules interact best through shared `reaction_class` tags.

A material opts in by carrying a tag:

```json
{
    "key": "SLAG",
    "reaction_classes": ["THERMALLY_PROCESSED", "BYPRODUCT"]
}
```

A reaction anywhere asks for the tag, not the material:

```json
{
    "code": "slag",
    "type": "BOULDER_UNTYPED",
    "quantity": 3,
    "reaction_class": "THERMALLY_PROCESSED"
}
```

Neither side knows the other exists. If the producing module is not installed,
the reaction simply finds no input; it does not break. If three modules produce
tagged materials, all three feed the same reaction.

Name tags after the **process**, not after your material. `THERMALLY_PROCESSED`
invites participation. `MYMOD_SLAG` does not.

### `depends_on`

When you genuinely must name another module's material, declare it:

```json
"module": {
    "prefix": "MYNEWMOD_",
    "name": "My New Module",
    "version": "1.0",
    "depends_on": ["MYOLDMOD_"]
}
```

RM injects the named modules first. This is for `reaction_products` links and
similar hard references, not a substitute for reaction classes.

Cross-module `reaction_products` are resolved in a final pass after every module
has injected, so they work in either direction, including mutual references.

---

## 9. Troubleshooting

### Module never appears in the log

The listener never registered or never returned. Check in order:

- Is the Lua file in `scripts_modinstalled/`?
- Does `MODULE_ID` exactly match `[ID:...]` in info.txt? A mismatch makes the
  path lookup fail.
- Is RM itself installed and enabled?

### "validation failed"

The message names the exact field. Common causes:

- `module.prefix` does not end in an underscore.
- The `module` blocks in your two JSON files disagree.
- A material `key` has lowercase letters or a space.
- A `material_class` of `GEM` with no `gem_names`.
- A product with zero or two material sources.
- A `contains` naming a reagent code that does not exist.

### "prefix overlaps"

Another module's prefix is a stem of yours or vice versa. Rename.

### Material is grey

`color` names a descriptor that is not loaded in this world. Add
`fallback_colors`, and add a `color_exists` check so it stops being silent.

### Reaction appears but never starts

Almost always a reagent that matches nothing:

- A `mat_id` naming a material that does not exist. Check with `refinish-find`.
- A container slot needing more than one bag's contents.
- A `reaction_class` no loaded material carries.
- Conflicting filters, such as a `mat_id` and `sand_bearing` on the same slot.

### Reaction does not appear at all

- The `category` is not the full prefixed ID.
- The building is a custom workshop that is not installed.
- Permissions excluded the player's civilization, and `fortress_mode` is false.

### Reaction eats the wrong thing

A `BOULDER_ANY` with `non_economic` is catching your own processed materials.
Give those a `reaction_class` (section 6.8).

### Diagnostics

- `preflight.py` catches schema and reference problems before you launch DF.
  Run it first; it is faster than any in-game test.
- `refinish-find` locates injected content in memory.
- `refinish-path` traces how something was built.
- RM's log panel records every injection decision, including which structural
  template each reaction cloned.

---

## 10. Rules and conventions

### Hard rules

1. **Never reference another module's material by `mat_id`** without declaring
   `depends_on`. Use reaction classes.
2. **Your prefix must not overlap anyone else's**, in either direction.
3. **Verify vanilla assets you depend on.** Another mod may have cut them.
4. **Do not remove the shutdown hook** if you use helper scripts.

### Naming

- **Material keys:** uppercase, underscores, no spaces. Descriptive of the
  material, not the process. `GOLDBRONZE`, not `ALLOY_3`.
- **Reaction keys:** uppercase, verb first. `MAKE_GOLDBRONZE`, `GRIND_CEMENT`.
- **Reaction names:** lowercase, verb first, the way vanilla phrases it.
  `make gold bronze bars`.
- **Reagent codes:** lowercase, local, descriptive. `copper_bar`, `sand_bag_1`.

### Content

- Set `skill` on every reaction.
- Set real numbers rather than leaving nulls, except where you compute them.
- Always supply `fallback_colors`.
- Give processed materials a `reaction_class`, both for interoperation and to
  keep them out of `non_economic` filters.

### Reference files

| File | What it is |
|---|---|
| `refinish-module-types.lua` | The authoritative list of every reagent type, product type, building, skill, and material class |
| `rm-module-materials-template.json` | Annotated materials template |
| `rm-module-reactions-template.json` | Annotated reactions template |
| `rm-module-template.lua` | Basic Lua shell |
| `rm-module-template-advanced.lua` | Full Lua shell with runtime helpers |
| `preflight.py` | Offline schema and reference checker |

When this guide and `refinish-module-types.lua` disagree, the Lua file is
correct. It is what the engine actually reads.
