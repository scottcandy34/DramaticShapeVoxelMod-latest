local V = ...

local Objects = V.require("voxel/structures/Objects")
local OBJ_SHADE = Objects.OBJ_SHADE

-- ---- closing a standee's sides ----
--
-- The grass tufts and the flowers are both built the same way: each row of
-- the 8x8 drawing becomes a horizontal RUN of lit pixels, stood up as a
-- front face and a back face one voxel apart, with a lid on top. What that
-- leaves open is the two ENDS of every run -- so the slab was a pair of
-- billboards rather than a solid, and from any angle off square you looked
-- in through the edge and straight out the other side. At the low cameras
-- this mod has grown (1ST, 3RD, the battle's floor-level seat) that is
-- most of the time.
--
-- A wall goes on an end only where the pixel beyond it is actually clear,
-- which for a run's end it is by construction -- except where two runs on
-- the same row meet across a gap of nothing, which cannot happen, and at
-- the tile's border, where the neighbouring tile's own standee may or may
-- not continue the shape. The border is closed anyway: tufts sit on their
-- own half-cells with a gap between them, so an open border edge is a hole
-- in the open, not a seam with anything.
--
-- Each wall samples ONE texel at its centre -- the end pixel it is closing
-- off -- so it wears that pixel's own colour, which is the nearest coloured
-- pixel to the surface being filled. Sampling a single texel is also what
-- carries the animation: when a frame keys that pixel out, the wall's own
-- fragments discard with the faces either side of it, so a swaying tuft
-- never leaves a wall standing where its blade no longer is.
-- `everyPixel` is for a standee whose silhouette ANIMATES. The mesh is
-- built once, over the UNION of every frame's mask, and each frame is cut
-- out again in texture space -- so a run that is six pixels wide in the
-- union may be two pixels wide in the frame on screen, and the four pixels
-- that dropped out took the union's end walls with them. What is left
-- exposed is an interior boundary, which had no wall because in the union
-- it was not a boundary at all. That is the gap that survived closing the
-- run ends: the first frame looked solid and every other frame did not.
--
-- So an animated standee gets a wall on BOTH sides of EVERY pixel. A wall
-- between two lit pixels is enclosed by the front and back faces and never
-- seen; the moment its neighbour is keyed out it becomes the edge, already
-- in place and already wearing the right colour. Each is inset a hair into
-- its own pixel so the two that meet at a boundary are not coplanar -- the
-- voxel pass draws with culling off, and two quads in the same plane would
-- z-fight rather than politely take turns.
local SIDE_INSET = 0.03

local function sideQuads(quads, ix, ix2, yBot, yTop, zB, zF,
                         ax0, ay0, atlasW, atlasH, py, lit, everyPixel)
  local function texel(px)
    return (ax0 + px + 0.5) / atlasW, (ay0 + py + 0.5) / atlasH
  end
  local function left(px, at)
    local u, v = texel(px)
    quads[#quads + 1] = {                 -- facing -X
      { at, yBot, zB }, { at, yBot, zF },
      { at, yTop, zF }, { at, yTop, zB },
      uv = { { u, v }, { u, v }, { u, v }, { u, v } },
      shade = OBJ_SHADE.side,
    }
  end
  local function right(px, at)
    local u, v = texel(px)
    quads[#quads + 1] = {                 -- facing +X
      { at, yBot, zF }, { at, yBot, zB },
      { at, yTop, zB }, { at, yTop, zF },
      uv = { { u, v }, { u, v }, { u, v }, { u, v } },
      shade = OBJ_SHADE.side,
    }
  end
  if everyPixel then
    for px = ix, ix2 do
      left(px, px + SIDE_INSET)
      right(px, px + 1 - SIDE_INSET)
    end
    return
  end
  if not lit(ix - 1, py) then left(ix, ix) end
  if not lit(ix2 + 1, py) then right(ix2, ix2 + 1) end
end

return {
    SIDE_INSET = SIDE_INSET,
    sideQuads = sideQuads,
}