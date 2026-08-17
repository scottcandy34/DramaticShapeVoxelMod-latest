local V = ...

local Assets = require("src.render.Assets")
local Budget = V.require("util/BuildBudget")
local Objects = V.require("voxel/structures/Objects")
local OBJ_SHADE = Objects.OBJ_SHADE
local Standee = V.require("voxel/structures/Standee")
local SIDE_INSET = Standee.SIDE_INSET
local sideQuads = Standee.sideQuads

-- ---- flowers ----

local DIRS4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function keyOf(tx, ty)
  return (ty + 64) * 4096 + (tx + 64)
end

-- The animated flower tile stands up as a billboard ONE VOXEL deep, cut
-- to the drawing's darkest tones PLUS everything they enclose -- the
-- round-scenery hull's rule: flood the tile border through every
-- non-dark pixel, and what the flood cannot reach is the flower, its
-- pale petal insides included. The mesh is static and the flower is
-- not, so the geometry spans the UNION of that mask over the base art
-- and every animation frame, and TerrainAtlas rewrites the tile's slot
-- each step with only the CURRENT frame's mask opaque -- the rest keyed
-- to alpha, which the voxel shader discards. The standing silhouette
-- trims itself frame by frame in texture space; the sway animates
-- without a vertex moving, off the same engine clock as the flat path.
--
-- The ground beneath is synthesized from the commonest flat neighbour,
-- like the ground under a detected prop: the tile's own slot no longer
-- holds art anyone can draw flat.
local FLOWER_THICK = 1

