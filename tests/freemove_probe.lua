-- Probe: does WASD still walk CAMERA-RELATIVE on the 1ST/3RD rungs?
--
-- The regression report is "in first and third person the wasd keys now
-- move in cardinal directions". Cardinal means the yaw is not being
-- applied -- either FreeMove.tick is not the handler that ran (so the
-- engine's grid walk did, which is cardinal by construction), or it ran
-- and moveWorld got a yaw of zero.
--
-- So measure both: which handler took the frame, what the yaw was, and
-- which way the player actually travelled for a held W.
--
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/freemove_probe.lua \
--   "/c/Program Files/LOVE/lovec.exe" .
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local Pipelines = require("src.render.Pipelines")

  local handle = game.mods.exports["DRAMATIC_SHAPE"]
  if not (handle and handle.lib) then
    U.log("DRAMATIC_SHAPE is not loaded")
    return love.event.quit()
  end
  local V = handle.lib
  local FirstPerson = V.require("camera/FirstPerson")
  local FreeMove = V.require("camera/FreeMove")
  local Voxel = V.require("voxel/VoxelState")
  local ChunkMesher = V.require("voxel/ChunkMesher")

  require("src.world.OverworldController").rollEncounter = function() return nil end

  -- FirstPerson captures the mouse only with WINDOW FOCUS, and a driver
  -- window never has it -- so without this the look reads as dead for a
  -- reason that has nothing to do with the code under test. Force the
  -- answer it gates on; setRelativeMode then arms and the relative-motion
  -- wrap claims the deltas exactly as it would for a player.
  love.window.hasFocus = function() return true end

  -- count which walk handler actually takes the frames
  local ticks = 0
  local innerTick = FreeMove.tick
  FreeMove.tick = function(...)
    ticks = ticks + 1
    return innerTick(...)
  end

  U.teleport(game, "ROUTE_1", 5, 8, "down")
  U.wait(60)

  local function settle()
    for _ = 1, 900 do
      if ChunkMesher.pending() == 0 then break end
      U.wait(1)
    end
    for _ = 1, 300 do
      if FirstPerson.blend >= 1 and Voxel.ready then break end
      U.wait(1)
    end
    U.wait(30)
  end

  -- W is the UP button; the B button's key is "x" (see Input's
  -- DEFAULT_BINDINGS -- the driver must press KEYS, not button names, to
  -- exercise the real path)
  local function holdKey(k, frames)
    love.keypressed(k, k, false)
    U.wait(frames)
    love.keyreleased(k, k)
    U.wait(4)
  end

  for _, rung in ipairs({ { "1ST", Voxel.FP_LEVEL }, { "3RD", Voxel.TP_LEVEL } }) do
    Pipelines.setLevel("voxel", rung[2])
    settle()
    -- face EAST: yaw is the free-roam look, and a camera-relative W must
    -- then walk +X. A cardinal W walks -Y (north) whatever the camera does.
    FirstPerson.yaw = math.pi / 2
    U.wait(10)

    local ow = game.stack:top()
    local p = ow and ow.player
    if not p then U.log(rung[1] .. ": no player") break end
    local x0, y0 = p.px, p.py
    ticks = 0
    holdKey("w", 40)
    local dx, dy = p.px - x0, p.py - y0
    U.log(("%s: driving=%s freeMove ticks=%d yaw=%.2f  W moved dx=%.1f dy=%.1f")
          :format(rung[1], tostring(FirstPerson.driving()), ticks,
                  FirstPerson.yaw, dx, dy))
    local wx, wz = FirstPerson.moveWorld(0, 1)
    U.log(("%s: moveWorld(0,1) = %.2f,%.2f  (want a mostly-X vector at this yaw)")
          :format(rung[1], wx, wz))

    -- ------- and does the LOOK still turn?
    --
    -- A yaw that never moves is the same symptom from the player's seat:
    -- it stays at the cardinal angle the rung was entered on (FACING_ANGLE
    -- is one of four compass points), so W walks due north for ever and
    -- "wasd moves in cardinal directions" is exactly what it feels like.
    -- The capture mode's pointer wraps are installed OUTSIDE FirstPerson's,
    -- so this is the path that could have regressed.
    -- FirstPerson only claims relative motion while it has CAPTURED the
    -- mouse, and it captures only with window focus. A driver window that
    -- never got focus would show a dead look for a reason that has nothing
    -- to do with the code -- so record the discriminator rather than read
    -- a zero and blame the wrap.
    local okF, focus = pcall(function() return love.window.hasFocus() end)
    local okR, rel = pcall(function() return love.mouse.getRelativeMode() end)
    U.log(("%s: engaged=%s focus=%s relativeMode=%s")
          :format(rung[1], tostring(FirstPerson.engaged()),
                  okF and tostring(focus) or "?",
                  okR and tostring(rel) or "?"))

    local before = FirstPerson.yaw
    for _ = 1, 10 do
      love.mousemoved(400, 300, 12, 0, false)
      U.wait(1)
    end
    U.wait(4)
    U.log(("%s: mouse look -- yaw %.3f -> %.3f (delta %.3f)%s")
          :format(rung[1], before, FirstPerson.yaw, FirstPerson.yaw - before,
                  math.abs(FirstPerson.yaw - before) < 1e-6
                  and "   <-- THE LOOK IS DEAD" or ""))
  end

  -- ------- and now the way a PLAYER gets there: the "3" hotkey
  --
  -- Pipelines.setLevel above is the driver's shortcut. A player cycles the
  -- rung with 3, which goes through the mod's own cycleVoxel. If that
  -- leaves Voxel.level disagreeing with the pipeline's level, the camera
  -- can be first-person while FreeMove.engaged() says no -- and then the
  -- ENGINE's grid handler takes the frame, which walks cardinally. That is
  -- the reported symptom exactly, so it is worth entering the rung the
  -- same way the report did.
  Pipelines.setLevel("voxel", 0)
  U.wait(20)
  for i = 1, 8 do
    love.keypressed("3", "3", false)
    U.wait(3)
    love.keyreleased("3", "3")
    U.wait(12)
    local lvl = Pipelines.level("voxel")
    U.log(("hotkey 3 x%d -> pipeline level=%s  Voxel.level=%s  freeCam=%s "
           .. "engaged=%s driving=%s")
          :format(i, tostring(lvl), tostring(Voxel.level),
                  tostring(Voxel.isFreeCam(Voxel.level)),
                  tostring(FirstPerson.engaged()),
                  tostring(FirstPerson.driving())))
    if Voxel.isFreeCam(Voxel.level) then
      settle()
      local ow = game.stack:top()
      local p = ow and ow.player
      FirstPerson.yaw = math.pi / 2
      U.wait(6)
      local yaw0 = FirstPerson.yaw
      local x0, y0 = p.px, p.py
      ticks = 0
      holdKey("w", 30)
      U.log(("  walked from the HOTKEY rung: ticks=%d yaw=%.2f dx=%.1f dy=%.1f%s")
            :format(ticks, yaw0, p.px - x0, p.py - y0,
                    ticks == 0 and "   <-- ENGINE GRID WALK (cardinal)" or ""))
    end
  end

  FreeMove.tick = innerTick
  U.log("done")
end
