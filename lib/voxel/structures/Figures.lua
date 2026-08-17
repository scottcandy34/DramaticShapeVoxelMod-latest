V = ...

local Budget = V.require("util/BuildBudget")
local TileShape = V.require("voxel/TileShape")
local AuthoredMasks = V.require("voxel/structures/AuthoredMasks")
local maskModel = AuthoredMasks.maskModel
local maskPlate = AuthoredMasks.maskPlate
local maskSlab = AuthoredMasks.maskSlab

-- ---- figures: a thing drawn INTO furniture, cut out and stood up ----

local function keyOf(tx, ty)
  return (ty + 64) * 4096 + (tx + 64)
end

-- One authored figure at one matched position.
--
-- The mask IS the classification: no flood, no shade segmentation, no
-- validation gate.  Every automatic route in this file asks the art where
-- the object ends, and a figure painted into its own furniture has no
-- answer to give -- so the profile answers instead, and this only has to
-- believe it.  Which also means figures build HEADLESS: unlike every
-- other standee here, nothing below reads a pixel.
--
-- A PERSON is a SPRITE, not a prop, and an entry that states no `depth`
-- gets exactly the treatment SpriteBillboards gives a character: one flat
-- plane of the drawing's own pixels, no thickness, standing at its feet
-- and leaned back by the camera's pitch at draw time so it always reads
-- face-on -- because that is what the artwork is.  A seated man drawn
-- face-on is a 2D icon like every other Gen 1 figure; extruding him into
-- a slab reconstructs a body nobody drew (the ten-voxel version read as a
-- wedge of furniture, and even one voxel showed an edge the sprites never
-- show).
--
-- So the card's quads are emitted in its OWN LOCAL SPACE -- x from the
-- mask's west edge, y from his feet, all at z = 0 -- and the placement
-- (`wx`, `wz`, `y`) rides along for VoxelScene to build the lean matrix
-- from.  One quad per pixel rather than one alpha-keyed texture: the
-- tileset atlas has no alpha to key on, and per-pixel quads cut the exact
-- same silhouette straight out of the live atlas, so every palette bake
-- (SGB, RED++ per-tile groups, a mod's own art) textures him for free.
--
-- An entry that DOES state a `depth` is not a person, and takes the other
-- branch: a per-pixel voxel slab in world space (maskSlab above), standing
-- on the same furniture the card would have stood on.  The Marts' cash
-- register is why -- a machine set down on a counter is a box seen from
-- the front, and a card of it is the billboard failure the standee pools
-- exist to avoid.  It keeps the card's anchoring exactly: its feet on the
-- support's top plane, and its body in the 8px depth band of the tile row
-- its lowest pixel is drawn in, which is where a character card would
-- have pivoted.  So the machine sits at the FRONT of the counter cell it
-- is drawn low in, and never leans into the aisle behind it.
local function buildFigure(S, map, fig, tx, ty, perRow)
  local bw, bh = fig.w * 8, fig.h * 8

  local function at(lx, ly)
    if lx < 0 or lx >= bw or ly < 0 or ly >= bh then return false end
    return fig.mask[ly * bw + lx] or false
  end

  -- his feet and his west edge: the card's own origin
  local lowY, minX = 0, bw - 1
  for ly = 0, bh - 1 do
    for lx = 0, bw - 1 do
      if at(lx, ly) then
        if ly > lowY then lowY = ly end
        if lx < minX then minX = lx end
      end
    end
  end

  -- He stands ON the furniture he was drawn into -- the same lift a pinned
  -- prop above a pinned box takes (see buildObject), and gated the same
  -- way: a thing set down on furniture occupies a BLOCKED cell, while a
  -- seat you merely walk up to is in a walkable one.  The row under his
  -- card is SCANNED for the tallest authored upright rather than read at
  -- its west corner: the corner tile can be furniture that is not his
  -- seat (the couch's raised backrest column stands there, `top` art and
  -- taller than the cushion he actually sits on).
  local baseY = 0
  local blocked = not map:isWalkableCell(math.floor(tx / 2),
                                         math.floor((ty + fig.h - 1) / 2))
  if blocked then
    for dx = 0, fig.w - 1 do
      local bs = S.shapeAt[keyOf(tx + dx, ty + fig.h)]
      if bs and bs.authored and bs.art == "upright"
         and (bs.h or 0) > baseY then
        baseY = bs.h
      end
    end
  end

  local atlasW = map.tileset.imageWidth or 128
  local atlasH = map.tileset.imageHeight or 48

  if fig.model then
    -- An authored solid: centred on the mask's own columns, standing on
    -- the furniture's top plane at the front of its cell.
    local maxX = minX
    for ly = 0, bh - 1 do
      for lx = 0, bw - 1 do
        if at(lx, ly) and lx > maxX then maxX = lx end
      end
    end
    local xMid = tx * 8 + math.floor((minX + maxX + 1) / 2)
    local zSouth = (math.floor((ty + fig.h - 1) / 2) + 1) * 16 - (fig.inset or 0)
    maskModel(S.objectQuads, fig.model, perRow, atlasW, atlasH,
              xMid, zSouth, baseY)
  elseif fig.depth then
    -- An OBJECT: the standee slab, standing on the FRONT edge of the tile
    -- row its feet are drawn in -- the south face of the 8px band a
    -- character card would have pivoted in.  It is anchored there and
    -- grows NORTH rather than being centred, so that `depth` is free to
    -- exceed the 8px band without the machine ever creeping toward the
    -- aisle: a till drawn low on a counter is at the counter's front, and
    -- a deeper one just eats more of the bare top behind it.  (At the
    -- 8 the band itself is, the two rules agree.)
    --
    -- `thin` caps the top rows to their own thickness, centred in the
    -- body's depth -- the register's receipt curl leaves the arm's top
    -- face by a slot in the middle of it, not flush with its front.
    local south = ty * 8 + math.floor(lowY / 8) * 8 + 8
    local function bandOf(ly)
      local z0 = south - fig.depth
      if fig.thin and ly < fig.thin.rows then
        local m = math.floor((fig.depth - fig.thin.depth) / 2)
        return z0 + m, z0 + m + fig.thin.depth
      end
      return z0, south
    end
    local function yOf(ly) return baseY + lowY - ly end
    maskSlab(S.objectQuads, fig, perRow, atlasW, atlasH, tx * 8,
             yOf, bandOf, baseY, fig.flat)
    if fig.flat then
      -- The top-view rect lands on the plane its own BOTTOM row would
      -- have stood at -- which is the top of whatever the extrusion left
      -- under it (the register's base band), so the keys lie on the deck
      -- and never float.
      --
      -- In depth it fills the body's whole band, STRETCHED to it: the rect
      -- is the machine's deck, so it reaches as deep as the machine does,
      -- and its last drawn row stays the deck's front edge directly over
      -- the fascia below it -- an object drawn LOW on a surface is drawn
      -- NEAR its front.
      maskPlate(S.objectQuads, fig, perRow, atlasW, atlasH, tx * 8,
                fig.flat, yOf(fig.flat.r1), south - fig.depth, fig.depth)
    end
  else
    local quads = {}
    for ly = 0, bh - 1 do
      Budget.tick()
      for lx = 0, bw - 1 do
        if at(lx, ly) then
          local tile = fig.tiles[math.floor(ly / 8) * fig.w
                                 + math.floor(lx / 8) + 1]
          local u = ((tile % perRow) * 8 + lx % 8 + 0.5) / atlasW
          local v = (math.floor(tile / perRow) * 8 + ly % 8 + 0.5) / atlasH
          local x, y = lx - minX, lowY - ly
          quads[#quads + 1] = { { x, y, 0 }, { x + 1, y, 0 },
                                { x + 1, y + 1, 0 }, { x, y + 1, 0 },
                                u = u, v = v, shade = 1 }
        end
      end
    end

    -- Where the card stands.  `wz` is the MIDDLE of the tile row his feet
    -- are drawn in, which is the same convention a character card uses
    -- (its feet plane sits at its cell's middle) -- so he sorts against
    -- the couch and against a player walking past exactly the way an NPC
    -- standing there would.
    S.figures[#S.figures + 1] = {
      quads = quads,
      wx = tx * 8 + minX,
      wz = ty * 8 + math.floor(lowY / 8) * 8 + 4,
      y = baseY,
    }
  end

  -- What each covered tile wears now that he is off it.  Only the ART
  -- changes: the couch tiles keep their `counter` box (they ARE the
  -- couch) and the floor tiles he overhung stay flat floor -- the
  -- profile just names the version of each drawing without him in it,
  -- so nothing has to be synthesized or repainted from a neighbour vote.
  for i = 1, #fig.tiles do
    local dx, dy = (i - 1) % fig.w, math.floor((i - 1) / fig.w)
    S.tileAt[keyOf(tx + dx, ty + dy)] = fig.under[i]
  end
end

-- Every authored figure, wherever the map draws it.
--
-- Matched by TILE PATTERN rather than by coordinates: one blockset entry
-- places this couch once in each of the eleven Pokemon Centers (and the
-- Celadon Hotel), so the pattern finds all of them without the profile
-- naming a single map or cell.  The repaint above replaces the pattern's
-- own tiles, so a match can never fire twice on the same drawing.
local function buildFigures(S, map, x0, x1, y0, y1)
  local figures = TileShape.figures(map.tileset.id)
  if not figures then return end
  local perRow = map.tileset.tilesPerRow or 16
  for _, fig in ipairs(figures) do
    for ty = y0, y1 - fig.h + 1 do
      for tx = x0, x1 - fig.w + 1 do
        Budget.tick()
        local hit = true
        for i = 1, #fig.tiles do
          local dx, dy = (i - 1) % fig.w, math.floor((i - 1) / fig.w)
          if S.tileAt[keyOf(tx + dx, ty + dy)] ~= fig.tiles[i] then
            hit = false
            break
          end
        end
        if hit then buildFigure(S, map, fig, tx, ty, perRow) end
      end
    end
  end
end

return buildFigures