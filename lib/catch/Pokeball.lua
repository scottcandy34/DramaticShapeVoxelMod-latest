-- A Poke Ball as real geometry: the prop the LET'S GO capture mode throws.
--
-- The mod has never drawn a ball in 3D -- the one the engine tosses is a 2D
-- sprite inside the battle's move-animation layer. This is a ball that can
-- fly through the arena, hang in the air in front of the camera, hinge its
-- lid open, drink a Pokemon in, click shut, rock on the ground and burst
-- back open -- all of it depth-tested, sun-shadowed and hour-tinted like
-- everything else in the diorama, because it is a mesh in Voxel3D's own
-- format going through Voxel3D's own shader.
--
-- ------- how it is built
--
-- Two lat/long hemisphere shells that meet at the equator -- the WHITE base
-- and the coloured LID -- each carrying its half of the black band as a
-- slightly bulged latitude belt, so the two halves separate exactly where
-- the real ball separates. The button is a little cylinder standing out of
-- the base's front; the interior is sealed with two pale discs so an open
-- ball shows a shell with a floor rather than a view through to the far
-- wall's backface. Colour is a palette texture one texel per material and
-- one ROW per ball tier (POKE/GREAT/ULTRA/MASTER/SAFARI), exactly the
-- HordeGun/Pokedex scheme -- so GREAT is blue and ULTRA wears its yellow
-- band without a second mesh, just a different V coordinate.
--
-- Shade is baked per vertex from the surface normal with StadiumStage's
-- fitted constants, which is this mod's answer for anything curved: the
-- ball's sun side and belly read as a sphere under the same southeastern
-- sun the roofs are lit by.
--
-- ------- how it animates
--
-- The HordeGun way: a handful of scalar timers advanced by update(dt) and
-- consumed as matrix terms at draw time. No skeleton, no keyframes --
-- lid is a hinge matrix about the back of the equator, the wobble is a
-- decaying rotateZ about the ground contact point, the caught click is a
-- squash pulse, the stars are one shared quad drawn a few times facing the
-- eye. The ball owns its POSE only; where it IS (the throw arc, the drop)
-- is the caller's problem, which is what keeps this file a prop and not a
-- game mode.
--
-- Nothing here touches love.* until something has to be drawn, so the
-- module loads and the state machine runs headless -- the test suite
-- exercises the phases without a GPU.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("Mat4")
local Voxel3D = V.require("Voxel3D")

local Pokeball = {}
Pokeball.__index = Pokeball

-- ------- the ball's measurements, in world pixels
--
-- A map cell is 16 and a full-size mon card is 16 wide, so a 4.4-pixel ball
-- sits in the hand and against a Pokemon at about the proportion the games
-- draw: unmissable in the foreground, believable at the far cell.
Pokeball.R = 2.2

-- the black belt: half-height as a latitude angle, and how far the belt
-- bulges past the shell so it reads as a band and not a painted stripe
local BAND_LAT = 0.16
local BAND_R = 1.045

-- lid hinge: at the BACK of the equator (-Z), opening backward. 2.0 rad is
-- past upright -- the mouth gapes at the sky, which is the capture pose.
local HINGE_Z = -0.86           -- as a fraction of R
local LID_OPEN = 2.0

-- tessellation: enough that the silhouette is round at held-ball size,
-- cheap enough that six of these would not show on a phone's frame budget
local LON = 14
local LAT = 5

-- pose timing
local LID_RATE = 6.5            -- lid open/close, in lid-fractions per second
local BURST_RATE = 14           -- the breakout pop is a violent open
local WOBBLE_T = 0.85           -- one rock, seconds
local WOBBLE_A = 0.38           -- how far it tips, radians
local PULSE_T = 0.14            -- the caught click's squash pulse
local STAR_T = 0.9              -- the caught stars' life
local GLOW_DECAY = 2.2          -- additive glow, per second

