-- Scratch driver: the Game Freak office computer desks (buildings
-- template mansion_computer_desk).  CELADON_MANSION_2F cell (0,5) and
-- CELADON_MANSION_3F cells (0,3)/(3,3)/(0,6).  Shot at the voxel rung
-- (5), the mid rung (4) and the flat rung (3) for orientation.
--
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/mansion_desk_shots.lua \
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
    print("[deskshot] DRAMATIC_SHAPE is not loaded")
    return
  end
  local V = handle.lib
  do -- prove the RUNNING mod's profile carries the new template
    local ok, s = pcall(V.data, "voxel_heights")
    local found = "NO"
    if ok and type(s) == "table" and s.buildings and s.buildings.MANSION then
      for _, t in ipairs(s.buildings.MANSION) do
        if t.id == "mansion_computer_desk" then
          found = ("YES fascia=%d-%d base=%d-%d parts=%d")
            :format(t.desk.fascia[1], t.desk.fascia[2],
                    t.desk.base[1], t.desk.base[2], #t.parts)
        end
      end
    end
    print("[deskshot] running-mod mansion_computer_desk: " .. found)
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
    -- 2F: the lone desk at (0,5):(1,6).  Stand just south of it, facing
    -- north, so the camera looks along the desk's front face.
    { map = "CELADON_MANSION_2F", x = 1, y = 7, face = "up", label = "desk2f" },
    -- and from the east, to see the drawer pedestal and the chair in
    -- profile against the checker floor
    { map = "CELADON_MANSION_2F", x = 2, y = 6, face = "left", label = "desk2f_side" },
    -- 3F: the pair at (0,3) and (3,3), both in frame from between them
    { map = "CELADON_MANSION_3F", x = 2, y = 5, face = "up", label = "desk3f_pair" },
    -- 3F: the south desk at (0,6), close in
    { map = "CELADON_MANSION_3F", x = 1, y = 8, face = "up", label = "desk3f" },
  }

  local shots = 0
  for _, s in ipairs(SCENES) do
    local ok = pcall(U.teleport, game, s.map, s.x, s.y, s.face)
    if ok then
      for _, rung in ipairs({ 5, 4, 3 }) do
        Pipelines.setLevel("voxel", rung)
        Pipelines.setLevel("tiltshift", 0)
        settle()
        local path = ("%s/%s_%s_r%d.png"):format(ROOT, TAG, s.label, rung)
        game.capturePath = path
        U.wait(6)
        local f = io.open(path, "rb")
        if f then f:close() shots = shots + 1
        else print("[deskshot] capture missed: " .. path) end
      end
    else
      print("[deskshot] teleport failed: " .. s.map)
    end
  end
  print(("[deskshot] %d shots into %s (tag %s)"):format(shots, ROOT, TAG))
  love.event.quit()
end
