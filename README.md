# Coin Beams

**Borderlands/Diablo-style loot beams for Grain Rot.**

Dropped valuables get a soft vertical shaft of light rising above them —
**gold** beams over gold coins, **purple** beams over artifacts — visible
across a dark room without dominating the scene. The beam is layered from
dozens of concentric translucent cylinders for a smooth glow taper, topped
with the game's own loot-glitter particles tinted to match and drifting up
the beam.

No keybinds, no configuration needed in-game: beams appear automatically on
every gold coin and artifact as levels load and as new loot spawns.

## Installation (manual)

1. Install [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) — an
   **experimental** build (v3.0.1-1021 or newer) — into
   `Grain Rot\Helden\Binaries\Win64\`.
2. Copy this package's `UE4SS_Signatures` folder into the `ue4ss` folder
   (next to `UE4SS.dll`). **Required** — without these signature files UE4SS
   crashes at startup on this game's engine version (UE 5.7).
3. Copy `Mods\CoinBeams` into `ue4ss\Mods\`.

The included `enabled.txt` activates the mod — no `mods.txt` editing needed.

## Multiplayer

Purely visual and local: only players with the mod see beams. Modded and
unmodded players join each other freely; nothing in the game files is
modified.

## How it works

- Each beam is a stack of thin engine-cylinder static meshes (81 layers,
  widths tapering exponentially) attached to the coin, using an emissive
  material via per-rarity dynamic material instances with HDR-boosted tint —
  the bloom pass turns the additive stack into a soft glow core.
- The material's tint parameter names are discovered at runtime by reading
  the game's own pre-tinted material instances, so unknown names no-op
  safely.
- Zero polling: new loot is caught by object-creation notifications and
  drained one per frame from a hook on the player's animation update, with a
  single catch-up sweep per level plus a slow periodic re-sweep for
  late-activating coins. Placed beams cost nothing per frame.

## Tuning

All knobs live in the `CFG` table at the top of
`Mods/CoinBeams/Scripts/main.lua` — beam height/width, per-rarity colors,
HDR boost, sparkle size/speed. UE4SS hot reload (Ctrl+R, only while idle —
never during a level transition) applies changes without restarting.

## Credits

Runs on [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS). Signature fixes
from UE4SS issue #1228.
