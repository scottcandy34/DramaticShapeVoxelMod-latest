local V = ...

local Budget = V.require("util/BuildBudget")
local Objects = V.require("voxel/structures/Objects")
local OBJ_SHADE = Objects.OBJ_SHADE

-- ---- authored masks with a body ----

local AuthoredMasks = {}

-- One authored mask emitted as a per-pixel voxel slab in WORLD space --
-- the treatment every solid standee in this file gets, driven by a hand
-- drawn silhouette instead of a flood.
--
-- The caller owns placement entirely, because placement is the whole
-- difference between the two things that use this: `x0` is the world x of
-- the mask's west edge, `yOf(ly)` the world y a drawn row lands at, and
-- `bandOf(ly)` its z span.  A bicycle hung on a wall keeps its drawn
-- elevation and juts south of the band; a cash register stands on the
-- counter's top plane and sits inside its own cell.
--
-- `bandOf` is per ROW rather than per object so one drawing can hold parts
-- of different thickness (the register's receipt curl over its body).
-- Where the band CHANGES between two stacked rows the lower row still gets
-- its top face: without that the body would be open along the strip the
-- thinner part does not cover, and you would see into the machine.
--
-- `omit` is a rect of the mask this pass does NOT extrude, because it is
-- not a face at all -- maskPlate lays it flat instead.  It leaves the mask
-- for good here, neighbours included, so the extrusion closes up around
-- the notch exactly as if the drawing had never filled it.
function AuthoredMasks.maskSlab(quads, m, perRow, atlasW, atlasH, x0, yOf, bandOf,
                        yFloor, omit)
  local bw, bh = m.w * 8, m.h * 8

  local function at(lx, ly)
    if lx < 0 or lx >= bw or ly < 0 or ly >= bh then return false end
    if omit and lx >= omit.x0 and lx <= omit.x1
       and ly >= omit.r0 and ly <= omit.r1 then return false end
    return m.mask[ly * bw + lx] or false
  end

  for ly = 0, bh - 1 do
    Budget.tick()
    local z0, z1 = bandOf(ly)
    local pz0, pz1 = bandOf(ly - 1)
    local capped = (pz0 ~= z0 or pz1 ~= z1)
    for lx = 0, bw - 1 do
      if at(lx, ly) then
        local tile = m.tiles[math.floor(ly / 8) * m.w
                             + math.floor(lx / 8) + 1]
        local u = ((tile % perRow) * 8 + lx % 8 + 0.5) / atlasW
        local v = (math.floor(tile / perRow) * 8 + ly % 8 + 0.5) / atlasH
        local x, y = x0 + lx, yOf(ly)
        local function quad(c1, c2, c3, c4, shade)
          quads[#quads + 1] = { c1, c2, c3, c4, u = u, v = v, shade = shade }
        end
        quad({ x, y, z1 }, { x + 1, y, z1 }, { x + 1, y + 1, z1 },
             { x, y + 1, z1 }, OBJ_SHADE.front)
        quad({ x + 1, y, z0 }, { x, y, z0 }, { x, y + 1, z0 },
             { x + 1, y + 1, z0 }, OBJ_SHADE.back)
        if capped or not at(lx, ly - 1) then
          quad({ x, y + 1, z0 }, { x + 1, y + 1, z0 }, { x + 1, y + 1, z1 },
               { x, y + 1, z1 }, OBJ_SHADE.top)
        end
        if y > yFloor and not at(lx, ly + 1) then
          quad({ x, y, z1 }, { x + 1, y, z1 }, { x + 1, y, z0 },
               { x, y, z0 }, OBJ_SHADE.bottom)
        end
        if not at(lx - 1, ly) then
          quad({ x, y, z0 }, { x, y, z1 }, { x, y + 1, z1 },
               { x, y + 1, z0 }, OBJ_SHADE.side)
        end
        if not at(lx + 1, ly) then
          quad({ x + 1, y, z1 }, { x + 1, y, z0 }, { x + 1, y + 1, z0 },
               { x + 1, y + 1, z1 }, OBJ_SHADE.side)
        end
      end
    end
  end
end

-- The other half of the same drawing: a rect of the mask that is a
-- TOP-VIEW surface, laid HORIZONTAL instead of extruded.
--
-- This is the methodology's band classification at rect granularity, and
-- the reason the register is not a box.  A GB cell packs several facings,
-- and the register's keypad is drawn from ABOVE -- its keys lie on the
-- machine's deck, sealed behind their own black border inside the outer
-- silhouette.  Extruding it stands that surface on end and paints the keys
-- up the machine's face, which is the extruded-picture failure exactly.
--
-- So the rect lands one voxel proud of what maskSlab left below it, at `y`,
-- one voxel thick, filling the body's whole depth band (`z0`, `D`).
--
-- The rect STRETCHES over that band rather than laying its rows 1:1: it is
-- the machine's whole deck, so it has to reach the machine's whole depth,
-- and the alternative -- panel at the front, bare deck behind -- leaves a
-- strip of the base band's top showing through where the keys should be.
-- Sampled at the voxel's CENTRE, the same rule Stage 1 samples the atlas
-- with, so a band scales by whole voxels and nothing blurs: at 8 rows over
-- 12 voxels every second drawn row doubles.  The one place in the model
-- where a texel is not 1:1 with a drawn pixel, and the reason `depth` is an
-- authored number again.  No bottom faces: it rests on the box.
function AuthoredMasks.maskPlate(quads, m, perRow, atlasW, atlasH, x0, r, y, z0, D)
  local bw, bh = m.w * 8, m.h * 8
  local rows = r.r1 - r.r0 + 1

  -- depth voxel -> the drawn row it wears
  local function rowAt(k)
    if k < 0 or k >= D then return nil end
    return r.r0 + math.min(rows - 1, math.floor((k + 0.5) * rows / D))
  end

  local function at(lx, k)
    local ly = rowAt(k)
    if not ly or lx < r.x0 or lx > r.x1 then return false end
    return m.mask[ly * bw + lx] or false
  end

  -- The plate's rim, in the two directions the drawing treats differently.
  -- ACROSS the rows the neighbour is the extrusion standing BESIDE the
  -- notch (the register's display unit), which is tall and covers the
  -- plate's edge, so that face must not be drawn twice.  ALONG them the
  -- neighbour is the extrusion BELOW it (the base band, whose own front
  -- face stops one voxel short), so the plate's front lip is exposed and
  -- is the deck's own front edge.
  local function beside(lx, ly)
    if lx < 0 or lx >= bw or ly < 0 or ly >= bh then return false end
    return m.mask[ly * bw + lx] or false
  end

  for k = 0, D - 1 do
    Budget.tick()
    local ly, z = rowAt(k), z0 + k
    for lx = r.x0, r.x1 do
      if at(lx, k) then
        local tile = m.tiles[math.floor(ly / 8) * m.w
                             + math.floor(lx / 8) + 1]
        local u = ((tile % perRow) * 8 + lx % 8 + 0.5) / atlasW
        local v = (math.floor(tile / perRow) * 8 + ly % 8 + 0.5) / atlasH
        local x = x0 + lx
        local function quad(c1, c2, c3, c4, shade)
          quads[#quads + 1] = { c1, c2, c3, c4, u = u, v = v, shade = shade }
        end
        quad({ x, y + 1, z }, { x + 1, y + 1, z }, { x + 1, y + 1, z + 1 },
             { x, y + 1, z + 1 }, OBJ_SHADE.top)
        if not at(lx, k + 1) then
          quad({ x, y, z + 1 }, { x + 1, y, z + 1 }, { x + 1, y + 1, z + 1 },
               { x, y + 1, z + 1 }, OBJ_SHADE.front)
        end
        if not at(lx, k - 1) then
          quad({ x + 1, y, z }, { x, y, z }, { x, y + 1, z },
               { x + 1, y + 1, z }, OBJ_SHADE.back)
        end
        if not beside(lx - 1, ly) then
          quad({ x, y, z }, { x, y, z + 1 }, { x, y + 1, z + 1 },
               { x, y + 1, z }, OBJ_SHADE.side)
        end
        if not beside(lx + 1, ly) then
          quad({ x + 1, y, z + 1 }, { x + 1, y, z }, { x + 1, y + 1, z },
               { x + 1, y + 1, z + 1 }, OBJ_SHADE.side)
        end
      end
    end
  end
end

-- An AUTHORED solid standing on furniture, given as plan layers instead of
-- extruded from the drawing (see TileShape's `model`).  The one thing it
-- shares with the mask paths is that nothing here is a colour: each layer
-- names the atlas texels its top and its sides wear, and every quad below
-- samples one of them, so the Centers' bell is painted out of the counter's
-- own pixels and recolours with it.
--
-- Placement is by CELL, not by drawn row.  A model exists because the
-- drawing was too small to un-project, so its drawn row says nothing about
-- depth worth keeping -- what says something is which piece of furniture it
-- is on and which end of it a person reaches: the solid is centred on the
-- mask's own columns and pushed to the SOUTH edge of the support cell, the
-- face the aisle is on, less the entry's `inset` -- the one number here
-- taste can move, because flush against the counter's own front lip is a
-- real position and so is a couple of voxels back from it.
function AuthoredMasks.maskModel(quads, m, perRow, atlasW, atlasH, xMid, zSouth, y0)
  local function uvOf(t)
    local tile, row, col = t[1], t[2], t[3] or 0
    return ((tile % perRow) * 8 + col + 0.5) / atlasW,
           (math.floor(tile / perRow) * 8 + row + 0.5) / atlasH
  end

  for k, L in ipairs(m) do
    local u, v = uvOf(L.side)
    local ut, vt = uvOf(L.top)
    local above = m[k + 1]
    local x0 = xMid - math.floor(L.w / 2)
    local z0 = zSouth - L.d
    local function solid(layer, dx, dz)
      if not layer or dx < 0 or dx >= layer.w or dz < 0 or dz >= layer.d then
        return false
      end
      return layer.cells[dz * layer.w + dx] or false
    end
    for dz = 0, L.d - 1 do
      for dx = 0, L.w - 1 do
        if solid(L, dx, dz) then
          local x, y, z = x0 + dx, y0 + k - 1, z0 + dz
          local function quad(c1, c2, c3, c4, uu, vv, shade)
            quads[#quads + 1] = { c1, c2, c3, c4, u = uu, v = vv,
                                  shade = shade }
          end
          -- a layer's own plan is what closes it: a face is drawn wherever
          -- the neighbouring cell of this layer is empty, and the top
          -- wherever the layer ABOVE does not stand on it.  Nothing needs a
          -- bottom -- layer 1 rests on the furniture and the rest rest on
          -- each other.
          if not solid(above, dx, dz) then
            quad({ x, y + 1, z }, { x + 1, y + 1, z }, { x + 1, y + 1, z + 1 },
                 { x, y + 1, z + 1 }, ut, vt, OBJ_SHADE.top)
          end
          if not solid(L, dx, dz + 1) then
            quad({ x, y, z + 1 }, { x + 1, y, z + 1 },
                 { x + 1, y + 1, z + 1 }, { x, y + 1, z + 1 }, u, v,
                 OBJ_SHADE.front)
          end
          if not solid(L, dx, dz - 1) then
            quad({ x + 1, y, z }, { x, y, z }, { x, y + 1, z },
                 { x + 1, y + 1, z }, u, v, OBJ_SHADE.back)
          end
          if not solid(L, dx - 1, dz) then
            quad({ x, y, z }, { x, y, z + 1 }, { x, y + 1, z + 1 },
                 { x, y + 1, z }, u, v, OBJ_SHADE.side)
          end
          if not solid(L, dx + 1, dz) then
            quad({ x + 1, y, z + 1 }, { x + 1, y, z }, { x + 1, y + 1, z },
                 { x + 1, y + 1, z + 1 }, u, v, OBJ_SHADE.side)
          end
        end
      end
    end
  end
end

return AuthoredMasks