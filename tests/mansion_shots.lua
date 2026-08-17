-- Scratch driver: the CELADON_MANSION_1F square table (buildings
-- template mansion_square_table, cells (0,6):(1,7)). Shot at the voxel
-- rung (5) and the flat rung (3) for orientation, front/back/side.
--
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/mansion_shots.lua \
--   SHOT_DIR=mods/DramaticShapeVoxelMod/.claude/voxelizations \
--   "/c/Program Files/LOVE/lovec.exe" .
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local Pipelines = require("src.render.Pipelines")

  local ROOT = (os.getenv("SHOT_DIR")
    or "mods/DramaticShapeVoxelMod/.claude/voxelizations")

  local handle = game.mods.exports["DRAMATIC_SHAPE"]
  if not (handle and handle.lib) then
    print("[mansion] DRAMATIC_SHAPE is not loaded")
    return
  end
  local V = handle.lib
  do -- prove the RUNNING mod's profile carries the new template
    local ok, s = pcall(V.data, "voxel_heights")
    local found = false
    if ok and type(s) == "table" and s.buildings and s.buildings.MANSION then
      for _, t in ipairs(s.buildings.MANSION) do
        if t.id == "mansion_square_table" then found = true end
      end
    end
    print("[mansion] running-mod mansion_square_table: " .. tostring(found))
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
    -- the rung-5 camera looks north from ~4 cells south of the player, so
    -- the room's 16-voxel south wall hides the 6-voxel table at the low
    -- rung; rungs 4 and 3 pitch over it.  Stand just south of the table.
    { map = "CELADON_MANSION_1F", x = 1, y = 8, face = "up", label = "sqtable" },
    { map = "CELADON_MANSION_1F", x = 2, y = 6, face = "left", label = "sqtable_beside" },
  }

  local shots = 0
  for _, s in ipairs(SCENES) do
    local ok = pcall(U.teleport, game, s.map, s.x, s.y, s.face)
    if ok then
      for _, rung in ipairs({ 5, 4, 3 }) do
        Pipelines.setLevel("voxel", rung)
        Pipelines.setLevel("tiltshift", 0)
        settle()
        local path = ("%s/%s_r%d.png"):format(ROOT, s.label, rung)
        game.capturePath = path
        U.wait(6)
        local f = io.open(path, "rb")
        if f then f:close() shots = shots + 1
        else print("[mansion] capture missed: " .. path) end
      end
    else
      print("[mansion] teleport failed: " .. s.map)
    end
  end
  print(("[mansion] %d shots into %s"):format(shots, ROOT))
  love.event.quit()
end
