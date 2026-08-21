-- Dramatic Shape Voxel Mod: a full 3D diorama overworld, shipped as a
-- rendering pipeline mod.
--
-- The engine's render_pipelines registry (src/mods/Schemas.lua) lets a mod
-- own part of the frame.  This mod registers two:
--
--   voxel      a drawWorld pipeline.  Instead of the flat tile blit, the
--              overworld's terrain is extruded into real geometry, walked
--              by a depth-buffered 3D camera, with characters as leaning
--              sprite slabs and a shadow map throwing real cast shadows
--              across whatever they land on.  Occlusion is the depth
--              buffer, not a y-sort: walk behind a building and the
--              building is simply in front.
--
--   tiltshift  a worldPresent pipeline -- the stage that post-processes
--              the finished world BEFORE the UI composites over it.  A
--              tilt-shift blur that sells the miniature-model look, on the
--              diorama only, leaving text boxes and menus crisp.
--
-- Everything a display mode needs beyond the two draw functions -- the
-- OFF/15/35/50 ladder, the options rows, the hotkeys, persistence in
-- save.options.pipelines, the free-roam gate, the mutual exclusion with
-- the engine's TILT mode -- is engine plumbing driven by the records
-- below.  This file declares; lib/ draws.
--
-- Voxel mode is presentational: it changes what the world LOOKS like and
-- nothing about what it IS.  TWO rungs are the deliberate exception. 1ST
-- (the camera in the player's own eyes) and 3RD (the same rig, boomed back
-- behind their shoulder) replace the grid WALK with a free,
-- camera-relative one while either is selected (lib/FreeMove.lua), because
-- a camera you can steer with a mouse demands feet that go where it looks.
-- Even there the game is untouched: the walk asks the engine's own
-- collision the same questions a grid step asks, keeps the player's
-- logical cell synced, and fires the engine's own landing pipeline per
-- cell crossed -- warps, encounters, ledges, gates and scripts all run
-- exactly as themselves. Step off the rung and the grid walk is back.

local mod = ...

-- ------- the mod namespace
--
-- lib/ modules require each other through V rather than package.path: a
-- mod directory is not on it, and may live inside a mounted .love archive
-- that plain require cannot reach.  Each module is loaded once, with V
-- passed in as its vararg (`local V = ...`).

local V = { mod = mod, path = mod.path }

-- Filled by VOXEL_VR via mod.exports.registerVR
local _vrCompanion = nil

local function chunkFor(rel)
  local source = mod:read(rel)
  if not source then
    error(("DRAMATIC_SHAPE: %s is missing -- reinstall the mod"):format(rel), 0)
  end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then
    error(("DRAMATIC_SHAPE: %s did not compile: %s"):format(rel, tostring(err)), 0)
  end
  return chunk
end

local modules = {}
function V.require(name)
  local hit = modules[name]
  if hit ~= nil then return hit end
  local value = chunkFor("lib/" .. name .. ".lua")(V)
  modules[name] = value
  return value
end

local dataFiles = {}
function V.data(name)
  local hit = dataFiles[name]
  if hit ~= nil then return hit end
  local value = chunkFor("data/" .. name .. ".lua")(V)
  dataFiles[name] = value
  return value
end

-- ------- pipelines

local Voxel = V.require("VoxelState")
local Voxel3D = V.require("Voxel3D")
local VoxelScene = V.require("VoxelScene")
local TiltShift = V.require("TiltShift")
local ChunkMesher = V.require("ChunkMesher")
local VoxelCacheScreen = V.require("VoxelCacheScreen")
local VoxelGrid = V.require("VoxelGrid")
local WorldCurve = V.require("WorldCurve")
local ViewBox = V.require("ViewBox")
local OverworldBattle = V.require("OverworldBattle")
local StadiumBattleFxProvider = V.require("StadiumBattleFxProvider")
local BattleExit = V.require("BattleExit")
local Shiny = V.require("Shiny")
local ShinyBattle = V.require("ShinyBattle")
local ShinyUI = V.require("ShinyUI")
local ShinyPics = V.require("ShinyPics")
local ShinyFlash = V.require("ShinyFlash")
local DayNight = V.require("DayNight")
local DayTint = V.require("DayTint")
local Water = V.require("Water")
local ForestAtmos = V.require("ForestAtmos")
local Shadows = V.require("Shadows")
local AntiAlias = V.require("AntiAlias")
local FirstPerson = V.require("FirstPerson")
local FreeMove = V.require("FreeMove")
local CamControl = V.require("CamControl")
-- the mod's settings menus: the categories, the screens they open, and the
-- red ink that marks this mod's one row on the engine's OPTIONS list
local SettingsMenu = V.require("SettingsMenu")
-- HORDE MODE: the konami code's minigame. Horde owns the state machine and
-- every hook; the other four are the gun, the crowd, the readout and the
-- chip-synthesized sounds it fires. See lib/Horde.lua for the whole design.
local Horde = V.require("Horde")
local HordeGun = V.require("HordeGun")
local HordeHud = V.require("HordeHud")
local HordeSfx = V.require("HordeSfx")
-- LET'S GO: the flick-to-throw capture mode. LetsGo owns the row, the
-- wraps and the experience math; CatchThrow the session (input, arc,
-- ring, choreography); Pokeball the animated prop they throw.
local LetsGo = V.require("LetsGo")
local Pokeball = V.require("Pokeball")

-- ------- diagnostics (mod.storage-backed log)
--
-- Same idea as StadiumBattleFX: a ring of event lines persisted under
-- diagnostics/log in this mod's playthrough storage, exportable via
-- mod.exports.diagnosticLog() and a SAVE DIAGNOSTIC SNAPSHOT options row.
local ModStorage = V.require("ModStorage")
V.storage = ModStorage
local ModLog = V.require("ModLog")
V.log = ModLog.new(mod.log)
local ModLogExport = V.require("ModLogExport")

