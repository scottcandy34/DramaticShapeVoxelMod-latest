local V = ...

local OverworldBattle = V.require("battle/OverworldBattle")
local BattleExit = V.require("battle/BattleExit")
local ShinyBattle = V.require("shiny/ShinyBattle")
local ShinyUI = V.require("shiny/ShinyUI")
local ShinyPics = V.require("shiny/ShinyPics")
local ShinyFlash = V.require("shiny/ShinyFlash")
local DayNight = V.require("effects/DayNight")
local DayTint = V.require("effects/DayTint")
local FirstPerson = V.require("camera/FirstPerson")
local FreeMove = V.require("camera/FreeMove")
local CamControl = V.require("camera/CamControl")
local VR = V.require("vr/VR")
local Horde = V.require("modes/horde/Horde")
local LetsGo = V.require("modes/catch/LetsGo")

-- Storage and log are established in main.lua before this module is required.
local ModStorage = V.storage

local Hotkeys         = V.require("ui/Hotkeys")
local cycleVoxel      = Hotkeys.cycleVoxel

local Settings        = V.require("ui/settings/Settings")
local pinEngineFx     = Settings.pinEngineFx

-- ------- battles on the map
--
-- The wraps this needs -- OverworldState:pushBattle, BattleState:draw and
-- BattleState:drawHUDs -- all live in lib/battle/OverworldBattle.lua, which is
-- where the reasoning for each one is written down. Installed once, here,
-- so this file keeps naming every engine seam the mod touches.
OverworldBattle.install()

-- ------- shiny Pokemon
--
-- ON, always, with no row to switch it off: shininess is a property of the
-- Pokemon rather than a display mode, and a Pokemon that is shiny in one
-- player's save and not another's is not a Pokemon, it is a setting.
--
-- It rests on a fact the engine already ships. Gen 1 has no shininess of its
-- own, but it has the four DVs Gen 2 reads to decide it, and
-- src/pokemon/Stats.lua:90 carries that reading -- the engine's own comment
-- calls it "the RBY virtual shiny" and says it is there for indicator mods.
-- So nothing new is stored on a Pokemon and nothing has to migrate: every
-- save ever made already contains the answer, and this only starts drawing
-- it. See lib/shiny/Shiny.lua for why deriving beats storing.
--
-- Three seams, each in its own file with its own reasoning:
--   ShinyBattle  wraps Pokemon.new, which is where every wild, gift,
--                starter and traded mon is built, so the roll lands before
--                the sprite is baked
--   ShinyUI      the status page's mark, and the summary pic's palette
--   ShinyPics    the battle pic's palette -- a real recolour, baked into the
--                image cache under a shiny key, on every rung that draws a
--                pic (OFF, both 2D-3D rungs, and the cards a STADIUM battle
--                still uses for a species with no model)
--   ShinyFx      the arrival sparkle for the STADIUM rungs (3D, armed from
--                Stadium.update)
--   ShinyFlash   the same announcement for every OTHER rung, drawn in the
--                Game Boy's own pixel grid over the pic
--
-- The Stadium models need no seam here at all: their recolour happens at
-- extraction (lib/stadium/StadiumBuild.lua), and the battle simply asks for the
-- shiny pack.
ShinyBattle.install()
ShinyUI.install()
ShinyPics.install()
ShinyFlash.install()

-- ShinyPics needs to know WHICH Pokemon a pic is being built for, and the
-- two palette functions it wraps are told only the species. The individual
-- passes through here one call earlier: `pokemon.sprite` carries ctx.mon.
--
-- next() first and the return value untouched -- this reads the context and
-- changes nothing about which art is chosen.
V.mod.hooks:wrap("pokemon.sprite", function(next, path, ctx)
  local out = next(path, ctx)
  pcall(ShinyPics.note, ctx)
  return out
end)

-- A save opened for the first time under this mod has shiny Pokemon in it
-- already -- they always did -- so refresh the cached flag across the party
-- rather than leaving it absent until each mon next changes.
V.mod.events:on("save.loaded", function() ShinyBattle.markParty() end)
V.mod.events:on("save.created", function() ShinyBattle.markParty() end)

-- ------- the free-roam rungs' inputs and their walk
--
-- 1ST and 3RD need two things no other rung does, and each is a named seam.
-- Both rungs are one rig -- the boom behind the shoulder is a number inside
-- it (lib/camera/ThirdPerson.lua) -- so both are installed by the same two calls:
--
-- FirstPerson.install claims the LOOK inputs the engine ignores: the right
-- stick's axes (Game:gamepadaxis passes them to Input, which returns early
-- on anything but the left pair), relative mouse motion (love.mousemoved --
-- there is no Game handler to wrap; the engine's own callback only feeds
-- the mouse-as-touch debug path, which stays untouched), the mouse buttons
-- while the cursor is captured (A and B -- there is no cursor to click UI
-- with), and any touch that lands off the overlay's controls (a drag on
-- open screen is the look; the d-pad and buttons still go to
-- TouchControls, whose own d-pad finger is also read back analog as the
-- move vector). Every wrap forwards whatever it does not claim, and claims
-- only while one of the two rungs is actually driving.
--
-- FreeMove.install wraps OverworldState:handleInput -- the one choke point
-- where the grid walk reads the pad, and the same seam the engine's own
-- Cycling Road pull lives behind. While either drives, the walk is continuous
-- and camera-relative; the player's logical cell stays synced and every
-- per-cell consequence still runs through the engine's own machinery
-- (onStepComplete, checkEdgeExit, checkLedgeHop, checkBoulderPush). The
-- file argues the whole arrangement.
do
  local ok, err = pcall(FirstPerson.install)
  if ok then V.log:event("input", "FirstPerson.install", { ok = "true" })
  else V.log:error("FirstPerson.install failed: %s", tostring(err)) end
