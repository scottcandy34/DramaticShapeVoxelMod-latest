-- Scratch driver: one shot of each fixture the wall-top / statue pass
-- touched, so the change can be looked at rather than reasoned about.
--
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/voxel_fix_shots.lua \
--   SHOT_DIR=mods/DramaticShapeVoxelMod/.claude/voxel_fix AB_TAG=. lovec.exe .
--
-- SHOT_DIR is relative to the PROJECT ROOT, which is where lovec runs from --
-- the mod's own .claude/ is where these belong, so it has to be spelt out.
--
-- Every scene stands the player on the nearest WALKABLE cell to the vantage
-- named below (teleporting into a wall puts the close cameras inside the
-- geometry), faces the fixture, and shoots at voxel rung 3 -- the higher
-- top-down camera, which is the one that shows what a wall wears on TOP.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local Pipelines = require("src.render.Pipelines")

  local ROOT = (os.getenv("SHOT_DIR")
                or "mods/DramaticShapeVoxelMod/.claude/voxel_fix")
    .. "/" .. (os.getenv("AB_TAG") or ".")

  local handle = game.mods.exports["DRAMATIC_SHAPE"]
  if not (handle and handle.lib) then
    print("[voxfix] DRAMATIC_SHAPE mod not loaded")
    return
  end
  local V = handle.lib
  local DayNight = V.require("effects/DayNight")
  local ChunkMesher = V.require("voxel/ChunkMesher")
  local Voxel = V.require("voxel/VoxelState")
  local TileShape = V.require("voxel/TileShape")

  -- prove the game is reading THIS tree, not a stale installed copy
  local ht = TileShape.wallTop and TileShape.wallTop("HOUSE")
  print(("[voxfix] wallTop present=%s HOUSE(45)=%s")
        :format(tostring(TileShape.wallTop ~= nil),
                tostring(ht and ht(45))))

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

  -- the nearest walkable cell to the vantage, searched in rings -- a
  -- vantage picked off a map dump is often the fixture itself
  local function place(x, y, face)
    local m = game.overworld.map
    for r = 0, 8 do
      for dy = -r, r do
        for dx = -r, r do
          if math.max(math.abs(dx), math.abs(dy)) == r then
            local px, py = x + dx, y + dy
            if m:inBounds(px, py) and m:isWalkableCell(px, py) then
              game.overworld.player.cellX = px
              game.overworld.player.cellY = py
              game.overworld.player.facing = face
              return px, py
            end
          end
        end
      end
    end
    return x, y
  end

  local SCENES = {
    { map = "BLUES_HOUSE",             x = 4,  y = 3,  face = "up",
      label = "house_wall_top" },
    { map = "VIRIDIAN_POKECENTER",     x = 4,  y = 3,  face = "up",
      label = "pokecenter_wall_top" },
    { map = "ROCKET_HIDEOUT_ELEVATOR", x = 2,  y = 3,  face = "up",
      label = "rocket_lift_wall_top" },
    { map = "REDS_HOUSE_2F",           x = 6,  y = 3,  face = "up",
      label = "reds_2f_wall_top" },
    { map = "REDS_HOUSE_1F",           x = 5,  y = 3,  face = "up",
      label = "reds_1f_wall_top" },
    { map = "LANCES_ROOM",             x = 6,  y = 15, face = "up",
      label = "lances_room_statues" },
    { map = "INDIGO_PLATEAU",          x = 2,  y = 5,  face = "up",
      label = "indigo_plateau_statue" },
    -- the west-edge statue itself, close enough to count the birds on it
    { map = "INDIGO_PLATEAU",          x = 1,  y = 4,  face = "up",
      label = "indigo_plateau_statue_close", rung = 5 },
    { map = "INDIGO_PLATEAU",          x = 2,  y = 4,  face = "up",
      label = "indigo_plateau_statue_near" },
  }

  local only = os.getenv("VF_ONLY")
  local shots = 0
  for _, s in ipairs(SCENES) do
   if not (only and only ~= "" and not only:find(s.label, 1, true)) then
    local ok, err = pcall(function()
      U.teleport(game, s.map, s.x, s.y, s.face)
      local px, py = place(s.x, s.y, s.face)
      Pipelines.setLevel("voxel", s.rung or 3)
      Pipelines.setLevel("tiltshift", 0)
      settle()
      local path = ("%s/%s.png"):format(ROOT, s.label)
      game.capturePath = path
      U.wait(8)
      local f = io.open(path, "rb")
      if f then
        f:close()
        shots = shots + 1
        print(("[voxfix] %s -> %s (stood %d,%d)"):format(s.map, path, px, py))
      else
        print("[voxfix] capture missed: " .. path)
      end
    end)
    if not ok then print("[voxfix] " .. s.map .. " failed: " .. tostring(err)) end
   end
  end
  print(("[voxfix] %d/%d shots into %s"):format(shots, #SCENES, ROOT))
  love.event.quit()
end
