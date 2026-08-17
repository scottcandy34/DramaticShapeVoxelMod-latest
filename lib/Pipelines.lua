local V = ...

local mod = V.mod

local Voxel = V.require("voxel/VoxelState")
local Voxel3D = V.require("voxel/Voxel3D")
local VoxelScene = V.require("voxel/VoxelScene")
local TiltShift = V.require("effects/TiltShift")
local ChunkMesher = V.require("voxel/ChunkMesher")
local VoxelCacheScreen = V.require("voxel/VoxelCacheScreen")
local WorldCurve = V.require("effects/WorldCurve")
local ViewBox = V.require("voxel/ViewBox")
local OverworldBattle = V.require("battle/OverworldBattle")
local StadiumBattleFxProvider = V.require("stadium/fx/StadiumBattleFxProvider")
local DayNight = V.require("effects/DayNight")
local Water = V.require("effects/Water")
local ForestAtmos = V.require("effects/ForestAtmos")
local AntiAlias = V.require("effects/AntiAlias")
local FirstPerson = V.require("camera/FirstPerson")
local VR = V.require("vr/VR")
-- HORDE MODE: the konami code's minigame. Horde owns the state machine and
-- every hook; the other four are the gun, the crowd, the readout and the
-- chip-synthesized sounds it fires. See lib/modes/horde/Horde.lua for the whole design.
local Horde = V.require("modes/horde/Horde")
local HordeHud = V.require("modes/horde/HordeHud")
-- LET'S GO: the flick-to-throw capture mode. LetsGo owns the row, the
-- wraps and the experience math; CatchThrow the session (input, arc,
-- ring, choreography); Pokeball the animated prop they throw.
local LetsGo = V.require("modes/catch/LetsGo")
local Pokeball = V.require("modes/catch/Pokeball")

local ModStorage = V.storage

mod.events:on("mods.loaded", function()
  StadiumBattleFxProvider.register()
end)

-- Forward declaration: the voxel pipeline's update hook (registered below)
-- calls this, and it is defined further down with the settings it drives.
-- Declared rather than left global -- a mod writing to _G would leak into
-- every other mod's namespace.

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

local function applyFull(level)
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
  -- hotkey block in lib/ui/Hotkeys.lua for how it is claimed
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
    pcall(function() V.require("stadium/StadiumScreen").maybePush() end)
    -- and a ROM the system file picker dropped in the save directory while
    -- we were not the top activity (Android; see StadiumRomPick.poll)
    pcall(function()
      V.require("stadium/rom/StadiumRomPick").poll(require("src.core.Game"))
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
    -- The whole VR frame -- session lifecycle, xrWaitFrame's pacing, both
    -- eye renders, the layer submit -- rides this hook, because it is the
    -- one tick that runs through menus, dialogs and battles, which is
    -- what a headset needs the world (or at least the UI panel) to do.
    -- Ahead of the active() gate: with the mode off, the headset still
    -- shows the flat screen on the floating panel.
    VR.update(dt)
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
    -- the palette closure, stashed for the VR frame: it renders from the
    -- update hook, where no ctx exists to carry one
    VR.paletteFor = ctx.paletteFor
    -- With a headset running, the window's world pass becomes the MIRROR
    -- -- the left eye, fitted to the window -- rather than a third full
    -- render of the scene. Everything else about the frame (the UI the
    -- engine composites over this) is unchanged, which is exactly what
    -- the headset's floating panel photographs.
    if VR.active() then
      local sw, sh = sceneSize(ctx)
      local m = VR.mirror(sw, sh)
      if m then return m end
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
      -- above) -- lib/VR draws the same HUD onto each eye instead.
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
    VR.invalidate()            -- the mirror, and FBO ids of dead canvases
    Pokeball.invalidate()      -- the ball's meshes and palette texture
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

return true
