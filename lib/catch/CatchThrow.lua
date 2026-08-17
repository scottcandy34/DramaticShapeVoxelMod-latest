-- LET'S GO capture mode: the throw itself.
--
-- The player sees the wild Pokemon from the staged battle's own
-- over-the-shoulder seat -- held perfectly still for the duration, with
-- their own Pokemon nowhere in the shot -- a Poke Ball hanging in the
-- foreground, and a timing ring pulsing on the foe. A flick of the mouse,
-- a finger, or the right stick throws the ball along a solved arc; spin
-- the ball first and it flies with a visible curve. Where the ball crosses
-- the foe's plane is judged in SCREEN space against the ring -- the player
-- aimed at pixels, so pixels are what they are graded on -- and a throw
-- inside the shrinking ring earns NICE / GREAT / EXCELLENT, which
-- multiplies the Gen 1 catch roll the engine then makes. The ball opens,
-- drinks the Pokemon in, drops, rocks once per engine shake, and either
-- clicks with stars or bursts the Pokemon back out.
--
-- ------- what this file owns, and what it borrows
--
-- It owns the SESSION: input sampling, the flick estimate, the arc, the
-- ring, the grading, and the choreography of the Pokeball prop. Everything
-- consequential is borrowed from the engine so the outcome is exactly a
-- Gen 1 ball throw: the roll is battle:catchAttempt (status, HP and ball
-- factors intact, our throw grade folded into the rate), the outcome texts
-- and the enemy's revenge turn are the same queue throwBall builds, and a
-- catch lands in storeCaughtMon -- dex page, nickname, box overflow and
-- the pokemon.caught event all included. While the session runs the battle
-- is FROZEN by parking battle.phase on a value the engine's update has no
-- branch for; the resolution puts "messages" back and the engine finishes
-- the fight believing it threw the ball itself.
--
-- ------- the input model (design: flick-to-throw)
--
-- All pointer samples are kept in GB-frame pixels (160x144), the same
-- space the ring is drawn in. The flick velocity is a least-squares slope
-- over the last 110 ms -- never last-minus-previous, which one frame of
-- jitter destroys. Strength comes from speed, direction from the fit, and
-- the landing point is "the spot the flick pointed at": release position
-- plus direction times a reach that grows with strength. Short flicks land
-- short, wild flicks sail long, and a ±30% speed error still lands inside
-- the outer ring, which is what keeps the mechanic hard rather than broken.
-- The right stick plays the same game with a virtual finger standing at
-- centre + stick * radius, so pad players flick by flicking the stick.
--
-- Spin is a circular gesture around the held ball: accumulated signed
-- angle arms the curve past 1.25 turns, and once armed it latches. A
-- curved ball hooks late in flight (the ramp is what forces aiming off to
-- the opposite side) with a 40% assist folded into the solve, so the curve
-- is a flourish first and a skill test second.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("Mat4")
local Voxel3D = V.require("Voxel3D")
local Pokeball = V.require("Pokeball")
local BattleScene = V.require("BattleScene")
local BattleCam = V.require("BattleCam")

local CatchThrow = {}

-- the parked phase: any value BattleState:update has no branch for freezes
-- the fight; namespaced so no future engine phase can collide with it
CatchThrow.PHASE = "dramaticShapeCapture"

-- ------- tuning
--
-- Screen quantities are GB pixels (the battle frame is 160x144); world
-- quantities are world pixels (a map cell is 16); times are seconds.

local WINDOW = 0.11          -- flick fit window
local S_MIN = 55             -- below this the release is a hesitation
-- a throw must point up-screen at least this much. LENIENT on purpose:
-- the gate only has to reject a plainly downward drag
local MIN_UP = 0.08

-- ------- the throw is the SWIPE'S OWN VELOCITY
--
-- The reference model (and the one that finally felt right): the ball is
-- dragged under the finger, and releasing LAUNCHES IT with the swipe's
-- velocity -- forward speed from how hard the swipe was, height from its
-- vertical, side from its horizontal, each clamped to a sane range like a
-- rigidbody throw. No aim point is picked and no arc is solved: gravity
-- and the collision decide what the throw earns. A soft flick drops
-- short, a wild one sails over, and the assist below is the only mercy.
--
-- CALIBRATED against the staging rather than picked: the throw is 48
-- world pixels (three cells) to a body about ten pixels up, so the
-- vertical speed that actually ARRIVES is somewhere in the 65-95 range
-- across every forward speed worth throwing at. The first cut had gains
-- of 3.0 and a 150/110 ceiling, which meant an ordinary ~190 GB px/s
-- swipe already saturated both clamps -- every throw left at maximum,
-- and maximum was well above anything that lands, so the ball sailed
-- over the Pokemon no matter how it was flicked. These put a
-- comfortable swipe in the middle of the band and leave the ceilings
-- where a genuinely hard throw still reaches them.
local K_FWD, K_UP, K_LAT = 2.4, 1.6, 1.0  -- swipe (world px/s) -> velocity
local F_MIN, F_MAX = 48, 140 -- forward speed clamp, world px/s
local U_MIN, U_MAX = 34, 92  -- upward
local L_MAX = 38             -- sideways
-- ------- and the ceiling that ends overthrowing
--
-- The launch height is never allowed to exceed what THIS throw's own
-- forward speed needs to arrive, by more than a margin. That is the
-- direct cure for the failure the gains alone could not fix: on a fixed
-- camera there is no depth cue for "too high", so a firm flick would
-- sail the ball clean over the Pokemon every time and the player had no
-- way to read why. Under the cap a throw can still fall SHORT (too
-- weak) or go WIDE (bad bearing) -- both of which are legible, because
-- you watch the ball land -- but it can no longer be lost over the top.
local OVER_CAP = 1.12
-- directional assist: the HORIZONTAL launch direction leans this fraction
-- toward the Pokemon. Speed, height and the short/long answer stay the
-- player's; the assist only trims the bearing, so an honest throw at the
-- creature connects instead of clipping past its ear.
local MAGNET = 0.3
-- range assist: the launch's HEIGHT leans this fraction toward what its
-- own forward speed would need to arrive at the foe's body. Pure velocity
-- throws punish the lob's shape as hard as its speed; this keeps speed as
-- the skill and stops a good read from sailing a ball-width over. Half,
-- not a third: the arc's SHAPE is the least legible thing about a throw
-- on a fixed camera -- there is no depth cue for how high is too high --
-- so it is the part worth forgiving, while distance and bearing stay the
-- player's to get right.
local V_ASSIST = 0.5
local T_REF = 0.6            -- the tap-throw / Master Ball solve time

local GRAVITY = 300          -- world px/s^2 -- ~2x earth at 16 px/metre,
                             -- the platformer exaggeration the arc needs
local H_STEP = 1 / 120       -- fixed integration step

-- ------- spin
--
-- The wind-up is a METER now, not a switch: every turn of the gesture adds
-- to it and it bleeds away when the hand stops, so the ball visibly spins
-- up with the player -- faster the more they wind -- to a cap. Only a ball
-- AT the cap curves when thrown; anything less is style.
local SPIN_FULL = 32         -- radians of gesture from still to the cap
local ROLL_MAX = 24          -- the cap's visible spin, rad/s
local SPIN_DECAY = 0.45      -- meter per second, once the hand pauses
local SPIN_IDLE = 0.2        -- how long a pause before the bleed starts
local ARM_AT, DISARM_AT = 0.99, 0.80  -- hysteresis on "at the cap"

local CURVE_GAIN = 120       -- lateral pull at full spin, world px/s^2
local CURVE_RAMP0, CURVE_RAMP1 = 0.25, 0.70   -- the hook bites late
local ASSIST = 0.4           -- how much of the curve the solve pre-corrects
local K_RAMP = 0.14          -- integral of the ramp, for the assist

local RING_PERIOD = 2.2      -- shrink cycle
local RING_HOLD = 0.15       -- pause at the smallest
local RING_MIN = 0.12        -- the Excellent floor
local CHEST = 9              -- ring/beam height over the foe's feet, world px

local SUCK_T = 0.6           -- the Pokemon drinking into the ball
local DROP_T = 0.45          -- fall to the ground
local SHAKE_GAP = 0.42       -- pause between rocks
local STICK_R = 34           -- the virtual finger's orbit, GB px

-- stick flick thresholds, in stick units (full deflection = 1) per second
local STICK_VEL = 5.5
local STICK_GRAB = 0.30

-- the Let's Go throw-grade multipliers, applied to the Gen 1 catch rate
-- and to the capture-experience stack (Bulbapedia's Let's Go tables)
local TIER_MULT = { EXCELLENT = 2.0, GREAT = 1.5, NICE = 1.1 }

-- ------- session state

local S = nil

local function game() return require("src.core.Game") end

local function sound(name)
  pcall(function()
    require("src.core.Sound").play(game().data, name)
  end)
end

local function emit(name, payload)
  pcall(function() require("src.mods.Runtime").emit(name, payload) end)
end

local function OB() return V.require("OverworldBattle") end

function CatchThrow.active()
  return S ~= nil and S.phase ~= "epilogue"
end

function CatchThrow.session()
  return S
end

