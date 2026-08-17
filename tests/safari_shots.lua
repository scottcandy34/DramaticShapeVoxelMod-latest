-- Scratch driver: the Safari Zone's decorations — the "cut"-style round
-- trees ($54/$55/$56/$57, one cell) and the stump/bush rows ($02/$03/
-- $12/$13) — front and back, at the voxel rung (5) and the flat rung (3)
-- for orientation. Same spots BEFORE and AFTER the pin change.
--
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/safari_shots.lua \
--   SHOT_DIR=.scratchpad/safari AB_TAG=before "/c/Program Files/LOVE/lovec.exe" .
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local Pipelines = require("src.render.Pipelines")

  local ROOT = (os.getenv("SHOT_DIR") or "shots/safari")
    .. "/" .. (os.getenv("AB_TAG") or "after")

  local handle = game.mods.exports["DRAMATIC_SHAPE"]
  if not (handle and handle.lib) then
    print("[safari] DRAMATIC_SHAPE is not loaded")
    return
  end
  local V = handle.lib
  do -- what does the RUNNING mod think tile 84 on FOREST is?
    local TS = V.require("voxel/TileShape")
    local shapes = TS.forMap({ tileset = { id = "FOREST",
                                           imageWidth = 128,
                                           imageHeight = 48 } })
    local s = shapes[84]
    print("[safari] running-mod tile 84: "
      .. (s and (tostring(s.class) .. "/" .. tostring(s.art)
                 .. " authored=" .. tostring(s.authored)) or "nil"))
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
    -- tree row at (2..5, 3), seen from the south = its front
    { map = "SAFARI_ZONE_EAST", x = 4, y = 5, face = "up", label = "trees_front" },
    -- the same row from the north = its back
    { map = "SAFARI_ZONE_EAST", x = 4, y = 1, face = "down", label = "trees_back" },
    -- the long tree line at (2..9, 6)
    { map = "SAFARI_ZONE_EAST", x = 6, y = 8, face = "up", label = "treeline" },
    -- the stump/bush row along the top edge (8..19, 0)
    { map = "SAFARI_ZONE_EAST", x = 12, y = 2, face = "up", label = "stumps_front" },
    -- Safari Center's west tree column, edge-on
    { map = "SAFARI_ZONE_CENTER", x = 2, y = 4, face = "left", label = "center_trees" },
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
        else print("[safari] capture missed: " .. path) end
      end
    else
      print("[safari] teleport failed: " .. s.map)
    end
  end
  print(("[safari] %d shots into %s"):format(shots, ROOT))
  love.event.quit()
end