-- Compatibility bridge used by gen2-gold-beta-style call sites (V.dlog).
-- Routes into the persistent mod.storage log instead of love.filesystem.
function V.dlog(msg)
  msg = tostring(msg)
  if V.log then V.log:info("%s", msg) end
  print("[DRAMATIC_SHAPE] " .. msg)
end
V.dlog(("main.lua loading path=%s id=%s"):format(
  tostring(mod.path), tostring(mod.id)))

mod.events:on("mods.loaded", function()
  StadiumBattleFxProvider.register()
end)

-- Forward declaration: the voxel pipeline's update hook (registered below)
-- calls this, and it is defined further down with the settings it drives.
-- Declared rather than left global -- a mod writing to _G would leak into
-- every other mod's namespace.
local applyFull

-- The last VOID FILL the terrain was meshed under; see the update hook.
-- The scene canvas's size, in FRAMEBUFFER PIXELS.
--
-- `ctx.width/height` are the window measured in LOVE UNITS
-- (love.graphics.getDimensions), but the engine composites a pipeline's
-- returned canvas with `draw(canvas, 0, 0, 0, 1/dpiX, 1/dpiY)` -- a scale
-- that only covers the window when the canvas is at PIXEL resolution.
-- Sizing it in units costs the DPI scale TWICE: the canvas is that much
-- smaller, then it is drawn that much smaller again, so the diorama lands
-- in the top-left corner at 1/dpi of the screen.  Desktop never sees it --
-- units and pixels are the same thing there -- but on Android the DPI scale
-- is the display density (2.625 on a 420dpi panel), and the world came out
-- a third of the size in each direction.
--
-- So ask for the pixel dimensions rather than trusting the ctx.  That is
-- the number a fixed engine would hand over, so this keeps working either
-- way instead of double-correcting.  It also squares the FX pass: ctx.scale
-- is ALREADY in pixels per world pixel (Zoom.scale over Renderer:fitScale,
-- which measures the drawable), so the closures ctx.drawFx runs were being
-- scaled for a canvas 2.6x bigger than the one they drew into.
local function sceneSize(ctx)
  if love.graphics and love.graphics.getPixelDimensions then
    local pw, ph = love.graphics.getPixelDimensions()
    if pw and ph and pw > 0 and ph > 0 then return pw, ph end
  end
  return ctx.width, ctx.height
end

local voidFill = { last = nil }

-- At high refresh rates, a grid step can contain brief frames where the
-- engine's moving flag is down. Keep a small grace window so Android never
-- mistakes those gaps for permission to start a cold neighbour build.
local IS_ANDROID = false
pcall(function()
  IS_ANDROID = love and love.system and love.system.getOS
               and love.system.getOS() == "Android"
end)
local moveProbe = { map = nil, x = nil, y = nil, last = -math.huge }
local moveClock = (love and love.timer and love.timer.getTime) or os.clock
local MOVE_GRACE = 0.18

local function overworldMoving(ow)
  if not IS_ANDROID then return false end
  local player = ow and ow.player
  if not (player and ow.map) then
    moveProbe.map, moveProbe.x, moveProbe.y = nil, nil, nil
    moveProbe.last = -math.huge
    return false
  end
  local sameMap = moveProbe.map == ow.map.id
  local moved = sameMap and moveProbe.x ~= nil
                and (player.px ~= moveProbe.x or player.py ~= moveProbe.y)
  local active = player.moving == true or moved
  if active then moveProbe.last = moveClock() end
  moveProbe.map, moveProbe.x, moveProbe.y = ow.map.id, player.px, player.py
  return active or (sameMap and moveClock() - moveProbe.last < MOVE_GRACE)
end

function voidFill.check()
  local TileRenderer = require("src.render.TileRenderer")
  local now = TileRenderer.voidFill
  if voidFill.last ~= nil and now ~= voidFill.last then
    ChunkMesher.invalidate()   -- no map id: every ring on every map is stale
  end
  voidFill.last = now
end

