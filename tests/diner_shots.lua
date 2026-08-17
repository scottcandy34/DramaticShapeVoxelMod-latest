-- Scratch driver: the Celadon Diner's stools ($07/$08/$23/$24 on LOBBY,
-- one cell each; the pinned `stool` standee pool). Shot at the voxel
-- rung (5) and the flat rung (3) for orientation, front/back/side of
-- the stool at cell (0,4).
--
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/diner_shots.lua \
--   SHOT_DIR=mods/DramaticShapeVoxelMod/.claude/voxelizations \
--   "/c/Program Files/LOVE/lovec.exe" .
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local Pipelines = require("src.render.Pipelines")

  local ROOT = (os.getenv("SHOT_DIR")
    or "mods/DramaticShapeVoxelMod/.claude/voxelizations")

  local handle = game.mods.exports["DRAMATIC_SHAPE"]
  if not (handle and handle.lib) then
    print("[diner] DRAMATIC_SHAPE is not loaded")
    return
  end
  local V = handle.lib
  do -- prove the RUNNING mod resolves the stool tiles as pinned
    local TS = V.require("voxel/TileShape")
    local shapes = TS.forMap({ tileset = { id = "LOBBY",
                                           imageWidth = 128,
                                           imageHeight = 48 } })
    for _, t in ipairs({ 7, 8, 23, 24 }) do
      local s = shapes[t]
      print(("[diner] running-mod tile %d: %s"):format(t,
        s and (tostring(s.class) .. "/" .. tostring(s.art)
               .. " h=" .. tostring(s.height)) or "nil"))
    end
  end
  local DayNight = V.require("effects/DayNight")
  local ChunkMesher = V.require("voxel/ChunkMesher")
  local Voxel = V.require("voxel/VoxelState")

  require("src.world.OverworldController").rollEncounter = function() return nil end
  local TileRenderer = require("src.render.TileRenderer")
  TileRenderer.tick = function() end
  TileRenderer.animFrame = function() return 0 end
  DayNight.setting:sync("day")

  pcall(os.execute, 'mkdir -p "' .. ROOT .. '" 2>/dev/null')
  pcall(os.execute, 'mkdir "' .. ROOT:gsub("/", "\\") .. '" 2>nul')

  local Zoom = require("src.render.Zoom")
  pcall(function()
    game.save.options.zoom = 1
    Zoom.applyOptions(game.save.options)
  end)

  local function settle()
    for _ = 1, 900 do
      if ChunkMesher.pending() == 0 then break end
      U.wait(1)
    end
    for _ = 1, 300 do
      if Voxel.t >= 1 and Voxel.ready and ChunkMesher.pending() == 0 then break end
      U.wait(1)
    end
    U.wait(40)
  end

  local SCENES = {
    -- the stool at (0,4), seen from the south = its front (legs row)
    { map = "CELADON_DINER", x = 0, y = 6, face = "up", label = "stool_front" },
    -- the same stool from the north = its back
    { map = "CELADON_DINER", x = 0, y = 2, face = "down", label = "stool_back" },
    -- edge-on from the east, with the table beside it in frame
    { map = "CELADON_DINER", x = 2, y = 4, face = "left", label = "stool_side" },
  }

  local shots = 0
  for _, s in ipairs(SCENES) do
    local ok = pcall(U.teleport, game, s.map, s.x, s.y, s.face)
    if ok then
      for _, rung in ipairs({ 5, 3 }) do
        Pipelines.setLevel("voxel", rung)
        Pipelines.setLevel("tiltshift", 0)
        settle()
        local path = ("%s/%s_r%d.png"):format(ROOT, s.label, rung)
        game.capturePath = path
        U.wait(6)
        local f = io.open(path, "rb")
        if f then f:close() shots = shots + 1
        else print("[diner] capture missed: " .. path) end
      end
    else
      print("[diner] teleport failed: " .. s.map)
    end
  end
  print(("[diner] %d shots into %s"):format(shots, ROOT))
  love.event.quit()
end
