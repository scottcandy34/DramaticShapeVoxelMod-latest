local V = ...

local Voxel           = V.require("voxel/VoxelState")
local VoxelGrid       = V.require("voxel/VoxelGrid")
local WorldCurve      = V.require("effects/WorldCurve")
local ViewBox         = V.require("voxel/ViewBox")
local OverworldBattle = V.require("battle/OverworldBattle")
local Shiny           = V.require("shiny/Shiny")
local DayNight        = V.require("effects/DayNight")
local Water           = V.require("effects/Water")
local ForestAtmos     = V.require("effects/ForestAtmos")
local Shadows         = V.require("effects/Shadows")
local AntiAlias       = V.require("effects/AntiAlias")
local VR              = V.require("vr/VR")
local SettingsMenu    = V.require("ui/settings/SettingsMenu")
local LetsGo          = V.require("modes/catch/LetsGo")

-- ------- this mod's own settings
--
-- Neither of these is a pipeline: they own no pass of the frame, they
-- PARAMETERISE the voxel one, so they have nothing to put in drawWorld or
-- present and the registry would rightly reject them.  Plain mod settings
-- instead -- see ModSetting for where they persist and how the two rows
-- each ends up on stay in step.

-- Whether a fight can be staged on the map, as far as the OPTIONS menu is
-- concerned: the 3D-BTL row, and nothing else.
--
-- It used to answer yes under FULL as well, on the grounds that FULL owned
-- that row and switched it on. FULL no longer owns it -- the row stays on the
-- menu under FULL and can be switched off there (see the rows hook) -- so that
-- clause would now claim staged battles for a preset the player had just
-- turned them off inside, pinning BATTLE LAYOUT to OG for a fight that is
-- never staged. The row is the only thing that decides, which is what every
-- other reader of this setting already believed: OverworldBattle.begin and
-- wantsFront both gate on enabled() alone.
--
-- Deliberately NOT gated on Voxel3D.available(): the engine offers a
-- pipeline's row whether or not the hardware can run it (Pipelines.rows), so
-- this mode's rows say ON on a machine without a depth buffer too, and a menu
-- that claims 3D battles are on must not also offer the layout they cannot be
-- drawn in.
local function stagedBattles()
  return OverworldBattle.enabled()
end

