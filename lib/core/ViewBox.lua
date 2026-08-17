-- RENDER DIST: how much of the map the orbit rungs bother to draw.
--
-- lib/Diorama cuts a headset's model out of the world with a box the
-- player opens and closes with their hands. This is the same cut on the
-- flat screen, asked the other way round: not "how much world do I want to
-- be holding" but "how much world can this camera actually SEE" -- so that
-- nothing off screen is drawn, and nothing on screen is missing.
--
-- THE FOOTPRINT IS NOT THE WINDOW. That is the whole difficulty, and the
-- first cut of this file got it wrong: it took the flat game's own vw-by-vh
-- rectangle about the view centre, which is exactly right at 0 degrees and
-- wrong at every rung the mode actually has. Tilt the camera and the ground
-- it frames stops being that rectangle and becomes a TRAPEZOID -- reaching
-- much further north (the far edge of the frame is further away, so it
-- covers more ground per pixel), flaring much wider there for the same
-- reason, and pulling IN at the south edge, which is nearer the eye than
-- the focus is. A window-sized box cuts the north field and both far
-- corners off a world that is plainly on screen: gaps at the top and down
-- the sides, with sky showing through them.
--
-- So the footprint is derived from the camera rather than guessed. The
-- orbit is one number (see Voxel3D.viewProjection): eye at distance
-- FOCAL*vh, pitched `a` off straight down, looking at the view centre,
-- with a fov chosen so a straight-down camera frames exactly vh. Cast the
-- frame's own corner rays at the ground plane and the trapezoid falls out
-- in closed form -- see footprint() for the derivation, which is three
-- lines of algebra and no tuning at all.
--
-- AND THE GROUND IS NOT THE PICTURE. The trapezoid is where the frame's
-- rays LAND; what is drawn is what stands on it, and a tree at the bottom
-- of the screen has its feet south of the row its top is seen on. Cut to
-- the trapezoid alone, the box takes that tree away whole -- the cut is by
-- column, so a base one pixel outside loses the whole height -- and the
-- bottom of the frame reads as a bite taken out of the scenery. So the
-- south edge is walked back down the bottom ray by the tallest thing that
-- can stand there; see lift().
--
-- The CUT is still a rectangle (the shader's box kind), so what is stored
-- is the trapezoid's bounding rect: never narrower than the picture, so it
-- can never take a bite out of it. It is off-centre in z, because the
-- trapezoid is -- the box sits north of the view centre at every rung but
-- the top one.
--
-- THE HORIZON IS WHY THERE IS A ROW AT ALL. Past about 63 degrees (exactly
-- atan(2*FOCAL), where the top of the frame lifts off the ground plane) the
-- trapezoid stops being finite: the camera can see to the horizon, and "all
-- the ground on screen" is an infinite answer. Something has to name a
-- distance, and that is what RENDER DIST names -- MAX_REACH view heights,
-- times the row's own multiplier. Below that pitch the row does nothing to
-- the picture at all, because the honest footprint is already smaller than
-- the reach; at 75 it is what decides where the world ends.
--
-- AND IT PAYS FOR ITSELF. A cut this file can describe in world pixels is
-- one VoxelScene can test a whole neighbour map against BEFORE drawing it
-- -- see shows() -- so a connected map that lands entirely outside the box
-- costs no terrain mesh, no water, no grass, no flowers and no shadow
-- pass. Most of the win is at the HIGH rungs, where the camera is nearly
-- overhead and the footprint is barely bigger than the window; at 75 it
-- sees half the region and skips almost nothing, which is the truth about
-- that rung rather than a shortcoming of the test.
--
-- WHAT IT DOES NOT TOUCH. The free-roam rungs (1ST and 3RD): the player is
-- standing IN the world there, and a box around a walking eye is a
-- fog-of-war circle rather than a model on a table. The rung tween into
-- them opens the box out with the blend rather than dropping it on a
-- frame, so diving into a head does not pop the sides away. A headset's
-- frame is not touched either -- lib/Diorama owns the cut there, and VR's
-- STANDARD rungs are a tabletop already.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ModSetting = V.require("ModSetting")

local ViewBox = {}

ViewBox.KEY = "viewbox"
-- RENDER DIST rather than a V- name like the rows either side of it: what
-- the player is choosing is HOW MUCH WORLD gets drawn, which is the thing
-- every game with this row calls a render distance. The mode read -- the
-- slab with sides -- is what that buys, not what the row is asking.
ViewBox.LABEL = "RENDER DIST"

-- The ladder, as a multiplier on the footprint the camera actually frames.
-- Rung 0 is FIT and it is the default, and FIT means exactly that: the
-- ground on screen and no more. It cannot open a gap -- 1.0 times the
-- honest answer is the honest answer -- so the only thing the wider rungs
-- buy below the horizon pitch is margin around a cut nobody can see.
--
-- Where they DO decide the picture is at 75, and at the tween rungs either
-- side of it, where the footprint is infinite and MAX_REACH below stands in
-- for it: there the ladder is a real render distance and FIT is the closest
-- horizon of the four.
--
-- Geometric rather than even, for the reason WorldCurve's ladder is: what
-- the player sees change between two rungs is the AREA inside the box, and
-- that goes as the square -- even steps bunch the whole ladder at the
-- near end.
--
-- The last rung is 0, which is no cut at all. It sits at the TOP because
-- "everything" is where the ladder is going: FIT, wider, wider, wider,
-- all of it.
ViewBox.FRACS = { 1.0, 1.5, 2.25, 3.5, 0 }

ViewBox.setting = ModSetting.new(ViewBox.KEY, ViewBox.LABEL,
                                 { 0, 1, 2, 3, 4 },
                                 { "FIT", "WIDE", "WIDER", "WIDEST", "OFF" })

-- How far the world may reach when the camera can see the HORIZON and the
-- honest footprint is infinite, in view heights. Generous on purpose: this
-- is a backstop for an unbounded answer, not a curtain to draw across the
-- middle distance, and it wants to land well past the edge of the loaded
-- neighbourhood so the world runs out before the cut does. Multiplied by
-- the row, so a player who can see the seam can push it away.
ViewBox.MAX_REACH = 6

-- ------- the geometry standing on the ground it frames
--
-- The footprint is where the frame's rays hit the GROUND, and the ground is
-- not what the picture is made of. A tree is most of a hundred world pixels
-- tall, and a point that high up on the BOTTOM edge's own ray sits south of
-- where that ray lands -- nearer the eye, because the ray is coming down. So
-- the bottom of the screen is full of things whose feet are outside the
-- ground trapezoid, and a box cut to the trapezoid alone takes them away
-- whole: the shader cuts a fragment by the column it stands in (Voxel3D's
-- dioramaCull is unbounded upward, deliberately, so a cut never takes the
-- tops off trees), so a tree one pixel south of the edge loses its whole
-- height at once. That is a bite along the bottom of the picture -- a row of
-- trees cut through by the frame's own edge, with the ground behind them
-- showing.
--
-- HEIGHT is the tallest thing standing on that ground, and it is the sun
-- pass's own figure for the same reason it needs one: how far outside the
-- ground it fits can something still reach the picture? Kept here rather
-- than read across so this file's cut does not move when the light's
-- frustum is retuned; they answer to the same world either way.
ViewBox.HEIGHT = 160

-- And a tile of slack on top, at every pitch. The cut's south edge would
-- otherwise land on the frame's own bottom row at the rungs where the term
-- below is zero, which is a hard edge (see FADE_FRAC) balanced on the
-- pixel it is drawn at -- a supersampled frame (lib/AntiAlias) resolves
-- half of it. One tile is cheap and no cut this file makes should be
-- decided by a rounding.
ViewBox.SOUTH_PAD = 16

-- How much further south than the ground it lands on the bottom edge of the
-- frame can still show, in world pixels.
--
-- At sy = -1 the ray direction (see footprint) is
--
--     d = (0, -(cos a + tanY sin a), -(sin a - tanY cos a))
--
-- in (x, y, z) with y up and -z north, so climbing it costs
--
--     (sin a - tanY cos a) / (cos a + tanY sin a)
--
-- of south per world pixel of height. Zero at and below atan(tanY) -- about
-- 26 degrees with FOCAL 1, where the ray is shallower than the frame's own
-- half-angle and a RAISED point lands north of the ground hit, which no cut
-- can lose -- a tile and a half at 35, four at 50, and a good eleven at 75,
-- where the eye is nearly level and a tree is nearly all of what is under
-- the bottom of the frame.
function ViewBox.lift(a)
  local Voxel = V.require("VoxelState")
  local tanY = 1 / (2 * (Voxel.FOCAL or 1))
  local ca = math.max(math.cos(a or 0), 1e-3)
  local sa = math.max(math.sin(a or 0), 0)
  local rise = (sa - tanY * ca) / (ca + tanY * sa)
  if rise <= 0 then return 0 end
  return ViewBox.HEIGHT * rise
end

-- The rim under V-CURVE, as a fraction of the shorter half-extent, and for
-- the reason Diorama.FADE_FRAC exists: a bent world has no straight sides,
-- so a hard edge across one is a lie about what is being looked at. Flat,
-- the box keeps its hard edge -- that IS the sides.
ViewBox.FADE_FRAC = 0.16

-- How far outside the box a map may still have geometry inside it: the
-- border ring ChunkMesher meshes around a body (RING = 3 blocks of 32
-- world pixels), which is the one thing a map draws beyond its own
-- rectangle. A neighbour kept by this margin that turns out to be entirely
-- outside is drawn and then cut per fragment, which is what would have
-- happened without the test -- the margin can only cost a draw, never a
-- hole.
ViewBox.PAD = 96

function ViewBox.level()
  return ViewBox.setting:get() or 0
end

-- The multiplier in force, or nil for OFF -- which is also every caller's
-- "there is no cut this frame" answer.
function ViewBox.frac()
  local f = ViewBox.FRACS[ViewBox.level() + 1]
  if not f or f <= 0 then return nil end
  return f
end

-- Whether this rung is one the box is about: an ORBIT rung, which is every
-- level the mode has except OFF (level 0, where there is no 3D pass to cut)
-- and the two free-roam rungs (see the header).
function ViewBox.appliesTo(level)
  local ok, applies = pcall(function()
    local Voxel = V.require("VoxelState")
    local l = level or Voxel.level or 0
    return l > 0 and not Voxel.isFreeCam(l)
  end)
  return ok and applies or false
end

-- ------- what the live frame is
--
-- Set by VoxelScene for the length of one flat frame and cleared with it,
-- exactly as Diorama's is for a headset's. Nothing else writes it, and
-- every reader -- the shader uniforms, the neighbour skip -- hangs off this
-- one field being nil or not.
ViewBox.cull = nil        -- { x, y, z, r, rx, rz, invFade, kind }

local function curved()
  local ok, on = pcall(function()
    return V.require("WorldCurve").active()
  end)
  return ok and on or false
end

-- How far out of the orbit and into a walking head the rung tween has got,
-- 0..1. The box opens out by one over what is LEFT of the orbit, so it has
-- grown past every edge of the frame by the time the eye arrives in the
-- head and the cut is dropped -- rather than the sides vanishing on the
-- frame the rung number changed, which is a pop in the middle of a move.
local function orbitLeft()
  local ok, blend = pcall(function()
    return V.require("FirstPerson").blendEased()
  end)
  if not ok or type(blend) ~= "number" then return 1 end
  return 1 - math.max(0, math.min(1, blend))
end

-- ------- the ground this camera frames
--
-- The orbit (Voxel3D.viewProjection's else branch) is: eye at distance
-- k = FOCAL*vh, pitched `a` off straight down and due south of the focus;
-- focus on the ground at the view centre; a symmetric frustum whose
-- half-tangents are tanY = 1/(2*FOCAL) vertically and tanY*(vw/vh)
-- horizontally. Screen coordinates run sx, sy in [-1, 1] with sy = +1 the
-- TOP of the frame, which is north.
--
-- The ray through a screen point is forward + right*sx*tanX + up*sy*tanY,
-- and with the orbit's basis (right = +x, forward = (0, -cos a, -sin a),
-- up = (0, sin a, -cos a)) that comes out as
--
--     d = ( sx*tanX,  -cos a + sy*tanY*sin a,  -sin a - sy*tanY*cos a )
--
-- Drop it to the ground plane from an eye at height k*cos a and the whole
-- trapezoid collapses to ONE denominator,
--
--     D(sy) = cos a - sy*tanY*sin a
--
-- with (the sin^2 + cos^2 cancels most of the algebra away):
--
--     north of centre : (vh/2) * sy / D(sy)
--     half-width      : (vw/2) * cos a / D(sy)
--
-- because k*tanY is exactly vh/2 and tanX*k is exactly vw/2, whatever FOCAL
-- is. At a = 0 both reduce to vh/2 and vw/2 -- the flat window, which is
-- the case the first cut of this file mistook for all of them.
--
-- D shrinks as sy climbs, so BOTH grow toward the top of the frame, and
-- both blow up where D reaches zero: sy* = cot(a)/tanY, the row the horizon
-- sits on. Past 63 degrees that row is inside the frame and the answer is
-- infinite -- which is what `reach` is for.
--
-- Returns three DISTANCES from the view centre, all positive: how far the
-- picture runs north, how far south, and how far to each side.
function ViewBox.footprint(a, vw, vh, reach)
  local Voxel = V.require("VoxelState")
  local halfW, halfH = (vw or 320) * 0.5, (vh or 288) * 0.5
  local tanY = 1 / (2 * (Voxel.FOCAL or 1))
  -- the orbit never reaches level (75 degrees is the last rung) but a tween
  -- reads a live angle, and a cos of zero is a horizon through the middle
  -- of the frame rather than a number
  local ca = math.max(math.cos(a or 0), 1e-3)
  local sa = math.max(math.sin(a or 0), 0)
  -- The screen row the far edge is taken at: the TOP of the frame, or the
  -- row whose ray lands `reach` out, whichever comes first. Inverting the
  -- north formula for sy gives
  --
  --     sy = reach*cos a / (vh/2 + reach*tanY*sin a)
  --
  -- which is always strictly below the horizon row (it approaches it from
  -- underneath as reach grows), so D below is always positive -- with the
  -- horizon in frame this never even reaches 1 and the clamp is inert.
  local sy = reach * ca / (halfH + reach * tanY * sa)
  if sy > 1 then sy = 1 end
  local D = ca - sy * tanY * sa
  if D < 1e-3 then D = 1e-3 end
  return halfH * sy / D,                 -- north
         halfH / (ca + tanY * sa),        -- south: the sy = -1 row
         halfW * ca / D                   -- and the widest row is the far one
end

-- Open the frame's cut: the bounding rectangle of the ground this camera
-- frames, times the row's multiplier. Returns the cut, or nil when this
-- frame has none -- which is the row at OFF, a rung the box is not about,
-- and a camera that has finished its dive into a head.
function ViewBox.frame(cx, cy, vw, vh, level)
  ViewBox.cull = nil
  local frac = ViewBox.frac()
  if not (frac and ViewBox.appliesTo(level)) then return nil end
  local left = orbitLeft()
  if left <= 0.001 then return nil end
  frac = frac / left
  local Voxel = V.require("VoxelState")
  local angle = Voxel.angle or 0
  local north, south, side = ViewBox.footprint(
    angle, vw, vh, ViewBox.MAX_REACH * (vh or 288))
  -- the ground the bottom edge lands on is not the southernmost thing under
  -- it: what STANDS there reaches into the frame from further south (see
  -- lift). Added before the row's multiplier, so FIT carries it too -- it is
  -- a correction to the honest answer, not margin around it.
  south = south + ViewBox.lift(angle) + ViewBox.SOUTH_PAD
  north, south, side = north * frac, south * frac, side * frac
  -- The rectangle around it. Off-centre in z, because the trapezoid is:
  -- the camera looks NORTH from south of its focus, so there is far more
  -- picture ahead of the view centre than behind it -- at 35 degrees
  -- roughly twice as much, at 75 the whole frame.
  --
  -- The same floor Diorama.radius keeps: a box smaller than a couple of
  -- tiles is not a viewport, it is a hole the player is standing in.
  local rx = math.max(24, side)
  local rz = math.max(24, (north + south) * 0.5)
  local bent = curved()
  local fade = bent and math.max(1, math.min(rx, rz) * ViewBox.FADE_FRAC) or 0
  ViewBox.cull = {
    x = cx, y = 0, z = cy - (north - south) * 0.5,
    -- `r` is what the ball and the pillar kinds are sized by and the box
    -- is not; carried so the cut table has one shape whoever made it
    r = math.max(rx, rz), rx = rx, rz = rz,
    -- a zero band is a hard edge: half a pixel of ramp, which is one pixel
    -- of antialiasing rather than a stair (Diorama says the same)
    invFade = 1 / math.max(fade, 0.5),
    kind = V.require("Diorama").BOX,
  }
  return ViewBox.cull
end

function ViewBox.stop()
  ViewBox.cull = nil
end

-- ------- the coarse half of the cut
--
-- Whether anything inside the world-pixel rectangle (x0, z0)-(x1, z1) can
-- be inside this frame's box. True whenever there is no box, so a caller
-- may guard every draw with it unconditionally.
function ViewBox.shows(x0, z0, x1, z1)
  local c = ViewBox.cull
  if not c then return true end
  local pad = ViewBox.PAD
  return x0 - pad <= c.x + c.rx and x1 + pad >= c.x - c.rx
     and z0 - pad <= c.z + c.rz and z1 + pad >= c.z - c.rz
end

-- The same question about a connected neighbour, in the shape VoxelScene
-- keeps them: { map, ox, oy } with the offset in world pixels and the map's
-- own size in blocks of 32 (the shape prefetch's masks are built from).
function ViewBox.showsMap(nb)
  if not (nb and nb.map and nb.map.def) then return true end
  return ViewBox.shows(nb.ox or 0, nb.oy or 0,
                       (nb.ox or 0) + (nb.map.def.width or 0) * 32,
                       (nb.oy or 0) + (nb.map.def.height or 0) * 32)
end

-- What the shadow pass has to notice: WHICH neighbours it drew is now a
-- function of the row, and the row is the one input to that the sun's own
-- signature does not already carry (the centre, the view size and the
-- rung are all in it). Widening the box brings a neighbour back into the
-- light's frustum, and a map recorded without it must be redrawn.
function ViewBox.signature()
  return ViewBox.frac() or 0
end

function ViewBox.row()
  return ViewBox.setting:row()
end

function ViewBox.sync(value)
  ViewBox.setting:sync(value)
end

return ViewBox