-- ------- palette
--
-- One texel per material (columns), one row per ball tier. Alpha stays 1
-- everywhere: the voxel shader discards below 0.5 (Voxel3D's SHADER), so a
-- translucent texel is an invisible one.
local SLOTS = { TOP = 1, BOTTOM = 2, BAND = 3, RING = 4, FACE = 5,
                INNER = 6, GLOW = 7, STAR = 8 }
local SLOT_N = 8

local TIERS = { "POKE_BALL", "GREAT_BALL", "ULTRA_BALL", "MASTER_BALL",
                "SAFARI_BALL" }

local COLORS = {
  POKE_BALL   = { top = { 0.86, 0.16, 0.16 }, band = { 0.12, 0.12, 0.13 },
                  bottom = { 0.93, 0.93, 0.95 } },
  GREAT_BALL  = { top = { 0.25, 0.45, 0.88 }, band = { 0.12, 0.12, 0.13 },
                  bottom = { 0.93, 0.93, 0.95 } },
  ULTRA_BALL  = { top = { 0.22, 0.22, 0.26 }, band = { 0.85, 0.70, 0.18 },
                  bottom = { 0.93, 0.93, 0.95 } },
  MASTER_BALL = { top = { 0.48, 0.22, 0.66 }, band = { 0.16, 0.13, 0.19 },
                  bottom = { 0.93, 0.93, 0.95 },
                  glow = { 1.0, 0.72, 0.92 } },
  SAFARI_BALL = { top = { 0.47, 0.52, 0.26 }, band = { 0.36, 0.27, 0.16 },
                  bottom = { 0.90, 0.88, 0.80 } },
}

local SHARED = {
  ring  = { 0.28, 0.28, 0.30 },
  face  = { 0.96, 0.96, 0.97 },
  inner = { 0.72, 0.70, 0.68 },
  glow  = { 1.00, 0.92, 0.65 },
  star  = { 1.00, 0.85, 0.25 },
}

local function tierRow(ball)
  for i, id in ipairs(TIERS) do
    if id == ball then return i end
  end
  return 1                       -- an unknown ball is a plain POKE BALL
end

-- palette texel centres
local function uvFor(slot, row)
  return (slot - 0.5) / SLOT_N, (row - 0.5) / #TIERS
end

local palette = nil
local function paletteTexture()
  if palette ~= nil then return palette or nil end
  local ok, img = pcall(function()
    local data = love.image.newImageData(SLOT_N, #TIERS)
    for row, id in ipairs(TIERS) do
      local c = COLORS[id]
      local function put(slot, rgb)
        data:setPixel(slot - 1, row - 1, rgb[1], rgb[2], rgb[3], 1)
      end
      put(SLOTS.TOP, c.top)
      put(SLOTS.BOTTOM, c.bottom)
      put(SLOTS.BAND, c.band)
      put(SLOTS.RING, SHARED.ring)
      put(SLOTS.FACE, SHARED.face)
      put(SLOTS.INNER, SHARED.inner)
      put(SLOTS.GLOW, c.glow or SHARED.glow)
      put(SLOTS.STAR, SHARED.star)
    end
    local tex = love.graphics.newImage(data)
    tex:setFilter("nearest", "nearest")
    return tex
  end)
  palette = ok and img or false
  return palette or nil
end

-- ------- shade
--
-- StadiumStage's fitted form of Voxel3D.FACE_SHADE: the same southeastern
-- sun, answered for an arbitrary normal instead of one of six faces.
local function shadeFor(nx, ny, nz)
  local s = 0.7725 + nx * 0.06 + ny * 0.225 + nz * 0.11
  return math.max(0.30, math.min(1.00, s))
end

-- ------- mesh building
--
-- Everything below appends {x,y,z, u,v, shade} rows plus triangle indices.
-- Quads go through the shared corner order; the discs use a degenerate
-- fourth vertex, which the rasteriser drops as the zero-area triangle it is.
local function quad(verts, map, a, b, c, d)
  local n = #verts
  verts[n + 1], verts[n + 2], verts[n + 3], verts[n + 4] = a, b, c, d
  Voxel3D.pushQuad(map, n / 4)
end

local R = Pokeball.R
local TAU = math.pi * 2

-- a latitude zone of the sphere between phi0 and phi1 (radians from the
-- equator, north positive), at radiusK times the shell radius
local function zone(verts, map, phi0, phi1, rows, slot, row, radiusK)
  local u, v = uvFor(slot, row)
  local r = R * (radiusK or 1)
  for i = 0, rows - 1 do
    local pa = phi0 + (phi1 - phi0) * (i / rows)
    local pb = phi0 + (phi1 - phi0) * ((i + 1) / rows)
    for j = 0, LON - 1 do
      local ta = TAU * (j / LON)
      local tb = TAU * ((j + 1) / LON)
      local function corner(phi, th)
        local nx = math.cos(phi) * math.sin(th)
        local ny = math.sin(phi)
        local nz = math.cos(phi) * math.cos(th)
        return { nx * r, ny * r, nz * r, u, v, shadeFor(nx, ny, nz) }
      end
      quad(verts, map, corner(pa, ta), corner(pa, tb),
                       corner(pb, tb), corner(pb, ta))
    end
  end
end

-- a disc in a y-plane, sealed with fan quads about the centre
local function disc(verts, map, y, radius, slot, row, up)
  local u, v = uvFor(slot, row)
  local sh = shadeFor(0, up and 1 or -1, 0)
  local centre = { 0, y, 0, u, v, sh }
  for j = 0, LON - 1 do
    local ta = TAU * (j / LON)
    local tb = TAU * ((j + 1) / LON)
    local a = { radius * math.sin(ta), y, radius * math.cos(ta), u, v, sh }
    local b = { radius * math.sin(tb), y, radius * math.cos(tb), u, v, sh }
    quad(verts, map, centre, a, b, centre)
  end
end

-- the button: a ring wall and its face, standing out of the shell along +Z
local function button(verts, map, row)
  local BLON = 10
  local function ringWall(rad, z0, z1, slot)
    local u, v = uvFor(slot, row)
    for j = 0, BLON - 1 do
      local ta = TAU * (j / BLON)
      local tb = TAU * ((j + 1) / BLON)
      local function at(th, z)
        local nx, ny = math.cos(th), math.sin(th)
        return { rad * nx, rad * ny, z, u, v, shadeFor(nx, ny, 0) }
      end
      quad(verts, map, at(ta, z0), at(tb, z0), at(tb, z1), at(ta, z1))
    end
  end
  local function faceDisc(rad, z, slot)
    local u, v = uvFor(slot, row)
    local sh = shadeFor(0, 0, 1)
    local centre = { 0, 0, z, u, v, sh }
    for j = 0, BLON - 1 do
      local ta = TAU * (j / BLON)
      local tb = TAU * ((j + 1) / BLON)
      local a = { rad * math.cos(ta), rad * math.sin(ta), z, u, v, sh }
      local b = { rad * math.cos(tb), rad * math.sin(tb), z, u, v, sh }
      quad(verts, map, centre, a, b, centre)
    end
  end
  -- the wall starts inside the shell so the junction never shows a gap
  ringWall(0.75, R * 0.90, R + 0.30, SLOTS.RING)
  faceDisc(0.75, R + 0.30, SLOTS.RING)
  ringWall(0.45, R + 0.30, R + 0.42, SLOTS.RING)
  faceDisc(0.45, R + 0.42, SLOTS.FACE)
end

-- one tier's meshes, memoised: { base = , lid = , spark = }
--
-- spark is a shared unit card (x -0.5..0.5, y 0..1, z 0) wearing one texel;
-- the glow disc, the beam and every star are that card under a matrix.
local meshes = {}
local function meshesFor(ball)
  local row = tierRow(ball)
  local hit = meshes[row]
  if hit ~= nil then return hit or nil end

  local ok, built = pcall(function()
    local bv, bm = {}, {}
    -- the base: white bowl from the south pole up to the band, its half of
    -- the band, the interior floor and the button on the front
    zone(bv, bm, -math.pi / 2, -BAND_LAT, LAT, SLOTS.BOTTOM, row)
    zone(bv, bm, -BAND_LAT, 0, 1, SLOTS.BAND, row, BAND_R)
    disc(bv, bm, -0.06, R * 0.97, SLOTS.INNER, row, true)
    button(bv, bm, row)

    local lv, lm = {}, {}
    -- the lid: its half of the band up to the coloured dome, and its pale
    -- underside, which is what shows once the hinge tips it back
    zone(lv, lm, 0, BAND_LAT, 1, SLOTS.BAND, row, BAND_R)
    zone(lv, lm, BAND_LAT, math.pi / 2, LAT, SLOTS.TOP, row)
    disc(lv, lm, 0.06, R * 0.97, SLOTS.INNER, row, false)

    local base = Voxel3D.newMesh(bv, bm)
    local lid = Voxel3D.newMesh(lv, lm)
    if not (base and lid) then return nil end

    local function card(slot)
      local u, v = uvFor(slot, row)
      local cv, cm = {}, {}
      quad(cv, cm, { -0.5, 0, 0, u, v, 1 }, { 0.5, 0, 0, u, v, 1 },
                   { 0.5, 1, 0, u, v, 1 }, { -0.5, 1, 0, u, v, 1 })
      return Voxel3D.newMesh(cv, cm)
    end
    return { base = base, lid = lid,
             glow = card(SLOTS.GLOW), star = card(SLOTS.STAR) }
  end)
  meshes[row] = (ok and built) or false
  return meshes[row] or nil
end

-- dropped so a lost GL context (Android resume) rebuilds everything
function Pokeball.invalidate()
  meshes = {}
  palette = nil
end

-- ------- an instance: one ball with a pose
--
-- Loads and runs without graphics; only draw() and cast() want a GPU.
function Pokeball.new(ball)
  return setmetatable({
    ball = ball or "POKE_BALL",
    pos = { 0, 0, 0 },          -- world pixels, the ball's CENTRE
    yaw = 0,                    -- which way the button faces
    scale = 1,
    spin = 0,                   -- visual spin about the vertical, rad/s
    tumble = 0,                 -- end-over-end in flight, rad/s
    roll = 0,                   -- SCREEN-PLANE spin, rad/s: rotation about
                                -- the axis out of the ball's face, which
                                -- with the yaw at the camera reads as the
                                -- ball turning clockwise/counter-clockwise
                                -- to the viewer -- the curveball wind-up
    spinAngle = 0, tumbleAngle = 0, rollAngle = 0,
    lid = 0, lidTarget = 0, lidRate = LID_RATE,
    wobbleT = nil, wobbleDir = 1,
    pulse = nil,                -- the caught click's squash
    glow = 0,
    stars = nil,                -- caught celebration, or nil
    visible = true,
  }, Pokeball)
end

-- ------- the verbs the capture flow speaks

function Pokeball:open()
  self.lidTarget, self.lidRate = 1, LID_RATE
  self.glow = 1
end

function Pokeball:close()
  self.lidTarget, self.lidRate = 0, LID_RATE
end

-- one rock on the ground; dir alternates shakes. Returns how long it takes,
-- so the caller can sequence the pauses between shakes.
function Pokeball:rock(dir)
  self.wobbleT = 0
  self.wobbleDir = dir or 1
  return WOBBLE_T
end

-- the caught click: squash pulse, a soft flash, and the stars
function Pokeball:catchClick()
  self.pulse = 0
  self.glow = 0.6
  local stars = {}
  for i = 1, 6 do
    stars[i] = { t = -0.04 * (i - 1), th = TAU * (i - 1) / 6 + 0.4 }
  end
  self.stars = stars
end

-- the breakout: the lid blown open and a hard flash
function Pokeball:burst()
  self.lidTarget, self.lidRate = 1, BURST_RATE
  self.glow = 1
end

function Pokeball:busy()
  return self.wobbleT ~= nil or self.pulse ~= nil
      or math.abs(self.lid - self.lidTarget) > 0.02
end

function Pokeball:update(dt)
  -- lid toward its target, at whatever violence was asked for
  local d = self.lidTarget - self.lid
  if d ~= 0 then
    local step = self.lidRate * dt
    if math.abs(d) <= step then
      -- arriving CLOSED from open is the shut click: the squash pulse
      if self.lid > self.lidTarget then self.pulse = self.pulse or 0 end
      self.lid = self.lidTarget
    else
      self.lid = self.lid + (d > 0 and step or -step)
    end
  end
  if self.wobbleT then
    self.wobbleT = self.wobbleT + dt
    if self.wobbleT >= WOBBLE_T then self.wobbleT = nil end
  end
  if self.pulse then
    self.pulse = self.pulse + dt
    if self.pulse >= PULSE_T then self.pulse = nil end
  end
  if self.stars then
    local live = false
    for _, s in ipairs(self.stars) do
      s.t = s.t + dt
      if s.t < STAR_T then live = true end
    end
    if not live then self.stars = nil end
  end
  self.glow = math.max(0, self.glow - GLOW_DECAY * dt)
  self.spinAngle = self.spinAngle + self.spin * dt
  self.tumbleAngle = self.tumbleAngle + self.tumble * dt
  self.rollAngle = self.rollAngle + self.roll * dt
end

-- ------- pose as a matrix

local function smooth(t)
  if t <= 0 then return 0 end
  if t >= 1 then return 1 end
  return t * t * (3 - 2 * t)
end

function Pokeball:matrix()
  local m = Mat4.mul(Mat4.translate(self.pos[1], self.pos[2], self.pos[3]),
                     Mat4.rotateY(self.yaw))
  if self.wobbleT then
    -- a decaying rock about the ground contact: tip, cross through centre,
    -- tip the other way, settle
    local t = self.wobbleT / WOBBLE_T
    local a = WOBBLE_A * math.sin(TAU * t) * (1 - t) * self.wobbleDir
    m = Mat4.mul(m, Mat4.mul(Mat4.translate(0, -R * self.scale, 0),
                 Mat4.mul(Mat4.rotateZ(a),
                          Mat4.translate(0, R * self.scale, 0))))
  end
  if self.spinAngle ~= 0 then m = Mat4.mul(m, Mat4.rotateY(self.spinAngle)) end
  if self.tumbleAngle ~= 0 then
    m = Mat4.mul(m, Mat4.rotateX(self.tumbleAngle))
  end
  -- the roll turns about the ball's own face axis, so with the yaw aimed
  -- at the camera it reads as clockwise/counter-clockwise on screen
  if self.rollAngle ~= 0 then
    m = Mat4.mul(m, Mat4.rotateZ(self.rollAngle))
  end
  local k = self.scale
  if self.pulse then
    -- the click: a quick squash and back, more felt than seen
    local p = math.sin((self.pulse / PULSE_T) * math.pi) * 0.14
    m = Mat4.mul(m, Mat4.scale(k * (1 + p), k * (1 - p), k * (1 + p)))
  elseif k ~= 1 then
    m = Mat4.mul(m, Mat4.scale(k, k, k))
  end
  return m
end

-- the hinge: the lid's own extra transform about the back of the equator
local function lidMatrix(open)
  if open <= 0 then return nil end
  local a = -LID_OPEN * smooth(open)
  local hz = HINGE_Z * R
  return Mat4.mul(Mat4.translate(0, 0, hz),
         Mat4.mul(Mat4.rotateX(a), Mat4.translate(0, 0, -hz)))
end

-- where the open mouth is, for aiming the capture beam
function Pokeball:mouth()
  return self.pos[1], self.pos[2] + R * 0.4 * self.scale, self.pos[3]
end

-- ------- drawing
--
-- Assumes a live Voxel3D scene (between beginScene and endScene), exactly
-- like Stadium.draw. Seams and glass are off for the duration: the ball is
-- not on the voxel grid and does not wear the tileset atlas.
local function eyeYaw(x, z)
  local eye = Voxel3D.eye
  if not eye then return 0 end
  return math.atan2(eye[1] - x, eye[3] - z)
end

function Pokeball:draw(pull)
  if not self.visible then return end
  local m = meshesFor(self.ball)
  local pal = paletteTexture()
  if not (m and pal) then return end
  Voxel3D.seams(false)
  Voxel3D.glass(false)
  local model = self:matrix()
  Voxel3D.draw(m.base, pal, model, pull)
  local lidM = lidMatrix(self.lid)
  Voxel3D.draw(m.lid, pal, lidM and Mat4.mul(model, lidM) or model, pull)

  -- the additive dressing: the open-mouth glow and the caught stars.
  -- Depth writes are off under "add" (Voxel3D.blend), so these can never
  -- punch holes for later draws.
  local anythingAdd = (self.glow > 0.05 and self.lid > 0.1) or self.stars
  if anythingAdd then
    Voxel3D.blend("add")
    if self.glow > 0.05 and self.lid > 0.1 then
      -- a pulsing octahedron of light standing in the mouth: two crossed
      -- cards read from every seat in the house
      local gx, gy, gz = self:mouth()
      local s = R * (1.1 + 0.25 * self.glow) * self.scale
      for i = 0, 1 do
        local card = Mat4.mul(Mat4.translate(gx, gy, gz),
                     Mat4.mul(Mat4.rotateY(eyeYaw(gx, gz) + i * math.pi / 2),
                              Mat4.scale(s, s, 1)))
        Voxel3D.draw(m.glow, pal, card, pull)
      end
    end
    if self.stars then
      for _, s in ipairs(self.stars) do
        if s.t > 0 and s.t < STAR_T then
          local t = s.t / STAR_T
          local rr = (R + 4.5 * t) * self.scale
          local sx = self.pos[1] + math.sin(s.th) * rr
          local sz = self.pos[3] + math.cos(s.th) * rr
          local sy = self.pos[2] + (R + 7 * t - 5 * t * t) * self.scale
          local sc = 1.1 * (1 - t)
          local card = Mat4.mul(Mat4.translate(sx, sy, sz),
                       Mat4.mul(Mat4.rotateY(eyeYaw(sx, sz)),
                       Mat4.mul(Mat4.rotateZ(TAU * t * 0.5),
                                Mat4.scale(sc, sc, 1))))
          Voxel3D.draw(m.star, pal, card, pull)
        end
      end
    end
    Voxel3D.blend(nil)
  end
  Voxel3D.glass(true)
  Voxel3D.seams(true)
end

-- the capture beam: a crossed pair of additive cards stretched from the
-- ball's mouth to the mon it is drinking in. Separate from draw() because
-- the caller owns the far end and the fade.
function Pokeball:drawBeam(tx, ty, tz, width, strength, pull)
  if not self.visible then return end
  local m = meshesFor(self.ball)
  local pal = paletteTexture()
  if not (m and pal) then return end
  local x, y, z = self:mouth()
  local dx, dy, dz = tx - x, ty - y, tz - z
  local len = math.sqrt(dx * dx + dy * dy + dz * dz)
  if len < 0.5 then return end
  dx, dy, dz = dx / len, dy / len, dz / len
  -- two perpendiculars to the beam axis
  local ux, uy, uz
  if math.abs(dy) < 0.94 then
    ux, uy, uz = -dz, 0, dx                 -- cross(d, worldUp), unnormalised
    local l = math.sqrt(ux * ux + uz * uz)
    ux, uz = ux / l, uz / l
  else
    ux, uy, uz = 1, 0, 0
  end
  local vx = dy * uz - dz * uy
  local vy = dz * ux - dx * uz
  local vz = dx * uy - dy * ux
  local w = (width or R) * (strength or 1)
  Voxel3D.seams(false)
  Voxel3D.glass(false)
  Voxel3D.blend("add")
  -- the unit card is x -0.5..0.5, y 0..1: columns map its x to a
  -- perpendicular and its y to the full run of the axis
  local a = { ux * w, dx * len, vx, x,
              uy * w, dy * len, vy, y,
              uz * w, dz * len, vz, z,
              0, 0, 0, 1 }
  local b = { vx * w, dx * len, ux, x,
              vy * w, dy * len, uy, y,
              vz * w, dz * len, uz, z,
              0, 0, 0, 1 }
  Voxel3D.draw(m.glow, pal, a, pull)
  Voxel3D.draw(m.glow, pal, b, pull)
  Voxel3D.blend(nil)
  Voxel3D.glass(true)
  Voxel3D.seams(true)
end

-- ------- the sun's view
--
-- The same two shells under the same matrix, so the shadow on the ground is
-- the pose the camera sees. The caller folds a term into the shadow
-- signature while a ball is live (the sun pass is cached -- see
-- BattleScene.shadowSignature) or this freezes on its first frame.
function Pokeball:cast(shadowMap)
  if not self.visible then return end
  local m = meshesFor(self.ball)
  local pal = paletteTexture()
  if not (m and pal) then return end
  local model = self:matrix()
  shadowMap.draw(m.base, pal, model)
  local lidM = lidMatrix(self.lid)
  shadowMap.draw(m.lid, pal, lidM and Mat4.mul(model, lidM) or model)
end

-- a term for the arena's cached shadow signature: quantised, so the cache
-- only re-renders when the ball has visibly moved
function Pokeball:signature()
  if not self.visible then return "" end
  return table.concat({ math.floor(self.pos[1] * 4), math.floor(self.pos[2] * 4),
                        math.floor(self.pos[3] * 4), math.floor(self.lid * 8),
                        self.wobbleT and math.floor(self.wobbleT * 30) or -1 },
                      ",")
end

return Pokeball
