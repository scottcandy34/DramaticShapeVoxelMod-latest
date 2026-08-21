-- Dramatic Shape Voxel Mod's own SDK suite: the mod loads clean, both
-- render pipelines land in the "render_pipelines" registry with the shape
-- the engine dispatches on, and the whole thing stays inert on a machine
-- that cannot run the 3D pass (which is exactly what the headless harness
-- is).

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Pipelines = require("src.render.Pipelines")

local Data = T.fixtures.load()
-- DS_MOD_PATH lets the suite run against a copy of the mod. The game holds
-- an open handle on the live directory while it is running, and on Windows
-- that is enough to make the headless loader's directory probe fail, so a
-- run alongside a live session points at a copy instead.
local MOD_PATH = os.getenv("DS_MOD_PATH") or "mods/DramaticShapeVoxelMod"
local run = T.sdk.loadMod(MOD_PATH, { data = Data })

T.eq(#run.errors, 0,
  "DRAMATIC_SHAPE loads clean: " .. table.concat(run.errors, "; "))

-- Game:load does this after the merge; the SDK harness merges into a
-- fixture dataset instead, so point the dispatcher at that one.
Pipelines.install(Data)

-- ------- the records reached the registry

local defs = Data.render_pipelines
T.check(type(defs) == "table", "the merge created the render_pipelines namespace")
T.check(type(defs.voxel) == "table", "the voxel pipeline is registered")
T.check(type(defs.tiltshift) == "table", "the tiltshift pipeline is registered")

T.eq(defs.voxel.label, "VOXEL", "voxel carries its options-row label")
T.eq(defs.tiltshift.label, "T-SHIFT", "tiltshift carries its options-row label")
T.eq(defs.voxel.hotkey, "3", "voxel claims hotkey 3")
T.eq(defs.tiltshift.hotkey, "6", "tiltshift claims hotkey 6")
T.check(type(defs.voxel.drawWorld) == "function",
  "voxel is a world pipeline (drawWorld)")
T.check(type(defs.tiltshift.worldPresent) == "function",
  "tiltshift is a world post-process (worldPresent)")
T.check(defs.tiltshift.drawWorld == nil,
  "tiltshift does not claim the world pass")

-- provenance: a callback that throws at play time must be attributable to
-- this mod, not reported as an engine fault
T.eq(defs._owners and defs._owners.voxel, "DRAMATIC_SHAPE",
  "the merge stamped the pipeline's owning mod")

-- ------- the ladders the engine drives

T.eq(#defs.voxel.levels, 8, "voxel exposes an eight-rung ladder")
T.eq(defs.voxel.levels[1], "OFF", "rung 0 is OFF")
T.eq(defs.voxel.levels[2], "FULL",
  "FULL is the first rung after OFF -- the order those two get used in")
T.eq(defs.voxel.levels[6], "75", "rung 5 is the 75-degree camera")
T.eq(defs.voxel.levels[7], "1ST (EXPERIMENTAL)",
  "rung 6 is the first-person camera, labelled as the experiment it is")
T.eq(defs.voxel.levels[8], "3RD (EXPERIMENTAL)",
  "and the top rung is the third-person one, labelled the same way")
T.eq(Pipelines.maxLevel("voxel"), 7, "the engine reads the ladder height")
T.eq(Pipelines.levelLabel("voxel", 3), "35", "the engine reads the rung labels")

-- ------- gating: inert until switched on, and inert without a GPU

T.eq(Pipelines.level("voxel"), 0, "the mode starts switched off")
T.eq(Pipelines.worldPipeline(), nil,
  "nothing owns the world pass while every pipeline is off")

Pipelines.setLevel("voxel", 2)
T.eq(Pipelines.level("voxel"), 2, "the engine can set the mode's level")
-- the headless love stub has no depth canvas, so `available` says no and
-- the engine keeps the vanilla 2D path -- the property that makes the mod
-- safe to ship enabled
T.eq(Pipelines.worldPipeline(), nil,
  "an unavailable pipeline never takes the world pass")

-- one world pipeline at a time, and never alongside the engine's tilt
local Tilt = require("src.render.Tilt")
Tilt.setLevel(3)
Pipelines.setLevel("voxel", 1)
T.eq(Tilt.level, 0, "switching a world pipeline on switches TILT off")

-- a post-process is not a world pipeline, so it composes with tilt
Tilt.setLevel(2)
Pipelines.setLevel("tiltshift", 3)
T.eq(Tilt.level, 2, "a worldPresent pipeline leaves TILT alone")

-- ------- persistence round-trip

local opts = { tilt = 0, pipelines = {} }
Pipelines.syncOptions(opts)
T.eq(opts.pipelines.voxel, 1, "the level is written back to save.options")
T.eq(opts.pipelines.tiltshift, 3, "every pipeline's level is written back")

Pipelines.reset()
T.eq(Pipelines.level("voxel"), 0, "reset clears the live levels")
Pipelines.applyOptions(opts)
T.eq(Pipelines.level("voxel"), 1, "a restored save restores the mode")
T.eq(Pipelines.level("tiltshift"), 3, "a restored save restores the blur")

-- ------- the options rows the menu splices in

local rows = Pipelines.rows({ save = { options = opts } })
T.eq(#rows, 2, "each pipeline contributes exactly one options row")
local byLabel = {}
for _, row in ipairs(rows) do byLabel[row.label] = row end
T.check(byLabel.VOXEL ~= nil, "the VOXEL row is offered")
T.check(byLabel["T-SHIFT"] ~= nil, "the T-SHIFT row is offered")
T.eq(byLabel.VOXEL.value(), "FULL", "the row renders the current rung's label")

-- ------- this mod's own settings
--
-- None of them is a pipeline -- two parameterise the voxel pass rather than
-- owning one, and the third decides what a BATTLE is drawn over, which is
-- not a stage the registry has -- so they reach the same menu through the
-- ui.options.rows hook, and store themselves where the mod manager's
-- settings page looks.

local Runtime = require("src.mods.Runtime")
local VoxelState = run.loader.exports.DRAMATIC_SHAPE.lib.require("VoxelState")
-- ------- reaching the rows now that they are on menus of their own
--
-- The ui.options.rows hook contributes ONE row to the engine's list, and that
-- row opens the mod's own screens. So a test asks SettingsMenu.rows -- which
-- is pure on purpose, precisely so that asking what is on a menu does not mean
-- pushing one -- rather than scanning the hook's output for a setting.
--
-- Keyed by id, because that is the one thing about a row that is a promise.
-- The old positional lookups (hookedRows[7] is 3D-BTL) pinned an ORDER the
-- menus are now free to change, and every one of them had to be rewritten to
-- get here; none of them was testing the order on purpose.
--
-- One table rather than three locals: this file is one Lua chunk, a chunk has
-- 200 local slots, and it is already spending them carefully (see the scoped
-- sections throughout).
local Menus = { lib = run.loader.exports.DRAMATIC_SHAPE.lib.require("SettingsMenu") }

function Menus.rows(catId, game)
  local ids = {}
  for _, row in ipairs(Menus.lib.rows(catId, game or { data = Data })) do
    ids[row.id] = row
  end
  return ids
end

-- every row the mod offers ANYWHERE: the root menu plus all four categories.
-- What most of this file wants, since "is this setting on a menu at all" is
-- the question the `when` and `full` gates actually answer.
function Menus.offered(game)
  local ids = Menus.rows(Menus.lib.ROOT, game)
  for _, cat in ipairs(Menus.lib.CATEGORIES) do
    for id, row in pairs(Menus.rows(cat.id, game)) do ids[id] = row end
  end
  return ids
end

-- the id of a category's own row on the root menu
function Menus.catId(catId)
  return Menus.lib.id(catId)
end

-- ------- FULL is a preset that owns the rows describing the LOOK
--
-- While it is selected the settings it drives come OFF the menu -- including
-- T-SHIFT, which is a pipeline row the engine spliced in. A row that no
-- longer decides anything is worse than no row.
--
-- The two BATTLE rows are the exception and stay. 3D-BTL decides what a fight
-- is drawn over and BACK SPRITES how it is framed; neither is a knob on the
-- diorama the preset is a preset FOR. FULL sets them on arrival and then lets
-- go, which is what makes it a preset rather than a lock.
Pipelines.setLevel("voxel", VoxelState.FULL_LEVEL)
-- scoped, like the sections below: this file is one Lua chunk and a chunk has
-- 200 local slots, so a section that wants four borrows them
do
local fullRows = Runtime.call("ui.options.rows", function(_, r) return r end,
                              { data = Data },
                              { { id = "tilt" }, { id = "pipeline:voxel" },
                                { id = "pipeline:tiltshift" } })
local fullIds = {}
for _, row in ipairs(fullRows) do fullIds[row.id] = true end
-- what the hook leaves on the ENGINE's list: one row, and the pipeline rows
-- gone from it because they have moved onto the mod's own root menu
T.check(fullIds[Menus.catId(Menus.lib.ROOT)],
  "the mod contributes exactly one row to the OPTIONS menu")
T.check(not fullIds["pipeline:voxel"],
  "and takes VOXEL off the engine's list -- it lives on the mod's menu now")
T.check(not fullIds["pipeline:tiltshift"], "and T-SHIFT with it")
T.eq(fullRows[1].id, Menus.catId(Menus.lib.ROOT),
  "and it LEADS the list: a mod that replaces the look of the whole game "
  .. "should not make the player scroll to find out where its settings went")

local fullRoot = Menus.rows(Menus.lib.ROOT)
local fullOffered = Menus.offered()
T.check(fullRoot["pipeline:voxel"], "FULL keeps the VOXEL row it lives on")
T.check(not fullRoot["pipeline:tiltshift"],
  "FULL takes T-SHIFT off the menu -- it owns the blur")
T.check(not fullOffered["DRAMATIC_SHAPE:grid"], "and V-GRID")
T.check(not fullOffered["DRAMATIC_SHAPE:curve"], "and V-CURVE")
T.check(not fullOffered["DRAMATIC_SHAPE:viewbox"], "and RENDER DIST")
T.check(not fullOffered["DRAMATIC_SHAPE:water"], "and WATER")
T.check(not fullOffered["DRAMATIC_SHAPE:daytime"], "and DAYTIME")
-- and with all five of them gone the category has nothing left in it, so it
-- takes ITSELF off the root menu. No rule anywhere says "hide 3D WORLD under
-- FULL" -- that category is exactly the rows FULL owns, and an empty category
-- is not offered.
T.check(not fullRoot[Menus.catId("world")],
  "so 3D WORLD is empty, and an empty category is not offered")

-- but the battle rows survive it: they are not knobs on the look, and FULL
-- sets them once rather than holding them, so a player who wants the classic
-- back sprite (or no staged fights at all) can still say so from inside FULL
T.check(fullOffered["DRAMATIC_SHAPE:battles"],
  "3D-BTL is still on the menu under FULL")
T.check(fullOffered["DRAMATIC_SHAPE:battleBack"], "and BACK SPRITES with it")
T.check(fullRoot[Menus.catId("battles")],
  "and the category that carries them is still offered")
-- and AA, for the opposite reason: it is not a knob on the look at all, it is
-- what the look COSTS, and only the player knows what their machine can carry
T.check(fullOffered["DRAMATIC_SHAPE:aa"],
  "and AA, which FULL neither sets nor owns")
-- SHADOWS on the same reasoning: the sun's pass is what the look costs, and
-- a preset for the diorama does not get to spend a second draw of the whole
-- world on a machine that cannot carry one
T.check(fullOffered["DRAMATIC_SHAPE:shadows"],
  "and SHADOWS, the other row that is a question about the hardware")
T.check(fullRoot[Menus.catId("perf")],
  "PERFORMANCE is the category for exactly that question, and it survives too")
-- VR survives FULL on AA's reasoning: whether a headset is on the desk is
-- not the diorama's to decide
T.check(fullOffered["DRAMATIC_SHAPE:vr"],
  "and VR, likewise the hardware's question")
end

-- DAYTIME is not only hidden under FULL, it is HELD at SYNC: the row cannot
-- be reached while FULL owns it, so a value changed underneath (the mod
-- manager's page, an edited options file) snaps back when the menu asks
do
  local DayNight = run.loader.exports.DRAMATIC_SHAPE.lib.require("DayNight")
  DayNight.setting:sync("night")
  Runtime.call("ui.options.rows", function(_, r) return r end,
               { data = Data }, { { id = "tilt" } })
  T.eq(DayNight.setting:get(), "sync",
    "under FULL the rows hook pins DAYTIME back to SYNC, whatever was chosen")
end

-- ------- BATTLE LAYOUT is pinned to OG while a fight can be staged on the map
--
-- The staged battle is composed in the GB's own 160x144 frame: the anchors the
-- arena camera is solved to put a cell under, the HUD rects the frosted panels
-- are cut to, the full-frame white intercepted to let the world through. WIDE
-- lays the same battle out on a 304x144 surface and moves every one of them. So
-- the value is set and the ENGINE's row comes off the menu -- the one row this
-- mod takes away that is not its own.
--
-- Scoped in a block of its own, like the sections below: this file is one Lua
-- chunk and a chunk has 200 local slots, so a section that wants half a dozen
-- borrows them rather than spending them for the rest of the run.
do
local Battles = run.loader.exports.DRAMATIC_SHAPE.lib.require("OverworldBattle")
T.eq(Battles.enabled(), true, "3D-BTL is on by default, which is what pins it")

-- off FULL first: the row on its own has to be enough, and FULL is checked
-- separately below
Pipelines.setLevel("voxel", 2)
local layoutGame = {
  data = Data,
  save = { options = { battleLayout = "wide", pipelines = {}, modOptions = {} } },
  mods = { modOptions = {} },
  writeOptions = function() end,
}
local pinned = Runtime.call("ui.options.rows", function(_, r) return r end,
                            layoutGame,
                            { { id = "battleLayout" }, { id = "tilt" },
                              { id = "pipeline:voxel" } })
local pinnedIds = {}
for _, row in ipairs(pinned) do pinnedIds[row.id] = true end
T.check(not pinnedIds["battleLayout"],
  "with staged battles on, BATTLE LAYOUT is off the menu")
T.eq(layoutGame.save.options.battleLayout, "og",
  "and a save that had WIDE is set to OG -- the only layout the shot composes in")

-- the STADIUM rung is still a staged fight, so it pins the layout exactly
-- as 2D-3D does: what changes on that rung is what stands on the cells, not
-- where the cells are or what screen they are composed for
Battles.setting:setValue("stadium", layoutGame)
T.eq(Battles.enabled(), true, "STADIUM stages the fight like 2D-3D does")
layoutGame.save.options.battleLayout = "wide"
Runtime.call("ui.options.rows", function(_, r) return r end, layoutGame,
             { { id = "battleLayout" } })
T.eq(layoutGame.save.options.battleLayout, "og",
  "and pins BATTLE LAYOUT to OG the same way")

-- switching 3D-BTL off hands the row straight back, WIDE and all
Battles.setting:setValue(false, layoutGame)
T.eq(Battles.enabled(), false, "3D-BTL off")
local handedBack = Runtime.call("ui.options.rows", function(_, r) return r end,
                                layoutGame,
                                { { id = "battleLayout" }, { id = "tilt" },
                                  { id = "pipeline:voxel" } })
local backIds = {}
for _, row in ipairs(handedBack) do backIds[row.id] = true end
T.check(backIds["battleLayout"], "the engine's row is back on the menu")
layoutGame.save.options.battleLayout = "wide"
Runtime.call("ui.options.rows", function(_, r) return r end, layoutGame,
             { { id = "battleLayout" } })
T.eq(layoutGame.save.options.battleLayout, "wide",
  "and WIDE is left alone once no battle can be staged on the map")

-- and FULL does not override that. It used to: the preset owned the 3D-BTL row
-- and hid it, so "FULL is selected" was a safe stand-in for "battles are
-- staged". The row is on the menu under FULL now and can be switched off
-- there, so the stand-in would pin BATTLE LAYOUT to OG for a fight that is
-- never staged. The ROW decides, which is what every other reader of this
-- setting already believed.
Pipelines.setLevel("voxel", VoxelState.FULL_LEVEL)
Runtime.call("ui.options.rows", function(_, r) return r end, layoutGame,
             { { id = "battleLayout" } })
T.eq(layoutGame.save.options.battleLayout, "wide",
  "with 3D-BTL off, FULL leaves the layout alone -- it no longer owns that row")

-- switch the row back on and the pin comes back with it, FULL or no FULL.
-- (Arriving at FULL for real runs applyFull, which switches the row on -- so
-- in the game the pin still follows the preset, by way of the row.)
Battles.setting:setValue(true, layoutGame)
Runtime.call("ui.options.rows", function(_, r) return r end, layoutGame,
             { { id = "battleLayout" } })
T.eq(layoutGame.save.options.battleLayout, "og",
  "and the row switched back on pins it again, from inside FULL")
end

-- ------- TILT and GBC FX are off the menu entirely
--
-- Two ENGINE rows, taken away for as long as this mod is installed. Both fight
-- the diorama and both were already half-taken -- the mode's own key forces
-- them off on every press, and the registry switches TILT off whenever a world
-- pipeline takes the pass -- so what was left was two rows a player could set
-- and watch get reverted.
--
-- Dropped AND held at zero, which is the part that matters: a save written
-- before the mod was installed can carry TILT 3, and a row that is not there
-- is a row that cannot turn it back off.
do
local fxGame = {
  data = Data,
  save = { options = { tilt = 3, gbcfx = 2, pipelines = {}, modOptions = {} } },
  mods = { modOptions = {} },
  writeOptions = function() end,
}
local Tilt = require("src.render.Tilt")
local GBCFX = require("src.render.GBCFX")
Tilt.setLevel(3)
GBCFX.setLevel(2)

local fxRows = Runtime.call("ui.options.rows", function(_, r) return r end,
                            fxGame,
                            { { id = "tilt" }, { id = "gbcfx" },
                              { id = "colors" }, { id = "pipeline:voxel" } })
local fxIds = {}
for _, row in ipairs(fxRows) do fxIds[row.id] = true end
T.check(not fxIds["tilt"], "TILT is off the OPTIONS menu")
T.check(not fxIds["gbcfx"], "and so is GBC FX")
T.check(fxIds["colors"],
  "with every other row the engine offered still on it")
-- VOXEL is off this list too, but for the opposite reason: not taken away,
-- MOVED -- onto the mod's own root menu, which the one remaining row opens
T.check(not fxIds["pipeline:voxel"] and fxIds[Menus.catId(Menus.lib.ROOT)],
  "and VOXEL moved onto the mod's own menu rather than being dropped")
T.check(Menus.rows(Menus.lib.ROOT)["pipeline:voxel"],
  "-- where it is still offered")

T.eq(fxGame.save.options.tilt, 0,
  "a save that had TILT on is pinned back to off, not left on with no row")
T.eq(fxGame.save.options.gbcfx, 0, "and GBC FX with it")
T.eq(Tilt.level, 0, "the live level follows, so the frame is not still tilted")

-- and FULL, which takes its own branch through the rows hook, must not be a
-- way back in
Pipelines.setLevel("voxel", VoxelState.FULL_LEVEL)
local fullFx = Runtime.call("ui.options.rows", function(_, r) return r end,
                            fxGame, { { id = "tilt" }, { id = "gbcfx" } })
local fullFxIds = {}
for _, row in ipairs(fullFx) do fullFxIds[row.id] = true end
T.check(not fullFxIds["tilt"] and not fullFxIds["gbcfx"],
  "under FULL they are gone too -- the drop is above every branch")
Pipelines.setLevel("voxel", 2)
end

-- ------- and off FULL, the rows come back -- on the mod's own menus
--
-- What the engine's list carries is ONE row, and it leads. What that row opens
-- is the mod: the two pipeline rows it took off the engine's list, and the
-- four categories.
Pipelines.setLevel("voxel", 2)
do
local grouped = Runtime.call("ui.options.rows", function(_, r) return r end,
                             { data = Data },
                             { { id = "tilt" }, { id = "pipeline:voxel" },
                               { id = "pipeline:tiltshift" },
                               { id = "void_fill" } })
-- the engine gave it four rows and got three back: three of ours are gone
-- (tilt dropped, both pipelines moved) and one is added, at the front
-- the engine offered four and two come back: TILT dropped, both pipeline rows
-- moved onto the mod's own menu, and one row added at the front
T.eq(#grouped, 2, "one row for the whole mod, and the engine's own beneath it")
T.eq(grouped[1].id, Menus.catId(Menus.lib.ROOT), "and it leads the list")
T.eq(grouped[2].id, "void_fill",
  "with the engine's own rows following in the order it built them")

local root = Menus.rows(Menus.lib.ROOT)
T.check(root["pipeline:voxel"] and root["pipeline:tiltshift"],
  "both pipeline rows are on the mod's root menu")
for _, cat in ipairs({ "world", "battles", "perf", "vr" }) do
  T.check(root[Menus.catId(cat)],
    ("off FULL the %s category is offered"):format(cat))
end

-- the split itself: each setting on the category that owns it, and nowhere
-- else. Order inside a category is free to change; membership is the promise.
local WHERE = {
  grid = "world", curve = "world", viewbox = "world", water = "world",
  daytime = "world",
  battles = "battles", battleBack = "battles", letsgo = "battles",
  atmos = "perf", shadows = "perf", aa = "perf",
  vr = "vr", smoothturn = "vr",
}
for key, cat in pairs(WHERE) do
  local id = "DRAMATIC_SHAPE:" .. key
  -- smoothturn and battleBack need their own switch on first; they are
  -- checked where those switches are, so only assert the ones offered now
  if Menus.offered()[id] then
    T.check(Menus.rows(cat)[id],
      ("%s is on the %s menu"):format(key, cat))
  end
end
-- the ROM import is an action, not a setting, and it is one-time SETUP, so it
-- sits on the top-level menu where the mod begins rather than two levels down
-- the category it unlocks
T.check(Menus.rows(Menus.lib.ROOT)["DRAMATIC_SHAPE:stadiumRom"],
  "and STADIUM ROM is on the top-level menu, not inside a category")
T.check(not Menus.rows("battles")["DRAMATIC_SHAPE:stadiumRom"],
  "and only there")
do
  local rootRows = Menus.lib.rows(Menus.lib.ROOT, { data = Data })
  T.eq(rootRows[#rootRows].id, "DRAMATIC_SHAPE:stadiumRom",
    "last on it, because the categories are what the menu is for")
end
end

-- ------- the open menu notices when FULL is stepped onto or off
--
-- A menu reads its row list every frame but builds it once, so without a
-- rebuild the rows FULL owns stay on screen until it is reopened -- and
-- stepping OFF FULL never brings them back.
local OptionsMenu = require("src.ui.OptionsMenu")
local pressed = {}
local menuGame = {
  data = Data,
  save = { options = { pipelines = {}, modOptions = {} } },
  mods = { modOptions = {} },
  input = { wasPressed = function(_, k) return pressed[k] or false end },
  -- a real stack, because the mod's own menus push and pop on it
  stack = {
    states = {},
    push = function(s, st) s.states[#s.states + 1] = st end,
    pop = function(s) s.states[#s.states] = nil end,
    top = function(s) return s.states[#s.states] end,
  },
  writeOptions = function() end,
}

local function rowIndex(m, id)
  for i, row in ipairs(m.rows) do if row.id == id then return i end end
end

Pipelines.setLevel("voxel", 2)
-- The mod's root menu shows the ENGINE's own pipeline descriptors, captured by
-- the hook on its way past. The sections above fed the hook stub rows, which
-- are enough to test what is dropped but carry no step function -- so hand it
-- the real ones before driving the menu, or a keypress on VOXEL does nothing.
Runtime.call("ui.options.rows", function(_, r) return r end, menuGame,
             Pipelines.rows(menuGame))
local menu = Menus.lib.new(menuGame, Menus.lib.ROOT)
T.check(rowIndex(menu, Menus.catId("world")),
  "off FULL the root menu opens with the 3D WORLD category on it")

-- step the VOXEL row from 15 down to FULL, the way the player would
menu.index = rowIndex(menu, "pipeline:voxel")
pressed = { left = true }
menu:update(0)
pressed = {}
T.eq(Pipelines.level("voxel"), 1, "the step landed on FULL")
T.check(not rowIndex(menu, Menus.catId("world")),
  "and the category FULL emptied left the OPEN menu at once")
T.check(not rowIndex(menu, "pipeline:tiltshift"), "T-SHIFT with it")
T.check(menu.index <= #menu.rows + 1, "the cursor stayed in range")
T.eq(menu.index, rowIndex(menu, "pipeline:voxel"),
  "and stayed on the row the player just used")

-- and back off it again
menu.index = rowIndex(menu, "pipeline:voxel")
pressed = { right = true }
menu:update(0)
pressed = {}
T.eq(Pipelines.level("voxel"), 2, "the step left FULL")
T.check(rowIndex(menu, Menus.catId("world")),
  "and the category came straight back without reopening the menu")
T.check(rowIndex(menu, "pipeline:tiltshift"), "T-SHIFT too")

-- ------- 3D-BTL owns BATTLE LAYOUT, from a menu the OPTIONS list cannot see
--
-- The switch lives on the mod's BATTLES menu now, and the stack ticks its TOP
-- state only (src/core/StateStack.update). So the step happens while the
-- OPTIONS menu underneath is suspended, and a before/after pair taken around
-- one call of its update would be read entirely after the fact and always
-- agree. The signature is held on the instance for exactly this.
do
local Battles = run.loader.exports.DRAMATIC_SHAPE.lib.require("OverworldBattle")
Battles.setting:setValue(false, menuGame)         -- staged battles off
menuGame.save.options.battleLayout = "wide"
Pipelines.setLevel("voxel", 2)
local layoutMenu = OptionsMenu.new(menuGame)
T.check(rowIndex(layoutMenu, "battleLayout"),
  "with staged battles off, the engine's BATTLE LAYOUT row is on the menu")

local battleMenu = Menus.lib.new(menuGame, "battles")
T.check(not rowIndex(battleMenu, "DRAMATIC_SHAPE:battleBack"),
  "and BACK SPRITES is off the BATTLES menu, having no staged fight to frame")
battleMenu.index = rowIndex(battleMenu, "DRAMATIC_SHAPE:battles")
pressed = { right = true }
battleMenu:update(0)
pressed = {}
T.eq(Battles.setting:get(), true, "the step switched staged battles on")
T.eq(menuGame.save.options.battleLayout, "og", "pinned to OG on the way out")
T.check(rowIndex(battleMenu, "DRAMATIC_SHAPE:battleBack"),
  "and BACK SPRITES arrived on the open submenu with the same keypress")
-- it arrives BELOW the row that was used, so this one only holds because the
-- cursor follows the row rather than the slot
T.eq(battleMenu.index, rowIndex(battleMenu, "DRAMATIC_SHAPE:battles"),
  "with the cursor still on the row the player just used")

layoutMenu:update(0)
T.check(not rowIndex(layoutMenu, "battleLayout"),
  "and the OPTIONS menu underneath drops BATTLE LAYOUT on its next update, "
  .. "though the step it is reacting to happened while it was suspended")
end

-- ------- the row OPENS the menus, and B comes back one level at a time
do
menuGame.stack.states = {}
Pipelines.setLevel("voxel", 2)
local hookRow
for _, row in ipairs(Runtime.call("ui.options.rows", function(_, r) return r end,
                                  menuGame, Pipelines.rows(menuGame))) do
  if row.id == Menus.catId(Menus.lib.ROOT) then hookRow = row end
end
T.check(hookRow.activate and not hookRow.step,
  "the row answers A alone -- `activate` SHADOWS `step` in the engine's own "
  .. "dispatch, so a row carrying both would silently ignore Left and Right")
T.eq(hookRow.value(menuGame), "15",
  "and its second line is VOXEL's own, so it says what the mode is doing "
  .. "without being opened")

hookRow.activate(menuGame)
local root = menuGame.stack:top()
T.check(root ~= nil, "pressing A pushed a screen")
T.eq(#root.rows, #Menus.lib.rows(Menus.lib.ROOT, menuGame),
  "carrying the root menu's rows")
T.eq(root:backLabel(), "B BACK  SEL HELP",
  "and a bottom line naming the two buttons that are not obvious")
T.check(#root:backLabel() <= 18,
  "which fits the eighteen characters the line has")

-- the second line of a category row
T.eq(root.rows[rowIndex(root, Menus.catId("battles"))].value(),
     Menus.rows("battles", menuGame)["DRAMATIC_SHAPE:battles"].value(),
  "a category one setting speaks for says that setting's rung")
T.eq(root.rows[rowIndex(root, Menus.catId("world"))].value(), "5 SETTINGS",
  "and one no single row speaks for counts them instead, which is honest "
  .. "rather than arbitrary")

-- into a category, and back out of it a level at a time
root.index = rowIndex(root, Menus.catId("world"))
pressed = { a = true }
root:update(0)
pressed = {}
T.check(menuGame.stack:top() ~= root,
  "A on a category opens it, as a screen of its own")
T.eq(menuGame.stack:top().cat, "world", "the one the cursor was on")

pressed = { b = true }
menuGame.stack:top():update(0)
pressed = {}
T.eq(menuGame.stack:top(), root, "B comes back ONE level, to the root menu")
pressed = { start = true }
root:update(0)
pressed = {}
T.eq(menuGame.stack:top(), nil, "and START leaves it the way B does")
end

-- ------- SELECT explains the row the cursor is on
--
-- Every setting has carried a paragraph of help since it was written -- it
-- goes into the schema the mod manager is handed -- and nothing in the engine
-- has ever drawn one. A row says what it IS and what it is SET TO, and no
-- engine row anywhere has room for a third thing.
do
menuGame.stack.states = {}
Pipelines.setLevel("voxel", 2)
local Help = run.loader.exports.DRAMATIC_SHAPE.lib.require("SettingsHelp")
local menu2 = Menus.lib.new(menuGame, "world")

-- every row on every menu has something to say, the two engine-owned pipeline
-- rows and the ROM import included -- those three keep theirs in SettingsMenu,
-- having no SETTINGS entry of their own to keep it in
for _, cat in ipairs({ Menus.lib.ROOT, "world", "battles", "perf", "vr" }) do
  for _, row in ipairs(Menus.lib.rows(cat, menuGame)) do
    T.check(Menus.lib.helpFor(row.id),
      ("%s has help behind SELECT"):format(row.id))
  end
end
T.check(not Menus.lib.helpFor("nothing:here"),
  "and a row with nothing to say gets nil rather than an empty box")

-- every character of every one of them has a glyph in the ROM's font.
--
-- Read from the REAL charmap rather than the fixture's, which is a stub with
-- seven entries in it. This is the one place in the mod where prose reaches
-- the screen verbatim, and Font.encode answers a character it does not know
-- with a SPACE and a one-time console warning that nobody is reading -- so a
-- curly quote or a `%` pasted in from somewhere would blank a word and say
-- nothing about it.
do
  local ok, font = pcall(dofile, "data/generated/font.lua")
  if ok and font and font.charmap then
    local glyph = { [" "] = true }
    for _, e in ipairs(font.charmap) do
      if #e.seq == 1 then glyph[e.seq] = true end
    end
    local missing = {}
    for _, cat in ipairs({ Menus.lib.ROOT, "world", "battles", "perf", "vr" }) do
      for _, row in ipairs(Menus.lib.rows(cat, menuGame)) do
        for ch in (Menus.lib.helpFor(row.id) or ""):gmatch(".") do
          if not glyph[ch] then missing[ch] = true end
        end
      end
    end
    local names = {}
    for ch in pairs(missing) do names[#names + 1] = ("%q"):format(ch) end
    table.sort(names)
    T.eq(#names, 0, "every character of every help string has a glyph in the "
      .. "ROM font -- these do not: " .. table.concat(names, " "))
  end
end

menu2.index = rowIndex(menu2, "DRAMATIC_SHAPE:viewbox")
pressed = { select = true }
menu2:update(0)
pressed = {}
local box = menuGame.stack:top()
T.check(box ~= nil and box ~= menu2, "SELECT opens a box over the menu")
T.eq(box.title, "RENDER DIST", "titled with the row it explains")
T.check(#box.lines > 1, "carrying the row's own description, wrapped")
for _, line in ipairs(box.lines) do
  T.check(#line <= 17,
    "every line fits between the border and the more-arrow's column")
end

-- ------- every description is ONE SENTENCE, and the whole of it is on screen
--
-- Both halves matter and the second follows from the first. The box is sized
-- to what it holds and anchored to the bottom, so a description that fits is
-- read at a glance with the row it describes still visible above it -- and one
-- that does not turns a glance into a scroll, which is a worse answer to
-- "what does this do" than a shorter sentence would have been.
--
-- One sentence is: ends with a full stop, and has none inside it. The version
-- numbers that would break that naive test ("US 1.0") have no space after the
-- point, which is why the check is for ". " rather than for ".".
do
  local long, many = {}, {}
  for _, cat in ipairs({ Menus.lib.ROOT, "world", "battles", "perf", "vr" }) do
    for _, row in ipairs(Menus.lib.rows(cat, menuGame)) do
      local help = Menus.lib.helpFor(row.id)
      if help then
        if help:find(". ", 1, true) or not help:find("%.$") then
          many[#many + 1] = row.id
        end
        local probe = Help.new(menuGame, row.label, help)
        if probe:maxTop() > 0 then
          long[#long + 1] = ("%s (%d lines)"):format(row.id, #probe.lines)
        end
      end
    end
  end
  T.eq(#many, 0,
    "every description is one sentence -- these are not: "
    .. table.concat(many, ", "))
  T.eq(#long, 0,
    "and every one of them fits its box without scrolling: "
    .. table.concat(long, ", "))
end

-- the scroll is still there, for a description that outgrows the box despite
-- the check above -- a mod-supplied font with a wider glyph, or a sentence
-- somebody lengthens later. It stops at both ends rather than wrapping.
do
  local tall = Help.new(menuGame, "TALL", ("word "):rep(80))
  T.check(tall:maxTop() > 0, "a description too long for the box scrolls")
  T.eq(tall.top, 0, "opening at the top")
  pressed = { up = true }
  tall:update()
  pressed = {}
  T.eq(tall.top, 0, "up at the top stays there")
  pressed = { down = true }
  tall:update()
  pressed = {}
  T.eq(tall.top, 1, "down moves one line")
  for _ = 1, 200 do
    pressed = { down = true }
    tall:update()
    pressed = {}
  end
  T.eq(tall.top, tall:maxTop(), "and the end of the text ends the scroll")
  T.eq(tall:maxTop(), #tall.lines - tall:bodyRows(),
    "with the last boxful still full, not one line stranded at the bottom")
end

-- and every button that could mean "done" closes it -- SELECT included, which
-- is the one a player who just pressed it will reach for
for _, btn in ipairs({ "a", "b", "start", "select" }) do
  menuGame.stack.states = {}          -- the scrolled box above is still open
  menu2.index = rowIndex(menu2, "DRAMATIC_SHAPE:viewbox")
  pressed = { select = true }
  menu2:update(0)
  pressed = {}
  T.check(menuGame.stack:top() ~= nil, "the box is open")
  pressed = { [btn] = true }
  menuGame.stack:top():update()
  pressed = {}
  T.eq(menuGame.stack:top(), nil, ("%s closes it"):format(btn:upper()))
end

-- a title strips the "..'" a category row wears to say it opens something:
-- inside the box it has already opened, the dots are a promise about a press
-- that has been made
T.eq(Help.new(menuGame, "3D WORLD..", "x").title, "3D WORLD",
  "a category's box is titled without the dots that meant `opens something'")
-- and the wrap never strands a word it cannot fit
T.eq(#Help.wrapped(("y"):rep(40))[1], 17,
  "a word longer than the line is broken across lines rather than cut")
end

-- ------- the mod's row is RED, which is a palette zone and not a color
--
-- setColor cannot do it here twice over: the glyph atlas is black ink and LOVE
-- tints multiplicatively, and the palette shader keys on the red channel alone
-- so a red pixel would land in the LIGHTEST slot (see lib/SettingsMenu.lua).
-- What a zone changes is which color the SHADE the text was drawn in comes out
-- as, so what there is to assert is where the band sits and which slot carries
-- the ink.
do
local PaletteFX = require("src.render.PaletteFX")
-- the fixture dataset ships no palettes; stand MEWMON up, since the point is
-- that the red palette is MEWMON COPIED rather than four invented colors
Data.palettes = { palettes = {
  MEWMON = { { 255, 239, 255 }, { 255, 140, 140 }, { 80, 80, 255 }, { 0, 0, 0 } },
} }

local red = Menus.lib.redPalette(Data)
T.eq(#red, 4, "the red palette is a palette like any other, four colors")
T.eq(red[1][2], 239,
  "and its paper is MEWMON's own -- Red, Blue and Yellow ship different "
  .. "tables, and the row must not shift the white it sits on")

-- What has to hold is not which slot the red is in but where it comes OUT:
-- black text is shade 3 and the white box fill shade 0, and the display mode
-- transforms the table before the shader ever sees it (effectiveColors). So
-- assert through that, which is the thing the screen actually draws.
do
  local eff = PaletteFX.effectiveColors(red)
  T.check(eff[4][1] == 255 and eff[4][2] == 0 and eff[4][3] == 0,
    "the ink shade comes out red")
  T.eq(eff[1][2], 239, "and the paper shade is the white it always was")
end

-- SGB INV REVERSES the table, so the red has to start in the other slot to
-- land on the ink. Without the special case the row draws as a solid red
-- block with the letters cut out of it.
PaletteFX.mode = "gbc_inv"
do
  local eff = PaletteFX.effectiveColors(Menus.lib.redPalette(Data))
  T.check(eff[4][1] == 255 and eff[4][2] == 0,
    "under SGB INV the ink shade STILL comes out red, once the mode has had "
    .. "its turn at the table")
  T.eq(eff[1][1], 0,
    "on the same dark paper SGB INV gives every other row -- red ink, not a "
    .. "red block")
end
PaletteFX.mode = "gbc"

-- the band covers the two TEXT lines of the box and nothing else: tile 1 is
-- the cursor and tiles 0 and 19 are the box borders, all of them black glyphs
-- that would turn red with the label if the zone spanned the whole row
local zone = Menus.lib.rowZone(Data, 1)
T.eq(zone.x, 16, "the band starts at the label column, past the cursor")
T.eq(zone.y, 8, "on the first box's label line")
T.eq(zone.w, 17 * 8, "and stops short of the box's right border")
T.eq(zone.h, 16, "covering the label and the value under it")
T.eq(Menus.lib.rowZone(Data, 3).y, 8 * ((3 - 1) * 4 + 1),
  "and it is addressed by SLOT, so it follows the row down the screen")

-- on the menu itself: the whole-screen palette it always had, plus one band
menuGame.stack.states = {}
Runtime.call("ui.options.rows", function(_, r) return r end, menuGame,
             Pipelines.rows(menuGame))
local palMenu = OptionsMenu.new(menuGame)
T.eq(#palMenu:sgbPalettes(menuGame), 2,
  "the OPTIONS menu paints its own palette and then the one band")
T.eq(palMenu:sgbPalettes(menuGame)[2].y, 8,
  "on row 1, where the mod's row leads the list")
T.eq(palMenu:sgbPalettes(menuGame)[2].colors[4][1], 255, "and it is the red one")

-- scrolled past, the band goes with it: a red stripe left behind on whatever
-- took the slot would be worse than no marker at all
palMenu.scroll = 4
T.eq(#palMenu:sgbPalettes(menuGame), 1,
  "scrolled off screen, the row takes its band with it")

-- and a submenu paints its own. This is the whole reason it has the method:
-- Game:draw stops at the first state that HAS one, so a submenu without it
-- would inherit the band above and land it on an unrelated row.
T.eq(#Menus.lib.new(menuGame, Menus.lib.ROOT):sgbPalettes(menuGame), 1,
  "a submenu owns its palette rather than inheriting the red band")

Data.palettes = nil
end

-- level 2 is the "15" rung: any rung that is not FULL, so the settings the
-- preset owns are back on the menu
Pipelines.setLevel("voxel", 2)
do
  -- what the engine really hands the hook: its own rows, the pipeline rows
  -- among them. The mod moves those two onto its root menu, so a call that
  -- left them out would leave the root menu with nothing but categories.
  local given = { { id = "text_speed" } }
  for _, row in ipairs(Pipelines.rows({ data = Data })) do
    given[#given + 1] = row
  end
  Runtime.call("ui.options.rows", function(_, r) return r end,
               { data = Data }, given)
end
-- Every row the mod offers, keyed by id. RENDER DIST, FOREST FX, LET'S GO,
-- SHADOWS and AA are read straight out of it where they are used rather than
-- named here, because this chunk is one main function and has 200 local slots
-- to spend.
local hookedRows = Menus.offered()
-- one per setting, plus the STADIUM ROM action row -- which is not a setting
-- (nothing to store, nothing for the mod manager to persist) and is offered
-- on every platform, saying WHERE? rather than IMPORT where there is no file
-- dialog to open -- and the four category rows that carry them
do
  -- named rather than counted: a count says "something moved" and this says
  -- WHAT is meant to be reachable. SMOOTH TURN is absent because VR is off,
  -- which is its own gate and is tested where VR is turned on.
  local want = { "grid", "curve", "viewbox", "water", "daytime",
                 "battles", "battleBack", "letsgo", "stadiumRom",
                 "atmos", "shadows", "aa", "vr" }
  local n = 0
  for _ in pairs(hookedRows) do n = n + 1 end
  for _, key in ipairs(want) do
    T.check(hookedRows["DRAMATIC_SHAPE:" .. key],
      ("%s is reachable from the mod's menus"):format(key))
  end
  T.check(hookedRows["pipeline:voxel"] and hookedRows["pipeline:tiltshift"],
    "and both pipeline rows with them")
  -- those, the two pipelines and the four categories, and nothing else
  T.eq(n, #want + 2 + 4, "and nothing else is on them")
end
local grid = hookedRows["DRAMATIC_SHAPE:grid"]
local curve, water = hookedRows["DRAMATIC_SHAPE:curve"], hookedRows["DRAMATIC_SHAPE:water"]
local battles = hookedRows["DRAMATIC_SHAPE:battles"]
local backRow, daytime = hookedRows["DRAMATIC_SHAPE:battleBack"],
                         hookedRows["DRAMATIC_SHAPE:daytime"]
T.eq(hookedRows["DRAMATIC_SHAPE:viewbox"].label, "RENDER DIST",
  "the viewport row carries its label")
T.eq(hookedRows["DRAMATIC_SHAPE:viewbox"].value(), "FIT",
  "and defaults to FIT -- the cut IS the window the flat game already "
  .. "framed, which is the whole claim the row makes")
T.eq(water.label, "WATER", "the water row carries its label")
T.eq(water.value(), "FULL",
  "and defaults to FULL -- reflections are the point of having the row")
water.step({ save = { options = {} }, mods = { modOptions = {} } }, 1)
T.eq(water.value(), "SKY",
  "stepping down drops the screen-space march and keeps the sky, sun and moon")
T.eq(hookedRows["DRAMATIC_SHAPE:atmos"].label, "FOREST FX", "the atmosphere row carries its label")
T.eq(hookedRows["DRAMATIC_SHAPE:atmos"].value(), "FULL",
  "and defaults to FULL -- it only spends anything on a map with an "
  .. "atmosphere entry, which is one forest today")
T.eq(daytime.label, "DAYTIME", "the day/night row carries its label")
T.eq(daytime.value(), "SYNC",
  "and defaults to SYNC -- no value set follows the clock on the wall")
T.eq(grid.label, "V-GRID", "the grid row carries its label")
T.eq(grid.value(), "OFF", "the grid starts off")
T.eq(curve.label, "V-CURVE", "the curve row carries its label")
T.eq(curve.value(), "OFF", "the curve starts off")
T.eq(battles.label, "3D-BTL", "the overworld-battle row carries its label")
T.eq(battles.value(), "2D-3D A",
  "overworld battles are on by default, on the rung that stands the game's "
  .. "own pics on the map -- the mode's headline is the world in 3D, and a "
  .. "battle is where the player spends half the game")
T.eq(backRow.label, "BACK SPRITES", "the back-pic row carries its label")
T.eq(backRow.value(), "OFF",
  "and is off by default -- what the mode advertises is BOTH mons out on the "
  .. "map, so the classic slot is opt-in")
T.check(backRow.id ~= battles.id and backRow.id:find("battleBack", 1, true),
  "on its own key, so it persists beside 3D-BTL rather than over it")
T.eq(hookedRows["DRAMATIC_SHAPE:letsgo"].label, "LET'S GO", "the capture-mode row carries its label")
T.eq(hookedRows["DRAMATIC_SHAPE:letsgo"].value(), "OFF",
  "and starts OFF -- a gameplay mode is opt-in, whatever the diorama does")

-- stepping writes through to the one place both rows read
local settingGame = { save = { options = {} }, mods = { modOptions = {} } }
grid.step(settingGame)
T.eq(grid.value(), "ON", "stepping the row toggles the grid")
T.eq(settingGame.save.options.modOptions.DRAMATIC_SHAPE.grid, true,
  "the toggle lands in options.modOptions, where the mod manager reads it")
T.eq(settingGame.mods.modOptions.DRAMATIC_SHAPE.grid, true,
  "and in the loader's live copy, which mod.options:get reads")
grid.step(settingGame)
T.eq(grid.value(), "OFF", "stepping again toggles it back")

-- the curve is a six-rung ladder rather than a toggle, and wraps
curve.step(settingGame, 1)
T.eq(curve.value(), "1", "stepping the curve climbs its ladder")
T.eq(settingGame.save.options.modOptions.DRAMATIC_SHAPE.curve, 1,
  "the curve level persists alongside the grid, not over it")
T.eq(settingGame.save.options.modOptions.DRAMATIC_SHAPE.grid, false,
  "and the grid it shares a bucket with is untouched")
for _ = 1, 4 do curve.step(settingGame, 1) end
T.eq(curve.value(), "5", "the ladder reaches its top rung")
curve.step(settingGame, 1)
T.eq(curve.value(), "OFF", "and wraps back to OFF")
curve.step(settingGame, -1)
T.eq(curve.value(), "5", "stepping down from OFF wraps to the top")
curve.step(settingGame, 1)

-- the strength scales with the view height, so a rung looks the same at
-- every zoom -- and is exactly zero when the setting is off
local WorldCurve = run.loader.exports.DRAMATIC_SHAPE.lib.require("WorldCurve")
T.eq(WorldCurve.k(154), 0, "an OFF curve bends nothing")
curve.step(settingGame, 1)
T.check(math.abs(WorldCurve.k(154) - WorldCurve.AMOUNTS[2] / 154) < 1e-9,
  "rung 1's coefficient is its amount over the view height")
for i = 2, #WorldCurve.AMOUNTS do
  T.check(WorldCurve.AMOUNTS[i] > WorldCurve.AMOUNTS[i - 1],
    "the ladder climbs at rung " .. (i - 1))
end
-- rung 5 is the HALF SPHERE, and that is arithmetic rather than taste: the
-- parabola y = k d^2 osculates a sphere of radius R at its pole when
-- k = 1 / 2R, so an amount of 1 puts the sphere's radius at half a view
-- height -- which is exactly where the diorama's box is cut, so the
-- model's own rim is that sphere's equator
T.eq(WorldCurve.AMOUNTS[#WorldCurve.AMOUNTS], 1.0,
  "the top rung's amount is 1 -- the half sphere")
do
  local Dio = (function() local ok,m=pcall(function() return run.loader.exports.DRAMATIC_SHAPE.lib.require("Diorama") end); return ok and m or {} end)() -- may be nil when VR companion absent
  local vh = 288
  local kTop = WorldCurve.AMOUNTS[#WorldCurve.AMOUNTS] / vh
  T.check(math.abs(1 / (2 * kTop) - vh * Dio.BOX_FRAC) < 1e-6,
    "whose radius is the diorama's own half-size: the model ends where "
    .. "the dome does")
end
T.check(math.abs(WorldCurve.k(308) * 2 - WorldCurve.k(154)) < 1e-9,
  "halving the zoom halves the coefficient, so the bend looks the same")
-- the CPU copy Voxel3D.project uses must agree with the shader's quadratic
local k = WorldCurve.k(154)
T.eq(WorldCurve.drop(k, 100, 100, 100, 100), 0,
  "nothing drops at the focus, so the ground underfoot stays flat")
T.check(math.abs(WorldCurve.drop(k, 0, 0, 3, 4) - 25 * k) < 1e-9,
  "the drop is the squared distance times the coefficient")
T.check(WorldCurve.drop(k, 0, 0, 20, 0) > 4 * WorldCurve.drop(k, 0, 0, 10, 0)
        - 1e-9,
  "and accelerates, so the far edge rolls away faster than the near one")
for _ = 1, 5 do curve.step(settingGame, 1) end
T.eq(curve.value(), "OFF", "the curve is left off for the rows below")

-- ------- AA renders the pass larger and folds it back down
--
-- The ladder is SAMPLES per display pixel, so the canvas scale each rung asks
-- for is its square root -- and the scale in force has to be readable after
-- the fact, because two things are quoted in DISPLAY pixels and have to be
-- multiplied up into the canvas the pass actually opened: the wireframe's
-- line width and the FX overlay's sprite scale.
do
local AntiAlias = run.loader.exports.DRAMATIC_SHAPE.lib.require("AntiAlias")
local VoxelGrid = run.loader.exports.DRAMATIC_SHAPE.lib.require("VoxelGrid")
local aaGame = { save = { options = {} }, mods = { modOptions = {} } }
local aa = hookedRows["DRAMATIC_SHAPE:aa"]
T.eq(aa.label, "AA", "the anti-aliasing row carries its label")
T.eq(aa.value(), "OFF",
  "and starts off -- supersampling is a cost knob, and a mod must not spend "
  .. "four times the fill rate of the machine it lands on unasked")

T.eq(AntiAlias.samples(), 0, "AA is off by default")
local w, h = AntiAlias.expand(320, 200)
T.eq(w, 320, "an OFF row renders at the window's own width")
T.eq(h, 200, "and its height")
T.eq(AntiAlias.factor(), 1, "with nothing to multiply display pixels by")
T.eq(VoxelGrid.width(), VoxelGrid.WIDTH,
  "so the wireframe is the one-display-pixel line it has always been")

aa.step(aaGame, 1)
T.eq(aa.value(), "2X", "stepping the row climbs to two samples a pixel")
T.eq(aaGame.save.options.modOptions.DRAMATIC_SHAPE.aa, 2,
  "the sample count persists beside the other settings, not over them")
w, h = AntiAlias.expand(320, 200)
T.eq(w, 453, "two samples a pixel is a canvas root-two wider")
T.eq(h, 283, "and root-two taller")
T.check(math.abs(AntiAlias.factor() - 453 / 320) < 1e-9,
  "and the factor is what it MEASURED, not what the row asked for")

aa.step(aaGame, 1)
T.eq(aa.value(), "4X", "and again to four")
w, h = AntiAlias.expand(320, 200)
T.eq(w, 640, "four samples a pixel is a canvas exactly twice the size")
T.eq(h, 400, "in each direction, which is the 2x2 box the fold reads")
T.eq(AntiAlias.factor(), 2, "with everything in display pixels doubled")
T.eq(VoxelGrid.width(), VoxelGrid.WIDTH * 2,
  "the wireframe among them -- a seam left at 1.0 would fold down to half a "
  .. "line, so the smoothing row would appear to fade the grid row out")

aa.step(aaGame, 1)
T.eq(aa.value(), "OFF", "and the ladder wraps back to off")
AntiAlias.expand(320, 200)
T.eq(AntiAlias.factor(), 1, "leaving nothing behind for the next pass")
end

-- ------- SHADOWS: the sun's own pass, and the row that stands it down
--
-- The most expensive thing in the frame after the geometry -- the whole world
-- drawn a second time from the light, every time anything in it moves -- so
-- the row exists for the machine that cannot carry it. What it must do is
-- switch shadows OFF rather than down: both halves of ShadowMap (can the pass
-- run, and is there a map to read) hang off the one gate, because the map
-- from the last frame is still in the canvas and a row that only stopped the
-- pass would leave every shadow frozen in the pose it was switched off in.
--
-- In an anonymous scope, like every section that wants more than a name or
-- two: this file is one chunk and a chunk has 200 local slots, which the
-- main function is already sitting on.
;(function()
local Shadows = run.loader.exports.DRAMATIC_SHAPE.lib.require("Shadows")
local ShadowMap = run.loader.exports.DRAMATIC_SHAPE.lib.require("ShadowMap")
local shadowRow = hookedRows["DRAMATIC_SHAPE:shadows"]
local shGame = { save = { options = {} }, mods = { modOptions = {} } }
T.eq(shadowRow.label, "SHADOWS", "the shadow row carries its label")
T.eq(shadowRow.value(), "ON",
  "and starts ON -- cast shadows are as much of the mode as the geometry, "
  .. "and the row is for the machine that cannot have them")
T.eq(Shadows.enabled(), true, "which is what the pass reads")
T.eq(ShadowMap.wanted(), true, "and the gate both halves of the sun pass ask")

shadowRow.step(shGame, 1)
T.eq(shadowRow.value(), "OFF", "stepping the row stands the sun pass down")
T.eq(shGame.save.options.modOptions.DRAMATIC_SHAPE.shadows, false,
  "the choice persists beside the other settings, not over them")
T.eq(Shadows.enabled(), false, "the pass sees it")
T.eq(ShadowMap.wanted(), false, "through the one gate")
T.eq(ShadowMap.available(), false,
  "so the sun pass never opens -- the frame's second draw of the world is "
  .. "the whole thing being saved")
T.eq(ShadowMap.active(), false,
  "and nothing reads the map either: a pass stopped WITHOUT this would leave "
  .. "the last frame's shadows standing forever")

shadowRow.step(shGame, 1)
T.eq(shadowRow.value(), "ON", "and the row is a toggle -- one step back on")
T.eq(ShadowMap.wanted(), true, "with the sun asked for again")
end)()

-- ------- the animated terrain atlas survives an engine without its seams
--
-- Regression: cycling palette modes with voxel mode on eventually killed
-- the pass outright --
--
--   render pipeline voxel failed: lib/TerrainAtlas.lua:192: attempt to
--   call field 'atlasImageData' (a nil value) -- disabled for this session
--
-- TerrainAtlas reads three OPTIONAL engine seams (README, "engine
-- internals"); this build ships only defaultAnimatedTiles, so animFrame and
-- atlasImageData are both absent. animFrame was already read guarded and
-- degrades to a frozen clock. atlasImageData was called straight, and only
-- on the branch where staticAtlas did NOT bake its own pixels -- which is
-- exactly what a palette change flips. Every mode whose world palette is
-- absent (pal() -> nil), plus RED++ (whose per-map bake sets gbcAtlas) and
-- any trueColor tileset, hands `baked = false` down to newEntry. So the
-- first map with animated water or flowers entered under one of those modes
-- took the whole pipeline down for the session.
--
-- The harness has no love.image at all, which is why the checks above never
-- reached this branch. Stand up just enough of one to walk it.

local TerrainAtlas = run.loader.exports.DRAMATIC_SHAPE.lib.require("TerrainAtlas")
local TileRenderer = require("src.render.TileRenderer")

local realImage, realNewImage = love.image, love.graphics.newImage

local function fakePixels(w, h)
  local d = { w = w or 128, h = h or 48 }
  function d:getDimensions() return self.w, self.h end
  function d:getPixel() return 0.5, 0.5, 0.5, 1 end
  function d:setPixel() end
  function d:paste() end
  return d
end

love.image = { newImageData = function(a, b)
  if type(a) == "number" then return fakePixels(a, b) end
  return fakePixels()          -- the "decoded from a path" overload
end }
-- animate() only uploads when the animation step actually turns over, so
-- counting replacePixels is how the suite sees the step move from outside.
-- builds counts entries made, and uploadFails forces the upload to throw.
local patches, builds, uploadFails = 0, 0, false
love.graphics.newImage = function()
  builds = builds + 1
  return { setFilter = function() end,
           replacePixels = function()
             if uploadFails then error("transient upload failure", 0) end
             patches = patches + 1
           end }
end

-- a tileset whose water tile rotates, i.e. one specsFor will accept
local function animatedMap(id, renderer)
  return {
    id = id,
    tileset = {
      -- a label, never opened: love.image is stubbed above
      image = "assets/tilesets/overworld.png",
      tilesPerRow = 16,
      animatedTiles = { { tile = 0x14, kind = "hshift",
                          offsets = { 0, 1, 2, 3 }, period = 20 } },
    },
    renderer = renderer,
  }
end

-- stands in for the atlas texture: what the engine hands over as
-- renderer.image, and what animate() patches through replacePixels
local base = { replacePixels = function() end,
               getDimensions = function() return 128, 48 end }

T.eq(TileRenderer.atlasImageData, nil,
  "this engine build does not carry the atlasImageData seam (the premise)")

-- 1. the crash itself: no bake of our own, and no engine seam to ask
TerrainAtlas.invalidate()
local plain = animatedMap("PLAIN", { image = base })
local ok, err = pcall(TerrainAtlas.animate, plain, nil, base, false)
T.check(ok, "an unbaked atlas does not take the pipeline down: " .. tostring(err))

-- 2. and it is a real recovery, not a shrug: the pixels behind an atlas the
--    engine never replaced are the tileset art, so the animation still runs
TerrainAtlas.invalidate()
local okArt, artImg = pcall(TerrainAtlas.animate, plain, nil, base, false)
T.check(okArt and artImg ~= nil,
  "unbaked terrain still animates, from the tileset art the atlas was built from")

-- 3. RED++ bakes per map and keeps no ImageData, so those pixels come back
--    off the texture. Where the driver will not read a canvas back -- which
--    is this harness, whose stub canvas has no newImageData -- the fallback
--    is to decline rather than patch grey art into a coloured atlas.
TerrainAtlas.invalidate()
local gbc = animatedMap("GBC", { image = base, gbcAtlas = true })
local okGbc, gbcImg = pcall(TerrainAtlas.animate, gbc, nil, base, false)
T.check(okGbc, "a RED++ atlas does not take the pipeline down either")
T.eq(gbcImg, nil, "and declines rather than patching raw art into a baked atlas")

-- 3b. give the harness a canvas it CAN read back and the same map animates,
--     with the pass's own render target put back afterwards -- this runs
--     mid-frame, so unbinding instead of restoring would cost the frame.
TerrainAtlas.invalidate()
local passCanvas = { name = "the pipeline's own target" }
love.graphics.setCanvas(passCanvas)
local realNewCanvas = love.graphics.newCanvas
love.graphics.newCanvas = function(w, h)
  return { w = w, h = h, setFilter = function() end,
           release = function() end,
           newImageData = function() return fakePixels(w, h) end }
end
local okRead, readImg = pcall(TerrainAtlas.animate, gbc, nil, base, false)
T.check(okRead and readImg ~= nil,
  "a RED++ atlas animates from a texture readback when the driver allows it")
T.eq(love.graphics.getCanvas(), passCanvas,
  "and the readback puts the pass's render target back")
love.graphics.newCanvas = realNewCanvas
love.graphics.setCanvas()

-- 3c. RED++ WITH the renderer's data in hand: the atlas is rebuilt on the
--     CPU from the raw art and the map's palette groups, so water animates
--     under RED++ without asking the driver for anything. This is the case
--     that was actually broken on hardware -- RED++ is the only mode where
--     staticAtlas declines to bake, so it was the only mode whose animated
--     tiles depended on a readback, and it stood still.
TerrainAtlas.invalidate()
local realNewCanvas2 = love.graphics.newCanvas
love.graphics.newCanvas = function() error("driver refuses canvas readback", 0) end
local redppMap = animatedMap("REDPP",
  { image = base, gbcAtlas = true, data = Data })
redppMap.id = "PALLET_TOWN"          -- a map the palette groups know about
redppMap.tileset.id = "OVERWORLD"
local PaletteFX = require("src.render.PaletteFX")
local modeWas = PaletteFX.mode
PaletteFX.mode = "redpp"
local okRedpp, redppImg = pcall(TerrainAtlas.animate, redppMap, nil, base, false)
T.check(okRedpp and redppImg ~= nil,
  "RED++ animates from a CPU rebuild, with no readback available at all")
PaletteFX.mode = modeWas
love.graphics.newCanvas = realNewCanvas2

-- 3d. A failure that might not repeat must not cost the animation for the
--     rest of the session. It used to: the key was condemned on the first
--     miss and nothing rebuilt it, so water stopped and stayed stopped.
TerrainAtlas.invalidate()
uploadFails = true
T.eq(TerrainAtlas.animate(plain, nil, base, false), nil,
  "a patch that throws declines the frame")
uploadFails = false
local okRetry, retryImg = pcall(TerrainAtlas.animate, plain, nil, base, false)
T.check(okRetry and retryImg ~= nil,
  "and the next frame rebuilds, rather than staying dead until a hot reload")

-- but a key that keeps failing is given up on, not rebuilt every frame
TerrainAtlas.invalidate()
uploadFails = true
for _ = 1, 6 do TerrainAtlas.animate(plain, nil, base, false) end
local settledBuilds = builds
for _ = 1, 6 do TerrainAtlas.animate(plain, nil, base, false) end
T.eq(builds, settledBuilds,
  "a key that fails repeatedly is condemned rather than rebuilt forever")
uploadFails = false
TerrainAtlas.invalidate()

-- 4. the reported path end to end: cycle every palette mode over a map with
--    animated tiles. PaletteFX.pal returns nil for a mode with no world
--    palette, which is the `colors = nil` that flips staticAtlas to no-bake.
local PaletteFX = require("src.render.PaletteFX")
local sgb = { { 1, 1, 1 }, { 0.6, 0.6, 0.6 }, { 0.3, 0.3, 0.3 }, { 0, 0, 0 } }
for _, mode in ipairs(PaletteFX.MODES) do
  for _, colors in ipairs({ sgb, false }) do   -- false stands in for nil
    TerrainAtlas.invalidate()
    local okMode = pcall(TerrainAtlas.forMap, animatedMap("M_" .. mode, { image = base }),
                         colors or nil)
    T.check(okMode, "palette mode " .. mode .. " survives a terrain atlas build"
                    .. (colors and " (with a world palette)" or " (with none)"))
  end
end

-- 5. forward compatible: a build that DOES carry the seam is preferred over
--    reading the art back off disk, and one that throws is still survivable
TerrainAtlas.invalidate()
local asked = false
TileRenderer.atlasImageData = function() asked = true; return fakePixels() end
local okSeam, seamImg = pcall(TerrainAtlas.animate, plain, nil, base, false)
T.check(okSeam and seamImg ~= nil,
  "an engine that provides the seam still animates")
T.check(asked, "and the engine's own accessor is what was asked")

TerrainAtlas.invalidate()
TileRenderer.atlasImageData = function() error("seam is angry") end
local okThrow = pcall(TerrainAtlas.animate, plain, nil, base, false)
T.check(okThrow, "a seam that throws costs the animation, not the pipeline")

TileRenderer.atlasImageData = nil

-- ------- the tile clock, the other half of the same seam problem
--
-- animFrame is the engine's 60Hz tile-animation counter and this build does
-- not export it either. It was read guarded, so it never crashed -- it just
-- answered 0 forever, which pinned every animated tile at step 0: water and
-- flowers stood still in voxel mode and nowhere else. It is a plain local in
-- TileRenderer, but an upvalue of the exported tick(), so the mod reads the
-- real counter rather than inventing one. That distinction is the point: the
-- flat tile layer draws from this same number, so a mode switch mid-cycle
-- continues the animation instead of restarting it.

local clock = TerrainAtlas._animFrame
T.check(type(clock) == "function", "the atlas exposes its clock for the suite")

T.eq(TileRenderer.animFrame, nil,
  "this engine build does not carry the animFrame seam either (the premise)")

local before = clock()
for _ = 1, 7 do TileRenderer.tick(nil) end
T.eq(clock() - before, 7, "the clock follows the engine's tick, rather than sitting at 0")
TileRenderer.tick(1 / 60)
T.eq(clock() - before, 8, "and a 60Hz frame of wall time advances it exactly one step")

-- End to end, and observed from OUTSIDE the clock: animate() re-uploads the
-- atlas only when the step turns over, so walking a full cycle has to
-- produce one upload per step. This is what a frozen clock silently
-- prevented -- it uploads once and then agrees with itself forever, which
-- is why reading the counter back here would prove nothing.
local spec = plain.tileset.animatedTiles[1]
TerrainAtlas.invalidate()
patches = 0
TerrainAtlas.animate(plain, nil, base, false)   -- builds, uploads step 0
local built = patches
for _ = 1, #spec.offsets do
  for _ = 1, spec.period do TileRenderer.tick(nil) end
  TerrainAtlas.animate(plain, nil, base, false)
end
T.eq(patches - built, #spec.offsets,
  "walking a full cycle re-patches the atlas once per step, rather than freezing at step 0")

-- repeat calls inside one step must NOT re-upload: animate() runs once per
-- map in the neighbourhood every frame, and repatching ~130 pixels each
-- time is the cost the step check exists to avoid
local settled = patches
for _ = 1, 5 do TerrainAtlas.animate(plain, nil, base, false) end
T.eq(patches, settled, "and holds still between steps rather than repatching every call")

-- and the same two guarantees the pixel seam gets: prefer the real thing,
-- survive a broken one
TileRenderer.animFrame = function() return 4242 end
T.eq(clock(), 4242, "an engine that exports the clock is preferred over the upvalue")
TileRenderer.animFrame = function() error("clock is angry") end
local okClock, clockVal = pcall(clock)
T.check(okClock and type(clockVal) == "number",
  "a clock that throws falls back to a working one rather than propagating")
TileRenderer.animFrame = nil

-- ------- the flower's slot carries an animated SILHOUETTE, not a tile
--
-- The flower tile stands in voxel mode as a billboard one voxel deep
-- (Structures.buildFlowers), cut to the drawing's darkest tones. Meshes
-- are static, so the geometry spans the union of every frame's dark
-- pixels and the animation lives in the atlas: patch() keys everything
-- lighter to alpha 0, the shader discards it, and the silhouette trims
-- itself frame by frame. Two halves to pin down: the CLASS is derived
-- (any frames-animated tile resolves `flower` with no profile entry),
-- and the PATCH writes alpha where the frame is not dark.

local TileShape = run.loader.exports.DRAMATIC_SHAPE.lib.require("TileShape")

local flowerSet = {
  id = "T_FLOWER_PIN", image = "assets/tilesets/stub.png",
  tilesPerRow = 16, imageWidth = 128, imageHeight = 48,
  animatedTiles = { { tile = 0x03, kind = "frames", period = 20,
                      images = { "stub_flowerframe.png" },
                      sequence = { 1 } } },
}
local flowerShapes = TileShape.forMap({ tileset = flowerSet })
T.eq(flowerShapes[0x03].class, "flower",
  "a frames-animated tile is pinned `flower` with no profile entry, like grass")
T.check(flowerShapes[0x03].flat,
  "the flower cell still counts as flat ground for its neighbours")
T.eq(flowerShapes[0x03].h, 0,
  "and carries no height, so a build with no pixel access degrades to the flat tile")
T.check(flowerShapes[0x03].authored,
  "the pin is authored-strength: cell walkability cannot re-file it as plain ground")

-- the patch, observed through a recording atlas copy: a crafted frame
-- whose dark pixels form a diamond ring around one light pixel -- the
-- billboard must keep the ring AND the pale pixel it encloses, and key
-- the reachable background (light or transparent) to alpha
local slotPx = {}
local sectionNewImageData = love.image.newImageData
do
  local crafted = fakePixels()
  local ring = { ["1,0"] = true, ["0,1"] = true,
                 ["2,1"] = true, ["1,2"] = true }
  local frame = fakePixels()
  function frame:getPixel(x, y)
    if ring[x .. "," .. y] then return 0.3, 0.3, 0.3, 1 end -- dark outline
    if x == 7 and y == 0 then return 0.9, 0.9, 0.9, 0 end   -- transparent
    return 1, 1, 1, 1                       -- light: petal inside at (1,1),
  end                                       -- background everywhere else
  love.image.newImageData = function(a, b)
    if type(a) == "number" then
      local d = fakePixels(a, b)
      function d:setPixel(x, y, r, g, b2, al)
        slotPx[x .. "," .. y] = { r, g, b2, al }
      end
      return d
    end
    if tostring(a):find("flowerframe") then return frame end
    return crafted
  end
end

TerrainAtlas.invalidate()
local fmap = {
  id = "T_FLOWER_PATCH_MAP",
  tileset = {
    id = "T_FLOWER_PATCH", image = "assets/tilesets/stub2.png",
    tilesPerRow = 16, imageWidth = 128, imageHeight = 48,
    animatedTiles = { { tile = 0x03, kind = "frames", period = 20,
                        images = { "stub_flowerframe.png" },
                        sequence = { 1 } } },
  },
  renderer = { image = base },
}
local okFlower, flowerImg = pcall(TerrainAtlas.animate, fmap, nil, base, false)
T.check(okFlower and flowerImg ~= nil,
  "a flower map animates: " .. tostring(flowerImg))

local fdx = (0x03 % 16) * 8
local function slotAlpha(x, y)
  local p = slotPx[(fdx + x) .. "," .. y]
  return p and p[4]
end
T.eq(slotAlpha(1, 0), 1,
  "a dark frame pixel lands opaque -- it is the standing cutout")
T.eq(slotAlpha(1, 1), 1,
  "and so does the pale pixel the outline encloses -- the petal's inside "
  .. "rides the billboard, not just its outline")
T.eq(slotAlpha(5, 5), 0,
  "a background pixel is keyed to alpha, so the billboard's shader discards it")
T.eq(slotAlpha(7, 0), 0,
  "a transparent frame pixel stays clear rather than painting black")

love.image.newImageData = sectionNewImageData

TerrainAtlas.invalidate()
love.image, love.graphics.newImage = realImage, realNewImage

-- ------- a palette switch must not drop the geometry
--
-- Regression: toggling palettes in voxel mode flashed the flat 2D world for
-- a moment on every switch.
--
-- PaletteFX.setMode reloads the live map to rebuild its atlas, passing
-- reason "colors", and this mod dropped the map's terrain mesh on any
-- map.reloaded at all. Mesh builds are asynchronous, so the frames between
-- the drop and the first rebuilt mesh have no terrain -- and a voxel
-- drawWorld with no terrain returns nil, which IS the engine's 2D
-- fallback. The geometry was never stale to begin with: the mesher reads
-- block layout and tile ids, and the palette lives in the texture.
--
-- Every OTHER reload still has to drop it, so this pins the distinction
-- rather than just the fix.

local ChunkMesher = run.loader.exports.DRAMATIC_SHAPE.lib.require("ChunkMesher")
local Runtime = require("src.mods.Runtime")

local realInvalidate = ChunkMesher.invalidate
local realRefresh = ChunkMesher.refresh
local dropped, refreshed = {}, {}
ChunkMesher.invalidate = function(id) dropped[#dropped + 1] = id or "<every map>" end
ChunkMesher.refresh = function(id) refreshed[#refreshed + 1] = id or "<every map>" end

Runtime.emit("map.reloaded", { mapId = "PALLET_TOWN", reason = "colors" })
T.eq(#dropped, 0,
  "a palette switch keeps the terrain mesh, so the diorama stays on screen")

Runtime.emit("map.reloaded", { mapId = "PALLET_TOWN", reason = "invalidate" })
T.eq(#dropped, 1, "a reload for any other reason still drops the stale mesh")
T.eq(dropped[1], "PALLET_TOWN", "and drops exactly the map that reloaded")

-- the reason field is the engine's, not ours: a payload without one is a
-- real reload and must still invalidate
Runtime.emit("map.reloaded", { mapId = "VIRIDIAN_CITY" })
T.eq(#dropped, 2, "a reload with no stated reason is treated as a real one")

-- a block edit (Cut, a door stamp, the tree regrowing on re-entry) is a
-- REFRESH, not a drop: the stale mesh keeps drawing while the rebuild
-- cooks, so the scene never blinks down to the flat 2D path
Runtime.emit("world.block_replaced", { mapId = "PALLET_TOWN" })
T.eq(#dropped, 2, "a replaced block does not drop the mesh outright")
T.eq(#refreshed, 1, "it refreshes the mesh in place instead")
T.eq(refreshed[1], "PALLET_TOWN", "and refreshes exactly the edited map")

-- ------- and the edits the engine does NOT announce
--
-- Cut swaps its tree block, the regrowth restores it on re-entry, and the
-- card-key doors are stamped on floor load -- all writing the block layer
-- directly, none of them emitting world.block_replaced. The mod wraps
-- Map:setBlock rather than asking the engine to announce each one (an
-- earlier cut changed the engine, which is the wrong place: it edits the
-- game for one mod, and every future block write has to remember).
--
-- These run through a REAL Map, so they also pin that the wrap survives
-- whatever the engine does to that method.

local Map = require("src.world.Map")
local function fakeMap(id)
  return setmetatable({
    id = id,
    def = { width = 2, height = 2, blocks = { 1, 1, 1, 1 }, borderBlock = 0 },
  }, Map)
end

local m = fakeMap("ROUTE_2")
refreshed = {}

m:setBlock(0, 0, 9)
T.eq(#refreshed, 1, "a direct setBlock refreshes the mesh -- this is Cut's path")
T.eq(refreshed[1], "ROUTE_2", "and names the map that was edited")
T.eq(m:blockAt(0, 0), 9, "and the block really changed")

-- the regrowth rewrites every block it recorded, changed or not; a write
-- that changes nothing must not throw the mesh away
m:setBlock(0, 0, 9)
T.eq(#refreshed, 1, "rewriting a block with the value it already held is not an edit")

-- setBlock silently ignores an out-of-bounds write, so there is nothing
-- to rebuild for one
m:setBlock(99, 99, 3)
T.eq(#refreshed, 1, "an out-of-bounds write refreshes nothing")

ChunkMesher.invalidate = realInvalidate
ChunkMesher.refresh = realRefresh

-- ------- the non-colour palette modes must not come through as SGB
--
-- Regression: GRAY, INVERTED and CLASSIC all rendered as the SGB palette in
-- voxel mode -- grey and inverted came out blue.
--
-- The engine's paletteFor hands back a map's RAW SGB zone palette. The flat
-- path then runs it through PaletteFX.effectiveColors on the way to the
-- shade-remap shader, and THAT is where the non-colour modes happen: OG and
-- OG INV swap in the DMG greys, CLASSIC swaps in the green set, GBC INV
-- permutes the zone's own shades. This pass bakes colour into the atlas
-- ahead of the draw instead of shading at blit time, so it never reached
-- that call and every mode drew the raw zone palette.
--
-- Asserted against what each mode should PAINT, not against the engine
-- function, so this stays a claim about the picture rather than a
-- restatement of the implementation.

local VoxelScene = run.loader.exports.DRAMATIC_SHAPE.lib.require("VoxelScene")
local modeColors = VoxelScene._modeColors
T.check(type(modeColors) == "function", "the scene exposes its palette resolve")

-- a recognisable stand-in for a map's SGB zone palette: strongly blue, so
-- "came through as SGB" is visible in the values themselves
local sgbBlue = { { 248, 248, 248 }, { 96, 152, 232 },
                  { 40, 80, 176 }, { 8, 24, 64 } }
local function paletteForBlue() return sgbBlue end
local function under(mode, fn)
  local prev = PaletteFX.mode
  PaletteFX.mode = mode
  local ok, err = pcall(fn)
  PaletteFX.mode = prev
  if not ok then error(err, 0) end
end

local function sameColors(a, b)
  if not (a and b) then return false end
  for i = 1, 4 do
    for ch = 1, 3 do
      if a[i][ch] ~= b[i][ch] then return false end
    end
  end
  return true
end

under("gbc", function()
  T.check(sameColors(modeColors(paletteForBlue), sgbBlue),
    "GBC is a colour mode, so the zone palette passes through untouched")
end)

under("og", function()
  local c = modeColors(paletteForBlue)
  T.check(sameColors(c, PaletteFX.GRAYS),
    "GRAY paints the DMG greys, not the map's SGB blue")
  T.check(not sameColors(c, sgbBlue), "and is not the SGB palette in disguise")
end)

under("og_inv", function()
  local c = modeColors(paletteForBlue)
  T.check(sameColors(c, PaletteFX.permute(PaletteFX.GRAYS,
                                          { [0] = 3, [1] = 2, [2] = 1, [3] = 0 })),
    "GRAY INV paints the greys with the shade ramp reversed")
  T.eq(c[1][1], PaletteFX.GRAYS[4][1],
    "so the lightest shade becomes the darkest -- an actual inversion")
end)

under("classic", function()
  T.check(sameColors(modeColors(paletteForBlue), PaletteFX.CLASSIC),
    "CLASSIC paints the green DMG set")
end)

under("gbc_inv", function()
  local c = modeColors(paletteForBlue)
  T.check(not sameColors(c, sgbBlue), "GBC INV does not pass the zone palette through")
  for i = 1, 4 do
    T.check(sameColors({ c[i], c[i], c[i], c[i] },
                       { sgbBlue[5 - i], sgbBlue[5 - i], sgbBlue[5 - i], sgbBlue[5 - i] }),
      "GBC INV reverses the zone's own shades, keeping its colours (shade " .. i .. ")")
  end
end)

-- a map with no palette at all stays uncoloured rather than inventing one,
-- which is what the flat path does when it has nothing to send the shader
T.eq(modeColors(function() return nil end), nil,
  "a map with no world palette bakes no colour, as on the flat path")
T.eq(modeColors(nil), nil, "and a pipeline given no paletteFor at all is safe")

-- ------- the hotkeys this mod claims
--
--   3  VOXEL    cycle the camera ladder
--   5  V-GRID   toggle the wireframe
--   6  T-SHIFT  cycle the blur ladder
--   7  V-CURVE  cycle the horizon bend
--   8  3D-BTL   toggle overworld battles
--
-- Only 6 reaches the pipeline registry the documented way. Game:keypressed
-- answers the engine's own display keys first and returns -- 3 is TILT and
-- 5 is GBC FX -- expressly so a pipeline cannot shadow one, and 7 and 8
-- belong to settings that own no pass and so have no registry to claim
-- from. The mod therefore wraps Game:keypressed, and these pin what that
-- wrapper is allowed to take.

local Game = require("src.core.Game")
Pipelines.reset()
Pipelines.setLevel("voxel", 0)
Pipelines.setLevel("tiltshift", 0)

-- a free-roam game: Zoom.gateOK wants the top screen to BE the overworld,
-- not transitioning and not running a script
local keyGame
local overworld = { transitioning = false }
keyGame = {
  overworld = overworld,
  stack = { top = function() return overworld end },
  save = { options = { modOptions = {} } },
  mods = { modOptions = {} },
  writeOptions = function() end,
}

local VoxelGrid = run.loader.exports.DRAMATIC_SHAPE.lib.require("VoxelGrid")
local Curve = run.loader.exports.DRAMATIC_SHAPE.lib.require("WorldCurve")

-- ------- 3 walks the ANGLE rungs and steps over FULL
--
-- The key is a display-mode cycler: it should change the camera and nothing
-- else. FULL reaches in and rewrites four other settings, so landing on it
-- mid-walk would silently turn the blur to maximum and flatten the horizon
-- with nothing on screen saying a keypress had done it.
Pipelines.setLevel("voxel", 0)
local walk = {}
for _ = 1, 8 do
  Game.keypressed(keyGame, "3")
  walk[#walk + 1] = Pipelines.levelLabel("voxel")
end
T.eq(table.concat(walk, ","),
  "15,35,50,75,1ST (EXPERIMENTAL),3RD (EXPERIMENTAL),OFF,15",
  "3 walks OFF -> 15 -> 35 -> 50 -> 75 -> 1ST -> 3RD and wraps, never "
  .. "touching FULL")

-- FULL is 35 degrees, so a press from it goes ON to 50 rather than back to
-- the rung that shows the same camera -- the key never appears to do nothing.
-- Matched by angle, so this follows FULL if it is ever retuned.
T.eq(VoxelState.ANGLES_DEG[VoxelState.FULL_LEVEL + 1], 35,
  "FULL is the 35-degree camera")
Pipelines.setLevel("voxel", VoxelState.FULL_LEVEL)
Game.keypressed(keyGame, "3")
T.eq(Pipelines.levelLabel("voxel"), "50",
  "a press from FULL goes to 50, since FULL already IS the 35 camera")

Pipelines.setLevel("voxel", 0)
Game.keypressed(keyGame, "3")
T.eq(Pipelines.level("voxel"), 2, "3 cycles the voxel camera ladder")
Game.keypressed(keyGame, "3")
T.eq(Pipelines.level("voxel"), 3, "and keeps climbing it")

Game.keypressed(keyGame, "6")
T.eq(Pipelines.level("tiltshift"), 1, "6 cycles the tilt-shift blur")

Game.keypressed(keyGame, "5")
T.eq(VoxelGrid.setting:get(), true, "5 toggles V-GRID on")
Game.keypressed(keyGame, "5")
T.eq(VoxelGrid.setting:get(), false, "and off again")

local curveBefore = Curve.setting:get()
Game.keypressed(keyGame, "7")
T.neq(Curve.setting:get(), curveBefore, "7 cycles V-CURVE")

local Battles = run.loader.exports.DRAMATIC_SHAPE.lib.require("OverworldBattle")

-- The two STADIUM rungs are gated on the models being installed, and they are
-- not installed anywhere this suite runs: the repository carries no Pokemon
-- Stadium data, so a clean clone has none and a developer checkout has them
-- only after tools/stadium_pack.py has been run. What the walk below is about
-- is the LADDER -- five rungs, in order, wrapping -- so the gate is held OPEN
-- for it and the skipping behaviour is tested on its own further down, where
-- it is the subject rather than an accident of the machine it ran on.
--
-- Held in GLOBALS rather than locals, here and for the pack probe below: this
-- chunk is at Lua's 200-local ceiling and three more would not compile.
BATTLE_ROW_GATE = Battles.setting.gate
Battles.setting:setGate(function() return true end)

T.eq(Battles.setting:get(), true, "3D-BTL starts on 2D-3D A")
T.eq(Battles.discs(), false, "which stages the fight on the map")
Game.keypressed(keyGame, "8")
T.eq(Battles.setting:get(), "flatB",
  "8 steps to 2D-3D B -- the same pics, on the discs")
T.eq(Battles.discs(), true,
  "and that IS a disc rung, with no Stadium model anywhere in it")
Game.keypressed(keyGame, "8")
T.eq(Battles.setting:get(), "stadium",
  "again and it is STADIUM A, the models on the map")
T.eq(Battles.discs(), false, "back on the map")
Game.keypressed(keyGame, "8")
T.eq(Battles.setting:get(), "stadiumB",
  "again and it is STADIUM B, the models on the discs")
T.eq(Battles.discs(), true, "on the discs again")
Game.keypressed(keyGame, "8")
T.eq(Battles.setting:get(), false, "again and overworld battles are off")
Game.keypressed(keyGame, "8")
T.eq(Battles.setting:get(), true, "and the ladder wraps back to 2D-3D A")

Battles.setting:setGate(BATTLE_ROW_GATE)

-- ------- importing a ROM instead of being told where to put one
--
-- The row is an ACTION, not a setting: it has no stored rung, so it is not in
-- SETTINGS and the mod manager's page does not carry it. What it shows is a
-- state, and what it does is open the host's file dialog -- which is why it
-- is absent where no dialog can be opened rather than being offered as a
-- button that does nothing.
;(function()
  local Pick = run.loader.exports.DRAMATIC_SHAPE.lib.require("StadiumRomPick")
  local Install =
    run.loader.exports.DRAMATIC_SHAPE.lib.require("StadiumInstall")

  T.check(type(Pick.canDialog()) == "boolean",
    "the picker reports whether this platform has a file dialog at all")

  -- The row is offered on EVERY platform. It used to be dropped where no
  -- dialog could be opened, which on Android read as the feature being
  -- missing rather than manual -- and the folder path it needed to show was
  -- only ever written to a console a phone does not have.
  local row = Pick.row()
  T.check(row ~= nil, "the row is offered whatever the platform can do")
  T.eq(row.label, "STADIUM ROM", "and says what it is for")
  T.check(type(row.step) == "function", "and does something when pressed")
  T.eq(row.value(),
    Install.available() and "READY" or (Pick.canDialog() and "IMPORT" or "WHERE?"),
    "reading READY once installed, IMPORT where a dialog can be opened, and "
    .. "WHERE? where pressing it can only name the folder -- a row that said "
    .. "IMPORT and then did not import would be the worse lie")

  -- and the drop folder it would name is an absolute path, which the note
  -- screen has to be able to show in full
  T.check(type(Install.romHint()) == "string" and #Install.romHint() > 0,
    "there is a folder to name")

  -- A ROM that carries no models must be refused BEFORE anything is written.
  -- An empty build otherwise completes with nothing attempted and therefore
  -- nothing failed, and the marker gets written saying so -- which on a
  -- machine that already had a set would uninstall it, because the marker is
  -- the only thing that makes 151 files on disk count as installed.
  T.eq(Install.beginFrom("", "empty"), false,
    "an empty file is refused outright")
  T.eq(select(2, Install.beginFrom(("\0"):rep(4096), "zeros")) ~= nil, true,
    "and so is a file that is not a ROM, with a reason")
  T.eq(Install.status.state ~= "building", true,
    "and neither of those started a build")
end)()

-- ------- the model set, when there is one
--
-- Everything below that loads a .dsm needs a BUILT set, and the repository
-- deliberately carries none: the models are Pokemon Stadium's data, built out
-- of the player's own ROM at runtime (StadiumInstall) or by
-- tools/stadium_pack.py into assets/stadium/ in a developer checkout. So a
-- clean clone has nothing to read, and these say so and stand down rather
-- than failing for the absence of data that is absent on purpose.
--
-- Announced rather than silent. A test that quietly evaporates when its
-- fixture is missing is a test that has stopped running and not told anyone,
-- which is worse than one that fails.
HAVE_STADIUM_PACKS =
  run.loader.exports.DRAMATIC_SHAPE.lib.require("StadiumPack").available(25)
if not HAVE_STADIUM_PACKS then
  print("SKIP stadium model tests -- no built .dsm set (run "
        .. "tools/stadium_pack.py, or play once with a ROM in baseroms/)")
end

-- ------- the eyes blink once a loop, not six times a second
--
-- A texture animation is sampled at the SKELETAL animation's frame and HOLDS
-- its last entry past the end of its own stream, which is what the game's own
-- sampler does. Wrapping on the stream's length instead plays it over and
-- over: Rattata's standby loop is 40 frames and its blink is 5, so that came
-- out as six blinks a second.
--
-- Driven through a stub rather than a real rig, because building one needs
-- meshes and there is no graphics context here -- and the rule under test is
-- pure index arithmetic that does not care.
;(function()
  local Rig = run.loader.exports.DRAMATIC_SHAPE.lib.require("StadiumRig")
  -- one prim on channel 0, whose stream values 6/7/8 map to textures 60/70/80
  local prim = { tex = 1, texAnim = 0, texMap = { [6] = 60, [7] = 70,
                                                  [8] = 80 } }
  local model = {
    prims = { prim },
    textures = { [1] = { w = 1, h = 1 }, [60] = { w = 1, h = 1 },
                 [70] = { w = 1, h = 1 }, [80] = { w = 1, h = 1 } },
    -- Rattata's actual blink: open, half, closed, half, open
    auxAnims = { { frames = 5, loopStart = 0, channels = { { 6, 8, 7, 8, 6 } } } },
  }
  local part = { prim = prim }
  local stub = setmetatable({ model = model, parts = { part } }, Rig)

  -- StadiumPack.image wants a real texture; what is asserted here is WHICH
  -- index was chosen, so record it instead
  local Pack = run.loader.exports.DRAMATIC_SHAPE.lib.require("StadiumPack")
  local realImage = Pack.image
  local picked
  Pack.image = function(_, index) picked = index return nil end

  local function at(frame)
    stub.frameAt = frame
    stub:textures(1)
    return picked
  end

  T.eq(at(0), 60, "frame 0 of the blink is the open eye")
  T.eq(at(1), 80, "frame 1 is half closed")
  T.eq(at(2), 70, "frame 2 is shut")
  T.eq(at(4), 60, "and frame 4 is open again -- one blink, five frames")
  -- the whole point: frames 5..39 of the forty-frame idle are NOT a second
  -- blink, they are the eye staying open
  T.eq(at(5), 60, "frame 5, past the end of the blink, HOLDS the open eye")
  T.eq(at(20), 60, "and so does frame 20")
  T.eq(at(39), 60, "and frame 39, the last of the idle loop")

  Pack.image = realImage
end)()

-- ------- the skeleton runs at 60, the textures step at 30
--
-- The animation streams carry one value per frame at 30 Hz, so replayed
-- honestly against a 60 Hz camera every pose holds for two frames and the
-- models visibly stutter against everything around them. StadiumRig blends
-- between consecutive frames instead -- but NOT across a snap, because these
-- are Euler triples and two triples that describe nearly the same rotation
-- can be nowhere near each other component by component. Walking from one to
-- the other is a bone flipping over inside a frame, which is exactly the
-- glitch a naive version of this shipped with.
--
-- Driven on a REAL species, through a rig with no meshes (there is no
-- graphics context here, and pose() only touches the matrix arrays).
;(function()
  if not HAVE_STADIUM_PACKS then return end
  local lib = run.loader.exports.DRAMATIC_SHAPE.lib
  local Pack, Rig = lib.require("StadiumPack"), lib.require("StadiumRig")
  local model = Pack.load(25)                     -- Pikachu
  local rig = setmetatable({ model = model, pivotM = {}, drawM = {},
                             accX = {}, accY = {}, accZ = {}, parts = {} }, Rig)
  local slot = model.ctx[Pack.SLOT.idle]
  local anim = (slot ~= Pack.NONE) and (slot + 1) or nil
  local frames = anim and model.anims[anim].frames or 0

  -- every bone's world origin under the pose as it stands
  local function origins()
    local out = {}
    for b = 1, model.boneCount do
      local o = (b - 1) * 12
      out[b] = { rig.drawM[o + 4], rig.drawM[o + 8], rig.drawM[o + 12] }
    end
    return out
  end

  T.check(frames > 8, "Pikachu's standby loop is long enough to sample")

  rig:pose(anim, 3, true)
  local a = origins()
  rig:pose(anim, 4, true)
  local c = origins()
  rig:pose(anim, 3.5, true)
  local b = origins()

  T.eq(rig.frameAt, 3,
    "half a frame in, the TEXTURE frame is still the whole one -- an eye is "
    .. "open or it is shut and there is no halfway swap to draw")

  -- the bone that travels furthest between those two frames is the one with
  -- something to say about the blend
  local best, moved = nil, 0
  for i = 1, #a do
    local d = ((c[i][1] - a[i][1]) ^ 2 + (c[i][2] - a[i][2]) ^ 2
               + (c[i][3] - a[i][3]) ^ 2) ^ 0.5
    if d > moved then best, moved = i, d end
  end
  T.check(moved > 0, "and some bone actually moves between frames 3 and 4")

  -- halfway is HALFWAY: within a twentieth of the step of the midpoint of the
  -- two frames it sits between, on every axis. A blend that overshoots, or
  -- that walks the long way round a wrapped angle, fails this by miles.
  local slack = moved / 20
  for axis = 1, 3 do
    local mid = (a[best][axis] + c[best][axis]) / 2
    T.check(math.abs(b[best][axis] - mid) <= slack,
      ("the half-frame pose sits between its two frames on axis %d"):format(axis))
  end

  -- and a whole frame is the frame itself, untouched: the blend has to be
  -- exactly nothing at k = 0, or every stepped caller (the blink probe, the
  -- oracle diff) is reading a pose the pack does not contain
  rig:pose(anim, 4, true)
  local again = origins()
  T.eq(again[best][1], c[best][1],
    "and a whole frame is that frame exactly, with nothing blended into it")
end)()

-- ------- growing out of the ball
--
-- The engine sizes its flat pic in the Game Boy's three steps across the
-- twelve frames AFTER the ball has finished opening. The model runs its own
-- ramp instead, started when the poof begins: continuous, and overlapping the
-- ball rather than following it.
;(function()
  if not HAVE_STADIUM_PACKS then return end
  local lib = run.loader.exports.DRAMATIC_SHAPE.lib
  local Mon = lib.require("StadiumMon")

  local mon = Mon.new("player")
  T.eq(mon:growScale(), 1, "a Pokemon that is not arriving is full size")
  T.eq(mon:beginGrow(), false,
    "and one with no model cannot start growing -- there is nothing to size")

  mon.model = { height = 10, rootScale = 1 }
  T.eq(mon:beginGrow(), true, "with a model, the arrival starts")
  T.eq(mon:growScale(), 0, "from nothing at all")
  T.eq(mon:beginGrow(), false,
    "and starting again is refused -- the engine's own send-out seam fires a "
    .. "third of a second later and must not restart the ramp")

  -- the curve: slow, then quick through the middle, then settling
  local last, monotonic = -1, true
  for i = 0, 10 do
    mon.grow = i / 10
    local s = mon:growScale()
    if s < last then monotonic = false end
    last = s
  end
  T.check(monotonic, "the ramp never goes backwards")
  mon.grow = 0.5
  T.eq(mon:growScale(), 0.5, "and is half size exactly half way through")
  mon.grow = 0.25
  T.check(mon:growScale() < 0.25,
    "slower than linear early, so the Pokemon is still small while the ball "
    .. "is coming apart")

  -- and it ends, rather than sticking at 0.99
  mon.grow = nil
  mon.dt = 0
  mon:beginGrow()
  for _ = 1, 200 do mon:update(1 / 60) end
  T.eq(mon.grow, nil, "the ramp finishes")
  T.eq(mon:growScale(), 1, "at exactly full size")
  T.eq(mon.grewOwn, true,
    "and remembers it owned this arrival, so the engine's three-step ramp is "
    .. "not consulted for it afterwards -- it reads 5/7 in the gap and shrank "
    .. "the Pokemon back down at the very end of the grow")
end)()

-- ------- the pack cache must not evict a Pokemon that is standing there
--
-- The eviction order is keyed on LOADS, and a side only loads when its
-- species changes -- so a Pokemon that has been out for a few turns is the
-- least recently loaded thing in the cache. A fifth species entering the
-- battle evicted it and RELEASED ITS TEXTURES mid-fight, and the next draw
-- threw "Cannot use object after it has been released" from inside the scene
-- pass, which took both models off the screen for the rest of the battle.
;(function()
  if not HAVE_STADIUM_PACKS then return end
  local Pack = run.loader.exports.DRAMATIC_SHAPE.lib.require("StadiumPack")
  local keep = Pack.KEEP
  Pack.forget()
  Pack.KEEP = 2

  local held = Pack.load(1)
  T.check(held ~= nil, "a model loads")
  local slot = held.textures and held.textures[1]
  T.check(slot ~= nil, "and carries at least one texture slot")

  -- more species than the cache holds, WITHOUT saying the first is in use
  Pack.load(4) Pack.load(7) Pack.load(10)
  T.eq(slot.image, nil,
    "an evicted model's texture slot is CLEARED, not left holding a released "
    .. "object -- a released Image is still truthy, so the corpse came back "
    .. "out of image() and died at mesh:setTexture")

  -- and with `keep` said every frame, as the mode does, it is never evicted
  Pack.forget()
  local live = Pack.load(1)
  for _, dex in ipairs({ 4, 7, 10, 13 }) do
    Pack.keep(1)
    Pack.load(dex)
  end
  T.eq(Pack.load(1), live,
    "a species the mode keeps saying is on the field is still the same "
    .. "cached model after four others have loaded past it")

  Pack.KEEP = keep
  Pack.forget()
end)()

-- ------- and an animation must not walk the Pokemon out of the shot
--
-- Stadium's animations were authored for a camera that followed the Pokemon;
-- this one holds two fixed cells. 65 of the 148 send-out entrances travel
-- more than a body-height off the spot, up to seven and a half -- which is
-- not drama here, it is an empty tile.
;(function()
  if not HAVE_STADIUM_PACKS then return end
  local lib = run.loader.exports.DRAMATIC_SHAPE.lib
  local Pack, Rig, Mon = lib.require("StadiumPack"), lib.require("StadiumRig"),
                         lib.require("StadiumMon")
  local model = Pack.load(87)                    -- Dewgong, the worst of them
  local rig = setmetatable({ model = model, pivotM = {}, drawM = {},
                             accX = {}, accY = {}, accZ = {}, parts = {} }, Rig)
  rig:measureBind()

  -- the same quantity StadiumRig.anchor corrects -- bone origins averaged and
  -- weighted by the vertices each bone moves -- written out here rather than
  -- called, so this checks the behaviour and not its own arithmetic
  local weight, total = {}, 0
  for b = 1, model.boneCount do weight[b] = 0 end
  for _, prim in ipairs(model.prims) do
    for k = 1, prim.vertCount do
      local b = prim.bone[k]
      if weight[b] then weight[b] = weight[b] + 1; total = total + 1 end
    end
  end
  local function centre()
    local x, y, z = 0, 0, 0
    for b = 1, model.boneCount do
      local q = weight[b]
      if q > 0 then
        local o = (b - 1) * 12
        x = x + rig.drawM[o + 4] * q
        y = y + rig.drawM[o + 8] * q
        z = z + rig.drawM[o + 12] * q
      end
    end
    return x / total, y / total, z / total
  end
  local raw = model.height / (model.rootScale > 0 and model.rootScale or 1)
  local slot = model.ctx[Pack.SLOT.entrance]
  local anim = slot + 1

  local function driftAt(frame, limit)
    rig:pose(anim, frame, false)
    rig:anchor(limit)
    local x, y, z = centre()
    return (((x - model.bindCX) ^ 2 + (y - model.bindCY) ^ 2
             + (z - model.bindCZ) ^ 2) ^ 0.5) / raw
  end

  T.check(driftAt(40, nil) > 5,
    "unanchored, Dewgong's entrance carries it more than five body-heights "
    .. "off its tile -- straight out of a frame that holds about one")
  T.check(driftAt(40, Mon.TRAVEL) <= Mon.TRAVEL * 1.001,
    "anchored, it stays inside the travel limit")
  -- and the animations that never travel are left completely alone
  local before = driftAt(0, nil)
  T.eq(driftAt(0, Mon.TRAVEL), before,
    "a frame already inside the limit is not moved at all -- the anchor takes "
    .. "out the EXCESS, so a lunge is still a lunge")
end)()

-- ------- the three species the extraction cannot read stand as PICS
--
-- Exeggutor, Tangela and Magmar come out of the ROM with standby loops that
-- throw bones off the body; the packer measures that and flags them. They
-- used to hold their bind pose for the whole fight, which among a hundred and
-- forty-eight species that breathe reads as broken rather than as still. So
-- they decline the model outright and the Game Boy's own battle pic stands
-- instead -- the same fallback a species with no pack at all takes.
;(function()
  if not HAVE_STADIUM_PACKS then return end
  local lib = run.loader.exports.DRAMATIC_SHAPE.lib
  local Mon = lib.require("StadiumMon")
  for _, dex in ipairs({ 103, 114, 126 }) do
    local mon = Mon.new("enemy")
    T.eq(mon:setSpecies(dex), false,
      ("dex %d has corrupt animation data, so no model stands for it")
      :format(dex))
    T.eq(mon.rig, nil, "and there is no rig left behind to draw")
  end
end)()

-- ------- the collapse waits for the HP bar
--
-- onFaint fires the moment HP reaches zero, but the engine queues the visible
-- collapse behind the move animation and the bar drain -- seconds later. The
-- model has to wait for the same thing, or a Pokemon lies down while its own
-- health is still draining above it. `shownHP` is the engine's own bar
-- position, so this is the bar and not a guess at how long it takes.
;(function()
  local Stad = run.loader.exports.DRAMATIC_SHAPE.lib.require("Stadium")
  local ready, due = Stad._faintReady, Stad._faintStillDue

  T.eq(ready({ shownHP = 19, mon = { hp = 0 } }), false,
    "a battler at 0 HP whose bar still reads 19 is NOT ready to collapse")
  T.eq(ready({ shownHP = 1, mon = { hp = 0 } }), false,
    "nor at one point left on the bar")
  T.eq(ready({ shownHP = 0, mon = { hp = 0 } }), true,
    "and is the moment the bar reaches zero")
  T.eq(ready({ mon = { hp = 0 } }), true,
    "a battler with no bar to drain collapses at once, rather than never")
  T.eq(ready(nil), false, "and a battler that is gone is not ready")

  T.eq(due({ faintQueued = true, mon = { hp = 0 } }), true,
    "a queued faint at 0 HP is still owed")
  T.eq(due({ faintQueued = true, mon = { hp = 12 } }), false,
    "one that has been healed since is not -- the debt is dropped, not paid "
    .. "late at whoever is standing there")
  T.eq(due({ mon = { hp = 0 } }), false, "and an unqueued battler owes nothing")
end)()

-- ------- and it gets to FINISH
--
-- The engine takes a fainted pic off the field when its slide ends, which is
-- fourteen frames of a 60 Hz clock -- under a quarter of a second. The
-- shortest faint animation in the Stadium set is 49 frames of a 30 Hz one,
-- the median 110 and the longest 230, so held to the pic's window every model
-- was cut off inside the first fifth of its own collapse. It now stays until
-- the animation is done, and not one frame past that.
;(function()
  local Stad = run.loader.exports.DRAMATIC_SHAPE.lib.require("Stadium")
  local onField = Stad._onField

  -- the engine's own guards, mirrored in the shape onField reads them
  local battle = { fxHidden = function() return false end,
                   fxFaintActive = function(_, b) return b.sliding end }
  local function mon(state, done)
    return { state = state, finished = function() return done end }
  end

  battle.enemy = { sprite = true }
  T.eq(onField(battle, "enemy", mon("idle", false)), true,
    "a Pokemon that is standing there is on the field")

  battle.enemy = { sprite = true, fainted = true, sliding = true }
  T.eq(onField(battle, "enemy", mon("faint", false)), true,
    "and one whose pic is still sliding is too, as it always was")

  battle.enemy = { sprite = true, fainted = true, sliding = false }
  T.eq(onField(battle, "enemy", mon("faint", false)), true,
    "the pic has gone but the model has not finished falling -- it STAYS, "
    .. "which is the whole of the fix: a quarter-second window was cutting "
    .. "off animations that run for one to eight seconds")
  T.eq(onField(battle, "enemy", mon("faint", true)), false,
    "and the frame its collapse finishes, it goes -- nothing is left lying "
    .. "on the field for the rest of the fight")
  T.eq(onField(battle, "enemy", mon("idle", false)), false,
    "a fainted battler whose model never got as far as the faint goes with "
    .. "the pic, exactly as before")
  T.eq(onField(battle, "enemy", nil), false,
    "and a side with no model at all is not held open by this")

  -- ------- FLY and DIG take it off the field entirely
  --
  -- The charge turn runs a 19-24 frame slide and ends by setting
  -- `picFx[battler].hidden`; the release turn clears it. That field is the
  -- engine's whole answer to "is this Pokemon on screen", and it is NOT
  -- fxHidden, which is the damage blink alone -- so a model reading only the
  -- blink stood on its tile while every attack aimed at it missed.
  battle.enemy = { sprite = true }
  battle.picFx = { [battle.enemy] = { hidden = true } }
  T.eq(onField(battle, "enemy", mon("attack", false)), false,
    "a Pokemon that has flown up or dug in is not on the field, however "
    .. "much of its own animation is still to play")

  battle.picFx = { [battle.enemy] = { kind = "slideOff", t = 4 } }
  T.eq(onField(battle, "enemy", mon("attack", false)), true,
    "but it IS while the engine's slide is still running -- which is the "
    .. "window its own launch animation plays in")

  battle.picFx = { [battle.enemy] = {} }
  T.eq(onField(battle, "enemy", mon("idle", false)), true,
    "and a pic program that has finished and cleared leaves it standing")
  battle.picFx = nil
end)()

-- ------- and the two STADIUM rungs are SKIPPED when the models are not there
--
-- The mod ships no Pokemon Stadium data, so on a machine whose owner has not
-- supplied that ROM the row has three stops rather than five. Checked by
-- gating them off by hand rather than by hiding the packs, because what is
-- being tested is the ladder's behaviour and not the installer's.
--
-- 2D-3D B survives that, which is the point of it being its own rung: the
-- discs are generated in Lua and the Pokemon on them are the game's own art,
-- so the disc framing is available to a player who has no Stadium ROM at all.
;(function()
  local gate = Battles.setting.gate
  Battles.setting:setGate(function(value)
    return value ~= "stadium" and value ~= "stadiumB"
  end)
  T.eq(Battles.setting:rungs(), 3,
    "with no models built the 3D-BTL row offers three rungs, not five")
  Battles.setting:setValue(true, Game)
  Game.keypressed(keyGame, "8")
  T.eq(Battles.setting:get(), "flatB",
    "8 still reaches 2D-3D B, which needs no ROM")
  Game.keypressed(keyGame, "8")
  T.eq(Battles.setting:get(), false,
    "and the next press steps straight past both STADIUM rungs to OFF")
  Game.keypressed(keyGame, "8")
  T.eq(Battles.setting:get(), true, "and back to 2D-3D A")

  -- a save that CHOSE stadium before the ROM went missing reads as the
  -- default, rather than as a mode with nothing behind it -- and the stored
  -- value is left alone, so putting the ROM back restores the choice
  Battles.setting.index = 3
  T.eq(Battles.setting:get(), true,
    "a stored STADIUM with no models behind it reads as 2D-3D A")
  -- and opening the gate hands the choice straight back, off the stored
  -- value that was never overwritten. Opened by HAND rather than by putting
  -- the real gate back: the real one answers "are the models installed on
  -- this machine", which is false wherever this suite runs from a clean
  -- clone -- and the subject here is the ladder, not the installer.
  Battles.setting:setGate(function() return true end)
  T.eq(Battles.setting:get(), "stadium",
    "and comes back the moment the models do")
  Battles.setting:setGate(gate)
  Battles.setting:setValue(true, Game)
end)()

-- ------- SELECT makes the same step the 3 key does
--
-- The pad's own button, for the machines with no number row. The wrap
-- sits on OverworldState:handleInput -- free-roam by construction -- and
-- reads the live Game's input, so the fake free-roam shape the key tests
-- built is lent to the Game module for the length of the check.
-- (An anonymous function scope: the main chunk sits AT LuaJIT's
-- 200-active-locals ceiling, so even a named wrapper is one too many.)
;(function()
  local OverworldState = require("src.world.OverworldController")
  T.eq(OverworldState.dramaticShapeSelectHook, true,
    "the SELECT wrap is installed on the overworld input seam")
  local hadInput, hadStack = Game.input, Game.stack
  local hadOw, hadSave, hadWrite = Game.overworld, Game.save, Game.writeOptions
  Game.input = { wasPressed = function(_, b) return b == "select" end }
  Game.stack, Game.overworld = keyGame.stack, keyGame.overworld
  Game.save, Game.writeOptions = keyGame.save, keyGame.writeOptions
  Pipelines.setLevel("voxel", 0)
  OverworldState.handleInput({})
  T.eq(Pipelines.levelLabel("voxel"), "15",
    "SELECT steps the VOXEL ladder exactly as 3 does")
  OverworldState.handleInput({})
  T.eq(Pipelines.levelLabel("voxel"), "35", "and keeps walking it")
  Game.input, Game.stack = hadInput, hadStack
  Game.overworld, Game.save, Game.writeOptions = hadOw, hadSave, hadWrite
  Pipelines.setLevel("voxel", 0)
end)()

-- 3 also clears the two engine modes it displaced. Without this a player
-- who left TILT or GBC FX on before enabling the mod has no key left to
-- turn them off with, and both fight the diorama -- TILT is the flat fake
-- of what this mode does for real, GBC FX a present pass over the top.
local GBCFX = require("src.render.GBCFX")
Tilt.setLevel(2)
GBCFX.setLevel(3)
keyGame.save.options.tilt = 2
keyGame.save.options.gbcfx = 3

Game.keypressed(keyGame, "3")
T.eq(keyGame.save.options.tilt, 0, "3 turns TILT off in the save")
T.eq(Tilt.level, 0, "and on the live renderer")
T.eq(keyGame.save.options.gbcfx, 0, "3 turns GBC FX off in the save")
T.eq(GBCFX.level, 0, "and on the live renderer")

-- Every press, not just the one that switches the mode on. This is the
-- half the registry does NOT cover: its tilt exclusion fires when a world
-- pipeline takes the pass, so a press that switches voxel ON would clear
-- TILT with or without us. Park the ladder on its top rung and turn both
-- back on, so the single press under test is the one that wraps to OFF --
-- where nothing else is going to clear them.
-- 3RD is the last rung the key walks before it wraps to OFF
Pipelines.setLevel("voxel", VoxelState.TP_LEVEL)
Tilt.setLevel(3)
GBCFX.setLevel(4)
keyGame.save.options.tilt = 3
keyGame.save.options.gbcfx = 4

Game.keypressed(keyGame, "3")
T.eq(Pipelines.level("voxel"), 0, "the press wraps the ladder back to OFF")
T.eq(keyGame.save.options.tilt, 0, "the press that wraps to OFF still clears TILT")
T.eq(Tilt.level, 0, "with the renderer agreeing")
T.eq(keyGame.save.options.gbcfx, 0, "and still clears GBC FX")
T.eq(GBCFX.level, 0, "with the renderer agreeing there too")

-- but 6 must not: T-SHIFT is a post-process that composes with TILT, and
-- the registry deliberately leaves it alone
Tilt.setLevel(2)
keyGame.save.options.tilt = 2
Game.keypressed(keyGame, "6")
T.eq(keyGame.save.options.tilt, 2, "6 leaves TILT alone -- the blur composes with it")
Tilt.setLevel(0)
keyGame.save.options.tilt = 0

-- the engine's own keys the mod did NOT claim must still reach it: 4 is
-- ZOOM, and taking it would be a bug rather than a feature
local zoomKeyReached = false
local realZoomGate = require("src.render.Zoom").gateOK
require("src.render.Zoom").gateOK = function() zoomKeyReached = true; return false end
Game.keypressed(keyGame, "4")
require("src.render.Zoom").gateOK = realZoomGate
T.check(zoomKeyReached, "a key this mod does not claim still reaches the engine")

-- A screen with its own key handler owns the keyboard: typing a nickname
-- must not cycle a render mode behind the text box.
local gridBefore = VoxelGrid.setting:get()
local voxelBefore = Pipelines.level("voxel")
local typed = {}
local menu = { onKeyPressed = function(_, k) typed[#typed + 1] = k end }
keyGame.stack.top = function() return menu end
for _, k in ipairs({ "3", "5", "6", "7" }) do Game.keypressed(keyGame, k) end
T.eq(#typed, 4, "every claimed key goes to a screen that handles keys itself")
T.eq(VoxelGrid.setting:get(), gridBefore, "V-GRID is untouched while a screen has focus")
T.eq(Pipelines.level("voxel"), voxelBefore, "and so is the voxel ladder")

-- and the free-roam gate the engine applies to its own display keys applies
-- to the settings too: no flipping the wireframe mid-cutscene
keyGame.stack.top = function() return overworld end
overworld.transitioning = true
local midWarp = VoxelGrid.setting:get()
Game.keypressed(keyGame, "5")
T.eq(VoxelGrid.setting:get(), midWarp, "V-GRID refuses mid-transition, as the mode does")
overworld.transitioning = false

-- ------- the sky at the top rung
--
-- At 75 degrees the camera is pitched far enough over that the horizon is
-- in frame, so the void behind the diorama becomes a sky rather than the
-- black plate it reads as at every rung below. Outdoors only: a house or a
-- cave is a room with a ceiling, and the void past its walls is the
-- outside of a box, not open air.

local Voxel = run.loader.exports.DRAMATIC_SHAPE.lib.require("VoxelState")
local skyFor = VoxelScene._skyFor
local skyStrength = VoxelScene._skyStrength
T.check(type(skyFor) == "function", "the scene exposes its sky resolve")

-- pinned to DAY for every sky assertion below: the row ships defaulting to
-- SYNC -- the machine's own clock -- which would hand these tests whatever
-- palette the hour of the test run happened to be
run.loader.exports.DRAMATIC_SHAPE.lib.require("DayNight").setting:sync("day")

local outside = { def = { id = "PALLET_TOWN", tileset = "OVERWORLD" } }
local inside = { def = { id = "REDS_HOUSE_1F", tileset = "HOUSE" } }
local TOP = math.rad(Voxel.ANGLES_DEG[Voxel.MAX_LEVEL + 1])

-- the ladder, by angle: every rung that tilts at all paints a sky
for level = 0, Voxel.MAX_LEVEL do
  Voxel.angle = math.rad(Voxel.ANGLES_DEG[level + 1])
  local sky = skyFor(outside)
  if level == 0 then
    T.eq(sky, nil, "rung 0 is the flat camera: no tilt, no void, no sky")
  else
    T.check(sky ~= nil, "rung " .. level .. " paints a sky outdoors")
    T.eq(sky[4], 1, "and paints it at full strength")
    T.check(sky.bands ~= nil, "with its bands on it")
  end
end

-- indoors, never -- at any rung, including the top one
for level = 0, Voxel.MAX_LEVEL do
  Voxel.angle = math.rad(Voxel.ANGLES_DEG[level + 1])
  T.eq(skyFor(inside), nil, "an interior has no sky at rung " .. level)
end
Voxel.angle = TOP
T.eq(skyFor(inside), nil, "not even at 75 degrees, where outdoors would")

-- a map record with nothing to ask is not a crash
T.eq(skyFor(nil), nil, "no map, no sky")
T.eq(skyFor({}), nil, "a map with no def is not an outdoor map")

-- full strength at every rung, with the ramp left only for the ARRIVAL: the
-- camera eases up from flat when the mode is switched on, and the sky comes up
-- with it rather than appearing whole on the keypress
T.eq(skyStrength(math.rad(15)), 1, "the shallowest rung is full sky")
T.eq(skyStrength(math.rad(50)), 1, "so is the one below the top")
T.eq(skyStrength(TOP), 1, "and the top rung")
T.eq(skyStrength(0), 0, "a camera that has not tilted at all paints none")
local rising = skyStrength(math.rad(4))
T.check(rising > 0 and rising < 1,
  "and the first few degrees off flat are the fade-in")
T.check(skyStrength(math.rad(6)) > skyStrength(math.rad(3)),
  "which strengthens as the camera lifts")

-- the colour answers to the display mode, exactly as the terrain does: a
-- hardcoded blue would sit wrong in the modes that are not colour modes
Voxel.angle = TOP
local function skyRGB(mode)
  local prev = PaletteFX.mode
  PaletteFX.mode = mode
  local c = skyFor(outside)
  PaletteFX.mode = prev
  return c
end

local blue = skyRGB("gbc")
T.check(blue[3] > blue[1], "in a colour mode the sky is blue -- more blue than red")

local grey = skyRGB("og")
T.check(math.abs(grey[1] - grey[2]) < 1e-6 and math.abs(grey[2] - grey[3]) < 1e-6,
  "GRAY paints a grey sky, not a blue one")

local green = skyRGB("classic")
T.check(green[2] > green[1] and green[2] > green[3],
  "CLASSIC paints a green sky, matching its green world")

T.check(skyRGB("gbc_inv")[3] ~= blue[3],
  "GBC INV does not paint the same sky as GBC")

-- ------- and the sky is a banded gradient, with no picture behind it
--
-- One flat blue was enough while the void was a sliver; with the horizon a
-- quarter of the way down the frame it is a wall of paint. So the sky is the
-- 8-bit skybox recipe: a short palette of blues painted as flat bands, deepest
-- overhead, with a checkerboard of the next band dithered into the bottom of
-- each. Nothing is baked to a fixed size and upscaled -- the bands fill the
-- window and the dither grid is cut to the diorama's own pixel scale.
do
local Sky = run.loader.exports.DRAMATIC_SHAPE.lib.require("Sky")
local Voxel3D = run.loader.exports.DRAMATIC_SHAPE.lib.require("Voxel3D")
local DayNight = run.loader.exports.DRAMATIC_SHAPE.lib.require("DayNight")

local function luma(c) return 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3] end

-- the palette is the band list, and it belongs to the CLOCK now: DayNight
-- owns one per phase and blends between them. The row defaults to DAY, so
-- what the sky paints here is the day palette -- still every inch a GBC one.
local dayPal = DayNight.PALETTES.day
for i, c in ipairs(dayPal) do
  T.check(c[1] % 8 == 0 and c[2] % 8 == 0 and c[3] % 8 == 0,
    "palette entry " .. i .. " is a colour a Game Boy Color could show -- five "
    .. "bits a channel, so every one is a multiple of 8")
  T.check(c[3] > c[1], "and it is blue: more blue than red")
end
T.eq(#dayPal, 6, "six of them: twilight needs the rungs, and day matches")

Voxel.angle = TOP
local skyGrad = skyRGB("gbc")
T.eq(#(skyGrad.bands or {}), #dayPal,
  "the sky arrives with one band per palette entry")

for i, band in ipairs(skyGrad.bands) do
  if i > 1 then
    T.check(luma(band) > luma(skyGrad.bands[i - 1]),
      "band " .. i .. " is lighter than the one above it: the sky pales toward "
      .. "the horizon")
  end
end
-- read backwards out of the palette, which is stored in shade order (lightest
-- first) so a display mode's own four colours drop straight in
local deepest = dayPal[#dayPal]
T.check(math.abs(skyGrad.bands[1][1] - deepest[1] / 255) < 1e-9,
  "the top band is the palette's deep rung, unmixed")

-- the fill a caller clears to IS the palest band, so the haze below the horizon
-- and the bottom of the sky are one colour and the horizon has no seam
local palest = skyGrad.bands[#skyGrad.bands]
T.check(math.abs(skyGrad[1] - palest[1]) < 1e-9
        and math.abs(skyGrad[2] - palest[2]) < 1e-9
        and math.abs(skyGrad[3] - palest[3]) < 1e-9,
  "the flat fill is the palest band, so the horizon line has no seam of its own")
T.eq(skyGrad[4], 1, "and the tween strength still rides on the descriptor")

-- the gradient belongs to the VOXEL 75 rung and the walking camera on it. The
-- arena shot asks for the sky by the flat route (VoxelScene.skyColor) and gets
-- exactly the sky it always had -- its placed camera's horizon is above the
-- frame, so there would be no gradient to see from down there anyway.
local flat = VoxelScene.skyColor(outside, 1)
T.eq(flat.bands, nil, "a battle's arena sky is the flat fill, not the gradient")
T.check(math.abs(flat[1] - palest[1]) < 1e-9
        and math.abs(flat[3] - palest[3]) < 1e-9,
  "and it is the hour's haze, so a staged fight stands under the same sky "
  .. "free-roam does -- navy at midnight, gold at dusk")

-- the same call, the same numbers, and the same TABLE: the bands are memoised
-- per display mode, so a frame that paints the sky allocates nothing to do it
local again = Sky.bands()
T.eq(Sky.bands(), again, "the bands are computed once and held, not rebuilt")

local greyBands = skyRGB("og").bands
for i, band in ipairs(greyBands) do
  T.check(math.abs(band[1] - band[2]) < 1e-9
          and math.abs(band[2] - band[3]) < 1e-9,
    "GRAY gets four greys, not four blues (band " .. i .. ")")
end
T.check(luma(greyBands[#greyBands]) > luma(greyBands[1]),
  "and they still climb toward the horizon")

-- ------- where the bands go is the camera's own answer
--
-- The pale end has to meet the horizon at any pitch, fov or window shape, so it
-- is placed on the ground plane's vanishing line -- which is what projecting a
-- direction ALONG the ground through the scene matrix gives. Checked against the
-- limit of projecting real ground points further and further away, so a retuned
-- camera either still agrees with this or says so.
local function groundY(h, dist)
  local m = Voxel3D.vp
  local y = m[5] * 0 + m[7] * -dist + m[8]
  local w = m[13] * 0 + m[15] * -dist + m[16]
  return (y / w * 0.5 + 0.5) * h
end

Voxel.angle = TOP
local vh = 288
Voxel3D.vp = Voxel3D.viewProjection(0, 0, 320, vh)
local horizon = Voxel3D.horizonY(vh)
T.check(horizon and horizon > 0 and horizon < vh,
  "at the top rung the horizon is inside the frame, which is why there is a sky")
T.check(math.abs(groundY(vh, 200000) - horizon) < 0.5,
  ("ground at infinity converges on it: %.2f vs %.2f")
  :format(groundY(vh, 200000), horizon))
T.check(groundY(vh, 200) > groundY(vh, 2000)
        and groundY(vh, 2000) > horizon,
  "and nearer ground is always below it, never above")
T.check(horizon < vh / 2,
  "the horizon sits in the upper half: the sky is a band across the top, not "
  .. "half the picture")

-- the fraction is a property of the camera, not of the canvas
Voxel3D.vp = Voxel3D.viewProjection(0, 0, 320, vh)
local tall = Voxel3D.horizonY(vh * 3)
T.check(math.abs(tall / (vh * 3) - horizon / vh) < 1e-9,
  "a taller canvas puts it at the same fraction, so the bands scale with it")

Voxel.angle = 0
Voxel3D.vp = Voxel3D.viewProjection(0, 0, 320, vh)
T.eq(Voxel3D.horizonY(vh), nil,
  "a camera looking straight down has no horizon to find, and paints no bands")

-- ------- where the sky's bottom edge goes at each rung
--
-- The camera's own horizon when that is in frame -- which is the top rung -- and
-- otherwise a fixed slice of the frame, because at the steeper rungs the void
-- that shows is where the ground runs OUT rather than what is above the horizon.
-- One sky across the whole ladder either way.
T.check(math.abs(Sky.region(288, 66.83) - 66.83) < 1e-9,
  "a horizon in frame is where the sky ends")
T.eq(Sky.region(288, -930), 288 * Sky.SPAN,
  "a horizon above the frame falls back to a fixed slice of it")
T.eq(Sky.region(288, nil), 288 * Sky.SPAN, "and so does no horizon at all")
T.eq(Sky.region(288, 4000), 288, "a horizon below the frame fills it")
T.eq(Sky.region(0, 40), nil, "and a canvas with no height paints nothing")
T.check(Sky.SPAN > 0.1 and Sky.SPAN < 0.5,
  "the fallback slice is a band across the top, not half the picture")

-- ------- the pass, as it is actually issued
--
-- One rectangle through one shader: no baked picture of a sky, nothing being
-- resampled -- which is the whole reason it is drawn this way rather than
-- generated once and scaled. Every pixel answers from its own canvas coordinate,
-- so it is computed at the size it is shown at.
--
-- The one texture bound is the band RAMP, and it is a palette rather than a
-- picture: one texel per band, sampled nearest. It used to be a uniform array,
-- and that is the bug this shape exists to have fixed -- on Android the array's
-- later slots arrived as zero and painted the bottom of the sky black, while the
-- identical colour delivered by love.graphics.clear (the haze under the horizon)
-- landed correctly. So the assertions below pin the ramp, not an array.
--
-- And the depth mode is put back to what it was, which is the piece that would
-- break the frame: a rectangle drawn under the pass's own ("lequal", true) stamps
-- itself across the depth buffer at the near plane and hides the whole world
-- behind the sky.
local realGraphics, realImage = love.graphics, love.image
local rects, depthCalls, sent, shaderUses = {}, {}, {}, 0
local fakeShader = {
  send = function(_, name, a, b, c, d)
    sent[name] = { a, b, c, d }
  end,
}
-- enough of an image to be built and measured; the ramp only ever has pixels
-- written into it and its dimensions read back
local function fakeImage(w, h)
  return {
    pixels = {},
    getWidth = function(self) return w end,
    getHeight = function(self) return h end,
    getDimensions = function(self) return w, h end,
    setPixel = function(self, x, _, r, g, b, a)
      self.pixels[x] = { r, g, b, a }
    end,
    setFilter = function() end,
    setWrap = function() end,
  }
end
love.image = { newImageData = function(w, h) return fakeImage(w, h) end }
love.graphics = {
  getShader = function() return nil end,
  setShader = function(sh) if sh then shaderUses = shaderUses + 1 end end,
  getDepthMode = function() return "lequal", true end,
  setDepthMode = function(cmp, write)
    depthCalls[#depthCalls + 1] = tostring(cmp) .. "/" .. tostring(write)
  end,
  setColor = function() end,
  newShader = function() return fakeShader end,
  newImage = function(data) return data end,
  rectangle = function(_, x, y, w, h)
    rects[#rects + 1] = { x = x, y = y, w = w, h = h }
  end,
}
Sky.invalidate()   -- so the ramp is built through the fakes above, not held

-- 320x288 canvas, horizon at 66.83, diorama pixels 7 canvas pixels square
local painted = Sky.paint(320, 288, skyGrad, 66.83, 7)
local ramp = Sky._rampFor(skyGrad.bands)
love.graphics, love.image = realGraphics, realImage

T.eq(painted, true, "the sky paints")
T.eq(shaderUses, 1, "through one shader")
T.eq(#rects, 1, "over one rectangle -- not one per band, and not one per cell")
T.eq(rects[1].x, 0, "from the left edge")
T.eq(rects[1].w, 320, "across the full width of the frame")
T.eq(rects[1].y, 0, "and from the top edge")
T.eq(rects[1].h, 67, "down to the horizon")

T.eq(sent.count[1], #skyGrad.bands, "the band count goes to the shader")
T.check(math.abs(sent.edge[1] - 66.83) < 1e-9, "with the sky's bottom edge")
T.eq(sent.cell[1], 7,
  "and the diorama's pixel size, which is what puts the bands and the dither "
  .. "cells on the world's own grid")
T.eq(sent.start[1], Sky.DITHER_START, "and where in a band the checker begins")
T.eq(sent.alpha[1], 1, "and the tween strength")
-- The palette goes as ONE ramp texture, not as eight uniform vectors. The width
-- is the contract the shader divides by: it samples texel (i + 0.5) / count, so
-- a ramp of any other width reads between two bands or off the end -- and off
-- the end is exactly the black the Android bug painted.
T.eq(sent.ramp[1], ramp, "the palette goes to the shader as its ramp texture")
T.eq(ramp:getWidth(), #skyGrad.bands, "one texel per band, and no spare slots")
T.eq(ramp:getHeight(), 1, "on a single row -- it is a palette, not a picture")
T.eq(Sky._rampFor(skyGrad.bands), ramp,
  "and it is built once and held, not rebuilt per frame")
-- every texel is a real colour: the failure being fixed here is a slot that
-- was never written reading back as zero, which is black
for i = 1, #skyGrad.bands do
  local texel = ramp.pixels[i - 1]
  T.check(texel ~= nil, "band " .. i .. " was written into the ramp")
  T.check(texel[1] == skyGrad.bands[i][1] and texel[2] == skyGrad.bands[i][2]
          and texel[3] == skyGrad.bands[i][3],
    "and it is that band's own colour, in the order the sky reads them")
end

T.eq(depthCalls[1], "always/false", "the sky is drawn with depth writes OFF")
T.eq(depthCalls[#depthCalls], "lequal/true",
  "and the pass's own depth mode is handed straight back")

-- ------- and it follows the zoom, in the frame the zoom changed
--
-- The cell size is handed in every frame rather than cached, so a ZOOM keypress
-- -- which is what changes the diorama's pixels-per-world-pixel -- lands in the
-- next frame with nothing to rebuild and nothing left over at the old scale.
local zoomed = {}
love.graphics = {
  getShader = function() return nil end, setShader = function() end,
  getDepthMode = function() return "lequal", true end,
  setDepthMode = function() end,
  setColor = function() end,
  newShader = function() return fakeShader end,
  rectangle = function(_, _, _, w, h) zoomed.rect = { w = w, h = h } end,
}
sent = {}
Sky.paint(1920, 1080, skyGrad, 250.6, 12)
love.graphics = realGraphics
T.eq(zoomed.rect.w, 1920, "a bigger window is filled to its own width")
T.eq(zoomed.rect.h, 251, "and its own horizon")
T.eq(sent.cell[1], 12, "with the cell size that came in with it, not a cached one")

T.eq(Sky.paint(320, 288, { 0, 0, 1, 1 }, 40, 7), false,
  "a descriptor with no bands on it is the old flat sky, untouched")
T.eq(Sky.paint(320, 0, skyGrad, 40, 7), false,
  "and a frame with no height paints nothing at all")
end

-- ------- reflections on water
--
-- Water is the one surface in this mode that cannot be drawn with the rest
-- of the world: it is a mirror, and a mirror needs what it reflects to
-- already be down. So it is lifted out of the terrain mesh at BUILD time and
-- drawn as its own pass. That lift is the load-bearing part -- get it wrong
-- and a lake is either a hole in the world or is drawn twice -- and it is
-- pure geometry, so it is driven here against a hand-drawn map.
do
local Water = run.loader.exports.DRAMATIC_SHAPE.lib.require("Water")
local Sky = run.loader.exports.DRAMATIC_SHAPE.lib.require("Sky")
local ChunkMesher = run.loader.exports.DRAMATIC_SHAPE.lib.require("ChunkMesher")
local Structures = run.loader.exports.DRAMATIC_SHAPE.lib.require("Structures")
local Shapes = run.loader.exports.DRAMATIC_SHAPE.lib.require("TileShape")
local TileShapeHeights = Shapes.heights()

-- ------- the ladder
--
-- Three rungs, not a toggle: the sky half of this costs a handful of
-- instructions and the screen-space half costs a ray march, so a machine
-- that wants the sunset on the lake but not the march has somewhere to sit.
T.eq(Water.setting.values[1], "full",
  "FULL is the default -- reflections are the point of having the row")
Water.setting:sync("full")            -- the row test above stepped it
T.eq(Water.level(), 2, "and it reads back as the full pass")
T.eq(Water.enabled(), true, "which is on")
Water.setting:sync("sky")
T.eq(Water.level(), 1, "SKY keeps the pass but drops the screen-space march")
T.eq(Water.enabled(), true, "and is still a reflection")
Water.setting:sync("off")
T.eq(Water.level(), 0, "OFF is no pass at all")
T.eq(Water.enabled(), false,
  "which is what puts the water back in the ordinary scene shader")
Water.setting:sync("full")

-- ------- the waves are geometry, not shading -- and they step at 15fps
--
-- The surface is a heightfield of one-world-pixel columns, each standing a
-- WHOLE number of pixels tall -- a voxel like every other voxel in this
-- mode -- and it advances in STEPS rather than sliding: 15 a second, the
-- cadence hand-drawn pixel art is animated at. A surface built out of whole
-- pixels that crawls smoothly between them gives away that the quantisation
-- is only skin deep.
do
local TerrainAtlas = run.loader.exports.DRAMATIC_SHAPE.lib.require("TerrainAtlas")
local realClock = TerrainAtlas._animFrame
local frame = 0
TerrainAtlas._animFrame = function() return frame end
local function at(f)
  frame = f
  return Water._waveTime()
end

local period = 60 / Water.WAVE_FPS
T.eq(period, 5, "12 steps a second is one every five engine frames")
T.eq(math.floor(period), period,
  "and the beat divides the engine's 60 exactly, so every step spans the "
  .. "same whole number of frames")
-- inside one step nothing moves; crossing one, it does
T.eq(at(0), at(period - 1),
  "every frame inside one wave step gets the same phase -- the surface "
  .. "steps rather than crawling between its own pixels")
T.neq(at(0), at(period), "and the step boundary is where it moves")

local steps = {}
for f = 0, 59 do steps[at(f)] = true end
local n = 0
for _ in pairs(steps) do n = n + 1 end
T.eq(n, Water.WAVE_FPS, "which is WAVE_FPS distinct positions in a second")
TerrainAtlas._animFrame = realClock

-- and the step is worth taking: one world pixel of the dominant train per
-- step, DERIVED from that train rather than tuned beside it, so a change of
-- wavelength moves the speed with it. A step the surface cannot resolve is
-- a smooth crawl wearing a quantised clock.
local t = Water.WAVE_TRAINS[1]
local freq = math.sqrt(t[1] * t[1] + t[2] * t[2])
local travel = (Water.waveRate() / Water.WAVE_FPS) * math.abs(t[3]) / freq
T.check(math.abs(travel - Water.WAVE_PIXELS_PER_STEP) < 1e-9,
  "each step advances the dominant crest by exactly WAVE_PIXELS_PER_STEP "
  .. "world pixels, so nothing ever lands half-way between two")

-- the trains reach the shader as source, off the same table the rate above
-- is derived from -- one list, so the two cannot drift
local trains = Water._trainSource()
T.eq(select(2, trains:gsub("h %+= sin", "")), #Water.WAVE_TRAINS,
  "every train in the table is summed by the shader")
T.check(trains:find(("%.4f"):format(t[1]), 1, true) ~= nil,
  "at the frequency the table states")

-- the variation that keeps three periodic trains from reading as wallpaper:
-- the dominant train's amplitude breathes with the swell and its crests bow
-- with the bend, both pasted from their own tables like the trains are
T.check(trains:find(("%.4f"):format(Water.WAVE_SWELL[1]), 1, true) ~= nil
        and trains:find(("%.4f"):format(Water.WAVE_BEND[1]), 1, true) ~= nil,
  "the swell and the bend reach the shader off the tables that document "
  .. "them, not off copies kept in step by hand")
T.check(Water.WAVE_SWELL[4] > 0 and Water.WAVE_SWELL[4] < 1,
  "the swell's deepest lull thins the dominant train without deleting or "
  .. "inverting it -- a sea with sets in it, not a sea that turns off")
for _, mod in ipairs({ Water.WAVE_SWELL, Water.WAVE_BEND }) do
  local mf = math.sqrt(mod[1] * mod[1] + mod[2] * mod[2])
  T.check(mf * 3.5 < freq,
    "a modulator's wavelength sits several times the carrier's, far enough "
    .. "apart that it reads as weather over the waves rather than as a "
    .. "fourth wave -- which would be the soup the weights exist to avoid")
end

T.check(Water.WAVE_HEIGHT > -TileShapeHeights.water,
  "the crests stand taller than the recess TileShape sinks water into -- "
  .. "they are RELIEF inside the quad's own footprint, so a bar that reaches "
  .. "above the bank is clipped at the water's edge rather than spilling")
end

-- ------- the moon on the water is the moon in the sky
--
-- The reflected disc is drawn by a shader and the painted one by rectangles,
-- so nothing but shared DATA can keep them the same moon. The crater list is
-- pasted into the shader source from Sky's own table, which is the seam that
-- makes "they cannot drift" true rather than merely intended.
local craters = Water._craterSource()
local craterLines = select(2, craters:gsub("crater%(", ""))
T.eq(craterLines, #Sky.MOON_CRATERS,
  "the shader gets one crater per crater the painted moon has")
for _, c in ipairs(Sky.MOON_CRATERS) do
  T.check(craters:find(("%.4f"):format(c[1]), 1, true) ~= nil,
    "and each one at the offset the painted moon puts it at")
end
T.check(craters:find(("%.4f"):format(Sky.CRATER_FRAC), 1, true) ~= nil,
  "at the same fraction of the disc's radius")

-- and the disc is the same SIZE, which is the other half of being the same
-- moon: one function answers for the painted radius and for the angle the
-- reflection subtends it at
local px, cells = Sky.discRadius(288, 7, { moon = true })
T.eq(cells, Sky.DISC_MIN,
  "a small frame floors the disc at its minimum radius in cells")
T.eq(px, Sky.DISC_MIN * 7, "reported in canvas pixels on that cell grid")
T.eq(select(2, Sky.discRadius(288, 7, { glowAmt = 0.9 })), Sky.DISC_MIN + 1,
  "and the low sun looms, exactly as the painted one does")
T.eq(select(2, Sky.discRadius(288, 7, { glowAmt = 0.9, moon = true })),
  Sky.DISC_MIN, "which is a SUNSET exaggeration -- the moon never looms")

-- the same band ramp, too: one texture, so the sky on the lake cannot be a
-- different palette from the sky over it
local rampImg, rampCount = Sky.ramp()
T.check(rampImg == nil or rampCount == #Sky.bands(),
  "the reflection reads the sky off the very ramp the sky is painted from")

-- ------- the horizon lean: the reflection has to have something IN it at
-- every rung, not just the one whose horizon is in frame
--
-- The rungs are named for the camera's tilt off VERTICAL, so at 15 the eye
-- meets the water nearly head-on and the mirror ray points 75 degrees UP --
-- where the sky's bands are darkest, the sun and moon (squashed to about 6
-- degrees) are nowhere near, and a screen-space ray leaves the frame in two
-- steps. All three are correct and together they are an empty lake. The lean
-- tips the reflection toward the way the camera looks by however far that
-- camera is from having a horizon in frame.
do
local Voxel3D = run.loader.exports.DRAMATIC_SHAPE.lib.require("Voxel3D")
local VoxelState = run.loader.exports.DRAMATIC_SHAPE.lib.require("VoxelState")
local wasAngle, wasCam = VoxelState.angle, Voxel3D.camera
Voxel3D.camera = nil

local lean = {}
for _, deg in ipairs({ 15, 35, 50, 75 }) do
  VoxelState.angle = math.rad(deg)
  Voxel3D.viewProjection(256, 256, 320, 288)
  lean[deg] = { Water.lean(Voxel3D.descent), Voxel3D.descent }
  -- the orbit looks NORTH, so the flattened view direction is -Z and level
  T.check(math.abs(Voxel3D.lookFlat[3] + 1) < 1e-6,
    ("the %d rung looks north along the ground plane"):format(deg))
  T.eq(Voxel3D.lookFlat[2], 0,
    "flattened onto it, so the lean can never tip a reflection underground")
end

-- descent is the SINE of how far below horizontal the view runs, and the
-- rungs are the camera's tilt off vertical -- so the two are complements
for _, deg in ipairs({ 15, 35, 50, 75 }) do
  T.check(math.abs(lean[deg][2] - math.cos(math.rad(deg))) < 1e-6,
    ("the %d rung descends by cos(%d)"):format(deg, deg))
end

T.eq(lean[75][1], 0,
  "at the rung whose horizon is in frame there is NO lean -- the one place "
  .. "the join can be seen (the waterline, where the lake meets the painted "
  .. "sky) is still the exact reflection it always was")
T.check(lean[50][1] > 0, "and it comes in as the camera tips over")
T.check(lean[35][1] >= lean[50][1] and lean[15][1] >= lean[35][1],
  "growing with every rung further from the horizon")
T.eq(lean[15][1], 1,
  "and complete well before the steepest rung, so every rung under the top "
  .. "one aims its reflection where the top one's already lands")

-- a camera looking dead level has nothing to lean
T.eq(Water.lean(0), 0, "a level camera leans not at all")
T.eq(Water.lean(1), 1, "and one looking straight down leans all the way")
T.eq(Water.lean(Water.LEAN_FROM), 0,
  "the ramp starts exactly where the top rung sits, so that rung is the one "
  .. "the lean never touches")
T.check(math.abs(math.sin(Water.LEAN_ELEV) - Water.LEAN_FROM) < 1e-12,
  "and the elevation it aims at IS that rung's own, stated as the same "
  .. "number rather than beside it")

VoxelState.angle, Voxel3D.camera = wasAngle, wasCam
end

-- ------- people do not shadow water
--
-- The sun pass is ONE map, so a surface cannot ask what threw a shadow
-- unless the map says -- and it does, in the blue channel, which was zero
-- anyway. Water is the only surface that asks: a character standing at a
-- lake's edge laid a hard cut-out of its own sprite across a surface already
-- showing the sky and the shoreline, which reads as a sticker rather than as
-- a shadow. Everything the world casts still shades it.
do
local ShadowMap = run.loader.exports.DRAMATIC_SHAPE.lib.require("ShadowMap")
T.check(type(ShadowMap.sprites) == "function",
  "the sun pass can be told it is drawing the cast rather than the world")
-- inert outside a pass, like every other toggle on it -- a caller that
-- brackets a draw it never made must not send to a shader that is not bound
T.check(pcall(ShadowMap.sprites, true) and pcall(ShadowMap.sprites, false),
  "and saying so outside one is harmless")

local shadowSrc = ShadowMap._source and ShadowMap._source() or nil
if shadowSrc then
  T.check(shadowSrc:find("fract(d), sprite", 1, true) ~= nil,
    "the marker rides the channel the depth pack left free, so it costs "
    .. "nothing: the map is still two channels of depth")
end
end

-- ------- the compiled variants
local plain = Water._source(false)
local gridded = Water._source(true)
T.check(plain:find("#define WAVE_STEPS " .. Water.WAVE_STEPS, 1, true) ~= nil,
  "the relief march's step count is compiled in too")
-- the whole surface is answered per COLUMN: the ray picks one, and the art,
-- the shading, the reflection and the dither all read that one rather than
-- the fragment's own place on the flat quad. A smoothly-shaded reflection
-- over hard-edged 8-bit water is two pictures stacked.
T.check(plain:find("floor(waveRaw(q) * waveHeight + 0.5)", 1, true) ~= nil,
  "column heights are floored to WHOLE world pixels -- a fractional step is "
  .. "a smooth wave with extra arithmetic, not a bar")
-- and the normal is read off the SMOOTH field underneath, which is the
-- difference between a moon on the water and confetti: integer heights give
-- integer differences, so a normal built from them can only point in about
-- five directions and a two-degree disc falls between them
T.check(plain:find("float h = waveRaw(q);", 1, true) ~= nil,
  "but the reflection's normal comes off the smooth surface the columns are "
  .. "a quantisation of, so the ray sweeps instead of jumping")
T.check(plain:find("waveNormal(vec2 q, float tilt)", 1, true) ~= nil
        and plain:find("waveNormal(col,", 1, true) ~= nil,
  "still one answer per column, so the surface stays pixel-quantised in "
  .. "space while the value it reflects with is continuous")
T.check(plain:find("relief(sheet, view, hit, col, face, axis)", 1, true) ~= nil,
  "and the visible column is found by walking the view ray through the "
  .. "slab, which is what makes a tall bar hide the short ones behind it")
-- ...over the FLAT sheet, which is the one thing that walk is built on: an
-- even slab over a level plane. The world curve drops each bar straight down
-- by its own column's drop, so undoing that drop hands relief() the field it
-- was written for. Walked in the world as DRAWN instead, the slab is a bowl:
-- the backward step up the ray climbs the bowl's near side as fast as it
-- climbs out of the water, the walk starts inside the sheet, and it returns a
-- column a pixel or three off -- differently per fragment, which is a
-- hard-edged patch of noise in the middle of a pond.
T.check(plain:find("vec3 sheet = vec3(vBent.x, vBent.y + bendDrop(vBent.xz), vBent.z)",
                   1, true) ~= nil,
  "and it walks the sheet the mesh was AUTHORED as, the bend taken back off, "
  .. "because a slab walk over a bowl starts inside the water")
-- the march's reach grows as one over the ray's descent, so a grazing camera
-- asks for hundreds of world pixels of it from a fixed number of samples --
-- which stepped over whole crests and smeared the surface into streaks
-- a sample is worth a SCREEN pixel of surface, so that is the stride: held
-- at a world pixel up close (finer buys nothing and skipping costs the
-- pepper) and opened out with distance (holding it there just runs the march
-- out of samples part-way down the slab, which flattened the lowest rung's
-- whole middle distance)
T.check(plain:find("#define WAVE_STRIDE", 1, true) ~= nil
        and plain:find("max(WAVE_STRIDE, dist * pxAngle / dy)", 1, true) ~= nil,
  "the relief stride is a screen pixel's worth of surface, floored at a "
  .. "world pixel")
T.check(Water.WAVE_STRIDE <= 1,
  "and that floor is at most ONE world pixel, because a column is one world "
  .. "pixel wide -- a longer one steps over columns, and which ones it "
  .. "misses changes fragment to fragment, which is the peppery noise")
-- and the art is read off the COLUMN rather than by offsetting the
-- fragment's own uv by however far the march happened to travel: one world
-- pixel is one texel, so a column's texel follows from where it stands and
-- two fragments landing on the same column cannot disagree about it
T.check(plain:find("org + (mod(col, 8.0) + 0.5) * texel", 1, true) ~= nil,
  "a column's art follows from its own world position, so it cannot swim "
  .. "with the camera or speckle between neighbouring fragments")
T.check(plain:find("waveUV(tc, col)", 1, true) ~= nil,
  "and the column is what is handed to it")

-- the wireframe is ruled on the COLUMNS, not on the flat sheet they stand on
T.check(gridded:find("columnSeam(hit, sheet, axis)", 1, true) ~= nil,
  "with V-GRID on, the seams outline the column the ray landed on -- every "
  .. "voxel of water its own block -- rather than ruling a grid across the "
  .. "flat quad underneath and ignoring the bars entirely")
T.check(gridded:find("vec3 w = fwidth(base);", 1, true) ~= nil,
  "measured off the smooth plane, because the hit jumps a whole column "
  .. "between neighbouring fragments and its own derivative is a step")
T.check(plain:find("march(surf, r)", 1, true) ~= nil,
  "the reflection marches from that column, not from the raw fragment")
-- The two halves of the world curve, and they pull opposite ways. WHAT the
-- lake reflects is worked out FLAT -- the same rule the rest of the mode
-- keeps, that the world tips away and the things standing on it do not lean
-- with it. Reflect off the bowl the bend has made instead and the far half
-- of a pond is a mirror tilted twenty degrees, throwing the ray past the
-- vertical, where the sky ramp's own measure (a screen row, through the
-- frame's matrix) swings from one end of the ramp to the other across a
-- single column and stamps hard-edged patches of the wrong sky into the
-- water.  But WHERE it lands has to be found in the world as DRAWN, because
-- that is what the depth buffer holds -- so the ray stays straight in the
-- flat world and every sample of it is bent on the way to the screen, by the
-- vertex stage's own displacement.
T.check(plain:find("p.y -= bendDrop(p.xz);", 1, true) ~= nil,
  "and every marched sample is bent into the world as DRAWN before it is "
  .. "projected, because that is the world the depth buffer holds")
T.check(plain:find("vec3 r = reflect(view, n);", 1, true) ~= nil
        and plain:find("reflect(view, vec3(0.0, 1.0, 0.0))", 1, true) ~= nil,
  "while the reflection itself is taken about the FLAT normal, so a curved "
  .. "world does not tip the lake the way it does not lean the buildings")
T.check(plain:find("mod(col.x + col.y, 2.0)", 1, true) ~= nil,
  "and the dither's checkerboard is cut from the columns too, so a camera "
  .. "pan slides the world through nothing")
T.check(plain:find("#define RAY_STEPS " .. Water.RAY_STEPS, 1, true) ~= nil,
  "the march's step count is compiled in -- GLSL wants a constant bound")
T.check(plain:find("VOXEL_GRID", 1, true) ~= nil,
  "the wireframe is guarded in the source")
T.check(plain:find("#define VOXEL_GRID", 1, true) == nil,
  "and off in the plain variant")
T.check(gridded:find("#define VOXEL_GRID", 1, true) ~= nil,
  "so a frame with the seams on gets its own compilation, like the scene "
  .. "shader -- a driver that refuses derivatives loses the seams and not "
  .. "the water")
T.check(plain:find("//@CRATERS", 1, true) == nil,
  "and the crater placeholder is gone by the time a driver sees the source")

-- ANDROID. GLSL ES defaults fragment floats to mediump and samplers to
-- lowp, and this shader is the one place in the mod where both defaults
-- are fatal: world coordinates run past fp16's fraction, the depth read
-- rounds to steps the march falls straight through, and -- the sharp edge
-- -- `vp` is declared by BOTH stages, whose defaults disagree, which GLSL
-- ES answers by refusing to LINK the shader at all. Flat lakes, empty log.
-- The sky's band ramp is this same lesson learned once already.
T.check(plain:find("precision highp float;", 1, true) ~= nil,
  "the pixel stage lifts GLSL ES's mediump default to highp, so the march "
  .. "keeps its fraction and the dual-declared vp links at one precision")
T.check(plain:find("GL_FRAGMENT_PRECISION_HIGH", 1, true) ~= nil,
  "guarded, so the odd GPU without fragment highp still compiles and "
  .. "falls back flat instead of failing loudly")
T.check(plain:find("LOVE_HIGHP_OR_MEDIUMP vec3 vBent", 1, true) ~= nil,
  "the world-position varying is qualified like the scene shader's vGrid "
  .. "rather than left to the fragment default")
T.check(plain:find("LOVE_HIGHP_OR_MEDIUMP Image depthTex", 1, true) ~= nil,
  "and the depth sampler is lifted off lowp, which is eight bits of depth")
T.check(plain:find(
    "effect(mediump vec4 color, Image tex, mediump vec2 tc, mediump vec2 sc)",
    1, true) ~= nil,
  "effect()'s own floats stay pinned to LOVE's prototype precision -- the "
  .. "Xclipse compiler reads a definition that drifted from the forward "
  .. "declaration as an illegal overload and refuses the whole shader")
T.check(plain:find("sc / love_ScreenSize.xy", 1, true) ~= nil,
  "the depth test normalises the pixel coord by the canvas's own pixel "
  .. "size -- `screen` counts canvas UNITS, and on a highdpi phone the two "
  .. "differ by the density, which clamped the lookup and cut the water "
  .. "into blocks")
-- ...and it tests against a buffer that now holds the water surface too,
-- because VoxelScene lays the meshes down flat before the reflective pass
-- runs over them. Nothing else can make one lake hide another: the pass
-- writes no depth (the buffer is detached so it can be READ), so before this
-- the sheets were simply painted in mesh order. Flat water never showed it --
-- one plane, and a farther sheet always lands farther down the screen -- but
-- the world curve drops the far side of the map into the near field of view,
-- and a sea a hundred and fifty tiles away came out rasterised on top of the
-- pond at the player's feet, tall grass and all.
T.check(plain:find("vec4 selfC = vp * vec4(vBent, 1.0)", 1, true) ~= nil
        and plain:find("Texel(depthTex, uv).r + 2e-4", 1, true) ~= nil,
  "testing a HIGHP recomputed depth (gl_FragCoord.z is mediump on mobile "
  .. "GLES -- fp16 loses a self-comparison outright) with slack covering "
  .. "the buffer's screen-linear interpolation drift across big quads")
T.check(VoxelScene.drawWater ~= nil, "and the flat draw that puts it there")

-- ------- the lift itself
--
-- A pond in a field: four water cells recessed below flat ground. The
-- shipped maps are the real thing but a picture states the invariant
-- exactly, and this one needs no atlas, no GPU and no fixture.
local WATER_TILE, GRASS_TILE = 20, 3
local pond = {
  { GRASS_TILE, GRASS_TILE, GRASS_TILE, GRASS_TILE },
  { GRASS_TILE, WATER_TILE, WATER_TILE, GRASS_TILE },
  { GRASS_TILE, WATER_TILE, WATER_TILE, GRASS_TILE },
  { GRASS_TILE, GRASS_TILE, GRASS_TILE, GRASS_TILE },
}
local pondMap = {
  id = "DS_TEST_POND",
  tileset = { id = "DS_TEST_SET", image = "gfx/tilesets/ds_test.png",
              tilesPerRow = 16, imageWidth = 128, imageHeight = 48,
              blocks = {}, grassTile = -1 },
  def = { width = 1, height = 1, tileset = "DS_TEST_SET" },
  walkable = { [GRASS_TILE] = true },
  waterTiles = { [WATER_TILE] = true },
  doorTiles = {},
  tileAt = function(_, tx, ty)
    return pond[(ty % 4) + 1][(tx % 4) + 1]
  end,
  cellTile = function(self, cx, cy) return self:tileAt(cx * 2, cy * 2 + 1) end,
  isWaterCell = function(self, cx, cy)
    return self:cellTile(cx, cy) == WATER_TILE
  end,
  isWalkableCell = function(self, cx, cy)
    return self:cellTile(cx, cy) == GRASS_TILE
  end,
  inBounds = function(_, cx, cy)
    return cx >= 0 and cy >= 0 and cx < 2 and cy < 2
  end,
}

-- body-only, so the border ring is out of it and the count is the picture
local _, _, whole = ChunkMesher.geometry(pondMap, true, nil)
Structures.invalidate(pondMap.id)
local landVerts, _, land, waterVerts, _, wet =
  ChunkMesher.geometry(pondMap, true, nil, true)

T.check(wet > 0, "the pond's surface comes out as water quads")
T.eq(land + wet, whole,
  "and the split is a MOVE, not a copy: every quad the one-sink build "
  .. "emitted is in exactly one of the two")
T.eq(#waterVerts, wet * 4, "the water sink holds whole quads")

-- every water vertex sits on the recessed plane, which is what says the
-- surface and only the surface was lifted -- the shoreline faces that drop
-- from the ground down to it belong to the GROUND that exposes them, and
-- must stay in the terrain mesh or a lake is ringed by a slit into the sky
local heights = Shapes.heights()
for _, v in ipairs(waterVerts) do
  T.check(v[2] == heights.water,
    "a water vertex stands on the water plane, not on a shoreline face")
end
local shore = 0
for _, v in ipairs(landVerts) do
  if v[2] < 0 then shore = shore + 1 end
end
T.check(shore > 0,
  "and the shoreline bands below ground level stayed with the terrain")

-- a map with no water at all splits into everything and nothing, rather
-- than into an empty terrain mesh
Structures.invalidate(pondMap.id)
local dry = {}
for y = 1, 4 do
  dry[y] = {}
  for x = 1, 4 do dry[y][x] = GRASS_TILE end
end
pond = dry
local _, _, dryLand, _, _, dryWet = ChunkMesher.geometry(pondMap, true, nil,
                                                         true)
T.check(dryLand > 0, "a map with no water still meshes its ground")
T.eq(dryWet, 0, "and hands back no water surface at all")

-- ------- and the pairing
--
-- The terrain mesh and the water lifted out of it are ONE answer: they came
-- from the same build, so a caller must never end up holding a full mesh
-- beside a body build's water (the ring's ponds twice, the body's as holes).
-- pair() is the only way to ask, which is what makes that unpairable.
local mesh, wetMesh = ChunkMesher.pair({ id = "DS_NOT_A_MAP" }, false)
T.eq(mesh, nil, "an unbuilt map pairs to nothing")
T.eq(wetMesh, nil, "on both halves, so a caller cannot half-draw one")

Structures.invalidate(pondMap.id)
ChunkMesher.invalidate(pondMap.id)
Shapes.invalidate()
end

Voxel.angle = 0

-- ------- overworld battles: where the fight is staged
--
-- The arena search is pure map arithmetic, so it is driven here against
-- hand-drawn maps rather than a fixture: the shape it looks for, the order
-- it relaxes in, and what it refuses are all things a picture can state
-- exactly.
--
-- The stub answers the small surface BattleArena asks a Map for. `rows` are
-- strings, one per cell row, "." open and anything else solid; "w" is water
-- (open to a surfer only) and "d" a warp tile.

local BattleArena = run.loader.exports.DRAMATIC_SHAPE.lib.require("BattleArena")

local function stubMap(rows)
  local at = function(cx, cy)
    local row = rows[cy + 1]
    return row and row:sub(cx + 1, cx + 1) or "#"
  end
  return {
    widthCells = #rows[1],
    heightCells = #rows,
    inBounds = function(_, cx, cy)
      return cx >= 0 and cy >= 0 and cx < #rows[1] and cy < #rows
    end,
    warpAtCell = function() return nil end,
    isWarpTileCell = function(_, cx, cy) return at(cx, cy) == "d" end,
    isWalkableCell = function(_, cx, cy) return at(cx, cy) == "." end,
    isWaterCell = function(_, cx, cy) return at(cx, cy) == "w" end,
    isGrassCell = function(_, cx, cy) return at(cx, cy) == "g" end,
  }
end

-- a field with room for the wide arena on its right-hand side only
local field = stubMap({
  "##########",
  "#....#####",
  "#....#####",
  "#....#####",
  "#....#####",
  "#....#####",
  "#....#####",
  "##########",
})

local arena = BattleArena.find(field, 2, 3, false)
T.check(arena ~= nil, "a field with a 3x6 clearing has an arena")
T.eq(arena.shape, "wide", "and it is the wide shape, not the fallback")
T.eq(arena.w, 3, "the wide arena is three cells across")
T.eq(arena.h, 6, "and six deep")

-- the two mons stand three cells apart down the middle column, which is
-- what the picture in BattleArena says and what the camera is built around
T.eq(arena.enemyCell[1], arena.playerCell[1],
  "both mons stand in the arena's middle column")
T.eq(arena.playerCell[2] - arena.enemyCell[2], 3,
  "with three cells of ground between them")
T.check(arena.enemyCell[2] < arena.playerCell[2],
  "the enemy is the NORTH one -- the far end from a camera parked south")

-- every cell of the shape is open, apron included: that one-cell margin is
-- the difference between a staged shot and a fight in a doorway
for cy = arena.y, arena.y + arena.h - 1 do
  for cx = arena.x, arena.x + arena.w - 1 do
    T.check(field:isWalkableCell(cx, cy),
      ("arena cell (%d,%d) is open ground"):format(cx, cy))
  end
end

-- world-pixel centres, which is the unit everything downstream works in
T.eq(arena.player[1], arena.playerCell[1] * 16 + 8,
  "the player's mark is the centre of its cell in world pixels")
T.eq(arena.mid[2], (arena.enemy[2] + arena.player[2]) / 2,
  "and the midpoint is halfway between the two")

-- nearest, not first found: two clearings, and the one under the player wins.
-- Wide enough that the battle camera -- which stands a few cells east and
-- south of whatever it is aimed at -- is over real ground for BOTH of them,
-- so this measures proximity rather than the clearance preference below.
local twin = stubMap({
  "########################",
  "#.##########.###########",
  "#.##########.###########",
  "#.##########.###########",
  "#.##########.###########",
  "########################",
  "########################",
  "########################",
  "########################",
  "########################",
})
local near = BattleArena.find(twin, 12, 3, false)
T.eq(near.shape, "narrow", "no 3x6 anywhere, so the search relaxes")
T.eq(near.x, 12, "and takes the corridor the player is standing in")
T.eq(BattleArena.find(twin, 1, 3, false).x, 1,
  "the same map from the other side picks the other one")

-- the wide shape wins even when a narrow one is closer: it is the shot this
-- mode is framed for, so proximity does not get to overrule it
local both = stubMap({
  "#.#########",
  "#.####...##",
  "#.####...##",
  "#.####...##",
  "######...##",
  "######...##",
  "######...##",
})
T.eq(BattleArena.find(both, 1, 1, false).shape, "wide",
  "a wide arena across the map beats a narrow one underfoot")

-- water is ground for a surfer and nothing at all for anyone else
local sea = stubMap({
  "wwwwww",
  "wwwwww",
  "wwwwww",
  "wwwwww",
  "wwwwww",
  "wwwwww",
})
T.eq(BattleArena.find(sea, 2, 2, false), nil,
  "open water is not open ground to someone walking")
T.check(BattleArena.find(sea, 2, 2, true) ~= nil,
  "but it is to a surfer, who is standing on it")

-- tall grass is walkable and is still not a stage: it is knee-high geometry
-- standing between a nearly-level camera and the mon behind it
local meadow = stubMap({
  "########",
  "#ggg..g#",
  "#ggg..g#",
  "#ggg..g#",
  "#ggg..g#",
  "#ggg..g#",
  "#ggg..g#",
  "########",
})
local mown = BattleArena.find(meadow, 2, 3, false)
T.check(mown ~= nil, "a meadow with a bare strip still has an arena")
for cy = mown.y, mown.y + mown.h - 1 do
  for cx = mown.x, mown.x + mown.w - 1 do
    T.check(not meadow:isGrassCell(cx, cy),
      ("no cell of the arena is tall grass (%d,%d)"):format(cx, cy))
  end
end
T.eq(BattleArena.find(stubMap({
  "#####", "#ggg#", "#ggg#", "#ggg#", "#ggg#", "#ggg#", "#ggg#", "#####",
}), 2, 3, false), nil,
  "a map that is nothing but grass has nowhere to stand a fight")

-- a doormat is walkable and is still not a stage
local hall = stubMap({
  "######",
  "#..d.#",
  "#....#",
  "#....#",
  "#....#",
  "######",
})
local halled = BattleArena.find(hall, 2, 3, false)
T.check(halled == nil or halled.shape == "narrow",
  "a warp tile is excluded, so the room's only 3x6 does not qualify")

T.eq(BattleArena.find(stubMap({ "###", "###" }), 1, 1, false), nil,
  "a map with no room at all yields no arena, and the battle draws plainly")

-- an authored refusal is honoured over the search: a map looked at and found
-- to have nowhere a fight reads has to be able to say so, or the fallback
-- goes and finds one of the spots that were already rejected by eye
local roomy = stubMap({
  "#####", "#...#", "#...#", "#...#", "#...#", "#...#", "#...#", "#####",
})
roomy.id = "TEST_REFUSED"
T.check(BattleArena.find(roomy, 2, 3, false) ~= nil,
  "a roomy map finds an arena by search when nothing is authored")
BattleArena.setOverride("TEST_REFUSED", false)
T.eq(BattleArena.find(roomy, 2, 3, false), nil,
  "an authored false refuses the map outright, search and all")
BattleArena.setOverride("TEST_REFUSED", nil)
T.check(BattleArena.find(roomy, 2, 3, false) ~= nil,
  "and dropping the refusal restores the search")

-- ------- overworld battles: the over-the-shoulder framing
--
-- The claim the whole shot rests on. The two pics are PINNED to their cells,
-- so the rig has to put those two patches of ground exactly where the GB's
-- own battle screen puts its two pics -- the player's low and left at
-- (40, 96), the enemy's high and right at (124, 56). Reprojected through the
-- real camera rather than asserted about the constants, so the day someone
-- retunes the rig this either still lands or says so.

local BattleCam = run.loader.exports.DRAMATIC_SHAPE.lib.require("BattleCam")
local BattleScene = run.loader.exports.DRAMATIC_SHAPE.lib.require("BattleScene")
local Voxel3Dcam = run.loader.exports.DRAMATIC_SHAPE.lib.require("Voxel3D")

-- where a world point lands in the 160x144 frame, or nil behind the camera
local function project(cam, point, w, h, fov)
  local saved = cam.fov
  if fov then cam.fov = fov end
  Voxel3Dcam.camera = cam
  local m = Voxel3Dcam.viewProjection(0, 0, w or 160, h or 144)
  Voxel3Dcam.camera = nil
  cam.fov = saved
  local x = m[1] * point[1] + m[2] * 0 + m[3] * point[2] + m[4]
  local y = m[5] * point[1] + m[6] * 0 + m[7] * point[2] + m[8]
  local cw = m[13] * point[1] + m[14] * 0 + m[15] * point[2] + m[16]
  if cw <= 1e-6 then return nil end
  return (x / cw * 0.5 + 0.5) * (w or 160), (y / cw * 0.5 + 0.5) * (h or 144)
end

BattleCam.reset()
local shot = BattleArena.find(field, 2, 3, false)
local rig, pitch = BattleCam.rig(shot, 0)

local px, py = project(rig, shot.player)
local ex, ey = project(rig, shot.enemy)
T.check(px ~= nil and ex ~= nil, "both marks are in front of the camera")
T.check(math.abs(px - 26) < 1 and math.abs(py - 96) < 1,
  ("the player's cell projects onto its pic's feet at (26, 96): got "
   .. "(%.2f, %.2f)"):format(px, py))
T.check(math.abs(ex - 124) < 1 and math.abs(ey - 56) < 1,
  ("the enemy's cell projects onto its pic's feet at (124, 56): got "
   .. "(%.2f, %.2f)"):format(ex, ey))
T.check(px < ex, "which puts the player's mon LEFT of the enemy's")
T.check(py > ey, "and lower in the frame -- nearer the camera")

-- low and long: the eye is near the floor looking almost along it, which is
-- what a 56-pixel sprite standing on a 16-pixel tile costs
T.check(pitch > math.rad(60) and pitch < math.rad(85),
  "the rig watches the arena from near ground level")

-- ------- a mon covers its own square
--
-- The pics are drawn at INTEGER scales -- 56 pixels for a front pic at 1x, 64
-- for a back pic at 2x -- so the only way a mon can stand in one overworld
-- square is for the camera to make that square that big. This is the pair of
-- equations the default rig was solved against alongside the two anchors, and
-- it is the one that sets how far away the camera has to be.
local function span(cam, point)
  local a = project(cam, { point[1] - 8, point[2] })
  local b = project(cam, { point[1] + 8, point[2] })
  return math.abs(b - a)
end

T.check(math.abs(span(rig, shot.player) - 64) < 4,
  ("the player's square is a back pic wide (64px at 2x): got %.2f")
  :format(span(rig, shot.player)))
T.check(math.abs(span(rig, shot.enemy) - 56) < 4,
  ("the enemy's square is a front pic wide (56px at 1x): got %.2f")
  :format(span(rig, shot.enemy)))

-- ------- the close rig, for rooms the default cannot stand back from
--
-- Five blocks is further than a gym is wide, so on one the default eye lands
-- outside the map and the border ring crosses the near mon. An arena asks for
-- the short rig by name, and the two things that have to hold are that it
-- really is close enough to sit in a room, and that it frames the SAME shot
-- -- both marks still on their anchors -- so swapping rigs changes the lens
-- and nothing about the composition.
local function eyeDistance(cam)
  local dx = cam.eye[1] - cam.focus[1]
  local dy = cam.eye[2] - cam.focus[2]
  local dz = cam.eye[3] - cam.focus[3]
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

T.check(eyeDistance(rig) > 120,
  "the default long lens stands well back -- that is what sizes the mons")

BattleCam.reset()
local snug = { mid = shot.mid, cam = "wide" }
local closeRig = BattleCam.rig(snug, 0)
local cd = eyeDistance(closeRig)
T.check(cd < 80,
  ("the wide lens is within five cells, so it fits inside a gym: got %.1f")
  :format(cd))
T.check(cd < eyeDistance(rig), "and is nearer than the default")

local cpx, cpy = project(closeRig, shot.player)
local cex, cey = project(closeRig, shot.enemy)
T.check(math.abs(cpx - 26) < 1 and math.abs(cpy - 96) < 1,
  ("the wide lens lands the player's mark on the same anchor: (%.2f, %.2f)")
  :format(cpx, cpy))
T.check(math.abs(cex - 124) < 1 and math.abs(cey - 56) < 1,
  ("and the enemy's too: (%.2f, %.2f)"):format(cex, cey))
T.check(span(closeRig, shot.player) < span(rig, shot.player),
  "the mons render smaller on it, which is what it trades for fitting")

-- ------- the quarter turns
--
-- An arena may be laid down any of the four ways (BattleArena's `turn`), and
-- the whole claim of the feature is that this is a fact about the GROUND and
-- never about the shot: the footprint, the two mons and the camera turn
-- together, so the pair land on the same two anchors at the same size and
-- only what is behind them changes.
--
-- Asserted by REPROJECTING each turn through the real rig, exactly the way
-- the unturned shot is checked above -- so a rig retune, or a sign error in
-- the rotation, says so here rather than in a screenshot nobody takes.
--
-- In its own scope: the suite's main chunk sits at LuaJIT's 200-active-local
-- ceiling, and every local below would be one more of them. The leading
-- semicolon is the file's own convention -- without it the previous
-- statement's `)` and this `(` parse as one call.
;(function()
  local corner = { shot.x, shot.y }
  -- How wide a mon's own square comes out, measured ACROSS the arena's axis.
  -- `span` above offsets along world X, which is across the axis only while
  -- the arena is standing the way the mode was drawn; on the odd quarters the
  -- axis IS X, so offsetting along it would measure the square's depth --
  -- foreshortened by a camera that is looking almost straight down it -- and
  -- report a shrinking mon that is nothing of the kind.
  local function acrossSpan(cam, point, turn)
    local d = (turn % 180 == 0) and { 8, 0 } or { 0, 8 }
    local a = project(cam, { point[1] - d[1], point[2] - d[2] })
    local b = project(cam, { point[1] + d[1], point[2] + d[2] })
    return math.abs(b - a)
  end
  for _, turn in ipairs({ 0, 90, 180, 270 }) do
    BattleCam.reset()
    local a = BattleArena.at(corner[1], corner[2], "wide", turn)
    T.check(a ~= nil, ("the wide arena places at turn %d"):format(turn))
    T.eq(a.turn, turn, ("and carries the turn it was placed at (%d)"):format(turn))

    -- the footprint swaps its reach on the odd quarters, which is the whole
    -- reason a corridor takes one way round and refuses the other
    local wantW = (turn % 180 == 0) and 3 or 6
    local wantH = (turn % 180 == 0) and 6 or 3
    T.eq(a.w, wantW, ("turn %d is %d cells across"):format(turn, wantW))
    T.eq(a.h, wantH, ("and %d deep"):format(wantH))

    -- both mons stay inside the footprint they were turned within, and stay
    -- three cells apart -- the gap the move animations are scaled against
    T.check(a.enemyCell[1] >= a.x and a.enemyCell[1] < a.x + a.w
            and a.enemyCell[2] >= a.y and a.enemyCell[2] < a.y + a.h,
      ("turn %d keeps the foe inside the footprint"):format(turn))
    T.check(a.playerCell[1] >= a.x and a.playerCell[1] < a.x + a.w
            and a.playerCell[2] >= a.y and a.playerCell[2] < a.y + a.h,
      ("turn %d keeps the player inside it too"):format(turn))
    local gap = math.abs(a.enemyCell[1] - a.playerCell[1])
                + math.abs(a.enemyCell[2] - a.playerCell[2])
    T.eq(gap, 3, ("turn %d still stands them three cells apart"):format(turn))

    -- and which way the foe lies from the player, which is what `turn` NAMES
    local dx = a.enemyCell[1] - a.playerCell[1]
    local dy = a.enemyCell[2] - a.playerCell[2]
    local want = ({ [0] = { 0, -3 }, [90] = { 3, 0 },
                    [180] = { 0, 3 }, [270] = { -3, 0 } })[turn]
    T.check(dx == want[1] and dy == want[2],
      ("turn %d puts the foe %d,%d from the player: got %d,%d")
      :format(turn, want[1], want[2], dx, dy))

    -- THE INVARIANT: the same composition, whichever way round it stands
    local r = BattleCam.rig(a, 0)
    local ppx, ppy = project(r, a.player)
    local eex, eey = project(r, a.enemy)
    T.check(ppx ~= nil and eex ~= nil,
      ("turn %d keeps both marks in front of the camera"):format(turn))
    T.check(math.abs(ppx - 26) < 1 and math.abs(ppy - 96) < 1,
      ("turn %d lands the player's mark on its anchor: (%.2f, %.2f)")
      :format(turn, ppx, ppy))
    T.check(math.abs(eex - 124) < 1 and math.abs(eey - 56) < 1,
      ("turn %d lands the enemy's on its own: (%.2f, %.2f)")
      :format(turn, eex, eey))
    T.check(math.abs(acrossSpan(r, a.player, turn) - 64) < 4,
      ("turn %d still makes the player's square a back pic wide (64px): got "
       .. "%.2f"):format(turn, acrossSpan(r, a.player, turn)))
    T.check(math.abs(acrossSpan(r, a.enemy, turn) - 56) < 4,
      ("turn %d still makes the foe's square a front pic wide (56px): got "
       .. "%.2f"):format(turn, acrossSpan(r, a.enemy, turn)))

    -- the eye really did move: a turn that left the camera where it was would
    -- pass every anchor test above by looking at the pair from the side
    if turn ~= 0 then
      local base = BattleArena.at(corner[1], corner[2], "wide", 0)
      BattleCam.reset()
      local r0 = BattleCam.rig(base, 0)
      local moved = math.abs(r.eye[1] - r0.eye[1])
                    + math.abs(r.eye[3] - r0.eye[3])
      T.check(moved > 16,
        ("turn %d actually moves the camera (%.1f world px)"):format(turn, moved))
    end
  end

  -- degrees in, degrees out, and anything else folded onto the four
  T.eq(BattleArena.quarters(360), 0, "a full turn is no turn")
  T.eq(BattleArena.quarters(-90), 3, "and a negative one comes round the back")
  T.eq(BattleArena.at(1, 1, "wide").turn, 0,
    "an arena placed without a turn is the way the mode was drawn")
end)()

-- an arena picks its rig by name, and anything unnamed gets the default
T.eq(BattleCam.rigFor({ cam = "wide" }), BattleCam.RIGS.wide,
  "an arena that asks for the wide lens gets it")
T.eq(BattleCam.rigFor({}), BattleCam.RIGS.tele, "and one that asks for nothing")
T.eq(BattleCam.rigFor({ cam = "nonsense" }), BattleCam.RIGS.tele,
  "as does one that asks for a rig that does not exist")

-- ------- the pins survive the window
--
-- The scene renders at the WINDOW's resolution, not the GB's, so the rig's
-- field of view is widened by the ratio the window bears to the letterbox.
-- What that has to buy is exactness: the letterbox sub-rectangle of the
-- widened render must be the framing the rig asked for, or the pics come
-- unpinned from the ground by however much it is out.

for _, win in ipairs({ { 1920, 1080, 7 }, { 640, 576, 4 }, { 1280, 1024, 7 },
                       { 800, 720, 5 } }) do
  local pw, ph, s = win[1], win[2], win[3]
  local lx = math.floor((pw - 160 * s) / 2)
  local ly = math.floor((ph - 144 * s) / 2)
  local wide = BattleScene.letterboxFov(rig.fov, ph, s)
  T.check(wide >= rig.fov - 1e-9,
    "a window taller than the letterbox needs a wider lens, never a tighter one")
  local wx, wy = project(rig, shot.player, pw, ph, wide)
  local gx, gy = (wx - lx) / s, (wy - ly) / s
  T.check(math.abs(gx - px) < 0.01 and math.abs(gy - py) < 0.01,
    ("%dx%d at scale %d reproduces the GB framing exactly: (%.3f, %.3f) vs "
     .. "(%.3f, %.3f)"):format(pw, ph, s, gx, gy, px, py))
end

-- ------- the drift
--
-- With the pics pinned, the drift is not decoration on a backdrop -- it
-- moves the mons themselves, and the whole reason it reads as depth is that
-- it moves the near one and the far one by DIFFERENT amounts. A backdrop
-- that merely slid would move them by the same one.
BattleCam.update(BattleCam.PAN_PERIOD / 4)
local rig2 = BattleCam.rig(shot, 0)
local px2 = project(rig2, shot.player)
local ex2 = project(rig2, shot.enemy)
T.check(math.abs(px2 - px) > 0.5, "the drift moves the near mark")
T.check((px2 - px) * (ex2 - ex) < 0,
  "and the far one the OTHER WAY -- parallax about a point between them")
T.check(math.abs(px2 - px) < 8 and math.abs(ex2 - ex) < 8,
  "neither is flung across the frame: the mons drift, they do not travel")

-- very slow: a quarter of the cycle is several seconds, and what it moves in
-- one FRAME has to be imperceptible
BattleCam.reset()
BattleCam.update(1 / 60)
local slow = BattleCam.rig(shot, 0)
local sx = project(slow, shot.player)
T.check(math.abs(sx - px) < 0.2,
  "one frame of drift moves a mon by a fifth of a pixel")

-- a placed camera declines the world curve outright: the bend exists to
-- drop the horizon away from a walking player, and here it would tip the
-- arena floor out from under the two mons pinned to it
T.eq(rig.curve, 0, "the battle camera switches the world curve off")

-- ------- the hit flash belongs to the mons, not the screen
--
-- The engine draws it as a full-screen white rectangle, which is a flash on
-- a white battle field and a whiteout of the map, the HUD and the text box
-- over a world. It is dropped on the way past and put back on the two cards.
local Battles = run.loader.exports.DRAMATIC_SHAPE.lib.require("OverworldBattle")
T.eq(Battles.flashing(nil), false, "no battle, no flash")
T.eq(Battles.flashing({ fx = {}, frame = 0 }), false,
  "a battle with no flash counter is not flashing")
T.eq(Battles.flashing({ fx = { flash = 0 }, frame = 0 }), false,
  "nor one whose counter has run out")
T.eq(Battles.flashing({ fx = { flash = 16 }, frame = 0 }), true,
  "a live counter flashes on the frames the engine would")
T.eq(Battles.flashing({ fx = { flash = 16 }, frame = 2 }), false,
  "and is dark on the others, which is what makes it flicker")
T.eq(Battles.flashing({ fx = { flash = 16 }, frame = 5 }), true,
  "on a four-frame cycle")

-- ------- the wireframe follows the V-GRID row, battles included
--
-- The row is the whole answer. A battle used to force the seams on whatever
-- it said -- so nothing may override enabled(), and the battle pass must not
-- write the row either: a fight that flipped it would rewrite a setting the
-- player chose.
local Grid = run.loader.exports.DRAMATIC_SHAPE.lib.require("VoxelGrid")
local idxWas = Grid.setting.index
Grid.setting:sync(true)
T.eq(Grid.enabled(), true, "the wireframe is on when the row is on")
Grid.setting:sync(false)
T.eq(Grid.enabled(), false, "and off when the row is off -- nothing overrides it")
T.eq(Grid.override, nil, "and there is no override left to force a battle on")
Grid.setting.index = idxWas

-- ------- the depth of field is measured off the two marks
--
-- The slab held sharp is the one the mons are standing in, so the band has
-- to be derived from where they landed rather than from a constant -- and it
-- has to hold BOTH, which a band narrower than the gap between them would
-- not.
local BattleDOF = run.loader.exports.DRAMATIC_SHAPE.lib.require("BattleDOF")
local focusY, band, range = BattleDOF.bandFor(96, 56, 144)
T.check(math.abs(focusY - 76 / 144) < 1e-9,
  "the band centres between the two marks")
T.check(focusY - band < 56 / 144 and focusY + band > 96 / 144,
  "and is wide enough that both of them are inside it")
T.check(range > 0, "with a ramp out of it, so the band edge has no seam")
local wide = select(2, BattleDOF.bandFor(120, 30, 144))
T.check(wide > band, "marks further apart hold a deeper slab in focus")

-- ------- the HUDs are snapped to the window's own edges
--
-- The battle screen is 160x144 in the middle of the window and the world is the
-- whole of it, which left both HUD blocks huddled in the middle of the frame
-- with map on either side of them. Each is snapped to its own side instead: the
-- foe's to the left edge, the player's to the right. Measured in world-canvas
-- pixels, because that is the surface they are composited into -- the GB canvas
-- they are drawn in cannot reach past its own 160 columns.
do
local hudShot = { lx = 100, ly = 12, scale = 3, pw = 1000, ph = 500 }
local hudRects, bandX = Battles.snapRects(hudShot)
local hudRect = Battles.HUD_RECT

T.eq(hudRects.enemy[1], 0, "the foe's panel starts at the window's left edge")
T.eq(hudRects.player[1] + hudRects.player[3], hudShot.pw,
  "and the player's ends at the right one")
T.check(hudRects.enemy[1] < hudShot.lx,
  "so the foe's block has left the letterbox it used to sit in")
T.check(hudRects.player[1] > hudShot.lx + hudRect.player[1] * hudShot.scale,
  "and the player's has gone the other way")

-- the vertical is untouched: both blocks stay on the rows the GB put them on
T.eq(hudRects.enemy[2], hudShot.ly + hudRect.enemy[2] * hudShot.scale,
  "the foe's block keeps its own rows")
T.eq(hudRects.player[2], hudShot.ly + hudRect.player[2] * hudShot.scale,
  "and so does the player's")

-- and their size: a block is the same GB tiles at the same scale as the rest of
-- the art, moved and not stretched
T.eq(hudRects.enemy[3], hudRect.enemy[3] * hudShot.scale,
  "a block is its own width at the frame's scale")
T.eq(hudRects.player[4], hudRect.player[4] * hudShot.scale,
  "and its own height")

-- the band each block is cut out of is placed so the block lands on the rect
-- above; that is what the panel and the glyphs agreeing depends on
T.eq(bandX.enemy + hudRect.enemy[1] * hudShot.scale, hudRects.enemy[1],
  "the foe's band is offset so its block lands on its panel")
T.eq(bandX.player + hudRect.player[1] * hudShot.scale, hudRects.player[1],
  "and the player's likewise")

-- a window the shape of the GB screen has nowhere to snap TO, and the player's
-- block already ends at column 160, so it must not move at all
local snug = { lx = 0, ly = 0, scale = 4, pw = 160 * 4, ph = 144 * 4 }
local snugRects = Battles.snapRects(snug)
T.eq(snugRects.player[1], hudRect.player[1] * snug.scale,
  "on a GB-shaped window the player's block stays exactly where it was")
T.eq(snugRects.enemy[1], 0, "and the foe's is flush with a left edge it already met")

-- the bands together cover every row drawHUDs draws into (0-96: the two HUDs,
-- the pokeball rows and the safari ball count) and never overlap, so nothing it
-- draws is dropped or shown twice
local e, p = Battles.HUD_BAND.enemy, Battles.HUD_BAND.player
T.eq(e[2], 0, "the foe's band starts at the top of the frame")
T.eq(e[2] + e[4], p[2], "the player's picks up exactly where it ends")
T.check(p[2] + p[4] >= 96, "and together they reach the bottom of the HUD rows")
T.check(e[2] + e[4] <= hudRect.player[2],
  "the split falls between the two blocks, so neither is cut in half")
T.eq(e[1], 0, "the bands are full width")
T.eq(e[3], 160, "so a shaken HUD or a long name is carried out with its block")
end

-- ------- and the box at the bottom is on the same glass
--
-- The HUDs got frosted panels because black glyphs on grass are not readable.
-- The text box had the opposite problem and the same cause: an opaque white
-- slab over the bottom third of the diorama, which was the field's own colour
-- back when the field was white. The rects here are what the glass is cut to,
-- and they are a READ-ONLY mirror of drawTextArea's own branches -- so this is
-- where a future engine that moves a box says so.
do
local rects = Battles.textRects({ phase = "messages" })
T.check(rects.box ~= nil, "there is always a box: drawTextArea opens with one")
T.eq(rects.box[2] + rects.box[4], 144,
  "and it reaches the bottom of the frame")
T.eq(rects.box[3], 160, "full width, like Font.drawBox(0, 12, 20, 6)")
T.eq(rects.box[2], 96, "starting on the row the player's mon stands on")

-- the menu the player picks FIGHT on is that same box, so nothing is added
T.eq(Battles.textRects({ phase = "menu" }).moves, nil,
  "the battle menu draws inside the box already there")

-- the two phases that put a SECOND box above it get a second panel, trimmed
-- to the rows above the first: two panels over the same pixels would frost it
-- twice and leave a step along the seam
for _, phase in ipairs({ "moveSelect", "mimicSelect" }) do
  local more = Battles.textRects({ phase = phase })
  local extra = more.moves or more.mimic
  T.check(extra ~= nil, phase .. " raises a box of its own, and it is frosted")
  T.eq(extra[2] + extra[4], more.box[2],
    "which stops exactly where the box below it starts, so they never overlap")
  T.check(extra[1] >= 0 and extra[1] + extra[3] <= 160 and extra[2] >= 0,
    "and stays inside the frame the battle is drawn in")
end

-- AskName blanks the field on purpose -- the nickname prompt is meant to sit
-- on nothing -- so there is no box and no glass under one
T.eq(next(Battles.textRects({ phase = "menu", blankForAskName = true })), nil,
  "the nickname prompt's blank field gets no glass")
T.eq(next(Battles.textRects(nil)), nil, "and no battle, no boxes")
end

-- ------- BACK: the player's own mon stays on the menu
--
-- The staged shot stands both mons on the map, which costs the framing Gen 1
-- is most recognisable by: your own Pokemon seen from behind, sitting on the
-- battle menu. BACK SPRITES hands that back without giving up the fight on the map --
-- the foe is still geometry on its own tile.
do
T.eq(Battles.backSetting:get(), false,
  "BACK SPRITES is off by default: both mons out on the map is what the mode is")
T.eq(Battles.backPinned(), false, "so nothing is pinned to the menu")

local backGame = { save = { options = { modOptions = {} } },
                   mods = { modOptions = {} } }
Battles.setting:setValue(true, backGame)           -- 3D-BTL on 2D-3D
Battles.backSetting:setIndex(2, backGame)          -- BACK SPRITES on
T.eq(Battles.backPinned(), true, "switched on, the back pic is pinned")
T.eq(backGame.save.options.modOptions.DRAMATIC_SHAPE.battleBack, true,
  "and it persists on its own key, beside 3D-BTL rather than over it")
T.eq(backGame.save.options.modOptions.DRAMATIC_SHAPE.battles, true,
  "which is still where it always was")

-- and it means nothing at all with staged battles off: there is no staged
-- shot for a back pic to be pinned in front of, and the engine's own battle
-- screen already draws exactly this
Battles.setting:setValue(false, backGame)
T.eq(Battles.backPinned(), false,
  "with 3D-BTL off the setting decides nothing, whatever it is left at")
T.eq(Battles.backSetting:get(), true, "without being rewritten underneath")

-- ...so the row comes off the menu with it, on the same reasoning the mod's
-- other absent rows come off: a row that no longer decides anything is worse
-- than no row
local offRows = Menus.rows("battles", backGame)
T.check(offRows["DRAMATIC_SHAPE:battles"], "3D-BTL itself is still offered")
T.check(not offRows["DRAMATIC_SHAPE:battleBack"],
  "but BACK SPRITES is off the menu while there is no staged fight to be about")

Battles.setting:setValue(true, backGame)
-- switched back on it returns, and to the BATTLES menu -- the one the switch
-- it depends on is on, so the two are read together
local onAt = {}
for i, row in ipairs(Menus.lib.rows("battles", backGame)) do onAt[row.id] = i end
T.check(onAt["DRAMATIC_SHAPE:battleBack"], "switched back on, so is the row")
T.eq(onAt["DRAMATIC_SHAPE:battleBack"] - onAt["DRAMATIC_SHAPE:battles"], 1,
  "directly under the row it belongs to")

-- ------- and which pic is the pinned one is asked with the other side BLANKED
--
-- picImage asks this so BattlePics knows whether a pic's feet are on the text
-- box -- where its bottom edge seals, and its belly stops being see-through --
-- and it is asked DURING the billboard render, inside which sideTexture has
-- switched the side it is not drawing off by setting the field to FALSE rather
-- than to nil (see OFF).
--
-- So the read has to be by truthiness. A test against nil passes that `false`
-- through to the index below it, the error comes back out of sideTexture into
-- the pcall that calls it, textures() reports no card for the side -- and the
-- foe is simply not on the field. Which is the whole bug: fixing the player's
-- back pic took the enemy's billboard out.
local mine, theirs = {}, {}
local live = { player = { sprite = mine }, enemy = { sprite = theirs } }
T.eq(Battles.pinnedPic(live, mine), true,
  "the player's own mon is the pic on the box")
T.eq(Battles.pinnedPic(live, theirs), false,
  "and the foe is geometry out on the map, whatever the mode")
T.eq(Battles.pinnedPic({ player = false, enemy = { sprite = theirs } }, theirs),
  false, "asking about the foe while the player is blanked answers, not throws")
T.eq(Battles.pinnedPic({ playerBackPic = mine }, mine), true,
  "the trainer back holds the slot until Go!, on the box like the mon")
T.eq(Battles.pinnedPic({ player = false, playerBackPic = false }, mine), false,
  "and with the side blanked outright nothing of it is pinned")

Battles.backSetting:setIndex(1, backGame)          -- and off for the rows below
T.eq(Battles.pinnedPic(live, mine), false,
  "with BACK SPRITES off the player's mon is out on the map with the foe")
end

-- ------- the hour reaches the FLAT world too
--
-- The clock reaches the diorama through the voxel shader's tint uniform, which
-- the 2D tile path never runs. With the mode off the same evening left the flat
-- world at permanent noon.
--
-- The fix is one multiplied rectangle, and the whole difficulty is WHERE. Not
-- on the world canvas -- in a colorized mode that is grayscale art the palette
-- shader classifies by RED CHANNEL, so tinting first would move every pixel
-- into the wrong shade bucket rather than darkening it. Not over the finished
-- frame either, or the dialog boxes darken with the world they are held up in
-- front of. Between the two, which is the one instant with no engine seam in
-- it -- worldPresent only runs when a pipeline drew the world, which in flat
-- mode is exactly what did not happen.
--
-- So the boundary is found by identity: `blit` passes the canvas it is
-- compositing as the first argument, so the first draw of the renderer's UI
-- canvas IS the moment the world is finished and the paper has not started.
-- That is what this drives -- the gates, and the ordering.
do
local DayTint = run.loader.exports.DRAMATIC_SHAPE.lib.require("DayTint")
local DayNight = run.loader.exports.DRAMATIC_SHAPE.lib.require("DayNight")

-- the map the hour is asked about is the one the player is standing on, read
-- off the live game rather than passed in -- so there has to be one
local Game = require("src.core.Game")
local owWas = Game.overworld
Game.overworld = { map = { id = "ROUTE_1", def = { tileset = "OVERWORLD" } } }

-- ------- the gates
--
-- A frame with a pipeline's world image in it was tinted inside that
-- pipeline's own shader; painting again would apply the hour twice.
DayNight.setting:sync("night")
T.check(DayTint.forFrame({ worldActive = true, worldOverride = {} }) == nil,
  "a frame a render pipeline drew is left alone -- it tinted itself")
T.check(DayTint.forFrame({ worldActive = false }) == nil,
  "and so is a frame with no world in it at all, like a menu over nothing")
T.check(DayTint.forFrame(nil) == nil, "and no renderer, no tint")

-- midday is a multiply by white, so it is skipped rather than drawn: a game
-- with the clock at DAY issues not one extra call
DayNight.setting:sync("day")
T.check(DayTint.forFrame({ worldActive = true }) == nil,
  "at midday the tint is white, so nothing is painted")

-- and a room has no sky to take its light from, which is the same answer
-- DayNight.tint gives on its own and the same one applyRig gives the sun
DayNight.setting:sync("night")
T.check(DayTint.forFrame({ worldActive = true }) ~= nil,
  "at night, outdoors, there is a tint to paint")
Game.overworld = { map = { id = "OAKS_LAB", def = { tileset = "HOUSE" } } }
T.check(DayTint.forFrame({ worldActive = true }) == nil,
  "but indoors the hour does not reach the floor")
Game.overworld = { map = { id = "ROUTE_1", def = { tileset = "OVERWORLD" } } }

-- ------- and the ordering, driven through the real wrap
--
-- A stand-in renderer whose endFrame issues the two draws the real one does,
-- in the real order: the world canvas, then the UI canvas.
DayNight.setting:sync("night")
local Renderer = require("src.render.Renderer")
local realEnd, realHook = Renderer.endFrame, Renderer.dramaticShapeTintHook
local log = {}
local uiCanvas, worldPixels = { "the UI canvas" }, { "the world canvas" }
Renderer.dramaticShapeTintHook = nil
Renderer.endFrame = function(self)
  log[#log + 1] = "world"
  love.graphics.draw(worldPixels, 0, 0)
  log[#log + 1] = "ui"
  love.graphics.draw(self.canvas, 0, 0)
  love.graphics.draw(self.canvas, 0, 0)   -- a second SGB zone's quad
end
DayTint.install()

local realRect = love.graphics.rectangle
love.graphics.rectangle = function(...)
  log[#log + 1] = "tint"
  return realRect(...)
end
Renderer.endFrame({ canvas = uiCanvas, worldActive = true, map = true })
love.graphics.rectangle = realRect

T.eq(table.concat(log, ","), "world,ui,tint",
  "the tint lands after the world is composited and before the UI blit draws")
local painted = 0
for _, step in ipairs(log) do if step == "tint" then painted = painted + 1 end end
T.eq(painted, 1,
  "once, not once per SGB zone quad the UI blit issues")

-- a frame the gates decline must not leave the shim installed on love.graphics
local drawWas = love.graphics.draw
Renderer.endFrame({ canvas = uiCanvas, worldActive = true, worldOverride = {} })
T.eq(love.graphics.draw, drawWas,
  "a declined frame does not leave a wrapper on love.graphics.draw")

Renderer.endFrame, Renderer.dramaticShapeTintHook = realEnd, realHook
Game.overworld = owWas
DayNight.setting:sync("sync")
end

-- ------- and a pinned back pic is not a stencil
--
-- Gen 1 battle pics are two-bit art whose lightest shade is WHITE, and the
-- decoded PNGs key that shade to alpha 0 -- free on a white field, a hole with
-- the world showing through over a route. BattlePics puts the paper back.
--
-- It does that by flooding the background INWARD and filling whatever the
-- background cannot reach. Started at the image border that finds nothing at
-- all -- a Gen 1 figure is an open drawing, and its belly walks out between
-- two legs and off the bottom of the frame -- so every mon was a stencil.
--
-- So the flood starts at the edges of the ARTWORK'S OWN BOX, and at three of
-- them: left, right and top. The bottom is closed, because it is not a side
-- the background is behind -- it is where the drawing was CUT. A pic is
-- bottom-aligned in its slot with the margin all at the top, so a mon's lowest
-- row is the last row it was given. Seed that cut and the background pours up
-- inside the figure, which was the channel of world showing through the middle
-- of a Clefairy.
--
-- Both halves are driven here, because getting one right at the other's
-- expense is exactly what went wrong twice: an earlier rule that filled
-- anything with ink to its left, right and above closed the channel and then
-- filled the notch between a Rattata's ears and the gap between its body and
-- its tail, which are background and have the drawing over them.
do
local BattlePics = run.loader.exports.DRAMATIC_SHAPE.lib.require("BattlePics")

-- Run one hand-drawn figure through the real BattlePics and hand back a
-- reader over what came out. The pic is faked at the readback seam, which is
-- the only thing between this and the pixels the engine would have blitted.
local lastCanvas = nil                  -- what the readback asked newCanvas for
-- '#' is ink and '.' the keyed-out nothing. 'W' is ink too, of the pic's
-- LIGHTEST shade -- a highlight the decoder happened not to key -- which is
-- what the paper a hole gets filled with is read off.
local SHADE = { ["#"] = 0.25, ["W"] = 0.75 }
-- reuse hands the SAME pic back through, which is how the two bottom rules
-- can be asked of one image the way a running battle would ask them
local function fill(rows, sealBottom, reuse)
  local W, H = #rows[1], #rows
  local built = nil
  local function fakeData()
    local px, sh = {}, {}
    for y = 0, H - 1 do
      for x = 0, W - 1 do
        local shade = SHADE[rows[y + 1]:sub(x + 1, x + 1)]
        px[y * W + x] = shade and 1 or 0
        sh[y * W + x] = shade or 0
      end
    end
    return {
      px = px, sh = sh,
      getDimensions = function() return W, H end,
      getPixel = function(self, x, y)
        local k = y * W + x
        return self.sh[k], self.sh[k], self.sh[k], self.px[k]
      end,
      setPixel = function(self, x, y, r, g, b, a)
        self.px[y * W + x] = a
        self.sh[y * W + x] = r
      end,
    }
  end

  local realNewCanvas, realNewImage = love.graphics.newCanvas, love.graphics.newImage
  love.graphics.newCanvas = function(cw, ch, opts)
    lastCanvas = { w = cw, h = ch, opts = opts }
    return { setFilter = function() end, release = function() end,
             newImageData = fakeData }
  end
  love.graphics.newImage = function(data)
    built = data
    return { setFilter = function() end }
  end
  local pic = reuse or { getDimensions = function() return W, H end }
  local out = BattlePics.filled(pic, sealBottom)
  love.graphics.newCanvas, love.graphics.newImage = realNewCanvas, realNewImage
  -- deliberately NOT invalidated: each figure brings its own pic, and the
  -- cache check at the bottom needs one of them still in there
  return out, pic,
         built and function(x, y) return built.px[y * W + x] > 0.5 end,
         built and function(x, y) return built.sh[y * W + x] end
end

-- ------- the cut at the feet, which is what the closed bottom edge is for
local out, pic, opaque = fill({
  "..#..#..",   -- two ears, with sky between them
  "..#..#..",
  "..####..",   -- and the head closing under them
  ".#....#.",   -- belly: nothing under it but the edge the drawing stops at
  ".#....#.",
  ".#....#.",
  ".#.##.#.",   -- legs, with the gap between them running down to that edge
  ".#.##.#.",
})
T.check(out ~= pic and opaque, "the pic comes back rebuilt: there was paper to put back")

T.check(opaque(2, 3) and opaque(3, 4) and opaque(5, 5),
  "the belly is filled edge to edge -- no channel of world down the middle")
T.check(opaque(2, 7),
  "and so is the notch between its legs, which the same cut runs through")

-- the sky between two ears reaches the top of the box, so it is background
T.check(not opaque(3, 0) and not opaque(4, 1),
  "the sky between its ears stays sky")
-- and everything outside the artwork's own box is never touched, which is what
-- keeps the silhouette cutting cleanly instead of standing in a white rectangle
T.check(not opaque(0, 0) and not opaque(7, 0), "the corners stay transparent")
T.check(not opaque(0, 4) and not opaque(7, 4), "and the columns beside it")

-- ------- and a pocket that drains out to the SIDE is background, however
-- much of the drawing is over it
--
-- This is the regression the ray rule caused: ink to the left, ink to the
-- right, ink above, and still plainly the gap between a body and a tail.
-- Every transparent pixel in this one drains out through the notch at (2,3)
-- and away to the left, so NONE of it is paper -- and a pic with no paper to
-- put back is handed straight back, unrebuilt. That identity IS the assertion:
-- under the ray rule this figure came back rebuilt with the pocket filled in.
local gapOut, gapPic = fill({
  "..#####.",   -- a brow, with the drawing over the pocket
  "..#...#.",
  "..#...#.",
  "....###.",   -- which opens at the left, and drains out that way
  "..#####.",
  "..#####.",
})
T.eq(gapOut, gapPic,
  "a pocket the background can walk into from the side is not paper")

-- ------- and neither is a wide MOUTH along the bottom
--
-- Two things meet the underside of a figure. A DRAIN is where the drawing ran
-- out -- a belly leaking through the inch between a body and a leg -- and is
-- sealed. A MOUTH is the space between two legs, background that happens to be
-- enclosed on three sides, and is left open so the world shows through a
-- trainer's stride. Width tells them apart, and on this game's art the drains
-- run 3-4 pixels and the mouths 10-17, so BattlePics.DRAIN sits at 6.
--
-- This figure's stride is eight wide, so nothing in it is paper and it comes
-- back unrebuilt -- the identity again.
local strideOut, stridePic = fill({
  "..##############..",
  "..##############..",
  "..##############..",
  "..###........###..",   -- a stride eight wide, past the drain cut
  "..###........###..",
  "..###........###..",
})
T.eq(strideOut, stridePic,
  "the world shows through the gap between a trainer's legs")

-- the same figure with a two-pixel gap IS a drain, and fills
local drainOut, drainPic, drain = fill({
  "..##############..",
  "..##############..",
  "..##############..",
  "..######..######..",   -- a belly running out, not a stride
  "..######..######..",
  "..######..######..",
})
T.check(drainOut ~= drainPic and drain and drain(8, 4),
  "a narrow one is where the drawing ran out, and is paper")

-- ------- but a pic ON THE MENU has no mouth at all
--
-- The drain/mouth cut is for a pic standing on the MAP, where a wide opening
-- along the bottom is a stride with real ground behind it. Under BACK SPRITES
-- the player's mon is drawn in the GB's own slot with its feet flush on the
-- text box, and the only thing under its lowest row is white box -- so nothing
-- reaches it from below, whatever the opening's width, and the rule stops
-- being a heuristic: paper is whatever the background cannot walk to from the
-- left, the right or the top.
--
-- Which is the difference between a Pikachu and a wireframe. The pale-bodied
-- back pics -- Pikachu, Seel, Dewgong, Chansey, Jigglypuff -- are drawn as
-- OUTLINES, every shade-0 pixel inside the ink keyed away, and each of them
-- leaks out through a bottom opening far too wide to read as a drain. On the
-- map that reading is right; on the box it left the mon a rim with the arena
-- showing through it.
--
-- The same stride figure the map rule leaves open, now standing on the box.
local boxOut, boxPic, boxOpaque = fill({
  "..##############..",
  "..##############..",
  "..##############..",
  "..###........###..",
  "..###........###..",
  "..###........###..",
}, true)
T.check(boxOut ~= boxPic and boxOpaque,
  "the gap a stride would have shown the world through is paper on the box")
T.check(boxOpaque(8, 3) and boxOpaque(8, 5),
  "and it fills right down to the row the feet are on")

-- the seal is the BOTTOM alone: the sides and the top still let the background
-- in, which is what keeps the silhouette cutting against the arena instead of
-- standing the mon in a white block
local boxGapOut, boxGapPic = fill({
  "..#####.",
  "..#...#.",
  "..#...#.",
  "....###.",   -- opens at the left, and drains out that way
  "..#####.",
  "..#####.",
}, true)
T.eq(boxGapOut, boxGapPic,
  "a pocket that drains out to the side is background on the box too")

-- ------- and a hole is filled with the pic's OWN paper, not with white
--
-- Shade 0 is white only while the pic is still grays, and by the time one
-- reaches here it usually is not: picImage hands it over after the bake -- a
-- species SGB colour, a BGP fade mid-animation, PAL_BLACK across the whole
-- screen while the blackout text is up -- and shade 0 travels with the rest.
-- A hardcoded white belly would be the one lit thing on a blacked-out mon.
--
-- So the paper is read off the pic: the lightest shade still standing in it,
-- which is shade 0 wherever the decoder could not reach one. It never has to
-- guess -- all 151 of this game's back pics keep at least one, an eye or a
-- highlight down a cheek.
local _, _, _, paperShade = fill({
  "..####..",
  "..#WW#..",   -- a highlight the decoder did not key: this is the paper
  "..#..#..",
  "..#..#..",
  "..####..",
})
T.eq(paperShade(3, 2), paperShade(3, 1),
  "the hole takes the lightest shade the pic still has")
T.check(paperShade(3, 2) ~= paperShade(2, 2),
  "which is not the ink beside it")

-- ------- and the readback is measured in PIXELS, which is what kept the mons
-- the size of the squares they stand on
--
-- love.graphics.newCanvas takes the SURFACE's dpi scale when it is not told
-- otherwise, conf.lua turns highdpi on for Android and iOS, and Android's
-- density is routinely 2.75. So an untold newCanvas(56, 56) allocated a
-- 154x154 texture on a phone, the pic was magnified into it, and newImageData
-- read the magnified copy back at its own size -- an image 2.75x the artwork,
-- which drawPicsLayer then drew at 1:1 because it trusts getWidth(). The mon
-- stood on the map three times the size of its tile.
--
-- Only for a pic with paper to put back, which is why it read as a bug in
-- particular Pokemon (a giant Pidgey beside a normal mon) rather than as a
-- scale that was wrong everywhere.
T.check(lastCanvas and lastCanvas.opts and lastCanvas.opts.dpiscale == 1,
  "the readback canvas is one texel per pic pixel, on a highdpi phone too")
T.eq(lastCanvas.w, 8, "and it is the size of the pic, in those pixels")

-- the answer is cached on the image, so a pic costs one readback a session
-- rather than one a frame -- checked on the first figure, which is still in
-- there because fill() does not clear it
T.eq(BattlePics.filled(pic), out, "the rebuilt pic is cached on the original")
-- and cached PER BOTTOM RULE, because one image answers differently on the map
-- and on the box. A single table for both would hand whichever caller asked
-- second the other one's answer -- the map's stencil to the menu, or a menu
-- fill to a mon standing on grass -- which is this section's bug arriving
-- through the cache rather than through the flood.
--
-- The stride figure again, on the SAME pic the map rule already answered for.
local reOut = fill({
  "..##############..",
  "..##############..",
  "..##############..",
  "..###........###..",
  "..###........###..",
  "..###........###..",
}, true, stridePic)
T.check(reOut ~= stridePic,
  "the pic the map left open still fills when the box asks for it")
T.eq(BattlePics.filled(stridePic), stridePic,
  "and the map's own answer for it is still the pic itself")
BattlePics.invalidate()
end

-- ------- the way out of a battle is a fade, not a cut
--
-- The engine wipes INTO a battle and cuts straight out of it. While voxel mode
-- is on that cut is between a placed camera looking across an arena and a
-- diorama looking down on a walking player, so the battle fades out, closes
-- behind the black, and the map fades up.
--
-- The pop ORDER is the part that has to be right: BattleState:finish pops
-- whatever is on top, which is the fade while it is up, so the fade has to be
-- off the stack before the battle finishes and back on it afterwards.
do
local Exit = run.loader.exports.DRAMATIC_SHAPE.lib.require("BattleExit")

T.eq(Data.transitions and Data.transitions[Exit.ID] and
     Data.transitions[Exit.ID].frames, Exit.FRAMES,
  "the fade's timing is a registered transitions record, retunable in data")

local function fakeStack(...)
  local s = { states = { ... } }
  function s:top() return self.states[#self.states] end
  function s:push(state) self.states[#self.states + 1] = state end
  function s:pop() return table.remove(self.states) end
  return s
end

-- headless has no depth buffer, so the real gate answers no on every rung;
-- pin it, which is what the seam is there for
local realModeOn = Exit.modeOn
Exit.modeOn = function() return true end

T.eq(Exit.wanted(nil), false, "no battle, no fade")
T.eq(Exit.wanted({ game = { stack = {} } }), true, "a battle in voxel mode fades")
T.eq(Exit.wanted({ game = { stack = {} }, payDay = 100, result = "win" }), false,
  "but not on an unpaid PAY DAY -- that finish() prints a message and comes "
  .. "back, so the fade belongs to the call that really leaves")
Exit.modeOn = function() return false end
T.eq(Exit.wanted({ game = { stack = {} } }), false,
  "and with voxel mode off the battle keeps the cut it always had")
Exit.modeOn = function() return true end

local exitOw = { isOverworld = true }
local exitGame = { data = Data, overworld = exitOw }
local exitBattle = { game = exitGame }
exitGame.stack = fakeStack(exitOw, exitBattle)

local finished = 0
local fade = Exit.start(exitBattle, function()
  finished = finished + 1
  exitGame.stack:pop()          -- what BattleState:finish does: pops itself
end)
T.eq(exitGame.stack:top(), fade, "the fade goes on top of the battle it closes")
T.eq(Exit.veil(), 0, "and starts on the battle's own last live frame")

for _ = 1, fade.frames - 1 do fade:update() end
T.check(Exit.veil() > 0.5, "the veil climbs while the battle is still up")
T.eq(exitGame.stack:top(), fade, "which is a frozen battle: the fade is on top")
T.eq(finished, 0, "and nothing has finished yet")

fade:update()                    -- the frame the cut lands on
T.eq(finished, 1, "at full black the battle finishes for real")
T.eq(Exit.veil(), 1, "with the screen fully black over the swap")
T.eq(#exitGame.stack.states, 2, "the battle left the stack")
T.eq(exitGame.stack.states[1], exitOw, "the map is under it")
T.eq(exitGame.stack:top(), fade,
  "and the fade went back on top of the map to bring it up")

for _ = 1, fade.frames - 1 do fade:update() end
T.check(Exit.veil() < 0.5, "the veil falls away over the map")
fade:update()
T.eq(Exit.veil(), nil, "and the fade is done -- no veil left on the screen")
T.eq(exitGame.stack:top(), exitOw, "with the map back on top, playable")
T.eq(finished, 1, "the battle finished exactly once")

-- ------- a blackout (or an evolution prompt) owns the way out itself
--
-- Those push their own transition on the way through onFinish, so this fade
-- stops at the cut rather than fading in over the top of somebody else's.
local other = { isSomeoneElse = true }
local blackout = { game = exitGame }
exitGame.stack = fakeStack(exitOw, blackout)
local warpFade = Exit.start(blackout, function()
  exitGame.stack:pop()                     -- the battle leaves
  exitGame.stack:push(other)               -- and a warp fade takes the screen
end)
for _ = 1, warpFade.frames do warpFade:update() end
T.eq(exitGame.stack:top(), other, "the state that took over is on top")
T.eq(Exit.veil(), nil, "and this fade let go of the screen at the cut")
T.eq(blackout.dramaticShapeLeaving, nil,
  "with the flag cleared, so a finish() that really leaves fades again")

-- ------- a stack cleared from under a fade cannot black the game out
--
-- A script (or the shot driver) pops down to the overworld without asking. The
-- fade is gone, so the veil has to go with it -- nothing is left to fade it in.
exitGame.stack = fakeStack(exitOw, exitBattle)
local orphan = Exit.start(exitBattle, function() end)
orphan:update()
T.check(Exit.veil() > 0, "a live fade veils the frame")
while exitGame.stack:top() ~= exitOw do exitGame.stack:pop() end
T.eq(Exit.veil(), nil, "and a fade popped from under itself veils nothing")

Exit.modeOn = realModeOn
end

-- ------- the day/night cycle
--
-- One twenty-minute clock, and everything is a pure function of it: the
-- pinned DAYTIME settings are fixed times on the dial, CYCLE lets it run,
-- and the sun, the moon, the shadows, the sky and the tint all read the same
-- number. What is checked here is the dial itself, the noon-exactness pledge
-- (DAY is the mod's existing sun, to the digit), the arcs' visibility (the
-- camera looks north, so the discs must actually cross the northern sky),
-- and the clock's ride through the save file.
do
local DayNight = run.loader.exports.DRAMATIC_SHAPE.lib.require("DayNight")
local ShadowMap = run.loader.exports.DRAMATIC_SHAPE.lib.require("ShadowMap")
local Voxel3D = run.loader.exports.DRAMATIC_SHAPE.lib.require("Voxel3D")
local Voxel = run.loader.exports.DRAMATIC_SHAPE.lib.require("VoxelState")

-- the dial and its pins
T.eq(DayNight.setting.values[1], "sync",
  "no value set means SYNC: values[1] is the row's contract default, and "
  .. "it follows the machine's clock")
DayNight.setting:sync("day")
T.eq(DayNight.time(), 300, "and DAY is noon on the dial")
local PINS = { day = 300, night = 900, dusk = 600, dawn = 0 }
for name, t in pairs(PINS) do
  DayNight.setting:sync(name)
  T.eq(DayNight.time(), t, name .. " pins the clock to " .. t)
end

-- CYCLE picks up from the pin the player was just looking at
DayNight.setting:sync("dusk")
DayNight.update(0)
DayNight.setting:sync("cycle")
DayNight.update(0)
T.eq(DayNight.clock, 600, "stepping onto CYCLE picks up from the pin: dusk")
DayNight.update(30)
T.check(math.abs(DayNight.time() - 630) < 1e-9, "and the clock then runs")
DayNight.clock = 1195
DayNight.update(10)
T.check(math.abs(DayNight.clock - 5) < 1e-9,
  "the dial wraps at twenty minutes, back into dawn")

-- the sun: noon is the mod's existing sun, exactly
local kx, kz, moon = DayNight.shearAt(300)
T.check(not moon, "noon is the sun's")
T.check(math.abs(kx - (-0.85)) < 1e-9 and math.abs(kz - (-0.55)) < 1e-9,
  ("DAY throws the shadows the mod always threw: (%.4f, %.4f)"):format(kx, kz))
local kx0, kz0 = DayNight.shearAt(0)
T.check(math.abs(math.sqrt(kx0 * kx0 + kz0 * kz0) - DayNight.K_MAX) < 1e-9,
  "a rising sun throws a LONG shadow, clamped -- never an infinite one")
T.eq(DayNight.strengthAt(0), 0, "and at the horizon it presses nothing")
T.eq(DayNight.strengthAt(300), 1, "at noon it presses in full")

-- the moon: due north at mid-night, pressing softly south
local mkx, mkz, mmoon = DayNight.shearAt(900)
T.check(mmoon, "mid-night is the moon's")
T.check(math.abs(mkx) < 1e-9, "due north: no east-west drift at all")
T.check(math.abs(mkz - 1 / math.tan(math.rad(40))) < 1e-9,
  "shadows fall south, away from it, cot(40) long")

-- the palettes: pins land on their phase palette unmixed, blends stay on
-- the 5-bit lattice
local function palEq(a, b)
  for i = 1, #a do
    for ch = 1, 3 do if a[i][ch] ~= b[i][ch] then return false end end
  end
  return #a == #b
end
T.check(palEq(DayNight.palette(300), DayNight.PALETTES.day),
  "noon paints the day palette, unmixed")
T.check(palEq(DayNight.palette(600), DayNight.PALETTES.dusk),
  "the dusk pin paints dusk proper -- the blend is centred on it, not over it")
T.check(palEq(DayNight.palette(0), DayNight.PALETTES.dawn),
  "and dawn's pin paints dawn")
local mid = DayNight.palette(562)         -- halfway through day -> dusk
for i, c in ipairs(mid) do
  T.check(c[1] % 8 == 0 and c[2] % 8 == 0 and c[3] % 8 == 0,
    "blended band " .. i .. " is re-quantised onto the GBC lattice")
end
T.check(mid[1][3] < DayNight.PALETTES.day[1][3]
        and mid[1][3] > DayNight.PALETTES.dusk[1][3],
  "and sits between the two phases it blends")
-- day's blue horizon and dusk's gold one are near-complements, and a
-- straight lerp between complements bottoms out in grey -- so the evening
-- path bends through the golden-hour waypoint, and halfway down the blend
-- the horizon band must already be WARM
T.check(mid[1][1] > mid[1][3],
  "mid-evening the horizon is gold, not the grey between blue and gold")
-- and the far side of sunset bends through violet the same way: halfway
-- from dusk to night the horizon is rose, not the taupe between gold and navy
local ev = DayNight.palette(645)[1]
T.check(ev[1] > ev[2] and ev[3] > ev[2],
  "mid-fall of night the horizon is violet-rose, not grey")
T.eq(DayNight.palette(300), DayNight.palette(300.4),
  "the palette is memoised within the second, not rebuilt per frame")

-- the tint: noon is neutral, night is dim and blue, indoors is always noon
local tn = DayNight.tint(true, 900)
T.check(tn[1] < 1 and tn[3] > tn[1], "night light is dim and leans blue")
T.eq(DayNight.tint(true, 300)[1], 1, "noon multiplies by one")
T.eq(DayNight.tint(false, 900)[1], 1,
  "a cave at midnight is exactly as dark as a cave at noon: neutral indoors")

-- the twilight glow: gold at the sun's horizons, never for the moon
local amt, gc = DayNight.glow(600)
T.check(math.abs(amt - 1) < 1e-9, "dusk glows in full")
T.check(gc[1] > gc[3], "and warm: more red than blue")
T.eq((DayNight.glow(300)), 0, "noon does not glow")
T.eq((DayNight.glow(900)), 0, "and the moon rises silver, not gold")

-- the discs cross the sky the camera can actually see
Voxel.angle = math.rad(75)
Voxel3D.camera = nil
Voxel3D.vp = Voxel3D.viewProjection(0, 0, 320, 288)
local horizon = Voxel3D.horizonY(288)

DayNight.setting:sync("night")
local mb = Voxel3D.skyBody(320, 288)
T.check(mb and mb.moon, "at the NIGHT pin the moon is in frame")
T.check(math.abs(mb.x - 160) < 8,
  ("due north is screen centre: got x %.1f"):format(mb.x))
T.check(mb.y > 0 and mb.y < horizon,
  ("hanging above the horizon point: y %.1f vs %.1f"):format(mb.y, horizon))

DayNight.setting:sync("day")
T.eq(Voxel3D.skyBody(320, 288), nil,
  "the noon sun is overhead behind the camera -- correctly not in frame")

DayNight.setting:sync("dawn")
local db = Voxel3D.skyBody(320, 288)
T.check(db and not db.moon, "at the DAWN pin the rising sun is in frame")
T.check(db.x > 160 and db.x < 320,
  ("north of east is screen right: got x %.1f"):format(db.x))
T.check(math.abs(db.y - horizon) < 2,
  "standing on the horizon point, half-risen")
T.check(db.glowAmt > 0.9, "and wrapped in the dawn glow")

DayNight.setting:sync("dusk")
local sb = Voxel3D.skyBody(320, 288)
T.check(sb and sb.x < 160, "the DUSK sun sets screen LEFT -- north of west")

-- the rig: outdoor follows the clock, indoor is pinned to noon
DayNight.setting:sync("night")
DayNight.applyRig(true)
T.check(math.abs(ShadowMap.KX - mkx) < 1e-9
        and math.abs(ShadowMap.KZ - mkz) < 1e-9,
  "outdoors at night the sun pass is lit by the moon")
T.check(math.abs(Voxel3D.SHADOW_ALPHA - DayNight.ALPHA_MOON) < 1e-9,
  "at the moon's own softer weight")
DayNight.applyRig(false)
T.check(math.abs(ShadowMap.KX - (-0.85)) < 1e-9
        and math.abs(ShadowMap.KZ - (-0.55)) < 1e-9,
  "indoors the rig stays the mod's noon sun, whatever the clock says")
T.check(math.abs(Voxel3D.SHADOW_ALPHA - DayNight.ALPHA_SUN) < 1e-9,
  "at the weight it always had")
T.eq(DayNight.shadowScale(false), 1, "an indoor arena keeps its full shadows")
T.check(math.abs(DayNight.shadowScale(true, 900)
                 - DayNight.ALPHA_MOON / DayNight.ALPHA_SUN) < 1e-9,
  "an outdoor arena under the moon presses at the moon's ratio")
T.check(DayNight.shadowScale(true, 600) < 1e-9,
  "and a sunset takes the arena's shadows with it")

-- the engine's own vocabulary, for map.palette and music.select
T.eq(DayNight.tod(300), "DAY", "noon is DAY")
T.eq(DayNight.tod(900), "NIGHT", "mid-night is NIGHT")
T.eq(DayNight.tod(0), "MORNING", "dawn is MORNING")
T.eq(DayNight.tod(600), "EVENING", "dusk is EVENING")

-- the clock rides the save slot
local modApi = run.loader.exports.DRAMATIC_SHAPE.lib.mod
DayNight.setting:sync("cycle")
DayNight.clock = 777
DayNight.store()
DayNight.clock = 5
DayNight.restore()
T.eq(DayNight.clock, 777, "the clock survives the round trip through mod.save")
modApi.save:set(DayNight.SAVE_KEY, nil)
DayNight.restore()
T.eq(DayNight.clock, 300, "a save with no clock in it starts at day")

-- SYNC lays the machine's own clock onto the dial: local noon is the DAY
-- pin, midnight is NIGHT, six and eighteen the twilights
local hoursWas = DayNight.hours
DayNight.setting:sync("sync")
DayNight.hours = function() return 12 end
T.eq(DayNight.time(), 300, "local noon is the DAY pin")
DayNight.hours = function() return 18 end
T.eq(DayNight.time(), 600, "six in the evening is DUSK")
DayNight.hours = function() return 0 end
T.eq(DayNight.time(), 900, "midnight is mid-night")
DayNight.hours = function() return 6.5 end
T.check(math.abs(DayNight.time() - 25) < 1e-9,
  "half past six in the morning is just after dawn")
-- and stepping from SYNC onto CYCLE picks up from the sky already showing
DayNight.update(0)
DayNight.setting:sync("cycle")
DayNight.update(0)
T.check(math.abs(DayNight.clock - 25) < 1e-9,
  "CYCLE picks up from wherever SYNC's sky already was")
DayNight.hours = hoursWas

-- arriving at FULL pins the sky to the clock on the wall
local Game = require("src.core.Game")
local hadSave = Game.save
Game.save = { options = {} }
DayNight.setting:sync("day")
defs.voxel.update(0, 2)               -- any rung that is not FULL
defs.voxel.update(0, 1)               -- and the arrival
T.eq(DayNight.setting:get(), "sync",
  "FULL pins DAYTIME to SYNC, whatever was chosen before")
Game.save = hadSave

-- put the room back the way it was found (SYNC is the shipped default)
DayNight.setting:sync("sync")
DayNight.clock = 300
DayNight.applyRig(false)
Voxel3D.tint = { 1, 1, 1 }
Voxel3D.vp = nil
end

-- ------- a scripted fight wipes in like a walked-into one
--
-- An engine seam this mod leans on: Commands.start_battle used to push the
-- BattleState bare, so the rival in Oak's lab CUT to battle with no
-- transition -- no flash, no wipe, the theme starting late. It now routes
-- through the overworld's own pushBattle, the same path a grass encounter
-- takes (and the path this mod wraps to stage the arena before the wipe).
do
local Commands = require("src.script.Commands")
local realBS = package.loaded["src.battle.BattleState"]
package.loaded["src.battle.BattleState"] = {
  newWild = function() return { kind = "wild" } end,
  newTrainer = function() return { kind = "trainer" } end,
}
local pushed, viaOverworld = nil, nil
local runner = { yield = function() end, resume = function() end }
local ctx = {
  runner = runner,
  game = { stack = { push = function(_, s) pushed = s end } },
  overworld = {
    pushBattle = function(_, b) viaOverworld = b end,
    afterBattle = function() end,
  },
}
Commands.start_battle(ctx, "trainer", "RIVAL1", 1)
T.check(viaOverworld ~= nil and pushed == nil,
  "a scripted trainer goes through pushBattle: the flash, the wipe and the "
  .. "theme, like any fight walked into")
-- guarded index: when the seam above regresses, this must FAIL like any
-- assertion rather than crash the suite half-run
T.eq(viaOverworld and viaOverworld.kind, "trainer",
  "with the battle it was asked to start")
ctx.overworld = nil
Commands.start_battle(ctx, "wild", "PIDGEY", 5)
T.check(pushed ~= nil,
  "and a battle scripted with no overworld under it still starts bare")
package.loaded["src.battle.BattleState"] = realBS
end

-- ------- night falls in the forest
--
-- Viridian Forest is not outdoor (no sky, and the light through the leaves
-- has no direction to swing) and not a sealed room either. Of everything
-- the clock does, exactly one thing reaches a canopy map: the hour's tint.
-- The scenes wire it as tint(outdoor or isCanopy(map)) over the unchanged
-- noon rig, so what is checked here is the classification itself.
do
local DayNight = run.loader.exports.DRAMATIC_SHAPE.lib.require("DayNight")
T.check(DayNight.isCanopy({ id = "VIRIDIAN_FOREST" }),
  "Viridian Forest stands under a canopy")
T.check(not DayNight.isCanopy({ id = "MT_MOON_1F" }),
  "a cave does not -- midnight there is exactly as dark as noon")
T.check(not DayNight.isCanopy({ id = "PALLET_TOWN" }),
  "and an outdoor town is already the clock's in full")
T.check(not DayNight.isCanopy(nil), "no map, no canopy")
end

-- ------- the air under the canopy
--
-- ForestAtmos hangs an INVISIBLE canopy above the forest's real trees and
-- lets light down through it: fog for the scene shader, a volumetric
-- march for the beams (GPU-only, not checkable here), colour and strength
-- following the clock. Everything checkable without a GPU is checked:
-- the authored table, the hour's ramp, and the seeded particle deal --
-- which must come out identical on every visit.
do
local ForestAtmos =
  run.loader.exports.DRAMATIC_SHAPE.lib.require("ForestAtmos")
local DayNight = run.loader.exports.DRAMATIC_SHAPE.lib.require("DayNight")

-- the authored table
local cfg = ForestAtmos.configFor("VIRIDIAN_FOREST")
T.check(cfg ~= nil, "Viridian Forest has an atmosphere entry")
T.check(cfg and (cfg.canopyY or 0) > 32,
  "whose invisible canopy hangs ABOVE the carved tree hulls (y = 32) -- "
  .. "a ray is alpha zero at the canopy and only fades in below it")
T.check(ForestAtmos.configFor("PALLET_TOWN") == nil,
  "a map without an entry has no atmosphere at all")
T.check(ForestAtmos.configFor(nil) == nil, "and no map id does not crash")

-- the hour's ramp: gold spears by day, silver rays by night, both dying
-- back through the twilight handover
local fmap = { id = "VIRIDIAN_FOREST" }
local day = ForestAtmos.frame(fmap, DayNight.T.day)
local night = ForestAtmos.frame(fmap, DayNight.T.night)
local dusk = ForestAtmos.frame(fmap, DayNight.T.dusk)
T.check(day and night and dusk, "the forest answers at every pin")
T.check(day.rayColor[1] > day.rayColor[3],
  "the day's rays are sun-gold: more red than blue")
T.check(night.rayColor[3] > night.rayColor[1],
  "the night's are moon-silver: more blue than red")
T.check(dusk.rayAlpha < day.rayAlpha and dusk.rayAlpha < night.rayAlpha,
  "and the twilight is the dim handover between the two")
T.check(day.fog.density > 0 and night.fog.density > 0,
  "the haze never lifts entirely, day or night")
T.check(day.moteLevel > 0.5 and day.fireflyLevel < 0.05,
  "pollen drifts through the day's beams, with no fireflies out")
T.check(night.fireflyLevel > 0.5 and night.moteLevel < 0.05,
  "and the night shift trades them")

-- the seeded deal: the same particles on every visit (the beams place
-- themselves -- they are marched from the shadow map, not dealt)
local tcfg = { canopyY = 56, fadeTo = 28, seed = 77,
               motes = { count = 12 }, fireflies = { count = 6 } }
local a = ForestAtmos.layout(tcfg, 320, 320)
local b = ForestAtmos.layout(tcfg, 320, 320)
T.eq(#a.motes, 12, "the pollen musters at authored strength")
T.eq(#a.flies, 6, "the fireflies too")
local same = true
for i = 1, #a.motes do
  local m1, m2 = a.motes[i], b.motes[i]
  same = same and m1.x == m2.x and m1.y == m2.y and m1.z == m2.z
end
T.check(same, "and the deal comes out identical on every visit")
local under = true
for _, m in ipairs(a.motes) do
  if m.y >= tcfg.canopyY then under = false end
end
T.check(under, "everything drifts BELOW the canopy it lives under")

-- the tuning override, the same handle arena_editor holds on battles
ForestAtmos.setOverride("PALLET_TOWN", { canopyY = 40, fog = {} })
T.check(ForestAtmos.configFor("PALLET_TOWN") ~= nil,
  "an override stages an atmosphere a driver can tune live")
ForestAtmos.setOverride("VIRIDIAN_FOREST", false)
T.check(ForestAtmos.configFor("VIRIDIAN_FOREST") == nil,
  "false is meaningful: this map has none, whatever the file says")
ForestAtmos.setOverride("PALLET_TOWN", nil)
ForestAtmos.setOverride("VIRIDIAN_FOREST", nil)
T.check(ForestAtmos.configFor("VIRIDIAN_FOREST") ~= nil
        and ForestAtmos.configFor("PALLET_TOWN") == nil,
  "and nil hands both back to the authored table")

-- the row: OFF is the ladder's last rung and the frame answers nothing
T.eq(ForestAtmos.setting.values[1], "full",
  "the atmosphere defaults to FULL -- it costs a handful of quads and "
  .. "exists on one map")
ForestAtmos.setting:sync("off")
T.check(ForestAtmos.frame(fmap, DayNight.T.day) == nil,
  "OFF answers no frame at all: no fog uniform, no draw, no spend")
ForestAtmos.setting:sync("full")
end

-- ------- a shadow keeps hold of the feet that throw it
--
-- The depth compare forgives `slack` world pixels so lit ground does not
-- acne, and that forgiveness detaches a standing card's shadow from its
-- feet by the same amount -- worse the lower the sun. Cards are drawn into
-- the map snugged TOWARD the sun along their own ray -- which moves their
-- stored depth and nothing about where their shadow falls -- taking most of
-- the forgiveness back for the shadow they throw and for nothing else.
do
local ShadowMap = run.loader.exports.DRAMATIC_SHAPE.lib.require("ShadowMap")
local Mat4 = run.loader.exports.DRAMATIC_SHAPE.lib.require("Mat4")
local dir = ShadowMap.sunDir()
local s = -ShadowMap.slack * ShadowMap.SNUG
local m = ShadowMap.snug(nil)
T.check(math.abs(m[4] - dir[1] * s) < 1e-9
        and math.abs(m[8] - dir[2] * s) < 1e-9
        and math.abs(m[12] - dir[3] * s) < 1e-9,
  "snug() moves a caster toward the sun -- AGAINST the light's travel")
T.check(m[8] > 0, "which is upward: the sun is above the world it lights")
T.check(ShadowMap.SNUG < 1,
  "and takes back less than the whole forgiveness, so a card cannot land "
  .. "on the float-equality knife edge against its own stored depth")
local snugged = ShadowMap.snug(Mat4.translate(10, 0, 6))
T.check(math.abs(snugged[4] - (10 + dir[1] * s)) < 1e-9
        and math.abs(snugged[12] - (6 + dir[3] * s)) < 1e-9,
  "and composes over the caster's own transform, not instead of it")
end

-- ------- the glass in the windows
--
-- Panes are found by SHAPE in the tileset art -- a black border row, four
-- or five black-flanked glass rows, a closing border -- at pixel
-- granularity, because the door's pane straddles a 2x2 tile block and the
-- building's sits a row down inside its tile. The scan takes a pure reader,
-- so the geometry is checked here without an image in sight.
do
local GlassMask = run.loader.exports.DRAMATIC_SHAPE.lib.require("GlassMask")
local DayNight = run.loader.exports.DRAMATIC_SHAPE.lib.require("DayNight")
local Voxel3D = run.loader.exports.DRAMATIC_SHAPE.lib.require("Voxel3D")

local W, H = 32, 16
local blackAt = {}
local function paint(x, y) blackAt[y * W + x] = true end
local function pane(x0, y0, rows, hole)
  for c = 1, 6 do paint(x0 + c, y0); paint(x0 + c, y0 + rows + 1) end
  for r = 1, rows do
    paint(x0, y0 + r); paint(x0 + 7, y0 + r)
    if hole and r == 2 then paint(x0 + 3, y0 + r) end
  end
end
pane(8, 1, 5)              -- a building pane, one row down inside its tile
pane(20, 3, 4)             -- a door pane, straddling a tile row boundary
pane(0, 8, 5, true)        -- a near-miss: one black texel inside the glass

local function getPixel(x, y)
  if blackAt[y * W + x] then return 0, 0, 0 end
  return 0.66, 0.66, 0.66
end

local rects = GlassMask.scan(getPixel, W, H)
T.eq(#rects, 2, "the scan finds the two real panes and rejects the near-miss")
T.check(rects[1].x == 9 and rects[1].y == 2
        and rects[1].w == 6 and rects[1].h == 5,
  "the building pane's glass is the 6x5 interior, border excluded")
T.check(rects[2].x == 21 and rects[2].y == 4
        and rects[2].w == 6 and rects[2].h == 4,
  "the door pane's glass is the 6x4 interior, wherever it sits in the grid")

-- black is the BORDER black, not the art's dark grey rung
T.check(GlassMask._isBlack(0, 0, 0), "true black is border")
T.check(not GlassMask._isBlack(85 / 255, 85 / 255, 85 / 255),
  "the dark grey shade is not")

-- the lamps behind the glass follow the clock, not the sky's own light
T.eq(DayNight.windowLight(300), 0, "no lamps at noon")
T.eq(DayNight.windowLight(900), 1, "all of them at mid-night")
T.check(math.abs(DayNight.windowLight(600) - 0.7) < 1e-9,
  "they come on through dusk -- lit windows against the sunset")
T.check(DayNight.windowLight(645) > 0.9,
  "and are fully on by the fall of night")
T.check(math.abs(DayNight.windowLight(0) - 0.25) < 1e-9,
  "mostly out again by dawn")

-- the pass defaults to no glass at all until a scene says otherwise
T.eq(Voxel3D.glassMask, nil, "no mask bound by default")
T.eq(Voxel3D.glassNight, 0, "and the lamps off")

-- the glint is fed by TRAVEL, not by a clock: still camera, still glass
local g = {}
VoxelScene.glintStep(g, 100, 100)
T.eq(g.amp, 0, "the first frame establishes position and shows no sheen")
for i = 1, 12 do VoxelScene.glintStep(g, 100 + i, 100) end
T.eq(g.amp, 1, "a dozen frames of walking fades the glint fully in")
local held = g.phase
T.check(held > 0 and held < 2 * math.pi, "with the phase advanced by the travel")
for _ = 1, 20 do VoxelScene.glintStep(g, 112, 100) end
T.eq(g.amp, 0, "standing still fades it back out within a beat")
T.eq(g.phase, held, "and the phase does not move while the camera does not")
end

-- ------- the first-person rung
--
-- 1ST rides the same placed-camera seam the battle proved out, so most of
-- what it adds is arithmetic this suite can hold still: the rig built from
-- a pose, the compass the grid game still thinks in, the camera-relative
-- walk vector, and the frame an NPC shows an eye that can stand anywhere.

do
local FirstPerson =
  run.loader.exports.DRAMATIC_SHAPE.lib.require("FirstPerson")
local VoxelState = run.loader.exports.DRAMATIC_SHAPE.lib.require("VoxelState")
local FreeMove = run.loader.exports.DRAMATIC_SHAPE.lib.require("FreeMove")
local Voxel3D = run.loader.exports.DRAMATIC_SHAPE.lib.require("Voxel3D")

T.eq(VoxelState.FP_LEVEL, 6, "1ST is the seventh rung")
T.check(VoxelState.isFirstPerson(6), "and isFirstPerson answers for it")
T.check(not VoxelState.isFirstPerson(5), "but not for the 75 orbit")
T.eq(VoxelState.ANGLE_LABELS[VoxelState.FP_LEVEL + 1], "1ST (EXPERIMENTAL)",
  "the rung wears the experimental label")
T.eq(VoxelState.ANGLES_DEG[VoxelState.FP_LEVEL + 1], 75,
  "and hands the blend the 75-degree orbit as its far end")

-- ------- the compass and the walk vector
--
-- Yaw 0 faces south (+Z), the way a resting sprite faces; the compass is
-- the dominant axis and the walk rotates camera space into world space.
FirstPerson.yaw, FirstPerson.pitch = 0, 0
T.eq(FirstPerson.compassFacing(), "down", "yaw 0 looks south")
FirstPerson.yaw = math.pi / 2
T.eq(FirstPerson.compassFacing(), "right", "a quarter turn looks east")
FirstPerson.yaw = math.pi
T.eq(FirstPerson.compassFacing(), "up", "a half turn looks north")
FirstPerson.yaw = -math.pi / 2
T.eq(FirstPerson.compassFacing(), "left", "and three quarters looks west")

local function near(a, b) return math.abs(a - b) < 1e-9 end

FirstPerson.yaw = 0
local wx, wz = FirstPerson.moveWorld(0, 1)
T.check(near(wx, 0) and near(wz, 1), "facing south, forward walks south")
wx, wz = FirstPerson.moveWorld(1, 0)
T.check(near(wx, -1) and near(wz, 0),
  "facing south, the right hand points west")
FirstPerson.yaw = math.pi
wx, wz = FirstPerson.moveWorld(0, 1)
T.check(near(wx, 0) and near(wz, -1), "facing north, forward walks north")
wx, wz = FirstPerson.moveWorld(1, 0)
T.check(near(wx, 1) and near(wz, 0),
  "facing north, the right hand points east")

-- the look clamps: pitch stops at the limits, yaw wraps
FirstPerson.pitch = 0
FirstPerson.lookBy(0, 100)
T.eq(FirstPerson.pitch, FirstPerson.PITCH_DOWN, "pitch clamps looking down")
FirstPerson.lookBy(0, -100)
T.eq(FirstPerson.pitch, FirstPerson.PITCH_UP, "and looking up")
FirstPerson.yaw = 0
FirstPerson.lookBy(2 * math.pi, 0)
T.check(math.abs(FirstPerson.yaw) < 1e-9, "a full turn of yaw wraps to zero")

-- ------- the rig
--
-- frame() is pure arithmetic over the pose and the orbit, so the suite can
-- stand the blend anywhere and read the record it hands Voxel3D.
FirstPerson.yaw, FirstPerson.pitch = 0, 0
FirstPerson.blend = 1
local me = { px = 100, py = 200, gh = 0, lift = 0 }
local rig, sx, sy = FirstPerson.frame(me, 500, 600, 320, 288)
T.check(rig ~= nil, "with the blend in, frame() builds a rig")
T.eq(Voxel3D.camera, rig, "and hands it to Voxel3D")
T.check(near(rig.eye[1], 108) and near(rig.eye[3], 208),
  "the eye stands on the player's centre")
T.eq(rig.eye[2], FirstPerson.EYE_HEIGHT, "at head height")
T.check(near(rig.fov, FirstPerson.FOV), "wearing the first-person lens")
T.check(near(sx, 108) and near(sy, 208),
  "and the scene centre stands with it")
T.check(rig.curve == 0,
  "the world curve is declined outright -- a zero, not a nil the setting "
  .. "could override")
T.check(rig.focus[3] > rig.eye[3],
  "yaw 0 focuses south of the eye")

-- surf bob and ledge lift carry the eye with them
local bobbed = FirstPerson.frame({ px = 100, py = 200, gh = 4, lift = 6 },
                                 500, 600, 320, 288)
T.eq(bobbed.eye[2], 10 + FirstPerson.EYE_HEIGHT,
  "ground height and lift both raise the eye")

-- mid-blend, the rig is a lerp of the orbit and the head: its eye sits
-- between the two ends, and the curve is only half declined
VoxelState.angle = math.rad(75)
FirstPerson.blend = 0.5
local mid = FirstPerson.frame(me, 500, 600, 320, 288)
T.check(mid.eye[2] > FirstPerson.EYE_HEIGHT,
  "half way out, the eye is higher than the head")
T.check(mid.eye[2] < 288 * VoxelState.FOCAL,
  "and lower than the orbit")

-- ------- the cards ask the rig, and only the rig
FirstPerson.blend = 1
FirstPerson.frame(me, 500, 600, 320, 288)
T.check(FirstPerson.cardBlend() == 1, "the free-roam rig turns the cards")
T.check(FirstPerson.hidePlayer(), "and hides the player's own card")

-- an NPC south of the eye: the card yaws to face north, back at the eye
local yaw = FirstPerson.cardYaw(108, 300)
T.check(near(math.sin(yaw), 0) and near(math.cos(yaw), -1),
  "a card south of the eye turns its face north")

-- the frame an entity SHOWS this eye: stand north of someone facing away
-- and you see their back; face to face you see their front; flanks show
-- profiles, named by which flank is toward you
T.eq(FirstPerson.apparentFacing("down", 108, 300), "up",
  "an NPC facing south, seen from the north, shows their back")
T.eq(FirstPerson.apparentFacing("up", 108, 300), "down",
  "an NPC facing north, seen from the north, shows their face")
T.eq(FirstPerson.apparentFacing("right", 108, 300), "left",
  "an NPC facing east, seen from the north, shows their left flank")
T.eq(FirstPerson.apparentFacing("left", 108, 300), "right",
  "an NPC facing west, seen from the north, shows their right flank")

-- another camera on the same seam -- the battle's placed shot -- and the
-- cards stand down: blend still 1, but it is not our rig drawing
local battleCam = { eye = { 0, 40, 120 }, focus = { 0, 8, 0 },
                    fov = math.rad(30) }
Voxel3D.camera = battleCam
T.eq(FirstPerson.cardBlend(), 0,
  "a battle camera on the seam turns no cards")
T.check(not FirstPerson.hidePlayer(),
  "and hides nobody")

-- blend fully out: frame() clears only a camera that is still ours
FirstPerson.blend = 0
T.eq(FirstPerson.frame(me, 500, 600, 320, 288), nil,
  "with the blend out, frame() answers nil and the orbit rules")
T.eq(Voxel3D.camera, battleCam,
  "without touching a camera some other pass placed")
Voxel3D.camera = nil

-- ------- the free walk's per-cell verdict
--
-- The same questions Collision asks a grid step, asked per cell the body
-- overlaps -- through a map stub shaped like the engine's own.
local blocked = FreeMove._blockedCell
local stubMap = {
  def = { tileset = "OVERWORLD" },
  inBounds = function(self, x, y)
    return x >= 0 and y >= 0 and x < 10 and y < 10
  end,
  isWalkableCell = function(self, x, y) return x ~= 3 end,
  isWaterCell = function(self, x, y) return x == 3 and y == 3 end,
  cellTile = function() return 0 end,
}
local p = { cellX = 5, cellY = 5, surfing = false }
local state = { map = stubMap, entities = {} }

T.eq(blocked(state, p, 5, 5), nil, "the body's own cell never refuses it")
T.eq(blocked(state, p, 6, 5), nil, "an open neighbour admits it")
T.eq(blocked(state, p, 3, 5), "tile", "an unwalkable cell refuses it")
T.eq(blocked(state, p, -1, 5), "bounds", "off the map is the edge's answer")
T.eq(blocked(state, p, 3, 3), "tile", "water refuses a walker")
p.surfing = true
T.eq(blocked(state, p, 3, 3), nil, "and admits a surfer")
p.surfing = false

state.entities = { { cellX = 6, cellY = 5 } }
T.eq(blocked(state, p, 6, 5), "entity", "an occupied cell refuses the body")
state.entities = { { cellX = 7, cellY = 5, targetX = 6, targetY = 5 } }
T.eq(blocked(state, p, 6, 5), "entity",
  "and so does one an NPC is mid-step into")

-- the ladder's own state, put back the way the suite found it
FirstPerson.blend = 0
VoxelState.reset()
end

-- ------- the third-person rung
--
-- 3RD is 1ST with the eye on a boom, so what the suite has to hold still is
-- the boom: where it stands the eye behind a pivot, the march through the
-- world that shortens it when something is in the way, and the two things
-- its extension decides that 1ST decides the other way -- the player's own
-- card being drawn, and the body turning to face where it walks.

do
local FirstPerson =
  run.loader.exports.DRAMATIC_SHAPE.lib.require("FirstPerson")
local ThirdPerson =
  run.loader.exports.DRAMATIC_SHAPE.lib.require("ThirdPerson")
local VoxelState = run.loader.exports.DRAMATIC_SHAPE.lib.require("VoxelState")
local Voxel3D = run.loader.exports.DRAMATIC_SHAPE.lib.require("Voxel3D")

T.eq(VoxelState.TP_LEVEL, 7, "3RD is the eighth rung")
T.check(VoxelState.isThirdPerson(7), "and isThirdPerson answers for it")
T.check(not VoxelState.isThirdPerson(6), "but not for 1ST")
T.check(VoxelState.isFreeCam(6) and VoxelState.isFreeCam(7),
  "both rungs that stand the camera with the player answer isFreeCam")
T.check(not VoxelState.isFreeCam(5), "the 75-degree orbit does not")
T.eq(VoxelState.ANGLE_LABELS[VoxelState.TP_LEVEL + 1], "3RD (EXPERIMENTAL)",
  "the rung wears the experimental label")
T.eq(VoxelState.ANGLES_DEG[VoxelState.TP_LEVEL + 1], 75,
  "and hands the blend the same 75-degree orbit 1ST does")
T.eq(VoxelState.HOTKEY_ORDER[#VoxelState.HOTKEY_ORDER], VoxelState.TP_LEVEL,
  "the 3 key walks onto it, and off it back to OFF")

-- the boom's own tween: picked from an orbit rung (blend fully out) the
-- extension SNAPS, so the dive into the world is one motion rather than a
-- dive followed by a slide; picked from inside the head it eases
VoxelState.setLevel(VoxelState.TP_LEVEL)
ThirdPerson.out, ThirdPerson.len = 0, 0
ThirdPerson.update(1 / 60, 0)
T.eq(ThirdPerson.out, 1, "picked from the diorama, the boom starts extended")
ThirdPerson.out, ThirdPerson.len = 0, 0
ThirdPerson.update(1 / 60, 1)
T.check(ThirdPerson.out > 0 and ThirdPerson.out < 1,
  "picked from inside the head, it slides out over the boom's own time")

-- ------- the world the march asks
--
-- A stub map that refuses everything from x = 4 rightward, with no tileset
-- for the height field to read -- so the ground answers 0 (the lookup is
-- guarded for exactly this) and only the walkability speaks.
local wall = { map = {
  inBounds = function(_, cx, cy) return cx >= 0 and cy >= 0 end,
  isWalkableCell = function(_, cx) return cx < 4 end,
  cellTile = function() return 0 end,
} }

T.check(ThirdPerson._occupied(wall, 70, 10, 8),
  "an unwalkable cell refuses the eye at head height")
T.check(not ThirdPerson._occupied(wall, 70, 30, 8),
  "but not one the eye stands well above -- a fence is not a wall")
T.check(ThirdPerson._occupied(wall, 70, 2, 8),
  "and the ground refuses it from below")
T.check(ThirdPerson._occupied(wall, -20, 30, 8),
  "off the world entirely there is nowhere to stand: the border ring")

-- the march itself: the wall's face is at x = 64, the pivot at x = 40, so
-- the eye may travel 24 east of it less the clearance pad -- the FACE's own
-- position rather than the four-pixel sampling grid's
local room = ThirdPerson.reach(wall, { 40, 10, 8 }, 1, 0, 0, ThirdPerson.BOOM)
T.check(math.abs(room - (24 - ThirdPerson.PAD)) < 0.5,
  "the boom stops a pad short of the face that blocked it")
T.eq(ThirdPerson.reach(wall, { 40, 30, 8 }, 1, 0, 0, ThirdPerson.BOOM),
  ThirdPerson.BOOM, "with nothing tall enough in the way it runs out full")
T.eq(ThirdPerson.reach(nil, { 40, 10, 8 }, 1, 0, 0, ThirdPerson.BOOM),
  ThirdPerson.BOOM, "and with no world to ask at all -- headless, mid-warp")

-- ------- the eye
--
-- place() is pure arithmetic over the pivot and the look, given a world
-- with nothing in it: the suite lends the overworld away for the length of
-- the check so the march has nothing to shorten against.
local Game = require("src.core.Game")
local hadOw = Game.overworld
Game.overworld = nil

ThirdPerson.out, ThirdPerson.len = 1, ThirdPerson.BOOM
local eye, aim = ThirdPerson.place({ 100, 20, 200 }, 0, 0, 1,
                                   { 100, 20, 224 })
T.check(math.abs(eye[3] - (200 - ThirdPerson.BOOM)) < 1e-6,
  "looking south, the eye stands a full boom north of the pivot")
T.eq(eye[2], 20 + ThirdPerson.PIVOT_LIFT,
  "raised to the orbit point above the head")
T.check(math.abs(eye[1] - (100 - ThirdPerson.SHOULDER)) < 1e-6,
  "and slid along the rail to the camera's own right -- which is west "
  .. "looking south, and puts the player left of centre")
T.check(math.abs(aim[1] - eye[1]) < 1e-6
        and math.abs(aim[3] - eye[3] - (ThirdPerson.BOOM + 24)) < 1e-6,
  "the focus slides with it, so the rail moves the frame and not the look")

ThirdPerson.out, ThirdPerson.len = 0, 0
local head = { 100, 20, 200 }
local focus = { 100, 20, 224 }
T.eq(ThirdPerson.place(head, 0, 0, 1, focus), head,
  "with the boom fully in, the eye IS the head -- 1ST to the pixel")

-- ------- what the extension decides
--
-- The rig is built through FirstPerson exactly as 1ST's is; the boom moves
-- the eye, and everything keyed to where the eye stands follows it.
ThirdPerson.out, ThirdPerson.len = 1, ThirdPerson.BOOM
FirstPerson.yaw, FirstPerson.pitch = 0, 0
FirstPerson.blend = 1
FirstPerson.frame({ px = 100, py = 200, gh = 0, lift = 0 }, 500, 600, 320, 288)
T.check(FirstPerson.cardBlend() == 1,
  "the boomed rig turns the cards to face it, exactly as the head does")
T.check(not FirstPerson.hidePlayer(),
  "but the player's own card is DRAWN -- it is what the camera is watching")
T.eq(FirstPerson.apparentFacing("down", 108, 208), "up",
  "and it shows the camera behind it its back")

-- and a boom a wall has squeezed back into the head takes the card out
-- again: at that range it is the first-person problem word for word
ThirdPerson.len = ThirdPerson.SHOW_AT - 1
T.check(FirstPerson.hidePlayer(),
  "backed into a fence, the collapsed boom stops drawing the card")
ThirdPerson.len = ThirdPerson.SHOW_AT
T.check(not FirstPerson.hidePlayer(), "and draws it again the moment it clears")
ThirdPerson.len = ThirdPerson.BOOM

T.eq(FirstPerson.bodyFacing(1, 0), "right",
  "a body walking east turns east, whichever way the camera is pointed")
T.eq(FirstPerson.bodyFacing(0, -1), "up", "and north walking north")
T.eq(FirstPerson.bodyFacing(0, 0), FirstPerson.compassFacing(),
  "standing still it comes back round to the camera's bearing, which is "
  .. "the one A talks along")

-- ------- the spin-flicker guard
--
-- The player's card is the one whose body the camera is derived FROM: the
-- body is pointed along the camera's own yaw, so the angle between them is
-- a flat 180 degrees and the card should show its back and nothing else,
-- at every bearing.
--
-- Quantise the body to a compass point first and that stops being true.
-- The shoulder rail stands the eye a few degrees off the exact rear axis,
-- and the round trip through four directions has no margin to spare for
-- it: in a band just short of each 45-degree boundary the pair measures as
-- 135 degrees and picks the mirrored PROFILE frame. Standing perfectly
-- still. Spin the camera and you sweep four of those bands a revolution --
-- the character flicking sideways for a split second, which is the bug
-- this pair of checks exists to hold shut.
--
-- 44 degrees is inside the first band. No lag anywhere: the body is
-- pointed exactly where the camera looks, which is what standing still IS.
FirstPerson.yaw, FirstPerson.pitch = math.rad(44), 0
FirstPerson.frame({ px = 100, py = 200, gh = 0, lift = 0 }, 500, 600, 320, 288)
FirstPerson.bodyYaw = FirstPerson.yaw
T.eq(FirstPerson.apparentFacing("down", 108, 208), "right",
  "measured off the compass point, a standing body picks the profile -- "
  .. "the flicker, reproduced with the camera perfectly still")
T.eq(FirstPerson.playerFacing("down", 108, 208), "up",
  "measured off the body's own bearing, the card keeps its back turned")

-- and the whole revolution, which is the assertion that actually matters:
-- there is no bearing at all where a standing body shows anything but its
-- back
;(function()
  local wrong = {}
  for deg = 0, 359 do
    FirstPerson.yaw = math.rad(deg)
    FirstPerson.frame({ px = 100, py = 200, gh = 0, lift = 0 },
                      500, 600, 320, 288)
    FirstPerson.bodyYaw = FirstPerson.yaw
    if FirstPerson.playerFacing(FirstPerson.compassFacing(), 108, 208)
       ~= "up" then
      wrong[#wrong + 1] = deg
    end
  end
  T.eq(#wrong, 0,
    "a standing body shows its back at every one of 360 bearings (bad: "
    .. table.concat(wrong, ",") .. ")")
end)()

-- and with nothing holding a bearing -- a scripted walk, a cutscene, the
-- grid walk -- the player falls back to the four-direction answer with
-- everybody else
FirstPerson.releaseBody()
T.eq(FirstPerson.bodyYaw, nil, "releasing the body drops the bearing")
T.eq(FirstPerson.playerFacing("down", 108, 208),
  FirstPerson.apparentFacing("down", 108, 208),
  "and the card reads exactly as an NPC's would")
T.eq(FirstPerson.pointBody(0, 0), FirstPerson.compassFacing(),
  "pointing it again hands back the compass facing p.facing wants")
T.eq(FirstPerson.bodyYaw, FirstPerson.yaw, "and records the bearing behind it")
FirstPerson.yaw, FirstPerson.pitch = 0, 0
FirstPerson.frame({ px = 100, py = 200, gh = 0, lift = 0 }, 500, 600, 320, 288)

ThirdPerson.out, ThirdPerson.len = 0, 0
T.eq(FirstPerson.bodyFacing(1, 0), "down",
  "in the head the body is the head, whichever way it walks")
T.check(FirstPerson.hidePlayer(),
  "and the card the camera stands inside is left out of the frame again")

-- everything the section borrowed, put back
Game.overworld = hadOw
FirstPerson.blend = 0
ThirdPerson.out, ThirdPerson.len, ThirdPerson.want = 0, 0, 0
Voxel3D.camera = nil
VoxelState.reset()
end

-- ------- the cameras the player steers
--
-- Three cameras take the same four inputs -- a wheel, Q/E, a pinch, a
-- stick -- and the whole of CamControl is the answer to "which one is this
-- aimed at". So the suite pins that routing table, then each camera's own
-- stops: the boom's zoom, and the battle's orbit, climb and lens.

do
local CamControl = run.loader.exports.DRAMATIC_SHAPE.lib.require("CamControl")
local ThirdPerson =
  run.loader.exports.DRAMATIC_SHAPE.lib.require("ThirdPerson")
local BattleCam = run.loader.exports.DRAMATIC_SHAPE.lib.require("BattleCam")
local VoxelState = run.loader.exports.DRAMATIC_SHAPE.lib.require("VoxelState")
local Voxel3D = run.loader.exports.DRAMATIC_SHAPE.lib.require("Voxel3D")

-- ------- the boom's own zoom
ThirdPerson.zoom, ThirdPerson.zoomGoal = 1, 1
T.eq(ThirdPerson.reachFor(), ThirdPerson.BOOM,
  "at zoom 1 the boom reaches exactly its own length")
T.check(ThirdPerson.stepZoom(1), "a notch out moves the goal")
T.check(ThirdPerson.zoomGoal > 1, "outward, which is what positive means")
T.check(ThirdPerson.stepZoom(-2), "and back in past where it started")
T.check(ThirdPerson.zoomGoal < 1, "inward")
for _ = 1, 40 do ThirdPerson.stepZoom(-1) end
T.eq(ThirdPerson.zoomGoal, ThirdPerson.ZOOM_MIN, "it stops coming in")
T.check(not ThirdPerson.stepZoom(-1),
  "and says so, so the input can fall through instead of being eaten")
for _ = 1, 60 do ThirdPerson.stepZoom(1) end
T.eq(ThirdPerson.zoomGoal, ThirdPerson.ZOOM_MAX, "and stops going out")

-- the ease: a step is a request, and the eye takes ZOOM_TIME to answer it
ThirdPerson.zoom, ThirdPerson.zoomGoal = 1, 1
ThirdPerson.stepZoom(2)
ThirdPerson.update(1 / 60, 1)
T.check(ThirdPerson.zoom > 1 and ThirdPerson.zoom < ThirdPerson.zoomGoal,
  "one frame later the eye is on its way but not there")
for _ = 1, 120 do ThirdPerson.update(1 / 60, 1) end
T.eq(ThirdPerson.zoom, ThirdPerson.zoomGoal, "and it arrives")
T.check(math.abs(ThirdPerson.reachFor()
                 - ThirdPerson.BOOM * ThirdPerson.zoom) < 1e-9,
  "the boom it reaches for is the length at that zoom")
ThirdPerson.zoom, ThirdPerson.zoomGoal = 1, 1

-- the same control with no notches, for a gesture whose own scale IS the
-- answer. It scales the BOOM, so the inversion a pinch needs (spread the
-- fingers, pull the camera in) belongs to the gesture, not to this
T.check(ThirdPerson.scaleZoom(2), "a continuous factor moves it too")
T.check(math.abs(ThirdPerson.zoomGoal - 2) < 1e-6,
  "and scales the boom by exactly that factor")
ThirdPerson.zoom, ThirdPerson.zoomGoal = 1, 1

-- ------- which camera an input is aimed at
--
-- Needs a 3D pass and a free-roam stack, neither of which a headless run
-- has; both are lent for the length of the check and handed back.
;(function()
  local Game = require("src.core.Game")
  local hadAvail = Voxel3D.available
  local hadStack, hadOw = Game.stack, Game.overworld
  local ow = {}
  Voxel3D.available = function() return true end
  Game.overworld = ow
  Game.stack = { top = function() return ow end }

  VoxelState.setLevel(0)
  T.eq(CamControl.zoomTarget(), nil, "with the mode off, no camera of ours")
  VoxelState.setLevel(3)
  T.eq(CamControl.zoomTarget(), "survey",
    "on an orbit rung a zoom is the engine's own survey zoom")
  VoxelState.setLevel(VoxelState.FP_LEVEL)
  T.eq(CamControl.zoomTarget(), nil,
    "in 1ST nothing zooms -- the eye is in the player's head")
  VoxelState.setLevel(VoxelState.TP_LEVEL)
  T.eq(CamControl.zoomTarget(), "boom", "and in 3RD it is the boom")

  ThirdPerson.zoomGoal = 1
  T.check(CamControl.zoomBy(1) and ThirdPerson.zoomGoal > 1,
    "so a wheel notch on that rung lets the boom out")
  ThirdPerson.zoomGoal = 1
  T.check(CamControl.pinchBy(2) and ThirdPerson.zoomGoal < 1,
    "and spreading two fingers pulls it IN -- the gesture is the inversion")
  ThirdPerson.zoomGoal = 1
  T.check(CamControl.pinchBy(0.5) and ThirdPerson.zoomGoal > 1,
    "pinching them together pushes it out again")
  ThirdPerson.zoom, ThirdPerson.zoomGoal = 1, 1

  -- 1ST is the rung that deliberately swallows nothing: a pinch there
  -- would silently wind the survey zoom for whenever the player stepped
  -- back out to an orbit rung
  VoxelState.setLevel(VoxelState.FP_LEVEL)
  T.check(not CamControl.zoomBy(1), "1ST claims no wheel notch")
  T.check(not CamControl.pinchBy(2), "and no pinch")
  VoxelState.setLevel(VoxelState.TP_LEVEL)

  -- a screen over the overworld takes every one of them back
  Game.stack = { top = function() return {} end }
  T.eq(CamControl.zoomTarget(), nil,
    "with anything pushed over the overworld, nothing is ours to zoom")

  Voxel3D.available = hadAvail
  Game.stack, Game.overworld = hadStack, hadOw
  VoxelState.reset()
end)()

-- ------- the battle's orbit
--
-- The stop that matters is the far one: swung fully right, the eye must be
-- SQUARE to the arena's axis -- the side-on shot -- and not a degree past
-- it. Measured off the rig rather than off the constant, because the
-- constant is computed from the rig's own stance.
;(function()
  local arena = { mid = { 100, 200 }, player = { 100, 216 },
                  enemy = { 100, 184 } }
  local function bearing()
    local rig = BattleCam.rig(arena, 0)
    return math.atan2(rig.eye[1] - arena.mid[1], rig.eye[3] - arena.mid[2])
  end
  BattleCam.recentre()
  BattleCam.reset()
  BattleCam.steerable = true

  local home = bearing()
  T.check(home > 0.4 and home < 0.6,
    "the solved shot stands about 28 degrees off the arena's axis")
  BattleCam.orbit = 1
  T.check(math.abs(bearing() - math.pi / 2) < 1e-9,
    "swung fully right, the eye is exactly square to the axis: side-on")
  T.check(math.abs(BattleCam.orbitRange(arena) - (math.pi / 2 - home)) < 1e-9,
    "which is precisely the room orbitRange said it had")

  -- and the near one: there is nothing to the left of the solved shot
  BattleCam.recentre()
  T.check(not BattleCam.dragOrbit(-1), "a drag left of home does nothing")
  T.eq(BattleCam.orbitGoal, 0, "the shot the composition was solved for IS "
    .. "the left stop")
  T.check(BattleCam.dragOrbit(0.2), "a drag right steers")
  BattleCam.dragOrbit(10)
  T.eq(BattleCam.orbitGoal, 1, "and stops at side-on however hard it is pushed")

  -- ------- the climb
  BattleCam.recentre()
  local function elevation()
    local rig = BattleCam.rig(arena, 0)
    local vx = rig.eye[1] - rig.focus[1]
    local vy = rig.eye[2] - rig.focus[2]
    local vz = rig.eye[3] - rig.focus[3]
    return math.atan2(vy, math.sqrt(vx * vx + vz * vz)),
           math.sqrt(vx * vx + vy * vy + vz * vz)
  end
  local low, radius = elevation()
  BattleCam.pitch = 1
  local high, radius2 = elevation()
  T.check(math.abs((high - low) - BattleCam.PITCH_RANGE) < 1e-6,
    "raised fully, the seat is exactly 45 degrees above the solved one")
  T.check(math.abs(radius2 - radius) < 1e-6,
    "at the same distance -- climbing is not zooming")
  BattleCam.recentre()
  T.check(not BattleCam.dragPitch(-1), "and it will not tilt below home")
  T.eq(BattleCam.pitchGoal, 0, "the rig's own low stance is the down stop")
  BattleCam.dragPitch(10)
  T.eq(BattleCam.pitchGoal, 1, "45 degrees is the up stop")

  -- ------- the lens opening to keep the pair framed
  --
  -- Swinging round or climbing un-foreshortens the arena's axis, so the two
  -- mons read further apart; left alone that threw them off the edges of
  -- the frame at the far end of both ranges.
  BattleCam.recentre()
  T.check(math.abs(BattleCam.spread(arena) - 1) < 1e-9,
    "at the solved shot the lens is the rig's own, exactly")
  BattleCam.orbit = 1
  T.check(BattleCam.spread(arena) > 1.8,
    "side-on the pair reads nearly twice as far apart, and the lens opens "
    .. "by the same amount")
  BattleCam.orbit = 0
  BattleCam.pitch = 1
  T.check(BattleCam.spread(arena) > 1.5,
    "and climbing spreads them too, on the other axis")
  BattleCam.recentre()

  local wide = BattleCam.rig(arena, 0).fov
  T.check(BattleCam.stepZoom(-3), "three notches in")
  BattleCam.zoom = BattleCam.zoomGoal
  T.check(BattleCam.rig(arena, 0).fov < wide,
    "and the lens is longer -- zoom is the FRAME, not the distance")
  T.check(math.abs(BattleCam.frameH(arena)
                   - BattleCam.rigFor(arena).frameH * BattleCam.zoom) < 1e-9,
    "which is what the sun's box is fitted to as well")
  for _ = 1, 40 do BattleCam.stepZoom(-1) end
  T.eq(BattleCam.zoomGoal, BattleCam.ZOOM_MIN, "the lens has a near stop")
  for _ = 1, 60 do BattleCam.stepZoom(1) end
  T.eq(BattleCam.zoomGoal, BattleCam.ZOOM_MAX, "and a far one")

  -- ------- what BACK SPRITES takes away
  --
  -- Not just the input: the RIG stands down too, so an angle stored from
  -- before the row was switched on cannot leave the pinned composition
  -- steered anyway.
  BattleCam.recentre()
  BattleCam.orbit, BattleCam.orbitGoal = 1, 1
  BattleCam.pitch, BattleCam.pitchGoal = 1, 1
  BattleCam.zoom, BattleCam.zoomGoal = 0.5, 0.5
  BattleCam.steerable = false
  T.check(math.abs(bearing() - home) < 1e-9,
    "with the player's mon pinned to the menu, the shot holds its own angle")
  T.eq(BattleCam.frameH(arena), BattleCam.rigFor(arena).frameH,
    "and its own lens")
  T.check(not BattleCam.dragOrbit(0.5), "and refuses to be steered")
  T.check(not BattleCam.dragPitch(0.5), "on either axis")
  T.check(not BattleCam.stepZoom(-1), "or zoomed")
  BattleCam.steerable = true

  -- ------- and what a new battle remembers
  BattleCam.recentre()
  BattleCam.dragOrbit(0.5)
  BattleCam.dragPitch(0.5)
  BattleCam.stepZoom(-1)
  BattleCam.reset()
  T.check(BattleCam.orbitGoal > 0 and BattleCam.pitchGoal > 0
          and BattleCam.zoomGoal < 1,
    "a new fight opens where the player left the camera, not where the rig "
    .. "was solved -- an angle they chose is how they watch battles")
  T.eq(BattleCam.t, 0, "only the drift's own phase starts over")
  BattleCam.recentre()
end)()
end

-- ------- the VR rig's arithmetic
--
-- VRRig is the deliberately pure half of the VR stack: headset poses in,
-- placed cameras out, with no FFI anywhere -- so the suite can hold a
-- synthetic head still and check the world lands where the design says.
-- (The FFI half -- VRXR, VRGL -- is exercised by tests/vr_probe.lua
-- against a real runtime, which a headless suite cannot be.)

-- an immediately-run function rather than a bare do-block: the main chunk
-- is brushing LuaJIT's 200-active-locals ceiling, and a function scope
-- keeps this section's locals off the chunk's own count
local function vrRigSection()
local VRRig = (function() local ok,m=pcall(function() return run.loader.exports.DRAMATIC_SHAPE.lib.require("VRRig") end); return ok and m or {} end)() -- may be nil when VR companion absent
local Mat4 = run.loader.exports.DRAMATIC_SHAPE.lib.require("Mat4")

local function near(a, b, eps) return math.abs(a - b) < (eps or 1e-5) end

-- a Mat4 applied to a point, for reading results back out
local function apply(m, x, y, z)
  return m[1] * x + m[2] * y + m[3] * z + m[4],
         m[5] * x + m[6] * y + m[7] * z + m[8],
         m[9] * x + m[10] * y + m[11] * z + m[12]
end

-- identity quaternion, head at the LOCAL origin: the eye lands ON the
-- pivot offset by the anchor, and the view carries a world point at the
-- pivot to `anchor` metres in eye space
local pose = { pos = { 0, 0, 0 }, quat = { 0, 0, 0, 1 } }
local fov = { angleLeft = -0.7, angleRight = 0.7,
              angleUp = 0.6, angleDown = -0.6 }
local pivot = { 1000, 0, 2000 }

local S = 128    -- an arbitrary table scale; eyeCamera takes any
local cam = VRRig.eyeCamera(pose, fov, pivot, VRRig.TABLE, S)
T.check(near(cam.eye[1], 1000 - VRRig.TABLE[1] * S)
        and near(cam.eye[2], -VRRig.TABLE[2] * S)
        and near(cam.eye[3], 2000 - VRRig.TABLE[3] * S),
  "the diorama eye stands the table's offset from the pivot, scaled")
T.eq(cam.curve, 0, "a VR camera declines the world curve outright")
T.check(near(cam.fov, 1.2), "fov is the vertical angular span")

-- the view ends in METRES: the pivot itself lands at `anchor` in eye
-- space, however big the scale is
local vx, vy, vz = apply(cam.view, pivot[1], pivot[2], pivot[3])
T.check(near(vx, VRRig.TABLE[1]) and near(vy, VRRig.TABLE[2])
        and near(vz, VRRig.TABLE[3]),
  "the view un-scales the world: the pivot sits at the table offset, "
  .. "in metres")

-- a point one metre of world east of the pivot lands one metre east in
-- eye space -- the scale cancels end to end
local ex, ey, ez = apply(cam.view, pivot[1] + S, pivot[2], pivot[3])
T.check(near(ex - vx, 1) and near(ey, vy) and near(ez, vz),
  "one scale's worth of world east is one metre east in eye space")

-- ------- the diorama presents at the rung's own angle and framing
--
-- The anchor sits VIEW_DIST along the rung's viewing angle: at 35 degrees
-- mostly below the head, at 75 mostly ahead of it -- so the resting head
-- looks at the model along exactly the line the flat camera uses.
local a35 = VRRig.dioramaAnchor(math.rad(35), 0)
T.check(near(a35[2], -VRRig.VIEW_DIST * math.cos(math.rad(35)))
        and near(a35[3], -VRRig.VIEW_DIST * math.sin(math.rad(35))),
  "the 35-degree anchor hangs the table down-and-ahead at the rung's angle")
local a75 = VRRig.dioramaAnchor(math.rad(75), 0)
T.check(a75[3] < a35[3] and a75[2] > a35[2],
  "75 degrees brings the table up toward eye level and further out")
T.check(near(VRRig.dioramaAnchor(math.rad(35), 0.25)[2], a35[2] + 0.25),
  "the grab-drag height rides the anchor straight up")

-- and the scale reproduces the flat screen's framing: vh world pixels
-- subtend the flat lens's field at VIEW_DIST
local sc = VRRig.dioramaScale(432, 1.0)
T.check(near(sc, 432 / VRRig.VIEW_DIST),
  "the diorama scale is the flat framing carried to arm's length")

-- first person: anchor at the origin pins the head to the pivot exactly
local fpCam = VRRig.eyeCamera(pose, fov, { 108, 13, 208 }, { 0, 0, 0 },
                              VRRig.FP_SCALE)
T.check(near(fpCam.eye[1], 108) and near(fpCam.eye[2], 13)
        and near(fpCam.eye[3], 208),
  "first person pins the start-of-session head to the player's head")

-- head motion moves the eye by metres-times-scale
local moved = VRRig.eyeCamera({ pos = { 0.1, 0.2, -0.3 },
                                quat = { 0, 0, 0, 1 } },
                              fov, { 108, 13, 208 }, { 0, 0, 0 },
                              VRRig.FP_SCALE)
T.check(near(moved.eye[1], 109) and near(moved.eye[2], 15)
        and near(moved.eye[3], 205),
  "a headset step moves the eye by metres times the scale")

-- with no rotation, the eye looks along LOCAL -Z, which is world NORTH
T.check(fpCam.focus[3] < fpCam.eye[3] - 1,
  "an identity orientation looks north, the LOCAL -Z convention")

-- headYawPitch round-trips this mod's conventions: identity looks north
-- (yaw pi), and a quarter turn about +Y (counterclockwise from above)
-- swings the forward from north to WEST (yaw -pi/2)
local yaw, pitch = VRRig.headYawPitch({ 0, 0, 0, 1 })
T.check(near(math.abs(yaw), math.pi) and near(pitch, 0),
  "an identity head faces north, level")
local s = math.sin(math.pi / 4)
yaw = VRRig.headYawPitch({ 0, s, 0, math.cos(math.pi / 4) })
T.check(near(yaw, -math.pi / 2),
  "a quarter turn about +Y faces west -- the compass agrees with the "
  .. "right-hand rule")

-- the asymmetric projection: a point ON the left frustum plane lands at
-- clip x = -w, one on the up plane at clip y = +w
local proj = Mat4.fovProjection(-0.5, 0.3, 0.4, -0.2, 0.1, 100)
local px_, py_, pz_ = nil, nil, nil
local function clip(m, x, y, z)
  local cx = m[1] * x + m[2] * y + m[3] * z + m[4]
  local cy = m[5] * x + m[6] * y + m[7] * z + m[8]
  local cw = m[13] * x + m[14] * y + m[15] * z + m[16]
  return cx / cw, cy / cw
end
local lx = math.tan(-0.5) * 2      -- on the left plane, 2 units out
local cxL = clip(proj, lx, 0, -2)
T.check(near(cxL, -1, 1e-4), "the left fov angle lands on clip x = -1")
local uy = math.tan(0.4) * 2
local _, cyU = clip(proj, 0, uy, -2)
T.check(near(cyU, 1, 1e-4), "the up fov angle lands on clip y = +1")

-- Mat4.fromQuat: a quarter turn about Y takes +X to -Z
local R = Mat4.fromQuat(0, s, 0, math.cos(math.pi / 4))
local rx, ry, rz = apply(R, 1, 0, 0)
T.check(near(rx, 0) and near(ry, 0) and near(rz, -1),
  "fromQuat: a quarter turn about +Y carries east into north")

-- ------- the battle mount: the over-the-shoulder seat, faced right
--
-- The seat sits BATTLE_DIST along the flat battle camera's own line from
-- its aim point, and the yaw is whatever turns XR forward (north) onto
-- that line's look direction.
local seat, byaw = VRRig.battleMount({ 100, 35, 332 }, { 100, 2, 200 })
local sdx = seat[1] - 100
local sdy = seat[2] - 2
local sdz = seat[3] - 200
T.check(near(math.sqrt(sdx * sdx + sdy * sdy + sdz * sdz),
             VRRig.BATTLE_DIST, 1e-3),
  "the battle seat sits BATTLE_DIST from the aim point")
T.check(near(byaw, 0),
  "a camera due south of its focus looks north -- XR forward, yaw 0")
local eyaw = select(2, VRRig.battleMount({ 150, 10, 200 }, { 100, 10, 200 }))
T.check(near(eyaw, math.pi / 2),
  "a camera east of its focus turns the mapping a quarter toward west")

-- ------- both VR seats follow the arena's quarter turn
--
-- `turn` promises the same composition on different ground, and every camera
-- has to keep it or the promise is only true on the flat screen. The two VR
-- seats keep it in different ways and both are pinned here.
--
-- THE STANDARD MOUNT keeps it by construction: it is built from the flat
-- battle camera's own eye and aim, which turn with the arena, so the seat
-- goes round with them. That is asserted rather than assumed, because the
-- day someone builds this seat from the arena's cells instead, the picture
-- stays plausible and starts pointing the wrong way.
--
-- THE DIORAMA disc does NOT get it for free: a fight arrives there as a
-- pillar of map about the arena's midpoint, whose bearing is its bearing in
-- the WORLD, so a turned arena landed on the table lying across the head.
-- Diorama.battleYaw takes the turn back out; the hand-turn rides on top.
--
-- In its own scope: the suite's main chunk is at LuaJIT's local ceiling.
;(function()
  local Arena = run.loader.exports.DRAMATIC_SHAPE.lib.require("BattleArena")
  local Cam = run.loader.exports.DRAMATIC_SHAPE.lib.require("BattleCam")
  local Dio = (function() local ok,m=pcall(function() return run.loader.exports.DRAMATIC_SHAPE.lib.require("Diorama") end); return ok and m or {} end)() -- may be nil when VR companion absent

  local function mountYawFor(turn)
    Cam.reset()
    local a = Arena.at(6, 6, "wide", turn)
    local rig = Cam.rig(a, 0, true)
    return select(2, VRRig.battleMount(rig.eye, rig.focus))
  end

  local base = mountYawFor(0)
  for _, turn in ipairs({ 90, 180, 270 }) do
    -- rotating (eye - focus) by +turn takes atan2(dx, dz) to (bearing - turn)
    local want = (base - math.rad(turn) + math.pi) % (2 * math.pi) - math.pi
    local got = (mountYawFor(turn) + math.pi) % (2 * math.pi) - math.pi
    T.check(near(got, want, 1e-6),
      ("the standard VR mount turns with a %d-degree arena: %.4f, wanted %.4f")
      :format(turn, got, want))
  end

  -- the disc: the turn comes back out, so the fight lies the same way on the
  -- table however the ground under it is laid
  local hand = Dio.yaw
  Dio.yaw = 0
  T.eq(Dio.battleYaw({ turn = 0 }), 0,
    "an unturned arena leaves the disc where the hands left it")
  T.check(near(Dio.battleYaw({ turn = 90 }), -math.pi / 2, 1e-9),
    "a quarter-turned arena counter-turns the disc a quarter")
  T.check(near(Dio.battleYaw({ turn = 270 }), math.pi / 2, 1e-9),
    "and three quarters comes round the other way, inside (-pi, pi]")
  T.eq(Dio.battleYaw(nil), 0, "no arena is no turn, not an error")
  -- and the same rule the standard mount lands on, so the two agree
  T.check(near(Dio.battleYaw({ turn = 90 }) - Dio.battleYaw({ turn = 0 }),
               mountYawFor(90) - mountYawFor(0), 1e-6),
    "the disc and the standard mount answer a turn by the same amount")
  -- the player's own hand-turn still rides on top of it
  Dio.yaw = math.rad(30)
  T.check(near(Dio.battleYaw({ turn = 90 }), math.rad(30) - math.pi / 2, 1e-9),
    "the hands keep whatever they did to the model, on top of the turn")
  Dio.yaw = hand
end)()

-- an eye seated with that yaw really faces the arena: an identity head at
-- the seat comes out looking WEST, and the view agrees to the metre
local seated = VRRig.eyeCamera(pose, fov, { 150, 10, 200 }, { 0, 0, 0 },
                               VRRig.FP_SCALE, math.pi / 2)
T.check(near(seated.eye[1], 150) and near(seated.eye[3], 200),
  "the yawed mapping still pins the resting head to the pivot")
T.check(seated.focus[1] < seated.eye[1] - 1,
  "and turns its gaze west, toward the focus it was seated against")
local wx2, wy2, wz2 = apply(seated.view, 150 - VRRig.FP_SCALE, 10, 200)
T.check(near(wx2, 0) and near(wy2, 0) and near(wz2, -1),
  "the yawed view carries one metre west of the pivot to one metre ahead")

-- the sky's RAY FAN round-trips the eye's own projection: the direction
-- the fan hands a canvas point looks along projects back to that very
-- point, through a rotated head AND a yawed mapping -- one sign wrong
-- anywhere here and the skybox paints sideways or upside down
local rayCam = VRRig.eyeCamera({ pos = { 0.2, 1.1, -0.4 },
                                 quat = { 0, s, 0, math.cos(math.pi / 4) } },
                               fov, { 50, 0, 70 }, { 0, 0, 0 }, 10,
                               math.pi / 3)
local rm = Mat4.mul(Mat4.mul(Mat4.scale(1, -1, 1), rayCam.proj), rayCam.view)
local function rayFrac(u, v)
  local sr = rayCam.skyRay
  local d1 = sr.base[1] + u * sr.du[1] + v * sr.dv[1]
  local d2 = sr.base[2] + u * sr.du[2] + v * sr.dv[2]
  local d3 = sr.base[3] + u * sr.du[3] + v * sr.dv[3]
  local x = rm[1] * d1 + rm[2] * d2 + rm[3] * d3
  local y = rm[5] * d1 + rm[6] * d2 + rm[7] * d3
  local ww = rm[13] * d1 + rm[14] * d2 + rm[15] * d3
  return x / ww * 0.5 + 0.5, y / ww * 0.5 + 0.5
end
local fu, fv = rayFrac(0.3, 0.8)
T.check(near(fu, 0.3, 1e-4) and near(fv, 0.8, 1e-4),
  "the sky's ray fan round-trips the eye's own projection")
local fu2, fv2 = rayFrac(0.9, 0.1)
T.check(near(fu2, 0.9, 1e-4) and near(fv2, 0.1, 1e-4),
  "at every corner of the frame alike")

-- ------- the hand prop: the pokedex rides the same mapping as the eyes
--
-- propMatrix carries a hand pose through worldFromXr: an identity hand at
-- the LOCAL origin lands ON the pivot, offsets scale by px-per-metre, and
-- the battle mount's yaw turns the prop with the whole mapping.
local handPose = { pos = { 0, 0, 0 }, quat = { 0, 0, 0, 1 } }
local pm = VRRig.propMatrix(handPose, { 500, 20, 700 }, { 0, 0, 0 }, 10)
local hx, hy, hz = apply(pm, 0, 0, 0)
T.check(near(hx, 500) and near(hy, 20) and near(hz, 700),
  "an identity hand at the origin puts the prop on the pivot")
local hx2, hy2, hz2 = apply(pm, 0.1, 0.2, 0)
T.check(near(hx2, 501) and near(hy2, 22) and near(hz2, 700),
  "prop-local metres scale to world pixels through the mapping")
local pmYaw = VRRig.propMatrix(handPose, { 500, 20, 700 }, { 0, 0, 0 },
                               10, math.pi / 2)
local yx, yy, yz = apply(pmYaw, 0, 0, -1)
T.check(near(yx, 490) and near(yy, 20) and near(yz, 700),
  "the battle mount's yaw turns the prop with the mapping: local "
  .. "forward comes out west")

-- and the pokedex module holds its shape headless: no frame until VR
-- places one, placement builds a model matrix, clear() takes it away
local Dex = (function() local ok,m=pcall(function() return run.loader.exports.DRAMATIC_SHAPE.lib.require("Pokedex") end); return ok and m or {} end)() -- may be nil when VR companion absent
T.eq(Dex.frame, nil, "no session, no pokedex frame")
Dex.place(handPose, { 500, 20, 700 }, { 0, 0, 0 }, 10)
T.check(Dex.frame ~= nil and type(Dex.frame.model) == "table"
        and #Dex.frame.model == 16,
  "placing the pokedex on a hand pose builds its world model matrix")
T.check(Dex.frame.tex == nil,
  "and the screen stays dark until something is put on it")
T.check(pcall(Dex.draw),
  "drawing headless is a clean no-op -- no meshes, no crash")
Dex.clear()
T.eq(Dex.frame, nil, "clear() takes the device away")
T.check(type(Dex.VOX) == "number" and Dex.VOX > 0,
  "the voxel size is a named, tunable number")
T.check(near(Dex.TILT, -math.pi / 2),
  "the device lies a full quarter turn forward, flush with the controller")

-- the sprite lean override and the anchored sky's knobs exist, unset and
-- set respectively, and an unstaged world offers no battle mount
local VS_ = run.loader.exports.DRAMATIC_SHAPE.lib.require("VoxelScene")
T.eq(VS_.spriteLean, nil,
  "the sprite lean override ships unset -- the flat screen leans with the rung")
local Sky_ = run.loader.exports.DRAMATIC_SHAPE.lib.require("Sky")
T.check(type(Sky_.ELEV_SPAN) == "number" and Sky_.ELEV_SPAN > 0,
  "the anchored sky hangs its gradient over a fixed elevation span")
local OB_ = run.loader.exports.DRAMATIC_SHAPE.lib.require("OverworldBattle")
T.eq(OB_.stage(), nil, "no staged fight, no battle mount")
T.eq(OB_.battle(), nil, "and no battle state for the UI panel to cut up")

-- ------- the effects plane: solved like the camera was, anchors on cells
--
-- fxCard's whole contract is that the classic layout's two slot marks land
-- on the two arena cells, so an effect authored at a slot bursts on the
-- mon standing in for it.
local BS_ = run.loader.exports.DRAMATIC_SHAPE.lib.require("BattleScene")
local fxArena = { player = { 96, 240 }, enemy = { 96, 192 } }
-- eyeless first (fxCard reads Voxel3D.eye at call time, and earlier
-- sections leave one behind): straight down the arena's axis the frame
-- is the fixed plane through both cells, marks exactly on them
local V3D_ = run.loader.exports.DRAMATIC_SHAPE.lib.require("Voxel3D")
local hadEye = V3D_.eye
V3D_.eye = nil
local fxm = BS_.fxCard(fxArena, 10, OB_.ANCHOR)
T.check(type(fxm) == "table" and #fxm == 16, "the effects plane has a model")
local pa, ea = OB_.ANCHOR.player, OB_.ANCHOR.enemy
local fpx, fpy, fpz = apply(fxm, pa[1] / 160 - 0.5, 1 - pa[2] / 144, 0)
T.check(near(fpx, 96, 1e-3) and near(fpy, 10, 1e-3) and near(fpz, 240, 1e-3),
  "the player slot's mark lands on the player's cell, at the floor")
local fex, fey, fez = apply(fxm, ea[1] / 160 - 0.5, 1 - ea[2] / 144, 0)
T.check(near(fex, 96, 1e-3) and near(fey, 10, 1e-3) and near(fez, 192, 1e-3),
  "and the enemy slot's mark on the enemy's cell")

-- and BILLBOARDED at an eye: seated east of the arena the frame turns
-- square to it, and the marks still land on the cells -- this eye's own
-- rays are what pinned them
V3D_.eye = { 200, 20, 216 }
local fxb = BS_.fxCard(fxArena, 10, OB_.ANCHOR)
T.check(near(fxb[3], 1, 1e-3) and near(fxb[11], 0, 1e-3),
  "the effects frame faces the eye in the east")
local bpx, bpy, bpz = apply(fxb, pa[1] / 160 - 0.5, 1 - pa[2] / 144, 0)
T.check(near(bpx, 96, 1e-3) and near(bpy, 10, 1e-3) and near(bpz, 240, 1e-3),
  "billboarded, the player mark still sits over the player's cell")
local bex, bey, bez = apply(fxb, ea[1] / 160 - 0.5, 1 - ea[2] / 144, 0)
T.check(near(bex, 96, 1e-3) and near(bey, 10, 1e-3) and near(bez, 192, 1e-3),
  "and the enemy mark over the enemy's")
V3D_.eye = hadEye

-- the FLAT first-person rig's sky fan: a placed eye/focus camera through
-- viewProjection carries a ray fan of its own, and it round-trips that
-- projection exactly like the VR eyes' does -- the flat 1ST sky is a
-- skybox by the same math
local hadCam = V3D_.camera
V3D_.camera = { eye = { 100, 13, 200 }, focus = { 130, 18, 160 },
                fov = 1.1, up = { 0, 1, 0 } }
local pvp = V3D_.viewProjection(0, 0, 320, 288)
local psr = V3D_.skyRayLive
T.check(psr ~= nil, "a placed free-pitch camera carries a ray fan")
local function pFrac(u, v)
  local d1 = psr.base[1] + u * psr.du[1] + v * psr.dv[1]
  local d2 = psr.base[2] + u * psr.du[2] + v * psr.dv[2]
  local d3 = psr.base[3] + u * psr.du[3] + v * psr.dv[3]
  local x = pvp[1] * d1 + pvp[2] * d2 + pvp[3] * d3
  local y = pvp[5] * d1 + pvp[6] * d2 + pvp[7] * d3
  local ww = pvp[13] * d1 + pvp[14] * d2 + pvp[15] * d3
  return x / ww * 0.5 + 0.5, y / ww * 0.5 + 0.5
end
local pu, pv = pFrac(0.25, 0.6)
T.check(near(pu, 0.25, 1e-4) and near(pv, 0.6, 1e-4),
  "and it round-trips the placed camera's own projection")
V3D_.camera = hadCam
V3D_.skyRayLive = nil

-- ------- VR owns the battle rows while it is on
local VRSet = (function() local ok,m=pcall(function() return run.loader.exports.DRAMATIC_SHAPE.lib.require("VR") end); return ok and m or {} end)() -- may be nil when VR companion absent.setting
VRSet:sync(true)
OB_.setting:sync(false)
OB_.backSetting:sync(true)
T.eq(OB_.enabled(), true, "VR on forces staged battles whatever the row says")
T.eq(OB_.backPinned(), false, "and holds back sprites off")
VRSet:sync(false)
T.eq(OB_.enabled(), false, "VR off hands the row back to its stored value")
OB_.setting:sync(true)
T.eq(OB_.backPinned(), true, "and back sprites return at theirs")
OB_.backSetting:sync(false)

-- and the VR row exists, shaped like every other mod setting
local VRMod = (function() local ok,m=pcall(function() return run.loader.exports.DRAMATIC_SHAPE.lib.require("VR") end); return ok and m or {} end)() -- may be nil when VR companion absent
T.eq(VRMod.setting.key, "vr", "the VR row persists under its own key")
T.eq(VRMod.setting:get(), false, "and ships OFF")
T.eq(VRMod.status(), "off", "with the status agreeing")
T.check(not VRMod.active(), "no session without a runtime, and no crash")
T.eq(type(VRMod.supported), "function",
  "the platform gate exists -- off Windows the row is not offered at all")
T.eq(VRMod.supported(), true,
  "and a headless run (no love.system) counts as supported, harmlessly")

-- the loader search covers every install shape: the mod-relative path
-- first, the system name last, and (with a filesystem to ask) the real
-- mount and the save directory in between
local VRXR_ = (function() local ok,m=pcall(function() return run.loader.exports.DRAMATIC_SHAPE.lib.require("VRXR") end); return ok and m or {} end)() -- may be nil when VR companion absent
local cands = VRXR_._loaderCandidates()
T.check(#cands >= 2, "the loader has candidates to try")
T.check(cands[1]:find("assets/vr/openxr_loader%.dll") ~= nil,
  "the first is the mod's own path")
T.eq(cands[#cands], "openxr_loader",
  "and the system search path is the last resort")
T.eq(type(VRMod.leave), "function",
  "VR.leave stays as the programmatic door out -- no controller button "
  .. "is wired to it")
end
vrRigSection()

-- ------- the DIORAMA modes
--
-- The VR row is a ladder now -- OFF / STANDARD / DIORAMA / DIORAMA-MR --
-- and the two diorama rungs are one presentation rather than a follow-on
-- from the VOXEL ladder: a viewport that cuts the world to a ball (a
-- pillar while a fight is staged), a base a tile deep under it, and grips
-- that carry, turn and resize the whole thing.
;(function()
  local lib = run.loader.exports.DRAMATIC_SHAPE.lib
  local VRM = (function() local ok,m=pcall(function() return lib.require("VR") end); return ok and m or {} end)() -- may be nil when VR companion absent
  local D = (function() local ok,m=pcall(function() return lib.require("Diorama") end); return ok and m or {} end)() -- may be nil when VR companion absent
  local V3 = lib.require("Voxel3D")
  local Rig = (function() local ok,m=pcall(function() return lib.require("VRRig") end); return ok and m or {} end)() -- may be nil when VR companion absent

  -- ------- the row
  T.eq(#VRM.setting.values, 4, "the VR row carries four rungs")
  T.eq(VRM.setting.values[2], true,
    "STANDARD is still stored as `true` -- a save written when the row was "
    .. "a toggle comes back on the rung it was left on")
  T.eq(VRM.setting.labels[3] .. "/" .. VRM.setting.labels[4],
    "DIORAMA/DIORAMA-MR", "and the two diorama rungs are labelled")
  VRM.setting:sync(false)
  T.eq(VRM.mode(), "off", "OFF is off")
  VRM.setting:sync(true)
  T.eq(VRM.mode(), "standard", "the stored true reads as STANDARD")
  T.eq(VRM.dioramaMode(), false, "which is not a diorama")
  VRM.setting:sync("diorama")
  T.eq(VRM.mode(), "diorama", "and the diorama rungs read as themselves")
  T.check(VRM.enabled() and VRM.dioramaMode(), "both on and a diorama")
  VRM.setting:sync("diorama-mr")
  T.check(VRM.dioramaMode(), "MR is a diorama too")
  T.eq(VRM.setting:get(), "diorama-mr", "under its own stored value")

  -- ------- the frame's own switches
  T.eq(D.begin("standard"), false, "STANDARD opens no diorama frame")
  T.eq(D.keyColor(), nil, "and keys nothing")
  T.eq(D.begin("diorama"), true, "DIORAMA opens one")
  T.eq(D.keyColor(), nil, "and still keys nothing -- it has a sky")
  T.eq(D.begin("diorama-mr"), true, "MR opens one as well")
  T.eq(D.keyColor()[2], 1, "and keys the background PURE green")
  T.check(D.keyColor()[1] == 0 and D.keyColor()[3] == 0,
    "no red and no blue in it: a keyer wants the colour the world cannot be")

  -- ------- the viewport
  --
  -- A square BOX with a hard edge while the world is flat, and the ball
  -- with the dissolved rim while V-CURVE bends it -- one click of the
  -- left stick throws the row and swaps the whole reading.
  local Curve = lib.require("WorldCurve")
  local curveWas = Curve.setting:get()
  Curve.setting:sync(0)
  local box = D.viewport(100, 200, 288)
  T.eq(box.kind, D.BOX, "a flat world is cut by a square BOX")
  T.check(box.x == 100 and box.z == 200, "centred on the view")
  T.check(math.abs(box.r - 288 * D.BOX_FRAC) < 1e-6,
    "spanning exactly the view the standard rung would have framed, so "
    .. "the zoom rows keep meaning what they mean")
  T.check(1 / box.invFade <= 0.5,
    "with a HARD edge: a flat world is a thing with sides")
  T.eq(D.fadeFor(100, false), 0, "and no fade band to speak of")
  Curve.setting:sync(3)
  local ball = D.viewport(100, 200, 288)
  T.eq(ball.kind, D.BALL, "V-CURVE turns the box into a BALL")
  T.check(math.abs(1 / ball.invFade - ball.r * D.FADE_FRAC) < 1e-6,
    "whose rim is a gradient fade into the sky rather than an edge")
  T.check(ball.r > box.r,
    "and which reaches further than the square did, so the throw curls "
    .. "the same model rather than shaving its corners off")
  local pillar = D.pillar({ mid = { 64, 96 },
                            player = { 64, 120 }, enemy = { 64, 72 } })
  T.eq(pillar.kind, D.PILLAR, "a staged fight cuts a vertical PILLAR instead")
  T.check(pillar.x == 64 and pillar.z == 96, "about the arena's midpoint")
  T.check(math.abs(pillar.r - (24 + D.ARENA_APRON)) < 1e-6,
    "wide enough for both mons and an apron -- the floating disc")
  T.eq(D.pillar(nil), nil, "and no arena cuts nothing")
  Curve.setting:sync(0)
  local flatFight = D.pillar({ mid = { 0, 0 } })
  T.eq(flatFight.kind, D.PILLAR,
    "the fight stays round whatever the curve is doing: a square tile "
    .. "floating in the air is not the picture")
  T.check(1 / flatFight.invFade > 1,
    "and keeps its dissolve with the curve off too -- a hard edge on "
    .. "something hanging in the air reads as a cookie cutter")
  Curve.setting:sync(curveWas)

  -- the shader takes the volume through a plain field, so no pass can be
  -- surprised by a cut world (Voxel3D never requires lib/Diorama)
  T.eq(V3.cull, nil, "nothing has left a viewport on Voxel3D")
  T.eq(V3.keyColor, nil, "nor a chroma key")

  -- ------- the grips
  D.reset()
  local function hand(x, y, z) return { pos = { x, y, z } } end
  T.eq(D.gesture({ gripL = 0, gripR = 0 }), false, "an open hand holds nothing")
  -- one grip: the model follows that hand, metre for metre, and the first
  -- frame of a squeeze moves nothing (there is no delta yet)
  D.gesture({ gripL = 1, handl = hand(0, 1, 0) })
  T.eq(D.offset[2], 0, "taking hold does not itself move the model")
  D.gesture({ gripL = 1, handl = hand(0.1, 1.25, -0.2) })
  T.check(math.abs(D.offset[1] - 0.1) < 1e-9
          and math.abs(D.offset[2] - 0.25) < 1e-9
          and math.abs(D.offset[3] + 0.2) < 1e-9,
    "one grip carries it through the room in all three axes")
  D.gesture({ gripL = 0, gripR = 0 })
  D.gesture({ gripL = 1, handl = hand(5, 5, 5) })
  T.check(math.abs(D.offset[2] - 0.25) < 1e-9,
    "letting go and taking hold somewhere else never snaps it")
  -- both grips: the turn and the resize, off the line between the hands
  D.reset()
  D.gesture({ gripL = 1, gripR = 1,
              handl = hand(-0.2, 1, 0), handr = hand(0.2, 1, 0) })
  local zoom0 = D.zoom
  D.gesture({ gripL = 1, gripR = 1,
              handl = hand(0, 1, 0.2), handr = hand(0, 1, -0.2) })
  T.check(math.abs(D.yaw - math.pi / 2) < 1e-6,
    "hand over hand turns the model by the same angle the mapping yaws by")
  T.check(math.abs(D.zoom - zoom0) < 1e-6,
    "a pure turn does not resize it")
  D.gesture({ gripL = 1, gripR = 1,
              handl = hand(0, 1, 0.4), handr = hand(0, 1, -0.4) })
  T.check(math.abs(D.zoom - zoom0 * 2) < 1e-6,
    "opening the hands opens the viewport by the same factor")
  for _ = 1, 12 do
    D.gesture({ gripL = 1, gripR = 1,
                handl = hand(0, 1, 4), handr = hand(0, 1, -4) })
    D.gesture({ gripL = 1, gripR = 1,
                handl = hand(0, 1, 0.001), handr = hand(0, 1, -0.001) })
  end
  T.check(D.zoom >= D.SCALE_MIN and D.zoom <= D.SCALE_MAX,
    "and it stays inside its stops however hard it is worked")

  -- ------- and NO base under it
  --
  -- The ground was extruded a tile deep once, cut to the viewport's shape
  -- and wearing Mt Moon's cave floor down its sides. It was removed at the
  -- user's request; the cut ends at the ground plane. Pinned so nothing
  -- puts a plinth back under the model by accident.
  T.eq(D.drawBase, nil, "the diorama draws no base under the world")
  T.eq(D.BASE_DEPTH, nil, "and keeps none of the arithmetic for one")
  -- ------- and the curve reaches the eyes
  --
  -- It did not: eyeCamera hardcoded `curve = 0`, and Voxel3D reads that
  -- field with `or` -- where 0 is TRUE in Lua -- so the bend was pinned
  -- off for every VR frame and the diorama's own V-CURVE throw did
  -- nothing at all. The rig takes it as a parameter now, and declining is
  -- still the default for the modes that want to decline.
  local POSE = { pos = { 0, 0, 0 }, quat = { 0, 0, 0, 1 } }
  local FOV = { angleLeft = -0.7, angleRight = 0.7,
                angleUp = 0.6, angleDown = -0.6 }
  local plain = Rig.eyeCamera(POSE, FOV, { 0, 0, 0 }, { 0, 0, 0 }, 64)
  T.eq(plain.curve, 0,
    "an eye declines the curve unless it asks -- first person and the "
    .. "battle seat both do")
  local bent = Rig.eyeCamera(POSE, FOV, { 0, 0, 0 }, { 0, 0, 0 }, 64, nil,
                             0.004)
  T.eq(bent.curve, 0.004,
    "and a diorama's eye carries the bend it asked for, which is what "
    .. "the left stick's throw is for")

  -- ------- the mapping carries all three axes now
  local a = Rig.dioramaAnchor(0, { 0.5, 0.25, -0.75 })
  T.check(math.abs(a[1] - 0.5) < 1e-9 and math.abs(a[3] + 0.75) < 1e-9,
    "the diorama anchor takes the carry in all three axes")
  T.check(math.abs(a[2] - (0.25 - Rig.VIEW_DIST)) < 1e-9,
    "with the height still riding the rung's own viewing line")
  local b = Rig.dioramaAnchor(0, 0.25)
  T.check(math.abs(b[2] - a[2]) < 1e-9 and b[1] == 0,
    "and a bare number is still the height alone -- STANDARD's own drag")

  -- ------- what the mode refuses
  T.eq(VRM.DIORAMA_RUNG, 3,
    "a diorama holds the VOXEL ladder on an orbit rung: there is no 2D "
    .. "diorama, and no first-person one either")
  T.eq(type(VRM.toggleCurve), "function",
    "and the left stick's click throws V-CURVE instead of stepping views")

  D.reset()
  VRM.setting:sync(false)
  T.eq(D.on, false, "and the frame shuts with the session")
end)()

-- ------- the skybox's checker and glow are the sky's own, not the screen's
--
-- The bands were already read by angle, but the DITHER between them kept
-- screen-cell parity: a world-fixed band edge sliding over a screen-fixed
-- checkerboard recomputes the pattern with every head motion -- the
-- shimmer. Now the ray path lays the checker (and the twilight glow's
-- rings) on azimuth/elevation cells, and these pin what it sends.
;(function()
  local Sky = run.loader.exports.DRAMATIC_SHAPE.lib.require("Sky")
  local realGraphics, realImage = love.graphics, love.image
  local sent = {}
  local fakeShader = {
    send = function(_, name, a, b, c, d) sent[name] = { a, b, c, d } end,
  }
  local function fakeImage(w, h)
    return {
      getWidth = function() return w end,
      getHeight = function() return h end,
      getDimensions = function() return w, h end,
      setPixel = function() end,
      setFilter = function() end,
      setWrap = function() end,
    }
  end
  love.image = { newImageData = function(w, h) return fakeImage(w, h) end }
  love.graphics = {
    getShader = function() return nil end,
    setShader = function() end,
    getDepthMode = function() return "lequal", true end,
    setDepthMode = function() end,
    setColor = function() end,
    newShader = function() return fakeShader end,
    newImage = function(data) return data end,
    rectangle = function() end,
  }
  Sky.invalidate()   -- rebuild the shader and ramp through the fakes

  local grad = { bands = { { 8, 8, 16 }, { 48, 64, 96 }, { 96, 128, 160 } } }
  -- a level fan looking north: base + u*du + v*dv, spanning 2*atan(0.5)
  -- both ways at depth 1 -- easy angles to pin the sends against
  local fan = { base = { -0.5, 0.5, -1 }, du = { 1, 0, 0 },
                dv = { 0, -1, 0 } }
  local span = 2 * math.atan(0.5)
  local body = { x = 160, y = 40, dx = 0, dy = 0.5, dz = -1,
                 glowAmt = 0.5, glowColor = { 248, 224, 168 } }
  T.eq(Sky.paint(320, 288, grad, nil, 7, body, nil, nil, fan), true,
    "the skybox paints with a ray fan and a bodied glow")
  T.check(sent.cellAng and sent.cellAng[1] > 0,
    "the checker gets an ANGULAR cell: the dither grid is laid on "
    .. "azimuth and elevation, so no head motion reslides it")
  T.check(math.abs(sent.cellAng[1] - span * 7 / 288) < 1e-6,
    "sized so the sky's grid matches the diorama's pixel grid on screen")
  T.check(sent.glowDir ~= nil, "the glow gets the sun's world direction")
  local gd = sent.glowDir[1]
  local gl = math.sqrt(gd[1] ^ 2 + gd[2] ^ 2 + gd[3] ^ 2)
  T.check(math.abs(gl - 1) < 1e-6 and math.abs(gd[2] - 0.4472) < 1e-3,
    "normalised, the hour's own")
  T.check(math.abs(sent.glowInvA[1] - 1 / (span * Sky.GLOW_REACH)) < 1e-6,
    "and an angular reach cut from the view the way the pixel reach was")
  T.eq(sent.glowPos, nil,
    "the screen-space glow stays the flat frame's path alone")

  sent = {}
  fakeShader.send = function(_, name, a, b, c, d) sent[name] = { a, b, c, d } end
  local bare = { x = 160, y = 40, glowAmt = 0.5,
                 glowColor = { 248, 224, 168 } }
  T.eq(Sky.paint(320, 288, grad, nil, 7, bare, nil, nil, fan), true,
    "a body with no world direction still paints")
  T.eq(sent.glowAmt[1], 0,
    "but offers no glow -- there is no direction to measure angles against")
  T.eq(sent.glowDir, nil, "and no direction is sent")

  love.graphics, love.image = realGraphics, realImage
  Sky.invalidate()

  -- ------- a live headset holds every menu inside the GB frame
  --
  -- The engine's zoom-aware anchoring docks the START menu to the WINDOW's
  -- edge; both VR screens crop the window to the GB frame, so a docked
  -- menu is cropped away with the border it hugged. The wrap answers the
  -- engine's own uiAnchorsHeldInStack predicate with yes while a headset
  -- is live, which blits every menu where it was drawn -- the START
  -- menu's slot is already flush with the frame's right edge.
  local Game = require("src.core.Game")
  local VRMod = (function() local ok,m=pcall(function() return run.loader.exports.DRAMATIC_SHAPE.lib.require("VR") end); return ok and m or {} end)() -- may be nil when VR companion absent
  T.eq(Game.dramaticShapeAnchorHold, true,
    "the anchor-hold wrap installed at load, once")
  T.eq(Game.uiAnchorsHeldInStack({ states = {} }), false,
    "with no headset the engine's own answer stands: an empty stack docks")
  local innerActive = VRMod.active
  VRMod.active = function() return true end
  T.eq(Game.uiAnchorsHeldInStack({ states = {} }), true,
    "a live headset holds anchors -- menus stay inside the GB frame, "
    .. "which is all either VR screen shows")
  VRMod.active = innerActive
  T.eq(Game.uiAnchorsHeldInStack({ states = {} }), false,
    "and hands the predicate back when the headset is gone")
  T.eq(Game.uiAnchorsHeldInStack({ states = { { holdsUIAnchors = true } } }),
    true, "a self-composing state still holds them on its own")

  -- and the panel's route to the headset is the SCALED region blit: the
  -- pixel-for-pixel copy ran the GB frame off a swapchain image smaller
  -- than the window (fullscreen cut the menu), so the scaled seam must
  -- exist for updateQuad to reach for first
  local VRGL_ = (function() local ok,m=pcall(function() return run.loader.exports.DRAMATIC_SHAPE.lib.require("VRGL") end); return ok and m or {} end)() -- may be nil when VR companion absent
  T.eq(type(VRGL_.copyFrontRegionToTexture), "function",
    "the letterbox reaches the panel scaled, not pixel-for-pixel")

  -- ------- the stick click IS the "3" key
  --
  -- Left stick click makes exactly the step the key (and SELECT) makes:
  -- the very same function, handed across from main.lua, so the ladder
  -- walk, the FULL step-over and the TILT/GBC FX clearing can never
  -- drift. Through the same fixture the key tests lend.
  T.eq(VRMod.cycleVoxel ~= nil, true,
    "main.lua hands its cycleVoxel to the stick click")
  local hadStack2, hadOw2 = Game.stack, Game.overworld
  local hadSave2, hadWrite2 = Game.save, Game.writeOptions
  Game.stack, Game.overworld = keyGame.stack, keyGame.overworld
  Game.save, Game.writeOptions = keyGame.save, keyGame.writeOptions
  Pipelines.setLevel("voxel", 0)
  VRMod.stepView()
  T.eq(Pipelines.levelLabel("voxel"), "15",
    "the stick click steps the VOXEL ladder exactly as 3 does")
  VRMod.stepView()
  T.eq(Pipelines.levelLabel("voxel"), "35", "and keeps walking it")
  keyGame.save.options.tilt = 2
  require("src.render.Tilt").setLevel(2)
  VRMod.stepView()
  T.eq(keyGame.save.options.tilt, 0,
    "each click clears TILT in the save, exactly as each keypress does")
  Game.stack, Game.overworld = hadStack2, hadOw2
  Game.save, Game.writeOptions = hadSave2, hadWrite2
  Pipelines.setLevel("voxel", 0)
end)()

-- ------- HORDE MODE
--
-- The parts that can be judged without a screen: the code detector (which
-- reads Game Boy buttons, so this is the same test the pad, the touch
-- overlay and the VR controllers would pass), the registrations, the
-- gloom's arithmetic, and the flow field the crowd chases along.
;(function()
  local lib = run.loader.exports.DRAMATIC_SHAPE.lib
  local Horde = lib.require("Horde")
  local Mobs = lib.require("HordeMobs")
  local Gun = lib.require("HordeGun")

  -- ------- the code

  local KONAMI = { "up", "up", "down", "down",
                   "left", "right", "left", "right", "b", "a" }

  local function feedAll(list)
    local fired = false
    for _, btn in ipairs(list) do
      if Horde.feed({ btn }) then fired = true end
    end
    return fired
  end

  T.eq(feedAll(KONAMI), true, "the konami code completes the detector")
  T.eq(Horde._progress(), 0, "and the detector resets behind itself")

  -- a wrong button in the middle is a wrong code
  T.eq(feedAll({ "up", "up", "down", "down", "left", "left" }), false,
    "a wrong button abandons the code")
  T.eq(Horde._progress(), 0, "and leaves nothing part-entered")

  -- the two Ups are two EDGES, which every device gives (the analog stick's
  -- hysteresis is what guarantees it there): one held Up is not two
  T.eq(feedAll({ "up", "up" }), false, "two Ups alone do not fire")
  T.eq(Horde._progress(), 2, "but they do stand at two")
  T.eq(feedAll({ "a" }), false, "a stray A after them is not the code")
  T.eq(Horde._progress(), 0, "and drops the run entirely")

  -- a false start re-enters on the first button rather than dying: pressing
  -- Up three times still leaves a code in progress
  feedAll({ "up", "up", "up" })
  T.eq(Horde._progress(), 2,
    "a third Up restarts the run rather than voiding it")
  Horde.feed({})
  feedAll({ "down", "down", "left", "right", "left", "right", "b" })
  T.eq(Horde.feed({ "a" }), true, "and the code still completes from there")

  -- every button in one step is still the code: the queue is ordered, and
  -- a frame that swallowed several presses must not lose any of them
  T.eq(Horde.feed(KONAMI), true, "the whole code inside one fixed step fires")

  -- ------- it cannot start from nowhere
  --
  -- canStart is the gate between the code and the mode. With no overworld
  -- in this harness it must refuse, which is also the "in a menu, in a
  -- battle, mid-warp" answer.
  T.eq(Horde.canStart(keyGame), false,
    "the code does nothing outside a live overworld")
  T.eq(Horde.active, false, "and the mode stays off")

  -- ------- what got registered

  T.check(type(Data.screens) == "table" and Data.screens.HordeGameOver ~= nil,
    "the GAME OVER card is in the screens registry")
  T.check(type(Data.screens) == "table" and Data.screens.HordeExitPrompt ~= nil,
    "and so is the exit prompt START opens")
  local sfx = Data.audio and Data.audio.sfx or {}
  local HordeSfx = lib.require("HordeSfx")
  for _, name in ipairs(HordeSfx.SHOTS) do
    T.check(type(sfx[name]) == "table" and sfx[name].chip ~= nil,
      "the gunshot " .. name .. " assembled into a chip program")
  end
  for _, name in ipairs({ HordeSfx.MAG_OUT, HordeSfx.MAG_IN, HordeSfx.RACK,
                          HordeSfx.DRY, HordeSfx.HIT, HordeSfx.HURT }) do
    T.check(type(sfx[name]) == "table" and sfx[name].chip ~= nil,
      name .. " assembled into a chip program")
  end
  T.eq(#HordeSfx.SHOTS, 3,
    "three shot variants, so a fast trigger overlaps its own echoes")
  -- none of them may duck the music: a fanfare pauses the song, and
  -- Lavender Town stopping every time the player fires is not the mode
  local fanfares = Data.audio and Data.audio.fanfares or {}
  for name in pairs(sfx) do
    if name:find("^DS_HORDE") then
      T.check(not fanfares[name] and not sfx[name].fanfare,
        name .. " is an overlay sound, not a fanfare that pauses the song")
    end
  end

  -- ------- the gloom
  --
  -- The mode pins NIGHT and then drags it down. Both wrappers must be
  -- INERT with the mode off -- this mod is a display mod first, and a
  -- horde-mode bug that tinted the ordinary game would be the worst kind.

  local DayNight = lib.require("DayNight")
  local litPal = DayNight.palette(DayNight.T.night)
  local litTint = DayNight.tint(true, DayNight.T.night)
  T.check(type(litPal) == "table" and #litPal > 0,
    "the night palette is readable with the mode off")

  Horde.active = true
  local darkPal = DayNight.palette(DayNight.T.night)
  local darkTint = DayNight.tint(true, DayNight.T.night)
  local darkIn = DayNight.tint(false, DayNight.T.night)
  Horde.active = false

  local litSum, darkSum = 0, 0
  for i = 1, #litPal do
    for c = 1, 3 do
      litSum = litSum + litPal[i][c]
      darkSum = darkSum + darkPal[i][c]
    end
  end
  T.check(darkSum < litSum * 0.6,
    "the horde's sky is markedly darker than the night it is built on")
  T.check(darkTint[1] < litTint[1] and darkTint[3] < litTint[3],
    "and the world tint comes down with it")
  T.check(darkTint[3] > darkTint[2],
    "toward violet rather than flat grey -- blue survives the desaturation")
  T.check(darkIn[1] < 1,
    "indoors is darkened too: a building is not a refuge")

  T.same(DayNight.palette(DayNight.T.night), litPal,
    "and with the mode off the palette is byte-for-byte what it was")
  T.same(DayNight.tint(true, DayNight.T.night), litTint,
    "as is the world tint")

  -- ------- the flow field
  --
  -- A room with a wall down the middle and one gap in it. Every mob's next
  -- step comes off this sweep, so what is being pinned here is that the
  -- crowd walks THROUGH THE DOORWAY rather than into the wall -- which is
  -- the whole of "they path to you" and "they follow you inside".

  local Map = require("src.world.Map")
  local FLOOR, WALL = 1, 2
  local WIDTH, HEIGHT = 6, 5              -- in blocks; cells are twice that
  local blocks = {}
  for i = 1, WIDTH * HEIGHT do blocks[i] = FLOOR end
  local mapDef = {
    id = "HORDE_TEST", width = WIDTH, height = HEIGHT,
    blocks = blocks, borderBlock = WALL, tileset = "FIX_OUT",
    objects = {}, warps = {}, signs = {},
  }
  -- the tileset says which collision tiles may be stood on; FLOOR may,
  -- WALL may not
  local tilesetDef = {
    walkable = { FLOOR },
    blockdefs = nil,
  }
  -- Map:cellTile reads the block layer through the tileset's blockdefs; the
  -- fixture tileset has none, so stand in a cellTile that answers straight
  -- off a grid this test owns
  local walls = {}
  local map = Map.new(mapDef, tilesetDef)
  local W, H = map.widthCells, map.heightCells
  function map:cellTile(cx, cy)
    if cx < 0 or cy < 0 or cx >= W or cy >= H then return WALL end
    return walls[cy * W + cx] and WALL or FLOOR
  end
  -- a wall along cx = 5, with a single gap at cy = 1
  for cy = 0, H - 1 do
    if cy ~= 1 then walls[cy * W + 5] = true end
  end

  Mobs._rebuild(map, 2, 2)                -- the player, west of the wall
  T.eq(Mobs._dist(2, 2), 0, "the sweep starts on the player's own cell")
  T.eq(Mobs._dist(3, 2), 1, "and counts outward a cell at a time")
  T.eq(Mobs._dist(5, 2), nil, "the wall is not a cell anything stands on")

  -- east of the wall the only way in is the gap, so the distance there has
  -- to be the way ROUND, not the way through
  local through = Mobs._dist(6, 2)
  T.check(through ~= nil, "the far side of the wall is still reachable")
  local direct = math.abs(6 - 2) + math.abs(2 - 2)
  T.check(through > direct,
    "and costs more than the straight line, because the wall is in the way")
  T.eq(through, Mobs._dist(6, 1) + 1,
    "the cheapest way there is through the gap")

  -- a mob standing east of the wall must take a step that shortens the
  -- walk -- which, from there, means heading for the doorway
  local state = { map = map, entities = {}, player = { cellX = 2, cellY = 2 } }
  local mob = { cellX = 7, cellY = 3, px = 112, py = 48,
                facing = "down", moving = false, progress = 0 }
  state.entities[1] = mob
  Mobs._stepMob(state, { npc = mob })
  T.eq(mob.moving, true, "a mob with a path takes a step")
  local before = Mobs._dist(7, 3)
  local after = Mobs._dist(mob.targetX, mob.targetY)
  T.check(after and before and after < before,
    "and the step it takes is one that shortens the walk to the player")

  -- an occupied cell is stepped AROUND, not into: this is what makes a
  -- pack spread out around the player instead of queueing single file
  local blocker = { cellX = mob.targetX, cellY = mob.targetY }
  local mob2 = { cellX = 7, cellY = 3, px = 112, py = 48,
                 facing = "down", moving = false, progress = 0 }
  state.entities = { blocker, mob2 }
  Mobs._stepMob(state, { npc = mob2 })
  if mob2.moving then
    T.check(not (mob2.targetX == blocker.cellX
                 and mob2.targetY == blocker.cellY),
      "a mob never steps into a cell another one already holds")
  else
    T.check(true, "a boxed-in mob waits rather than walking through a body")
  end

  -- seal the gap and the east side is cut off entirely. A mob over there
  -- has nowhere to walk that gets it any closer, and must stand rather
  -- than guess -- an island across water is not a path.
  walls[1 * W + 5] = true
  Mobs._rebuild(map, 2, 2)
  T.eq(Mobs._dist(6, 2), nil, "walling the gap cuts the far side off")
  local stranded = { cellX = 7, cellY = 3, px = 112, py = 48,
                     facing = "down", moving = false, progress = 0 }
  state.entities = { stranded }
  Mobs._stepMob(state, { npc = stranded })
  T.eq(stranded.moving, false, "a mob with nowhere to go does not move")
  T.eq(stranded.facing, "left",
    "it turns toward the player instead, so the pack still reads as a threat")

  -- ------- the way out
  --
  -- START is asked, not taken: the mode does not pause, but it does have
  -- to be leavable, and every device's START (the pad's, the keyboard's
  -- ESCAPE, the touch overlay's) lands on the same GB button.
  T.eq(Horde.askExit(keyGame), false,
    "there is nothing to exit with the mode off")

  -- and asking while the mode IS on must not throw. Worth its own check:
  -- askExit reaches for this module's own overworld helper, and a Lua
  -- local declared BELOW the function that uses it is a nil global --
  -- which says nothing at load, nothing in a headless suite that never
  -- turns the mode on, and blows up the first time somebody presses
  -- ESCAPE. That is exactly how it shipped the first time.
  Horde.active, Horde.state = true, "active"
  local askedOk, askErr = pcall(Horde.askExit, keyGame)
  Horde.active, Horde.state = false, "idle"
  T.eq(askedOk, true, "asking the way out never throws: " .. tostring(askErr))

  -- ------- the banner wraps rather than running off the screen
  --
  -- The HUD's scale follows the window's zoom, so a player zoomed well in
  -- gets glyphs twice a large scale -- and the announcement was wider
  -- than the frame it was announcing over.
  local Hud = lib.require("HordeHud")
  local wrap = Hud._layout
  T.check(type(wrap) == "function", "the banner exposes its layout")

  -- a stand-in font of fixed-width glyphs: the real sheets are not in the
  -- fixture set, and pinning the line breaks against exact advances is a
  -- claim about the WRAPPING rather than about whatever art is loaded
  local stub = {
    encode = function(s)
      local out = {}
      for i = 1, #s do out[i] = s:byte(i) end
      return out
    end,
    advanceOf = function() return 8 end,
  }
  local SHOUT = "A DARKNESS APPROACHES"

  local wide = wrap(stub, SHOUT, 2, 4000)
  T.eq(#wide, 1, "given room, the announcement is one line")

  local narrow, smallBs = wrap(stub, SHOUT, 2, 300)
  T.check(#narrow > 1, "and wraps onto more lines when the frame is narrow")
  for _, line in ipairs(narrow) do
    T.check(line.width <= 300,
      ("every wrapped line fits the frame (%q is %d wide)")
        :format(line.text, line.width))
  end

  -- A scale far past what the frame can carry shrinks the glyphs rather
  -- than letting a word hang off the edge -- there is no wrap point
  -- inside a word, so wrapping alone cannot save this case. This is the
  -- one the player hit: the HUD's scale follows the window's zoom.
  local tiny, tinyBs = wrap(stub, SHOUT, 40, 200)
  for _, line in ipairs(tiny) do
    T.check(line.width <= 200,
      ("a scale the frame cannot carry shrinks to fit (%q is %d wide)")
        :format(line.text, line.width))
  end
  T.check(tinyBs < smallBs,
    "and that shrink really is a smaller glyph than the narrow case's")

  -- the degenerate end: one unbreakable word and almost no room. The
  -- glyph cannot go below one pixel, so this is allowed to overflow --
  -- what it may NOT do is fail to lay out
  local one = wrap(stub, "APPROACHES", 8, 4)
  T.check(one and #one == 1, "a single word always lays out on one line")
  T.eq(wrap(stub, "   ", 2, 100), nil, "and nothing but spaces lays out to nothing")

  -- ------- SMOOTH TURN belongs to the headset
  --
  -- A comfort setting for a device that is not plugged in decides
  -- nothing, so the row exists only while VR is ON -- and it is OFF by
  -- default, because a software turn moves the world past a head that
  -- did not move and that is how you make somebody ill in a headset.
  local VRMod = (function() local ok,m=pcall(function() return lib.require("VR") end); return ok and m or {} end)() -- may be nil when VR companion absent
  T.eq(VRMod.smoothTurn:get(), false, "SMOOTH TURN is off out of the box")

  Pipelines.setLevel("voxel", 3)          -- off FULL, which owns other rows
  VRMod.setting:sync(false)
  T.check(not Menus.rows("vr")["DRAMATIC_SHAPE:smoothturn"],
    "with VR off the row is not on the VR menu")
  -- and with the headset's own row the only thing left on it, that menu is
  -- still worth offering: a category is dropped when it is EMPTY, not when it
  -- is short
  T.check(Menus.rows(Menus.lib.ROOT)[Menus.catId("vr")],
    "though the category is, on the strength of the VR row alone")

  VRMod.setting:sync(true)
  local smoothRow = Menus.rows("vr")["DRAMATIC_SHAPE:smoothturn"]
  T.check(smoothRow ~= nil, "and with VR on it is")
  if smoothRow then
    T.eq(smoothRow.label, "SMOOTH TURN", "under its own name")
    T.eq(smoothRow.value(), "OFF", "reading OFF until the player says otherwise")
  end
  -- VR on takes the two battle rows away, which is the other half of the same
  -- gate: the headset requires staged battles and forbids back sprites, so
  -- both rows decide nothing there
  T.check(not Menus.rows("battles")["DRAMATIC_SHAPE:battles"],
    "and the battle rows are gone, being decided by the headset instead")
  VRMod.setting:sync(false)

  -- ------- the gun's own bookkeeping

  Gun.reset()
  local ammo, mag, reloading = Gun.ammo()
  T.eq(ammo, mag, "the gun starts with a full magazine")
  T.eq(reloading, false, "and is not reloading")
  T.eq(Gun.fire(), false, "and cannot be fired with no session running")
  T.eq(select(1, Gun.ammo()), mag, "a refused shot spends no round")
  T.eq(Gun.reload(), false, "nor reloaded when it is already full")
  T.eq(Gun.visible(), false, "and it is not drawn with the mode off")
end)()

-- ------- STADIUM: the .dsm packs, and the rig that reads them
--
-- Wrapped in its own scope for the same reason the horde block above is:
-- the main chunk is at Lua's 200-local ceiling, so a new top-level local
-- would refuse to compile.
--
-- What this is really guarding is the FORMAT SEAM. tools/stadium_pack.py
-- writes those files and lib/StadiumPack.lua reads them, and the two agree
-- only by having been written to agree -- there is no schema between them.
-- A field inserted on one side and not the other slides every byte after it
-- and produces no error at all: the models load, the numbers are garbage,
-- and every Pokemon is silently scaled to nothing. That is exactly what
-- happened once during development, and the assertion that caught it is the
-- one below -- walk the bind pose with the REAL rig code and check it
-- against the header the packer wrote, which cannot agree by accident.
;(function()
local Pack = run.loader.exports.DRAMATIC_SHAPE.lib.require("StadiumPack")
local Rig = run.loader.exports.DRAMATIC_SHAPE.lib.require("StadiumRig")

-- The packs are generated (tools/stadium_pack.py) and a checkout without
-- them is a legitimate state -- the mode declines per Pokemon. So the whole
-- block is skipped rather than failed when they are not there.
if not Pack.available(25) then
  T.check(true, "stadium packs are not installed -- pack assertions skipped")
  return
end

local pikachu = Pack.load(25)
T.check(pikachu ~= nil, "a stadium pack loads")
T.eq(pikachu.species, 25, "and knows which species it is")
T.eq(pikachu.boneCount, 37, "Pikachu's rig is 37 bones, as the extract reports")
T.check(pikachu.rootScale > 0.09 and pikachu.rootScale < 0.11,
  "the model_root scale came through as the 0.1 the geo layout sets")

-- the battle system's own slot table: idle is animation 0 for all 151
-- species (manifest.json's animationSlots calls that one `code` evidence)
T.eq(pikachu.ctx[Pack.SLOT.idle], 0, "the idle slot resolves to animation 0")
T.check(pikachu.ctx[Pack.SLOT.faint] ~= Pack.NONE, "and the faint slot resolves")
T.check(pikachu.ctx[Pack.SLOT.entrance] ~= Pack.NONE, "and the entrance slot")

-- the move table is the Gen 1 move id, which is the engine's own `index`
T.eq(#pikachu.moveAnim, Pack.N_MOVES, "every move id has a row")
T.check(pikachu.moveAnim[85] ~= Pack.NONE,
  "and THUNDERBOLT (move 85) names an animation Pikachu has")

-- animations decode lazily; asking for one is what builds its tracks
local tracks = Pack.tracks(pikachu, 1)
T.check(type(tracks) == "table", "an animation's tracks decode on demand")
local animated = 0
for b = 1, pikachu.boneCount do if tracks[b] then animated = animated + 1 end end
T.check(animated > 0 and animated <= pikachu.boneCount,
  "and move a sane number of the rig's bones")

-- THE SEAM. Walk the bind pose with the shipping rig code and measure it
-- the way tools/stadium_pack.py measured it. The packer's own answer was
-- checked against the reference glTF export on all 151 species, so
-- agreement here means the byte layout, the bone tree, the rotation basis
-- and the two-chain scale split all survived the trip into Lua.
local function bindExtent(model)
  local rig = setmetatable({
    model = model, pivotM = {}, drawM = {}, accX = {}, accY = {}, accZ = {},
    parts = {},
  }, Rig)
  rig:pose(nil, 0, false)
  local drw = rig.drawM
  local lo, hi = math.huge, -math.huge
  for _, prim in ipairs(model.prims) do
    for k = 1, prim.vertCount do
      local o = (prim.bone[k] - 1) * 12
      local y = drw[o + 5] * prim.px[k] + drw[o + 6] * prim.py[k]
                + drw[o + 7] * prim.pz[k] + drw[o + 8]
      y = y * model.rootScale
      if y < lo then lo = y end
      if y > hi then hi = y end
    end
  end
  return hi - lo, lo
end

for _, dex in ipairs({ 25, 6, 95, 143 }) do
  local model = Pack.load(dex)
  if model then
    local h, f = bindExtent(model)
    -- a tenth of a game unit of slack: bone translations are stored as
    -- integers and the packer measured in doubles
    T.check(math.abs(h - model.height) < 0.5,
      ("species %d: the rig's bind pose is the height the pack recorded "
       .. "(walked %.2f, header %.2f)"):format(dex, h, model.height))
    T.check(math.abs(f - model.floor) < 0.5,
      ("species %d: and its feet are where the pack put them"):format(dex))
  end
end

-- No species is held at its bind pose any more. Magmar (with Pidgeot,
-- Dodrio, Exeggutor and Tangela) uses the game's hermite-keyframe animation
-- mode, which the extractor used to misread as packed streams -- the flags
-- byte was read at +0, the always-zero high half of the u16 -- and the
-- packer then declared their exploding standby loops corrupt. The broken-
-- idle detector stays as the guard, so this asserts it no longer fires.
T.eq(Pack.load(126).staticPose, false,
  "Magmar animates -- its hermite animations decode correctly now")
T.eq(pikachu.staticPose, false, "and a packed-stream species does too")
end)()

-- ------- RENDER DIST: the orbit rungs cut to the window that frames them
--
-- The flat screen's answer to the same question the headset's diorama box
-- asks. Two halves, and this asserts both: the CUT the shader takes (a
-- rectangle, because a window is not square), and the SKIP it buys -- a
-- connected map lying entirely outside the box is never submitted.
;(function()

local lib = run.loader.exports.DRAMATIC_SHAPE.lib
local VB = lib.require("ViewBox")
local Dio = (function() local ok,m=pcall(function() return lib.require("Diorama") end); return ok and m or {} end)() -- may be nil when VR companion absent
local VS = lib.require("VoxelState")
local Curve = lib.require("WorldCurve")
local boxWas, curveWas = VB.setting:get(), Curve.setting:get()
local angleWas = VS.angle
Curve.setting:sync(0)

-- ------- the ladder
T.eq(VB.setting.values[1], 0,
  "FIT is rung 0, so an unset save lands on the cut rather than off it")
T.eq(VB.setting.labels[1], "FIT", "and FIT is what the row calls it")
T.eq(VB.setting.labels[#VB.setting.labels], "OFF",
  "OFF is the TOP of the ladder -- 'how much world' ending in all of it, "
  .. "rather than a switch beside the sizes")
for i = 2, #VB.FRACS - 1 do
  T.check(VB.FRACS[i] > VB.FRACS[i - 1],
    "the ladder opens out at rung " .. (i - 1))
end
T.eq(VB.FRACS[1], 1.0,
  "and FIT is exactly one window: the cut is the framing the flat game "
  .. "already had, not one this file made up")

-- ------- which rungs it is about
VB.setting:sync(0)
T.eq(VB.appliesTo(0), false, "OFF has no 3D pass to cut")
T.check(VB.appliesTo(VS.FULL_LEVEL), "FULL is cut -- it IS the model read")
T.check(VB.appliesTo(2) and VB.appliesTo(3) and VB.appliesTo(4)
        and VB.appliesTo(5),
  "and so is every orbit rung: 15, 35, 50 and 75")
T.eq(VB.appliesTo(VS.FP_LEVEL), false,
  "1ST is not: the player is standing IN the world, and a box round a "
  .. "walking eye is a fog-of-war circle rather than a model on a table")
T.eq(VB.appliesTo(VS.TP_LEVEL), false, "nor 3RD, which is the same rig")

-- ------- the footprint IS NOT the window
--
-- The bug this replaced: the box was the flat game's own vw-by-vh
-- rectangle, which is the ground a camera frames at 0 degrees and at no
-- rung the mode actually has. Every tilted rung frames a TRAPEZOID that
-- reaches further north and flares wider out there, and a window-sized box
-- cut the top and both sides off a world plainly on screen -- gaps, with
-- sky showing through them.
--
-- So the footprint is checked against a RAY CAST through the orbit's own
-- basis: the frame's corner rays dropped on the ground plane. If the closed
-- form and the rays ever disagree, the picture has a hole in it.
local REACH = VB.MAX_REACH * 288
local function castFootprint(a)
  local tanY = 1 / (2 * VS.FOCAL)
  local tanX = tanY * (320 / 288)
  local k = VS.FOCAL * 288
  local ca, sa = math.cos(a), math.sin(a)
  local n, s, x = -1e18, -1e18, 0
  for i = 0, 200 do
    local sy = -1 + 2 * i / 200
    -- forward (0,-ca,-sa), true up (0,sa,-ca), right (1,0,0)
    local dy = -ca + sy * tanY * sa
    local dz = -sa - sy * tanY * ca
    if dy < -1e-9 then
      local t = (k * ca) / -dy                 -- eye height over the drop
      local wz, wx = k * sa + t * dz, t * tanX
      if -wz > n then n = -wz end
      if wz > s then s = wz end
      if wx > x then x = wx end
    end
  end
  return n, s, x
end
for _, deg in ipairs({ 0, 15, 35, 50 }) do
  local n, s, x = castFootprint(math.rad(deg))
  local fn, fs, fx = VB.footprint(math.rad(deg), 320, 288, REACH)
  T.check(math.abs(fn - n) < 1 and math.abs(fs - s) < 1
          and math.abs(fx - x) < 1,
    ("%d degrees: the footprint is the ground the rays actually land on "
     .. "(north %.0f/%.0f, south %.0f/%.0f, side %.0f/%.0f)")
      :format(deg, fn, n, fs, s, fx, x))
end
-- straight down is the ONE case the old window-sized box got right, which
-- is why it survived being wrong everywhere else
do
  local n, s, x = VB.footprint(0, 320, 288, REACH)
  T.check(math.abs(n - 144) < 1e-6 and math.abs(s - 144) < 1e-6
          and math.abs(x - 160) < 1e-6,
    "at 0 degrees it reduces to the flat window, exactly")
end
-- and the shape of the error the gaps were: north grows with the tilt,
-- south SHRINKS (the bottom of the frame is nearer than the focus), and
-- the sides flare with the far field
do
  local n15, s15, x15 = VB.footprint(math.rad(15), 320, 288, REACH)
  local n50, s50, x50 = VB.footprint(math.rad(50), 320, 288, REACH)
  T.check(n15 > 144 and n50 > n15,
    "every tilted rung reaches further north than the window did -- which "
    .. "is the gap that used to open along the top")
  T.check(s15 < 144,
    "and less far south, because the bottom of the frame is nearer the eye "
    .. "than the focus is")
  T.check(x15 > 160 and x50 > x15,
    "and wider at the sides, because the far field is further away -- the "
    .. "other gap")
  T.check(s50 < n50 * 0.5,
    "so the picture is mostly AHEAD of the view centre, and the box has to "
    .. "sit north of it rather than around it")
end
-- past atan(2*FOCAL) -- about 63 degrees -- the horizon is inside the frame
-- and the honest answer is infinite. That is the whole reason there is a
-- row: something has to name a distance.
do
  local n75 = VB.footprint(math.rad(75), 320, 288, REACH)
  T.check(math.abs(n75 - REACH) < 1,
    "at 75 the footprint is unbounded and the reach stands in for it")
  local near = VB.footprint(math.rad(75), 320, 288, REACH / 2)
  T.check(near < n75, "and a shorter reach brings the world's edge in")
end

-- ------- the cut itself
VS.angle = math.rad(35)
local box = VB.frame(100, 200, 320, 288, 3)
T.eq(box.kind, Dio.BOX, "the cut is the shader's BOX kind, like the diorama's")
T.eq(box.x, 100, "centred on the view in x, which the trapezoid is")
T.check(box.z < 200,
  "and NORTH of it in z, which the trapezoid also is -- a box centred on "
  .. "the view centre is the bug that cut the top off")
do
  local n, s, x = VB.footprint(math.rad(35), 320, 288, REACH)
  -- the south edge is the ground the bottom ray lands on PLUS what stands
  -- there: a tree's feet are south of the row its top is seen on, and the
  -- cut is by column (see lift)
  s = s + VB.lift(math.rad(35)) + VB.SOUTH_PAD
  T.check(math.abs(box.rz - (n + s) * 0.5) < 1e-6,
    "the half-depth spans the footprint from its south edge to its north")
  T.check(math.abs(box.z - (200 - (n - s) * 0.5)) < 1e-6,
    "and the centre sits exactly between them")
  T.check(math.abs(box.rx - x) < 1e-6, "with the far field's own half-width")
  T.check(box.rz > 144 and box.rx > 160,
    "both bigger than the window at every tilted rung, so the cut can "
    .. "never take a bite out of the picture")
end

-- ------- and the geometry standing on the ground it frames
--
-- The bug: the box was cut to where the frame's rays hit the GROUND, and
-- the ground is not what the picture is made of. At every rung past the
-- frame's own half-angle the bottom of the screen shows things whose FEET
-- are south of that line, and the shader cuts by column -- so a tree one
-- pixel outside lost its whole height and the bottom of the frame wore a
-- bite out of the scenery, the ground behind showing through.
do
  local tanY = 1 / (2 * VS.FOCAL)
  T.eq(VB.lift(0), 0,
    "straight down nothing is lost: a raised point lands NORTH of where its "
    .. "own ray hits the ground, which no cut can take")
  T.eq(VB.lift(math.atan(tanY)), 0,
    "and up to atan(tanY) -- the frame's own half-angle -- it still is")
  T.check(VB.lift(math.rad(35)) > 0 and VB.lift(math.rad(50)) > VB.lift(math.rad(35))
          and VB.lift(math.rad(75)) > VB.lift(math.rad(50)),
    "past it the lift opens with the tilt: the flatter the eye, the more of "
    .. "a tree is what sits under the bottom of the frame")
  -- against the ray it is derived from: a point HEIGHT up on the bottom
  -- edge's own ray, dropped to the ground, is exactly this far south of
  -- where that ray lands
  for _, deg in ipairs({ 35, 50, 75 }) do
    local a = math.rad(deg)
    local dy = -(math.cos(a) + tanY * math.sin(a))
    local dz = -(math.sin(a) - tanY * math.cos(a))
    T.check(math.abs(VB.lift(a) - VB.HEIGHT * (-dz / -dy)) < 1e-9,
      ("%d degrees: the lift is that ray walked back up by HEIGHT")
        :format(deg))
  end
  -- and it is in the CUT, at FIT, which is the rung the artefact was seen on
  VS.angle = math.rad(35)
  local fit = VB.frame(0, 0, 320, 288, 3)
  local n, s = VB.footprint(math.rad(35), 320, 288, REACH)
  T.check(fit.z + fit.rz >= s + VB.lift(math.rad(35)) - 1e-6,
    "so the box's south edge clears the feet of everything the bottom of "
    .. "the frame can show, tree tops included")
  T.check(fit.z + fit.rz > s and fit.z - fit.rz < -n + 1e-6,
    "without moving the north edge, which the reach already decides")
end
VS.angle = math.rad(35)
box = VB.frame(100, 200, 320, 288, 3)
T.check(box.rx ~= box.rz,
  "which is the whole reason the box kind carries two half-extents: a "
  .. "square cut on a wide frame either loses the sides or overshoots")
T.check(1 / box.invFade <= 0.5,
  "with a HARD edge while the world is flat: that IS the sides")
-- and the diorama's own box still passes the same number twice, so one
-- shader branch serves both
local sq = Dio.viewport(0, 0, 288)
T.eq(sq.rx, sq.r, "a headset's box is square in x")
T.eq(sq.rz, sq.r, "and in z -- no window to be shaped like")

-- the row opens it out, and OFF stops cutting entirely
VB.setting:sync(1)
local wide = VB.frame(100, 200, 320, 288, 3)
T.check(wide.rx > box.rx and wide.rz > box.rz,
  "a wider rung reaches further in both directions")
VB.setting:sync(#VB.setting.values - 1)
T.eq(VB.setting:get(), 4, "the top rung is OFF")
T.eq(VB.frame(100, 200, 320, 288, 3), nil, "and OFF cuts nothing at all")
T.eq(VB.cull, nil, "leaving no viewport on the module for a pass to inherit")

-- a bent world has no straight sides, so the rim dissolves under V-CURVE --
-- the same call Diorama.fadeFor makes for the same reason
VB.setting:sync(0)
Curve.setting:sync(3)
local bent = VB.frame(0, 0, 320, 288, 3)
T.check(1 / bent.invFade > 1,
  "V-CURVE softens the box's rim: a hard edge across a bent world is a "
  .. "lie about what is being looked at")
Curve.setting:sync(0)

-- ------- the coarse half: whole maps skipped before they are drawn
VB.setting:sync(0)
VS.angle = math.rad(35)
local cut = VB.frame(0, 0, 320, 288, 3)
-- a 10x9-block map (Pallet's shape) at the origin is under the box
local here = { map = { def = { width = 10, height = 9 } }, ox = 0, oy = 0 }
T.check(VB.showsMap(here), "the map under the box is drawn")
-- the same map pushed a long way north-east cannot reach the picture
local far = { map = { def = { width = 10, height = 9 } },
              ox = 4000, oy = 4000 }
T.eq(VB.showsMap(far), false,
  "a connected map entirely outside the box is skipped -- no terrain, no "
  .. "water, no grass, no flowers and no shadow pass")
-- the test is taken against the CUT's own edge, which is the trapezoid's
-- and not the window's -- the border ring is meshed outside a map's own
-- rectangle, so a map that stops just short still has trees in frame
T.check(VB.showsMap({ map = { def = { width = 1, height = 1 } },
                      ox = cut.x + cut.rx + VB.PAD - 8, oy = cut.z }),
  "a map just outside the edge is kept for its border ring, which is "
  .. "meshed beyond its own rectangle")
T.eq(VB.showsMap({ map = { def = { width = 1, height = 1 } },
                   ox = cut.x + cut.rx + VB.PAD + 64, oy = cut.z }), false,
  "and dropped once even the ring cannot reach")
-- and the skip follows the trapezoid north: a map the OLD window-sized box
-- would have thrown away is still on screen at a tilted rung
T.check(VB.showsMap({ map = { def = { width = 4, height = 4 } },
                      ox = -64, oy = -200 }),
  "a map north of the view centre, past where a window-sized box ended, "
  .. "is kept -- the camera is looking straight at it")
VB.stop()
T.check(VB.showsMap(far),
  "with no box open every map is drawn, so a caller may guard "
  .. "unconditionally -- which is every headset frame and every OFF rung")
T.check(VB.showsMap(nil), "and a malformed neighbour is never skipped")

-- ------- the sun has to notice the row
--
-- WHICH neighbours went into the shadow map is now a function of the box,
-- and the box is the one input the sun's signature did not already carry.
VB.setting:sync(0)
local sigFit = VB.signature()
VB.setting:sync(2)
T.neq(VB.signature(), sigFit,
  "opening the row out changes the sun's signature, so a map recorded "
  .. "without a neighbour is redrawn with it")

Curve.setting:sync(curveWas)
VB.setting:sync(boxWas)
VS.angle = angleWas
end)()

-- ------- LET'S GO: the capture mode's arithmetic and the ball's pose
--
-- The throw itself is a rendered, pointer-driven thing the suite cannot
-- fly, but everything consequential under it is plain arithmetic and runs
-- headless: the scaled experience formula (checked against the published
-- Let's Go table), the combo ladder, and the Pokeball prop's state
-- machine, which must load and animate without a GPU.
;(function()
  local lib = run.loader.exports.DRAMATIC_SHAPE.lib
  local LetsGo = lib.require("LetsGo")
  local Pokeball = lib.require("Pokeball")
  local Mat4 = lib.require("Mat4")

  -- the reference points from the community-measured table: a Lv30
  -- Chansey (base exp 395) pays 2371 to a Lv30 receiver and 5497 to a
  -- Lv10 one, before any catch bonuses
  T.eq(LetsGo._scaledGain({ defeatedDef = { baseExp = 395 }, level = 30,
                            mon = { level = 30 } }, 1), 2371,
    "the scaled formula at equal levels is b*L/5 + 1 -- the table's 2371")
  T.eq(LetsGo._scaledGain({ defeatedDef = { baseExp = 395 }, level = 30,
                            mon = { level = 10 } }, 1), 5497,
    "and a Lv10 receiver pulls the table's 5497 from the same catch -- "
    .. "the receiver's own level is in the denominator")
  T.check(LetsGo._scaledGain({ defeatedDef = { baseExp = 40 }, level = 3,
                               mon = { level = 100 } }, 1) >= 1,
    "a trivial catch still pays at least one point")

  -- ------- the capture seat speaks the pull's own language
  --
  -- The seat hands BattleScene a pitch, and the only thing downstream reads
  -- it is the camera-ward pull the grass and flowers are drawn with. That
  -- angle is measured off STRAIGHT DOWN -- Voxel.angle's convention, and
  -- BattleCam.rig's -- and this rig used to answer the DEPRESSION below
  -- level instead, which is its complement. A seat looking nearly level
  -- therefore read as "straight down", the end of the ladder where the pull
  -- is at its longest: 46 world pixels of bias handed to a camera standing
  -- 46 world pixels behind the player. The pull is a shove along each
  -- vertex's own eye ray, so at that range it carried the grass at the eye
  -- THROUGH the lens, and a tuft landed smeared across the top of the frame.
  do
    local CatchThrow = lib.require("CatchThrow")
    local BattleCam = lib.require("BattleCam")
    local VoxelScene = lib.require("VoxelScene")
    -- two mons two cells apart, the arena laid down unturned
    local arena = { player = { 100, 200 }, enemy = { 100, 168 },
                    mid = { 100, 184 }, turn = 0 }
    local seat, pitch = CatchThrow._rig(arena, 0)
    T.check(pitch > math.rad(75),
      ("the capture seat reads as NEARLY LEVEL (%.1f degrees off straight "
       .. "down), which is what it is"):format(math.deg(pitch)))
    local _, camPitch = BattleCam.rig(arena, 0, true)
    T.check(camPitch > math.rad(45) and pitch > math.rad(45),
      "in the same convention the battle's own rig hands back, so one pull "
      .. "formula can serve both seats")
    -- the invariant the bug broke: a bias along the eye ray must never
    -- reach the eye, or the vertex comes out behind the lens
    local dx, dz = seat.eye[1] - arena.player[1], seat.eye[3] - arena.player[2]
    local range = math.sqrt(dx * dx + dz * dz)
    T.check(VoxelScene.pull(math.max(pitch, 0.05)) < range * 0.5,
      ("the grass pull (%.1f px) stays well inside the seat's own range to "
       .. "the player's cell (%.1f px) -- the tufts it is biasing are the "
       .. "ones standing right there")
        :format(VoxelScene.pull(math.max(pitch, 0.05)), range))
  end

  -- and the same formula pays TRAINER knockouts under FULL, with the
  -- wild/trainer 1.5 that a catch never sees (a caught Pokemon is always
  -- wild, which is why the catch numbers above are untouched by it)
  local wildKO = LetsGo._scaledGain({ defeatedDef = { baseExp = 395 },
                                      level = 30, mon = { level = 30 } }, 1)
  local trainerKO = LetsGo._scaledGain({ defeatedDef = { baseExp = 395 },
                                         level = 30, mon = { level = 30 },
                                         isTrainer = true }, 1)
  T.eq(wildKO, 2371, "a wild payout is unchanged by the trainer term")
  T.eq(trainerKO, 3556, "a trainer's Pokemon pays the same formula at 1.5")
  T.check(trainerKO > wildKO, "which is more than the same wild one")
  -- the receiver's own level still drives it, which is the whole point of
  -- sharing to the party: the low member gains multiples of the high one
  local lowKO = LetsGo._scaledGain({ defeatedDef = { baseExp = 395 },
                                     level = 30, mon = { level = 5 },
                                     isTrainer = true }, 1)
  T.check(lowKO > trainerKO * 2,
    "a level 5 party member takes several times what a level 30 one does "
    .. "from the very same knockout")

  -- the combo ladder's five tiers
  T.eq(LetsGo._comboMult(1), 1.1, "a fresh combo is the 1.1 tier")
  T.eq(LetsGo._comboMult(10), 1.1, "which runs to ten")
  T.eq(LetsGo._comboMult(11), 1.5, "eleven starts the 1.5 tier")
  T.eq(LetsGo._comboMult(21), 2.0, "twenty-one the 2.0")
  T.eq(LetsGo._comboMult(31), 2.5, "thirty-one the 2.5")
  T.eq(LetsGo._comboMult(41), 3.0, "and forty-one caps it at 3.0")
  T.eq(LetsGo._comboMult(999), 3.0, "where it stays")

  -- the row answers the mode, and OFF answers false
  T.eq(LetsGo.mode(), false, "LET'S GO defaults to OFF")

  -- The capture's buttons are read on the LOGIC STEP, through the engine's
  -- input.step seam, because edges do not survive the render clock (see
  -- CatchThrow.buttons). The hook calls it under pcall, so a rename would
  -- be swallowed silently and B would simply stop working -- which is
  -- exactly the failure it was written to fix. Assert the name exists, and
  -- that it is harmless with no session, since it runs every single step.
  do
    local CatchThrow = lib.require("CatchThrow")
    T.eq(type(CatchThrow.buttons), "function",
      "the capture reads its buttons on the logic step, by name")
    local q = { "a", "b" }
    CatchThrow.buttons({ input = { pressQueue = q } })
    T.eq(#q, 2, "and with no session in flight it takes nothing and does nothing")
  end

  -- ------- the scripted catch tutorials are none of LET'S GO's business
  --
  -- The VIRIDIAN CITY old man and Yellow's PROF.OAK / PIKACHU intro are
  -- the same makeOldManDemo cutscene: the cursor, the bag and the throw
  -- are all scripted, and nobody keeps the Pokemon. Every rung has to
  -- leave them exactly as the engine plays them.
  T.eq(LetsGo.scripted({ demo = true }), true,
    "the old man's tutorial is a scripted battle")
  T.eq(LetsGo.scripted({ demo = true, oakDemo = true }), true,
    "and so is PROF.OAK catching the PIKACHU")
  T.eq(LetsGo.scripted({ kind = "wild" }), false,
    "an ordinary wild encounter is not")
  T.eq(LetsGo.scripted(nil), false, "and no battle at all is not either")
  do
    -- the predicates that gate every FULL behaviour, read at FULL
    local realMode = LetsGo.mode
    LetsGo.mode = function() return "full" end
    T.eq(LetsGo.fullWild({ kind = "wild" }), true,
      "FULL owns an ordinary wild encounter")
    T.eq(LetsGo.fullWild({ kind = "wild", demo = true }), false,
      "but never the old man's demo, whatever the row says")
    T.eq(LetsGo.fullWild({ kind = "wild", oakDemo = true }), false,
      "nor PROF.OAK's")
    T.eq(LetsGo.wantsMinigame({ kind = "wild", demo = true }), false,
      "and a scripted throw is never handed the minigame")
    LetsGo.mode = realMode
  end

  -- the ball: a full open-drop-rock-click life without a GPU
  T.eq(Mat4.rotateZ ~= nil, true, "Mat4 grew the roll the wobble rocks on")
  do
    local m = Mat4.rotateZ(math.pi / 2)
    -- row-major: x' of (1,0,0) is m[1], y' is m[5]
    T.check(math.abs(m[1]) < 1e-9 and math.abs(m[5] - 1) < 1e-9,
      "rotateZ carries +X onto +Y, the right-handed roll")
  end
  local ball = Pokeball.new("GREAT_BALL")
  T.eq(ball.lid, 0, "a fresh ball is shut")
  ball:open()
  for _ = 1, 60 do ball:update(1 / 60) end
  T.eq(ball.lid, 1, "open() hinges the lid fully over its ramp")
  T.check(ball.glow < 1, "and the mouth glow decays on its own")
  ball:close()
  for _ = 1, 60 do ball:update(1 / 60) end
  T.eq(ball.lid, 0, "close() brings it back")
  local dur = ball:rock(1)
  T.check(dur > 0, "a rock reports its duration for the caller's cadence")
  T.check(ball:busy(), "and the ball is busy while it rocks")
  for _ = 1, math.ceil(dur * 60) + 2 do ball:update(1 / 60) end
  T.check(not ball:busy(), "then settles")
  ball:catchClick()
  T.check(ball.stars ~= nil, "the caught click spawns its stars")
  local matrix = ball:matrix()
  T.eq(#matrix, 16, "the pose is one model matrix")
  for _ = 1, 120 do ball:update(1 / 60) end
  T.check(ball.stars == nil, "and the stars burn out on their own")
end)()

-- ------- an interior wall caps with its own plain course
--
-- A wall band is 16px of art over a run two drawn rows deep, so it folds
-- ENTIRELY onto its south face and has no drawn row left to lay flat on
-- top. The top therefore repeated the face: the town house's town-map
-- poster and window, and the Pokemon Center's pokeball poster, came out
-- lying across the top of the wall as well as hanging on it -- a picture
-- you look DOWN on from the voxel camera.
--
-- `wall_top` names the capping course per tileset (the plain panel the
-- decorated column's own neighbours draw), and it is a fact about the
-- drawing that no measurement of the geometry can recover -- nothing
-- distinguishes "poster" from "panel" but knowing which is which.
;(function()
  local Mesher = run.loader.exports.DRAMATIC_SHAPE.lib.require("ChunkMesher")
  local Struct = run.loader.exports.DRAMATIC_SHAPE.lib.require("Structures")
  local Shape = run.loader.exports.DRAMATIC_SHAPE.lib.require("TileShape")

  -- the blanket form: whatever a wall cell draws, it caps with the one
  -- course the atlas's rooms are panelled in
  T.eq(Shape.wallTop("HOUSE")(45), 0,
    "the town house caps its walls with the blank course")
  T.eq(Shape.wallTop("POKECENTER")(2), 40,
    "and a Center with its striped panel -- the tile cell (9,0) draws")
  T.eq(Shape.wallTop("REDS_HOUSE_2")(36), 0,
    "Red's bedroom with its own blank panel, over the window")
  T.eq(Shape.wallTop("REDS_HOUSE_1")(36), 0, "and so does the floor below")
  -- the keyed form, for an atlas that dresses more than one kind of room
  T.eq(Shape.wallTop("LOBBY")(40), 93,
    "the Rocket lift's car door caps with the cabin frame")
  T.eq(Shape.wallTop("LOBBY")(1), nil,
    "but the department store's own panel is left exactly as it was -- "
    .. "one atlas, several rooms, and only the lift is a lift")
  T.eq(Shape.wallTop("DS_NO_SUCH_TILESET"), nil,
    "a tileset that says nothing keeps the top it always had")

  local FLOOR = 1
  local function topTiles(tilesetId, rows)
    local map = {
      id = "DS_TEST_WALLTOP_" .. tilesetId,
      tileset = { id = tilesetId, image = "gfx/tilesets/ds_test.png",
                  tilesPerRow = 16, imageWidth = 128, imageHeight = 48,
                  blocks = {}, grassTile = -1 },
      def = { width = 4, height = 2, tileset = tilesetId },
      walkable = { [FLOOR] = true },
      waterTiles = {},
      doorTiles = {},
      tileAt = function(_, tx, ty)
        local r = rows[ty + 1]
        return (r and r[tx + 1]) or FLOOR
      end,
      cellTile = function(self, cx, cy) return self:tileAt(cx * 2, cy * 2 + 1) end,
      isWaterCell = function() return false end,
      isWalkableCell = function(self, cx, cy)
        return self:cellTile(cx, cy) == FLOOR
      end,
      inBounds = function(_, cx, cy)
        return cx >= 0 and cy >= 0 and cx < 4 and cy < 2
      end,
    }
    Struct.invalidate(map.id)
    local verts = Mesher.geometry(map, true, nil)
    -- the flat quads standing at wall height, keyed by the column they cap
    local out = {}
    for i = 1, #verts, 4 do
      local a, b, c, d = verts[i], verts[i + 1], verts[i + 2], verts[i + 3]
      if a[2] == b[2] and b[2] == c[2] and c[2] == d[2] and a[2] == 16 then
        local ax = math.floor(math.min(a[4], b[4], c[4], d[4]) * 128 + 0.5)
        local ay = math.floor(math.min(a[5], b[5], c[5], d[5]) * 48 + 0.5)
        local tx = math.floor(math.min(a[1], b[1], c[1], d[1]) / 8)
        local ty = math.floor(math.min(a[3], b[3], c[3], d[3]) / 8)
        -- keyed by the TILE ROW too: a wall band is two drawn rows deep
        -- and they can wear different art
        out[ty * 100 + tx] = out[ty * 100 + tx]
                             or (math.floor(ay / 8) * 16 + math.floor(ax / 8))
      end
    end
    return out, verts
  end

  -- BLUES_HOUSE's back wall: blank panel, the town-map poster (45/46 over
  -- 61/62) at cell (3,0)'s block, the window (36 over 52) at (5,0)'s
  local houseTops, houseVerts = topTiles("HOUSE", {
    { 0, 0, 45, 46, 36, 36, 0, 0 },
    { 0, 0, 61, 62, 52, 52, 0, 0 },
  })
  for ty = 0, 1 do
    for tx = 0, 7 do
      T.eq(houseTops[ty * 100 + tx], 0,
        ("(%d,%d) of the house's back wall caps with the blank course")
        :format(tx, ty))
    end
  end

  -- and the FACE is untouched: the poster still hangs in the room, which is
  -- the half of this the fix must not take with it
  local hung = {}
  for _, v in ipairs(houseVerts) do
    hung[math.floor(math.floor(v[5] * 48 + 0.5) / 8) * 16
         + math.floor(math.floor(v[4] * 128 + 0.5) / 8)] = true
  end
  T.check(hung[45] and hung[46] and hung[61] and hung[62],
    "the town-map poster is still drawn on the wall it hangs on")
  T.check(hung[36] and hung[52], "and so is the window")

  -- VIRIDIAN_POKECENTER's back wall: the striped panel with the pokeball
  -- poster (2/3 over 18/19) spanning cells (3,0) and (4,0)
  local pcTops = topTiles("POKECENTER", {
    { 40, 40, 40, 2, 3, 40, 40, 40 },
    { 40, 40, 40, 18, 19, 40, 40, 40 },
  })
  for ty = 0, 1 do
    for tx = 0, 7 do
      T.eq(pcTops[ty * 100 + tx], 40,
        ("(%d,%d) of the Center's back wall caps with the striped panel")
        :format(tx, ty))
    end
  end

  -- ------- the Rocket lift's car doors
  --
  -- Detected rather than pinned -- the doors are a volume Structures finds
  -- -- so the cap has to reach the RUN branch too, not only the pinned one.
  local liftTops = topTiles("LOBBY", {
    { 92, 92, 92, 92, 92, 92, 92, 92 },
    { 93, 93, 93, 93, 93, 93, 93, 93 },
    {  1,  1, 40, 40, 40, 40,  1,  1 },
    { 33, 33, 56, 56, 56, 56, 33, 33 },
  })
  -- rows 2 and 3 are the doors' own band; the doors span columns 2-5
  for ty = 2, 3 do
    for tx = 2, 5 do
      T.eq(liftTops[ty * 100 + tx], 93,
        ("(%d,%d) of the lift's door caps with the cabin frame"):format(tx, ty))
    end
  end
  -- and the panelling either side of them is left alone, which is what the
  -- keyed form buys: the same atlas panels the department store
  T.eq(liftTops[2 * 100], 1, "the blank course beside the door is untouched")
  T.eq(liftTops[3 * 100], 33, "and so is its skirting")
end)()

-- ------- Lance's room is furnished with the badge gyms' statue
--
-- The same drawing on a different atlas: one cell of bird over one cell of
-- plinth. Left derived the pair merged into one 32px volume wearing the
-- statue folded onto its face -- the extruded picture. The gyms' reading
-- (solid plinth, per-pixel standee on top) is the right one here too, and
-- these eight tiles draw nothing else anywhere in the game.
;(function()
  local Shape = run.loader.exports.DRAMATIC_SHAPE.lib.require("TileShape")
  local shapes = Shape.forMap({
    tileset = { id = "DOJO", tilesPerRow = 16,
                imageWidth = 128, imageHeight = 48, grassTile = -1 },
    walkable = { [17] = true },
  })
  for _, t in ipairs({ 2, 18, 19, 56 }) do
    T.eq(shapes[t].class, "prop",
      ("the statue's figure tile %d stands as a per-pixel cutout"):format(t))
    T.eq(shapes[t].authored, true, "and it is an authored answer, not derived")
  end
  for _, t in ipairs({ 34, 35, 50, 51 }) do
    T.eq(shapes[t].class, "wall",
      ("the plinth tile %d stays a solid 16px block"):format(t))
    T.eq(shapes[t].authored, true,
      "authored, which is what the standee's support rule tests -- and "
      .. "what keeps tile 50 ($32) out of the water-fallback trap")
  end
  T.eq(shapes[13].class, "bookcase",
    "and Oak's shelf ranks on the same atlas are untouched")
end)()

-- ------- a wall cut into a terrace inherits TERRACE, never a statue
--
-- `bookcase_backfill = "above"` hands a vacated row the cell above the run,
-- so masonry set into a hillside has more hillside behind it rather than a
-- trench. Indigo Plateau's avenue statues stand directly on the pilasters
-- that collapse this way, so what every one of them inherited was the BIRD:
-- the figure's shape and art copied onto two more rows down the shaft, and
-- the statue came out two deep behind itself. A standee above is an object
-- standing ON the terrace, not terrace -- so there is nothing to inherit.
;(function()
  local Struct = run.loader.exports.DRAMATIC_SHAPE.lib.require("Structures")
  -- the real west-edge statue of INDIGO_PLATEAU, tile for tile: the bird
  -- (37/38 over 40/41) on the pilaster (cap 21/22, shaft 5/6 twice, foot
  -- 21/22), standing on the plateau's paving (35)
  local rows = {
    { 46, 47 }, { 46, 47 },
    { 37, 38 }, { 40, 41 },
    { 21, 22 }, {  5,  6 },
    {  5,  6 }, { 21, 22 },
    { 35, 35 }, { 35, 35 },
    { 35, 35 }, { 35, 35 },
  }
  local map = {
    id = "DS_TEST_PLATEAU_STATUE",
    tileset = { id = "PLATEAU", image = "gfx/tilesets/ds_test.png",
                tilesPerRow = 16, imageWidth = 128, imageHeight = 40,
                blocks = {}, grassTile = -1 },
    def = { width = 1, height = 3, tileset = "PLATEAU" },
    walkable = { [35] = true },
    waterTiles = {},
    doorTiles = {},
    tileAt = function(_, tx, ty)
      local r = rows[math.max(1, math.min(#rows, ty + 1))]
      return r[(tx % 2) + 1]
    end,
    cellTile = function(self, cx, cy) return self:tileAt(cx * 2, cy * 2 + 1) end,
    isWaterCell = function() return false end,
    isWalkableCell = function(self, cx, cy)
      return self:cellTile(cx, cy) == 35
    end,
    isDoorTileCell = function() return false end,
    isGrassCell = function() return false end,
    inBounds = function(_, cx, cy)
      return cx >= 0 and cy >= 0 and cx < 2 and cy < 6
    end,
  }
  Struct.invalidate(map.id)
  local S = Struct.forMap(map)
  local function keyOf(tx, ty) return (ty + 64) * 4096 + (tx + 64) end

  -- the bird stands, once, where it is drawn
  for _, ty in ipairs({ 2, 3 }) do
    T.eq(S.shapeAt[keyOf(0, ty)].art, "billboard",
      "the statue's own rows carry the standee")
  end
  -- and the pilaster rows it vacates carry NOTHING -- not a second bird
  for _, ty in ipairs({ 4, 5, 6, 7 }) do
    local s = S.shapeAt[keyOf(0, ty)]
    T.check(s == nil or s.art ~= "billboard",
      ("pilaster row %d did not inherit the statue standing on it"):format(ty))
  end

  -- ...and the bird stands on the box rather than where it is DRAWN. The
  -- collapse walks the whole four-row pilaster onto its southmost cell, so
  -- a standee that trusted its own drawn position ended up a full cell
  -- north of the pillar holding it up -- at the right height, over open
  -- ground. Every row of the rank records where the box actually went.
  for _, ty in ipairs({ 4, 5, 6, 7 }) do
    T.eq(S.bookcaseBox[keyOf(0, ty)], 6,
      ("rank row %d knows the box stands on row 6"):format(ty))
  end
  local zlo = math.huge
  for _, q in ipairs(S.objectQuads) do
    for i = 1, 4 do zlo = math.min(zlo, q[i][3]) end
  end
  T.eq(math.floor(zlo / 8), 6,
    "and the statue's own geometry starts on that row -- standing on the "
    .. "pillar, not hanging in the air two cells in front of it")
end)()

-- ------- persistent Android voxel BODY cache

;(function()
  local lib = run.loader.exports.DRAMATIC_SHAPE.lib
  dofile(MOD_PATH .. "/tests/voxel_mesh_cache_test.lua")(
    T,
    lib.require("VoxelMeshCache"),
    lib.require("ChunkMesher"),
    lib.require("VoxelScene"),
    lib.require("TerrainAtlas"),
    lib.require("VoxelCacheScreen"),
    lib.require("Structures"),
    MOD_PATH)
end)()

Pipelines.reset()
run.release()

T.finish("DRAMATIC_SHAPE")