mod.content.render_pipelines:register("voxel", {
  label = "VOXEL",
  levels = Voxel.ANGLE_LABELS,
  -- 3 is the engine's TILT key, which this mode supersedes -- see the
  -- hotkey block near the bottom of this file for how it is claimed
  hotkey = "3",
  -- above tiltshift, so the two sort together in the options list with the
  -- mode first and its post-process under it
  priority = 20,

  -- Headless runs and drivers without a depth canvas or shader support
  -- answer false here, and the engine keeps the vanilla 2D path -- which
  -- is why no caller ever has to guard for a missing 3D pass.
  available = function()
    local ok, avail = pcall(Voxel3D.available)
    if not ok then
      if not V._voxelAvailLogged then
        V._voxelAvailLogged = true
        V.log:error("Voxel3D.available raised: %s", tostring(avail))
      end
      return false
    end
    if not V._voxelAvailLogged then
      V._voxelAvailLogged = true
      V.log:event("voxel", "available", { ok = avail and "true" or "false" })
    end
    return avail and true or false
  end,

  -- the engine hands over the live level; we ease the camera toward it.
  -- pump() advances queued mesh builds inside a few-millisecond budget,
  -- so entering voxel mode (and streaming neighbours while walking)
  -- costs frames nothing visible -- the old synchronous build froze the
  -- first frame for seconds. prefetch() runs here as well as in the
  -- draw, because update ticks even while a warp's Transition covers
  -- the screen: the destination's meshes start building the moment the
  -- map swaps behind the fade, and the fade-covered frames get a wider
  -- pump slice -- so stepping out of a door lands on terrain that is
  -- already there instead of a flat flash.
  update = function(dt, level)
    -- Bind playthrough storage once a Game exists so diagnostics can persist.
    if not ModStorage.game() then
      local okG, Game = pcall(require, "src.core.Game")
      if okG and Game then
        ModStorage.setGame(Game)
        V.log:event("runtime", "game-bound", {})
      end
    end
    -- gen2-gold-beta: one-shot first-tick snapshot (level + capability).
    if not V._updLogged then
      V._updLogged = true
      local okA, avail = pcall(function() return Voxel3D.available() end)
      V.dlog(("voxel update first tick level=%s available=%s"):format(
        tostring(level), okA and tostring(avail) or tostring(avail)))
    end
    -- FULL is a preset, so it is applied ON THE PRESS rather than held every
    -- frame: it SETS the other rows and then leaves them alone. Holding them
    -- would make the zoom keys and the wheel dead while the mode was on, and
    -- would fight anyone who changed one deliberately.
    applyFull(level)
    Voxel.update(dt, level)
    -- the first-person head, on the same tick: its blend in and out of the
    -- orbit, the mouse capture lifecycle, and the frame's stick-rate look.
    -- Unconditional like Voxel.update, because the blend has to keep easing
    -- OUT after the rung is left
    FirstPerson.update(dt)
    -- the day/night clock, on the same always-running tick: Pipelines.update
    -- runs whatever the level, so time passes with the mode off, through
    -- battles and menus, and a CYCLE evening falls mid-fight exactly as it
    -- would mid-walk
    DayNight.update(dt)
    -- the atmosphere's own clock (shaft shimmer, drifting motes), on the
    -- same tick so the beams keep breathing through a dialog box
    ForestAtmos.update(dt)
    -- LET'S GO rides the same always-running tick, and BEFORE the battle's
    -- own update on purpose: the capture session poses the Poke Ball here,
    -- and OverworldBattle.update renders the arena a moment later -- so
    -- the ball each frame draws is the ball that frame computed. Guarded,
    -- and loudly: a fault in the capture game must cost the capture game,
    -- not the whole voxel pipeline.
    do
      local okLG, errLG = pcall(LetsGo.update, dt)
      if not okLG and not V.letsGoWarned then
        V.letsGoWarned = true
        local msg = ("LET'S GO update failed: %s"):format(tostring(errLG))
        V.log:error("%s", msg)
        V.dlog(msg)
      end
    end
    -- The overworld battle rides this hook rather than owning a pipeline of
    -- its own, because it owns no pass of the FRAME: it draws under a battle
    -- screen the engine composites, which is not a stage the registry has.
    -- What it needs is a tick that keeps running once the overworld stops
    -- being the top state, and this is one -- Game:update calls
    -- Pipelines.update unconditionally, so it survives the transition wipe
    -- and the whole battle. Ahead of the active() gate below, because a 3D
    -- battle does not require the free-roam mode to be switched on.
    OverworldBattle.update(dt)
    -- The one-time build of the Pokemon Stadium battle models out of the
    -- player's own ROM, if there is one to build from and it has not been
    -- done (see StadiumInstall). Rides this hook for the same reason the
    -- battle does -- it is the tick that runs whatever is on the stack -- and
    -- asks exactly once, on the first frame the player is actually in the
    -- world, so it is never fighting the engine's own launcher for the
    -- screen.
    pcall(function() V.require("StadiumScreen").maybePush() end)
    -- and a ROM the system file picker dropped in the save directory while
    -- we were not the top activity (Android; see StadiumRomPick.poll)
    pcall(function()
      V.require("StadiumRomPick").poll(require("src.core.Game"))
    end)
    -- The horde, on the same always-running tick and for the same reason:
    -- it owns no pass of the frame, it is a MODE over the overworld, and
    -- it has to keep thinking while a warp's wipe covers the screen (the
    -- crowd follows the player through the door) and under the GAME OVER
    -- card, which is a pushed state that stops everything below it.
    Horde.update(dt)
    -- VOID FILL picks the block the border ring is made of, and in this
    -- mode that ring is BAKED INTO THE MESH rather than drawn each frame.
    -- So the option has to reach the cache or nothing happens on screen
    -- until the meshes are dropped for some other reason -- which reads
    -- exactly like the option doing nothing at all. Polled rather than
    -- hooked because the engine changes it from three places (the options
    -- row, applyOptions on load, TileRenderer.setVoidFill) and none of
    -- them announces it. Ahead of the active() gate, so switching it
    -- while voxel mode is OFF still invalidates what is cached.
    voidFill.check()
    -- Android prepares large BODY meshes once on an opaque, resumable screen.
    -- Completion lives in persistent storage, so subsequent launches and
    -- ordinary traversal only stream bounded cache chunks. Keep this after
    -- the always-running modes above so the new screen does not pause them.
    pcall(VoxelCacheScreen.maybePush)
    if VoxelCacheScreen.active() then return end
    if not Voxel.active() then return end
    local Game = require("src.core.Game")
    local ow = Game and Game.overworld
    local covered = ((Game and Game.stack and Game.stack:top() ~= ow)
                     or (ow and ow.transitioning)) and true or false
    if ow and ow.map and ow.camera then
      pcall(VoxelScene.prefetch, ow, covered)
    end
    ChunkMesher.pump(covered, not covered and overworldMoving(ow))
  end,

  drawWorld = function(ctx)
    -- Soft VR companion hook: when VOXEL_VR is active, the window
    -- shows the left-eye mirror instead of a third full render.
    do
      local vr = _vrCompanion
      if not vr then
        local ok, info = pcall(function() return mod.find("VOXEL_VR") end)
        if ok and info and info.exports then vr = info.exports end
      end
      if vr then
        pcall(function()
          if vr.setPaletteFor then vr.setPaletteFor(ctx.paletteFor) end
        end)
        local active = false
        pcall(function() active = vr.active and vr.active() end)
        if active and vr.mirror then
          local sw, sh = sceneSize(ctx)
          local okM, m = pcall(vr.mirror, sw, sh)
          if okM and m then return m end
        end
      end
    end
    -- Terrain and characters are geometry; the field FX stay ordinary 2D
    -- draws composited on top, anchored through the same camera the 3D
    -- pass used (ctx.drawFx below).  The scene renders at the window's
    -- PIXEL resolution (see sceneSize) so the 3D pass is crisp rather than
    -- a magnified low-res image, while the FX closures keep drawing in
    -- world-pixel units.
    local sw, sh = sceneSize(ctx)
    -- With AA on, the whole pass runs into a canvas BIGGER than the window
    -- and is folded back down at the end (see AntiAlias).  Nothing between
    -- these two lines knows: every pass in the frame measures itself in the
    -- canvas it was handed, so the sky's dither, the water's march and the
    -- camera itself all come out the same picture at a higher sample rate.
    local rw, rh = AntiAlias.expand(sw, sh)
    local st = ctx.state

    -- gen2-gold-beta meshKick diagnostics: once per session, name the map
    -- and force a short pump so a stuck empty cache surfaces as a real
    -- build failure rather than an endless silent 2D fallback.
    if st and st.map and not V._meshKick and not VoxelCacheScreen.active() then
      V._meshKick = true
      local map = st.map
      local ts = map.tileset
      local sample = nil
      pcall(function() sample = map:tileAt(0, 0) end)
      V.dlog(("meshKick map=%s tileset=%s hasBlocks=%s tileAt00=%s"):format(
        tostring(map.id),
        tostring(ts and ts.id),
        tostring(ts and ts.blocks ~= nil),
        tostring(sample)))
      local okB, errB = pcall(function()
        ChunkMesher.request(map, true, {}, true)
        ChunkMesher.request(map, false, {}, true)
        if ChunkMesher.persistentCacheAvailable() then
          -- A single ordinary-frame slice is enough to diagnose the Android
          -- path without reinstating the old 30-slice visible-frame stall.
          ChunkMesher.pump(false, false)
        else
          -- Keep the maintained release's diagnostic behaviour on desktop.
          for _ = 1, 30 do
            ChunkMesher.pump(true, false)
            if ChunkMesher.pair(map, true) or ChunkMesher.pair(map, false) then
              break
            end
          end
        end
      end)
      if not okB then V.dlog("meshKick error: " .. tostring(errB)) end
      local body = select(1, ChunkMesher.pair(map, true))
      local full = select(1, ChunkMesher.pair(map, false))
      V.dlog(("meshKick after pump pending=%s body=%s full=%s"):format(
        tostring(ChunkMesher.pending()),
        tostring(body ~= nil),
        tostring(full ~= nil)))
    end

    local okDraw, canvas = pcall(VoxelScene.render, st, rw, rh,
                                 ctx.vw, ctx.vh, ctx.paletteFor)
    if not okDraw then
      if not V.drawWorldWarned then
        V.drawWorldWarned = true
        V.dlog(("drawWorld 3D failed: %s"):format(tostring(canvas)))
      end
      return nil
    end
    if not canvas then
      if not V._nilDrawLogged then
        V._nilDrawLogged = true
        local map = st and st.map
        local body = map and select(1, ChunkMesher.pair(map, true))
        local full = map and select(1, ChunkMesher.pair(map, false))
        V.dlog(("drawWorld nil canvas map=%s pending=%s body=%s full=%s"):format(
          tostring(map and map.id),
          tostring(ChunkMesher.pending()),
          tostring(body ~= nil),
          tostring(full ~= nil)))
      end
      return nil   -- fall back to the 2D path
    end
    if not V._drawOkLogged then
      V._drawOkLogged = true
      V.dlog(("drawWorld 3D ok map=%s"):format(
        tostring(st and st.map and st.map.id)))
    end
    if Voxel3D.beginOverlay() then
      -- the FX closures are ordinary 2D draws sized in DISPLAY pixels, and
      -- they are drawing into the supersampled canvas alongside everything
      -- else -- so the scale goes up with it, or the "!" bubble lands the
      -- right place at half the size.  project() already answers in canvas
      -- pixels, so only the scale needs saying.
      ctx.drawFx(function(wx, wy) return Voxel3D.project(wx, 0, wy) end,
                 ctx.scale * AntiAlias.factor())
      -- the horde's readout rides the same overlay, over the FX: health,
      -- ammunition, the crosshair and the banners, sized in the same
      -- supersampled canvas pixels everything else here is drawn in. A
      -- headset never reaches this line (drawWorld returns the mirror
            HordeHud.drawFlat(rw, rh, ctx.scale * AntiAlias.factor())
      Voxel3D.endOverlay()
    end
    -- and back to the window's own size, which is what the engine composites
    -- one canvas pixel to one display pixel.  A pass-through when AA is off.
    return AntiAlias.resolve(canvas, sw, sh, "world")
  end,

  invalidate = function()
    Voxel3D.invalidate()
    OverworldBattle.invalidate()
    AntiAlias.invalidate()
    ChunkMesher.invalidate()   -- no map id = every cached mesh
    ForestAtmos.invalidate()   -- shaft/particle meshes and shader sentinels
    Pokeball.invalidate()      -- the ball's meshes and palette texture
    pcall(function()
      local vr = _vrCompanion or (mod.find and mod.find("VOXEL_VR") and mod.find("VOXEL_VR").exports)
      if vr and vr.invalidate then vr.invalidate() end
    end)
  end,
})