end
do
  local ok, err = pcall(FreeMove.install)
  if ok then V.log:event("input", "FreeMove.install", { ok = "true" })
  else V.log:error("FreeMove.install failed: %s", tostring(err)) end
end

-- ------- the zooms, and the battle camera the player can steer
--
-- CamControl claims the wheel, Q/E, the mouse and the touch screen for
-- whichever camera is actually in front of the player -- the staged
-- battle's, the third-person boom, or the engine's own survey zoom -- and
-- forwards everything else. Installed AFTER the two above deliberately: a
-- wrap installed later is the OUTER one, so a fight gets first refusal on
-- the mouse and the fingers, which is right, because while one is staged
-- the free-roam look is not driving.
do
  local ok, err = pcall(CamControl.install)
  if ok then V.log:event("input", "CamControl.install", { ok = "true" })
  else V.log:error("CamControl.install failed: %s", tostring(err)) end
end

-- Stadium ROM drop support: love.filedropped for desktops (sandbox may
-- reject the assignment; fails soft). Mobile uses love.system.pickFile
-- from the OPTIONS row instead.
do
  local ok, err = pcall(function()
    V.require("stadium/rom/StadiumRomPick").install()
  end)
  if ok then V.log:event("input", "StadiumRomPick.install", { ok = "true" })
  else V.log:error("StadiumRomPick.install failed: %s", tostring(err)) end
end

-- ------- SELECT walks the angle ladder
--
-- The same step the "3" key makes, on the pad's own button: a phone (and
-- a controller) has no number row, and SELECT has no overworld job in
-- Gen 1 -- its work is all in-menu, which this wrap never sees. The seam
-- is OverworldState:handleInput, the same choke point the free walk
-- replaced: every gate above it -- menus, dialogs, scripted moves,
-- transitions -- already decided the overworld owns the buttons, so a
-- SELECT here is free-roam by construction, exactly like the key. When
-- the step is refused (mid-warp, no 3D pass) the press falls through to
-- the engine's own handling, which is a no-op, as ever.
--
-- Installed AFTER FreeMove.install, deliberately: its wrap must sit
-- OUTSIDE the free walk's, or first person -- where FreeMove.tick takes
-- the frame and never calls further in -- would eat the button, and the
-- one rung SELECT could not step off of would be 1ST itself.
do
  local OverworldState = require("src.world.OverworldController")
  if not OverworldState.dramaticShapeSelectHook then
    local inner = OverworldState.handleInput
    function OverworldState:handleInput(...)
      local Game = require("src.core.Game")
      local input = Game.input
      if input and input.wasPressed and input:wasPressed("select") then
        if cycleVoxel(Game) then return end
      end
      return inner(self, ...)
    end
    OverworldState.dramaticShapeSelectHook = true
  end
end

-- ------- the konami code, and everything it turns on
--
-- Installed last of the input seams so its handleInput reasoning sits
-- outside FreeMove's and SELECT's. The detector itself does not live on
-- handleInput at all -- it reads the fixed step's own press queue, which
-- is where keyboard, pad, touch and the VR controllers have all already
-- become the same eight buttons. See lib/modes/horde/Horde.lua.
Horde.install()

-- ------- LET'S GO capture mode
--
-- After every other input seam on purpose: while a throw is being aimed
-- the capture's mouse and touch wraps are the OUTERMOST, so the flick is
-- read before anything else can claim the pointer -- and outside the aim
-- they forward every byte untouched. The battle-side wraps (throwBall,
-- safariAction) and the experience hooks install here too.
LetsGo.install()

-- ------- edge-anchored menus stay in the GB frame while a headset is live
--
-- The engine's zoom-aware anchoring (Renderer:setUIAnchor) docks the START
-- menu to the WINDOW's top-right edge. Both VR screens -- the floating
-- panel and the Pokedex -- crop the window to the GB frame, so a menu at
-- the window's edge is cropped away with the border it docked to. The
-- engine's own answer to "a state composes its screen, keep every element
-- inside it" is uiAnchorHold, computed per frame from this predicate; a
-- live headset is exactly that situation for the WHOLE window, so the
-- predicate answers yes for as long as one is. Held menus blit where they
-- were drawn in the 160x144 canvas -- the START menu's 9,0 x 11 slot is
-- already flush with the frame's right edge, which is the right edge of
-- what the headset sees. Off-headset frames fall through untouched.
do
  local Game = require("src.core.Game")
  if not Game.dramaticShapeAnchorHold then
    local inner = Game.uiAnchorsHeldInStack
    function Game.uiAnchorsHeldInStack(stack)
      if VR.active() then return true end
      return inner(stack)
    end
    Game.dramaticShapeAnchorHold = true
  end
