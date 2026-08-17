V = ...

local Budget = V.require("util/BuildBudget")
local TileShape = V.require("voxel/TileShape")
local AuthoredMasks = V.require("voxel/structures/AuthoredMasks")
local maskSlab = AuthoredMasks.maskSlab

-- ---- mounted: a thing drawn INTO a wall band, stood proud of it ----

local function keyOf(tx, ty)
  return (ty + 64) * 4096 + (tx + 64)
end

-- One authored mounted object at one matched position.
--
-- Same authoring premise as a figure -- the mask IS the classification,
-- because a drawing painted onto the wall it hangs on has no background
-- margin for a flood to enter by, and here the wall's own #555 stripes
-- are a flood boundary as well, so a silhouette comes back striped.
-- Like a figure it therefore builds HEADLESS: nothing below reads a
-- pixel.
--
-- But a mounted object is an OBJECT, so it is built the way every other
-- standee here is -- a per-pixel voxel slab wearing the drawing's own
-- texels, quads emitted in world space -- and not as a sprite card:
--
--   ELEVATION is the drawn one.  A figure stands on its own feet; this
--   keeps the row it is painted in, because the band it is painted into
--   is a measured 16px face rising off the floor.  So drawn row `ly`
--   becomes world y = (band height - 1) - ly, and a bicycle whose wheels
--   are drawn on the band's bottom row lands on the floor while one hung
--   clear of it stays hung.
--   DEPTH juts SOUTH of the band's own face (z0 at the drawing's south
--   edge), so the object stands in front of the wall rather than inside
--   it.  It overhangs the walkable cell in front, which is what a bicycle
--   leaning on a wall does; nothing about collision changes.
local function buildMountedAt(S, map, m, tx, ty, perRow)
  local bh = m.h * 8
  local z0 = (ty + m.h) * 8
  local z1 = z0 + (m.depth or 2)

  maskSlab(S.objectQuads, m, perRow, map.tileset.imageWidth or 128,
           map.tileset.imageHeight or 48, tx * 8,
           function(ly) return (bh - 1) - ly end,
           function() return z0, z1 end, 0)

  -- What the band wears now that the object is off it: the plain panel
  -- the artist drew everywhere else along the same wall.  Only the ART
  -- changes -- these tiles keep the `wall` box they always resolved to,
  -- because they ARE the wall.
  for i = 1, #m.tiles do
    local dx, dy = (i - 1) % m.w, math.floor((i - 1) / m.w)
    S.tileAt[keyOf(tx + dx, ty + dy)] = m.under[i]
  end
end

-- Every authored mounted object, wherever the map draws it.  Matched by
-- TILE PATTERN like a figure, and for the same reason -- one blockset
-- entry can place the same drawing in several rooms -- and the repaint
-- above replaces the pattern's own tiles, so a match never fires twice
-- on one drawing.
local function buildMounted(S, map, x0, x1, y0, y1)
  local list = TileShape.mounted(map.tileset.id)
  if not list then return end
  local perRow = map.tileset.tilesPerRow or 16
  for _, m in ipairs(list) do
    for ty = y0, y1 - m.h + 1 do
      for tx = x0, x1 - m.w + 1 do
        Budget.tick()
        local hit = true
        for i = 1, #m.tiles do
          local dx, dy = (i - 1) % m.w, math.floor((i - 1) / m.w)
          if S.tileAt[keyOf(tx + dx, ty + dy)] ~= m.tiles[i] then
            hit = false
            break
          end
        end
        if hit then buildMountedAt(S, map, m, tx, ty, perRow) end
      end
    end
  end
end

return buildMounted