mod.content.render_pipelines:register("tiltshift", {
  label = "T-SHIFT",
  levels = TiltShift.LABELS,
  -- 6 is free: no engine branch claims it, so this one alone reaches the
  -- registry by the documented route
  hotkey = "6",
  priority = 10,

  update = function(dt, level)
    TiltShift.update(dt, level)
  end,

  -- worldPresent, not present: the blur belongs on the diorama, not on the
  -- dialog box in front of it.  A pass-through when the level is 0 or the
  -- shader is unavailable, so the frame is untouched in every other case.
  worldPresent = function(canvas)
    return TiltShift.apply(canvas)
  end,

  invalidate = function()
    TiltShift.invalidate()
  end,
})

-- ------- this mod's own settings
--
-- Neither of these is a pipeline: they own no pass of the frame, they
-- PARAMETERISE the voxel one, so they have nothing to put in drawWorld or
-- present and the registry would rightly reject them.  Plain mod settings
-- instead -- see ModSetting for where they persist and how the two rows
-- each ends up on stay in step.

-- ------- the FULL preset
--
-- Everything the mode wants switched to at once. Applied when the VOXEL row
-- ARRIVES at FULL and not again, so the player can still move the camera or
-- the zoom afterwards -- it is a starting point, not a lock.
--
-- Leaving FULL deliberately does NOT undo any of it. A preset that reverted
-- would throw away whatever the player had changed since, and "put it back
-- how it was" is not a thing this can know.
local fullWas = nil