-- ------- geometry helpers
--
-- The shot BattleScene hands back carries the camera (eye/focus), the
-- combined matrix (vp) and the letterbox, which together answer every
-- space question the session has: world -> GB via BattleScene.toGB, and
-- the camera's flat forward/right for aiming errors.

local function camBasis(shot)
  local e, f = shot.eye, shot.focus
  local fx, fz = f[1] - e[1], f[3] - e[3]
  local l = math.sqrt(fx * fx + fz * fz)
  if l < 1e-6 then fx, fz = 0, -1 else fx, fz = fx / l, fz / l end
  -- right-handed about +Y up: right = fwd x up
  return fx, fz, -fz, fx
end

local function toGB(shot, wx, wy, wz)
  return BattleScene.toGB(shot.vp, wx, wy, wz,
                          shot.lx, shot.ly, shot.scale, shot.pw, shot.ph)
end

-- the yaw that turns a thing at (x, z) to face this shot's eye
local function eyeYaw(x, z)
  local e = S.shot and S.shot.eye
  if not e then return 0 end
  return math.atan2(e[1] - x, e[3] - z)
end

-- ------- the capture seat's measurements
--
-- HEAD ON: the eye stands on the arena's own axis, behind the player's
-- cell, looking straight at the foe -- the GO framing, not the battle's
-- over-the-shoulder rig. Declared here rather than beside captureRig
-- below because the ray reconstruction underneath needs the lens.
local SEAT_BACK = 46         -- eye behind the player's cell, world px
local SEAT_UP = 13           -- and above the floor
local SEAT_FOV = math.rad(26)
local SEAT_FRAME = 44        -- world height the sun's box is fitted to

-- ------- the ray a GB-frame point looks along
--
-- The drag's whole job is "the ball is under the finger", and only the
-- real projection answers that: an offset scaled by some world-per-pixel
-- estimate is right at one depth and wrong everywhere else, and it has
-- no way to say what the bottom of the screen even means. This is the
-- ordinary pinhole reconstruction from the seat's own basis -- the
-- vertical field covers the GB's 144 rows, and the horizontal falls out
-- of square pixels (which is why both axes divide by the same half
-- height).
--
-- Keyed to SEAT_FOV rather than to the shot, deliberately: the shot's
-- fov has been widened to the window (BattleScene.letterboxFov) and what
-- is wanted here is the lens the GB frame was framed with, which is the
-- capture rig's own and nobody else's.
local function rayThrough(gx, gy)
  local shot = S and S.shot
  if not shot then return nil end
  local e, f = shot.eye, shot.focus
  local dx, dy, dz = f[1] - e[1], f[2] - e[2], f[3] - e[3]
  local l = math.sqrt(dx * dx + dy * dy + dz * dz)
  if l < 1e-6 then return nil end
  dx, dy, dz = dx / l, dy / l, dz / l
  -- right = forward x worldUp; camUp = right x forward
  local rx, rz = -dz, dx
  local rl = math.sqrt(rx * rx + rz * rz)
  if rl < 1e-6 then return nil end
  rx, rz = rx / rl, rz / rl
  local ux, uy, uz = -rz * dy, rz * dx - rx * dz, rx * dy
  local half = BattleScene.GB_H / 2
  local t = math.tan(SEAT_FOV / 2)
  local ax = (gx - BattleScene.GB_W / 2) / half * t
  local ay = (gy - half) / half * t
  local vx = dx + rx * ax - ux * ay
  local vy = dy - uy * ay
  local vz = dz + rz * ax - uz * ay
  local vl = math.sqrt(vx * vx + vy * vy + vz * vz)
  if vl < 1e-6 then return nil end
  return vx / vl, vy / vl, vz / vl
end

-- Where the held ball hangs: over the PLAYER'S OWN CELL, which capture
-- mode has just emptied. Not in front of the camera -- the default battle
-- rig is a long lens standing five blocks back, and anything a hand's
-- reach from THAT eye is a blimp filling the frame. The player's cell is
-- where the trainer stands, it sits bottom-centre of the head-on seat
-- below, and it makes the throw a real three-cell lob at 16 pixels a
-- metre instead of an eleven-metre crane shot from the sky.
local HAND_HOVER = 6.5       -- the held ball's height over the floor
local function handPos()
  local p = S.playerPos
  return { p[1], p[2] + HAND_HOVER, p[3] }
end

-- The seat itself, from the measurements above: the foe centred, the held
-- ball at the bottom of the frame, the throw a straight shot up the
-- middle. Handed to BattleScene.render through the capture table's `rig`;
-- everything downstream (pins, cards, sun, fov) is camera-generic.
-- ------- and how far back the WORLD lets it stand
--
-- SEAT_BACK is what the shot wants. It is not always available: this seat
-- is low (SEAT_UP is 13 world pixels, under a single cell) where the
-- battle's own rig stands at 37.9, and it is planted three cells behind
-- the player wherever the encounter happened -- which on a hedged route
-- like ROUTE 6 is inside the hedge. The eye then looks out from within
-- the foliage and the scenery it is standing in hangs across the top of
-- the frame, over the horizon and the distant rooftops both.
--
-- ThirdPerson's boom answers exactly this question for the free-roam
-- camera, so it answers it here rather than being restated: march back
-- from the player's cell and stop at the first thing the eye may not be
-- inside, keeping its PAD. Its rule is the right one for a seat this low,
-- too -- terrain height always blocks, and anything BUILT on a cell
-- blocks below head height, so a kerb is passed over and a hedge is not.
--
-- Pulling in brings the foe closer in a fixed field of view, which is a
-- composition the throw already handles: the ring, the collision and the
-- drag are all measured from the live shot, so they follow the seat.
local SEAT_MIN_BACK = 20     -- never nearer than this: the held ball hangs
                             -- at the player's own cell and has to stay in
                             -- front of the eye

local function seatBack(px, pz, ax, az, eyeY)
  local ok, ow = pcall(function() return game().overworld end)
  if not (ok and ow) then return SEAT_BACK end
  local ThirdPerson = V.require("ThirdPerson")
  local okR, reach = pcall(ThirdPerson.reach, ow, { px, eyeY, pz },
                           -ax, 0, -az, SEAT_BACK)
  if not (okR and reach) then return SEAT_BACK end
  return math.max(SEAT_MIN_BACK, math.min(SEAT_BACK, reach))
end

local function captureRig(arena, groundY)
  local ex, ez = arena.enemy[1], arena.enemy[2]
  local px, pz = arena.player[1], arena.player[2]
  local ax, az = ex - px, ez - pz
  local l = math.sqrt(ax * ax + az * az)
  if l < 1e-6 then ax, az = 0, -1 else ax, az = ax / l, az / l end
  local eyeY = groundY + SEAT_UP
  local back = seatBack(px, pz, ax, az, eyeY)
  local cam = {
    eye = { px - ax * back, eyeY, pz - az * back },
    focus = { ex, groundY + 8, ez },
    fov = SEAT_FOV,
  }
  -- The pitch VoxelScene.pull wants, and it is the angle off STRAIGHT DOWN
  -- -- the convention Voxel.angle keeps and BattleCam.rig hands back
  -- (atan2(horizontal run, height over the focus)). This used to answer the
  -- DEPRESSION below level instead, which is that angle's complement, and
  -- the two are as far apart as a camera can be: a seat looking nearly
  -- level read as 0.06 radians, which is what the pull formula means by
  -- LOOKING STRAIGHT DOWN, so the grass and the flowers were pulled 46
  -- world pixels camera-ward instead of 6.
  --
  -- 46 is the whole distance this seat stands behind the player. The pull
  -- is a bias along each vertex's own eye ray, harmless while it is short
  -- of the range -- and past it, it drags geometry THROUGH the lens, where
  -- the projection turns inside out and one tuft of grass at the eye smears
  -- across the frame. That was the greenery hanging over the top of a
  -- capture shot, on a route or a city street with grass rows either side.
  -- (Voxel3D's vertex stage now clamps the pull to half the range as well,
  -- so no camera this close can be smeared by a bias again.)
  local pitch = math.atan2(back + l, math.max(1e-3, SEAT_UP - 8))
  return cam, pitch, SEAT_FRAME
end

-- The ring in GB space, centred on the CREATURE. The pinned mark is the
-- cell's ground point, but a species' art sits wherever the artist put it
-- in the frame -- a bird hovers half a slot over its own feet row -- so
-- the session measures the foe's rendered pic once (measureArt below) and
-- centres on the art's opaque box. The conversion is the card's own
-- arithmetic: one pic pixel is FULL_W/FULL_PIC world pixels, and a cell
-- is enemySpan GB pixels, so a pic pixel is span/56 GB pixels on screen.
-- The heuristic fallback (no pic: a STADIUM model, or a readback that
-- failed) is a chest height over the mark. The outer clamp is the
-- design's 0.06..0.18 screen heights, in GB pixels.
local function ringGeometry(shot)
  local span = shot.enemySpan or 16
  local b = S and S.artBox
  if b then
    local k = span / 56
    local cx = shot.enemy[1] + ((b.x0 + b.x1) / 2 - b.ax) * k
    local cy = shot.enemy[2] - (b.ay - (b.y0 + b.y1) / 2) * k
    local r = math.max(b.x1 - b.x0, b.y1 - b.y0) * 0.55 * k
    return cx, cy, math.max(9, math.min(26, r))
  end
  -- no pic to measure (a Stadium model, or a readback still pending):
  -- the collision body doubles as the ring's anchor, in the same
  -- world-to-screen scale a cell provides
  local body = (S and S.body) or { r = 8, yOff = 8 }
  local outer = math.max(9, math.min(26, body.r * 1.25 * span / 16))
  return shot.enemy[1], shot.enemy[2] - body.yOff * span / 16, outer
