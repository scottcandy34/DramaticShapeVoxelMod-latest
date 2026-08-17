-- Scratch driver: the round tables of the Celadon diner and the Mart
-- roof terrace (the diner_round_table template's four placements).
-- Shot at the voxel rung (5) and the flat rung (3), front/back/side of
-- the diner table at cells (0,5):(1,6) plus the terrace pair.
--
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/table_shots.lua \
--   SHOT_DIR=mods/DramaticShapeVoxelMod/.claude/voxelizations \
--   AB_TAG=before "/c/Program Files/LOVE/lovec.exe" .
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local Pipelines = require("src.render.Pipelines")

  local ROOT = (os.getenv("SHOT_DIR")
    or "mods/DramaticShapeVoxelMod/.claude/voxelizations")
  local TAG = os.getenv("AB_TAG") or "shot"

  local handle = game.mods.exports["DRAMATIC_SHAPE"]
  if not (handle and handle.lib) then
    print("[table] DRAMATIC_SHAPE is not loaded")
    return
  end
  local V = handle.lib
  local Buildings = V.require("voxel/structures/Buildings")
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
    -- the diner table at (0,5):(1,6), seen from the south = its front
    { map = "CELADON_DINER", x = 1, y = 7, face = "up", label = "diner_front" },
    -- the same table from the north = its back (standing between the two)
    { map = "CELADON_DINER", x = 0, y = 4, face = "down", label = "diner_back" },
    -- edge-on from the east
    { map = "CELADON_DINER", x = 3, y = 5, face = "left", label = "diner_side" },
    -- the roof terrace's table at (4,2):(5,3), from the south
    { map = "CELADON_MART_ROOF", x = 4, y = 4, face = "up", label = "roof_front" },
  }

  local shots = 0
  for _, s in ipairs(SCENES) do
    local ok = pcall(U.teleport, game, s.map, s.x, s.y, s.face)
    if ok then
      for _, rung in ipairs({ 5, 3 }) do
        Pipelines.setLevel("voxel", rung)
        Pipelines.setLevel("tiltshift", 0)
        settle()
        -- prove which models the RUNNING mod built for this map
        local st = Buildings.stats()
        local keys = {}
        for k, v in pairs(st) do
          keys[#keys + 1] = ("%s(v=%d)"):format(k, v.voxels)
        end
        table.sort(keys)
        print(("[table] %s r%d models: %s"):format(s.label, rung,
          #keys > 0 and table.concat(keys, " ") or "none"))
        local path = ("%s/%s_%s_r%d.png"):format(ROOT, TAG, s.label, rung)
        game.capturePath = path
        U.wait(6)
        local f = io.open(path, "rb")
        if f then f:close() shots = shots + 1
        else print("[table] capture missed: " .. path) end
      end
    else
      print("[table] teleport failed: " .. s.map)
    end
  end
  print(("[table] %d shots into %s"):format(shots, ROOT))
  love.event.quit()
end