applyFull = function(level)
  local isFull = Voxel.isFull(level)
  local was = fullWas
  fullWas = isFull
  if not isFull or was == true or was == nil then return end

  local Game = require("src.core.Game")
  local Pipelines = require("src.render.Pipelines")
  local Zoom = require("src.render.Zoom")
  local opts = Game.save and Game.save.options
  if not opts then return end

  -- the miniature blur at its strongest: FULL is the diorama look, and the
  -- tilt-shift is most of what makes it read as a model
  Pipelines.setLevel("tiltshift", Pipelines.maxLevel("tiltshift"))
  Pipelines.syncOptions(opts)
  -- the horizon flat. The curve bends the world away from a walking player,
  -- which fights a fixed diorama framing
  WorldCurve.setting:setIndex(1, Game)
  -- and the world cut to the window it is framed in (lib/ViewBox). FULL is
  -- the model-on-a-table read and the sides are most of what makes it one:
  -- a slab of Kanto with edges, rather than a map whose corners happen to
  -- fall off the frame.
  ViewBox.setting:setIndex(1, Game)
  -- and the water reflecting everything it can: FULL is the diorama at its
  -- most photographed, and a lake with the sky and the shoreline in it is
  -- most of what makes the model read as being outdoors
  Water.setting:setIndex(1, Game)
  -- and the view fitted to the window
  opts.zoom = 0
  Zoom.applyOptions(opts)
  -- battles on the map too: FULL means the whole mode, and a fight is where
  -- half of it is spent. Set and then LET GO of -- unlike the rows above, both
  -- battle rows stay on the menu under FULL (see the rows hook), so this is
  -- where the preset puts them and not where they are held.
  OverworldBattle.setting:setIndex(1, Game)
  -- with both mons out there on it: BACK SPRITES keeps the player's own on the
  -- menu, which is the one part of the old screen FULL is least about. Set the
  -- same way, and changed back on the same row a keypress later.
  OverworldBattle.backSetting:setIndex(1, Game)
  -- and the battle screen the staged fight is composed for. WIDE re-lays that
  -- screen out on a 304x144 surface, which moves every anchor the arena camera
  -- is solved against (OverworldBattle.forceOG); FULL has just switched staged
  -- fights on, so the layout follows them.
  OverworldBattle.forceOG(Game)
  -- and the sky on the clock on the wall: FULL pins DAYTIME to SYNC. Unlike
  -- the rest of the preset this one IS held, not just set -- the row is off
  -- the menu while FULL owns it (the rows hook below), so a value changed
  -- under it could never be seen or changed back.
  DayNight.forceSync(Game)
  if Game.writeOptions then pcall(Game.writeOptions, Game) end
end

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
  { OverworldBattle.setting,
    "Fights staged in 3D over your shoulder, on the map or on discs against "
    .. "the sky, as cards or Stadium's animated models.",
    cat = "battles", full = true },
  -- Only offered while a fight can actually be staged on the map: with 3D-BTL
  -- off the engine draws the classic screen, which is this row's ON already,
  -- and a row that no longer decides anything is worse than no row.
  { OverworldBattle.backSetting,
    "Keeps your own Pokemon on the battle menu, seen from behind, instead "
    .. "of standing it on the map facing the foe.",
    cat = "battles",
    when = function() return stagedBattles() end,
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
}

SettingsMenu.define(SETTINGS)

