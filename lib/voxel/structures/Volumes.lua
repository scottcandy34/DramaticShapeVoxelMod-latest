-- ---- volume mode: per-column runs with real drawn heights ----

local MAX_ROWS = 6                 -- volume height cap: 48px

local function keyOf(tx, ty)
  return (ty + 64) * 4096 + (tx + 64)
end

-- `tiles` is a list of {tx, ty} forming one region (or what is left of one
-- after object extraction); runs are column-local, heights are measured
-- per column and reconciled per region.
local function buildVolume(S, map, tiles)
  local cols = {}
  for _, c in ipairs(tiles) do
    cols[c[1]] = cols[c[1]] or {}
    cols[c[1]][c[2]] = true
  end

  local runs = {}
  local heightVotes = {}
  local repeatVotes = {}
  for tx, ys in pairs(cols) do
    -- visit each contiguous vertical run in this column
    local sorted = {}
    for y in pairs(ys) do sorted[#sorted + 1] = y end
    table.sort(sorted)
    local i = 1
    while i <= #sorted do
      local north = sorted[i]
      local front = north
      while i + 1 <= #sorted and sorted[i + 1] == front + 1 do
        i = i + 1
        front = sorted[i]
      end
      i = i + 1
      local extent = front - north + 1

      -- the column's own reading: its extent, unless its tile sequence
      -- repeats -- then the repeat period is the drawn unit. Both readings
      -- cap at MAX_ROWS (a long-period repeat is still not one column of
      -- drawing).
      local unit, repeatRead = math.min(extent, MAX_ROWS), false
      if extent > 1 then
        local t0 = map:tileAt(tx, front)
        for k = 1, extent - 1 do
          if map:tileAt(tx, front - k) == t0 then
            unit = math.min(math.max(k, 2), MAX_ROWS)
            repeatRead = true
            break
          end
        end
        -- A one-row TRIM at the column's foot hides a repeat from the
        -- scan above, which anchors at the front tile: a cliff plateau
        -- ends its south edge in a rounded corner tile, the corner
        -- never recurs, and the column read its whole capped extent --
        -- a 48px fin (or a whole tent of them) sticking out of a 16px
        -- mesa on Routes 3 and 4. When the two rows directly above the
        -- front are IDENTICAL, the column is that repeat wearing a trim
        -- foot: one course plus the trim is its drawn unit. Doorway
        -- columns are untouched -- their run answers to the region
        -- (see below) before the unit matters.
        if not repeatRead and extent > 2
           and map:tileAt(tx, front - 1) == map:tileAt(tx, front - 2) then
          unit = 2
          repeatRead = true
        end
      end
      local isDoor = false
      for ty = north, front do
        if S.doorFold[keyOf(tx, ty)] then
          isDoor = true
          break
        end
      end
      local run = { front = front, north = north, extent = extent,
                    unit = unit, fromRepeat = repeatRead, door = isDoor }
      runs[#runs + 1] = { tx = tx, run = run }
      local h = unit * 8
      heightVotes[h] = (heightVotes[h] or 0) + 1
      if repeatRead then repeatVotes[h] = (repeatVotes[h] or 0) + 1 end
    end
  end

  -- region consensus: the dominant height. A column whose reading came
  -- from a repeat adopts it when taller (the column above a doorway
  -- repeats internally but belongs to a 48px house); a column that read
  -- its full extent keeps it (an attached low wing stays low).
  local modeH, modeN = 16, 0
  for h, n in pairs(heightVotes) do
    if n > modeN or (n == modeN and h > modeH) then modeH, modeN = h, n end
  end
  -- whether the region's dominant columns are flat repeats (a cliff
  -- mound's plateau) rather than drawn facades (a house's front)
  local modeRepeat = (repeatVotes[modeH] or 0) * 2 > modeN

  -- Whether this REGION's tops are a rim over a uniform body -- what every
  -- cliff mound is drawn as: a top edge, then the same rock the whole way
  -- down. The top face may then lay that rim once along its north edge and
  -- hold the body after it, instead of cycling the rim back every second
  -- tile and striping a plateau with edges it should not have.
  --
  -- Answered per column AND per region, because each catches what the
  -- other misses. A mound is one structure many columns wide, and the
  -- columns carrying its cave mouth read differently from their neighbours
  -- (their drawing ends in the mouth's own tiles): per column alone, those
  -- kept cycling while the rest held, leaving rim stubs above the doorway.
  -- But a region vote alone silences a genuine rim-over-body column that
  -- happens to stand in a region of repeating art -- three of them in the
  -- Safari Zone. A column holds if EITHER says so.
  --
  -- Art that genuinely repeats is not uniform and keeps cycling: the
  -- Safari Zone's fence alternates two tiles the whole way down, and there
  -- the repeat IS what the drawing says.
  local uniformVotes, uniformTotal = 0, 0
  for _, r in ipairs(runs) do
    local run = r.run
    if run.extent > 2 then
      uniformTotal = uniformTotal + 1
      local body = map:tileAt(r.tx, run.north + 1)
      local uniform = true
      for d = 2, run.extent - 1 do
        if map:tileAt(r.tx, run.north + d) ~= body then
          uniform = false
          break
        end
      end
      run.ownUniform = uniform
      if uniform then uniformVotes = uniformVotes + 1 end
    end
  end
  local regionUniform = uniformTotal > 0 and uniformVotes * 2 > uniformTotal
  for _, r in ipairs(runs) do
    local run = r.run
    local h = run.unit * 8
    local adopted = false
    local flatDoor = false
    if run.door then
      -- A folded doorway column answers to its region ENTIRELY. Its own
      -- reading spans the door plus everything drawn above it -- a
      -- house's full height when the door is a house's, but a 32px
      -- tower over a 16px plateau when the door is a cave mouth cut
      -- into a cliff mound (Diglett's Cave: the entrance jumped a block
      -- above the mound around it). Height and top both come from the
      -- region: the mode height, roofed like a facade when the mode
      -- columns are drawn facades, flat when they are flat repeats.
      h = modeH
      adopted = not modeRepeat
      flatDoor = modeRepeat
    elseif run.fromRepeat and modeH > h then
      h = modeH
      adopted = true
    end
    -- Outdoors, a structure's top rows are its ROOF: the drawn height
    -- splits into a vertical facade and a slope rising north to the drawn
    -- peak (the mesher builds it; hips close the exposed flanks). Repeat
    -- patterns (a border wall) stay flat-topped -- unless they adopted
    -- their region's height, which means they are part of a building (the
    -- column above a doorway) and roof with it. Total height is always
    -- the drawn height: facade + rise = extent rows * 8.
    --
    -- But only PITCHED roofs slope. Gen 1 draws two kinds: a pitched roof
    -- has distinct ridge and eaves rows (the houses' stripes), while a
    -- flat ROOFTOP (the lab, the mart) repeats one texture tile over the
    -- whole roof area -- and a rooftop tilted into a 48px ramp reads
    -- wrong instantly. Distinct top rows -> slope; repeated -> level top.
    local roofRows = 0
    if S.outdoor and (not run.fromRepeat or adopted) and h >= 16
       and not flatDoor then
      roofRows = math.min(2, math.floor(h / 8) - 1)
      if roofRows > 0 and map:tileAt(r.tx, run.north)
                         == map:tileAt(r.tx, run.north + 1) then
        roofRows = 0
      end
    end
    run.roofRows = roofRows
    run.rise = roofRows * 8
    run.peak = h
    run.h = h - run.rise               -- facade height: what sides build to
    run.topUniform = run.ownUniform or regionUniform
    for ty = run.north, run.front do
      S.runs[keyOf(r.tx, ty)] = run
    end
  end
end

return buildVolume