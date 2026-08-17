-- ---- stairs: pinned cells that render as real steps ----

local function keyOf(tx, ty)
  return (ty + 64) * 4096 + (tx + 64)
end

-- A cell the profile pins stair_e / stair_w (art "stair") becomes a
-- flight of STAIR_STEPS boxes rising evenly across the cell toward the
-- named side, each the full cell deep.  stair_down_e / stair_down_w is
-- the same flight EXCAVATED: the cell opens into a stairwell and the
-- steps descend below floor level toward the named side -- the shape a
-- staircase leading down a floor actually has.  The 2D staircase is
-- drawn from the side, so vertical faces (step fronts and stairwell
-- walls) wear the matching slice of that drawing -- the railing's
-- diagonal lands along the stepped silhouette -- while treads sample the
-- art band drawn at their own height.
--
-- stair_n / stair_down_n are the same pair of flights running INTO the
-- map rather than across it, for a staircase drawn head-on; that changes
-- the art reading enough to need its own branch below.
local STAIR_STEPS = 4

local STAIR_SHADE = { south = 1.0, north = 0.68, tread = 1.0,
                      riser = 0.82, cap = 0.78,
                      wellN = 0.9, wellS = 0.55, wellEnd = 0.15,
                      wellTread = 0.8 }

local function stairCell(S, map, data, cx, cy, s)
  local perRow = map.tileset.tilesPerRow or 16
  local atlasW = map.tileset.imageWidth or 128
  local atlasH = map.tileset.imageHeight or 48
  local quads = S.objectQuads
  local north = s.class == "stair_n" or s.class == "stair_down_n"
  local down = s.class == "stair_down_n" or s.class == "stair_down_e"
             or s.class == "stair_down_w"
  local east = s.class == "stair_e" or s.class == "stair_down_e"
  local mx, mz = cx * 16, cy * 16
  local h = s.h or 16
  local rise = h / STAIR_STEPS
  local runW = 16 / STAIR_STEPS
  local z0, z1 = mz, mz + 16

  -- cell-space art coords (16x16, row 0 the top) -> atlas uv; callers keep
  -- a quad's range inside one 8px tile so it never samples across a seam
  local function uv(px, py)
    px = math.max(0.05, math.min(15.95, px))
    py = math.max(0.05, math.min(15.95, py))
    local tile = S.tileAt[keyOf(cx * 2 + (px >= 8 and 1 or 0),
                                cy * 2 + (py >= 8 and 1 or 0))]
    return ((tile % perRow) * 8 + px % 8) / atlasW,
           (math.floor(tile / perRow) * 8 + py % 8) / atlasH
  end
  -- corners run bottom-left, bottom-right, top-right, top-left as seen
  -- from outside (the mesher's side convention); art rect in cell space
  local function face(c1, c2, c3, c4, ax0, ay0, ax1, ay1, shade)
    local u0, v0 = uv(ax0, ay0)
    local u1, v1 = uv(ax1, ay1)
    quads[#quads + 1] = { c1, c2, c3, c4,
      uv = { { u0, v1 }, { u1, v1 }, { u1, v0 }, { u0, v0 } },
      shade = shade }
  end
  -- a vertical face spanning heights [fy0, fy1] wearing art rows
  -- [ay0, ay1], emitted per 8-row art band so no quad crosses the seam
  local function banded(z, ax0, ax1, fy0, fy1, ay0, ay1, shade, flip)
    local scale = (fy1 - fy0) / math.max(ay1 - ay0, 0.001)
    for _, band in ipairs({ { ay0, math.min(8, ay1) },
                            { math.max(ay0, 8), ay1 } }) do
      local a0, a1 = band[1], band[2]
      if a1 > a0 then
        local by1 = fy1 - (a0 - ay0) * scale
        local by0 = fy1 - (a1 - ay0) * scale
        local xa, xb = mx + ax0, mx + ax1
        if flip then
          face({ xb, by0, z }, { xa, by0, z }, { xa, by1, z },
               { xb, by1, z }, ax0, a0, ax1, a1, shade)
        else
          face({ xa, by0, z }, { xb, by0, z }, { xb, by1, z },
               { xa, by1, z }, ax0, a0, ax1, a1, shade)
        end
      end
    end
  end

  -- A flight running INTO the map instead of across it.  The drawing is
  -- the same staircase seen head-on rather than from the side, and that
  -- changes which axis of the art means what: a drawn ROW is a step here,
  -- and -- because looking down a well is looking along its depth -- drawn
  -- row IS depth row, 1:1 across the cell's 16.
  --
  -- The Centers' steps state their own band table and it lands exactly:
  -- 4 white rows, 1 black, 3 grey, 1 black, 3 checker, 4 black = 16.  So
  -- an even four-step division puts a black NOSING on the southmost row of
  -- every band (15, 11, 7, 3) and leaves the rows behind it as that step's
  -- tread.  Nothing is authored but the RISE, which no head-on drawing can
  -- state; the depths, the treads and the nosings are all measured.
  --
  -- A nosing is drawn as one row because it is seen nearly edge-on, so
  -- un-projected it has real height and no depth: its row lies flat as the
  -- tread's front lip AND stands as the riser under it.  That is the one
  -- texel in the flight used twice, and using it twice is what a nosing is.
  --
  -- The well's own walls come free as well: the drawing's first and last
  -- COLUMNS are its black side walls, and its top band is the darkness the
  -- flight leaves by, which is what the far end wants to wear.
  --
  -- A flight CLIMBING away (`stair_n`) is the same reading with the sign of
  -- the rise flipped -- bands still run south to north, drawn row is still
  -- depth row, the nosing still serves twice.  Two things follow from the
  -- sign.  The risers turn around: a flight descending away from you closes
  -- its steps from below and shows you their backs, one climbing away shows
  -- you their FRONTS, so they face south.  And the drawing's black side
  -- columns stop being a well's walls and become the walls of the opening
  -- the flight climbs into: they run from each tread UP to the top of the
  -- wall band rather than down from the floor.  At the last step the flight
  -- has reached that top and there is no opening left to wall.
  --
  -- Every quad here is split at the cell's own 8px seam, in x and in rows
  -- both: `uv` resolves ONE tile per corner, and these four tiles are not
  -- neighbours in the atlas, so a quad that spans a seam interpolates
  -- between two unrelated corners of the sheet.
  if north then
    local runD = 16 / STAIR_STEPS
    local HALVES = { { 0.2, 7.9, 0, 8 }, { 8.1, 15.8, 8, 16 } }
    for i = 0, STAIR_STEPS - 1 do
      local a0 = 16 - (i + 1) * runD           -- band i, in art rows
      local a1 = a0 + runD
      local yTop = (down and -1 or 1) * (i + 1) * rise
      local ry = (down and -1 or 1) * i * rise        -- the step behind it
      local z0b, z1b = mz + a0, mz + a1

      for _, H in ipairs(HALVES) do
        local ax0, ax1, wx0, wx1 = H[1], H[2], mx + H[3], mx + H[4]

        -- the tread: the whole band, drawn row = depth row, so the nosing
        -- lies on its front lip exactly where the artist drew it
        face({ wx0, yTop, z0b }, { wx1, yTop, z0b },
             { wx1, yTop, z1b }, { wx0, yTop, z1b },
             ax0, a1, ax1, a0,
             down and STAIR_SHADE.wellTread or STAIR_SHADE.tread)

        -- the riser at that lip, one art row tall -- so it needs none of
        -- `banded`'s row splitting, and written straight keeps the geometry
        -- flush at the seam while the art stays inside its tile.  Facing
        -- north when the flight descends (the steps are closed from below,
        -- not looked at) and south when it climbs
        if down then
          face({ wx1, yTop, z1b }, { wx0, yTop, z1b },
               { wx0, ry, z1b }, { wx1, ry, z1b },
               ax1, a1 - 1, ax0, a1, STAIR_SHADE.riser)
        else
          face({ wx0, ry, z1b }, { wx1, ry, z1b },
               { wx1, yTop, z1b }, { wx0, yTop, z1b },
               ax0, a1 - 1, ax1, a1, STAIR_SHADE.riser)
        end

        -- the deep end, closing the opening this flight is cut into: from
        -- the floor of the well up to the top of the wall band beside it,
        -- in the drawing's own black top rows.  A climbing flight has no
        -- such end -- its top tread stands at the wall's own height and
        -- fills the opening
        if down and i == STAIR_STEPS - 1 then
          face({ wx1, -h, mz }, { wx0, -h, mz },
               { wx0, h, mz }, { wx1, h, mz },
               ax1, 3.9, ax0, 0.1, STAIR_SHADE.wellEnd)
        end
      end

      -- the opening's side walls beside this tread, wearing the drawing's
      -- own black edge columns -- excavation or recess, it is walled in its
      -- own texels.  Descending they run from the tread up to the floor,
      -- climbing from the tread up to the top of the wall band
      local wallTop = down and 0 or h
      local function sideWall(px, sx0, sx1, inward)
        local c
        if inward then                                  -- west wall, faces E
          c = { { px, yTop, z1b }, { px, yTop, z0b },
                { px, wallTop, z0b }, { px, wallTop, z1b } }
        else                                            -- east wall, faces W
          c = { { px, yTop, z0b }, { px, yTop, z1b },
                { px, wallTop, z1b }, { px, wallTop, z0b } }
        end
        face(c[1], c[2], c[3], c[4], sx0, a1, sx1, a0, STAIR_SHADE.wellN)
      end
      if wallTop > yTop then
        sideWall(mx, 0.1, 1.3, true)
        sideWall(mx + 16, 14.7, 15.9, false)
      end
    end
    return
  end

  for i = 0, STAIR_STEPS - 1 do
    local sx0 = east and (i * runW) or (16 - (i + 1) * runW)
    local sx1 = sx0 + runW
    local x0, x1 = mx + sx0, mx + sx1

    if down then
      -- stairwell: tread i sits (i+1) rises below the floor; the walls
      -- above it are the excavation, wearing the drawing at its depth
      local yTop = -(i + 1) * rise
      local dep = (i + 1) * rise

      face({ x0, yTop, z0 }, { x1, yTop, z0 },
           { x1, yTop, z1 }, { x0, yTop, z1 },
           sx0, dep - 1.4, sx1, dep, STAIR_SHADE.wellTread)

      -- stairwell walls above this tread: north wall faces the camera
      banded(z0, sx0, sx1, yTop, 0, 0, dep, STAIR_SHADE.wellN)
      banded(z1, sx0, sx1, yTop, 0, 0, dep, STAIR_SHADE.wellS, true)

      -- riser dropping to this tread from the shallower step
      local rx = east and x0 or x1
      local ry1 = -i * rise
      local rax = east and (sx0 + 0.1) or (sx1 - 1.3)
      if east then
        face({ rx, yTop, z0 }, { rx, yTop, z1 },
             { rx, ry1, z1 }, { rx, ry1, z0 },
             rax, i * rise, rax + 1.2, dep, STAIR_SHADE.riser)
      else
        face({ rx, yTop, z1 }, { rx, yTop, z0 },
             { rx, ry1, z0 }, { rx, ry1, z1 },
             rax, i * rise, rax + 1.2, dep, STAIR_SHADE.riser)
      end

      -- the deep end: a dark opening under the wall the flight leaves by
      if i == STAIR_STEPS - 1 then
        local px = east and (mx + 16) or mx
        local cax = east and 14.7 or 0.1
        if east then
          face({ px, -h, z1 }, { px, -h, z0 }, { px, 0, z0 }, { px, 0, z1 },
               cax, 0, cax + 1.2, 16, STAIR_SHADE.wellEnd)
        else
          face({ px, -h, z0 }, { px, -h, z1 }, { px, 0, z1 }, { px, 0, z0 },
               cax, 0, cax + 1.2, 16, STAIR_SHADE.wellEnd)
        end
      end
    else
      -- rising flight
      local yTop = (i + 1) * rise
      local py0 = 16 - yTop

      -- south + north faces: the drawn flight sliced at this step's column
      banded(z1, sx0, sx1, 0, yTop, py0, 16, STAIR_SHADE.south)
      banded(z0, sx0, sx1, 0, yTop, py0, 16, STAIR_SHADE.north, true)

      -- tread: the step's top, wearing the art band drawn at its height
      face({ x0, yTop, z0 }, { x1, yTop, z0 },
           { x1, yTop, z1 }, { x0, yTop, z1 },
           sx0, py0, sx1, py0 + 1.4, STAIR_SHADE.tread)

      -- riser: the vertical strip exposed above the previous step
      local rx = east and x0 or x1
      local ry0 = i * rise
      local rax = east and (sx0 + 0.1) or (sx1 - 1.3)
      if east then
        face({ rx, ry0, z0 }, { rx, ry0, z1 },
             { rx, yTop, z1 }, { rx, yTop, z0 },
             rax, 16 - yTop, rax + 1.2, 16 - ry0, STAIR_SHADE.riser)
      else
        face({ rx, ry0, z1 }, { rx, ry0, z0 },
             { rx, yTop, z0 }, { rx, yTop, z1 },
             rax, 16 - yTop, rax + 1.2, 16 - ry0, STAIR_SHADE.riser)
      end

      -- cap the tall end of the flight so it never shows a hole
      if i == STAIR_STEPS - 1 then
        local px = east and (mx + 16) or mx
        local cax = east and 14.7 or 0.1
        if east then
          face({ px, 0, z1 }, { px, 0, z0 }, { px, h, z0 }, { px, h, z1 },
               cax, 0, cax + 1.2, 16, STAIR_SHADE.cap)
        else
          face({ px, 0, z0 }, { px, 0, z1 }, { px, h, z1 }, { px, h, z0 },
               cax, 0, cax + 1.2, 16, STAIR_SHADE.cap)
        end
      end
    end
  end
end

local function buildStairs(S, map, x0, x1, y0, y1, data)
  for cy = math.floor(y0 / 2), math.floor(y1 / 2) do
    for cx = math.floor(x0 / 2), math.floor(x1 / 2) do
      local s = S.shapeAt[keyOf(cx * 2, cy * 2)]
      if s and s.art == "stair" then
        -- claim the cell whichever way the quads go: the mesher must not
        -- box or floor it.  A rising flight stands on the map's common
        -- floor; a stairwell IS the hole, so nothing is painted under it
        local down = s.class == "stair_down_e" or s.class == "stair_down_w"
                  or s.class == "stair_down_n"
        for dy = 0, 1 do
          for dx = 0, 1 do
            local tk = keyOf(cx * 2 + dx, cy * 2 + dy)
            S.skip[tk] = true
            if not down then S.ground[tk] = false end
          end
        end
        if data then stairCell(S, map, data, cx, cy, s) end
      end
    end
  end
end

return buildStairs