end

-- The overworld's own pushBattle is the choke point for a wild encounter or
-- a trainer, and it is wrapped. A battle that arrives some other way -- a
-- link battle, a script pushing a BattleState directly -- reaches this
-- instead, which stages the arena from wherever the player is standing.
-- Nothing visible is lost by being late: the cull only has to beat the
-- battle screen, and the wipe those battles skip is where it would have
-- shown.
V.mod.events:on("battle.started", function(payload)
  OverworldBattle.ensure(payload and payload.battle)
  local b = payload and payload.battle
  V.log:event("battle", "started", {
    kind = b and b.kind or "unknown",
  })
end)

-- Both mons face the camera, so the player's side wants its FRONT pic where
-- the battle screen would have used the back one. The engine's own
-- pokemon.sprite hook is the seam for exactly this: it is asked for every
-- battle pic with the side it is resolving, so swapping one side's answer
-- needs no battle code at all -- and every path that builds a battler goes
-- through it, including a Transform mid-fight.
--
-- next() first, so a sprite-replacing mod loaded before this one still gets
-- the last word on WHICH art is used; this only changes which SIDE is asked
-- for.
V.mod.hooks:wrap("pokemon.sprite", function(next, path, ctx)
  local out = next(path, ctx)
  if not (ctx and ctx.kind == "battle" and ctx.side == "back") then
    return out
  end
  if not OverworldBattle.wantsFront() then return out end
  local def = ctx.data and ctx.data.pokemon and ctx.data.pokemon[ctx.species]
  return (def and def.spriteFront) or out
end)

-- Every ending path emits this, including a battle skipped before it drew,
-- so this is where the map's cast comes back.
V.mod.events:on("battle.ended", function()
  OverworldBattle.finish()
  V.log:event("battle", "ended", {})
end)

-- ------- and the way back out
--
-- The engine wipes INTO a battle with one of the original's eight transitions
-- and cuts straight OUT of it. That cut is between two very different cameras
-- in this mode, so while voxel mode is on the battle fades out, closes behind
-- the black, and the map fades up. The two seams it needs -- BattleState:finish
-- and Renderer:endFrame -- and the reasoning for each live in lib/battle/BattleExit.lua.
--
-- Declared as a transitions record rather than a constant in that file, so the
-- fade is retunable in data exactly like the eight wipes it answers, and a total
-- conversion can make it as long or as short as its own pacing wants.
V.mod.content.transitions:register(BattleExit.ID, {
  frames = BattleExit.FRAMES,
})

BattleExit.install()

-- ------- and the hour on the flat world
--
-- The clock reaches the diorama through the voxel shader's own tint uniform,
-- which the 2D tile path never runs -- so with the mode off, the same evening
-- that fell on the diorama left the flat world at permanent noon. One clock,
-- two worlds, one of them ignoring it. DayTint paints the same multiply over
-- the composited flat world, between the world blit and the UI blit; the
-- reasoning for that exact instant is in the file.
DayTint.install()

-- ------- what time it is
--
-- The cycle's clock rides the SAVE SLOT (save.modData, via V.mod.save): what
-- time it is in Kanto is a fact about that journey, like where the player is
-- standing. Written on the engine's save.writing event -- the moment before
-- the bytes hit disk -- and read back whenever a save is opened or begun. A
-- save with no clock in it starts at day; that is DayNight.restore's
-- fallback, and also the DAYTIME row's own default.
V.mod.events:on("save.writing", function()
  DayNight.store()
end)

V.mod.events:on("save.loaded", function()
  local okG, Game = pcall(require, "src.core.Game")
  if okG and Game then ModStorage.setGame(Game) end
  DayNight.restore()
  -- a save written before this mod was installed can carry TILT or GBC FX
  -- switched on, and their rows are not there to switch them back off (see
  -- pinEngineFx). Answered here rather than only when the menu opens, so a
  -- player who never opens it is not left playing under one.
  pinEngineFx()
  V.log:event("save", "loaded", {})
  pcall(function() V.log:flush() end)
end)

V.mod.events:on("save.created", function()
  local okG, Game = pcall(require, "src.core.Game")
  if okG and Game then ModStorage.setGame(Game) end
  DayNight.restore()
  pinEngineFx()
  V.log:event("save", "created", {})
  pcall(function() V.log:flush() end)
end)

-- The engine's own time-of-day seam. OverworldState:timeOfDay() is an
-- eternal "DAY" until a mod answers here; answering it hands the period to
-- the map.palette hook (ctx.tod) and music.select, so a palette or music
-- pack keyed to night works with this mod's clock for free. next() first: a
-- mod loaded before this one that already moved the time keeps its answer.
V.mod.hooks:wrap("world.tod", function(next, tod, ctx)
  local out = next(tod, ctx)
  if out ~= tod then return out end
  return DayNight.tod()
end)
