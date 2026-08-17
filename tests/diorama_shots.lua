-- Driver: the DIORAMA mode's own frame, without a headset.
--
-- The diorama is drawn through VoxelScene's `eyes` path, and that path only
-- ever runs from lib/VR -- so with no OpenXR runtime on the machine there is
-- nothing to look at and nothing to check. This builds ONE eye by hand (the
-- same VRRig mapping the headset would have built), opens a diorama frame,
-- and encodes the eye canvas straight to a PNG.
--
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/diorama_shots.lua \
--   SHOT_DIR=<dir> lovec.exe .
--
-- knobs (env):
--   SHOT_DIR    output directory under the LOVE save dir (default "diorama")
--   DIO_MAP     map id                        (default VIRIDIAN_CITY)
--   DIO_SPOT    "x,y[,facing]"                (default 20,26,up)
--   DIO_RUNG    the voxel camera rung         (default 5, the 75 one)
--
-- It also prints whether each shader the mode touches actually COMPILED,
-- which is the part a headless suite cannot answer: the cull is new source
-- in the scene shader, the water shader and both forest ones, and a shader
-- that will not build fails soft everywhere in this mod -- the picture just
-- quietly loses a pass.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local Pipelines = require("src.render.Pipelines")

  local ROOT = os.getenv("SHOT_DIR") or "diorama"

  local handle = game.mods.exports["DRAMATIC_SHAPE"]
  if not (handle and handle.lib) then
    print("[dio] DRAMATIC_SHAPE mod not loaded -- nothing to shoot")
    return
  end
  local V = handle.lib
  local Voxel = V.require("voxel/VoxelState")
  local Voxel3D = V.require("voxel/Voxel3D")
  local VoxelScene = V.require("voxel/VoxelScene")
  local VRRig = V.require("vr/VRRig")
  local Diorama = V.require("vr/Diorama")
  local Water = V.require("effects/Water")
  local ChunkMesher = V.require("voxel/ChunkMesher")
  local DayNight = V.require("effects/DayNight")
  local VR = V.require("vr/VR")
  local Curve = V.require("effects/WorldCurve")

  local MAP = os.getenv("DIO_MAP") or "VIRIDIAN_CITY"
  local SPOT = os.getenv("DIO_SPOT") or "20,26,up"
  local RUNG = math.floor(tonumber(os.getenv("DIO_RUNG")) or 5)
  local sx, sy, sf = SPOT:match("^(%-?%d+),%s*(%-?%d+),?%s*(%a*)$")
  sx, sy = tonumber(sx) or 20, tonumber(sy) or 26
  if sf == "" then sf = "up" end

  require("src.world.OverworldController").rollEncounter = function() return nil end
  DayNight.setting:sync("day")
  U.teleport(game, MAP, sx, sy, sf)
  Pipelines.setLevel("voxel", RUNG)
  Pipelines.setLevel("tiltshift", 0)

  local function settle()
    for _ = 1, 900 do
      if ChunkMesher.pending() == 0 then break end
      U.wait(1)
    end
    for _ = 1, 300 do
      if Voxel.t >= 1 and Voxel.ready and ChunkMesher.pending() == 0 then
        break
      end
      U.wait(1)
    end
    U.wait(20)
  end
  settle()
  settle()

  print(("[dio] scene shader %s | grid variant %s | water %s")
    :format(tostring(Voxel3D.shader() ~= nil),
            tostring(Voxel3D.shader(true) ~= nil),
            tostring(Water.shader(false) ~= nil)))

  -- one eye, straight ahead from the resting head: the mapping lib/VR would
  -- have built for this rung, with no pose to read off a runtime
  local POSE = { pos = { 0, 0, 0 }, quat = { 0, 0, 0, 1 } }
  local FOV = { angleLeft = -0.8, angleRight = 0.8,
                angleUp = 0.7, angleDown = -0.7 }

  local function shoot(name, opts)
    local ow = game.overworld
    local vw, vh = 320, 288
    pcall(function() vw, vh = game.renderer:worldViewSize() end)
    local cx = ow.camera.x + vw / 2
    local cy = ow.camera.y + vh / 2

    Diorama.begin(opts.mode or "diorama")
    Diorama.zoom = opts.zoom or 1
    Diorama.yaw = opts.yaw or 0
    -- the cut's SHAPE is the V-CURVE row's (box while flat, ball while
    -- bent), so the driver throws the row rather than asking for a shape
    Curve.setting:sync(opts.curve or 0)
    if opts.arena then
      Diorama.pillar(opts.arena)
    else
      Diorama.viewport(cx, cy, vh)
    end
    local pivot = VRRig.dioramaPivot(Diorama.cull.x, Diorama.cull.z)
    local anchor = VRRig.dioramaAnchor(Voxel.angle, Diorama.offset)
    -- the same framing lib/VR picks: the view ordinarily, the DISC while a
    -- fight is staged
    local frame = opts.arena and (Diorama.cull.r * 2.6) or vh
    local scale = VRRig.dioramaScale(frame, Voxel.FOCAL)
    -- the bend the diorama asks its eyes for (lib/VR does the same)
    local curveK = Curve.k(vh)
    local eyes = {
      { camera = VRRig.eyeCamera(POSE, FOV, pivot, anchor, scale,
                                 opts.yaw ~= 0 and opts.yaw or nil, curveK),
        w = 720, h = 720, slot = "vrL", adopt = false },
      cx = pivot[1], cy = pivot[3],
    }
    VoxelScene.spriteLean = math.rad(75)
    local ok, out = pcall(VoxelScene.render, ow, 0, 0, vw, vh,
                          VR.paletteFor, eyes)
    VoxelScene.spriteLean = nil
    if not (ok and out and out[1]) then
      print("[dio] " .. name .. ": no frame (" .. tostring(out) .. ")")
      Diorama.stop()
      return
    end
    local okE, err = pcall(function()
      love.filesystem.createDirectory(ROOT)
      local data = out[1]:newImageData()
      data:encode("png", ROOT .. "/" .. name .. ".png")
    end)
    print("[dio] " .. name
          .. (okE and " written" or (" ENCODE FAILED: " .. tostring(err))))
    Diorama.stop()
  end

  shoot("box", { mode = "diorama" })
  shoot("box-turned", { mode = "diorama", yaw = math.rad(35) })
  shoot("box-tight", { mode = "diorama", zoom = 0.5 })
  shoot("ball-3", { mode = "diorama", curve = 3 })
  shoot("ball-4", { mode = "diorama", curve = 4 })
  shoot("ball-5", { mode = "diorama", curve = 5 })
  shoot("ball-wide", { mode = "diorama", curve = 5, zoom = 1.9 })
  shoot("keyed", { mode = "diorama-mr" })
  shoot("keyed-ball", { mode = "diorama-mr", curve = 3 })
  do
    -- a fight's disc, cut about the arena the map would actually stage on
    local BattleArena = V.require("battle/BattleArena")
    local ow = game.overworld
    local arena = BattleArena.find(ow.map, ow.player.cellX, ow.player.cellY,
                                   false)
    if arena then
      shoot("arena-disc", { mode = "diorama", arena = arena })
    else
      print("[dio] no arena on this map -- disc shot skipped")
    end
  end

  Diorama.stop()
  print("[dio] done; PNGs are under the LOVE save directory / " .. ROOT)
  love.event.quit()
end