end

-- read the foe's pic back once and box its opaque pixels. A few thousand
-- getPixel calls on a 160x144 canvas, paid once per session -- the ring
-- then sits on the Pokemon for every species without a per-species table.
local function measureArt()
  local ok, box = pcall(function()
    local tex = OB().enemyTexture()
    if not (tex and tex.canvas and tex.canvas.newImageData) then return nil end
    local data = tex.canvas:newImageData()
    local w, h = data:getWidth(), data:getHeight()
    local x0, y0, x1, y1
    for y = 0, h - 1, 2 do
      for x = 0, w - 1, 2 do
        local _, _, _, a = data:getPixel(x, y)
        if a > 0.1 then
          if not x0 or x < x0 then x0 = x end
          if not x1 or x > x1 then x1 = x end
          if not y0 or y < y0 then y0 = y end
          if not y1 or y > y1 then y1 = y end
        end
      end
    end
    if not x0 then
      if data.release then data:release() end
      return nil
    end
    -- the ImageData is KEPT: it is the foe's collision geometry -- the
    -- flight samples it per plane crossing -- and it is released when the
    -- session is swept (endSession / battle.ended)
    return { ax = tex.ax, ay = tex.ay, x0 = x0, y0 = y0, x1 = x1, y1 = y1,
             data = data }
  end)
  return (ok and box) or nil
end

-- is there sprite under this pic pixel, within `r` pixels? Nine taps --
-- centre and a ring -- which at the dilation radii in play reads a hit
-- anywhere the ball's silhouette overlaps the art's.
local function maskHit(data, x, y, r)
  local ok, hit = pcall(function()
    local w, h = data:getWidth(), data:getHeight()
    local function tap(px, py)
      px, py = math.floor(px + 0.5), math.floor(py + 0.5)
      if px < 0 or py < 0 or px >= w or py >= h then return false end
      local _, _, _, a = data:getPixel(px, py)
      return a > 0.1
    end
    if tap(x, y) then return true end
    for i = 0, 7 do
      local a = i * math.pi / 4
      if tap(x + math.cos(a) * r, y + math.sin(a) * r) then return true end
    end
    return false
  end)
  return ok and hit or false
end

-- The foe's BODY -- where the ball has to physically arrive, and what the
-- ring is sized on. Measured from whichever the foe actually is: the pic's
-- opaque box (a hovering bird is hit where the bird is drawn, not where
-- its shadow falls), or the Stadium model's own height and footprint. A
-- default torso stands in until one of them answers; measured=false says
-- keep trying.
local function measureBody()
  local box = measureArt()
  if box then
    S.artBox = box
    local k = 16 / 56
    S.body = {
      r = math.max(5, math.min(14,
            math.max(box.x1 - box.x0, box.y1 - box.y0) * k * 0.5)),
      yOff = math.max(4, (box.ay - (box.y0 + box.y1) / 2) * k),
      hh = math.max(4, (box.y1 - box.y0) * k * 0.55),
    }
    S.bodyMeasured = true
    return
  end
  local ok, body = pcall(function()
    return V.require("Stadium").captureBody()
  end)
  if ok and body then
    S.body = body
    S.bodyMeasured = true
  end
end

-- named for the drivers: where the ball hangs and where the ring sits, in
-- GB pixels plus the live letterbox -- everything a scripted flick needs
-- to aim like a hand would
function CatchThrow._aimInfo()
  if not (S and S.shot) then return nil end
  local cx, cy, outer = ringGeometry(S.shot)
  return { hand = { S.handGB[1], S.handGB[2] },
           ring = { cx, cy }, outer = outer,
           lx = S.shot.lx, ly = S.shot.ly, scale = S.shot.scale,
           pw = S.shot.pw, ph = S.shot.ph }
end

-- the ring's inner fraction right now: 1 -> RING_MIN, hold, snap back
local function ringRho(t)
  local cycle = RING_PERIOD + RING_HOLD
  local u = t % cycle
  if u >= RING_PERIOD then return RING_MIN end
  return 1 - (1 - RING_MIN) * (u / RING_PERIOD)
end

-- ------- flick estimation

local function pushSample(x, y)
  local n = S.samples
  n[#n + 1] = { x = x, y = y, t = S.clock }
  if #n > 32 then table.remove(n, 1) end
end

-- least-squares velocity over the window before `at`; also answers the
-- window's peak two-sample speed and the mean speed of the last 40 ms,
-- which the dead-flick gate reads
local function flickFit(at)
  local xs, n = S.samples, 0
  local sx, sy, st = 0, 0, 0
  local first = at - WINDOW
  local pts = {}
  for _, p in ipairs(xs) do
    if p.t >= first and p.t <= at then
      pts[#pts + 1] = p
      sx, sy, st = sx + p.x, sy + p.y, st + p.t
      n = n + 1
    end
  end
  if n < 3 then return nil, nil, n end
  local mt, mx, my = st / n, sx / n, sy / n
  local num_x, num_y, den = 0, 0, 0
  for _, p in ipairs(pts) do
    local d = p.t - mt
    num_x = num_x + d * (p.x - mx)
    num_y = num_y + d * (p.y - my)
    den = den + d * d
  end
  if den < 1e-9 then return nil, nil, n end
  local vx, vy = num_x / den, num_y / den
  local peak, tailSum, tailN = 0, 0, 0
  for i = 2, #pts do
    local a, b = pts[i - 1], pts[i]
    local dt = b.t - a.t
    if dt > 1e-5 then
      local sp = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2) / dt
      if sp > peak then peak = sp end
      if b.t > at - 0.04 then tailSum, tailN = tailSum + sp, tailN + 1 end
    end
  end
  local tail = tailN > 0 and tailSum / tailN or 0
  return vx, vy, n, peak, tail
end

-- ------- spin gesture
--
-- A METER, not a switch. Circling the held ball winds it: every radian of
-- gesture adds to the meter and the ball's screen-plane roll follows it,
-- so the ball visibly spins faster the more it is wound, to a cap. Pause
-- and it bleeds back down (the decay lives in the aim tick). Winding the
-- OTHER way unwinds first. Only a ball at the cap curves when thrown.
local function feedSpin(x, y)
  -- About the CENTROID of the recent gesture, not about any fixed point:
  -- the ball rides under the finger, so the finger is never orbiting the
  -- ball -- it is orbiting the middle of the loop it is drawing, and that
  -- is what the centroid of the last few samples is. It also gives the
  -- straight-drag rejection for free: on a straight swipe the centroid
  -- trails along the line, so both spokes point the same way and the
  -- accumulated angle stays at nothing.
  local n = #S.samples
  if n < 4 then return end
  local sx, sy, count = 0, 0, 0
  for i = math.max(1, n - 11), n do
    sx, sy, count = sx + S.samples[i].x, sy + S.samples[i].y, count + 1
  end
  local cx, cy = sx / count, sy / count
  local px, py = S.spinPrev and S.spinPrev[1], S.spinPrev and S.spinPrev[2]
  S.spinPrev = { x, y }
  if not px then return end
  local ax, ay = px - cx, py - cy
  local bx, by = x - cx, y - cy
  local ra = math.sqrt(ax * ax + ay * ay)
  local rb = math.sqrt(bx * bx + by * by)
  if ra < 4 or rb < 4 then return end        -- thumb jitter, not an orbit
  local d = math.atan2(ax * by - ay * bx, ax * bx + ay * by)
  if d == 0 then return end
  local sign = d > 0 and 1 or -1
  if sign ~= S.spinSign and S.spinLevel > 0 then
    -- winding against the charge unwinds it, twice as fast as it built
    S.spinLevel = math.max(0, S.spinLevel - math.abs(d) * 2 / SPIN_FULL)
    if S.spinLevel == 0 then S.spinSign = sign end
  else
    S.spinSign = sign
    S.spinLevel = math.min(1, S.spinLevel + math.abs(d) / SPIN_FULL)
  end
  S.spinT = S.clock
  if not S.spinArmed and S.spinLevel >= ARM_AT then
    S.spinArmed = true
    sound("Press_AB")
  end
end

-- ------- the throw

local function smoothstep(a, b, t)
  local u = math.max(0, math.min(1, (t - a) / (b - a)))
  return u * u * (3 - 2 * u)
end

-- the moment the ball leaves the hand: pay for it, count it, sound it
local function paidAndAway()
  if not S.consumed then
    if S.safari then
      local st = S.battle.safari
      if st then st.balls = math.max(0, st.balls - 1) end
    else
      pcall(function()
        require("src.inventory.Bag").remove(game().save, S.ballId, 1)
      end)
    end
    S.consumed = true
  end
  S.battle.dramaticShapeThrows = (S.battle.dramaticShapeThrows or 0) + 1
  S.phase = "flight"
  S.tFly, S.acc = 0, 0
  -- a charged ball keeps its screen-plane roll all the way in; a plain
  -- throw tumbles end over end, harder the less it was wound
  S.ballInst.tumble = S.spinArmed and 0 or 15 * (1 - S.spinLevel)
  sound("Ball_Toss")
end

-- estimate how long the flight will take to reach the foe, for the curve
-- ramp and the give-up timer -- with a thrown VELOCITY there is no solved
-- T any more, only this
local function estimateT()
  local p, E = S.ballInst.pos, S.enemyPos
  local dx, dz = E[1] - p[1], E[3] - p[3]
  local horiz = math.sqrt(dx * dx + dz * dz)
  local hs = math.sqrt(S.vel[1] ^ 2 + S.vel[3] ^ 2)
  S.T = math.max(0.35, math.min(1.0, horiz / math.max(20, hs)))
end

-- launch with the swipe's own velocity (GB px/s in, world velocity out)
local function launchVelocity(vgx, vgy)
  local shot = S.shot
  local fx, fz, rx, rz = camBasis(shot)
  -- what a GB pixel is worth at the BALL's own depth: the swipe moved the
  -- ball, so the ball's speed is the swipe's speed in its own plane
  local wpg = 16 / math.max(6, shot.playerSpan or 16)
  local speed = math.sqrt(vgx * vgx + vgy * vgy) * wpg
  local fwd = math.max(F_MIN, math.min(F_MAX, speed * K_FWD))
  local up = math.max(U_MIN, math.min(U_MAX, (-vgy) * wpg * K_UP))
  local lat = math.max(-L_MAX, math.min(L_MAX, vgx * wpg * K_LAT))
  -- the horizontal launch, leaned MAGNET of the way toward the Pokemon
  local hx, hz = fx * fwd + rx * lat, fz * fwd + rz * lat
  local hmag = math.sqrt(hx * hx + hz * hz)
  local p, E = S.ballInst.pos, S.enemyPos
  local tx, tz = E[1] - p[1], E[3] - p[3]
  local tl = math.sqrt(tx * tx + tz * tz)
  if hmag > 1e-6 and tl > 1e-6 then
    local nx = hx / hmag * (1 - MAGNET) + tx / tl * MAGNET
    local nz = hz / hmag * (1 - MAGNET) + tz / tl * MAGNET
    local nl = math.sqrt(nx * nx + nz * nz)
    hx, hz = nx / nl * hmag, nz / nl * hmag
  end
  -- the range assist: what height would land THIS forward speed on the
  -- body, and lean toward it
  if hmag > 1 then
    local body = S.body or { yOff = 8 }
    local tt = tl / hmag
    local need = (S.groundY + body.yOff - p[2] + 0.5 * GRAVITY * tt * tt) / tt
    up = up + (need - up) * V_ASSIST
    -- and never more than a margin over what this throw needs (OVER_CAP)
    if need > 0 then up = math.min(up, need * OVER_CAP) end
    up = math.max(U_MIN * 0.6, math.min(U_MAX, up))
  end
  S.vel = { hx, up, hz }
  estimateT()
  paidAndAway()
end

-- the solved arc, kept for exactly two throwers: the Master Ball (which
-- must not miss) and the pad's A tap (full participation without the
-- dexterity requirement). Flies to the foe's own body centre.
local function launchSolve()
  local body = S.body or { r = 10, yOff = 8 }
  local E, p = S.enemyPos, S.ballInst.pos
  local T = T_REF
  S.vel = { (E[1] - p[1]) / T,
            (S.groundY + body.yOff - p[2]) / T + 0.5 * GRAVITY * T,
            (E[3] - p[3]) / T }
  S.T = T
  paidAndAway()
