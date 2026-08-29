## 1.3.1

- **Lamp-type valuables now get their glow.** Floor lights, lamps and anything else that emits light were skipped entirely: the check that prevents double-lighting asked whether the item already owned a light component, which is true of every lamp by definition. It now tracks only the lights this mod adds.
- **Items no longer need to be approached or nudged first.** The game puts particle systems to sleep when you are not near them, and sleeping sparkles were being ignored, so an item stayed dark until you walked up to it or picked it up. Dormant sparkles are now included, and a room lights up as you enter it.
- Added a fallback for items that refuse a light on the first attempt, and raised the per-level light ceiling from 28 to 64 now that far more valuables are found.
- New icon.

## 1.3.0

- **Excellent tier now supported.** The game has a fourth rarity that inspects as "Excellent" and carries its own pale-blue sparkle. Every earlier version discarded those items outright, so they never got a glow. They are now marked in their own colour.
- **Furniture is marked properly.** Chairs, tables, paintings, floor lamps and plant pots were skipped because the mod only looked for treasure-class objects. It now treats anything the game attaches its rarity sparkle to as loot, which covers every sellable prop type.
- **The sparkle boost actually applies.** A component test checked a property that does not exist, so the pass that enlarges and speeds up the game's own sparkles had never once run.
- Glow retuned much softer after testing - it marks the item without lighting the room.
- Sparkle colours are correct on every tier. Extra sparkle copies are no longer added: a spawned copy keeps the shared effect's purple tint regardless of colour settings, which contaminated white and blue items.

## 1.2.2

- **Description corrected.** The package blurb claimed a rarity light and boosted sparkles "on every valuable", which overstated the mod. Beams are what CoinBeams adds, and they go on gold and artifact coins only.
- **Carries the newer sparkle build** (internal v25 -> v31). 1.2.1 was packaged from an older copy of the script than the one in use; this ships the current one, including the sparkle-density work and a new `MARK_SPARKLING_ACTORS` switch.
- Package no longer embeds a source-repo link.

## 1.2.1

- **New icon.**
- **Rarity light doubled** - valuables glow twice as strongly.
- **Even sparkle density across items.** The game scatters its rarity sparkle over each item's mesh surface, so a single system spread across a big table read far sparser than the same system on a small trinket. Sparkle copies are now proportional to each item's measured size, so a wardrobe twinkles as readably as a candlestick.

## 1.2.0

- **Found the actual item sparkle.** Every previous version enhanced `NS_Loot_01`, which is the coin / loot-spot effect. The sparkle on furniture, plants and pictures is a different system, `NS_RareProp_01` - which is why none of the earlier boosts ever touched it.
- **The game's own sparkles are now enhanced directly**, so they stay glued to the item's mesh surface and keep aligning correctly on wall-mounted pictures: **2.2x bigger** (scaled at the emitter's own size curve), **faster twinkle**, and **two extra sparkle systems per item** for density.
- **New: rarity light.** Each valuable gets a small colored point light - blue Rare, purple Epic, white Common. It has no shape or up-vector, so unlike a beam it cannot misalign on a hanging picture. Never casts shadows; capped per level.
- **Item beams are off by default** - they sprouted out of picture frames. Set `ITEM_BEAMS = true` to bring them back.
- **Fixed an intermittent crash on loading in.** The sparkle pass walked every particle component in the level and touched them all, including blueprint archetypes and sequence-owned templates that are not live world components. It now requires a registered component with a real owner, and all cosmetic work waits for the level to finish streaming before it runs.
- Internal cleanup: removed dead diagnostic code left over from development, and the particle sweep now runs a third as often for the same result.

## 1.1.2

- **Fixed crash on loading in.** Valuables were being given the full 81-layer coin beam - roughly 1500 new components and 36 particle systems built across a couple of seconds, on top of a level already carrying 4000+ physics actors. Item beams are now 3 components each with no particles, built at a throttled rate and capped per level.
- **Item beams are 65% smaller** (67cm tall, ~6cm wide) - the old ones punched through ceilings.
- **No more white rings or glitter on item beams.** That came from the coin beam's attached particle system; item beams are pure geometry now.

## 1.1.1

- **Valuables now get a rarity-colored loot beam**, not just a glow shell. The 1.1.0 overlay applied correctly but drew nothing in game: it used the material behind the game's own character glow, which is authored for skeletal meshes and has no static-mesh shader permutation. Beams use the rendering path this mod already proves works.
- Beams on valuables are scaled ~6x the coin beam so they clear the item itself (a table or a potted plant is metres tall; a 32cm beam hid inside it).
- **Common items are now marked too** (the white-sparkle ones), matching Rare and Epic. Set `OUTLINE_MIN_QUALITY = 1` for Rare+ only.
- Overlay shell is still applied as a second layer, now using a static-mesh-safe material.

## 1.1.0

- **New: rarity outlines on valuables.** Carryable treasures now wear a constant, rarity-colored glow shell - blue for Rare, purple for Epic - so you can read a room's loot at a glance instead of flying into each sparkle and inspecting it. Uses the mesh overlay pass the game already uses for its own character glow, so it is always visible and costs nothing per frame once applied.
- Sparkles are bigger, faster, and doubled up (two desynced glitter layers per coin).
- Outlines are configurable: `OUTLINE_ENABLED`, `OUTLINE_MIN_QUALITY` (set `0` to tag common items too), `OUTLINE_RARE` / `OUTLINE_EPIC` colors, `OUTLINE_OPACITY`, `OUTLINE_HDR`.

## 1.0.2

- Fixed: beams on freshly dropped coins (enemy kills, extractor output) now appear instantly instead of seconds late. Spawn notifications bind to the coin class object, which the game reinstances on level travel - the mod now re-registers them on every level change. The periodic catch-up sweep remains as a safety net.