local schema = {}
for _, entry in ipairs(SETTINGS) do
  schema[#schema + 1] = entry[1]:schema(entry[2])
end
mod.options:define(schema)

-- ------- this mod's hotkeys
--
--   3  VOXEL    cycle the camera ladder      (was 6; skips FULL)
--   5  V-GRID   toggle the wireframe         (new)
--   6  T-SHIFT  cycle the blur ladder        (was 9)
--   7  V-CURVE  cycle the horizon bend       (new)
--   8  3D-BTL   cycle overworld battles      (new)
--   9  WATER    cycle the water reflections  (new; 9 was T-SHIFT's old key)
--
-- Only 6 arrives by the documented route. Game:keypressed answers the
-- engine's own display keys FIRST and returns -- 2 COLORS, 3 TILT, 4 ZOOM,
-- 5 GBC FX -- and only then offers the key to Pipelines.hotkey, expressly
-- so "a pipeline can never shadow one" (Schemas, render_pipelines.hotkey).
-- 3 and 5 are two of those, and 7 and 8 belong to plain mod settings that
-- own no pass and so have no registry to claim a key from at all.
--
-- So this wraps Game:keypressed. It is the invasive option and it is the
-- only one: polling the keyboard in update() would fire alongside the
-- engine's handler rather than instead of it, so 3 would cycle this mode
-- AND the engine's TILT on the same press.
--
-- Consequences worth being explicit about: while this mod is enabled, TILT
-- (3) and GBC FX (5) are unreachable by key -- and unreachable on the OPTIONS
-- menu too, where both rows are taken away and both values held at zero (see
-- pinEngineFx). Nothing is being hidden that still does something: TILT is the
-- flat fake of what this mode does for real, the registry already forces it
-- off whenever a world pipeline takes the pass, and GBC FX is a full-screen
-- present pass over the top of the diorama. Uninstalling puts both back.
--
-- Everything the engine does around a pipeline hotkey has to happen here
-- too, so the work is DELEGATED rather than reimplemented: Pipelines.hotkey
-- applies its own gate and ladder, and the three lines after it are the
-- engine's own (syncOptions, the tilt exclusion, writeOptions).

local HOTKEYS = {
  ["3"] = "pipeline",           -- voxel, by its declared hotkey
  ["6"] = "pipeline",           -- tiltshift, likewise
  ["5"] = VoxelGrid.setting,
  ["7"] = WorldCurve.setting,
  ["8"] = OverworldBattle.setting,
  ["9"] = Water.setting,
}

-- One step of the VOXEL angle ladder: everything a "3" press does, named
-- so the pad's SELECT button (below) can make exactly the same step. The
-- gate is the registry's own; the tilt/GBC FX clearing is the engine work
-- the key has always delegated (see the wrap below for why).
local function cycleVoxel(game)
  local Pipelines = require("src.render.Pipelines")
  -- HORDE MODE holds the rung at 1ST for as long as it runs. Refused HERE
  -- rather than at each caller because this one function IS every way a
  -- player can step the ladder: the "3" key and the pad's SELECT.
  if Horde.viewLocked() then return false end
  local top = game.stack and game.stack:top()
  if not Pipelines.canToggle("voxel", top, game.overworld) then return false end
  local nextLevel = Voxel.nextHotkeyLevel(Pipelines.level("voxel"))
  Pipelines.setLevel("voxel", nextLevel)
  Pipelines.syncOptions(game.save.options)
  -- 3 is the key that used to turn TILT on and sits next to the one that
  -- used to turn GBC FX on, and this mod has taken both away. A player who
  -- left either running before enabling the mod would otherwise have no
  -- way back to off, and both fight the diorama -- so the VOXEL step
  -- clears them on EVERY press, not just the press that switches on.
  game.save.options.tilt = 0
  game.save.options.gbcfx = 0
  require("src.render.GBCFX").setLevel(0)
  require("src.render.Tilt").setLevel(game.save.options.tilt or 0)
  game:writeOptions()
  V.log:event("voxel", "cycle", { level = nextLevel })
  return true
end

-- The same, to a NAMED rung rather than one step on: what a diorama mode
-- holds the ladder with, since 2D and both free-roam rungs are things it
-- cannot present. Everything after the setLevel is
-- the engine work above, for the same reasons.
local function setVoxelLevel(game, level)
  local Pipelines = require("src.render.Pipelines")
  if Horde.viewLocked() then return false end
  if Pipelines.level("voxel") == level then return false end
  Pipelines.setLevel("voxel", level)
  Pipelines.syncOptions(game.save.options)
  game.save.options.tilt = 0
  game.save.options.gbcfx = 0
  require("src.render.GBCFX").setLevel(0)
  require("src.render.Tilt").setLevel(game.save.options.tilt or 0)
  game:writeOptions()
  return true
end


do
  local Game = require("src.core.Game")
  local Pipelines = require("src.render.Pipelines")
  local inner = Game.keypressed

  function Game:keypressed(key)
    -- HORDE MODE owns the keyboard's spare keys while it runs: R reloads,
    -- and the mode keys are swallowed rather than left to change the rung
    -- or the post-processing out from under a locked camera.
    if Horde.active then
      if key == "r" then
        HordeGun.reload()
        return
      end
      if HOTKEYS[key] then return end
    end
    local claim = HOTKEYS[key]
    local top = self.stack and self.stack:top()
    -- Q and E work whichever camera is in front of the player -- the
    -- battle's lens, the third-person boom, or the engine's own survey
    -- zoom on an orbit rung. CamControl answers which, and answers "none"
    -- for 1ST and for every screen with no camera of ours behind it, in
    -- which case the key falls through untouched. Ahead of the hotkey
    -- table because unlike those it is NOT free-roam only: a staged battle
    -- is exactly where the zoom is most wanted.
    if (key == "q" or key == "e")
       and not (top and top.onKeyPressed) then
      if CamControl.zoomBy(key == "q" and 1 or -1) then return end
    end
    -- A screen with its own key handler gets the key first, exactly as the
    -- engine's first branch does: typing a nickname must not toggle a
    -- render mode. Only free-roam presses are ours to take.
    if claim and not (top and top.onKeyPressed) then
      if claim == "pipeline" then
        -- 3 walks the ANGLE rungs and steps over FULL (Voxel.HOTKEY_ORDER),
        -- so the registry's plain "advance one and wrap" is not what it
        -- wants; 6 still is. The gate is the registry's own either way.
        -- The whole of 3's step lives in cycleVoxel, because the pad's
        -- SELECT button makes the same step (see the handleInput wrap).
        if key == "3" then
          if cycleVoxel(self) then return end
        elseif Pipelines.hotkey(key, top, self.overworld) then
          Pipelines.syncOptions(self.save.options)
          require("src.render.Tilt").setLevel(self.save.options.tilt or 0)
          self:writeOptions()
          return
        end
      elseif Pipelines.canToggle("voxel", top, self.overworld) then
        -- All four answer to the voxel pass's own free-roam gate --
        -- borrowed from the registry rather than restated, so a press
        -- mid-warp or mid-cutscene is refused for the wireframe exactly when
        -- it would be for the mode itself. Three of them parameterise that
        -- pass; the fourth (3D-BTL) decides what a battle is drawn over, and
        -- wants the same gate for a different reason: the answer is read
        -- when the fight starts, so flipping it from inside one would be a
        -- switch that appeared to do nothing.
        claim:cycle(self)
        -- 8 is one of the two ways staged battles get switched on, and they
        -- pin BATTLE LAYOUT to OG (see the rows hook). The other keys
        -- parameterise the pass and leave the layout alone; the guard answers
        -- for all of them, so nothing here has to know which key it was.
        if stagedBattles() then OverworldBattle.forceOG(self) end
        return
      end
    end
    return inner(self, key)
  end
end

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
-- lib/SettingsMenu.lua. VOXEL and T-SHIFT go with it: they are this mod's
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
mod.hooks:wrap("ui.options.rows", function(next, game, rows)
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
mod.events:on("mod.options_changed", function(payload)
  if not (payload and payload.mod == mod.id) then return end
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

-- ------- keeping the geometry in step with the world
--
-- Terrain meshes are derived from a map's block layer, so anything that
-- rewrites a block (a cut tree, a smashed rock, a script's replaceBlock)
-- has to drop that map's cached mesh or the 3D world keeps showing the
-- tree that is no longer there.  The 2D tile renderer invalidates its own
-- caches off the same edit.

-- refresh, not invalidate: the stale mesh keeps drawing while the
-- replacement builds in the background, so a one-block edit (Cut, a
-- door stamp, the tree regrowing on re-entry) repopulates in place
-- instead of blinking the whole scene down to the flat 2D path
mod.events:on("world.block_replaced", function(payload)
  local mapId = payload and (payload.mapId or (payload.map and payload.map.id))
  if mapId then ChunkMesher.refresh(mapId) end
end)

-- The event above is the ANNOUNCED edit -- OverworldState:replaceBlock
-- emits it, which is the path Victory Road's barriers and a script's
-- replaceBlock take. Several edits do not go through it:
--
--   Cut          swaps the tree block and rebuilds the 2D renderer
--   the regrowth restores those blocks when the map is re-entered
--   card-key doors are stamped closed on floor load
--
-- all of them writing the block layer directly. Meshes derived from that
-- layer went stale with no announcement -- the cut tree stayed standing,
-- and after a round trip through a door the stump stayed cut because this
-- map's mesh survives in the cache (that is what prevLive is for).
--
-- The engine could announce each of those, and an earlier cut of this
-- work changed it to. That is the wrong place: it edits the game for one
-- mod's benefit, and every future path that writes a block has to
-- remember to do the same. They all funnel through ONE choke point --
-- Map:setBlock -- so wrap that from here instead. Map is a plain
-- metatable shared by every map instance, so this covers all of them,
-- including paths written after this mod.
--
-- Read back rather than trust the argument: setBlock silently ignores an
-- out-of-bounds write, and a stamp that rewrites a block with the value
-- it already held (the door code guards for this, the regrowth does not)
-- is not a change and must not throw the mesh away.
do
  local Map = require("src.world.Map")
  if not Map.dramaticShapeBlockHook then
    local setBlock = Map.setBlock
    Map.setBlock = function(self, bx, by, block)
      local before = self:blockAt(bx, by)
      setBlock(self, bx, by, block)
      if self.id and self:blockAt(bx, by) ~= before then
        ChunkMesher.refresh(self.id)
      end
    end
    Map.dramaticShapeBlockHook = true
  end
end

-- A reloaded map is rebuilt from scratch (warps that re-enter the same map,
-- hot reload), so its mesh is stale for the same reason -- with one
-- exception, and it is the common one.
--
-- A palette switch reloads the map ONLY to rebuild its atlas
-- (PaletteFX.setMode -> reloadMap(id, "colors")). The geometry that comes
-- back is identical: this mesher reads block layout and tile ids and never
-- reads colour, and the palette lives entirely in the texture TerrainAtlas
-- hands back per frame -- which is keyed BY palette, so the new colours are
-- already built by the time the next frame draws.
--
-- Dropping the mesh anyway cost a visible flash of the flat 2D world on
-- every palette toggle. Mesh builds are asynchronous, so the frames between
-- the drop and the first finished mesh have no terrain to draw, and
-- drawWorld returning nil IS the 2D fallback. Keeping the geometry lets the
-- new colours land on the diorama already on screen, in one frame, which is
-- what a palette toggle should look like from inside voxel mode.
mod.events:on("map.reloaded", function(payload)
  if payload and payload.reason == "colors" then return end
  local mapId = payload and (payload.mapId or (payload.map and payload.map.id))
  if mapId then ChunkMesher.invalidate(mapId) end
  -- the atmosphere's layout stands on the same carved stamps the meshes
  -- do, so it goes stale on exactly the same event
  if mapId then ForestAtmos.invalidate(mapId) end
  if V.log then
    V.log:event("map", "reloaded", {
      map = mapId or "unknown",
      reason = payload and payload.reason or "unknown",
    })
  end
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
    -- an engine row -- 3D-BTL, which owns BATTLE LAYOUT. Only the FULL-ness of the voxel level
    -- matters, so stepping 35 to 50 is not a change.
    local function signature()
      return string.format("%s|%s",
      tostring(Voxel.isFull(Pipelines.level("voxel"))),
      tostring(OverworldBattle.enabled()))
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
    -- -- is written out in lib/SettingsMenu.lua, next to the code that builds
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

-- ------- battles on the map
--
-- The wraps this needs -- OverworldState:pushBattle, BattleState:draw and
-- BattleState:drawHUDs -- all live in lib/OverworldBattle.lua, which is
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
-- it. See lib/Shiny.lua for why deriving beats storing.
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
-- extraction (lib/StadiumBuild.lua), and the battle simply asks for the
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
mod.hooks:wrap("pokemon.sprite", function(next, path, ctx)
  local out = next(path, ctx)
  pcall(ShinyPics.note, ctx)
  return out
end)

-- A save opened for the first time under this mod has shiny Pokemon in it
-- already -- they always did -- so refresh the cached flag across the party
-- rather than leaving it absent until each mon next changes.
mod.events:on("save.loaded", function() ShinyBattle.markParty() end)
mod.events:on("save.created", function() ShinyBattle.markParty() end)

-- ------- the free-roam rungs' inputs and their walk
--
-- 1ST and 3RD need two things no other rung does, and each is a named seam.
-- Both rungs are one rig -- the boom behind the shoulder is a number inside
-- it (lib/ThirdPerson.lua) -- so both are installed by the same two calls:
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
    V.require("StadiumRomPick").install()
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
-- is where keyboard, pad and touch have all already
-- become the same eight buttons. See lib/Horde.lua.
Horde.install()

-- ------- LET'S GO capture mode
--
-- After every other input seam on purpose: while a throw is being aimed
-- the capture's mouse and touch wraps are the OUTERMOST, so the flick is
-- read before anything else can claim the pointer -- and outside the aim
-- they forward every byte untouched. The battle-side wraps (throwBall,
-- safariAction) and the experience hooks install here too.
LetsGo.install()


-- The overworld's own pushBattle is the choke point for a wild encounter or
-- a trainer, and it is wrapped. A battle that arrives some other way -- a
-- link battle, a script pushing a BattleState directly -- reaches this
-- instead, which stages the arena from wherever the player is standing.
-- Nothing visible is lost by being late: the cull only has to beat the
-- battle screen, and the wipe those battles skip is where it would have
-- shown.
mod.events:on("battle.started", function(payload)
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
mod.hooks:wrap("pokemon.sprite", function(next, path, ctx)
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
mod.events:on("battle.ended", function()
  OverworldBattle.finish()
  V.log:event("battle", "ended", {})
end)

-- ------- and the way back out
--
-- The engine wipes INTO a battle with one of the original's eight transitions
-- and cuts straight OUT of it. That cut is between two very different cameras
-- in this mode, so while voxel mode is on the battle fades out, closes behind
-- the black, and the map fades up. The two seams it needs -- BattleState:finish
-- and Renderer:endFrame -- and the reasoning for each live in lib/BattleExit.lua.
--
-- Declared as a transitions record rather than a constant in that file, so the
-- fade is retunable in data exactly like the eight wipes it answers, and a total
-- conversion can make it as long or as short as its own pacing wants.
mod.content.transitions:register(BattleExit.ID, {
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
-- The cycle's clock rides the SAVE SLOT (save.modData, via mod.save): what
-- time it is in Kanto is a fact about that journey, like where the player is
-- standing. Written on the engine's save.writing event -- the moment before
-- the bytes hit disk -- and read back whenever a save is opened or begun. A
-- save with no clock in it starts at day; that is DayNight.restore's
-- fallback, and also the DAYTIME row's own default.
mod.events:on("save.writing", function()
  DayNight.store()
end)

mod.events:on("save.loaded", function()
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

mod.events:on("save.created", function()
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
mod.hooks:wrap("world.tod", function(next, tod, ctx)
  local out = next(tod, ctx)
  if out ~= tod then return out end
  return DayNight.tod()
end)

mod.exports.version = "1.9.0"
-- exposed so a companion mod can pin its own tiles' shapes or read the
-- camera without reaching into this mod's file layout
mod.exports.lib = V
-- Ladder helpers for the VOXEL_VR companion (was VR.cycleVoxel /
-- VR.setVoxelLevel when VR lived in this package).
mod.exports.cycleVoxel = cycleVoxel
mod.exports.setVoxelLevel = setVoxelLevel
-- Optional VR companion registration (VOXEL_VR calls this).
function mod.exports.registerVR(exports)
  _vrCompanion = exports
  if V and V.dlog then V.dlog("VR companion registered") end
end
function mod.exports.vrCompanion()
  return _vrCompanion
end
-- Diagnostic ring buffer (also under mod.storage key diagnostics/log).
mod.exports.diagnosticLog = function()
  return V.log and V.log:contents() or ""
end
mod.exports.flushDiagnostics = function()
  return V.log and V.log:flush()
end

-- Options row: SAVE DIAGNOSTIC SNAPSHOT (forces a flush to mod.storage).
mod.hooks:wrap("ui.options.rows", function(next, game, rows)
  local out = next(game, rows)
  if type(out) ~= "table" then return out end
  if game then ModStorage.setGame(game) end
  out[#out + 1] = ModLogExport.row()
  return out
end)

V.log:info("main.lua load complete")
