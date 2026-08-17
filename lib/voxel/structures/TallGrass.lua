local V = ...

local Budget = V.require("util/BuildBudget")
local Objects = V.require("voxel/structures/Objects")
local OBJ_SHADE = Objects.OBJ_SHADE
local Standee = V.require("voxel/structures/Standee")
local sideQuads = Standee.sideQuads

-- ---- tall grass ----

local function keyOf(tx, ty)
  return (ty + 64) * 4096 + (tx + 64)
end

-- A tall-grass CELL is four tufts: 2x2 tiles, and each 8x8 tile is one
-- whole clump of grass. Each tile stands as its own thin per-pixel slab
-- at ITS OWN depth -- the cell's north tile row in the north half of the
-- cell, the south row in the south half -- over the flat grass base the
-- tile already renders. So the player walks BETWEEN the two rows, and
-- the southern row occludes their feet the way the 2D grass overdraw
-- did. Transparency respected: only the tuft strokes stand. Runs of
-- adjacent pixels merge into single quads, and one template per grass
-- tile id is stamped across the map (grass comes in fields).
--
-- One tile is ONE standing piece, full height. The first cut split each
-- tile again into its top and bottom four art rows and stood those at
-- two different depths, which cut every blade that runs down the tile
-- clean in half -- the two halves ended up 4px tall and 4px apart in
-- depth, so a clump read as two stubs rather than one tuft.
local GRASS_THICK = 2

