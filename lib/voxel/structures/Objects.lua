local V = ...

local Budget = V.require("util/BuildBudget")
local TileShape = V.require("voxel/TileShape")

-- ---- object mode: per-pixel voxelization of drawn props ----

-- object-mode gates
local OBJECT_MAX_ROWS = 6          -- a prop is at most 48px of drawing
local OBJECT_MAX_QUADS = 4096      -- safety cap per cluster
local TILE_BG_RATIO = 0.20         -- art background for "sprite-like"
local CLUSTER_MIN_BG = 0.05        -- a silhouette must actually exist
local OBJECT_DEPTH = 6             -- voxel thickness of a detected prop
-- thickness of profile-pinned standees per class: a TV is a deliberate
-- object and reads better with body; `prop` doubles as the THIN pool
-- (plants, stools -- mostly silhouette); `cutout` is paper: one voxel,
-- pure profile; `post` matches the 6px the detector gives the fence
-- rows it finds on its own, so pinned and detected fences look alike;
-- `signpost` is a plate on a stick -- 2 voxels, the thinnest that still
-- shows an edge; `bike` is the same 2 for the same reason from the other
-- direction -- a bicycle drawn side-on is a LINE drawing whose negative
-- space is the drawing, and at the 5 voxels `prop` gives, the side faces
-- of neighbouring strokes close every gap in it off-axis
local PINNED_DEPTH = { billboard = 10, prop = 5, stool = 10, cutout = 1,
                       console = 10, post = 6, signpost = 2, bike = 2 }

local DIRS4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function keyOf(tx, ty)
  return (ty + 64) * 4096 + (tx + 64)
end

local OBJ_SHADE = { front = 1.0, back = 0.68, side = 0.78,
                    top = 1.0, bottom = 0.55 }

-- The four GB shades, by a pixel's darkest channel.  Force-mode
-- segmentation reasons in these: black is always outline/object, the
-- other three are background only where they touch the cluster's edge.
local function shadeClass(v)
  if v <= 0.25 then return "black" end
  if v <= 0.55 then return "dark" end
  if v <= 0.85 then return "light" end
  return "white"
end

