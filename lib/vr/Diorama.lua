-- The DIORAMA modes: Kanto as a model you can pick up.
--
-- STANDARD VR presents whatever rung the player is on -- the orbit rungs
-- become a tabletop, 1ST stands you inside the world (see lib/VR.lua).
-- DIORAMA is a different promise, and it is one promise rather than a
-- ladder: the world is ALWAYS the model on the table, seen from outside,
-- and what the headset adds is that the model is a THING IN THE ROOM --
-- grab it, turn it, set it down somewhere else, decide how much of it you
-- want to be holding.
--
-- Two pieces make that read, and this file owns both.
--
--   THE VIEWPORT. Everything outside an invisible BOX centred on the view
--   is simply not drawn -- the Final Fantasy Tactics read, a square slab
--   of the world sitting in the air rather than a map running off to a
--   horizon. A square cut with a HARD edge, because a flat world is a
--   thing with sides and the sides are what say so.
--
--   V-CURVE is what changes its shape. With the bend on, the world is not
--   flat any more -- it is a little globe curling away over its own
--   horizon -- and a square cut through a globe is a lie about what is
--   being looked at. So the box becomes a BALL, and its rim becomes a
--   GRADIENT that dissolves into the sky rather than an edge that
--   guillotines it. One click of the left stick (which throws V-CURVE --
--   see lib/VR) swaps between the two readings of the same model.
--
--   A staged fight ignores both and cuts a vertical PILLAR about the
--   arena, which lifts the fight out of the map as a floating disc.
--
--   (A BASE was built under all this once -- the ground extruded a tile
--   deep, cut to the viewport's shape, wearing Mt Moon's cave floor down
--   its sides -- and it was REMOVED at the user's request. The cut ends at
--   the ground plane now; don't put a plinth back under it.)
--
--   THE GRIP. Squeeze one and the model follows that hand through the
--   room; squeeze both and it turns with them and the viewport resizes
--   to whatever you open your hands to. All of it is arithmetic on the
--   XR-to-world mapping lib/VRRig already had (an anchor, a yaw and a
--   scale), so nothing about the world's own geometry knows this is
--   happening.
--
-- DIORAMA-MR is the same mode with the background keyed pure green, for
-- a mixed-reality capture that composites the model into the room the
-- player is actually standing in.
--
-- Nothing here reaches the flat screen: every field is set by lib/VR for
-- the length of one headset frame and cleared with the session.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Diorama = {}

-- ------- the viewport
--
-- The half-size at rest, as a fraction of the view height the flat screen
-- frames. Sized off the VIEW rather than fixed in world pixels so the zoom
-- rows keep meaning what they mean -- a zoomed-in rung frames less world
-- and gets a smaller model, exactly as it frames a smaller picture.
--
-- The BOX takes half of it, so the square is exactly the view the standard
-- rung would have shown, edge to edge. The BALL takes rather more: a ball
-- inscribed in that square holds noticeably less world (its corners are
-- the four biggest pieces of it), and the point of the V-CURVE throw is to
-- see the same model curl, not to lose a quarter of it.
Diorama.BOX_FRAC = 0.5
Diorama.BALL_FRAC = 0.62

-- How far the grips may open and close it, as a multiplier on that.
Diorama.SCALE_MIN = 0.3
Diorama.SCALE_MAX = 4

-- The rim under V-CURVE, as a fraction of the radius: where the world
-- starts fading and where it has finished. Wide enough to read as a
-- dissolve rather than an edge, narrow enough that the middle of the model
-- is solid. The BOX has no fade at all -- see fadeFor.
Diorama.FADE_FRAC = 0.16

-- The staged fight's disc: the arena's own half-length plus an apron, in
-- world pixels (a map cell is 16). The two mons stand three cells apart,
-- so this is a disc about seven cells across -- the fight, the ground it
-- is fought on, and nothing else.
Diorama.ARENA_APRON = 32

-- ------- what the live frame is
--
-- All three set by lib/VR for the length of one headset frame, and by
-- nothing else. `on` is the whole mode's gate; VoxelScene reads it once
-- per frame and every diorama-shaped thing hangs off that read.
Diorama.on = false
Diorama.keyed = false
Diorama.cull = nil        -- { x, y, z, r, invFade, kind }

-- Chroma green, and PURE green deliberately: a keyer wants the one colour
-- nothing in the picture can accidentally be, and no palette this mod can
-- paint the world in reaches 0,255,0.
Diorama.KEY_COLOR = { 0, 1, 0 }

-- ------- what the grips have done to it
--
-- Kept across frames (this is where the model IS, as far as the player is
-- concerned) and cleared only when the session ends. `offset` is in LOCAL
-- metres and rides the mapping's anchor, `yaw` turns the mapping, `zoom`
-- multiplies the viewport's radius.
Diorama.offset = { 0, 0, 0 }
Diorama.yaw = 0
Diorama.zoom = 1

function Diorama.reset()
  Diorama.on, Diorama.keyed, Diorama.cull = false, false, nil
  Diorama.offset = { 0, 0, 0 }
  Diorama.yaw, Diorama.zoom = 0, 1
  Diorama.release()
end

-- ------- which way a staged fight lies on the table
--
-- The disc's bearing while a battle is up: the player's own hand-turn, with
-- the ARENA's quarter turn taken back out of it.
--
-- An arena may be laid down any of the four ways (BattleArena's `turn`), and
-- the promise that field makes everywhere else is that turning it changes the
-- GROUND under the fight and never the fight itself -- the two Pokemon land
-- on the same marks, seen the same way round. Every other camera keeps that
-- promise by construction: the flat shot and the standard VR mount are both
-- built from BattleCam's eye, which turns with the arena, so the composition
-- follows it round.
--
-- This one is not built from that eye. It is a disc of map lifted onto the
-- table, and its bearing is the arena's bearing in the WORLD -- so a fight
-- staged on a turned arena arrived on the table lying across the head that
-- was looking at it, while the same fight on an unturned one faced properly.
-- Same fight, same composition everywhere else, sideways here.
--
-- So the turn comes back out. Subtracted, matching the sign the standard
-- mount already lands on: its yaw is atan2 of (eye - focus), and rotating
-- that pair by +turn takes the bearing to (bearing - turn). One rule, two
-- seats.
--
-- The hand-turn stays on top of it, because that is the player moving the
-- model and is theirs to keep.
function Diorama.battleYaw(arena)
  local turn = (arena and arena.turn) or 0
  if turn == 0 then return Diorama.yaw end
  local yaw = Diorama.yaw - math.rad(turn)
  -- kept in (-pi, pi] like the grips leave it, so nothing downstream has to
  -- care which way round it came
  return (yaw + math.pi) % (2 * math.pi) - math.pi
end

-- Open a diorama frame. `mode` is VR.mode()'s answer; anything that is
-- not a diorama mode closes it.
function Diorama.begin(mode)
  Diorama.on = (mode == "diorama" or mode == "diorama-mr")
  Diorama.keyed = Diorama.on and mode == "diorama-mr"
  if not Diorama.on then Diorama.cull = nil end
  return Diorama.on
end

function Diorama.stop()
  Diorama.on, Diorama.keyed, Diorama.cull = false, false, nil
end

-- What the world's background must be cleared to, or nil to leave the sky
-- alone. Only ever a colour in DIORAMA-MR, and only while a frame is open.
function Diorama.keyColor()
  if not (Diorama.on and Diorama.keyed) then return nil end
  return Diorama.KEY_COLOR
end

-- ------- the viewport, as the shaders take it
--
-- `kind` is the shader's own switch: 0 no cut, 1 the box, 2 the ball, 3
-- the fight's pillar. `invFade` is one over the fade band in world pixels,
-- so the rim is a single multiply out there -- and a hard edge is simply a
-- band under a pixel wide, which costs the shader no branch of its own.
Diorama.BOX = 1
Diorama.BALL = 2
Diorama.PILLAR = 3

-- The half-size the viewport stands at right now, for a view `vh` world
-- pixels tall -- the flat framing this rung would have shown -- and for
-- the shape it is currently in.
function Diorama.radius(vh, curved)
  local frac = curved and Diorama.BALL_FRAC or Diorama.BOX_FRAC
  return math.max(24, (vh or 288) * frac * Diorama.zoom)
end

-- Whether the world is BENT right now, which is the whole of what decides
-- the viewport's shape: a square cut suits a flat slab of map, and a
-- curved world rolling away over its own horizon wants a ball with a
-- dissolve. Asked of the row rather than remembered, so the V-CURVE the
-- stick click throws (and the "7" key, and the OPTIONS row) all reach it.
function Diorama.curved()
  local ok, on = pcall(function()
    return V.require("WorldCurve").active()
  end)
  return ok and on or false
end

-- The fade band for a cut of half-size `r`: the curve's dissolve, or a
-- hard edge (band 0) for the box.
function Diorama.fadeFor(r, curved)
  if not curved then return 0 end
  return math.max(1, r * Diorama.FADE_FRAC)
end

local function volume(kind, x, y, z, r, fade)
  return { x = x, y = y, z = z, r = r,
           -- The BOX kind is rectangular in the shader, because the flat
           -- screen's box is the WINDOW's own footprint and a window is not
           -- square (lib/ViewBox). A headset's model has no window to be
           -- shaped like, so this one is: the same half-size twice.
           rx = r, rz = r,
           -- a zero band is a hard edge: half a pixel of ramp, which is
           -- one pixel of antialiasing rather than a stair
           invFade = 1 / math.max(fade or 0, 0.5), kind = kind }
end

-- The viewport this frame, centred on the world point the model is pinned
-- by: the BOX ordinarily, and the BALL while the world is curved.
function Diorama.viewport(cx, cy, vh)
  local curved = Diorama.curved()
  local r = Diorama.radius(vh, curved)
  Diorama.cull = volume(curved and Diorama.BALL or Diorama.BOX,
                        cx, 0, cy, r, Diorama.fadeFor(r, curved))
  return Diorama.cull
end

-- The staged fight's disc: a vertical pillar about the arena's midpoint,
-- wide enough for both mons and their apron. Vertical means UNBOUNDED --
-- a tree standing on the disc keeps all of its height, which is what
-- makes the cut read as the ground having been lifted out rather than as
-- the world having been sliced through at eye level.
function Diorama.pillar(arena)
  if not (arena and arena.mid) then return nil end
  local mx, mz = arena.mid[1], arena.mid[2]
  local r = Diorama.ARENA_APRON
  if arena.player and arena.enemy then
    local dx = arena.player[1] - mx
    local dz = arena.player[2] - mz
    r = r + math.sqrt(dx * dx + dz * dz)
  end
  -- Round whatever the curve is doing -- a fight is a disc, and a square
  -- arena tile floating in the air is not the picture -- and ALWAYS
  -- dissolved at the rim, curve or no curve. The box's hard edge is there
  -- to say "this is a flat slab of map with sides"; a fight is a thing
  -- lifted out of the world and hanging in the air, and a hard edge on it
  -- reads as a cookie cutter rather than as a piece of ground.
  Diorama.cull = volume(Diorama.PILLAR, mx, 0, mz, r,
                        Diorama.fadeFor(r, true))
  return Diorama.cull
end

-- ------- the grips
--
-- One hand carries the model; two turn it and open the viewport. The
-- gesture is measured as a DELTA per frame rather than from where the
-- squeeze started, so letting go and taking hold again never snaps
-- anything -- the model simply stops following and starts again.

Diorama.GRIP = 0.6              -- squeezed past this counts as holding on
Diorama.SPREAD_MIN = 0.08       -- hands closer than this give no scale

local lastOne = nil             -- the carrying hand's position, last frame
local lastMid = nil             -- both hands' midpoint
local lastAngle = nil           -- and the bearing of the line between them
local lastSpread = nil          -- and its length

local function clearGrab()
  lastOne, lastMid, lastAngle, lastSpread = nil, nil, nil, nil
end

Diorama.releaseGrab = clearGrab

-- Advance the grab from this frame's controller state (lib/VRXR's table:
-- gripL/gripR in 0..1, handl/handr as { pos, quat } when tracked).
-- Returns true while the model is being held.
function Diorama.gesture(ctl)
  if not ctl then
    clearGrab()
    return false
  end
  local gl, gr = ctl.gripL or 0, ctl.gripR or 0
  local hl = (gl > Diorama.GRIP) and ctl.handl or nil
  local hr = (gr > Diorama.GRIP) and ctl.handr or nil

  if hl and hr then
    lastOne = nil
    local lp, rp = hl.pos, hr.pos
    local mid = { (lp[1] + rp[1]) / 2, (lp[2] + rp[2]) / 2,
                  (lp[3] + rp[3]) / 2 }
    local dx, dy, dz = rp[1] - lp[1], rp[2] - lp[2], rp[3] - lp[3]
    local spread = math.sqrt(dx * dx + dy * dy + dz * dz)
    -- the bearing of the line between the hands, in the same convention
    -- the mapping's yaw turns through (see VRRig.eyeCamera): atan2 of the
    -- x component over the z one, so a hand-over-hand turn and the model's
    -- turn are the same number
    local angle = math.atan2(dx, dz)
    if lastMid then
      for i = 1, 3 do
        Diorama.offset[i] = Diorama.offset[i] + (mid[i] - lastMid[i])
      end
    end
    if lastAngle then
      local d = (angle - lastAngle + math.pi) % (2 * math.pi) - math.pi
      Diorama.yaw = (Diorama.yaw + d + math.pi) % (2 * math.pi) - math.pi
    end
    if lastSpread and lastSpread > Diorama.SPREAD_MIN
       and spread > Diorama.SPREAD_MIN then
      Diorama.zoom = math.max(Diorama.SCALE_MIN,
                       math.min(Diorama.SCALE_MAX,
                                Diorama.zoom * (spread / lastSpread)))
    end
    lastMid, lastAngle, lastSpread = mid, angle, spread
    return true
  end

  lastMid, lastAngle, lastSpread = nil, nil, nil
  local one = hl or hr
  if one then
    if lastOne then
      for i = 1, 3 do
        Diorama.offset[i] = Diorama.offset[i] + (one.pos[i] - lastOne[i])
      end
    end
    lastOne = { one.pos[1], one.pos[2], one.pos[3] }
    return true
  end
  lastOne = nil
  return false
end

-- Nothing here owns a GPU object any more (the base did, and it is gone --
-- see the header), so this is only the grab's own hand-to-hand state: a
-- window resize or a hot reload should not leave the model following a
-- delta measured against a frame that no longer exists.
function Diorama.release()
  clearGrab()
end

Diorama.invalidate = Diorama.release

return Diorama