end

local function tapThrow()
  if S.shot then launchSolve() end
end

local function pointerRelease(at)
  if not S.grab then return end
  S.grab = nil
  local vx, vy, n, peak, tail = flickFit(at or S.clock)
  if not vx or n < 3 then return end          -- a tap, not a throw
  local speed = math.sqrt(vx * vx + vy * vy)
  -- dead flick: the finger braked before lifting -- the player changed
  -- their mind, and the ball drifts back to the hand
  if peak and peak > 0 and tail / peak < 0.10 then return end
  if speed < S_MIN then return end
  if vy / speed > -MIN_UP then return end     -- throws point up the screen
  local def = S.battle:ballDef(S.ballId)
  if def and def.autoCatch then return launchSolve() end
  launchVelocity(vx, vy)
end

-- ------- contact

local function tierFor(rho, inside)
  if not inside then return nil end
  if rho <= 0.30 then return "EXCELLENT" end
  if rho <= 0.70 then return "GREAT" end
  return "NICE"
end

local function beginSuck(cross)
  S.phase = "suck"
  S.t = 0
  S.ballInst.pos = cross
  S.ballInst.tumble, S.ballInst.tumbleAngle = 0, 0
  S.ballInst.spin, S.ballInst.spinAngle = 0, 0
  S.ballInst.roll, S.ballInst.rollAngle = 0, 0
  -- face the foe: the hinge is at the back, so the mouth gapes at it
  local E = S.enemyPos
  S.ballInst.yaw = math.atan2(E[1] - cross[1], E[3] - cross[3]) + math.pi
  S.ballInst:open()
  sound("Ball_Poof")
end

-- The ball has TOUCHED the Pokemon -- contact is a real collision in
-- world space (see the flight step), so any touch opens the ball; the
-- ring's only job is the GRADE, judged in screen space at this instant:
-- inside the shrinking ring earns the tier, outside is a plain hit.
local function resolveContact(cross)
  local shot = S.shot
  local cx, cy, outer = ringGeometry(shot)
  local rho = ringRho(S.ringT)
  local inside = false
  local gx, gy = toGB(shot, cross[1], cross[2], cross[3])
  if gx then
    local dist = math.sqrt((gx - cx) ^ 2 + (gy - cy) ^ 2)
    inside = dist <= rho * outer + 1
  end
  S.tier = tierFor(rho, inside)
  S.rho = rho
  S.hit = true
  -- hang the ball where it struck
  beginSuck({ cross[1], math.max(S.groundY + Pokeball.R, cross[2]),
              cross[3] })
  return true
end

-- ------- the engine roll, and the queue that finishes the fight

local function throwMult()
  return (S.tier and TIER_MULT[S.tier]) or 1.0
end

local function rollCatch()
  local b = S.battle
  local base = S.safari and (b.safariCatchRate or b.enemy.def.catchRate)
               or b.enemy.def.catchRate
  local rate = math.min(255, math.floor(base * throwMult()))
  local caught, shakes = b:catchAttempt(S.ballId, rate)
  S.caught = caught
  S.shakes = caught and 3 or (shakes or 0)
  emit("battle.ball_thrown", { battle = b, ball = S.ballId,
                               caught = caught, shakes = shakes })
end

-- the camera hold's previous value, owned by whoever engaged first -- the
-- battle-long veil under FULL, or a lone session under CATCH ONLY
local heldStill = nil

local function releaseMask()
  if S and S.artBox and S.artBox.data then
    pcall(function() S.artBox.data:release() end)
    S.artBox.data = nil
  end
end

local function endSession(keepScene)
  if not S then return end
  if not keepScene then
    BattleCam.still = heldStill or false
    heldStill = nil
    BattleScene.capture = nil
    releaseMask()
    S = nil
  end
end

-- the catch: the engine's own captured flow, with the fanfare the anim
-- chain would have supplied. The session stays alive as an epilogue so the
-- ball and the stars remain in shot under the caught text; battle.ended
-- sweeps it away.
local function resolveCaught()
  local b = S.battle
  b.lastBall = S.ballId
  -- the experience context has to exist before storeCaughtMon fires the
  -- catch-exp hooks; LetsGo owns the arithmetic
  pcall(function()
    V.require("LetsGo").noteCatch(b, {
      tier = S.tier,
      mult = throwMult(),
      firstThrow = (b.dramaticShapeThrows or 1) == 1,
      safari = S.safari,
    })
  end)
  b.phase = "messages"
  b.afterQueue = "menu"
  b:act(function() sound("Caught_Mon") end)
  b:say(require("src.core.Strings")("All right!\n%s was\ncaught!",
                                    b.enemy.name))
  b:act(function() b:storeCaughtMon() end)
  S.phase = "epilogue"
end

-- a failed throw -- broke out, or never touched the Pokemon at all. The
-- engine's own miss line for the shake count, then the foe's turn, exactly
-- as throwBall's failure path builds it.
--
-- Except under FULL, where a wild encounter IS the catch: the foe never
-- takes a turn, and the session stays alive as "await" -- the moment the
-- miss text clears, the next ball is in the hand. Let's Go wilds do not
-- fight back, and the player is never dropped out of throwing mode.
local function resolveFail(shakes)
  local b = S.battle
  b.lastBall = S.ballId
  b.phase = "messages"
  b.afterQueue = "menu"
  b:say(b:ballMissMessage(shakes))
  if S.fullWild then
    S.phase = "await"
    S.ballInst.visible = false
    S.hit, S.tier, S.planeD = nil, nil, nil
    if BattleScene.capture then BattleScene.capture.shrink = nil end
    return
  end
  if S.safari then
    b:act(function() b:safariEnemyTurn() end)
  else
    b:act(function() b:executeAction(b.enemy, b.player, b:enemyAction()) end)
    b:act(function() b:endOfTurn() end)
  end
  endSession()
