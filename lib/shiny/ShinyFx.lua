-- The shiny sparkle: the flash a Pokemon makes when it first appears.
--
-- The games announce a shiny with a burst of stars over the sprite the
-- instant it lands, before the first text box. This is that moment, in the
-- diorama: a ring of additive stars that springs outward from the mon's
-- chest, rises, and fades over about three quarters of a second.
--
-- ------- where the moment IS
--
-- Harder than it sounds, because the two battle paths arrive differently:
--
--   the model rung   a Pokemon grows out of its ball -- Stadium.update
--                    already finds that frame (the POOF_ANIM edge) and
--                    calls StadiumMon:beginGrow.
--   the pic rung     a WILD foe is simply THERE on the first frame, with
--                    no poof and no grow at all. There is no animation to
--                    hang off.
--
-- So the arming edge is neither of those: it is the frame a side's OCCUPANT
-- changes (Stadium's `session.at[side] ~= battler` test, the same identity
-- the mode already uses because a trainer leading with two Rattata changes
-- occupant without changing species). That edge fires for a send-out, a
-- switch and a wild foe alike, which is exactly the set of moments a shiny
-- should announce itself.
--
-- ------- drawn additively, and why it survives the flash
--
-- Stars are light, so they add rather than cover: `Voxel3D.blend("add")`,
-- the same treatment the Poke Ball's glow gets. They are drawn inside the
-- battle's flash window alongside the cards and models, so a sparkle during
-- a hit flash is lit by it like everything else rather than floating over
-- it as a separate layer.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Voxel3D = V.require("Voxel3D")
local Mat4 = V.require("Mat4")
local BattleBillboard = V.require("BattleBillboard")

local ShinyFx = {}

local max, min = math.max, math.min

-- ------- shape and timing

-- ------- sized to the Pokemon, not to a constant
--
-- A Pokemon on the map is between 5 and 18 world pixels tall
-- (StadiumMon.MIN_HEIGHT/MAX_HEIGHT, REF_HEIGHT 14) and roughly its own
-- radius wide. Every earlier attempt here used flat numbers and every one of
-- them was wrong for most of the dex: first a ring 7 units across, which sat
-- INSIDE anything bigger than a Rattata and was depth-rejected; then, over-
-- correcting, a ring 24 across starting 20 units up -- taller than the
-- tallest Pokemon there is, so it hung in the sky above a Ponyta with
-- nothing under it.
--
-- One ring cannot fit a Diglett and a Gyarados. The burst is therefore a
-- FRACTION of the mon it belongs to: Stadium hands us each side's
-- worldHeight and worldRadius (StadiumMon has them, and worldRadius exists
-- precisely so "a caller can size something to its footprint"), and every
-- distance below is measured off those.
ShinyFx.LIFE = 0.75          -- seconds from spring to gone
ShinyFx.STARS = 10           -- around the ring

ShinyFx.CHEST_FRAC = 0.50    -- up the body: the ring is centred on the
                             -- Pokemon, not perched above or below it
ShinyFx.RISE_FRAC = 0.16     -- of its height, drifted up over the burst
ShinyFx.SIZE_FRAC = 0.20     -- a star, as a fraction of the mon's height

-- THE RING IS AN ELLIPSE AROUND THE SILHOUETTE, with its two axes measured
-- separately. A single radius cannot do this: flattened enough to look like
-- a ring seen from the battle's low seat, its vertical reach ends up a third
-- of the body's height, so the top and bottom stars sit ON the Pokemon. The
-- horizontal axis clears its width, the vertical axis clears its height.
ShinyFx.RING_X_FRAC = 1.50   -- of the mon's RADIUS -- just outside its width
ShinyFx.RING_X_MIN = 0.34    -- ...but never narrower than this of its height,
                             -- for the thin ones (Onix, Ekans) whose radius
                             -- alone would put the ring inside them
ShinyFx.RING_Y_FRAC = 0.62   -- of its HEIGHT -- so the ring reaches its
                             -- shoulders and its feet, not just its middle

-- The burst OPENS from here rather than from nothing. Springing out of a
-- point means every star spends the first frames stacked at the centre --
-- which is the middle of the Pokemon, and reads exactly like the sparkles
-- being stuck inside it. Starting already clear of the body and expanding
-- the rest of the way keeps them outside for the whole life of the effect.
ShinyFx.RING_START = 0.72

-- What a side with no model gets: the flat-pic rung, where a pic stands
-- FULL_W (16) units wide in a card. Close enough to a median Pokemon that
-- the same fractions land sensibly.
ShinyFx.DEFAULT_HEIGHT = 14
ShinyFx.DEFAULT_RADIUS = 6

