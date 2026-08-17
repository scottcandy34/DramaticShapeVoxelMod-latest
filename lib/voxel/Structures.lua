-- Voxel world mode: detect the map's structures and pick a 3D model for
-- each -- the 3dSen idea applied to a tile map. 3dSen turns flat NES
-- scenes into 3D by classifying every graphic into a geometry archetype
-- (floor, wall, box, voxelized sprite) and building real geometry that
-- keeps the original art as its texture; this module does the same with
-- the map's tile layer as the scene description:
--
--   1. Flood-fill every connected region of solid (upright, unauthored)
--      tiles -- a house with its mailbox, the potted plant, a fence row,
--      a stretch of border forest.
--
--   2. Decide which pixels of the region's art are BACKGROUND. Tileset
--      art carries no alpha and white is a paint color (window frames,
--      wall stripes), so whiteness alone says nothing. The map does: the
--      background is the white that CONNECTS TO WALKABLE GROUND in the
--      assembled scene. Seeding a flood from the surrounding ground
--      eats the air around a fence post or a plant's leaves but cannot
--      reach an interior wall's white stripes sealed behind its dark
--      trim -- exactly the distinction a human reads.
--
--   3. Tiles whose art turned out mostly background are SPRITE-LIKE;
--      their connected clusters become per-pixel voxel OBJECTS at the
--      art's real drawn height (a 2-row plant is a 16px silhouette, a
--      fence a row of true posts with air between), thin voxel depth,
--      standing on synthesized ground. This splits mixed regions: the
--      mailbox voxelizes even where it touches the house.
--
--   4. Everything else becomes a VOLUME: each column rises to the height
--      the structure is actually DRAWN. A column's run gives its extent,
--      repetition caps it -- the border forest repeats a 2-row canopy
--      for forty rows and must be rows of 16px trees, not a monolith --
--      and columns answer to their region: the column above a doorway
--      repeats internally but adopts its 48px house. The south face
--      folds the artwork up (ChunkMesher's band rule).
--
-- data/voxel_heights.lua is the PROFILE over this: a tile authored there
-- (ledges, or a mod pinning a shape) bypasses detection entirely, the way
-- a 3dSen game profile pins a pattern to a geometry type.
--
-- Everything here is derived per map and cached; pixel access (object
-- voxelization, void detection) degrades gracefully headless -- regions
-- simply stay volumes and the geometry tests keep passing.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Assets = require("src.render.Assets")
local Map = require("src.world.Map")
local Buildings = V.require("voxel/structures/Buildings")
local TileShape = V.require("voxel/TileShape")
local Budget = V.require("util/BuildBudget")

local Structures = {}

-- must match ChunkMesher's ring (3 border blocks, in tiles)
local RING = 12

-- how far past the map body cells still get the hull. A route's ring is
-- nearly as big as its body; modelling all of it costs hundreds of
-- thousands of quads of border trees nobody walks near. Beyond this,
-- pinned cells simply are not claimed and fall through to the mesher's
-- plain box -- cheap distant scenery. (Declared up here rather than
-- beside buildCylinders because forMap's grid resolve reads it too.)
local ROUND_RING = 4

local cache = {}

-- ---------------------------------------------------------------- pixels --

local atlasData = {}

local function pixels(tileset)
  local path = tileset.image
  if atlasData[path] == nil then
    local ok, data = pcall(Assets.imageData, path)
    atlasData[path] = (ok and data and data.getPixel) and data or false
  end
  return atlasData[path] or nil
end

-- tiles whose art is entirely black or transparent (interior darkness):
-- these never extrude, whatever class they resolved to
local function voidTiles(tileset)
  local data = pixels(tileset)
  if not data then return nil end
  local perRow = tileset.tilesPerRow or 16
  local iw, ih = data:getDimensions()
  local set = {}
  for t = 0, (iw / 8) * (ih / 8) - 1 do
    local ox = (t % perRow) * 8
    local oy = math.floor(t / perRow) * 8
    local void = true
    for py = 0, 7 do
      for px = 0, 7 do
        local r, g, b, a = data:getPixel(ox + px, oy + py)
        if a > 0 and math.max(r, g, b) > 0.17 then
          void = false
          break
        end
      end
      if not void then break end
    end
    if void then set[t] = true end
  end
  return set
end

-- ----------------------------------------------------------------- build --

local DIRS4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function keyOf(tx, ty)
  return (ty + 64) * 4096 + (tx + 64)
end

function Structures.forMap(map)
  local S = cache[map.id]
  if S then return S end

  local tileset = map.tileset
  local shapes = TileShape.forMap(map)
  local void = voidTiles(tileset)
  local perRow = tileset.tilesPerRow or 16

  local def = map.def
  local tw, th = def.width * 4, def.height * 4
  local x0, x1 = -RING, tw + RING - 1
  local y0, y1 = -RING, th + RING - 1

  -- resolve the whole grid once: shape + tile per key. Ring positions use
  -- the same border override the 2D renderer draws with
  -- (TileRenderer.borderBlockFor: outdoor maps ring with the solid tree
  -- wall, NOT their own borderBlock) -- a route's borderBlock is the GRASS
  -- block, and meshing that grew a 12-tile apron of tall grass past every
  -- route edge, which leaked into the neighbouring town's plaza.
  -- BLACK void fill is not a block at all: borderBlockFor answers `false`,
  -- and there is simply nothing out there to build. tileLookup then returns
  -- nil past the body and the ring keys are never written, which the whole
  -- file already copes with -- every neighbour query reaches one step
  -- outside the analysed range and reads nil for its trouble, so an absent
  -- cell is the shape "nothing" has always had here. (It used to add 1 to
  -- that `false`, which threw, failed the mesh build for every map on the
  -- route, and dropped the mode to the flat 2D path entirely.)
  local TileRenderer = require("src.render.TileRenderer")
  local borderId = TileRenderer.borderBlockFor(map)
  local borderBlk = borderId and tileset.blocks[borderId + 1] or nil
  -- TREES fill stops at ROUND_RING instead of running the full RING.
  -- Only that far out does a tree cell get carved into a hull; past it
  -- the cells fall through to the mesher's plain box, and a slab of
  -- flat-topped boxes beside the modelled wall reads as a painted-on
  -- plateau -- the wall looking like it was cut off with scissors. So
  -- the far ring is simply not built: beyond ROUND_RING tileLookup
  -- answers nil, which is the same "nothing out there" BLACK already
  -- produces and every pass below already copes with. The cut lands on
  -- the carve boundary exactly -- the 2x2-cell canopy scan starts at
  -- floor(-RING/2) and RING, ROUND_RING and the body are all multiples
  -- of 4 tiles, so no group is left half-resolved at the edge.
  --
  -- WATER and the other tilesets' own borders keep the full ring: a flat
  -- sheet of water is what water looks like from above anyway, and an
  -- interior's border is black already.
  local hullRingOnly = borderBlk and def.tileset == "OVERWORLD"
                       and (TileRenderer.voidFill or "trees") == "trees"
  local tw2, th2 = tw, th
  local function tileLookup(tx, ty)
    if tx >= 0 and ty >= 0 and tx < tw2 and ty < th2 then
      return map:tileAt(tx, ty)
    end
    if not borderBlk then return nil end
    if hullRingOnly and (tx < -ROUND_RING or ty < -ROUND_RING
                         or tx >= tw2 + ROUND_RING
                         or ty >= th2 + ROUND_RING) then
      return nil
    end
    return borderBlk[(ty % 4) * 4 + (tx % 4) + 1] or 0
  end
  local shapeAt, tileAt = {}, {}
  for ty = y0, y1 do
    for tx = x0, x1 do
      Budget.tick()
      local tile = tileLookup(tx, ty)
      if tile then
        local k = keyOf(tx, ty)
        local s = TileShape.at(map, shapes, tile, tx, ty)
        if s and void and void[tile] and not s.authored then
          s = shapes.classes.void
        end
        shapeAt[k], tileAt[k] = s, tile
      end
    end
  end

  -- ---- buildings: whole sprites voxelized band by band ----
  --
  -- Before anything else looks at this grid. A profiled building is a
  -- drawing whose bands depict DIFFERENT 3D surfaces (roof from above,
  -- facade face-on, ends sloped), and the passes below -- the door fold,
  -- the region flood, the volume builder -- all assume one drawing is one
  -- upright thing. Modelling the building first and claiming its tiles
  -- keeps every one of them off it.
  --
  -- (grassQuads live apart from objectQuads: grass renders as its own mesh
  -- AFTER the characters -- see VoxelScene -- so the southern tuft row
  -- still overdraws a walker's feet even though characters stamp over
  -- terrain.)
  S = { shapeAt = shapeAt, tileAt = tileAt, outdoor = Map.isOutdoor(def),
        hideBareRing = hullRingOnly or nil,
        runs = {}, skip = {}, ground = {}, doorFold = {}, objectQuads = {},
        grassQuads = {}, flowerQuads = {}, roundStamps = {}, figures = {},
        -- tile key -> the row a collapsed bookcase rank's box actually
        -- stands on, so a standee supported by one lands on it rather than
        -- where the drawing put it (see buildBookcases)
        bookcaseBox = {} }
  Buildings.build(S, map, pixels(tileset), perRow)

  -- Fold doors into their buildings. A door cell is WALKABLE (the player
  -- steps onto it to warp), so it resolves to ground and punches a hole in
  -- the facade: the door lies flat, the rows above it recess, and -- worse
  -- -- the hole lets the background flood into the building's interior
  -- whites, shredding it into misdetected sprite clusters. Visually the
  -- door is part of the facade, so mark the door cell's tiles structural:
  -- the fold then shows the door art standing at ground level in the
  -- building's front face. Door graphics only (the tileset's doorTiles);
  -- interior stair/mat warps stay flat.
  --
  -- A PROFILE PIN WINS over the fold. The fold is detection, and rule 1
  -- of the resolution order is that an authored tile bypasses detection
  -- -- but this used to overwrite shapeAt unconditionally, so a pin on
  -- any tile the tileset also lists in doorTiles was dead on arrival.
  -- Celadon Mansion is the case that found it: all four of its
  -- staircases are door tiles, so `stair_e` / `stair_down_w` pins there
  -- silently did nothing and the flights stayed painted on the floor.
  for cy = math.floor(y0 / 2), math.floor(y1 / 2) do
    for cx = math.floor(x0 / 2), math.floor(x1 / 2) do
      if map.doorTiles[map:cellTile(cx, cy)] then
        local northK = keyOf(cx * 2, cy * 2 - 1)
        local ns = shapeAt[northK]
        if ns and ns.art == "upright" then
          for dy = 0, 1 do
            for dx = 0, 1 do
              local dk = keyOf(cx * 2 + dx, cy * 2 + dy)
              local ds = shapeAt[dk]
              if not (ds and ds.authored) then
                shapeAt[dk] = shapes.classes.wall
                -- remembered for buildVolume: a folded doorway column
                -- answers to its REGION for height and top, not to its
                -- own drawn extent (see the door adoption there)
                S.doorFold[dk] = true
              end
            end
          end
        end
      end
    end
  end

  -- a structure cell: solid art the detector may model (authored tiles are
  -- profile-pinned and keep their authored shape)
  local function structural(k)
    local s = shapeAt[k]
    return s and s.art == "upright" and not s.authored
  end

  -- ---- cylinders: profile-pinned round graphics, one per 16x16 cell ----
  -- the flat ground tiles this map actually places, for the hull's
  -- ground matching: the ball's own drawn background picks its floor
  local groundTiles = {}
  do
    local seenG = {}
    for k, s in pairs(shapeAt) do
      if s and s.flat and s.class == "ground" then
        local t = tileAt[k]
        if t and not seenG[t] then
          seenG[t] = true
          groundTiles[#groundTiles + 1] = t
        end
      end
    end
  end
  Structures.buildCylinders(S, map, x0, x1, y0, y1, pixels(tileset), groundTiles)

  -- ---- stairs: profile-pinned cells that render as real steps ----
  Structures.buildStairs(S, map, x0, x1, y0, y1, pixels(tileset))

  -- ---- bookcases: pinned shelves collapsed to one cell of depth ----
  -- The atlas comes along so the shelf front can carry its own measured
  -- relief: the panes it seals behind its black frames sink a voxel.
  Structures.buildBookcases(S, map, x0, x1, y0, y1, pixels(tileset), perRow)

  -- ---- figures: a person drawn INTO furniture, lifted off it ----
  -- Before the region flood and the volume pass, so everything after this
  -- reads the tiles the profile says are there once the figure is gone.
  -- (Its own tiles are authored furniture or walkable floor either way, so
  -- no pass below would have claimed them -- but the repaint is what those
  -- passes should see, and this needs no pixel access to do it.)
  Structures.buildFigures(S, map, x0, x1, y0, y1)

  -- ---- mounted: a thing drawn INTO a wall band, stood proud of it ----
  -- Here for the same reason and with the same guarantee as the figures
  -- above: the repaint hands every pass below the plain panel the profile
  -- says is behind the object, so the wall band it was painted into keeps
  -- resolving as the wall it is -- without a second copy of the drawing
  -- flat on its face.
  Structures.buildMounted(S, map, x0, x1, y0, y1)

  -- ---- flood-fill regions of structural tiles ----
  local seen = {}
  local regions = {}
  for ty = y0, y1 do
    for tx = x0, x1 do
      local k = keyOf(tx, ty)
      if structural(k) and not seen[k] then
        local region = { tiles = {}, minX = tx, maxX = tx,
                         minY = ty, maxY = ty }
        local queue = { { tx, ty } }
        seen[k] = true
        while #queue > 0 do
          Budget.tick()
          local c = table.remove(queue)
          local cx, cy = c[1], c[2]
          region.tiles[#region.tiles + 1] = c
          region.minX = math.min(region.minX, cx)
          region.maxX = math.max(region.maxX, cx)
          region.minY = math.min(region.minY, cy)
          region.maxY = math.max(region.maxY, cy)
          for _, d in ipairs(DIRS4) do
            local nx, ny = cx + d[1], cy + d[2]
            if nx >= x0 and nx <= x1 and ny >= y0 and ny <= y1 then
              local nk = keyOf(nx, ny)
              if structural(nk) and not seen[nk] then
                seen[nk] = true
                queue[#queue + 1] = { nx, ny }
              end
            end
          end
        end
        regions[#regions + 1] = region
      end
    end
  end

  -- ---- model each region: carve out per-pixel objects, volume the rest --
  local data = pixels(tileset)
  for _, region in ipairs(regions) do
    local leftover = region.tiles
    if data then
      leftover = Structures.extractObjects(S, map, region, data, perRow)
    end
    if #leftover > 0 then
      Structures.buildVolume(S, map, leftover)
    end
  end

  -- ---- profile-pinned billboards (signs): forced per-pixel slabs ----
  if data then
    local seenB = {}
    for ty = y0, y1 do
      for tx = x0, x1 do
        local k = keyOf(tx, ty)
        local s = shapeAt[k]
        if s and s.art == "billboard" and not seenB[k] then
          local reg = { tiles = {}, minX = tx, maxX = tx,
                        minY = ty, maxY = ty }
          local queue = { { tx, ty } }
          seenB[k] = true
          while #queue > 0 do
            local c = table.remove(queue)
            reg.tiles[#reg.tiles + 1] = c
            reg.minX = math.min(reg.minX, c[1])
            reg.maxX = math.max(reg.maxX, c[1])
            reg.minY = math.min(reg.minY, c[2])
            reg.maxY = math.max(reg.maxY, c[2])
            for _, d in ipairs(DIRS4) do
              local nk = keyOf(c[1] + d[1], c[2] + d[2])
              local ns = shapeAt[nk]
              -- same CLASS, not just billboard art: `billboard` and
              -- `prop` are two pools precisely so touching drawings (a TV
              -- behind its console) become two standing objects instead
              -- of one stacked cutout
              if ns and ns.art == "billboard" and ns.class == s.class
                 and not seenB[nk] then
                seenB[nk] = true
                queue[#queue + 1] = { c[1] + d[1], c[2] + d[2] }
              end
            end
          end
          Structures.extractObjects(S, map, reg, data, perRow, true)
        end
      end
    end

    -- ---- profile-pinned fence posts: per-CELL standee slabs ----
    -- A fence line repeats one drawing for a dozen cells, and its art
    -- touches across cell seams. Pooled like a billboard the whole line
    -- would stand as ONE drawing-tall tower at one depth (the detector's
    -- vertical-repetition guard exists precisely to refuse that, which
    -- is why undetected fence columns fell to the volume path as boxes).
    -- Each CELL extracts alone instead: its posts stand in their own row
    -- band and the fence marches north cell by cell.
    local postCells = {}
    for ty = y0, y1 do
      for tx = x0, x1 do
        local s = shapeAt[keyOf(tx, ty)]
        if s and s.art == "post" then
          local ck = keyOf(math.floor(tx / 2), math.floor(ty / 2))
          postCells[ck] = postCells[ck] or {}
          local list = postCells[ck]
          list[#list + 1] = { tx, ty }
        end
      end
    end
    for _, tiles in pairs(postCells) do
      local reg = { tiles = tiles,
                    minX = tiles[1][1], maxX = tiles[1][1],
                    minY = tiles[1][2], maxY = tiles[1][2] }
      for _, c in ipairs(tiles) do
        reg.minX = math.min(reg.minX, c[1])
        reg.maxX = math.max(reg.maxX, c[1])
        reg.minY = math.min(reg.minY, c[2])
        reg.maxY = math.max(reg.maxY, c[2])
      end
      Structures.extractObjects(S, map, reg, data, perRow, "opaque")
    end

    -- ---- profile-pinned relief props: top-down drawings that extrude ----
    local seenR = {}
    for ty = y0, y1 do
      for tx = x0, x1 do
        local k = keyOf(tx, ty)
        local s = shapeAt[k]
        if s and s.art == "relief" and not seenR[k] then
          local reg = { tiles = {}, minX = tx, maxX = tx,
                        minY = ty, maxY = ty }
          local queue = { { tx, ty } }
          seenR[k] = true
          while #queue > 0 do
            local c = table.remove(queue)
            reg.tiles[#reg.tiles + 1] = c
            reg.minX = math.min(reg.minX, c[1])
            reg.maxX = math.max(reg.maxX, c[1])
            reg.minY = math.min(reg.minY, c[2])
            reg.maxY = math.max(reg.maxY, c[2])
            for _, d in ipairs(DIRS4) do
              local nk = keyOf(c[1] + d[1], c[2] + d[2])
              local ns = shapeAt[nk]
              if ns and ns.art == "relief" and ns.class == s.class
                 and not seenR[nk] then
                seenR[nk] = true
                queue[#queue + 1] = { c[1] + d[1], c[2] + d[2] }
              end
            end
          end
          for _, c in ipairs(reg.tiles) do
            local ck = keyOf(c[1], c[2])
            S.skip[ck] = true
            S.ground[ck] = false
          end
          Structures.buildRelief(S, map, reg, data, perRow, s.h or 5)
        end
      end
    end

    -- ---- tall grass: two standing tuft rows per tile. BODY only: the 2D
    -- renderer never draws a neighbour's ring, and standing scenery past a
    -- map's edge would poke into the map next door ----
    Structures.buildGrass(S, map, 0, tw - 1, 0, th - 1, data)

    -- ---- flowers: the animated meadow tile stands as a 1px cutout ----
    Structures.buildFlowers(S, map, tw, th, x0, x1, y0, y1, data)
  end

  -- ---- authored ground under pinned props ----
  -- The profile can name the tile a pinned prop stands on (a tileset
  -- entry's prop_ground: prop tile id -> ground tile id), overriding
  -- the neighbour vote. The cuttable bush stands on the plain grass
  -- Cut itself leaves behind, not on whatever path its neighbours
  -- happen to vote in.
  do
    local okP, prof = pcall(V.data, "voxel_heights")
    local entry = okP and type(prof) == "table" and prof.tilesets
                  and prof.tilesets[tileset.id]
    local pg = entry and entry.prop_ground
    if type(pg) == "table" then
      for k, skipped in pairs(S.skip) do
        if skipped then
          local g = pg[S.tileAt[k]]
          if g then S.ground[k] = g end
        end
      end
    end
  end

  -- unresolved claimed ground (a hull with no art match, headless
  -- cylinders): no flat neighbour to vote with, so fall back to the
  -- map's commonest ground tile
  local votes, best, bestN = {}, nil, 0
  for k, s in pairs(shapeAt) do
    if s and s.flat and s.class == "ground" then
      local t = tileAt[k]
      votes[t] = (votes[t] or 0) + 1
      if votes[t] > bestN then best, bestN = t, votes[t] end
    end
  end
  for k, g in pairs(S.ground) do
    if g == false then S.ground[k] = best end
  end

  cache[map.id] = S
  return S
end

local Objects = V.require("voxel/structures/Objects")
Structures.extractObjects = Objects.extractObjects
Structures.buildObject = Objects.buildObject
Structures.buildCylinders = V.require("voxel/structures/Cylinders")
Structures.buildVolume = V.require("voxel/structures/Volumes")
Structures.buildStairs = V.require("voxel/structures/Stairs")
Structures.buildBookcases = V.require("voxel/structures/Bookcases")
Structures.buildFigures = V.require("voxel/structures/Figures")
Structures.buildMounted = V.require("voxel/structures/Mounted")
Structures.buildRelief = V.require("voxel/structures/ReliefProps")
Structures.buildGrass = V.require("voxel/structures/TallGrass")
Structures.buildFlowers = V.require("voxel/structures/Flowers")

-- Drop one map's analysis (Cut changed the block layer) or everything.
-- Hull templates key on art content (tileset + tiles), which a block edit
-- cannot change, so only the full drop clears them (atlas reload).
function Structures.invalidate(mapId)
  if mapId then
    cache[mapId] = nil
  else
    cache = {}
    atlasData = {}
    roundCache = {}
    Buildings.invalidate()
  end
end

Assets.register(function() Structures.invalidate() end)

return Structures