end

-- B during the aim. Under FULL it is the encounter's RUN: a Let's Go wild
-- is a catch encounter, so leaving it always works -- the safari's own
-- farewell. Everywhere else it backs out to whatever the session was
-- opened over, refunding a ball the bag menu already consumed.
function CatchThrow.cancel(declined)
  if not (S and S.phase == "aim") then return false end
  local b = S.battle
  if V.log then
    V.log:event("catch", "cancel", {
      declined = declined and "true" or "false",
      fullWild = S.fullWild and "true" or "false",
    })
  end
  if S.fullWild then
    sound("Run")
    b:say(require("src.core.Strings")("Got away safely!"))
    b.result = "run"
    b.phase = "messages"
    b.afterQueue = "finish"
    S.phase = "epilogue"      -- the veil holds until battle.ended sweeps
    return true
  end
  if S.consumed and not S.safari then
    pcall(function()
      require("src.inventory.Bag").add(game().save, S.ballId, 1, game().data)
    end)
  end
  if declined then b.dramaticShapeDeclined = true end
  b.phase = "menu"
  endSession()
  sound("Press_AB")
  return true
end

-- ------- the scene hooks BattleScene consults
--
-- One table on BattleScene while a session runs: the ball's draw and
-- shadow, the foe's shrink, the hidden player side, and the GB overlay.

local function sceneDraw(pull)
  if not S then return end
  S.ballInst:draw(pull)
  if S.phase == "suck" then
    local E = S.enemyPos
    local k = 1 - smoothstep(0, 1, S.t / SUCK_T)
    S.ballInst:drawBeam(E[1], S.groundY + CHEST * 0.8, E[3],
                        3.2 * k + 0.6, 1, pull)
  end
end

local function sceneCast(shadowMap)
  if S then S.ballInst:cast(shadowMap) end
end

local function sceneSig()
  if not S then return "" end
  return S.ballInst:signature() .. "," .. S.phase
end

-- ------- the GB overlay (rings, labels, ball readout)
--
-- Drawn inside the battle's own 160x144 UI canvas, from the BattleState
-- draw wrap, so it composites exactly where the engine's HUD does and
-- comes out with the same chunky letterboxed pixels.

local Font = nil
local function font()
  if Font ~= nil then return Font or nil end
  local ok, F = pcall(require, "src.render.Font")
  Font = ok and F or false
  return Font or nil
end

local function label(str, x, y, align)
  local F = font()
  if not F then return end
  local g = love.graphics
  local w = F.width(str) + 4
  local px = align == "right" and (x - w) or
             align == "center" and math.floor(x - w / 2) or x
  g.setColor(0.06, 0.05, 0.09, 0.75)
  g.rectangle("fill", px, y, w, 11)
  g.setColor(0.93, 0.94, 0.90, 1)
  g.rectangle("fill", px + 1, y + 1, w - 2, 9)
  g.setColor(0, 0, 0, 1)
  F.draw(str, px + 2, y + 2)
  g.setColor(1, 1, 1, 1)
end

-- a tiny ball glyph for the readout
local BALL_TOP = {
  POKE_BALL = { 0.86, 0.16, 0.16 }, GREAT_BALL = { 0.25, 0.45, 0.88 },
  ULTRA_BALL = { 0.22, 0.22, 0.26 }, MASTER_BALL = { 0.48, 0.22, 0.66 },
  SAFARI_BALL = { 0.47, 0.52, 0.26 },
}

local function ballGlyph(x, y, id)
  local g = love.graphics
  local top = BALL_TOP[id] or BALL_TOP.POKE_BALL
  g.setColor(0.93, 0.94, 0.90, 1)
  g.circle("fill", x, y, 4)
  g.setColor(top[1], top[2], top[3], 1)
  g.arc("fill", x, y, 4, math.pi, 2 * math.pi)
  g.setColor(0.08, 0.08, 0.09, 1)
  g.setLineWidth(1)
  g.line(x - 4, y, x + 4, y)
  g.circle("line", x, y, 4)
  g.setColor(1, 1, 1, 1)
end

-- how sure the ring should look: the Gen 1 odds, ball and status included,
-- but never the throw -- a colour that jittered with your own inputs would
-- be unreadable (and is why the reference game excludes it too)
local function ringColor()
  local b = S.battle
  local ok, p = pcall(function()
    local def = b:ballDef(S.ballId)
    if def and def.autoCatch then return 1 end
    local rate = S.safari and (b.safariCatchRate or 0) or b.enemy.def.catchRate
    local randMax = (def and def.randMax) or 255
    return math.max(0.05, math.min(1, (rate + 1) / (randMax + 1)))
  end)
  if not ok then p = 0.5 end
  return 1 - p * 0.75, 0.25 + p * 0.7, 0.28, p
end

local function drawGB(battle)
  if not S or S.battle ~= battle then return end
  local shot = OB().shot()
  if not shot then return end
  S.shot = shot
  local g = love.graphics
  g.push("all")

  -- The empty hand: no ring (nothing will be graded) and no ball readout
  -- (there is no ball) -- just what happened and the way out. On the two
  -- rows the aim HUD already uses, NOT side by side on one: at the GB font
  -- these two strings are ~110 and ~56 pixels wide in a 160 pixel frame,
  -- so a single row draws the second plate straight over the end of the
  -- first ("OUT OF BALL|A/B:RUN").
  if S.phase == "aim" and S.empty then
    label("NO BALLS LEFT", 8, 119)
    label("A/B:RUN", 158, 131, "right")
    g.pop()
    return
  end

  if S.phase == "aim" or S.phase == "flight" then
    local cx, cy, outer = ringGeometry(shot)
    local rho = ringRho(S.ringT)
    g.setLineWidth(1)
    -- outer: fixed, white, the hit area
    g.setColor(1, 1, 1, 0.85)
    g.circle("line", cx, cy, outer)
    -- inner: the timing ring, coloured by the odds
    local r, gr, bl = ringColor()
    g.setColor(r, gr, bl, 0.95)
    g.circle("line", cx, cy, math.max(1.5, rho * outer))
  end

  if S.phase == "aim" then
    -- the ball readout: which ball, how many left
    local count
    if S.safari then
      count = battle.safari and battle.safari.balls or 0
    else
      count = (game().save.inventory[S.ballId] or 0)
             + ((S.consumed and not S.safari) and 1 or 0)
    end
    local name = (game().data.items[S.ballId]
                  and game().data.items[S.ballId].name) or S.ballId
    -- along the bottom edge, out of the throwing lane: with the empty
    -- text box gone the whole middle of the frame is the wind-up, and
    -- chrome parked in it would be something to drag around
    -- " BALL" is dropped from the name: the glyph beside it is already a
    -- ball, in that tier's own colours, and the full string is wide
    -- enough at the GB font to run under the B:BACK plate opposite
    ballGlyph(8, 137, S.ballId)
    label(("%s x%d"):format(name:gsub("%s*BALL%s*", ""), count), 15, 131)
    -- and what B does, which is not the same thing in both modes: under
    -- FULL there is no classic menu behind the throw to back out TO, so B
    -- is the encounter's RUN and the label has to say so
    label(S.fullWild and "B:RUN" or "B:BACK", 158, 131, "right")
    if S.canSwitch then label("L/R:BALL", 15, 119) end

    -- the wind-up readout: sparks orbit the ball as it charges, dim and
    -- slow at a quarter wind, bright gold and quick at the cap -- the cap
    -- is the only wind that curves, so it has to be unmistakable
    if S.spinLevel > 0.12 then
      local bx, by = S.handGB[1], S.handGB[2]
      local orbit = math.max(6, (shot.playerSpan or 16) * 0.2)
      local lvl = S.spinLevel
      if S.spinArmed then
        g.setColor(1, 0.9, 0.35, 1)
      else
        g.setColor(1, 1, 0.75, 0.25 + lvl * 0.55)
      end
      for i = 0, 2 do
        local a = S.clock * (3 + 8 * lvl) * S.spinSign + i * (2 * math.pi / 3)
        g.circle("fill", bx + math.cos(a) * orbit,
                 by + math.sin(a) * orbit * 0.45, S.spinArmed and 1.5 or 1)
      end
    end
  end

  -- the grade, splashed at the ring for a beat after contact
  if S.tier and S.tierSplash and S.tierSplash > 0 then
    local cx, cy = ringGeometry(shot)
    label(S.tier .. "!", cx, math.max(8, cy - 20), "center")
  end

  g.pop()
end

-- ------- ball switching (the FULL entry owns its ball choice)

local SWITCHABLE = { "POKE_BALL", "GREAT_BALL", "ULTRA_BALL", "MASTER_BALL" }

