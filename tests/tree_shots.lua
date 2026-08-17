-- Scratch driver: Celadon Gym's little tree ($40/$41 over $50/$51,
-- one cell) at CELADON_GYM (5,7), flanked by the hedge cylinders.
-- Front and back, voxel rung (5) and flat rung (3). Same spots BEFORE
-- and AFTER the pin change.
--
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/tree_shots.lua \
--   SHOT_DIR=.scratchpad/celtree AB_TAG=before "/c/Program Files/LOVE/lovec.exe" .
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local Pipelines = require("src.render.Pipelines")

  local ROOT = (os.getenv("SHOT_DIR") or "shots/celtree")
    .. "/" .. (os.getenv("AB_TAG") or "after")

  local handle = game.mods.exports["DRAMATIC_SHAPE"]
  if not (handle and handle.lib) then
    print("[celtree] DRAMATIC_SHAPE is not loaded")
    love.event.quit()
    return
  end
  local V = handle.lib
  do -- prove the RUNNING mod sees the pin we think it does
    local TS = V.require("voxel/TileShape")
    local shapes = TS.forMap({ tileset = { id = "GYM",
                                           imageWidth = 128,
                                           imageHeight = 48 } })
    for _, t in ipairs({ 64, 80 }) do
      local s = shapes[t]
      print("[celtree] running-mod GYM tile " .. t .. ": "
        .. (s and (tostring(s.class) .. "/" .. tostring(s.art)
                   .. " h=" .. tostring(s.h)) or "nil"))
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
    -- the tree at (5,7) seen from the south = its front
    { map = "CELADON_GYM", x = 5, y = 8, face = "up", label = "tree_front" },
    -- the same tree from the north = its back
    { map = "CELADON_GYM", x = 5, y = 6, face = "down", label = "tree_back" },
    -- a step further back so the whole tree fits over the hedges
    { map = "CELADON_GYM", x = 5, y = 9, face = "up", label = "tree_far" },
    -- from the open floor west of it, edge-on
    { map = "CELADON_GYM", x = 4, y = 8, face = "up", label = "tree_west" },
    -- the second placement at (7,5), unobstructed in the east garden
    { map = "CELADON_GYM", x = 7, y = 7, face = "up", label = "tree2_front" },
    { map = "CELADON_GYM", x = 8, y = 5, face = "left", label = "tree2_east" },
    { map = "CELADON_GYM", x = 7, y = 3, face = "down", label = "tree2_back" },
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
        else print("[celtree] capture missed: " .. path) end
      end
    else
      print("[celtree] teleport failed: " .. s.map)
    end
  end
  print(("[celtree] %d shots into %s"):format(shots, ROOT))
  love.event.quit()
end