-- ------- this mod's settings, grouped the way the menus present them
--
-- One entry per setting: the ModSetting itself, the help text the mod
-- manager's page carries, and the fields that decide where it is offered.
--
--   cat   which of SettingsMenu's categories the row lives on. The table is
--         kept in category order as well, so the mod manager's own page --
--         which has no categories to give and lists every row flat -- at
--         least keeps related settings next to each other.
--   when  a predicate. The row is off the menu entirely while it answers
--         false, because a row that decides nothing reads as a broken mod.
--   full  the row SURVIVES the FULL preset. FULL owns the look, so a row
--         goes with it by default; `full` marks the ones that were never
--         about the look. SettingsMenu leans on this and needs no rule of
--         its own: 3D WORLD is exactly the rows WITHOUT it, so that whole
--         category empties out under FULL and takes itself off the menu.
local SETTINGS = {
  -- ------- the top-level menu -- settings that are about the GAME
  --
  -- SettingsMenu.ROOT as a `cat` puts a row on the DRAMATIC SHAPE screen
  -- itself rather than inside one of the four categories, which is right
  -- here: the categories are the diorama, the fights, what the look costs
  -- and the headset, and how often a shiny appears is none of those.
  --
  -- `full` for the battle rows' reason: FULL is a preset for the LOOK, and
  -- an encounter rate is a rule of the game. A player inside FULL must be
  -- able to reach it, and FULL must never set it.
  { Shiny.setting,
    "How often a wild Pokemon turns up shiny. 1:8192 is the games' own "
    .. "rate, and every rung below it is twice as often as the one above.",
    cat = SettingsMenu.ROOT, full = true },

  -- ------- 3D WORLD -- the diorama's own knobs, every one of them FULL's
  { VoxelGrid.setting, "One-pixel wireframe along every voxel edge.",
    cat = "world" },
  { WorldCurve.setting,
    "Bends the world down over the horizon, until a town sits on top of its "
    .. "own little planet.",
    cat = "world" },
  { ViewBox.setting,
    "How far out the camera bothers to draw, which only changes the picture "
    .. "above about 63 degrees where the horizon comes into view.",
    cat = "world" },
  { Water.setting,
    "Reflections on water: SKY is the sun, moon and sky alone, and FULL "
    .. "adds the shoreline and trees behind it.",
    cat = "world" },
  { DayNight.setting,
    "What time it is outdoors -- pinned to an hour, running on a ten-minute "
    .. "cycle, or synced to the clock on your wall.",
    cat = "world" },

  -- ------- BATTLES -- what a fight is drawn over, and how it is played
  --
  -- `full` marks a row FULL does not take away. FULL owns the diorama's own
  -- knobs; what a battle is drawn over, and how it is framed, are not that.
  -- Off the OPTIONS menu while VR is on: the headset REQUIRES staged
  -- battles (OverworldBattle.enabled answers true regardless of this row)
  -- and forbids back sprites (backPinned answers false), so both rows
  -- decide nothing there and a dead switch on the menu reads as broken.
  { OverworldBattle.setting,
    "Fights staged in 3D over your shoulder, on the map or on discs against "
    .. "the sky, as cards or Stadium's animated models.",
    cat = "battles",
    when = function() return not VR.enabled() end, full = true },
  -- Only offered while a fight can actually be staged on the map: with 3D-BTL
  -- off the engine draws the classic screen, which is this row's ON already,
  -- and a row that no longer decides anything is worse than no row.
  { OverworldBattle.backSetting,
    "Keeps your own Pokemon on the battle menu, seen from behind, instead "
    .. "of standing it on the map facing the foe.",
    cat = "battles",
    when = function() return stagedBattles() and not VR.enabled() end,
    full = true },
  -- `full` like the battle rows: this is a GAMEPLAY mode, not a knob on
  -- the diorama, so the FULL preset neither sets it nor takes it away.
  { LetsGo.setting,
    "Pokemon GO-style catching -- flick to throw the ball, with FULL adding "
    .. "half-price balls and party experience (needs 3D-BTL).",
    cat = "battles", full = true },

  -- ------- PERFORMANCE -- what the look COSTS, which is a different question
  --
  -- All three are `full`, and all three for the same reason: FULL is a preset
  -- for the diorama, not a licence to spend whatever the machine it happens
  -- to be running on has got. The player decides what their hardware can
  -- carry, from inside FULL like anywhere else.
  -- `full` for the AA reason: additive shafts are fill rate, and under 4X
  -- supersampling that is a question about the hardware, not the look.
  { ForestAtmos.setting,
    "Haze and volumetric light shafts in the deep woods, with pollen in the "
    .. "beams by day and fireflies at night.",
    cat = "perf", full = true },
  -- `full` on AA's reasoning below, and for the same reason: the sun's pass
  -- is the most expensive thing in the frame after the geometry, so this is
  -- a question about the machine rather than a knob on the diorama, and it
  -- has to stay reachable from inside FULL -- which never sets it either.
  { Shadows.setting,
    "Real cast shadows from the sun, and the first thing to switch off on a "
    .. "phone or an old machine.",
    cat = "perf", full = true },
  -- Marked `full` for the opposite reason the battle rows are: this is not a
  -- knob on the look at all, it is what the look COSTS.
  { AntiAlias.setting,
    "Smooths the stair-stepped edges of the 3D world, and the most "
    .. "expensive row in the mod.",
    cat = "perf", full = true },

  -- ------- VR -- the headset, and the one comfort knob that is only its
  --
  -- `full` for the same reason as AA: not a knob on the look, a question
  -- about the hardware on the desk.
  { VR.setting,
    "PCVR through OpenXR on Windows, either following the VOXEL ladder or "
    .. "as a DIORAMA you carry and turn with the grips.",
    cat = "vr",
    -- on Windows the row stays even when a runtime is missing (the console
    -- says why); off Windows -- mobile above all -- there is no VR to have
    -- and the row does not exist
    when = function() return VR.supported() end, full = true },
  -- Under the VR row and only while it is ON: a comfort setting for a
  -- device that is not plugged in decides nothing, and this one is read
  -- exclusively by the headset's right stick.
  { VR.smoothTurn,
    "Turns smoothly with the right stick instead of snapping 45 degrees, "
    .. "if you have your sea legs for it.",
    cat = "vr",
    -- and only under STANDARD: the stick turns a HEAD, and neither diorama
    -- mode has the player standing in the world to be turned
    when = function() return VR.enabled() and not VR.dioramaMode() end,
    full = true },
}

