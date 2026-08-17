local V = ...

local Budget = V.require("util/BuildBudget")
local Objects = V.require("voxel/structures/Objects")
local shadeClass = Objects.shadeClass

-- how far past the map body cells still get the hull. A route's ring is
-- nearly as big as its body; modelling all of it costs hundreds of
-- thousands of quads of border trees nobody walks near. Beyond this,
-- pinned cells simply are not claimed and fall through to the mesher's
-- plain box -- cheap distant scenery. (Declared up here rather than
-- beside buildCylinders because forMap's grid resolve reads it too.)
local ROUND_RING = 4

-- ---- round scenery: outline-hulled voxel balls ----

local function keyOf(tx, ty)
  return (ty + 64) * 4096 + (tx + 64)
end

-- Cells the profile pins as round (tree canopies -- the class keeps its
-- historical `cylinder` name in the data file) render as a VOXEL HULL cut
-- from the drawing itself. The first shipped attempt was a lathe -- the
-- per-row silhouette width revolved into a 12-segment column with the art
-- wrapped by sin(angle) -- and it read exactly like what it was: the
-- sprite pasted on a cylinder, with the wrap smearing the pixels into
-- vertical stripes. This replaces it with real voxels.
--
-- Segmentation first, silhouette-width second: the tree cell's art is a
-- ball drawn over background grass, and the background's mid greens pass
-- any brightness test (they inflated every lathe row to full width). The
-- ball's own DARKEST pixels are what bound it, so the mask is "the
-- darkest-shade outline plus everything it encloses": flood from the cell
-- border through every non-black pixel; what the flood cannot reach is
-- the tree, and the cast shadow under the canopy (dark but not enclosed)
-- floods away with the grass. Art with no closed black outline -- the
-- border tree wall is a dither of black and canopy with no drawn ring --
-- encloses nothing; there the flood passes only through the LIGHT shades
-- (the methodology doc's rule: black and dark together form the
-- boundary), and the dither mass itself becomes the mask, checker holes
-- and all, because a 4-connected flood cannot thread a diagonal checker.
--
-- Volume: each mask row is a disc. The row's span gives a center and
-- half-width, and every mask pixel's column runs that circle's chord in
-- z, quantized to whole voxels -- the front view IS the sprite, the plan
-- view is the sprite's own width profile turned in depth, and both step
-- pixel by pixel. Rows below the mask (the drawn shadow) repeat the
-- bottom row's discs down to the ground so the canopy stands on a short
-- dark foot instead of floating.
--
-- Skin: front and back faces carry the drawing per-pixel (the back reads
-- mirrored, sprite-pure); side and step faces take their column's own
-- texel, which puts the drawn outline exactly on the silhouette's rim;
-- and a fully exposed cap keeps its outline only on the rim cells while
-- the interior samples the canopy a couple of rows deeper -- painting the
-- whole cap with the outline row blacked out every dome on the first
-- attempt (the lathe hit the same bug with its top discs).
--
-- Tree walls repeat the same four tiles for hundreds of cells, so the
-- hull is built once per distinct art signature and stamped per cell.
local ROUND_SHADE = { front = 1.0, back = 0.68, side = 0.78,
                      top = 1.0, bottom = 0.55 }

-- The potted plant's ORGANIC HALF: the leaf crown (16 rows), then the
-- trunk, its root flare and the strands draping over the pot's rim (8
-- more) -- all of it stands as a slab this many voxels deep instead of
-- revolving. `depth` 5 is the thin standee pool's depth, what every other
-- interior plant already uses.
--
-- `rows` = 24 puts the slab/revolve boundary AT THE VESSEL'S RIM ROW, and
-- that placement is what makes the pot read as a pot. The first cut put
-- it at the cell seam (16), which let the root and drape rows revolve:
-- their drawn spans are 8-12 wide, so they stacked 8-12-deep discs on top
-- of the rim and the whole base read as one bulbous onion instead of a
-- flat-mouthed planter with a trunk standing out of it. Only rows 24-31
-- -- black rim edge, gold band, body, foot, the drawn flowerpot profile
-- -- are the vessel, and only they revolve.
local PLANTER_SPRAY = { rows = 24, depth = 5 }