-- One sprite-like cluster -> a per-pixel voxel prism, or false when it
-- fails validation (too tall, vertically repeating, too big) and should
-- stay part of the volume.
local function buildObject(S, map, region, cluster,
                                state, flooded, srcU, srcV, W, force)
  local rows = cluster.maxY - cluster.minY + 1
  if not force then
    if rows > OBJECT_MAX_ROWS then return false end

    -- a prop stands ON the ground: somewhere the cluster must meet flat
    -- ground to its south. A cluster carved out of a structure's middle
    -- (roof rows whose whites leaked) fails this and stays in the volume.
    -- Indoors any side will do -- furniture backs onto walls and bottom-row
    -- props meet the void ring, so south alone is too strict.
    local dirs = S.outdoor and { { 0, 1 } } or DIRS4
    local touchesGround = false
    for _, c in ipairs(cluster.tiles) do
      for _, d in ipairs(dirs) do
        local ss = S.shapeAt[keyOf(c[1] + d[1], c[2] + d[2])]
        if ss and ss.flat and ss.class ~= "void" then
          touchesGround = true
          break
        end
      end
      if touchesGround then break end
    end
    if not touchesGround then return false end

    -- a vertically repeating cluster (tree wall edge) is scenery, not a
    -- prop
    local cols = {}
    for _, c in ipairs(cluster.tiles) do
      cols[c[1]] = cols[c[1]] or {}
      cols[c[1]][c[2]] = true
    end
    for tx, ys in pairs(cols) do
      local front = nil
      for y in pairs(ys) do front = math.max(front or y, y) end
      local extent = 0
      while ys[front - extent] do extent = extent + 1 end
      if extent > 1 then
        local t0 = map:tileAt(tx, front)
        for k = 1, extent - 1 do
          if map:tileAt(tx, front - k) == t0 then return false end
        end
      end
    end
  end

  local memberC = {}
  for _, c in ipairs(cluster.tiles) do memberC[keyOf(c[1], c[2])] = true end

  -- solid pixels of this cluster (art minus flooded background)
  local solidPx, count, bgCount = {}, 0, 0
  local bw = (cluster.maxX - cluster.minX + 1) * 8
  local bh = (cluster.maxY - cluster.minY + 1) * 8
  for _, c in ipairs(cluster.tiles) do
    local rx = (c[1] - region.minX) * 8
    local ry = (c[2] - region.minY) * 8
    for py = 0, 7 do
      Budget.tick()
      for px = 0, 7 do
        local i = (ry + py + 1) * W + (rx + px + 1)
        local on = state[i] ~= nil and state[i] ~= "air"
                   and state[i] ~= "iair" and state[i] ~= "barrier"
                   and not flooded[i]
        if on then
          local lx = (c[1] - cluster.minX) * 8 + px
          local ly = (c[2] - cluster.minY) * 8 + py
          solidPx[ly * bw + lx] = i
          count = count + 1
        else
          bgCount = bgCount + 1
        end
      end
    end
  end
  if count == 0 or count > OBJECT_MAX_QUADS then return false end
  if not force and bgCount / (count + bgCount) < CLUSTER_MIN_BG then
    return false
  end

  -- geometry: each solid pixel is one voxel column deep enough to read as
  -- a body, standing at the cluster's south row, base on the ground plane
  local depth = OBJECT_DEPTH
  if force then
    local cs = S.shapeAt[keyOf(cluster.tiles[1][1], cluster.tiles[1][2])]
    depth = (cs and PINNED_DEPTH[cs.class]) or PINNED_DEPTH.billboard
  end
  local wx0 = cluster.minX * 8

  -- A pinned prop drawn directly above an authored box stands ON it -- a
  -- monitor on its desk, a flower pot on the table.  The prism rises from
  -- the box's top with its feet on the box's north row, and the claimed
  -- tiles keep rendering as that box (wearing its plain art) instead of
  -- punching a floor-level hole through it.
  --
  -- Only when the prop's OWN CELL IS BLOCKED, though.  "Is something
  -- drawn above me?" is not the same question as "am I standing on it":
  -- a chair drawn against the north side of a table is above the table's
  -- trim row too, and it was being lifted onto the tabletop -- three
  -- chairs standing on the furniture in Cinnabar's trade room and
  -- Fuchsia's meeting room, with the claimed cells re-tiled as tabletop
  -- so the table marched two rows north with them.  The world already
  -- knows which is which: a thing that sits ON furniture occupies a
  -- blocked cell (you cannot walk through the gym statue, Red's plant,
  -- the PC), while a seat you walk up to is in a walkable one.
  --
  -- FENCE POSTS (the `post` pool, force == "opaque") never take the lift
  -- at all. A post stands in the ground by definition -- it is not a
  -- thing set down on top of something -- and its cell is blocked like
  -- any other post, so the test above cannot tell it apart. Lavender
  -- Town is where it showed: pinning the cliff's slope chain gave the
  -- posts along the cliff edge an authored 16px box to their south, and
  -- they were hoisted to stand on the clifftop instead of the path.
  local baseY, support, supportRow = 0, nil, nil
  if force and force ~= "opaque" then
    local belowK = keyOf(cluster.minX, cluster.maxY + 1)
    local bs = S.shapeAt[belowK]
    local blocked = not map:isWalkableCell(math.floor(cluster.minX / 2),
                                           math.floor(cluster.maxY / 2))
    -- `bookcase` supports as well as `upright`.  A prop drawn above an
    -- authored box stands ON it whatever art the box renders with, and a
    -- stacked box is still a box: the Plateau's gate pilasters carry a
    -- statue on 48 of their tops, and collapsing the pilaster to a stacked
    -- run made every one of them fail this test and drop to ground level.
    -- A `building` claim supports too, when it carries a height: a
    -- Buildings template that names `support` is furniture modelled in
    -- full with a standee left standing on it (Red's dining table under
    -- its potted plant), and the height it states is the model's top
    -- plane.  A plain claim stays at h = 0 and supports nothing.
    if blocked and bs and bs.authored and (bs.h or 0) > 0
       and (bs.art == "upright" or bs.art == "bookcase"
            or bs.class == "building") then
      baseY, support = bs.h, bs
      -- A bookcase support has MOVED: the collapse walks the whole drawn
      -- run onto its southmost cell, and the cell tested above is the run's
      -- north end.  On the Plateau's two-cell pilasters that is a full cell
      -- away, and the bird stood at the right HEIGHT over open ground with
      -- its pillar behind it -- floating.  Stand it on the box's own north
      -- row instead of one row south of its drawing.
      supportRow = S.bookcaseBox[belowK]
    end
  end
  local atlasW = map.tileset.imageWidth or 128
  local atlasH = map.tileset.imageHeight or 48
  local quads = S.objectQuads

  local function at(lx, ly)
    if lx < 0 or lx >= bw or ly < 0 or ly >= bh then return nil end
    return solidPx[ly * bw + lx]
  end

  -- Connected components: one cluster can hold several OBJECTS -- two
  -- stools stacked in adjacent cells, a loose leaf beside a vase.  Each
  -- component stands on its own feet (base on the ground or the support
  -- box, never floating at its bbox height) in the depth band of the
  -- tile row its lowest pixel is drawn in, so stacked drawings become
  -- separate standees in their own cells instead of one tower.
  -- 8-connectivity keeps diagonal strokes whole.
  local comp, comps = {}, {}
  for ly = 0, bh - 1 do
    Budget.tick()
    for lx = 0, bw - 1 do
      local idx = ly * bw + lx
      if solidPx[idx] and not comp[idx] then
        local c = { lowY = ly, n = 0 }
        comps[#comps + 1] = c
        local stack = { idx }
        comp[idx] = c
        while #stack > 0 do
          local p = table.remove(stack)
          local px, py = p % bw, math.floor(p / bw)
          c.n = c.n + 1
          if py > c.lowY then c.lowY = py end
          for dy = -1, 1 do
            for dx = -1, 1 do
              local nx, ny = px + dx, py + dy
              if (dx ~= 0 or dy ~= 0) and nx >= 0 and nx < bw
                 and ny >= 0 and ny < bh then
                local ni = ny * bw + nx
                if solidPx[ni] and not comp[ni] then
                  comp[ni] = c
                  stack[#stack + 1] = ni
                end
              end
            end
          end
        end
      end
    end
  end
  for _, c in ipairs(comps) do
    c.z0 = supportRow and (supportRow * 8 + (8 - depth) / 2)
           or (cluster.minY * 8 + math.floor(c.lowY / 8) * 8
               + (support and 8 or 0) + (8 - depth) / 2)
    c.z1 = c.z0 + depth
  end

  -- A `cutout` or `console` pin is ONE object by contract: keep only
  -- the largest connected drawing.  Loose black scraps -- a cast
  -- shadow's drawn edge, a seam, the vertical rules the surrounding
  -- furniture draws down its own edges -- are background even though
  -- black pixels always survive the shade flood, and this is what
  -- removes them.  Every other pool may hold several objects per
  -- cluster (two stools side by side, a leaf beside a vase), so this
  -- cannot be the default.
  if force then
    local cs = S.shapeAt[keyOf(cluster.tiles[1][1], cluster.tiles[1][2])]
    if cs and (cs.class == "cutout" or cs.class == "console")
       and #comps > 1 then
      local biggest = comps[1]
      for _, c in ipairs(comps) do
        if c.n > biggest.n then biggest = c end
      end
      for idx, c in pairs(comp) do
        if c ~= biggest then solidPx[idx] = nil end
      end
    end
  end

  for ly = 0, bh - 1 do
    Budget.tick()
    for lx = 0, bw - 1 do
      local i = at(lx, ly)
      if i then
        local c = comp[ly * bw + lx]
        local z0, z1 = c.z0, c.z1
        local x, y = wx0 + lx, baseY + c.lowY - ly
        local u = (srcU[i] + 0.5) / atlasW
        local v = (srcV[i] + 0.5) / atlasH
        local function quad(c1, c2, c3, c4, shade)
          quads[#quads + 1] = { c1, c2, c3, c4, u = u, v = v, shade = shade }
        end
        quad({ x, y, z1 }, { x + 1, y, z1 }, { x + 1, y + 1, z1 },
             { x, y + 1, z1 }, OBJ_SHADE.front)
        quad({ x + 1, y, z0 }, { x, y, z0 }, { x, y + 1, z0 },
             { x + 1, y + 1, z0 }, OBJ_SHADE.back)
        if not at(lx, ly - 1) then
          quad({ x, y + 1, z0 }, { x + 1, y + 1, z0 }, { x + 1, y + 1, z1 },
               { x, y + 1, z1 }, OBJ_SHADE.top)
        end
        if y > baseY and not at(lx, ly + 1) then
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

  -- the ground the prop stands on: the commonest flat tile touching the
  -- cluster, painted under every cluster tile (the art that was there is
  -- now standing up as the object)
  local votes, best, bestN = {}, nil, 0
  for _, c in ipairs(cluster.tiles) do
    for _, d in ipairs(DIRS4) do
      local nk = keyOf(c[1] + d[1], c[2] + d[2])
      local ns = S.shapeAt[nk]
      if ns and ns.flat and ns.class ~= "void" and not memberC[nk] then
        local t = S.tileAt[nk]
        votes[t] = (votes[t] or 0) + 1
        if votes[t] > bestN then best, bestN = t, votes[t] end
      end
    end
  end
  for _, c in ipairs(cluster.tiles) do
    local k = keyOf(c[1], c[2])
    if support and (support.class == "wall" or support.class == "cliff"
                    or support.art == "bookcase"
                    or support.class == "building") then
      -- a figure drawn above a FULL-HEIGHT block (the gym statue on its
      -- plinth) is a statue on a pillar with ONE cell of footprint: the
      -- block below already carries the whole base, so the drawn cell
      -- becomes synthesized floor rather than a second block marching
      -- the base backwards. Furniture supports (a monitor on its desk)
      -- keep the box-extension below -- their drawn cell is the
      -- furniture's own upper rows, and floor there would amputate it.
      --
      -- STRUCTURE, not height, decides which: `cliff` and `bookcase` are
      -- full-height blocks like `wall` and belong here, while `desk` is
      -- 24px and still furniture.  The Plateau's statues on stacked
      -- pilasters found this -- taking the furniture branch turned each
      -- statue's own two rows into a 32px box wearing the pilaster's art,
      -- so every one of them stood inside a slab of its own plinth.
      -- A `building` support belongs here too: the template's stamped
      -- model already carries every surface under the standee (that is
      -- what its `support` height asserts), so a box here would stand
      -- INSIDE the modelled tabletop.  Its stamp pre-painted the floor
      -- under these tiles, which the `or` keeps when no flat tile
      -- touches a cluster ringed by its own furniture.
      S.skip[k] = true
      S.ground[k] = best or S.ground[k]
    elseif support then
      -- the claimed tile keeps rendering as the box the prop stands on,
      -- wearing the art its own ROW would have without the drawing (the
      -- trim row stays trim); only when the whole row is the prop does
      -- it fall back to the row below
      S.shapeAt[k] = support
      local src = keyOf(c[1], cluster.maxY + 1)
      for dx = 1, 3 do
        for _, sx in ipairs({ c[1] - dx, c[1] + dx }) do
          local nk = keyOf(sx, c[2])
          local ns = S.shapeAt[nk]
          if not memberC[nk] and ns and ns.authored
             and ns.class == support.class then
            src = nk
            break
          end
        end
        if src ~= keyOf(c[1], cluster.maxY + 1) then break end
      end
      S.tileAt[k] = S.tileAt[src]
    else
      S.skip[k] = true
      S.ground[k] = best
    end
  end
  return true
end

-- Analyze one region's art against its surroundings, voxelize the
-- sprite-like clusters, and return the tiles that remain for volume mode.
-- `force` (profile-pinned billboards) voxelizes every tile of the region
-- unconditionally -- the pin IS the classification. `force = "opaque"`
-- (the `post` pool) keeps the decree -- every tile is a prop, aprons
-- seed the flood, validation is skipped -- but classifies pixels the way
-- the DETECTOR does (everything non-white is solid) instead of by
-- outline shade: a fence's mid browns are its body, and the outline
-- rule would strip the posts to black skeletons.
local function extractObjects(S, map, region, data, perRow, force)
  local bw = (region.maxX - region.minX + 1) * 8
  local bh = (region.maxY - region.minY + 1) * 8

  local member = {}
  for _, c in ipairs(region.tiles) do member[keyOf(c[1], c[2])] = true end

  -- Image over the region bbox plus a 1px ground apron. Pixel states:
  --   solid   opaque member art (non-white, or white that survives)
  --   cand    member white: background candidate, the flood decides
  --   air     ground the flood may travel: INSIDE the bbox (the gaps
  --           between fence posts), or the SOUTH apron row. This is the
  --           direction the viewer reads background from -- a prop's
  --           white meets the ground at its feet. OUTDOORS the other
  --           aprons are barriers on purpose: a building's roof stripes
  --           touch the grass BEHIND it, and a flood allowed to walk
  --           around the sides would pour in from the north and shred the
  --           roof into misdetected sprite clusters (it did). INDOORS all
  --           four aprons seed: furniture backs onto walls and bottom-row
  --           props meet the void ring, so the south row alone often
  --           cannot reach the background at all -- and there are no
  --           roofs inside to protect.
  --   barrier everything else
  local W, H = bw + 2, bh + 2
  local state = {}
  local srcU, srcV = {}, {}
  for iy = 0, H - 1 do
    for ix = 0, W - 1 do
      Budget.tick()
      local i = iy * W + ix
      local px, py = ix - 1, iy - 1
      local tx = region.minX + math.floor(px / 8)
      local ty = region.minY + math.floor(py / 8)
      local k = keyOf(tx, ty)
      local inside = px >= 0 and px < bw and py >= 0 and py < bh
      -- a forced (pinned) prop floods from every apron even when the
      -- neighbours are solid: the pin itself declares the art a prop
      -- whose whites are background -- a monitor pinned atop its desk has
      -- no flat neighbour anywhere to seed from
      local apron = iy == H - 1
        or ((force or not S.outdoor)
            and (iy == 0 or ix == 0 or ix == W - 1))
      if inside and member[k] then
        local tile = S.tileAt[k]
        local ax = (tile % perRow) * 8 + px % 8
        local ay = math.floor(tile / perRow) * 8 + py % 8
        srcU[i], srcV[i] = ax, ay
        local r, g, b, a = data:getPixel(ax, ay)
        if a == 0 then
          state[i] = "cand"
        elseif force and force ~= "opaque" then
          state[i] = shadeClass(math.min(r, g, b))
        else
          state[i] = math.min(r, g, b) > 0.83 and "cand" or "solid"
        end
      elseif inside or apron then
        if force then
          -- a pinned prop's surroundings are background BY DECREE -- the
          -- pin declares the drawing a prop even when every neighbour is
          -- solid furniture (a vase boxed in by its table).  Ring pixels
          -- seed the flood outright; interior non-member pixels ("iair")
          -- seed it too but never drain paint whites -- only a white run
          -- reaching the RING is background white.
          state[i] = inside and "iair" or "air"
        else
          local s = S.shapeAt[k]
          state[i] = (s and s.flat and s.class ~= "void") and "air"
                     or "barrier"
        end
      else
        state[i] = "barrier"
      end
    end
  end

  -- Forced (pinned) props are segmented the way the art is authored:
  -- objects wear a BLACK OUTLINE, and the background is whatever shades
  -- actually touch the cluster's edge -- the white floor around a TV,
  -- the grey tabletop around a vase.  Only those shades flood; the
  -- outline, its interior, the drawing's paint whites and anything they
  -- enclose all survive as the object.
  --
  -- The `cutout` pool is STRICTER, per the pure-profile contract: mid
  -- shades are always background (a drawn cast shadow must not ring the
  -- object in brown), and whites flood only along white runs from the
  -- edge -- a background white sheet drains away, but paint whites the
  -- flood could only reach through grey are the object.
  if force and force ~= "opaque" then
    local strict = false
    do
      local fs = S.shapeAt[keyOf(region.tiles[1][1], region.tiles[1][2])]
      strict = fs ~= nil and fs.class == "cutout"
    end
    -- The rim vote reads the shades on the DRAWING'S OWN bounding box, so a
    -- prop whose body reaches its own edge votes itself out. The Center's
    -- potted plants are the case: the pot's olive base is drawn flush on the
    -- bottom row of the block, so "dark" came back as background and every
    -- dark pixel in the whole plant drained with it -- the pots rendered as
    -- hollow black frames while the 2D art has solid olive bodies.
    --
    -- Where the vote misreads the art, the profile can name the background
    -- shades outright (a tileset entry's prop_bg). Keyed BY TILE rather than
    -- per tileset, because the answer is per drawing: the healing consoles'
    -- screens really do stand on a dark wall band and really do need dark
    -- voted out, and the PC really does need light kept.
    local bg = {}
    do
      local named = TileShape.propBg(map.tileset.id)
      if named then
        for _, c in ipairs(region.tiles) do
          local rule = named[S.tileAt[keyOf(c[1], c[2])]]
          if rule then
            for shadeName in pairs(rule) do bg[shadeName] = true end
            break
          end
        end
      end
    end
    if not next(bg) then
      for iy = 0, H - 1 do
        for ix = 0, W - 1 do
          local px, py = ix - 1, iy - 1
          local edge = px == 0 or px == bw - 1 or py == 0 or py == bh - 1
          local st = state[iy * W + ix]
          if edge and (st == "dark" or st == "light" or st == "white") then
            bg[st] = true
          end
        end
      end
      if not (bg.dark or bg.light or bg.white) then bg.white = true end
    end
    for i, st in pairs(state) do
      if strict then
        if st == "dark" or st == "light" then
          state[i] = "cand"
        elseif st == "white" then
          state[i] = "wcand"
        elseif st == "black" then
          state[i] = "solid"
        end
      elseif st == "dark" or st == "light" or st == "white" then
        state[i] = bg[st] and "cand" or "solid"
      elseif st == "black" then
        state[i] = "solid"
      end
    end
  end

  -- flood background in from the ground at the structure's feet
  local flooded = {}
  local queue = {}
  for i, st in pairs(state) do
    if st == "air" or st == "iair" then
      flooded[i] = true
      queue[#queue + 1] = i
    end
  end
  while #queue > 0 do
    Budget.tick()
    local i = table.remove(queue)
    local ix, iy = i % W, math.floor(i / W)
    for _, d in ipairs(DIRS4) do
      local nx, ny = ix + d[1], iy + d[2]
      if nx >= 0 and nx < W and ny >= 0 and ny < H then
        local ni = ny * W + nx
        if not flooded[ni] then
          local ns = state[ni]
          -- "wcand" (a strict cutout's white) drains only along a white
          -- run that reaches the RING: entered from the outer apron or
          -- from another flooded white, never through grey or through
          -- interior air
          if ns == "cand" or ns == "air" or ns == "iair"
             or (ns == "wcand"
                 and (state[i] == "air" or state[i] == "wcand")) then
            flooded[ni] = true
            queue[#queue + 1] = ni
          end
        end
      end
    end
  end

  -- per-tile background ratio -> sprite-like tiles (a pinned billboard is
  -- sprite-like by decree)
  local sprite = {}
  for _, c in ipairs(region.tiles) do
    Budget.tick()
    if force then
      sprite[keyOf(c[1], c[2])] = true
    else
      local bx = (c[1] - region.minX) * 8
      local by = (c[2] - region.minY) * 8
      local bg = 0
      for py = 0, 7 do
        for px = 0, 7 do
          if flooded[(by + py + 1) * W + (bx + px + 1)] then bg = bg + 1 end
        end
      end
      if bg / 64 >= TILE_BG_RATIO then sprite[keyOf(c[1], c[2])] = true end
    end
  end

  -- cluster sprite-like tiles; validate each cluster as one prop
  local leftover, claimed = {}, {}
  local clusterSeen = {}
  for _, c in ipairs(region.tiles) do
    local k = keyOf(c[1], c[2])
    if sprite[k] and not clusterSeen[k] then
      local cluster = { tiles = {}, minX = c[1], maxX = c[1],
                        minY = c[2], maxY = c[2] }
      local queue2 = { c }
      clusterSeen[k] = true
      while #queue2 > 0 do
        local cc = table.remove(queue2)
        cluster.tiles[#cluster.tiles + 1] = cc
        cluster.minX = math.min(cluster.minX, cc[1])
        cluster.maxX = math.max(cluster.maxX, cc[1])
        cluster.minY = math.min(cluster.minY, cc[2])
        cluster.maxY = math.max(cluster.maxY, cc[2])
        for _, d in ipairs(DIRS4) do
          local nk = keyOf(cc[1] + d[1], cc[2] + d[2])
          if sprite[nk] and not clusterSeen[nk] then
            clusterSeen[nk] = true
            queue2[#queue2 + 1] = { cc[1] + d[1], cc[2] + d[2] }
          end
        end
      end
      if buildObject(S, map, region, cluster,
                                state, flooded, srcU, srcV, W, force) then
        for _, cc in ipairs(cluster.tiles) do
          claimed[keyOf(cc[1], cc[2])] = true
        end
      end
    end
  end

  for _, c in ipairs(region.tiles) do
    if not claimed[keyOf(c[1], c[2])] then leftover[#leftover + 1] = c end
  end
  return leftover
end

return {
  OBJ_SHADE = OBJ_SHADE,
  shadeClass = shadeClass,
  extractObjects = extractObjects,
  buildObject = buildObject,
}