SettingsMenu.define(SETTINGS)

local schema = {}
for _, entry in ipairs(SETTINGS) do
  -- the VR rows are absent from the mod manager's page too where the
  -- platform cannot do VR at all -- the OPTIONS menu's `when` gates are
  -- situational (a row hidden for now), this one is existential
  local vrOnly = entry[1] == VR.setting or entry[1] == VR.smoothTurn
  if not vrOnly or VR.supported() then
    schema[#schema + 1] = entry[1]:schema(entry[2])
  end
end
V.mod.options:define(schema)

-- ------- the mode's rows, on menus of their own
--
-- This mod used to put FOURTEEN rows on the engine's OPTIONS list, in one
-- block spliced in beside the pipeline rows. OptionRows shows four boxes at a
-- time, so that was four screens of scrolling inside a list that already
-- carried twenty engine rows, and finding SHADOWS meant knowing it was in
-- there past the wireframe and the horizon bend.
--
-- Now there is ONE row, and it leads the list. What it opens -- the
-- categories, the screens, and why the split falls where it does -- is
-- lib/ui/SettingsMenu.lua. VOXEL and T-SHIFT go with it: they are this mod's
-- display modes, the engine only spliced them beside TILT because it had
-- nowhere better, and TILT is not on the menu any more anyway (see below).
--
-- Two things it takes to move a pipeline row: the engine's descriptor is
-- captured on the way past and handed to SettingsMenu VERBATIM -- it persists
-- through its own step function into save.options.pipelines, and rebuilding
-- it here would be a second implementation of something the engine already
-- got right -- and the row is then dropped from the top-level list so it is
-- not in two places at once.
local function captureRow(out, id)
  for _, row in ipairs(out) do
    if type(row) == "table" and row.id == id then return row end
  end
  return nil
end

-- FULL owns the settings that describe the LOOK, so while it is selected those
-- are taken off the menu rather than left to be changed under it -- including
-- T-SHIFT, which is a pipeline row the engine put there. A row that no longer
-- decides anything is worse than no row.
--
-- The battle rows are the exception and they stay; see the rows hook.
local function dropRow(out, id)
  for i = #out, 1, -1 do
    if type(out[i]) == "table" and out[i].id == id then table.remove(out, i) end
  end
  return out
end

-- ------- TILT and GBC FX are gone while this mod is installed
--
-- Both fight the diorama, and both were already half-taken: the mode's own key
-- (3) forces them off on every press, and the registry switches TILT off
-- whenever a world pipeline takes the pass. What was left was two rows the
-- player could set and watch get reverted -- TILT is the flat fake of what
-- this mode does for real, and GBC FX is a full-screen present pass over the
-- top of the whole thing.
--
-- So they come OFF the menu, and are HELD at zero rather than merely dropped.
-- Hiding a live setting is a trap: a save written before the mod was installed
-- can carry TILT 3, and a row that is not there is a row that cannot turn it
-- back off. Pinned wherever the value could have arrived from -- the menu
-- opening, a save being loaded or begun -- so there is no route by which one
-- of them is on and unreachable.
--
-- Everything they did is still reachable: uninstall the mod and both rows are
-- back, at whatever they were last set to.
-- BATTLE BG rides the same reasoning, and comes off for a reason of its own.
-- The row picks what fills the screen AROUND the battle's 160x144 field --
-- WHITE paper, BLACK bars, or the frozen overworld dimmed behind it -- and
-- all three were answers to the same question: what to do with the voids,
-- given the battle is a small picture in the middle of a big window.
--
-- This mod answers that question differently and permanently. A staged fight
-- fills the whole window with the map the fight is standing on, and the
-- flat battle screen it composites over it is drawn on the mode's own
-- surface; there are no voids left for the row to fill. WORLD is the worst
-- of the three under it -- it makes the battle non-opaque so the engine
-- draws the overworld underneath, which is a SECOND copy of the world drawn
-- under the one the arena pass already put there, dimmed and at a different
-- camera. BLACK bars over a diorama read as a letterboxed screenshot.
--
-- So the value is pinned at WHITE, which is the one the mode was composed
-- against, and the row comes off the menu on the same reasoning as TILT and
-- GBC FX: a row that no longer decides anything is worse than no row.
-- Uninstall the mod and it is back, at whatever it was last set to.
local function pinEngineFx(game)
  game = game or require("src.core.Game")
  local opts = game and game.save and game.save.options
  local Tilt = require("src.render.Tilt")
  local GBCFX = require("src.render.GBCFX")
  local changed = false
  if opts then
    changed = (opts.tilt or 0) ~= 0 or (opts.gbcfx or 0) ~= 0
                or (opts.battleBg or "white") ~= "white"
    opts.tilt, opts.gbcfx = 0, 0
    opts.battleBg = "white"
  end
  pcall(Tilt.setLevel, 0)
  pcall(GBCFX.setLevel, 0)
  if changed and game.writeOptions then pcall(game.writeOptions, game) end
end

-- ------- the values that follow other values
--
-- Two settings hold a third in place. 3D-BTL pins BATTLE LAYOUT to OG while a
-- fight can be staged on the map, and FULL pins DAYTIME to SYNC while it owns
-- that row. Both pins used to be a side effect of the rows hook, which every
-- step on the OPTIONS menu reran -- so they happened whether or not the step
-- was the one that mattered, and nothing had to name them.
--
-- Now a step can happen on the mod's own menu, where no hook runs, or on the
-- mod manager's page, where one never did. So the pinning is a function, and
-- all three routes ask for it.
local function pinDependents(game)
  if stagedBattles() then OverworldBattle.forceOG(game) end
  local Pipelines = require("src.render.Pipelines")
  if Voxel.isFull(Pipelines.level("voxel")) then DayNight.forceSync(game) end
end

SettingsMenu.setOnChanged(pinDependents)

-- call next() first and decorate what comes back, so every other mod's
-- rows survive this one
V.mod.hooks:wrap("ui.options.rows", function(next, game, rows)
  local out = next(game, rows)
  if type(out) ~= "table" then return out end
  local Pipelines = require("src.render.Pipelines")
  -- ahead of every branch below, including FULL's early return: these two are
  -- off the menu whatever else this mod is or is not doing
  pinEngineFx(game)
  dropRow(out, "tilt")
  dropRow(out, "gbcfx")
  -- and BATTLE BG with them: this mode fills the window with the map, so
  -- the row's whole question -- what to put in the voids around the battle
  -- -- no longer has voids to be about (see pinEngineFx)
  dropRow(out, "battleBg")
  -- BATTLE LAYOUT is the ENGINE's row, and this is the one place the mod takes
  -- one away. While a fight can be staged on the map, OG is the only layout it
  -- can be composed in (OverworldBattle.forceOG), so the value is pinned there
  -- and the row comes off the list on the same reasoning as the rows FULL owns:
  -- a row that no longer decides anything is worse than no row. Nothing is
  -- lost by switching 3D-BTL off -- the row is back, WIDE and all, on the same
  -- keypress.
  if stagedBattles() then
    OverworldBattle.forceOG(game)
    dropRow(out, "battleLayout")
  end
  if Voxel.isFull(Pipelines.level("voxel")) then
    -- FULL owns the rows that PARAMETERISE the diorama -- the wireframe, the
    -- horizon bend, the blur, the hour -- so DAYTIME is held at SYNC while its
    -- row is unreachable. The rows themselves come off inside SettingsMenu,
    -- which is where they live now: T-SHIFT with the wireframe and the bend,
    -- and each of them by the same `full` rule rather than by name.
    DayNight.forceSync(game)
  end
  -- The two pipeline rows move INTO the mod's own root menu: captured as the
  -- engine built them, then dropped from here so they are not in two places.
  local captured, voxelRow = {}, nil
  for _, id in ipairs({ "pipeline:voxel", "pipeline:tiltshift" }) do
    local row = captureRow(out, id)
    -- a pipeline the registry refused is simply not there, and the menu says
    -- so by not offering it rather than by offering a hole
    if row then captured[#captured + 1] = row end
    if id == "pipeline:voxel" then voxelRow = row end
    dropRow(out, id)
  end
  SettingsMenu.setPipelineRows(captured)
  -- ------- one row, and it leads the list
  --
  -- At the TOP rather than spliced in beside the display modes it used to sit
  -- with. This is a mod that replaces the whole look of the game, and a player
  -- who installed it and went looking for its settings should not have to
  -- scroll to find out where they went -- least of all past the engine rows it
  -- has quietly taken away.
  --
  -- Inserted after next() has run, so it leads every OTHER mod's rows too. The
  -- second line is VOXEL's own value function, which makes the row say what
  -- the mode is currently doing without opening it -- and reuses the engine's
  -- label ladder rather than restating it.
  table.insert(out, 1, {
    id = SettingsMenu.id(SettingsMenu.ROOT),
    label = SettingsMenu.ROOT_LABEL,
    value = voxelRow and voxelRow.value or nil,
    -- `activate` and not `step`: the engine fires activate on A alone, and a
    -- row that OPENS something should not also answer Left and Right
    -- (src/ui/OptionsMenu.update).
    activate = function(g)
      g.stack:push(SettingsMenu.new(g, SettingsMenu.ROOT))
    end,
  })
  return out
end)

-- The mod manager writes and persists on its own, so the only thing left
-- to do is move our cached index and pick the new value up.
V.mod.events:on("mod.options_changed", function(payload)
  if not (payload and payload.mod == V.mod.id) then return end
  for _, entry in ipairs(SETTINGS) do
    if payload.key == entry[1].key then entry[1]:sync(payload.value) end
  end
  -- 3D-BTL switched on from the manager's page pins BATTLE LAYOUT exactly as
  -- the mod's own row does, and DAYTIME changed there while FULL owns it snaps
  -- straight back to SYNC -- that row is off the mod's menus under FULL, but
  -- the manager's page carries every setting unconditionally, and the pin has
  -- to hold against both.
  pinDependents()
end)

-- ------- rows come and go, so the menu has to notice
--
-- OptionsMenu builds its row list ONCE, when it is opened, and then reads
-- that list every frame. So stepping the VOXEL row onto or off FULL changed
-- which rows the hook would return but not which rows were on screen -- the
-- settings FULL owns stayed visible until the menu was closed and reopened,
-- and a player who stepped off FULL could not see the rows come back.
--
-- Rebuilt in place, and only on a step that changes the LIST: crossing FULL,
-- or toggling 3D-BTL, which is the other row that owns one (BATTLE LAYOUT).
-- Every other rung returns the same list, and rebuilding on all of them would
-- rerun every mod's ui.options.rows hook once per keypress. The cursor is
-- clamped rather than reset, so it stays on the row it was just used on
-- instead of jumping to the top when the list below it shortens.
--
-- Held on the INSTANCE rather than compared across one call of update, and
-- that is not a tidying: those three rows live in a SUBMENU now, and the
-- stack only ticks its top state (src/core/StateStack.update). So the step
-- that changes them happens while this menu is suspended and a
-- before/after pair taken around inner() would both be read after the fact
-- and always agree. A signature that outlives the suspension does not.
do
  local OptionsMenu = require("src.ui.OptionsMenu")
  if not OptionsMenu.dramaticShapeFullHook then
    local OptionRows = require("src.ui.OptionRows")
    local Pipelines = require("src.render.Pipelines")
    local inner = OptionsMenu.update
    local innerPalettes = OptionsMenu.sgbPalettes

    local function idAt(menu, index)
      local row = menu.rows and menu.rows[index or 1]
      return type(row) == "table" and row.id or nil
    end

    -- What the row LIST depends on: whether FULL is selected (it owns the
    -- rows that describe the look), and the two switches that give and take
    -- an engine row -- 3D-BTL, which owns BATTLE LAYOUT, and VR, which hides
    -- both battle rows while it is on. Only the FULL-ness of the voxel level
    -- matters, so stepping 35 to 50 is not a change.
    local function signature()
      return string.format("%s|%s|%s",
        tostring(Voxel.isFull(Pipelines.level("voxel"))),
        tostring(OverworldBattle.enabled()), tostring(VR.enabled()))
    end

    -- Stamped where the ROWS are built, which is the thing the signature is a
    -- signature OF. Read lazily on the first update instead and a menu opened
    -- before the change and updated after it would compare the new state
    -- against itself and never rebuild.
    local innerNew = OptionsMenu.new
    function OptionsMenu.new(game, opts)
      local menu = innerNew(game, opts)
      menu.dramaticShapeSig = signature()
      return menu
    end

    function OptionsMenu:update(dt)
      local wasOn = idAt(self, self.index)
      local before = self.dramaticShapeSig or signature()
      inner(self, dt)
      local after = signature()
      self.dramaticShapeSig = after
      if before ~= after then
        local rebuilt = OptionsMenu.new(self.game)
        self.rows = rebuilt.rows
        -- Follow the row the cursor was ON rather than the slot it was in:
        -- 3D-BTL takes BATTLE LAYOUT off the list ABOVE itself, which would
        -- otherwise slide the cursor onto the row under the one just used.
        for i = 1, #self.rows do
          if wasOn and idAt(self, i) == wasOn then self.index = i; break end
        end
        local cancel = #self.rows + 1
        if (self.index or 1) > cancel then self.index = cancel end
      end
    end

    -- ------- and the mod's own row is red
    --
    -- Why this is a palette zone and not love.graphics.setColor -- twice over
    -- -- is written out in lib/ui/SettingsMenu.lua, next to the code that builds
    -- the palette. The short of it: setColor picks a SHADE on this screen and
    -- the zone picks the COLOR.
    --
    -- Addressed by SLOT, because the row scrolls: it leads the list, so it is
    -- normally the top box, but a player who scrolls past it must not leave a
    -- red band behind on whatever takes its place. Searched by id rather than
    -- assumed to be row 1 for the same reason -- another mod's hook running
    -- after ours could put something above it.
    function OptionsMenu:sgbPalettes(game)
      local zones = innerPalettes and innerPalettes(self, game) or nil
      local scroll = self.scroll or 0
      for slot = 1, OptionRows.VISIBLE do
        local row = self.rows and self.rows[scroll + slot]
        if type(row) == "table"
            and row.id == SettingsMenu.id(SettingsMenu.ROOT) then
          local zone = SettingsMenu.rowZone(game and game.data, slot)
          if zone then
            zones = zones or {}
            zones[#zones + 1] = zone
          end
          break
        end
      end
      return zones
    end

    OptionsMenu.dramaticShapeFullHook = true
  end
end

return {
  pinEngineFx = pinEngineFx,
}