-- `spray`, when given, caps the chord over the canvas's top `rows` rows to
-- `depth` voxels instead of revolving them.
--
-- Revolving a row turns its DRAWN WIDTH into depth, which only means
-- something when the drawing states a width to turn -- the pot's rows do
-- (a 3px stem opening to a 12px belly and closing to a 6px foot, an urn's
-- profile), and a tree canopy's do (the ball's outline is drawn). A leaf
-- crown's do NOT: the leaves are a spray that runs off all four sides of
-- its tile, so every row measures the full canvas and the revolve can only
-- produce a solid cylinder -- the "hedge column" a plant must never become,
-- with one row of texels smeared down its whole top face. Where the drawing
-- states no profile, the honest reading is the one the thin standee pools
-- exist for: the foliage stands as a per-pixel slab and keeps the airy
-- silhouette that makes it read as leaves.
-- `squash`, when given, is the PERCENT of its revolved depth every chord
-- keeps -- 100 (or nil) is the identity, 50 halves the hull front to back.
--
-- A full revolve assumes the drawing's width is also its depth, which is
-- true of a thing that really is round in plan (a hedge ball, a boulder,
-- a trash can). A TREE is round in its canopy and thin at every other
-- reading: the trunk is a stick, the crown is more air than wood, and the
-- drawing is scenery seen from one side. Revolved at full width the little
-- tree eats a whole cell of depth and reads as a boulder wearing bark, so
-- the plan stays a circle and shrinks toward an ellipse: still round in
-- section, still stepping pixel by pixel, just shallower. The chord is
-- re-centred on the mid-plane, so the model neither slides nor detaches
-- from the cells around it.
local function roundTemplate(S, map, data, cx, cy, groundTiles, N, capRows,
                             NYin, spray, baseRows, bodyRows, wellRows,
                             taperVox, squash)
  -- The canvas is NX wide and NX DEEP (a hull is round in plan, so its
  -- depth is its width) by NY tall. NX = 16 is one cell, 32 a 2x2-cell
  -- group; NY defaults to NX -- a ball -- and NY = 2 * NX is a drawing
  -- STACKED two cells high on one cell of plot (the potted plant).
  local NX = N or 16
  local NY = NYin or NX
  local N2 = NX / 2
  local perRow = map.tileset.tilesPerRow or 16
  local atlasW = map.tileset.imageWidth or 128
  local atlasH = map.tileset.imageHeight or 48

  -- cell-space art access (NX x NY, row 0 = top), anchored at cell (cx, cy)
  local function tileOf(px, py)
    return S.tileAt[keyOf(cx * 2 + math.floor(px / 8),
                          cy * 2 + math.floor(py / 8))]
  end
  local function texel(px, py)
    local tile = tileOf(px, py)
    return (tile % perRow) * 8 + px % 8,
           math.floor(tile / perRow) * 8 + py % 8
  end

  -- shade class of every canvas pixel, indexed py * NX + px
  local cls = {}
  for py = 0, NY - 1 do
    for px = 0, NX - 1 do
      local ax, ay = texel(px, py)
      local r, g, b, a = data:getPixel(ax, ay)
      cls[py * NX + px] = a == 0 and "off"
                          or shadeClass(math.min(r, g, b))
    end
  end

  -- 4-connected flood from a row band's border through `passable` classes
  local function floodOutside(passable, y0, y1)
    local out, stack = {}, {}
    local function seed(i)
      if not out[i] and passable[cls[i]] then
        out[i] = true
        stack[#stack + 1] = i
      end
    end
    for px = 0, NX - 1 do
      seed(y0 * NX + px); seed(y1 * NX + px)
    end
    for py = y0, y1 do
      seed(py * NX); seed(py * NX + NX - 1)
    end
    while #stack > 0 do
      local i = table.remove(stack)
      local px, py = i % NX, math.floor(i / NX)
      if px > 0 then seed(i - 1) end
      if px < NX - 1 then seed(i + 1) end
      if py > y0 then seed(i - NX) end
      if py < y1 then seed(i + NX) end
    end
    return out
  end

  -- The mask -- darkest-pixel outline plus its enclosure, with the dither
  -- rule as fallback -- computed per CELL BAND of NX rows.
  --
  -- A square canvas is ONE band, so this is exactly the whole-canvas rule
  -- it replaces. A STACKED canvas needs it per band because its two halves
  -- want opposite answers: the potted plant's leaf crown is a black-outlined
  -- dither drawn over floor (outline enclosure keeps it), while its pot is a
  -- solid DARK body whose base runs flush to the band's bottom edge (the
  -- enclosure flood walks in through dark and guts it, and the fallback --
  -- which the band's own `enclosed` count asks for -- keeps it). Measured on
  -- the Center plant: one flood over both bands keeps 53% of the drawing and
  -- leaves the pot a hollow black frame; per band keeps 68% and both read.
  local mask = {}
  for band = 0, NY / NX - 1 do
    local y0, y1 = band * NX, band * NX + NX - 1
    local out = floodOutside({ off = true, dark = true,
                               light = true, white = true }, y0, y1)
    local enclosed = 0
    for i = y0 * NX, (y1 + 1) * NX - 1 do
      if not out[i] then
        mask[i] = true
        if cls[i] ~= "black" then enclosed = enclosed + 1 end
      end
    end
    if enclosed < NX * NX / 8 then
      out = floodOutside({ off = true, light = true, white = true }, y0, y1)
      for i = y0 * NX, (y1 + 1) * NX - 1 do
        mask[i] = (not out[i] and cls[i] ~= "off") or nil
      end
    end
  end
  local any = nil
  for i = 0, NX * NY - 1 do any = any or mask[i] end
  if not any then return {} end

  -- a CAPPED hull (the stump): the top capRows rows of the mask are the
  -- drawn cut face -- a surface seen at an angle, not body. Strip them
  -- from the mask and remember their art span; the top-face quads below
  -- project that ellipse across the round cap.
  local capY0, capY1 = nil, nil
  if capRows and capRows > 0 then
    local top = nil
    for iy = 0, NY - 1 do
      for ix = 0, NX - 1 do
        if mask[iy * NX + ix] then top = iy break end
      end
      if top then break end
    end
    if top then
      capY0 = top
      capY1 = math.min(top + capRows - 1, NY - 2)
      for iy = capY0, capY1 do
        for ix = 0, NX - 1 do mask[iy * NX + ix] = nil end
      end
      any = nil
      for i = 0, NX * NY - 1 do any = any or mask[i] end
      if not any then return {} end
    end
  end

  -- a FLAT-BASED hull (the can): the bottom baseRows rows of the mask are
  -- the BASE circle's front arc -- the drawing's mirror of the cut face
  -- above, ground contact seen from above rather than body. A can is only
  -- round in the horizontal plane, so the drop those rows make toward the
  -- middle is DEPTH, not a narrowing of the plan: left as body they revolve
  -- into ever smaller discs and the can ends up balanced on a stem three
  -- voxels wide (which is exactly what the first build did). Strip them and
  -- the foot rule below runs the last body row's full disc straight to the
  -- floor; the rows keep their own texels there, so the front view is still
  -- the drawing, base rim and all.
  local baseArt = nil
  if baseRows and baseRows > 0 then
    local bot = nil
    for iy = NY - 1, 0, -1 do
      for ix = 0, NX - 1 do
        if mask[iy * NX + ix] then bot = iy break end
      end
      if bot then break end
    end
    if bot then
      baseArt = {}
      for iy = math.max(bot - baseRows + 1, (capY1 or -1) + 2), bot do
        for ix = 0, NX - 1 do
          local i = iy * NX + ix
          if mask[i] then baseArt[i] = true end
          mask[i] = nil
        end
      end
      any = nil
      for i = 0, NX * NY - 1 do any = any or mask[i] end
      if not any then return {} end
    end
  end

  -- The can's HEIGHT, and the one place this file departs from the drawing
  -- on purpose. Strictly un-projected, the drawing states a squat drum: cut
  -- the mouth ellipse off the top and the base circle off the bottom and
  -- barely two rows of straight side are left between them, because the GB
  -- artist spent most of a 16px cell on the opening. A real bin is TALLER
  -- than it is wide, and the flat game reads as one because the drawing is
  -- 14px tall next to a 16px player -- so the height is authored (can_height
  -- voxels) rather than measured, and the surviving body band is repeated
  -- upward to fill it, bottom row first, which continues the drawn rib
  -- rhythm instead of inventing a texel. Everything else still comes off
  -- the pixels.
  local artRow = {}
  if bodyRows and bodyRows > 0 then
    local body = {}
    for iy = 0, NY - 1 do
      for ix = 0, NX - 1 do
        if mask[iy * NX + ix] then body[#body + 1] = iy break end
      end
    end
    local nb = #body
    if nb > 0 then
      local top = body[1]
      for iy = top - 1, math.max(NY - bodyRows, 0), -1 do
        -- the LOWEST surviving body row, repeated: it is the widest and
        -- plainest reading of the material (outline, shaded flank, lit
        -- face) and stacks into a clean metal cylinder. Cycling the whole
        -- surviving band instead stacks the drawn rim arcs into a barcode
        -- of hoops, which is detail the drawing never states about the
        -- side of the can.
        local from = body[nb]
        artRow[iy] = from
        for ix = 0, NX - 1 do
          mask[iy * NX + ix] = mask[from * NX + ix]
        end
      end
    end
  end

  -- the ground the ball stands on: the drawing's own background names
  -- it. Score every flat ground tile the map places against the cell's
  -- unmasked light pixels and keep the closest -- mid-forest trees have
  -- no flat neighbour to vote with, and the commonest-ground fallback
  -- paints pale path under trees whose art sits on grass. Dark unmasked
  -- pixels (the drawn cast shadow) stay out of the score: no ground
  -- tile carries a shadow, and their darks would drag every match.
  local bg = nil
  if groundTiles and #groundTiles > 0 then
    local bestScore = nil
    for _, t in ipairs(groundTiles) do
      local ox = (t % perRow) * 8
      local oy = math.floor(t / perRow) * 8
      local score, n = 0, 0
      for py = 0, NY - 1 do
        for px = 0, NX - 1 do
          local i = py * NX + px
          local c = cls[i]
          -- a stripped base row is the OBJECT's own rim, not background:
          -- scoring its whites against the floor tiles matches paper-white
          -- ground under a can whose art stands on the gym's grey
          if not mask[i] and not (baseArt and baseArt[i])
             and (c == "light" or c == "white") then
            local ax, ay = texel(px, py)
            local r1, g1, b1 = data:getPixel(ax, ay)
            local r2, g2, b2 = data:getPixel(ox + px % 8, oy + py % 8)
            local dr, dg, db = r1 - r2, g1 - g2, b1 - b2
            score = score + dr * dr + dg * dg + db * db
            n = n + 1
          end
        end
      end
      if n > 0 then
        score = score / n
        if not bestScore or score < bestScore then bestScore, bg = score, t end
      end
    end
  end

  -- discs: per mask pixel a z chord [z0, z1), from its row's span circle.
  -- z2/z3 is an optional SECOND chord for the same pixel, which only the
  -- can's hollow mouth uses: a ring in plan needs a front wall and a back
  -- wall at the same column, and one interval cannot say that.
  local z0, z1, z2, z3, src, srcX = {}, {}, {}, {}, {}, {}
  local loRow, hiRow = {}, {}
  local yBot = nil
  for iy = 0, NY - 1 do
    local lo, hi = nil, nil
    for ix = 0, NX - 1 do
      if mask[iy * NX + ix] then
        lo = lo or ix
        hi = ix
      end
    end
    if lo then
      loRow[iy], hiRow[iy] = lo, hi
      yBot = iy
      local c = (lo + hi + 1) / 2
      local hw = (hi - lo + 1) / 2
      for ix = lo, hi do
        local i = iy * NX + ix
        if mask[i] then
          local dx = ix + 0.5 - c
          local n = 1
          if hw * hw > dx * dx then
            n = math.max(1, math.floor(2 * math.sqrt(hw * hw - dx * dx)
                                       + 0.5))
          end
          if spray and iy < spray.rows then n = math.min(n, spray.depth) end
          if squash then n = math.max(1, math.floor(n * squash / 100 + 0.5)) end
          z0[i] = math.floor(N2 - n / 2 + 0.5)
          z1[i] = z0[i] + n
          -- a row the can's body band was repeated into wears the row it
          -- was copied from, never a texel of its own
          src[i] = artRow[iy] or iy
        end
      end
    end
  end

  -- Spray-gap BACKING: the drawing's own gap pixels, one voxel deep at
  -- the slab's mid-plane. The flat crown is full of floor showing
  -- between leaves; carved as an open slab those gaps became TUNNELS --
  -- the Center couch, the man sitting on it and the void wall all read
  -- as pink/orange/black confetti INSIDE the foliage, and the sparse
  -- bottom rows (lone drawn leaf tips) floated as disconnected specks
  -- against them. The drawing itself backs every gap with its own
  -- pixels, so the hull does the same: each in-span gap below drawn
  -- foliage takes ITS OWN texel as a plate recessed behind the leaf
  -- relief. Coverage is monotone down a column, so the first backed
  -- cell always sits directly under a leaf chord -- and every chord
  -- spans the mid-plane, so no plate ever caps the crown's top: columns
  -- open to the sky stay open and the silhouette keeps its notches.
  if spray then
    for iy = 1, math.min(spray.rows, NY) - 1 do
      if loRow[iy] then
        for ix = loRow[iy], hiRow[iy] do
          local i = iy * NX + ix
          if not z0[i] then
            local covered = false
            for iy2 = 0, iy - 1 do
              if mask[iy2 * NX + ix] then covered = true break end
            end
            if covered then
              z0[i], z1[i], src[i] = N2, N2 + 1, iy
            end
          end
        end
      end
    end
  end

  -- foot: rows under the mask repeat the bottom row's discs, wearing the
  -- bottom row's (outline-dark) pixels -- except where a stripped base row
  -- DREW something at that pixel, which keeps its own texel, so a can's
  -- drawn base rim lands on the model's base instead of being painted over
  -- by the body band above it
  for iy = yBot + 1, NY - 1 do
    loRow[iy], hiRow[iy] = loRow[yBot], hiRow[yBot]
    for ix = loRow[yBot], hiRow[yBot] do
      local b = yBot * NX + ix
      if z0[b] then
        local i = iy * NX + ix
        z0[i], z1[i] = z0[b], z1[b]
        src[i] = (baseArt and baseArt[i]) and iy or yBot
      end
    end
  end

  -- the TAPER: a bin is a truncated cone, not a tube -- wide at the rim,
  -- drawn in a couple of voxels toward the base. The drawing agrees as far
  -- as it can (its own base arc pulls in to 9px from the 11px flanks), but
  -- it cannot state the whole run, so taperVox is the diameter the base
  -- loses and the rows in between interpolate. Every row keeps its plan
  -- ROUND: narrow the span, then re-cut the chords from the narrowed span,
  -- or the model comes out a cylinder with its corners shaved.
  local stepped = {}
  if taperVox and taperVox > 0 then
    local yTopRow = nil
    for iy = 0, NY - 1 do
      if loRow[iy] then yTopRow = iy break end
    end
    local span = NY - 1 - (yTopRow or 0)
    if yTopRow and span > 0 then
      for iy = yTopRow, NY - 1 do
        local inset = math.floor(taperVox / 2 * (iy - yTopRow) / span + 0.5)
        if inset > 0 and loRow[iy] then
          local lo = loRow[iy] + inset
          local hi = hiRow[iy] - inset
          if hi - lo < 1 then
            lo = math.floor((loRow[iy] + hiRow[iy]) / 2)
            hi = lo + 1
          end
          for ix = loRow[iy], hiRow[iy] do
            if ix < lo or ix > hi then
              local i = iy * NX + ix
              z0[i], z1[i], z2[i], z3[i] = nil, nil, nil, nil
            end
          end
          -- squeeze the row's ART into the narrowed span rather than
          -- clipping its ends off: the drawn outline is the last column
          -- either side, and dropping it leaves the taper's new edge
          -- wearing an interior texel -- a white chip down the rim
          for ix = lo, hi do
            srcX[iy * NX + ix] = loRow[iy]
              + math.floor((ix - lo) * (hiRow[iy] - loRow[iy])
                           / (hi - lo) + 0.5)
          end
          loRow[iy], hiRow[iy] = lo, hi
          stepped[iy] = true
          local c = (lo + hi + 1) / 2
          local hw = (hi - lo + 1) / 2
          for ix = lo, hi do
            local i = iy * NX + ix
            if z0[i] then
              local dx = ix + 0.5 - c
              local n = 1
              if hw * hw > dx * dx then
                n = math.max(1, math.floor(2 * math.sqrt(hw * hw - dx * dx)
                                           + 0.5))
              end
              if squash then
                n = math.max(1, math.floor(n * squash / 100 + 0.5))
              end
              z0[i] = math.floor(N2 - n / 2 + 0.5)
              z1[i] = z0[i] + n
            end
          end
        end
      end
    end
  end

  -- the MOUTH: a bin is open, and a solid top wearing the drawn opening
  -- only paints one. Hollow the top wellRows voxel rows -- every chord
  -- long enough to hold two walls plus a gap keeps a wall at each end and
  -- loses its middle, which is a ring in plan, so the model has a real rim
  -- to look into. The short chords at the left and right of the row ARE
  -- the ring's sides and stay solid on their own.
  local wellTop = nil
  if wellRows and wellRows > 0 then
    for iy = 0, NY - 1 do
      if loRow[iy] then wellTop = iy break end
    end
    local wall = 2
    for iy = wellTop or 0, math.min((wellTop or 0) + wellRows - 1, NY - 1) do
      if loRow[iy] then
        for ix = loRow[iy], hiRow[iy] do
          local i = iy * NX + ix
          if z0[i] and z1[i] - z0[i] > wall * 2 then
            z2[i], z3[i] = z1[i] - wall, z1[i]
            z1[i] = z0[i] + wall
          end
        end
      end
    end
  end

  -- the round cap's top row and z extent, for the stump's ring
  -- projection below
  local capTopRow, capZ0, capZ1 = nil, nil, nil
  if capY0 then
    for iy = 0, NY - 1 do
      if loRow[iy] then capTopRow = iy break end
    end
    if capTopRow then
      for ix = loRow[capTopRow], hiRow[capTopRow] do
        local i = capTopRow * NX + ix
        if z0[i] then
          -- the OUTER extent, so a hollowed row still projects the mouth
          -- across the whole opening and not just its front wall
          local back = z3[i] or z1[i]
          capZ0 = math.min(capZ0 or z0[i], z0[i])
          capZ1 = math.max(capZ1 or back, back)
        end
      end
    end
  end

  -- the art row the mouth projection puts at depth iz -- the drawn
  -- opening's north arc at the far side of the hull, its south arc at the
  -- near one. The top-face pass below reads the same mapping; this is the
  -- vertical faces inside the well asking it the same question.
  local function mouthRow(iz)
    if not (capY0 and capZ0 and capZ1) then return 0 end
    local t = capZ1 - 1 > capZ0 and (iz - capZ0) / (capZ1 - 1 - capZ0) or 0
    t = math.max(0, math.min(1, t))
    return capY0 + math.floor(t * (capY1 - capY0) + 0.5)
  end

  local function solidAt(ix, iy, iz)
    if ix < 0 or ix > NX - 1 or iy < 0 or iy > NY - 1 then return false end
    local i = iy * NX + ix
    if z0[i] == nil then return false end
    if iz >= z0[i] and iz < z1[i] then return true end
    return z2[i] ~= nil and iz >= z2[i] and iz < z3[i]
  end

  -- cap interiors sample the canopy a couple of rows below the rim,
  -- skipping outline-dark pixels
  local function deepTexel(ix, iy)
    for iy2 = iy + 2, math.min(NY - 1, iy + 4) do
      local i = iy2 * NX + ix
      if mask[i] and cls[i] ~= "black" then return texel(ix, iy2) end
    end
    return texel(ix, iy)
  end

  -- side walls read as material, not outline: walk inward past black
  -- pixels (the building extruder's de-outline rule). The silhouette's
  -- edge columns are all outline, and without this every flank of the
  -- ball paints solid black the moment the camera turns. The foot rows
  -- stay dark on purpose: their whole source row is outline-black.
  local function sideTexel(ix, iy)
    -- A foot row's SIDE keeps the last body row's material even where its
    -- FRONT wears a stripped base row (the can). The drawn base rim is
    -- front-face art; walking the de-outline inside a row that is no longer
    -- in the mask breaks at once and hands back the silhouette's own
    -- outline, which painted every flank of the can solid black.
    local r = (yBot and iy > yBot) and yBot or src[iy * NX + ix]
    -- the walk runs in ART columns, so a tapered row starts from the drawn
    -- pixel its squeezed span put here rather than from the model column
    local a = srcX[iy * NX + ix] or ix
    local dir = ix + ix < loRow[iy] + hiRow[iy] and 1 or -1
    for step = 0, 3 do
      local x2 = a + dir * step
      local i2 = r * NX + x2
      if x2 < 0 or x2 > NX - 1 or not mask[i2] then break end
      if cls[i2] ~= "black" then return texel(x2, r) end
    end
    return texel(a, r)
  end

  local quads = {}

  for iy = 0, NY - 1 do
    if loRow[iy] then
      local yB, yT = NY - 1 - iy, NY - iy

      -- front and back: the drawing per-pixel, columns merged where they
      -- share a chord plane; a run never crosses the 8px atlas tile seam
      -- (its u range must interpolate inside one tile)
      local ix = loRow[iy]
      while ix <= hiRow[iy] do
        local i = iy * NX + ix
        if z0[i] then
          local ix2 = ix
          while ix2 + 1 <= hiRow[iy] do
            local j = iy * NX + ix2 + 1
            -- src too: a can's foot row draws part of its span from the
            -- stripped base rim and the rest from the body band above it,
            -- so a run must not straddle two source rows (the u range is
            -- interpolated from one row's texels)
            if z0[j] == z0[i] and z1[j] == z1[i] and src[j] == src[i]
               and z2[j] == z2[i] and z3[j] == z3[i]
               and math.floor((ix2 + 1) / 8) == math.floor(ix / 8) then
              ix2 = ix2 + 1
            else
              break
            end
          end
          local x0, x1 = ix - N2, ix2 - N2 + 1
          -- one facing pair per chord, each face given the art row it
          -- should wear. A hollowed mouth row has two chords, and the two
          -- faces that look into the well take the drawn OPENING (via the
          -- same projection the rim does) rather than the body band: the
          -- drawing paints its mouth dark, and an inside-out white wall
          -- across the opening is the one thing that stops a bin reading
          -- as a bin.
          local function facing(za, zb, rowF, rowB)
            local zF, zB = zb - N2, za - N2
            local function pair(z, row, shade, back)
              local ax0, ay = texel(srcX[i] or ix, row)
              local ax1 = (texel(srcX[iy * NX + ix2] or ix2, row))
              local u0, u1 = (ax0 + 0.05) / atlasW, (ax1 + 0.95) / atlasW
              local v0, v1 = (ay + 0.05) / atlasH, (ay + 0.95) / atlasH
              if back then
                quads[#quads + 1] = {
                  { x1, yB, z }, { x0, yB, z }, { x0, yT, z }, { x1, yT, z },
                  uv = { { u1, v1 }, { u0, v1 }, { u0, v0 }, { u1, v0 } },
                  shade = shade,
                }
              else
                quads[#quads + 1] = {
                  { x0, yB, z }, { x1, yB, z }, { x1, yT, z }, { x0, yT, z },
                  uv = { { u0, v1 }, { u1, v1 }, { u1, v0 }, { u0, v0 } },
                  shade = shade,
                }
              end
            end
            pair(zF, rowF, ROUND_SHADE.front, false)
            pair(zB, rowB, ROUND_SHADE.back, true)
          end
          local body = src[i]
          if z2[i] then
            -- z grows toward the viewer: the low chord is the can's FAR
            -- wall, so its +z face is the inside you look across, and the
            -- near chord's -z face is the inside of the wall facing you
            facing(z0[i], z1[i], mouthRow(z1[i]), body)
            facing(z2[i], z3[i], body, mouthRow(z2[i] - 1))
          else
            facing(z0[i], z1[i], body, body)
          end
          ix = ix2 + 1
        else
          ix = ix + 1
        end
      end

      -- sides, steps, undersides: constant-texel quads over the z runs a
      -- neighbour doesn't cover
      for ix = loRow[iy], hiRow[iy] do
        local i = iy * NX + ix
        if z0[i] then
          local ax, ay = texel(srcX[i] or ix, src[i])
          local u, v = (ax + 0.5) / atlasW, (ay + 0.5) / atlasH
          local x0, x1 = ix - N2, ix - N2 + 1

          -- exposed z pieces against one neighbouring column, over each of
          -- the pixel's chords (a hollowed mouth row has two)
          local function chordPieces(nx, ny, emit, zLo, zHi)
            local iz = zLo
            while iz < zHi do
              if not solidAt(nx, ny, iz) then
                local iz2 = iz
                while iz2 + 1 < zHi and not solidAt(nx, ny, iz2 + 1) do
                  iz2 = iz2 + 1
                end
                emit(iz - N2, iz2 - N2 + 1, iz, iz2)
                iz = iz2 + 1
              else
                iz = iz + 1
              end
            end
          end
          local function pieces(nx, ny, emit)
            chordPieces(nx, ny, emit, z0[i], z1[i])
            if z2[i] then chordPieces(nx, ny, emit, z2[i], z3[i]) end
          end

          local sax, say = sideTexel(ix, iy)
          local su, sv = (sax + 0.5) / atlasW, (say + 0.5) / atlasH
          pieces(ix - 1, iy, function(zA, zB)
            quads[#quads + 1] = {
              { x0, yB, zA }, { x0, yB, zB }, { x0, yT, zB }, { x0, yT, zA },
              u = su, v = sv, shade = ROUND_SHADE.side,
            }
          end)
          pieces(ix + 1, iy, function(zA, zB)
            quads[#quads + 1] = {
              { x1, yB, zB }, { x1, yB, zA }, { x1, yT, zA }, { x1, yT, zB },
              u = su, v = sv, shade = ROUND_SHADE.side,
            }
          end)
          pieces(ix, iy - 1, function(zA, zB, izA, izB)
            local function top(za, zb, tu, tv)
              quads[#quads + 1] = {
                { x0, yT, za }, { x1, yT, za }, { x1, yT, zb }, { x0, yT, zb },
                u = tu, v = tv, shade = ROUND_SHADE.top,
              }
            end
            -- the whole hollowed band takes the projection, not just its
            -- top row: the rim ring gets the mouth's outer arcs and the
            -- floor of the well gets its middle, so looking in reads as
            -- one opening rather than a lid with a hole punched in it
            if capTopRow and capZ1
               and iy >= capTopRow and iy <= capTopRow + (wellRows or 0) then
              -- the CUT FACE (a capped hull's top): project the drawn
              -- ellipse across the round cap voxel row by voxel row --
              -- its top arc at the cap's north rim, its bottom arc at
              -- the south, the perspective the 2D art already implies
              for iz = izA, izB do
                local t = capZ1 - 1 > capZ0
                          and (iz - capZ0) / (capZ1 - 1 - capZ0) or 0
                local ry = capY0 + math.floor(t * (capY1 - capY0) + 0.5)
                local cax, cay = texel(srcX[i] or ix, ry)
                top(iz - N2, iz - N2 + 1,
                    (cax + 0.5) / atlasW, (cay + 0.5) / atlasH)
              end
            elseif izA == z0[i] and izB == z1[i] - 1 and izB - izA >= 2 then
              -- the dome cap: outline on the rim cells, canopy inside
              local du, dv = deepTexel(ix, iy)
              top(zA, zA + 1, u, v)
              top(zA + 1, zB - 1, (du + 0.5) / atlasW, (dv + 0.5) / atlasH)
              top(zB - 1, zB, u, v)
            elseif stepped[iy] then
              -- a taper STEP: the chord narrowing leaves a ring facing up
              -- at the front of the can, and wearing the lit body band it
              -- reads as a bright chip taken out of the wall. The drawing's
              -- own rim column is black, so the step wears that and the
              -- taper reads as a hoop line -- which is how the reference
              -- object is banded anyway.
              local rx = srcX[iy * NX + loRow[iy]] or loRow[iy]
              local rax, ray = texel(rx, src[i])
              top(zA, zB, (rax + 0.5) / atlasW, (ray + 0.5) / atlasH)
            else
              top(zA, zB, u, v)
            end
          end)
          if iy < NY - 1 then
            pieces(ix, iy + 1, function(zA, zB)
              quads[#quads + 1] = {
                { x0, yB, zB }, { x1, yB, zB }, { x1, yB, zA }, { x0, yB, zA },
                u = u, v = v, shade = ROUND_SHADE.bottom,
              }
            end)
          end
        end
      end
    end
  end
  return quads, bg
end

-- Hull templates dedupe GLOBALLY per (tileset, four tiles, ground set):
-- the same four-tile tree repeats for hundreds of cells on a map and
-- across every route of its tileset, so the carve runs once per distinct
-- drawing per session.  What a map keeps is a STAMP LIST -- (template,
-- cell offset) pairs the mesher expands while packing vertices -- rather
-- than materialized per-cell quad tables, which retained ~500 quads x
-- hundreds of tree cells x six Lua tables each PER MAP (the multi-GB
-- heap growth on a cross-region trek).
local roundCache = {}

local function buildCylinders(S, map, x0, x1, y0, y1, data, groundTiles)
  local tw, th = map.def.width * 4, map.def.height * 4

  -- ground-set fingerprint: the template's art-matched floor depends on
  -- which ground tiles this map places, so maps sharing a tileset but
  -- not a palette of floors carve separately
  local gsig
  do
    local g = {}
    for i, t in ipairs(groundTiles or {}) do g[i] = t end
    table.sort(g)
    gsig = table.concat(g, ",")
  end
  local tsid = tostring(map.tileset.id or map.tileset.image or "?")

  -- the stump class's drawn-ellipse height, hand-authored per tileset
  -- (the profile's stump_cap, in art rows), and the can class's three: the
  -- mouth ellipse over the top (can_cap) and the base ellipse under the
  -- bottom (can_base), both in art rows, plus the authored can_height in
  -- voxels the body band is repeated up to
  local stumpCap, canCap, canBase, canHeight, canWell, canTaper
    = 6, 9, 4, 9, 5, 4
  -- the sapling class's depth, as a PERCENT of the revolved chord
  local saplingSquash = 50
  do
    local okP, prof = pcall(V.data, "voxel_heights")
    local entry = okP and type(prof) == "table" and prof.tilesets
                  and prof.tilesets[map.tileset.id]
    if entry and type(entry.stump_cap) == "number" then
      stumpCap = entry.stump_cap
    end
    if entry and type(entry.can_cap) == "number" then
      canCap = entry.can_cap
    end
    if entry and type(entry.can_base) == "number" then
      canBase = entry.can_base
    end
    if entry and type(entry.can_height) == "number" then
      canHeight = entry.can_height
    end
    if entry and type(entry.can_well) == "number" then
      canWell = entry.can_well
    end
    if entry and type(entry.can_taper) == "number" then
      canTaper = entry.can_taper
    end
    if entry and type(entry.sapling_squash) == "number" then
      saplingSquash = entry.sapling_squash
    end
  end

  -- cells consumed by a 2x2 `canopy` group; the scan runs north to
  -- south, west to east, so an anchor always claims its partners
  -- before they are visited
  local grouped = {}
  for cy = math.floor(y0 / 2), math.floor(y1 / 2) do
    for cx = math.floor(x0 / 2), math.floor(x1 / 2) do
      Budget.tick()
      local ckey = cy * 8192 + cx
      local k = keyOf(cx * 2, cy * 2)
      local s = (not grouped[ckey]) and S.shapeAt[k] or nil
      local near = cx * 2 >= -ROUND_RING and cx * 2 < tw + ROUND_RING
               and cy * 2 >= -ROUND_RING and cy * 2 < th + ROUND_RING
      if s and s.art == "canopy" and near then
        -- ONE 32px hull over the 2x2-cell drawing. The partner cells
        -- must be round-pinned too, or the drawing is partial (a map
        -- edit, a mod's stray anchor tile) and the anchor is left
        -- alone rather than carved into a half-empty giant.
        local whole = true
        for _, d in ipairs({ { 1, 0 }, { 0, 1 }, { 1, 1 } }) do
          local ps = S.shapeAt[keyOf((cx + d[1]) * 2, (cy + d[2]) * 2)]
          if not (ps and (ps.art == "cylinder" or ps.art == "canopy")) then
            whole = false
          end
        end
        if whole then
          local ground = false
          if data then
            local ids = {}
            for dy = 0, 3 do
              for dx = 0, 3 do
                ids[#ids + 1] = S.tileAt[keyOf(cx * 2 + dx, cy * 2 + dy)]
              end
            end
            local sig = tsid .. "|g32|" .. gsig .. "|"
                        .. table.concat(ids, ":")
            local tpl = roundCache[sig]
            if not tpl then
              local tq, tbg = roundTemplate(S, map, data, cx, cy,
                                            groundTiles, 32)
              tpl = { quads = tq, bg = tbg }
              roundCache[sig] = tpl
            end
            ground = tpl.bg or false
            S.roundStamps[#S.roundStamps + 1] =
              { quads = tpl.quads, mx = cx * 16 + 16, mz = cy * 16 + 16,
                r = 16 }
          end
          for dy = 0, 3 do
            for dx = 0, 3 do
              local tk = keyOf(cx * 2 + dx, cy * 2 + dy)
              S.skip[tk] = true
              S.ground[tk] = ground
            end
          end
          grouped[ckey + 1] = true
          grouped[ckey + 8192] = true
          grouped[ckey + 8193] = true
        end
      elseif s and s.art == "planter" and near then
        -- ONE 16x32x16 hull over a drawing stacked TWO CELLS HIGH on one
        -- cell of plot: the Pokemon Centers' potted plants (a leaf crown
        -- over a flared pot, 78 placements across 13 maps).
        --
        -- The anchor is the NORTH cell -- the crown, where the canvas
        -- starts -- but the hull stands in the SOUTH cell, because that is
        -- where the pot is drawn and an object's ground contact is its
        -- plot. The crown is therefore HEIGHT, not depth: the north cell
        -- is claimed and left as floor for the crown to overhang, which is
        -- what un-projecting the 3/4 view means here. Pinning only one of
        -- the two cells leaves the drawing partial (a map edit, a mod's
        -- stray tile), so the anchor is left alone rather than carved into
        -- half a plant.
        local below = S.shapeAt[keyOf(cx * 2, (cy + 1) * 2)]
        if below and below.art == "planter" then
          local ground = false
          if data then
            local ids = {}
            for dy = 0, 3 do
              for dx = 0, 1 do
                ids[#ids + 1] = S.tileAt[keyOf(cx * 2 + dx, cy * 2 + dy)]
              end
            end
            local sig = tsid .. "|p32|" .. gsig .. "|"
                        .. table.concat(ids, ":")
            local tpl = roundCache[sig]
            if not tpl then
              local tq, tbg = roundTemplate(S, map, data, cx, cy,
                                            groundTiles, 16, nil, 32,
                                            PLANTER_SPRAY)
              tpl = { quads = tq, bg = tbg }
              roundCache[sig] = tpl
            end
            ground = tpl.bg or false
            S.roundStamps[#S.roundStamps + 1] =
              { quads = tpl.quads, mx = cx * 16 + 8,
                mz = (cy + 1) * 16 + 8 }
          end
          for dy = 0, 3 do
            for dx = 0, 1 do
              local tk = keyOf(cx * 2 + dx, cy * 2 + dy)
              S.skip[tk] = true
              S.ground[tk] = ground
            end
          end
          grouped[ckey + 8192] = true
        end
      elseif s and s.art == "cylinder" and near then
        -- a `stump`-class cell is the same hull with a cut face: its
        -- top capRows of drawing project onto the round top. A `can`-class
        -- cell is that hull cut at BOTH ends -- lid on top, base circle on
        -- the floor -- which is what a drum standing on a floor is.
        local cap = (s.class == "stump" and stumpCap)
                    or (s.class == "can" and canCap) or nil
        local base = s.class == "can" and canBase or nil
        local tall = s.class == "can" and canHeight or nil
        local well = s.class == "can" and canWell or nil
        local taper = s.class == "can" and canTaper or nil
        -- 100% is the full revolve, so it is the identity: never signed
        -- into the cache key, and never passed, by a class that has no
        -- squash of its own
        local squash = (s.class == "sapling" and saplingSquash ~= 100)
                       and saplingSquash or nil
        local ground = false
        if data then
          local sig = tsid .. (cap and ("|c" .. cap) or "")
            .. (base and ("|b" .. base) or "")
            .. (tall and ("|h" .. tall) or "")
            .. (well and ("|w" .. well) or "")
            .. (taper and ("|t" .. taper) or "")
            .. (squash and ("|q" .. squash) or "") .. "|"
            .. gsig .. "|" .. table.concat({
            S.tileAt[k], S.tileAt[keyOf(cx * 2 + 1, cy * 2)],
            S.tileAt[keyOf(cx * 2, cy * 2 + 1)],
            S.tileAt[keyOf(cx * 2 + 1, cy * 2 + 1)] }, ":")
          local tpl = roundCache[sig]
          if not tpl then
            local tq, tbg = roundTemplate(S, map, data, cx, cy,
                                          groundTiles, 16, cap, nil, nil,
                                          base, tall, well, taper, squash)
            tpl = { quads = tq, bg = tbg }
            roundCache[sig] = tpl
          end
          ground = tpl.bg or false
          S.roundStamps[#S.roundStamps + 1] =
            { quads = tpl.quads, mx = cx * 16 + 8, mz = cy * 16 + 8 }
        end
        -- headless (no pixels): no hull, but still claim the tiles so
        -- the volume path never boxes a pinned cell. Ground is the
        -- template's own art-matched tile; `false` (no match, headless)
        -- falls to the commonest-ground pass below.
        for dy = 0, 1 do
          for dx = 0, 1 do
            local tk = keyOf(cx * 2 + dx, cy * 2 + dy)
            S.skip[tk] = true
            S.ground[tk] = ground
          end
        end
      end
    end
  end
end

return buildCylinders