-- Additive drawing keeps the depth TEST (Voxel3D.blend sets lequal with
-- writes off), so a star level with the model is rejected by it however
-- bright it is. The extra pull puts the ring in front of the Pokemon it
-- belongs to, the same trick the move-animation card uses.
ShinyFx.PULL_BONUS = 6

-- one per side, nil when nothing is playing
local live = { player = nil, enemy = nil }

-- How big the Pokemon on each side actually is, pushed in by Stadium.update
-- every frame it has a model. Kept here rather than reached for, because
-- ShinyFx is drawn from BattleScene and asking Stadium from inside it would
-- close a require loop between the three.
local size = { player = nil, enemy = nil }

-- world pixels, from StadiumMon:worldHeight/worldRadius. Pass nil height to
-- say "no model on this side" -- the flat-pic rung, which falls back to the
-- defaults above.
function ShinyFx.setMetrics(side, height, radius)
  if side ~= "player" and side ~= "enemy" then return end
  if not (height and height > 0) then size[side] = nil return end
  size[side] = { h = height, r = radius or 0 }
end
local star = nil             -- the generated star image, built once

-- ------- the star
--
-- Generated rather than shipped: it is a four-pointed twinkle, which is a
-- cheap closed form (a radial falloff times a cross-shaped spike term) and
-- costs nothing next to an asset that would have to be authored, packed,
-- loaded and kept in step with the rest of the mod's art.
local function starImage()
  if star ~= nil then return star or nil end
  if not (love and love.image and love.graphics) then
    star = false
    return nil
  end
  local ok, img = pcall(function()
    local N = 32
    local data = love.image.newImageData(N, N)
    local c = (N - 1) / 2
    for y = 0, N - 1 do
      for x = 0, N - 1 do
        local dx, dy = (x - c) / c, (y - c) / c
        local r = math.sqrt(dx * dx + dy * dy)
        -- the body: a soft core that is gone by the edge of the square
        local core = math.max(0, 1 - r)
        core = core * core * core
        -- the spikes: bright along the two axes, narrow, and reaching
        -- further out than the core does
        local ax, ay = math.abs(dx), math.abs(dy)
        local spike = math.max(0, 1 - ax * 6) * math.max(0, 1 - ay)
                    + math.max(0, 1 - ay * 6) * math.max(0, 1 - ax)
        local a = math.min(1, core + spike * 0.55)
        -- white with the faintest warm cast, so a sparkle over a cool
        -- model still reads as light rather than as a blue smear
        data:setPixel(x, y, 1, 1, 0.97, a)
      end
    end
    return love.graphics.newImage(data)
  end)
  star = (ok and img) or false
  return star or nil
end

-- ------- arming

-- Start (or restart) the burst on one side. Restarting rather than ignoring
-- a second call is deliberate: a shiny that faints and is sent back out
-- should sparkle again.
-- ARMED, BUT NOT YET RUNNING. The clock does not start here, and that is the
-- whole point: the edge this is armed on -- a side's occupant changing --
-- happens while the screen is still mid-WIPE, a second or more before the
-- battle draws a single frame. A burst that started its three-quarter-second
-- life at that moment was always over before anybody could see it, which is
-- exactly what "the sparkle isn't appearing" looked like: armed, drawn,
-- counted, and finished behind the transition.
--
-- So `pending` holds it at frame zero until the scene actually draws this
-- side (see draw), and the life begins from there.
function ShinyFx.arm(side)
  if side ~= "player" and side ~= "enemy" then return end
  live[side] = { t = 0, pending = true }
  if ShinyFx.debug then ShinyFx.debug.armed = (ShinyFx.debug.armed or 0) + 1 end
end

-- The fight is on screen now: let any burst waiting on this side begin.
--
-- Split from arm because the two moments are genuinely different and were
-- conflated twice. Arming happens when the OCCUPANT changes, which is during
-- the transition; the burst may only start once the transition is OVER and
-- there is somebody watching. Between them it sits at zero.
function ShinyFx.release(side)
  local s = live[side]
  if s and s.pending then
    s.pending = nil
    if ShinyFx.debug then
      ShinyFx.debug.released = (ShinyFx.debug.released or 0) + 1
    end
  end
end

function ShinyFx.clear(side)
  if ShinyFx.debug and side and live[side] then
    ShinyFx.debug.cleared = (ShinyFx.debug.cleared or 0) + 1
  end
  if side then live[side] = nil else live.player, live.enemy = nil, nil end
end

function ShinyFx.active(side)
  if side then return live[side] ~= nil end
  return live.player ~= nil or live.enemy ~= nil
end

function ShinyFx.update(dt)
  dt = dt or 0
  for _, side in ipairs({ "player", "enemy" }) do
    local s = live[side]
    -- a pending burst does not age: it is waiting for the scene to draw it
    -- for the first time, which is when its life actually begins (see arm)
    if s and not s.pending then
      s.t = s.t + dt
      if s.t >= ShinyFx.LIFE then live[side] = nil end
    end
  end
