local V = ...

local Objects = V.require("voxel/structures/Objects")
local shadeClass = Objects.shadeClass

-- ---- relief props: top-down drawings lying on their surface ----

local DIRS4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function keyOf(tx, ty)
  return (ty + 64) * 4096 + (tx + 64)
end

-- A cell pinned `relief` is a prop DRAWN FROM ABOVE (a game console on
-- the floor): standing it up would be wrong, and a solid box would carry
-- the drawn floor around it.  The drawing is segmented like any forced
-- prop (black outline; the shades touching the cluster's edge are the
-- background) and the object pixels extrude straight up a few voxels,
-- art on the top face -- a piece of the drawing pushed out of the
-- ground.  The floor the flood removed is repainted by the claimed
-- tiles' common-ground fill.
local RELIEF_SHADE = { top = 1.0, south = 0.9, north = 0.62, side = 0.75 }

local function buildRelief(S, map, region, data, perRow, h)
  local atlasW = map.tileset.imageWidth or 128
  local atlasH = map.tileset.imageHeight or 48
  local bw = (region.maxX - region.minX + 1) * 8
  local bh = (region.maxY - region.minY + 1) * 8
  local member = {}
  for _, c in ipairs(region.tiles) do member[keyOf(c[1], c[2])] = true end

  local cls, srcU, srcV = {}, {}, {}
  for py = 0, bh - 1 do
    for px = 0, bw - 1 do
      local i = py * bw + px
      local k = keyOf(region.minX + math.floor(px / 8),
                      region.minY + math.floor(py / 8))
      if member[k] then
        local tile = S.tileAt[k]
        local ax = (tile % perRow) * 8 + px % 8
        local ay = math.floor(tile / perRow) * 8 + py % 8
        srcU[i], srcV[i] = ax, ay
        local r, g, b, a = data:getPixel(ax, ay)
        cls[i] = a == 0 and "off" or shadeClass(math.min(r, g, b))
      end
    end
  end

  local bg = {}
  for py = 0, bh - 1 do
    for px = 0, bw - 1 do
      if px == 0 or px == bw - 1 or py == 0 or py == bh - 1 then
        local c = cls[py * bw + px]
        if c and c ~= "black" and c ~= "off" then bg[c] = true end
      end
    end
  end

  local flooded, queue = {}, {}
  local function seed(i)
    local c = cls[i]
    if c and c ~= "black" and (c == "off" or bg[c]) and not flooded[i] then
      flooded[i] = true
      queue[#queue + 1] = i
    end
  end
  for px = 0, bw - 1 do
    seed(px)
    seed((bh - 1) * bw + px)
  end
  for py = 0, bh - 1 do
    seed(py * bw)
    seed(py * bw + bw - 1)
  end
  while #queue > 0 do
    local i = table.remove(queue)
    local px, py = i % bw, math.floor(i / bw)
    for _, d in ipairs(DIRS4) do
      local nx, ny = px + d[1], py + d[2]
      if nx >= 0 and nx < bw and ny >= 0 and ny < bh then
        seed(ny * bw + nx)
      end
    end
  end

  local function on(px, py)
    if px < 0 or px >= bw or py < 0 or py >= bh then return false end
    local i = py * bw + px
    return cls[i] ~= nil and cls[i] ~= "off" and not flooded[i]
  end

  local quads = S.objectQuads
  local wx0, wz0 = region.minX * 8, region.minY * 8
  for py = 0, bh - 1 do
    for px = 0, bw - 1 do
      if on(px, py) then
        local i = py * bw + px
        local u = (srcU[i] + 0.5) / atlasW
        local v = (srcV[i] + 0.5) / atlasH
        local x, z = wx0 + px, wz0 + py
        local function quad(c1, c2, c3, c4, shade)
          quads[#quads + 1] = { c1, c2, c3, c4, u = u, v = v, shade = shade }
        end
        quad({ x, h, z }, { x + 1, h, z }, { x + 1, h, z + 1 },
             { x, h, z + 1 }, RELIEF_SHADE.top)
        if not on(px, py + 1) then
          quad({ x, 0, z + 1 }, { x + 1, 0, z + 1 }, { x + 1, h, z + 1 },
               { x, h, z + 1 }, RELIEF_SHADE.south)
        end
        if not on(px, py - 1) then
          quad({ x + 1, 0, z }, { x, 0, z }, { x, h, z },
               { x + 1, h, z }, RELIEF_SHADE.north)
        end
        if not on(px - 1, py) then
          quad({ x, 0, z }, { x, 0, z + 1 }, { x, h, z + 1 },
               { x, h, z }, RELIEF_SHADE.side)
        end
        if not on(px + 1, py) then
          quad({ x + 1, 0, z + 1 }, { x + 1, 0, z }, { x + 1, h, z },
               { x + 1, h, z + 1 }, RELIEF_SHADE.side)
        end
      end
    end
  end
end

return buildRelief