-- Scratch driver: the overworld cuttable tree ($2D/$2E/$3D/$3E, one
-- cell) at PEWTER_CITY (26,4) -- it sits in a gap of the border tree
-- wall, so shoot from the open grass east/west and the path south.
-- Same spots BEFORE and AFTER the pin change.
--
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/cuttree_shots.lua \
--   SHOT_DIR=.scratchpad/cuttree AB_TAG=before "/c/Program Files/LOVE/lovec.exe" .
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local Pipelines = require("src.render.Pipelines")

  local ROOT = (os.getenv("SHOT_DIR") or "shots/cuttree")
    .. "/" .. (os.getenv("AB_TAG") or "after")

  local handle = game.mods.exports["DRAMATIC_SHAPE"]
  if not (handle and handle.lib) then
    print("[cuttree] DRAMATIC_SHAPE is not loaded")
    love.event.quit()
    return
  end
  local V = handle.lib
  do -- prove the RUNNING mod sees the pin we think it does
    local TS = V.require("voxel/TileShape")
    local shapes = TS.forMap({ tileset = { id = "OVERWORLD",
                                           imageWidth = 128,
                                           imageHeight = 48 } })
    for _, t in ipairs({ 45, 61 }) do
      local s = shapes[t]
      print("[cuttree] running-mod OVERWORLD tile " .. t .. ": "
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
    -- open grass west of the tree, edge-on
    { map = "PEWTER_CITY", x = 25, y = 4, face = "right", label = "cut_west" },
    -- open grass east of it
    { map = "PEWTER_CITY", x = 27, y = 4, face = "left", label = "cut_east" },
    -- the path south, seeing its front over the tree wall gap
    { map = "PEWTER_CITY", x = 26, y = 6, face = "up", label = "cut_front" },
    -- one step closer on the gap's south side
    { map = "PEWTER_CITY", x = 26, y = 5, face = "up", label = "cut_near" },
    -- Cerulean's lone cut tree at (19,28): open grass to its south
    { map = "CERULEAN_CITY", x = 19, y = 30, face = "up", label = "cer_front" },
    { map = "CERULEAN_CITY", x = 19, y = 29, face = "up", label = "cer_near" },
    { map = "CERULEAN_CITY", x = 20, y = 29, face = "up", label = "cer_diag" },
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
        else print("[cuttree] capture missed: " .. path) end
      end
    else
      print("[cuttree] teleport failed: " .. s.map)
    end
  end
  print(("[cuttree] %d shots into %s"):format(shots, ROOT))
  love.event.quit()
end
