# Dramatic Shape Voxel Mod

Redistribution of non-derivative code is expressly prohibited after v1.6.0 without permission.

A mod for the [Pokémon Gen 1 Recompilation
Project](https://github.com/bryanthaboi/pokemon-gen1-recomp-project).

The overworld as a voxelized 3D diorama. Also supports experimental
first-person and third-person. Optional PCVR is a separate companion mod.


## Optional PCVR (VoxelVR)

Headset support is **not** bundled here. It lives in
[**VoxelVR**](https://github.com/scottcandy34/VoxelVR) so this mod never
loads LuaJIT FFI or an OpenXR loader (sandbox-safe / Android-friendly).

### Install both

1. Install this mod (**DRAMATIC_SHAPE** 1.9.0+).
2. Import [VoxelVR 1.0.0](https://github.com/scottcandy34/VoxelVR) the same
   way: **MODS → Import mod .zip**.
3. Enable both. On Windows with an OpenXR runtime (SteamVR, Oculus, WMR, …)
   a **VR** row appears on the OPTIONS menu.

### Requirements for VR

- Windows x64
- OpenXR runtime + PCVR headset
- This mod enabled (VoxelVR depends on it)

Without VoxelVR, everything else in this mod works as usual.


## Controls

Every key is free-roam only, and each one is also a row on the OPTIONS
menu.

| control | does |
| --- | --- |
| `3`, or the **VOXEL** options row | OFF → 15 → 35 → 50 → 75 → 1ST → 3RD → OFF (camera pitch) |
| `SELECT` (pad / touch) | the same step as `3` — for the machines with no number row |
| `5`, or the **V-GRID** options row | OFF / ON — a one-pixel wireframe on every voxel |
| `6`, or the **T-SHIFT** options row | OFF → 1 → 2 → 3 → OFF (miniature blur) |
| `7`, or the **V-CURVE** options row | OFF → 1 → 2 → 3 → 4 → 5 — bend the world over the horizon; 5 is a half sphere |
| the **RENDER DIST** options row | FIT / WIDE / WIDER / WIDEST / OFF — how much of the map the camera bothers to draw. **FIT** is exactly the ground on screen and no more: the trapezoid a tilted camera really frames, which reaches well north of you and flares wide out there — not the square the flat game shows. A connected map falling entirely outside it is skipped before it is drawn, terrain, water, grass and shadows together, which is most of the frame's geometry at the high rungs. Below about 63° that is all the row does and the picture is untouched; at **75** the camera sees to the horizon, so something has to name a distance — FIT is the closest, the wider rungs push the world's edge out, **OFF** stops cutting. Not on **1ST** or **3RD**: you are standing in the world there, and the box opens out and away as the camera dives in. **FULL** sets it to FIT |
| `8`, or the **3D-BTL** options row | 2D-3D A / 2D-3D B / STADIUM A / STADIUM B / OFF — fight in 3D instead of on a white field. **A** stages it on the map, **B** on two discs against the sky; **2D-3D** uses the game's own battle pics and **STADIUM** the Pokémon Stadium battle models |
| `9`, or the **WATER** options row | FULL / SKY / OFF — waves and reflections on water. **SKY** gives the surface its pixel-tall wave columns and puts the sky, the sun, the moon and the cast in them; **FULL** adds a screen-space ray march that also reflects the shoreline, the trees and the buildings standing behind it |
| the **BACK SPRITES** options row | OFF / ON — keep your own Pokémon on the battle menu, seen from behind in its classic slot, instead of standing it on the map; the foe is still out there. Only on the menu while **3D-BTL** is on, because it decides nothing without it |
| the **SHADOWS** options row | ON / OFF — real cast shadows, thrown by rendering the whole scene a second time from the sun, so buildings, trees, ledges and people shadow whatever they land on: walls, roofs, each other. The most expensive pass in the mode after the geometry itself, and the first thing to turn off on a phone or an old machine. **OFF** is no shadow at all — the flat drop shadows under characters included — and the forest's light shafts go with it, since the beams are lit by the sun's own map. **FULL** leaves it alone |
| the **AA** options row | OFF / 2X / 4X — smooth the stair-stepped edges of the 3D world by rendering the diorama larger than the window and folding it back down. The ladder is samples per display pixel: 2X is a canvas root-two wider and taller, 4X one exactly twice the size. Every edge in the projected picture softens with the silhouettes — the tileset's own texels are quads in a perspective view and cross the pixel grid at the same arbitrary angles — so the diorama reads smoother rather than sharper. The most expensive row in the mod, so it is OFF by default and **FULL** leaves it alone |
| the **DAYTIME** options row | SYNC / DAY / NIGHT / DUSK / DAWN / CYCLE — what time it is outdoors, on the diorama *and* on the flat 2D world; held at SYNC (and off the menu) while VOXEL is FULL |

## Free-roam cameras (1ST / 3RD)

The last two rungs of the **VOXEL** ladder are experimental, and they are
the same camera: **1ST** stands it in the player's own eyes, **3RD** pulls
it back onto a boom behind their shoulder. Both steer, and on both the grid
walk is replaced by continuous camera-relative movement — push in any
direction and you go there, at any angle, not just along the four compass
lines. Collision, warps, ledges, encounters and scripts all still run
through the engine's own machinery.

| control | does |
| --- | --- |
| mouse | look (the cursor is captured; left click is A, right click is B) |
| right stick | look |
| a touch drag off the overlay's controls | look |
| left stick / touch d-pad / arrow keys | walk, relative to where the camera looks |
| wheel, `Q` / `E`, pinch, or a stick click | **3RD only** — let the boom out and pull it in (`Q` and left stick click out, `E` and right stick click in) |

On an **orbit rung** the same wheel, `Q`/`E` and pinch drive the engine's own
survey zoom. On **1ST** they do nothing at all: the eye is in your head, and
there is no distance to change.

On **3RD** the boom shortens against whatever is behind you, so backing into
a wall walks the camera in to your shoulders rather than through it — squeeze
it all the way in and the view is 1ST until you step clear. The character
turns to face where they are walking, and every sprite in the world — yours,
the NPCs', the figures drawn into the furniture — turns to face the camera
and shows the frame it would look like from where the camera actually
stands, so walking behind someone shows you their back.

## The battle camera

A fight staged on the map (**3D-BTL**, on by default) is shot with a solved
over-the-shoulder rig — and you can steer it.

| control | does |
| --- | --- |
| right stick, a touch drag, or the mouse | swing the shot around the arena (→) and raise the seat (↑) |
| wheel, `Q` / `E`, pinch, or a stick click | the lens (`Q` / left stick click out, `E` / right stick click in) |

Both axes stop where the composition does. Left stops at the shot the rig was
solved for — there is nothing to the left of it. Right ends **side-on**: the
eye square to the arena's axis, both Pokémon at the same distance instead of
one behind the other. Down stops at the rig's own low stance; up is 45° above
it. The lens opens as you swing or climb, by exactly the amount the two
Pokémon spread apart, so they stay framed at every angle. Move animations
follow the pair's position *and* its separation, so a beam still lands on the
Pokémon it was aimed at.

Where you leave the camera is where the next battle opens.

**BACK SPRITES locks it.** That setting pins your own Pokémon to the GB's slot
on the menu while the foe stands out on the map, and no angle holds a
composition that is half frame and half world — so with it on, the shot holds
the one the rig was solved for.

## STADIUM battles

The **3D-BTL** row has five rungs, which are two choices — what is standing
there, and where:

| rung | the fight |
| --- | --- |
| **2D-3D A** | staged on the map, with the Game Boy's own pics stood up on their tiles |
| **2D-3D B** | those same pics on two discs against the sky, with no map drawn |
| **STADIUM A** | staged on the map, with the Pokémon Stadium battle models |
| **STADIUM B** | those models on the discs |
| **OFF** | the engine's own battle screen |

**A** is the map — real ground, in that place's own weather and light. **B**
is the carried stage, which works everywhere, including the caves and shop
floors that have nowhere to put a fight. Only the STADIUM rungs need a ROM;
**2D-3D B** is generated in Lua and uses the game's own art.

Skinned and animated, playing the animation the move being used actually
calls for — the Stadium ROM's own per-species move table, so **DIG** really
does put Diglett into the ground. Fainting plays the faint and holds there, a
send-out grows the Pokémon out of the ball as it opens and plays the entrance,
and between all of that the standby loop runs. Eyes blink and go dizzy;
Charmander's tail flame and Weezing's gas are drawn over the body.

Taking damage plays nothing, because the set has no damage reaction in it —
the slot that looked like one is each species' default attack, which is why
being hit used to look like swinging. The engine's own screen flash, pic blink
and HP drain are what say "that hurt".

148 of the 151 have models. Exeggutor, Tangela and Magmar come out of the ROM
with corrupt standby loops and stand as their Game Boy battle sprites
instead, on their own tile, in the same arena — the same per-Pokémon fallback
a substitute doll and the pre-send-out trainer pic already take.

**B is for the maps that cannot host a fight.** Half of Kanto's interiors are
furniture, a cave floor can be nothing but corridors, and a map where neither
Pokémon can be *seen* from a low camera is declined outright — which drops you
back to the flat battle screen. B carries its stage, so it works everywhere
and looks the same every time. It is abstracted from the ground, not from the
world: the sky behind the discs is the hour's own, and a fight in a cave is
under that cave's void and its own flat light.

### Getting the models

**They are not in this mod, and they cannot be** — they are Pokémon Stadium's
data. What ships is the reader; you supply the cartridge, exactly as this
engine already asks you to supply the Game Boy ROM it is a recompilation of.

> **You must supply a Pokémon Stadium (US) 1.0 ROM.** Not Stadium 2, not
> another region, not a later revision. Every offset in the reader was
> measured against that one cartridge, and nothing else is promised: a
> different file is either refused outright or builds models that are subtly
> wrong. The mod checks, and says so — on the console, and on the loading
> screen itself if it built from something unexpected.
>
> The reference dump is **md5 `ed1378bc12115f71209a77844965ba50`**, 32 MB.
> The mod does not tell you where to get one, and none ships with it.

1. Open **OPTIONS** and press the **STADIUM ROM** row. It opens your system's
   file picker; choose your **Pokémon Stadium (US) 1.0** ROM. `.z64`, `.n64`
   and `.v64` all work — the byte order is detected, and the wrong file is
   refused with a reason rather than half-built.
2. The 151 models are built on a loading screen that says so and shows a
   progress bar, in about ten seconds. The row then reads **READY**.

The ROM itself is **not kept** — it is read, built from, and forgotten, so
the cartridge does not sit in your save directory alongside the models it
produced. Press the row again any time to import a different one.

There is no picker on Android, or on a Linux install with neither `zenity`
nor `kdialog`. Those keep the original route, which still works everywhere:

- Put the **US 1.0** ROM in a `baseroms/` folder beside the game — straight
  in it, not in a subfolder — and start the game.
- In a packaged build (and on Android) `baseroms/` goes in the save
  directory; the mod logs the exact path on startup when it cannot find one.
  On Android that is the app's external-files folder, reachable over USB or
  any file manager without root.

Either way, the two STADIUM rungs appear on the 3D-BTL row when it's done.

The built models live in the save directory, not in the mod folder, and are
rebuilt automatically if the format changes or the ROM does. Until they exist
the STADIUM rungs are simply not on the row — skipped rather than shown and
refused, because a setting you can select that then does nothing is worse than
one that is not there.

**This works on mobile.** The extraction is pure Lua — no FFI, no native
helper, no second process — so it runs anywhere LÖVE does. It peaks at about
68 MB of Lua heap (32 MB of that the cartridge itself) with a working set that
does not grow across the run, and `tests/stadium_budget_test.lua` fails if
either stops being true. On Android the save directory is the app's
external-files folder, so `baseroms/` there is reachable over USB or a file
manager without root; the build is slower than a desktop's ~7 s but runs one
species a frame behind the progress bar either way.

Developers can pre-build them with `tools/stadium_pack.py`, which reads the
same ROM through `model_extract/pipeline`. That path is also the *oracle*:
`tests/stadium_extract_test.lua` runs it and the in-game Lua extractor over
the same cartridge and requires all 151 packed files to come out byte for byte
identical.


## Licenses

It redistributes one third-party binary:



Everything else in this mod is original to it, except that the voxel
geometry and shape profiles are derived from the tile and sprite data of
the original game, as documented by the
[pret/pokered](https://github.com/pret/pokered) disassembly. No ROM
data, artwork or audio is included; the mod reads the assets the host
game already has.

### Acknowledgements — pret/pokestadium

The STADIUM battle models are read out of the player's own Pokémon Stadium
(US) 1.0 cartridge by original code in [`lib/`](lib) and
[`model_extract/`](model_extract). **That code exists because of
[pret/pokestadium](https://github.com/pret/pokestadium)**, the community
decompilation of that game, which is the reference this mod's reader was
written against. Specifically, it is where the following came from:

- the bone matrix chain, and the fact that scale is kept *out* of it and
  applied only at draw time (`func_800143C0`) — the single most important
  thing to get right in the whole rig, and not guessable from the data
- the rotation basis and its row-vector `Rx·Ry·Rz` order
  (`func_8000F730`, `src/F420.c`)
- the animation player's frame counter and loop-start behaviour
  (`func_80016FBC`), and the texture-animation sampler that *clamps* past
  the end of its stream rather than wrapping (`func_80017540`) — which is
  the difference between a Pokémon blinking and twitching
- the battle system's per-species animation context slots and the routines
  that select them (`func_8432B0A4`, `func_8430506C`, `func_84305A74`)
- the move-id constants the per-species move table is keyed by

**No code, data or asset from that project is included in or redistributed
by this mod**, and none is needed to build or run it. What was taken is an
understanding of the file formats, re-expressed in this mod's own Lua and
Python. If you want to reuse anything from the decompilation itself, get it
from upstream and follow that project's own terms.

No Pokémon Stadium ROM data ships here either. The models are built on the
player's own machine, from a cartridge they supply, into their own save
directory — see [Getting the models](#getting-the-models).