local function flowerFrames(tileset, tileId)
  local out = {}
  local ok, declared = pcall(function()
    if tileset.animatedTiles then return tileset.animatedTiles end
    local TileRenderer = require("src.render.TileRenderer")
    return TileRenderer.defaultAnimatedTiles(tileset)
  end)
  if not ok then return out end
  for _, spec in ipairs(type(declared) == "table" and declared or {}) do
    if spec.kind == "frames" and spec.tile == tileId then
      for _, path in pairs(spec.images or {}) do
        local okF, frame = pcall(Assets.imageData, path)
        if okF and frame then out[#out + 1] = frame end
      end
    end
  end
  return out
end

local function flowerTemplate(map, data, tileId)
  local tileset = map.tileset
  local perRow = tileset.tilesPerRow or 16
  local atlasW = tileset.imageWidth or 128
  local atlasH = tileset.imageHeight or 48
  local ax0 = (tileId % perRow) * 8
  local ay0 = math.floor(tileId / perRow) * 8

  -- per image: dark tones, then the border flood that finds what they
  -- enclose. Each image closes over ITS OWN outline before the union --
  -- a pocket two frames only enclose together is not part of either.
  local dark = {}
  local function markMask(img, ox, oy)
    local d, reach, stack = {}, {}, {}
    for py = 0, 7 do
      for px = 0, 7 do
        local r, g, b, a = img:getPixel(ox + px, oy + py)
        if a > 0 and math.min(r, g, b) <= 0.5 then
          d[py * 8 + px] = true
        end
      end
    end
    for i = 0, 7 do
      for _, s in ipairs({ i, 56 + i, i * 8, i * 8 + 7 }) do
        if not d[s] and not reach[s] then
          reach[s] = true
          stack[#stack + 1] = s
        end
      end
    end
    while #stack > 0 do
      local p = table.remove(stack)
      local px, py = p % 8, math.floor(p / 8)
      for _, dir in ipairs(DIRS4) do
        local nx, ny = px + dir[1], py + dir[2]
        if nx >= 0 and nx < 8 and ny >= 0 and ny < 8 then
          local ni = ny * 8 + nx
          if not d[ni] and not reach[ni] then
            reach[ni] = true
            stack[#stack + 1] = ni
          end
        end
      end
    end
    for i = 0, 63 do
      if d[i] or not reach[i] then dark[i] = true end
    end
  end
  markMask(data, ax0, ay0)
  for _, frame in ipairs(flowerFrames(tileset, tileId)) do
    pcall(markMask, frame, 0, 0)
  end

  local function on(px, py)
    if px < 0 or px > 7 or py < 0 or py > 7 then return false end
    return dark[py * 8 + px] == true
  end

  local quads = {}
  local zB = 4 - FLOWER_THICK / 2      -- one slab at the tile's middle
  local zF = zB + FLOWER_THICK
  for py = 0, 7 do
    Budget.tick()
    local yTop, yBot = 8 - py, 7 - py
    local ix = 0
    while ix < 8 do
      if on(ix, py) then
        local ix2 = ix
        while ix2 + 1 < 8 and on(ix2 + 1, py) do ix2 = ix2 + 1 end
        local u0 = (ax0 + ix + 0.05) / atlasW
        local u1 = (ax0 + ix2 + 0.95) / atlasW
        local v0 = (ay0 + py + 0.05) / atlasH
        local v1 = (ay0 + py + 0.95) / atlasH
        quads[#quads + 1] = {           -- front
          { ix, yBot, zF }, { ix2 + 1, yBot, zF },
          { ix2 + 1, yTop, zF }, { ix, yTop, zF },
          uv = { { u0, v1 }, { u1, v1 }, { u1, v0 }, { u0, v0 } },
          shade = OBJ_SHADE.front,
        }
        quads[#quads + 1] = {           -- back
          { ix2 + 1, yBot, zB }, { ix, yBot, zB },
          { ix, yTop, zB }, { ix2 + 1, yTop, zB },
          uv = { { u1, v1 }, { u0, v1 }, { u0, v0 }, { u1, v0 } },
          shade = OBJ_SHADE.back,
        }
        -- ------- the shell, closed on all four remaining faces
        --
        -- A flower SWAYS: the geometry spans the union of every animation
        -- frame's mask and each frame is cut back out of it in texture
        -- space (see the header). So "is there a pixel next door" has two
        -- different answers -- one in the union this mesh was built from,
        -- and one in the frame actually on screen -- and only the second
        -- decides what is exposed.
        --
        -- Closing the union's own edges is therefore not enough, and was
        -- the bug the first cut of this shipped: the base frame looked
        -- solid and every other frame still had gaps, because a pixel that
        -- drops out of a frame takes the union's wall with it and leaves an
        -- interior boundary that never had one.
        --
        -- So every pixel gets a cap on all four of its remaining faces,
        -- whatever its neighbours do. A cap between two lit pixels sits
        -- inside the slab, enclosed by the front and back faces, and is
        -- never seen; the moment its neighbour is keyed out it IS the edge,
        -- already there and already wearing the right colour. Each samples
        -- its own pixel's texel, so it appears and vanishes with the pixel
        -- it belongs to rather than with the one it is closing off.
        --
        -- Inset a hair into its own pixel, because the voxel pass draws
        -- with culling off: the two caps that meet at a boundary would be
        -- coplanar and z-fight rather than politely take turns.
        for px = ix, ix2 do
          local tu = (ax0 + px + 0.5) / atlasW
          local tv = (ay0 + py + 0.5) / atlasH
          local xa, xb = px, px + 1
          local yT = yTop - SIDE_INSET
          local yB = yBot + SIDE_INSET
          quads[#quads + 1] = {           -- the pixel's own lid
            { xa, yT, zB }, { xb, yT, zB }, { xb, yT, zF }, { xa, yT, zF },
            uv = { { tu, tv }, { tu, tv }, { tu, tv }, { tu, tv } },
            shade = OBJ_SHADE.top,
          }
          quads[#quads + 1] = {           -- and its floor
            { xa, yB, zF }, { xb, yB, zF }, { xb, yB, zB }, { xa, yB, zB },
            uv = { { tu, tv }, { tu, tv }, { tu, tv }, { tu, tv } },
            shade = OBJ_SHADE.bottom,
          }
        end
        sideQuads(quads, ix, ix2, yBot, yTop, zB, zF,
                  ax0, ay0, atlasW, atlasH, py, on, true)
        ix = ix2 + 1
      else
        ix = ix + 1
      end
    end
  end
  return quads
end

local function buildFlowers(S, map, tw, th, x0, x1, y0, y1, data)
  local templates = {}
  -- flowerQuads, not objectQuads: flowers sit on WALKABLE cells, so
  -- their mesh draws after the characters with the character pull
  -- (ChunkMesher's flower mesh) -- terrain-baked they lose the depth
  -- fight against the pulled card whenever the player stands among them
  local quads = S.flowerQuads
  for ty = y0, y1 do
    for tx = x0, x1 do
      Budget.tick()
      local k = keyOf(tx, ty)
      local s = S.shapeAt[k]
      if s and s.art == "flower" then
        -- the tile's atlas slot carries only the standing cutout now, so
        -- EVERY flower position -- ring included -- paints synthesized
        -- ground instead of its own art: the commonest flat neighbour
        -- that is not itself a flower, else the map's commonest ground
        -- (forMap's end-of-build vote resolves the `false`)
        S.skip[k] = true
        local votes, best, bestN = {}, nil, 0
        for _, d in ipairs(DIRS4) do
          local nk = keyOf(tx + d[1], ty + d[2])
          local ns = S.shapeAt[nk]
          if ns and ns.flat and ns.class ~= "void"
             and ns.class ~= "flower" then
            local t = S.tileAt[nk]
            votes[t] = (votes[t] or 0) + 1
            if votes[t] > bestN then best, bestN = t, votes[t] end
          end
        end
        S.ground[k] = best or false

        -- standee BODY only, like grass: standing scenery past a map's
        -- edge would poke into the map next door
        if tx >= 0 and ty >= 0 and tx < tw and ty < th then
          local tileId = S.tileAt[k]
          local tpl = templates[tileId]
          if not tpl then
            tpl = flowerTemplate(map, data, tileId)
            templates[tileId] = tpl
          end
          local wx, wz = tx * 8, ty * 8
          for _, q in ipairs(tpl) do
            quads[#quads + 1] = {
              { q[1][1] + wx, q[1][2], q[1][3] + wz },
              { q[2][1] + wx, q[2][2], q[2][3] + wz },
              { q[3][1] + wx, q[3][2], q[3][3] + wz },
              { q[4][1] + wx, q[4][2], q[4][3] + wz },
              uv = q.uv, shade = q.shade,
            }
          end
        end
      end
    end
  end
end

return buildFlowers