end

-- ------- drawing

-- Eased so the ring leaves fast and settles, which is what a spark does;
-- linear looks like a diagram of a spark.
local function easeOut(u) return 1 - (1 - u) * (1 - u) end

-- Draw whatever is playing. `arena` and `groundY` come from the scene, the
-- same two the mon cards are placed from, so a sparkle lands where its
-- Pokemon is standing rather than where the layout thinks it should be.
-- Why a burst did not draw, for a driver to read back. Rendering faults are
-- invisible to the test suite and this one has four separate ways to be a
-- no-op, all of them silent.
ShinyFx.debug = { calls = 0, noArena = 0, noImage = 0, noMesh = 0,
                  noLive = 0, quads = 0, armed = 0, cleared = 0 }

function ShinyFx.draw(arena, groundY, pull)
  local dbg = ShinyFx.debug
  dbg.calls = dbg.calls + 1
  if not arena then dbg.noArena = dbg.noArena + 1 return end
  local img = starImage()
  if not img then dbg.noImage = dbg.noImage + 1 return end
  local mesh = BattleBillboard.mesh()
  if not mesh then dbg.noMesh = dbg.noMesh + 1 return end
  if not (live.player or live.enemy) then
    dbg.noLive = dbg.noLive + 1
    return
  end

  local drew = false
  for _, side in ipairs({ "player", "enemy" }) do
    local s = live[side]
    local cell = (side == "player") and arena.player or arena.enemy
    -- A pending burst is not drawn at all. It is waiting for the fight to be
    -- ON SCREEN, which is not the same as the scene being drawn: the battle
    -- renders underneath the transition wipe for a second or so first, and a
    -- burst started there spends its whole life behind it. Stadium.release
    -- is what says the wipe is done.
    if s and s.pending then s = nil end
    if s and cell then
      local u = math.min(1, s.t / ShinyFx.LIFE)
      local e = easeOut(u)
      -- bright immediately, then out: the announcement is the first frame
      local alpha = 1 - u * u
      local x, z = cell[1], cell[2]
      local yaw = BattleBillboard.yawToward(x, z, Voxel3D.eye)

      -- every distance measured off THIS Pokemon (see the header)
      local m = size[side]
      local mh = (m and m.h) or ShinyFx.DEFAULT_HEIGHT
      local mr = (m and m.r and m.r > 0 and m.r) or ShinyFx.DEFAULT_RADIUS
      local ringX = max(mr * ShinyFx.RING_X_FRAC, mh * ShinyFx.RING_X_MIN)
      local ringY = mh * ShinyFx.RING_Y_FRAC
      local starK = mh * ShinyFx.SIZE_FRAC
      -- open from clear of the body, not from a point (see RING_START)
      local grow = ShinyFx.RING_START + (1 - ShinyFx.RING_START) * e
      local baseY = groundY + mh * ShinyFx.CHEST_FRAC
                    + mh * ShinyFx.RISE_FRAC * e

      if not drew then
        Voxel3D.blend("add")
        Voxel3D.seams(false)
        Voxel3D.glass(false)
        drew = true
      end

      for i = 1, ShinyFx.STARS do
        -- the ring is offset half a step per side so the two sides do not
        -- twinkle in lockstep when both are shiny
        local a = (i / ShinyFx.STARS) * math.pi * 2
                  + (side == "player" and 0.31 or 0)
        -- stars shrink as they fade, and alternate size so the ring reads
        -- as scattered rather than as a cog
        local k = starK * (1 - u * 0.6) * ((i % 2 == 0) and 0.7 or 1)
        local ox = math.cos(a) * ringX * grow
        local oy = math.sin(a) * ringY * grow
        local m = Mat4.mul(
          Mat4.mul(Mat4.translate(x, baseY, z), Mat4.rotateY(yaw)),
          Mat4.mul(Mat4.translate(ox, oy, 0), Mat4.scale(k, k, 1)))
        love.graphics.setColor(1, 1, 1, alpha)
        Voxel3D.draw(mesh, img, m, (pull or 0) + ShinyFx.PULL_BONUS)
        dbg.quads = dbg.quads + 1
      end
    end
  end

  if drew then
    love.graphics.setColor(1, 1, 1, 1)
    Voxel3D.glass(true)
    Voxel3D.seams(true)
    Voxel3D.blend("alpha")
  end
end

-- Drop the generated image (hot reload, or a graphics context that went
-- away) -- the same contract StadiumPack.invalidate honours.
function ShinyFx.invalidate()
  if star and star.release then pcall(star.release, star) end
  star = nil
  ShinyFx.clear()
end

return ShinyFx