local function ownedBalls()
  local inv = game().save.inventory
  local out = {}
  for _, id in ipairs(SWITCHABLE) do
    if (inv[id] or 0) > 0 then out[#out + 1] = id end
  end
  return out
end

local function switchBall(dir)
  if not (S and S.canSwitch and S.phase == "aim") then return end
  local owned = ownedBalls()
  if #owned == 0 then return end
  local at = 1
  for i, id in ipairs(owned) do
    if id == S.ballId then at = i break end
  end
  S.ballId = owned[((at - 1 + dir) % #owned) + 1]
  S.ballInst.ball = S.ballId
  sound("Press_AB")
end

CatchThrow.pickBall = function()
  local owned = ownedBalls()
  for _, id in ipairs(owned) do
    if id == CatchThrow.lastBall then return id end
  end
  return owned[1]
end

-- The seat, named for the suite: it is a pure function of the arena and the
-- floor height, so the framing and -- the reason it is reachable at all --
-- the PITCH convention it hands BattleScene can both be asserted without a
-- battle, a canvas or a game.
CatchThrow._rig = captureRig

-- ------- session lifecycle

-- The capture table BattleScene consults: one shape, installed by the
-- session OR by the battle-long veil below.
local function installScene()
  if not BattleScene.capture then
    if heldStill == nil then heldStill = BattleCam.still end
    BattleCam.still = true
  end
  BattleScene.capture = {
    hidePlayer = true,
    rig = captureRig,
    draw = sceneDraw,
    cast = sceneCast,
    sig = sceneSig,
    drawGB = drawGB,
    shrink = nil,
  }
end

-- The FULL veil: installed at battle.started for a Let's Go wild, before
-- any session exists, so the whole encounter -- the wipe, the "Wild X
-- appeared!" line, every beat between throws -- plays from the head-on
-- seat with the player's side out of the shot. The player's Pokemon is
-- NEVER shown; the encounter IS the catch.
function CatchThrow.veil(battle)
  installScene()
end

-- opts: consumed (the bag already took the ball), safari (safari flow),
-- canSwitch (aim-time ball cycling), declinable (B backs out / runs),
-- fullWild (Let's Go rules: no foe turns, stay in throw mode, B flees),
-- empty (ballId is nil -- the out-of-balls hand, see rearm below)
function CatchThrow.begin(battle, ballId, opts)
  if S then return false end
  opts = opts or {}
  local empty = opts.empty or ballId == nil
  local ok = pcall(function()
    local arena, groundY = OB().arenaInfo()
    local shot = OB().shot()
    assert(arena and shot and shot.eye, "no staged shot to capture in")
    local ball = Pokeball.new(ballId)
    S = {
      battle = battle,
      ballId = ballId,
      safari = opts.safari or false,
      fullWild = opts.fullWild or false,
      empty = empty,
      consumed = opts.consumed or false,
      canSwitch = (opts.canSwitch and not empty) or false,
      declinable = opts.declinable ~= false,
      phase = "aim",
      clock = 0, t = 0, ringT = 0,
      samples = {}, grab = nil,
      spinLevel = 0, spinArmed = false, spinSign = 1,
      stickHeld = false, stickSamples = {},
      ballInst = ball,
      enemyPos = { arena.enemy[1], groundY, arena.enemy[2] },
      playerPos = { arena.player[1], groundY, arena.player[2] },
      groundY = groundY,
      shot = shot,
      handGB = { 80, 110 },
    }
    ball.pos = handPos()
    ball.visible = not empty
    S.body = { r = 10, yOff = 8, hh = 8 }  -- until a measurement lands
    measureBody()
  end)
  if not ok or not S then
    S = nil
    if V.log then
      V.log:warn("CatchThrow.begin failed ball=%s", tostring(ballId))
    end
    return false
  end
  battle.phase = CatchThrow.PHASE
  if ballId then CatchThrow.lastBall = ballId end
  -- the capture seat, HELD: still drops the drift, the steer and the lift
  -- inside the rig itself, and OverworldBattle's per-frame steerable gate
  -- closes every input that could move it. The player's own steered angle
  -- and lens come back when the hold releases.
  installScene()
  if V.log then
    V.log:event("catch", "begin", {
      ball = ballId or "empty",
      safari = opts.safari and "true" or "false",
      fullWild = opts.fullWild and "true" or "false",
    })
  end
  return true
end

-- The next ball into the hand, without tearing the seat down: FULL's
-- "always in throw mode" between one throw and the next.
--
-- A NIL ball is not a failure to rearm -- it is the empty hand, and it is
-- still capture mode. Running out mid-encounter does not hand the fight
-- back to the classic menu (there is no fight: a Let's Go wild has no
-- player Pokemon in it and the foe never takes a turn, so the menu would
-- offer a FIGHT that cannot happen against a foe that cannot answer).
-- The seat holds, the Pokemon stands there, and the readout says so with
-- the one move that is left.
local function rearm(ballId)
  S.ballId = ballId
  S.empty = ballId == nil
  if ballId then
    CatchThrow.lastBall = ballId
    S.ballInst = Pokeball.new(ballId)
    S.ballInst.pos = handPos()
  else
    S.ballInst.visible = false
    S.canSwitch = false
  end
  S.battle.phase = CatchThrow.PHASE   -- park the engine's menu again
  S.phase = "aim"
  S.clock = 0
  S.samples, S.grab, S.spinPrev = {}, nil, nil
  S.spinLevel, S.spinArmed, S.spinSign = 0, false, 1
  S.stickHeld, S.stickSamples = false, {}
  S.consumed = false
  S.hit, S.tier, S.rho, S.caught, S.shakes, S.planeD = nil, nil, nil, nil,
                                                      nil, nil
  S.tFly, S.tierSplash = 0, nil
end

-- battle.ended sweeps the epilogue, the veil, and any half-open session:
-- a battle torn down by a script must never leave the camera held
function CatchThrow.onBattleEnded()
  releaseMask()
  if heldStill ~= nil or S ~= nil or BattleScene.capture ~= nil then
    BattleCam.still = heldStill or false
  end
  heldStill = nil
  BattleScene.capture = nil
  S = nil
end

-- ------- input entry points (installed once, from LetsGo.install)

local installed = false

-- window coordinates (LOVE units) -> GB frame pixels
local function winToGB(x, y)
  local shot = S and S.shot
  if not shot then return nil end
  local uw, uh = love.graphics.getDimensions()
  if not (uw > 0 and uh > 0) then return nil end
  local px = x * shot.pw / uw
  local py = y * shot.ph / uh
  return (px - shot.lx) / shot.scale, (py - shot.ly) / shot.scale
end

-- An EMPTY hand is not aimable: with no ball there is nothing to drag, so
-- the pointer seams stand down entirely and the mouse/finger goes back to
-- whatever owned it -- rather than the player wrestling an invisible ball
-- around a screen that can never throw it.
local function aiming()
  return S ~= nil and S.phase == "aim" and not S.empty
end

local function pointer(kind, x, y, id)
  local gx, gy = winToGB(x, y)
  if not gx then return end
  if kind == "press" and not S.grab then
    S.grab = { id = id }
    S.samples = {}
    S.spinPrev = nil
    pushSample(gx, gy)
  elseif S.grab and S.grab.id == id then
    pushSample(gx, gy)
    feedSpin(gx, gy)
    if kind == "release" then pointerRelease(S.clock) end
  end
end

-- ------- the BUTTONS, read on the LOGIC STEP rather than the frame
--
-- Everything else in this file is presentational and rides the render
-- frame (Pipelines.update). Button EDGES cannot: Input:step rebuilds
-- `pressed` from scratch once per FIXED step, and Game:update runs the
-- fixed steps for the frame FIRST and Pipelines.update after -- so a
-- frame that runs two steps has already thrown the first step's edges
-- away by the time anything on the render clock looks at them.
--
-- Which is not a rare race. It is every frame below 60fps: the key is
-- queued between frames, the frame's FIRST step promotes it, the SECOND
-- wipes it, and the poll never sees it at all. A 3D battle is exactly
-- where the frame rate goes under, so B-to-run, A-to-throw and the L/R
-- ball switch were all reliably dead on the machines that most needed
-- them and fine on a 144Hz one (where most frames run no step at all and
-- the edge lingers). Read from the pressQueue on the engine's own
-- input.step seam instead: it fires once per logic step, never skipped,
-- with this step's presses still in the queue.
--
-- Taken rather than peeked, so a press the capture consumed does not also
-- page the message it just queued.
local function take(g, btn)
  local q = g and g.input and g.input.pressQueue
  if not q then return false end
  local hit = false
  for i = #q, 1, -1 do
    if q[i] == btn then
      table.remove(q, i)
      hit = true
    end
  end
  return hit
end

function CatchThrow.buttons(g)
  if not (S and S.phase == "aim") then return end
  -- This runs on EVERY logic step for the whole session, so it has to be
  -- certain the fight it is aiming into is still the thing on screen. A
  -- session that outlived its battle -- a script tearing the fight down, a
  -- forced finish, an error between the throw and the sweep -- would
  -- otherwise sit in the overworld silently eating A, B and L/R out of the
  -- queue every step, which reads as "the buttons stopped working" and
  -- points nowhere near here.
  local b = S.battle
  if not b or b.result then return end
  if not (g and g.stack and g.stack:top() == b) then return end
  -- the same beat of deafness the drag has: the A that picked the ball out
  -- of the bag menu is still this step's edge, and must not become a throw
  if S.clock < 0.25 then return end
  if S.empty then
    -- A as well as B: nothing here can be confirmed, so the confirm button
    -- should get the player out rather than do nothing at all
    local b, a = take(g, "b"), take(g, "a")
    if b or a then CatchThrow.cancel(true) end
    return
  end
  if S.declinable and take(g, "b") then
    CatchThrow.cancel(true)
    return
  end
  if take(g, "a") then tapThrow() end
  if take(g, "left") then switchBall(-1) end
  if take(g, "right") then switchBall(1) end
end

function CatchThrow.installInput()
  if installed then return end
  installed = true
  if V.log then V.log:event("input", "CatchThrow.installInput", { ok = "true" }) end

  local Game = require("src.core.Game")

  -- the logic-step seam for the buttons (see above). next_ first, so a
  -- tool mod injecting presses on this hook is read like a controller.
  local mod = V.mod
  if mod and mod.hooks then
    mod.hooks:wrap("input.step", function(next_, g, dt)
      local r = next_(g, dt)
      pcall(CatchThrow.buttons, g)
      return r
    end)
  end

  -- ------- mouse
  --
  -- Installed after CamControl's wraps (see main.lua's install order), so
  -- these are the OUTER ones and the aim owns the button first. Bare
  -- motion is not claimed -- CamControl's battle steer already stands
  -- down while the capture holds the camera (BattleCam.steerable).
  -- Assigning love.* callbacks is blocked by the mod sandbox; wrap the
  -- Game methods that main.lua routes those callbacks into instead.
  do
    local inner = Game.mousepressed
    function Game:mousepressed(x, y, button, istouch, presses)
      if aiming() and not istouch and button == 1 then
        pointer("press", x, y, "mouse")
        return
      end
      if inner then return inner(self, x, y, button, istouch, presses) end
    end
  end
  do
    local inner = Game.mousemoved
    function Game:mousemoved(x, y, dx, dy, istouch)
      if aiming() and not istouch and S.grab and S.grab.id == "mouse" then
        pointer("move", x, y, "mouse")
        return
      end
      if inner then return inner(self, x, y, dx, dy, istouch) end
    end
  end
  do
    local inner = Game.mousereleased
    function Game:mousereleased(x, y, button, istouch, presses)
      if aiming() and not istouch and button == 1
         and S.grab and S.grab.id == "mouse" then
        pointer("release", x, y, "mouse")
        return
      end
      if inner then return inner(self, x, y, button, istouch, presses) end
    end
  end

  -- ------- touch
  --
  -- A finger on open screen is the throw; fingers on the overlay's d-pad
  -- and buttons flow to TouchControls untouched, so B still backs out on
  -- a phone. One finger owns the ball at a time, the FirstPerson rule.
  local TouchControls = require("src.core.TouchControls")
  do
    local inner = Game.touchpressed
    function Game:touchpressed(id, x, y)
      if aiming() then
        local onControl = nil
        pcall(function() onControl = TouchControls:hitTest(x, y) end)
        if not onControl and not S.grab then
          pointer("press", x, y, id)
          return
        end
      end
      return inner(self, id, x, y)
    end
  end
  do
    local inner = Game.touchmoved
    function Game:touchmoved(id, x, y)
      if aiming() and S.grab and S.grab.id == id then
        pointer("move", x, y, id)
        return
      end
      return inner(self, id, x, y)
    end
  end
  do
    local inner = Game.touchreleased
    function Game:touchreleased(id, x, y)
      if aiming() and S.grab and S.grab.id == id then
        pointer("release", x, y, id)
        return
      end
      return inner(self, id, x, y)
    end
  end
end

-- ------- the stick, polled
--
-- FirstPerson's always-on wrap records the right stick whatever the mode,
-- so the session reads it rather than claiming a seam of its own. The
-- stick plays "virtual finger": deflection stands a finger at centre +
-- stick * STICK_R, circling winds the spin, and a hard upward flick of
-- the stick is the throw -- strength from the flick's own velocity.
local function stickInput(dt)
  local FirstPerson = V.require("FirstPerson")
  local sx = FirstPerson.stickX and FirstPerson.stickX() or 0
  local sy = FirstPerson.stickY and FirstPerson.stickY() or 0
  local mag = math.sqrt(sx * sx + sy * sy)

  local st = S.stickSamples
  st[#st + 1] = { x = sx, y = sy, t = S.clock }
  if #st > 16 then table.remove(st, 1) end

  if mag > STICK_GRAB then
    if not S.stickHeld then
      S.stickHeld = true
      if not S.grab then
        S.grab = { id = "stick" }
        S.samples = {}
        S.spinPrev = nil
      end
    end
    if S.grab and S.grab.id == "stick" then
      local gx = S.handGB[1] + sx * STICK_R
      local gy = S.handGB[2] + sy * STICK_R
      pushSample(gx, gy)
      feedSpin(gx, gy)
      -- the flick: stick velocity over the last few samples, upward and
      -- fast. Measured in stick units so a worn pad and a fresh one
      -- answer alike after their deadzones.
      local n = #st
      if n >= 3 then
        local a, b = st[n - 2], st[n]
        local dt2 = b.t - a.t
        if dt2 > 1e-4 then
          local vy = (b.y - a.y) / dt2
          if vy < -STICK_VEL and sy < -0.45 then
            -- hand the same release path the pointer takes; the samples
            -- already trace the gesture in GB pixels
            pointerRelease(S.clock)
            S.stickHeld = false
          end
        end
      end
    end
  elseif S.stickHeld then
    S.stickHeld = false
    if S.grab and S.grab.id == "stick" then
      -- stick returned to centre without the flick: let the fit decide
      -- whether the travel back was itself a throw (it usually is not)
      pointerRelease(S.clock)
    end
  end
end

-- ------- per-frame drive (called from LetsGo.update, before the battle
-- scene renders, so the ball this frame draws is the ball this frame)

function CatchThrow.update(dt)
  if not S then return end
  local b = S.battle
  S.clock = S.clock + dt
  S.ringT = S.ringT + dt
  S.ballInst:update(dt)
  if S.tierSplash then S.tierSplash = S.tierSplash - dt end
  -- the box is back by default and taken away only by the aim branch, so
  -- the first frame with something to say has somewhere to say it
  if BattleScene.capture then BattleScene.capture.hideTextBox = false end

  -- the battle went away under us (forced finish, a script): stand down
  if S.phase ~= "epilogue" then
    local ok, gone = pcall(function()
      return b.result ~= nil and b.result ~= false
    end)
    if ok and gone then
      CatchThrow.onBattleEnded()
      return
    end
  end

  -- the staged shot for this frame's reasoning: last frame's render.
  -- Losing it (a lost context, a broken arena) abandons the session
  -- rather than playing blind.
  local shot = OB().shot()
  if shot then
    S.shot = shot
    S.lostShot = 0
  else
    S.lostShot = (S.lostShot or 0) + dt
    if S.lostShot > 1.0 and S.phase == "aim" then
      CatchThrow.cancel(true)
      return
    end
  end

  if S.phase == "aim" then
    -- ------- the empty hand
    --
    -- No ball, so no drag, no wind-up, no throw and no ring: the seat and
    -- the Pokemon are all that is left, and the only input that means
    -- anything is leaving. A runs as well as B on purpose -- there is no
    -- second choice for it to be confused with, and a player mashing the
    -- confirm button at a screen that cannot confirm anything should get
    -- out rather than get stuck.
    if S.empty then
      if BattleScene.capture then BattleScene.capture.hideTextBox = true end
      return                      -- A/B are read on the logic step, below
    end
    -- the foe's body, if no measurement landed at begin (the texture pass
    -- and the session race on the entry frame; a model needs its pack
    -- warm): retried while aiming, briefly -- the default torso covers a
    -- foe that never answers
    if not S.bodyMeasured and (S.artTries or 0) < 30 then
      S.artTries = (S.artTries or 0) + 1
      measureBody()
    end
    -- The held ball is DRAGGED, riding directly under the finger with no
    -- fence around it (the reference model: the ball follows the hand,
    -- and the throw will be the hand's own velocity). It moves in the
    -- CAMERA-FACING PLANE through its hover -- screen right is the eye's
    -- right, screen up is the eye's own tilted up -- so every part of
    -- the frame maps to somewhere the ball can be: dragging low brings
    -- it down and toward the seat rather than jamming it into the floor.
    -- The floor is the one true limit, and it is the world's, not a box.
    local home = handPos()
    local bob = math.sin(S.clock * 2.2) * 0.35
    local target = { home[1], home[2] + bob, home[3] }
    if S.grab and #S.samples > 0 then
      -- straight down the finger's own ray, at the hand's reach: the ball
      -- is wherever the pointer is, over the WHOLE frame, with no plane
      -- and no box to run into.
      --
      -- The one limit is the world's own floor, and it is not a clamp:
      -- drag low enough that the ray would put the ball underground and
      -- the ball is pulled IN toward the eye instead, which is how a
      -- hand holding it low actually looks. So the bottom of the screen
      -- is reachable everywhere -- the ball simply comes nearer as it
      -- goes down, rather than stopping dead at the grass.
      local last = S.samples[#S.samples]
      local e = S.shot.eye
      local dx, dy, dz = rayThrough(last.x, last.y)
      if dx then
        local reach = math.sqrt((home[1] - e[1]) ^ 2 + (home[2] - e[2]) ^ 2
                                + (home[3] - e[3]) ^ 2)
        if dy < -1e-6 then
          local floor = (e[2] - (S.groundY + Pokeball.R * 1.4)) / -dy
          reach = math.min(reach, math.max(Pokeball.R * 3, floor))
        end
        target = { e[1] + dx * reach, e[2] + dy * reach, e[3] + dz * reach }
      end
    end
    -- direct under the finger, a soft drift when coming home
    local ease = S.grab and math.min(1, dt * 30) or math.min(1, dt * 9)
    local bp = S.ballInst.pos
    bp[1] = bp[1] + (target[1] - bp[1]) * ease
    bp[2] = bp[2] + (target[2] - bp[2]) * ease
    bp[3] = bp[3] + (target[3] - bp[3]) * ease
    -- face the seat, so the wind-up's roll reads as the ball turning
    -- clockwise/counter-clockwise to the player watching it
    S.ballInst.yaw = eyeYaw(bp[1], bp[3])
    local gx, gy = toGB(S.shot, bp[1], bp[2], bp[3])
    if gx then S.handGB = { gx, gy } end

    -- the wind-up meter: bleeds once the hand pauses, and the ball's
    -- visible roll IS the meter -- faster the more it is wound
    if S.spinLevel > 0 and S.clock - (S.spinT or 0) > SPIN_IDLE then
      S.spinLevel = math.max(0, S.spinLevel - SPIN_DECAY * dt)
    end
    if S.spinArmed and S.spinLevel < DISARM_AT then S.spinArmed = false end
    S.ballInst.roll = -S.spinSign * S.spinLevel * ROLL_MAX
    -- the empty text box is off the frame while aiming, which is what
    -- gives the drag the bottom third of the screen to wind up in
    if BattleScene.capture then BattleScene.capture.hideTextBox = true end

    stickInput(dt)
    -- B, A and the L/R ball switch are NOT read here: button edges do not
    -- survive the render clock (CatchThrow.buttons, on the logic step)
    return
  end

  -- FULL, between throws: the miss text is playing, the seat is held, and
  -- the moment the engine offers the menu the next ball is in the hand
  -- instead -- or, when that was the last ball, the empty hand is (rearm
  -- takes nil for exactly this). Either way the capture screen stays up.
  if S.phase == "await" then
    if S.battle.phase == "menu" then rearm(CatchThrow.pickBall()) end
    return
  end

  if S.phase == "flight" then
    S.acc = S.acc + dt
    local E = S.enemyPos
    -- The foe's GEOMETRY, not a blob. A pic foe is judged against its own
    -- art: crossing the card's plane samples the sprite's opaque pixels
    -- (dilated by the ball's radius and a mercy margin), so a ball through
    -- the gap under a wing flies on and one that clips the wing connects.
    -- A model foe is an ellipsoid at its measured height and footprint;
    -- the default torso covers a foe that never answered.
    local body = S.body or { r = 10, yOff = 8, hh = 8 }
    local box = S.artBox
    local fx, fz, rx, rz = camBasis(S.shot)
    local kPic = 16 / 56                       -- world px per pic px
    local dilate = (Pokeball.R * 1.6 + 2) / kPic
    local sr = body.r * 1.3 + Pokeball.R + 1.5 -- ellipsoid semi-axes
    local sh = (body.hh or body.r) + Pokeball.R + 1
    while S.acc >= H_STEP do
      S.acc = S.acc - H_STEP
      local p, v = S.ballInst.pos, S.vel
      local ax, ay, az = 0, -GRAVITY, 0
      if S.spinArmed then
        local w = smoothstep(CURVE_RAMP0, CURVE_RAMP1, S.tFly / S.T)
        ax = ax + rx * CURVE_GAIN * S.spinSign * w
        az = az + rz * CURVE_GAIN * S.spinSign * w
      end
      v[1], v[2], v[3] = v[1] + ax * H_STEP, v[2] + ay * H_STEP,
                         v[3] + az * H_STEP
      p[1] = p[1] + v[1] * H_STEP
      p[2] = p[2] + v[2] * H_STEP
      p[3] = p[3] + v[3] * H_STEP
      S.tFly = S.tFly + H_STEP

      if not S.hit then
        local contact = false
        if box and box.data then
          -- the card's plane through the foe's cell, crossed this step?
          local d1 = (p[1] - E[1]) * fx + (p[3] - E[3]) * fz
          if (S.planeD or -1) < 0 and d1 >= 0 then
            -- where the ball stands ON the art, in pic pixels
            local ux = (p[1] - E[1]) * rx + (p[3] - E[3]) * rz
            local px = box.ax + ux / kPic
            local py = box.ay - (p[2] - S.groundY) / kPic
            contact = maskHit(box.data, px, py, dilate)
          end
          S.planeD = d1
        else
          local dx = (p[1] - E[1]) / sr
          local dy = (p[2] - (S.groundY + body.yOff)) / sh
          local dz = (p[3] - E[3]) / sr
          contact = dx * dx + dy * dy + dz * dz <= 1
        end
        if contact then
          resolveContact({ p[1], p[2], p[3] })
          S.tierSplash = S.tier and 1.0 or nil
          return
        end
      end

      -- short or wide: the ground takes it, with a couple of tired hops
      if p[2] <= S.groundY + Pokeball.R and v[2] < 0 then
        p[2] = S.groundY + Pokeball.R
        v[2] = -v[2] * 0.35
        v[1], v[3] = v[1] * 0.55, v[3] * 0.55
        S.ballInst.tumble = S.ballInst.tumble * 0.5
        if math.abs(v[2]) < 12 then v[2] = 0 end
      end
    end
    if S.tFly > S.T + 1.2 then
      S.ballInst.visible = false
      resolveFail(0)                          -- "You missed the POKéMON!"
    end
    return
  end

  if S.phase == "suck" then
    S.t = S.t + dt
    local k = 1 - smoothstep(0, 1, S.t / SUCK_T)
    BattleScene.capture.shrink = math.max(0.02, k)
    if S.t >= SUCK_T then
      S.ballInst:close()
      S.phase = "drop"
      S.t = 0
      -- the roll happens NOW, so the wobble count is honest
      rollCatch()
      local p = S.ballInst.pos
      S.dropFrom = { p[1], p[2], p[3] }
      -- land a step toward the camera from the foe's feet
      local fx, fz = camBasis(S.shot)
      S.dropTo = { S.enemyPos[1] - fx * 5, S.groundY + Pokeball.R,
                   S.enemyPos[3] - fz * 5 }
    end
    return
  end

  if S.phase == "drop" then
    S.t = S.t + dt
    local u = math.min(1, S.t / DROP_T)
    local p0, p1 = S.dropFrom, S.dropTo
    -- a dropped arc: linear across, gravity-shaped down, one bounce
    local h = (1 - u) * (p0[2] - p1[2])
    local bounce = 0
    if u > 0.82 then
      bounce = math.abs(math.sin((u - 0.82) / 0.18 * math.pi)) * 1.2 * (1 - u)
    end
    S.ballInst.pos = { p0[1] + (p1[1] - p0[1]) * u,
                       p1[2] + h * (1 - u * 0.4) + bounce,
                       p0[3] + (p1[3] - p0[3]) * u }
    if u >= 1 then
      S.ballInst.pos = { p1[1], p1[2], p1[3] }
      S.phase = "wobble"
      S.t = -0.35                             -- a beat before the first rock
      S.shakeIx = 0
      sound("Tink")
    end
    return
  end

  if S.phase == "wobble" then
    S.t = S.t + dt
    if S.ballInst:busy() then return end
    if S.t < SHAKE_GAP then return end
    if S.shakeIx < S.shakes then
      S.shakeIx = S.shakeIx + 1
      S.t = 0
      S.ballInst:rock(S.shakeIx % 2 == 0 and 1 or -1)
      sound("Tink")
    elseif S.caught then
      S.phase = "clicked"
      S.t = 0
      S.ballInst:catchClick()
    else
      -- the breakout: the ball bursts, the foe pours back out
      S.phase = "burst"
      S.t = 0
      S.ballInst:burst()
      sound("Ball_Poof")
    end
    return
  end

  if S.phase == "clicked" then
    S.t = S.t + dt
    if S.t >= 0.9 then resolveCaught() end
    return
  end

  if S.phase == "burst" then
    S.t = S.t + dt
    local k = smoothstep(0, 1, S.t / 0.3)
    BattleScene.capture.shrink = k >= 0.98 and nil or math.max(0.02, k)
    if S.t >= 0.55 then
      BattleScene.capture.shrink = nil
      S.ballInst.visible = false
      resolveFail(S.shakes)
    end
    return
  end

  -- epilogue: the ball rests in shot while the caught text plays; the
  -- stars fade on their own, and battle.ended clears the table
end

return CatchThrow