local function grassTemplate(map, data, tileId)
  local perRow = map.tileset.tilesPerRow or 16
  local atlasW = map.tileset.imageWidth or 128
  local atlasH = map.tileset.imageHeight or 48
  local ax0 = (tileId % perRow) * 8
  local ay0 = math.floor(tileId / perRow) * 8

  local function opaque(px, py)
    if px < 0 or px > 7 or py < 0 or py > 7 then return false end
    local r, g, b, a = data:getPixel(ax0 + px, ay0 + py)
    return a > 0 and math.min(r, g, b) <= 0.83
  end

  local quads = {}
  -- the slab stands across the middle of its own tile, so the two tile
  -- rows of a cell are half a cell apart in depth
  local zMid = 4
  local zB, zF = zMid - GRASS_THICK / 2, zMid + GRASS_THICK / 2
  for iy = 0, 7 do
    local yTop = 8 - iy
    local yBot = yTop - 1
    local ix = 0
    while ix < 8 do
      if opaque(ix, iy) then
        local ix2 = ix
        while ix2 + 1 < 8 and opaque(ix2 + 1, iy) do
          ix2 = ix2 + 1
        end
        local u0 = (ax0 + ix + 0.05) / atlasW
        local u1 = (ax0 + ix2 + 0.95) / atlasW
        local v0 = (ay0 + iy + 0.05) / atlasH
        local v1 = (ay0 + iy + 0.95) / atlasH
        quads[#quads + 1] = {           -- front
          { ix, yBot, zF }, { ix2 + 1, yBot, zF },
          { ix2 + 1, yTop, zF }, { ix, yTop, zF },
          uv = { { u0, v1 }, { u1, v1 }, { u1, v0 }, { u0, v0 } },
          shade = 1,
        }
        quads[#quads + 1] = {           -- back
          { ix2 + 1, yBot, zB }, { ix, yBot, zB },
          { ix, yTop, zB }, { ix2 + 1, yTop, zB },
          uv = { { u1, v1 }, { u0, v1 }, { u0, v0 }, { u1, v0 } },
          shade = 0.68,
        }
        -- blade tips: a top strip where the row above is clear
        if not opaque(ix, iy - 1) then
          quads[#quads + 1] = {
            { ix, yTop, zB }, { ix2 + 1, yTop, zB },
            { ix2 + 1, yTop, zF }, { ix, yTop, zF },
            uv = { { u0, v0 }, { u1, v0 }, { u1, v0 }, { u0, v0 } },
            shade = 1,
          }
        end
        -- and underneath, where a blade ends in mid-air over the ground
        if not opaque(ix, iy + 1) then
          quads[#quads + 1] = {
            { ix, yBot, zF }, { ix2 + 1, yBot, zF },
            { ix2 + 1, yBot, zB }, { ix, yBot, zB },
            uv = { { u0, v1 }, { u1, v1 }, { u1, v1 }, { u0, v1 } },
            shade = OBJ_SHADE.bottom,
          }
        end
        -- and the run's two end walls, which is what makes a blade a solid
        -- thing rather than two billboards you can see between (sideQuads
        -- above argues it, and why each wall wears its end pixel's colour)
        sideQuads(quads, ix, ix2, yBot, yTop, zB, zF,
                  ax0, ay0, atlasW, atlasH, iy, opaque)
        ix = ix2 + 1
      else
        ix = ix + 1
      end
    end
  end
  return quads
end

local function buildGrass(S, map, x0, x1, y0, y1, data)
  local templates = {}
  local quads = S.grassQuads
  for ty = y0, y1 do
    for tx = x0, x1 do
      Budget.tick()
      local k = keyOf(tx, ty)
      local s = S.shapeAt[k]
      -- tufts only where the CELL is tall grass by the engine's own rule
      -- (isGrassCell: the cell's collision tile). The grass GRAPHIC also
      -- appears as decorative filler inside ordinary ground blocks, and a
      -- tile-level test sprouted tufts all over town plazas.
      if s and s.art == "grass"
         and map:isGrassCell(math.floor(tx / 2), math.floor(ty / 2)) then
        local tileId = S.tileAt[k]
        local tpl = templates[tileId]
        if not tpl then
          tpl = grassTemplate(map, data, tileId)
          templates[tileId] = tpl
        end
        local wx, wz = tx * 8, ty * 8
        -- Stable diagonal phase per tuft. Both ends of every quad receive
        -- the same value, so a gust bends the slab without shearing it.
        local sway = wx * 0.050 + wz * 0.031
        for _, q in ipairs(tpl) do
          quads[#quads + 1] = {
            { q[1][1] + wx, q[1][2], q[1][3] + wz },
            { q[2][1] + wx, q[2][2], q[2][3] + wz },
            { q[3][1] + wx, q[3][2], q[3][3] + wz },
            { q[4][1] + wx, q[4][2], q[4][3] + wz },
            uv = q.uv, shade = q.shade, sway = sway,
            cx = wx + 4, cz = wz + 4,
          }
        end

        -- Sparse wind-borne leaf. It reuses one opaque grass texel and is
        -- animated entirely on the GPU, so no per-frame Lua particles exist.
        if #tpl > 0 and ((tx * 13 + ty * 7) % 11 == 0) then
          local src = tpl[1]
          local uv = src.uv and src.uv[1] or { src.u, src.v }
          local lx = wx + 2 + ((tx * 5 + ty * 3) % 5)
          local lz = wz + 4
          local ly, size = 9 + ((tx + ty) % 3), 1.25
          quads[#quads + 1] = {
            { lx - size, ly,        lz }, { lx + size, ly,        lz },
            { lx + size, ly + size, lz }, { lx - size, ly + size, lz },
            uv = { uv, uv, uv, uv }, shade = 1, sway = sway + 0.73,
            cx = lx, cz = lz, leaf = true,
          }
        end

        -- Rarer one-pixel firefly. Geometry exists all day, but the shader
        -- gives it zero glow outside outdoor night.
        if #tpl > 0 and ((tx * 17 + ty * 11) % 29 == 0) then
          local src = tpl[1]
          local uv = src.uv and src.uv[1] or { src.u, src.v }
          local fx = wx + 2 + ((tx * 3 + ty * 5) % 5)
          local fz = wz + 4
          local fy, half = 9 + ((tx + ty) % 4), 0.5
          quads[#quads + 1] = {
            { fx - half, fy,     fz }, { fx + half, fy,     fz },
            { fx + half, fy + 1, fz }, { fx - half, fy + 1, fz },
            uv = { uv, uv, uv, uv }, shade = 1, sway = sway + 1.37,
            cx = fx, cz = fz, firefly = true,
          }
        end
      end
    end
  end
end

return buildGrass
