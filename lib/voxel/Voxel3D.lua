-- Voxel world mode: the 3D pass -- shader, depth buffer and camera.
--
-- World space is world PIXELS, so every coordinate the 2D paths already
-- compute drops straight in with no unit conversion:
--
--   +X  map east   (world-pixel x)
--   +Y  up         (0 is the ground plane)
--   +Z  map south  (world-pixel y)
--
-- A character at rest faces +Z, i.e. toward a camera parked to the south,
-- which is what "facing down" means in the 2D game -- and a character card
-- is drawn in exactly that pose, leaning back rather than yawing.
--
-- The camera orbits the view centre at Voxel.angle: 0 is straight down
-- (what the flat 2D view already is) and 50 degrees leans toward the
-- horizon. Distance and field of view are tied to Voxel.FOCAL, which is the
-- same constant Tilt projects with, so a given angle frames the world
-- identically in both modes -- switching between them changes the geometry,
-- not the framing.
--
-- Every GPU object is pcall-guarded and `available()` reports the result:
-- headless test runs and any driver without depth-canvas support fall back
-- to the existing tilt/flat paths rather than erroring.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("util/Mat4")
local Voxel = V.require("voxel/VoxelState")
local ShadowMap = V.require("effects/ShadowMap")
local VoxelGrid = V.require("voxel/VoxelGrid")
local WorldCurve = V.require("effects/WorldCurve")
local Sky = V.require("effects/Sky")
local DayNight = V.require("effects/DayNight")
local GlassMask = V.require("util/GlassMask")
local PixelCanvas = V.require("util/PixelCanvas")

local Voxel3D = {}

-- Vertex format shared by terrain chunks and character models: a position,
-- the map-canvas / sprite-sheet pixel it samples, and a per-vertex darken
-- factor that gives a face its angle to the sun without a normal or a
-- light uniform. Cast shadows are a separate thing entirely -- see
-- ShadowMap, which the pixel shader below samples on top of this.
Voxel3D.FORMAT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
  { "VertexShade", "float", 1 },
}

-- Tall grass carries one extra value: a stable phase shared by every
-- vertex in a tuft. Keeping it constant prevents the two ends of a blade
-- from shearing apart while the gust travels across the map.
Voxel3D.GRASS_FORMAT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
  { "VertexShade", "float", 1 },
  { "VertexGrass", "float", 4 }, -- phase, clump centre x/z, effect kind
}

Voxel3D.GRASS_WIND_PIXELS = 1.15
Voxel3D.GRASS_WIND_SPEED = 2.35
Voxel3D.GRASS_INTERACT_RADIUS = 12
Voxel3D.GRASS_INTERACT_PIXELS = 2.5

-- Face shading by direction id. Top faces stay full brightness; sides step
-- down so an extruded block reads as solid instead of a flat sticker. Faces
-- turned away from the sun (currently in the southeast — see ShadowMap) are
-- darkest.
--
-- Baked face-angle shading is still useful even with the real shadow pass:
-- a surface turned away from the sun is dark because of its orientation,
-- which the shadow map does not capture. The two effects compound correctly
-- (an occluded, away-facing wall goes darker still).
Voxel3D.FACE_SHADE = {
  [1] = 0.84,   -- +X east (toward the sun)
  [2] = 0.72,   -- -X west (away)
  [3] = 1.00,   -- +Y up
  [4] = 0.55,   -- -Y down
  [5] = 0.90,   -- +Z south (toward the camera, and toward the sun)
  [6] = 0.68,   -- -Z north (away)
}

-- Scene shader source (moved out of this file for readability).
-- Loaded once; variants are built by prepending #defines.
local SHADER = V.mod:read("lib/voxel/shaders/voxel.glsl")
if not SHADER then
  error("DRAMATIC_SHAPE: lib/voxel/shaders/voxel.glsl is missing -- reinstall the mod", 0)
end

-- Compilations of SHADER, by what is compiled INTO it: the voxel
-- wireframe, and the diorama's viewport. Variants rather than branches,
-- for two different reasons.
--
-- The wireframe needs shader derivatives (fwidth), the one piece of this a
-- driver can refuse, so a refusal has to cost the grid and nothing else.
--
-- The viewport carries a world-position varying, and a varying is paid for
-- by every fragment of every frame whether or not anything reads it. The
-- cut only ever exists inside a headset's diorama, so every other frame --
-- the flat screen, and a phone above all -- compiles and binds exactly
-- what it always did.
--
-- Each entry is nil = untried, false = unavailable.
local shaders = {}

local function shaderKey(grid, cull)
  return (grid and "grid" or "plain") .. (cull and "+cull" or "")
end
local activeShader = nil      -- the variant this pass bound

-- Scene canvases, one per NAMED SLOT. There are exactly two callers and
-- they want different sizes -- the free-roam pass renders at the window's
-- pixel dimensions, the overworld battle at the GB's 160x144 -- and a
-- single cached canvas made every battle entry and exit reallocate one.
-- A slot reallocates only when its OWN size changes, which is a window
-- resize, so the pair is stable for a session.
local slots = {}
local canvas, canvasW, canvasH = nil, 0, 0   -- the slot this pass bound
local held = nil                             -- and the whole record for it
local active = false

-- A READABLE depth canvas, so a later pass in the same frame can ask the
-- buffer questions rather than only write to it -- which is the whole of
-- what makes screen-space reflections possible (see Water).
--
-- `depth = true` in the target list, which is what this used to bind,
-- allocates an internal depth buffer that is written and tested and can
-- never be sampled. An explicit canvas is the same buffer with a texture
-- handle on it, and costs the same memory.
--
-- nil where the driver will not make one -- every depth format is optional
-- in GLES and a canvas is the only honest test of any of them, so this asks
-- for several in order of preference: 24 bits, the same 24 riding a stencil
-- (a pairing some mobile drivers will texture when the bare format they
-- refuse), 32-bit float, and 16 as the floor every GLES3 device can read.
-- Refused all four, beginScene falls straight back to the internal buffer,
-- which is exactly the old behaviour minus the reflections.
local DEPTH_FORMATS = { "depth24", "depth24stencil8", "depth32f", "depth16" }

-- dpiscale = 1, for the same reason PixelCanvas pins it and for one more:
-- newCanvas otherwise takes the WINDOW's scale, and every canvas bound
-- together must agree on PIXEL dimensions. The colour canvas beside this one
-- comes from PixelCanvas at scale 1, so on any surface whose scale is not 1
-- -- Android's density is routinely 2.625, and a retina Mac's is 2 -- this
-- one came back 2.625x larger and the pair would not bind. beginScene then
-- dropped the readable depth for the session (see below), depthReadable()
-- went false, and the water pass never ran at all: the reflections were
-- missing on every high-density display, with nothing in the log to say so,
-- because a canvas that will not BIND is not a canvas the driver refused.
local function newDepth(w, h)
  if not (love.graphics and love.graphics.newCanvas) then return nil end
  local c = nil
  for _, format in ipairs(DEPTH_FORMATS) do
    local ok, made = pcall(love.graphics.newCanvas, w, h,
                           { format = format, readable = true, dpiscale = 1 })
    if ok and made then c = made break end
  end
  if not c then return nil end
  -- nearest: a depth is a distance, and a blend of two of them is a
  -- distance to nothing. The march wants the texel it landed on.
  pcall(c.setFilter, c, "nearest", "nearest")
  pcall(c.setWrap, c, "clamp", "clamp")
  -- and no compare mode: with one set, Texel returns a 0/1 shadow verdict
  -- instead of the depth, which is not what any reader here wants
  pcall(c.setDepthSampleMode, c)
  return c
end

-- The bound target for the slot this pass holds: the colour canvas plus
-- either the readable depth canvas or the internal buffer.
local function depthTarget()
  if held and held.depth then
    return { held.canvas, depthstencil = held.depth }
  end
  return { canvas, depth = true }
end

-- Every GPU object one slot owns. The mirror is the copy of the frame the
-- water pass reads (see beginWater); it is only ever made if something asks
-- for one, so a session that never sees a lake never pays for it.
local function releaseSlot(slotHeld)
  for _, key in ipairs({ "canvas", "depth", "mirror" }) do
    local obj = slotHeld[key]
    if obj and obj.release then pcall(obj.release, obj) end
    slotHeld[key] = nil
  end
end

local IDENTITY = Mat4.identity()

-- Whether the driver admits to supporting derivatives. Only a hint --
-- the compile below is the real test -- but it saves building a shader
-- that was never going to work, and it is how LOVE reports the ES2
-- extension the grid rides on.
local function derivativesOK()
  if not (love.graphics and love.graphics.getSupported) then return false end
  local ok, caps = pcall(love.graphics.getSupported)
  return ok and caps and caps.shaderderivatives == true
end

-- The scene shader. `grid` asks for the wireframe variant and `cull` for
-- the diorama's viewport; nil comes back when that combination will not
-- build -- callers then fall back to a plainer one rather than losing the
-- whole 3D pass.
function Voxel3D.shader(grid, cull)
  grid, cull = grid and true or false, cull and true or false
  local key = shaderKey(grid, cull)
  if shaders[key] == nil then
    if grid and not derivativesOK() then
      shaders[key] = false
    else
      local src = (grid and "#define VOXEL_GRID 1\n" or "")
                  .. (cull and "#define VOXEL_CULL 1\n" or "") .. SHADER
      local ok, sh = pcall(love.graphics.newShader, src)
      shaders[key] = ok and sh or false
    end
  end
  return shaders[key] or nil
end

-- Whether the 3D path can run at all. False on a headless test run (no
-- love.graphics), without shader support, or where a depth canvas cannot be
-- created -- every caller treats that as "stay on the 2D path".
function Voxel3D.available()
  if not (love.graphics and love.graphics.newCanvas
          and love.graphics.setDepthMode) then
    if V.log and not V._v3dAvailGfx then
      V._v3dAvailGfx = true
      V.log:event("voxel3d", "unavailable", { reason = "no-depth-canvas" })
    end
    return false
  end
  local ok = Voxel3D.shader() ~= nil
  if not ok and V.log and not V._v3dAvailShader then
    V._v3dAvailShader = true
    V.log:event("voxel3d", "unavailable", { reason = "shader-nil" })
  end
  return ok
end

-- Build a mesh in the shared format. `verts` is the LOVE vertex list and
-- `map` the triangle index list. Returns nil when meshes are unavailable,
-- which the callers treat the same way they treat a missing model.
function Voxel3D.newMesh(verts, map)
  if #verts == 0 then return nil end
  local ok, mesh = pcall(love.graphics.newMesh, Voxel3D.FORMAT, verts,
                         "triangles", "static")
  if not ok then return nil end
  if map and #map > 0 then pcall(mesh.setVertexMap, mesh, map) end
  return mesh
end

function Voxel3D.newGrassMesh(verts, map)
  if #verts == 0 then return nil end
  local ok, mesh = pcall(love.graphics.newMesh, Voxel3D.GRASS_FORMAT, verts,
                         "triangles", "static")
  if not ok then return nil end
  if map and #map > 0 then pcall(mesh.setVertexMap, mesh, map) end
  return mesh
end

-- The quad corner offsets and UV corners for one face direction, in the
-- order the vertex map below stitches into two triangles. Corners are unit
-- offsets from the voxel's (x, y, z) minimum corner.
Voxel3D.FACE_CORNERS = {
  [1] = { { 1, 0, 0 }, { 1, 0, 1 }, { 1, 1, 1 }, { 1, 1, 0 } },  -- +X
  [2] = { { 0, 0, 1 }, { 0, 0, 0 }, { 0, 1, 0 }, { 0, 1, 1 } },  -- -X
  [3] = { { 0, 1, 0 }, { 1, 1, 0 }, { 1, 1, 1 }, { 0, 1, 1 } },  -- +Y
  [4] = { { 0, 0, 1 }, { 1, 0, 1 }, { 1, 0, 0 }, { 0, 0, 0 } },  -- -Y
  [5] = { { 0, 0, 1 }, { 1, 0, 1 }, { 1, 1, 1 }, { 0, 1, 1 } },  -- +Z
  [6] = { { 1, 0, 0 }, { 0, 0, 0 }, { 0, 1, 0 }, { 1, 1, 0 } },  -- -Z
}

-- Append the six indices of quad `n` (0-based) to a triangle index list.
function Voxel3D.pushQuad(map, n)
  local b = n * 4
  map[#map + 1] = b + 1
  map[#map + 1] = b + 2
  map[#map + 1] = b + 3
  map[#map + 1] = b + 1
  map[#map + 1] = b + 3
  map[#map + 1] = b + 4
end

-- ---------------------------------------------------------------- camera --

-- An explicit camera, replacing the orbit below for as long as it is set:
-- { eye = {x,y,z}, focus = {x,y,z}, fov = radians, curve = k or nil,
--   up = {x,y,z} or nil }.
--
-- A caller with matrices of its own -- the VR eyes, whose view comes from
-- a tracked pose and whose projection is an off-centre frustum no
-- eye/focus/fov triple can express -- sets `view` and `proj` instead, and
-- the eye/focus fields stay for everything that reasons about the camera
-- rather than projecting with it (setLook, the sky, the water's lean).
--
-- The orbit is the free-roam camera and it is described entirely by ONE
-- number, the pitch, because that is all a camera following the player over
-- their own map ever needs. A staged shot -- the overworld battle's
-- over-the-shoulder rig (see BattleCam) -- is a placed camera: it has a yaw,
-- it does not sit above its focus, and its framing comes from the arena
-- rather than from the view size. Rather than widen the orbit into
-- something that could express both and be the wrong shape for each, a
-- caller with a camera of its own simply hands it over.
--
-- Everything downstream is unchanged by this: the shader uniforms, project()
-- and the overlay all read Voxel3D.vp / Voxel3D.eye, which are set the same
-- way either way.
Voxel3D.camera = nil

-- This frame's camera RAY FAN, set by viewProjection alongside vp: the
-- world direction a canvas point looks along (see Sky.paint's `ray`).
-- Present for every free-pitch camera -- the VR eyes bring theirs
-- (VRRig.eyeCamera), a placed eye/focus camera gets one built -- and nil
-- for the orbit, whose frame-hung sky is the classic look.
Voxel3D.skyRayLive = nil

-- ------- which way, and how steeply, this camera looks
--
-- Two facts about the view direction, set alongside the eye and the focus
-- because they ARE the eye and the focus, and read by anything that has to
-- reason about the camera's ATTITUDE rather than about a point in front of
-- it:
--
--   lookFlat   the view direction flattened onto the ground plane and
--              normalized -- "the way the horizon lies from here", which is
--              what a reflection leans toward at the steeper rungs (Water).
--   descent    how far below horizontal the view runs, as a sine: 0 looking
--              level, 1 looking straight down. It is the number that says
--              whether there is a horizon in frame at all, and it answers
--              the same way for the orbit and for a placed battle camera --
--              which is why this is derived from the two vectors rather than
--              read off Voxel.angle, a rung the battle camera does not have.
--
-- A camera looking exactly straight down has no horizontal direction at all,
-- and lookFlat then keeps whatever it last held rather than becoming a zero
-- vector nothing downstream could normalize.
Voxel3D.lookFlat = { 0, 0, -1 }
Voxel3D.descent = 0

local function setLook(eye, focus)
  local dx = focus[1] - eye[1]
  local dy = focus[2] - eye[2]
  local dz = focus[3] - eye[3]
  local len = math.sqrt(dx * dx + dy * dy + dz * dz)
  if len < 1e-6 then return end
  Voxel3D.descent = math.max(0, math.min(1, -dy / len))
  local flat = math.sqrt(dx * dx + dz * dz)
  if flat < 1e-6 then return end
  Voxel3D.lookFlat = { dx / flat, 0, dz / flat }
end

-- View and projection for a `vw` x `vh` world-pixel view centred on
-- (cx, cy) in world pixels. Returns the combined matrix.
function Voxel3D.viewProjection(cx, cy, vw, vh)
  local cam = Voxel3D.camera
  if cam then
    local eye, focus = cam.eye, cam.focus
    Voxel3D.eye = eye
    -- kept beside the eye for horizonY: where the sky's pale end goes is a
    -- question about which way this camera looks, and only these two answer it
    Voxel3D.focus = focus
    setLook(eye, focus)
    -- a camera that brought its own matrices (a VR eye) projects with
    -- them; only the clip-space Y flip is added, for the same canvas
    -- reason as every other branch here
    if cam.view and cam.proj then
      Voxel3D.fovY = cam.fov
      -- the VR eyes bring their fan with them (VRRig.eyeCamera)
      Voxel3D.skyRayLive = cam.skyRay
      return Mat4.mul(Mat4.mul(Mat4.scale(1, -1, 1), cam.proj), cam.view)
    end
    local dx = eye[1] - focus[1]
    local dy = eye[2] - focus[2]
    local dz = eye[3] - focus[3]
    local dist = math.max(1, math.sqrt(dx * dx + dy * dy + dz * dz))
    -- kept for the passes that measure an ANGLE against this camera rather
    -- than a position: the water's reflected sun is sized in radians, and
    -- radians per canvas pixel is exactly this over the frame height
    Voxel3D.fovY = cam.fov
    local proj = Mat4.perspective(cam.fov, vw / vh,
                                  math.max(1, dist * 0.05), dist * 4 + 4096)
    -- the same clip-space Y flip the orbit needs, for the same reason: we
    -- bypass LOVE's transform_projection and canvas coordinates run Y down
    proj = Mat4.mul(Mat4.scale(1, -1, 1), proj)
    -- The camera's RAY FAN, for the sky's skybox path (Sky.paint's `ray`):
    -- a placed camera with a FREE PITCH -- the first-person rig, steered
    -- by a mouse on the flat screen -- must not hang its gradient off the
    -- frame, or looking up and down drags the bands with the view. Built
    -- from the very basis the view below is: forward, the true right, the
    -- true up, and the symmetric frustum's tangents.
    local upv = cam.up or { 0, 1, 0 }
    local fx, fy, fz = -dx / dist, -dy / dist, -dz / dist
    local crx = fy * upv[3] - fz * upv[2]
    local cry = fz * upv[1] - fx * upv[3]
    local crz = fx * upv[2] - fy * upv[1]
    local crl = math.sqrt(crx * crx + cry * cry + crz * crz)
    if crl > 1e-6 then
      crx, cry, crz = crx / crl, cry / crl, crz / crl
      local cux = cry * fz - crz * fy
      local cuy = crz * fx - crx * fz
      local cuz = crx * fy - cry * fx
      local tanY = math.tan(cam.fov / 2)
      local tanX = tanY * (vw / vh)
      Voxel3D.skyRayLive = {
        base = { fx - crx * tanX + cux * tanY,
                 fy - cry * tanX + cuy * tanY,
                 fz - crz * tanX + cuz * tanY },
        du = { crx * 2 * tanX, cry * 2 * tanX, crz * 2 * tanX },
        dv = { cux * -2 * tanY, cuy * -2 * tanY, cuz * -2 * tanY },
      }
    else
      Voxel3D.skyRayLive = nil
    end
    -- world up by default, so the horizon stays level -- a placed camera
    -- that rolled with its own pitch would tip the whole arena. A caller
    -- may hand its own up: the first-person BLEND does, because its far
    -- end is the orbit, whose up leans with the pitch -- world up at the
    -- orbit's steep end degenerates against a straight-down view.
    return Mat4.mul(proj, Mat4.lookAt(eye, focus, cam.up or { 0, 1, 0 }))
  end

  -- the orbit: a fixed pitch per rung, and the classic frame-hung sky --
  -- no ray fan wanted
  Voxel3D.skyRayLive = nil

  local a = Voxel.angle
  local focal = Voxel.FOCAL
  local dist = focal * vh
  -- the FOV that makes a straight-down camera at `dist` frame exactly `vh`
  -- world pixels, which is the framing the flat view already has
  local fov = 2 * math.atan(1 / (2 * focal))
  Voxel3D.fovY = fov

  local focus = { cx, 0, cy }
  local eye = { cx, dist * math.cos(a), cy + dist * math.sin(a) }
  -- exposed for camera-facing billboards (VoxelScene yaws sprites at it)
  Voxel3D.eye = eye
  Voxel3D.focus = focus
  setLook(eye, focus)
  -- perpendicular to the view direction in the YZ plane: north is screen-up
  -- when looking straight down, +Y is screen-up when looking level. Never
  -- parallel to the view direction, so there is no degenerate a = 0 case.
  local up = { 0, math.sin(a), -math.cos(a) }

  local proj = Mat4.perspective(fov, vw / vh,
                                math.max(1, dist * 0.05), dist * 4 + 4096)
  -- Flip clip-space Y. Mat4.perspective emits textbook GL clip space with
  -- +Y up, but we bypass LOVE's own transform_projection, and LOVE's canvas
  -- coordinates run Y DOWN -- so without this the entire scene composites
  -- vertically mirrored: north at the bottom and buildings extruding
  -- downward. Winding flips with it, which is free here because the pass
  -- draws with culling off.
  proj = Mat4.mul(Mat4.scale(1, -1, 1), proj)
  return Mat4.mul(proj, Mat4.lookAt(eye, focus, up))
end

-- ------- the horizon
--
-- Where the ground plane's vanishing line lands, in canvas pixels down from the
-- top edge, or nil when this camera has no horizon to find.
--
-- Not a fraction picked by eye. A direction ALONG the ground is a point at
-- infinity, and putting one through the same matrix the geometry is drawn with
-- gives the line every ground plane in the scene converges on -- so the sky's
-- pale end meets the horizon at any pitch, fov, window shape or zoom, and rides
-- the camera tween instead of having to be retuned against it.
--
-- The world CURVE is not in it, and cannot be: it bends distant ground down in
-- the vertex shader, so the ground's apparent edge sits BELOW this line by
-- however much the bend took. What shows in between is the haze the sky's fill
-- already is, which is what a curved-away horizon should look like.
--
-- nil in two cases, both meaning "no horizon in this frame": a camera looking
-- straight down, whose forward direction has no horizontal part to send to
-- infinity, and one whose vanishing line is behind it.
function Voxel3D.horizonY(h)
  local m, eye, focus = Voxel3D.vp, Voxel3D.eye, Voxel3D.focus
  if not (m and eye and focus and h and h > 0) then return nil end
  local dx = focus[1] - eye[1]
  local dz = focus[3] - eye[3]
  local len = math.sqrt(dx * dx + dz * dz)
  if len < 1e-6 then return nil end
  dx, dz = dx / len, dz / len
  -- a DIRECTION, so its w is zero and the matrix's translation column drops
  -- out; the clip-space Y flip is already baked into m, so this comes out in
  -- canvas coordinates rather than needing one
  local y = m[5] * dx + m[7] * dz
  local w = m[13] * dx + m[15] * dz
  if w <= 1e-6 then return nil end
  return (y / w * 0.5 + 0.5) * h
end

-- The horizon as a LINE rather than a row, for a camera that can ROLL --
-- a VR eye. A head tipped sideways tips the true horizon across the
-- canvas, and a sky painted in flat rows then visibly hinges with the
-- head. So: project the flat forward direction (a point ON the vanishing
-- line) and the same direction nudged a hair of world-up (a point just
-- above it); the difference is the canvas direction "down toward the
-- ground", perpendicular to the horizon however the head is tipped.
--
-- Returns (ax, ay, edge, top): a unit axis in canvas pixels pointing from
-- sky toward ground, the horizon's signed distance along it -- a pixel at
-- canvas (x, y) is above the horizon while x*ax + y*ay < edge -- and,
-- when `elev` (radians) is given, the distance the direction that far
-- ABOVE the horizon projects to. `top` is what pins the gradient's far
-- end to a real direction in the sky: extrapolating it linearly from a
-- pixels-per-radian estimate left the bands sliding as a pitch moved the
-- horizon through the frame, because a perspective's rows are tan-spaced,
-- not angle-spaced. nil `top` (the elevated direction is outside this
-- frustum's forward hemisphere) leaves the caller its estimate. nil
-- everything with no horizon in front of this camera.
function Voxel3D.horizonLine(w, h, elev)
  local m, eye, focus = Voxel3D.vp, Voxel3D.eye, Voxel3D.focus
  if not (m and eye and focus and w and h and h > 0) then return nil end
  local dx = focus[1] - eye[1]
  local dz = focus[3] - eye[3]
  local len = math.sqrt(dx * dx + dz * dz)
  if len < 1e-6 then return nil end
  dx, dz = dx / len, dz / len
  local function proj(vx, vy, vz)
    local x = m[1] * vx + m[2] * vy + m[3] * vz
    local y = m[5] * vx + m[6] * vy + m[7] * vz
    local ww = m[13] * vx + m[14] * vy + m[15] * vz
    if ww <= 1e-6 then return nil end
    return (x / ww * 0.5 + 0.5) * w, (y / ww * 0.5 + 0.5) * h
  end
  local qx, qy = proj(dx, 0, dz)
  if not qx then return nil end
  local rx, ry = proj(dx, 0.02, dz)
  if not rx then return nil end
  local ax, ay = qx - rx, qy - ry
  local al = math.sqrt(ax * ax + ay * ay)
  if al < 1e-6 then ax, ay = 0, 1 else ax, ay = ax / al, ay / al end
  local top = nil
  if elev then
    local ce, se = math.cos(elev), math.sin(elev)
    local tx, ty = proj(dx * ce, se, dz * ce)
    if tx then top = tx * ax + ty * ay end
  end
  return ax, ay, qx * ax + qy * ay, top
end

-- ------- the hour's light
--
-- What the scene shader multiplies every surface by (see dayTint in the
-- shader). Set per pass by whoever knows what map is being drawn --
-- VoxelScene for free-roam, BattleScene for the arena -- because "is this
-- outdoors" is the map's question, not this pass's. Neutral until somebody
-- answers it, so a caller that never does draws exactly what it always drew.
Voxel3D.tint = { 1, 1, 1 }

-- The map's haze, set the same way (VoxelScene and BattleScene ask
-- ForestAtmos, who knows which maps have weather): a table of
-- { color = {r,g,b}, density, start, heightK }, or nil for a clear day.
-- nil -- the default -- sends density 0, so a caller that never heard of
-- fog draws exactly what it always drew, and no pass can inherit the
-- last one's weather.
Voxel3D.fog = nil

-- THE DIORAMA'S VIEWPORT, set the same way (VoxelScene asks lib/Diorama,
-- who is told by lib/VR what the headset is doing): a table of
-- { x, y, z, r, invFade, kind }, kind 1 for the ball and 2 for the staged
-- fight's pillar. nil -- the default, and what every flat frame leaves it
-- at -- sends kind 0, which is the shader's "draw the whole world".
--
-- A plain field rather than a require of lib/Diorama, and deliberately:
-- this file is the bottom of the stack and everything else in the mode is
-- built on it, so it learns about the diorama the same way it learns about
-- the weather and the hour -- by being handed the answer.
Voxel3D.cull = nil

-- What the background is cleared to INSTEAD of the sky, or nil for the
-- sky: DIORAMA-MR's chroma key, set for the eye passes alone.
Voxel3D.keyColor = nil

-- The window-glass pass, set the same way and for the same reason: the
-- MASK belongs to the map's tileset (GlassMask.texture) and how lit the
-- panes are belongs to the hour and to being outdoors at all
-- (DayNight.windowLight). nil / 0 -- the defaults -- draw no glass effect.
Voxel3D.glassMask = nil
Voxel3D.glassNight = 0

-- the glint, fed by the camera's TRAVEL rather than by a clock (see
-- VoxelScene.glintStep): the phase is radians already wrapped to 2pi, and
-- the strength is 0 whenever the view has been still for a beat
Voxel3D.glassPhase = 0
Voxel3D.glassGlint = 0

-- The sun or moon disc's place on this camera's canvas, or nil when the
-- body is set, on the southern half of the sky, or behind the camera.
--
-- The direction comes from DayNight (true bearing, squashed elevation) and
-- goes through the SAME matrix the geometry is drawn with, as a point at
-- infinity -- exactly how horizonY finds the vanishing line. So the disc's
-- azimuth is honest: it stands over the point on the horizon its shadows
-- point away from, at every pitch, fov, window shape and zoom.
--
-- Must run after beginScene has set Voxel3D.vp for this frame's camera.
function Voxel3D.skyBody(w, h)
  local m = Voxel3D.vp
  local b = m and DayNight.body()
  if not b then return nil end
  local x = m[1] * b.dx + m[2] * b.dy + m[3] * b.dz
  local y = m[5] * b.dx + m[6] * b.dy + m[7] * b.dz
  local ww = m[13] * b.dx + m[14] * b.dy + m[15] * b.dz
  if ww <= 1e-6 then return nil end
  local amt, color = DayNight.glow()
  return {
    x = (x / ww * 0.5 + 0.5) * w,
    y = (y / ww * 0.5 + 0.5) * h,
    -- the body's WORLD direction, for the skybox path: a ray-fan caller
    -- measures the twilight glow by the angle between a pixel's ray and
    -- this, so the glow is pinned to the sky like the bands are (see
    -- Sky.paint's glowDir)
    dx = b.dx, dy = b.dy, dz = b.dz,
    moon = b.moon,
    glowAmt = amt,
    glowColor = color,
  }
end

-- ------- the VR sky's world-anchored pieces
--
-- Both exist because a headset showed the shortcuts: a gradient painted
-- off the frame moved with the head that carried the frame, and a
-- screen-space disc re-snapped its cell grid with every head movement
-- and held its face square to the canvas instead of to the world. The
-- gradient's fix rides the camera record itself (skyRay -- see VRRig and
-- Sky's useRay path); the disc's is below.

-- The sun or moon as a QUAD IN THE WORLD: the baked cell art
-- (Sky.discImage) on a square spanned about the hour's direction, its
-- corners projected through this very eye -- so the disc is pinned to
-- the sky like the terrain is to the ground, stable under every head
-- motion, its face upright over the world. Runs inside beginScene's sky
-- window, before the depth mode is set, so the world draws over it.
local discMesh = nil

local function drawWorldDisc(w, h)
  local b = DayNight.body()
  if not (b and b.dy and b.dy > 0.005) then return end
  local amt = DayNight.glow()
  local img = Sky.discImage(b.moon, Sky.discLooming(amt, b.moon))
  if not img then return end
  local m = Voxel3D.vp
  if not m then return end
  local hl = math.sqrt(b.dx * b.dx + b.dz * b.dz)
  if hl < 1e-6 then return end
  -- right = horizontal, perpendicular to the direction; up completes it
  local rx, rz = b.dz / hl, -b.dx / hl
  local ux = -rz * b.dy
  local uy = rz * b.dx - rx * b.dz
  local uz = rx * b.dy
  local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
  if ul < 1e-6 then return end
  ux, uy, uz = ux / ul, uy / ul, uz / ul
  if uy < 0 then ux, uy, uz = -ux, -uy, -uz end
  -- apparent size is an ANGLE, the same fraction of the view the flat
  -- screen's disc takes of its frame; the low sun looms exactly as there
  local ang = Sky.DISC_FRAC * (Voxel3D.fovY or 1)
  if Sky.discLooming(amt, b.moon) then ang = ang * 1.4 end
  local k = math.tan(ang)
  local verts = {}
  local corners = { { -1, -1, 0, 1 }, { 1, -1, 1, 1 },
                    { 1, 1, 1, 0 }, { -1, 1, 0, 0 } }
  for i, c in ipairs(corners) do
    local vx = b.dx + (rx * c[1] + ux * c[2]) * k
    local vy = b.dy + (uy * c[2]) * k
    local vz = b.dz + (rz * c[1] + uz * c[2]) * k
    local x = m[1] * vx + m[2] * vy + m[3] * vz
    local y = m[5] * vx + m[6] * vy + m[7] * vz
    local ww = m[13] * vx + m[14] * vy + m[15] * vz
    if ww <= 1e-6 then return end
    verts[i] = { (x / ww * 0.5 + 0.5) * w, (y / ww * 0.5 + 0.5) * h,
                 c[3], c[4] }
  end
  pcall(function()
    if not discMesh then
      discMesh = love.graphics.newMesh(4, "fan", "stream")
    end
    discMesh:setVertices(verts)
    discMesh:setTexture(img)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(discMesh)
  end)
end

-- ----------------------------------------------------------------- scene --

-- Begin the 3D pass into a `w` x `h` pixel canvas centred on world
-- (cx, cy), covering `vw` x `vh` world pixels. Returns false when the pass
-- could not start, in which case the caller must not call endScene.
-- `sky` is an optional {r, g, b, a} in 0..1 to clear the void to, for the
-- pitch where the horizon is in frame (VoxelScene.skyFor). nil leaves the
-- void transparent, which is what every rung below it wants.
-- `slot` names which cached canvas to render into (see `slots` above);
-- omitted is the free-roam world pass.
function Voxel3D.beginScene(w, h, cx, cy, vw, vh, sky, slot)
  -- the wireframe variant when the player has it on AND it built, and the
  -- viewport variant while a diorama frame is open; either answer falls
  -- through to a plainer scene rather than to no scene. The cut is dropped
  -- LAST, because losing it draws a whole uncut world where a model should
  -- be, which is worse than losing the seams.
  local grid = VoxelGrid.enabled()
  local cut = Voxel3D.cull ~= nil
  local sh = grid and Voxel3D.shader(true, cut) or nil
  if not sh then
    grid = false
    sh = Voxel3D.shader(false, cut)
  end
  if not sh and cut then
    cut, sh = false, Voxel3D.shader(false, false)
  end
  if not sh then return false end
  local name = slot or "world"
  local slotHeld = slots[name]
  if not (slotHeld and slotHeld.w == w and slotHeld.h == h) then
    local ok, c = PixelCanvas.new(w, h)
    if not ok then return false end
    c:setFilter("nearest", "nearest")
    if slotHeld then releaseSlot(slotHeld) end
    -- the depth canvas is sized with its colour, so a window resize
    -- reallocates the pair together and they can never disagree
    slotHeld = { canvas = c, w = w, h = h, depth = newDepth(w, h) }
    slots[name] = slotHeld
  end
  held = slotHeld
  canvas, canvasW, canvasH = held.canvas, w, h
  -- a depth buffer is what makes occlusion real: walk behind a building and
  -- the building wins, with no y-sorting anywhere
  local ok = pcall(love.graphics.setCanvas, depthTarget())
  if not ok and held.depth then
    -- the readable canvas would not bind; fall back to the internal buffer
    -- for the rest of this session rather than losing the whole 3D pass
    pcall(held.depth.release, held.depth)
    held.depth = nil
    ok = pcall(love.graphics.setCanvas, depthTarget())
  end
  if not ok then
    pcall(love.graphics.setCanvas)
    return false
  end
  -- Ahead of the clear, because the sky's bands are placed off the ground
  -- plane's vanishing line and that is a property of this matrix.
  Voxel3D.vp = Voxel3D.viewProjection(cx, cy, vw, vh)
  -- This frame's pixels per WORLD pixel: the size a diorama pixel is on
  -- screen. The sky's dither grid is cut to it, and so is the water's --
  -- one number, so the two break up on the same checkerboard.
  Voxel3D.cell = w / math.max(1, vw or w)
  -- A FREE-PITCH camera's sky is ANCHORED IN SPACE, where the orbit's is
  -- glued to the frame. One discriminator: skyRayLive, set by
  -- viewProjection above for every camera whose pitch the player steers
  -- -- the VR eyes and the flat first-person rig alike. With a fan, the
  -- gradient is a SKYBOX (every pixel takes its band, and its GBC
  -- checker, from its ray's true elevation -- no motion of the camera
  -- moves a band, only the clock recolours them) and the sun or moon
  -- hangs in the WORLD (drawWorldDisc). Without one -- the orbit, whose
  -- pitch is the rung's -- the classic frame-hung painting stands.
  local skyRay = Voxel3D.skyRayLive
  local hy = Voxel3D.horizonY(h)
  -- DIORAMA-MR: the background is a CHROMA KEY, so there is no sky at all
  -- -- not a green one painted over, but no bands, no disc and no haze,
  -- because every one of those is a colour a keyer would have to survive.
  -- The world itself is untouched; only what is behind it changes.
  local key = Voxel3D.keyColor
  if key then sky = nil end
  -- where the sky's bottom edge lands, which is what the reflection
  -- reads its bands against (see Water). nil when nothing painted bands.
  Voxel3D.skyEdge = (sky and sky.bands) and Sky.region(h, hy) or nil
  if key then
    love.graphics.clear(key[1], key[2], key[3], 1, true, true)
  elseif sky then
    love.graphics.clear(sky[1], sky[2], sky[3], sky[4] or 1, true, true)
    -- The sky goes down here, in the one window in this function where a
    -- rectangle is just a rectangle: the depth mode and the scene shader are
    -- both set below. Sky.paint puts them aside anyway -- beginScene is not the
    -- only thing that has ever left a shader bound.
    --
    -- w / vw is this frame's pixels per WORLD pixel, which is the size a diorama
    -- pixel is on screen: the sky's dither grid is cut to that, so its squares
    -- are the same size as the world's own and follow every resize and zoom.
    -- The banded sky also hangs the hour's sun or moon (skyBody projects it
    -- through this very camera); a flat sky has no bands and hangs nothing.
    if skyRay and sky.bands then
      Sky.paint(w, h, sky, nil, Voxel3D.cell, Voxel3D.skyBody(w, h),
                nil, nil, skyRay)
      drawWorldDisc(w, h)
    else
      Sky.paint(w, h, sky, hy, Voxel3D.cell,
                sky.bands and Voxel3D.skyBody(w, h) or nil)
    end
  else
    love.graphics.clear(0, 0, 0, 0, true, true)
  end
  love.graphics.setDepthMode("lequal", true)
  -- models mirror on X for right-facing and alternate walk steps, which
  -- flips winding; hidden faces are already culled at build time, so there
  -- is nothing to gain from backface culling and a real bug to avoid
  love.graphics.setMeshCullMode("none")
  love.graphics.setShader(sh)
  love.graphics.setColor(1, 1, 1, 1)
  pcall(sh.send, sh, "vp", "row", Voxel3D.vp)
  pcall(sh.send, sh, "eye", Voxel3D.eye)
  -- the sun's frame, filled by ShadowMap just before this pass opened.
  -- Sent unconditionally: the sampler is declared either way, and leaving
  -- one unbound is a driver-dependent crash rather than a fallback.
  local map = ShadowMap.active()
  pcall(sh.send, sh, "sunVP", "row", map and ShadowMap.uvVP or IDENTITY)
  local tex = ShadowMap.texture()
  if tex then pcall(sh.send, sh, "sunMap", tex) end
  pcall(sh.send, sh, "sunDark", map and Voxel3D.SHADOW_ALPHA or 0)
  pcall(sh.send, sh, "sunBias", ShadowMap.bias)
  local texel = 1 / ShadowMap.res
  pcall(sh.send, sh, "sunTexel", { texel, texel })
  if grid then
    pcall(sh.send, sh, "gridDark", VoxelGrid.DARK)
    pcall(sh.send, sh, "gridWidth", VoxelGrid.width())
  end
  -- ordinary shading until the silhouette pass asks for otherwise. Sent
  -- every frame rather than once, because a scene that opened mid-ghost --
  -- a driver hiccup between beginGhost and endGhost -- would otherwise
  -- start out flattening everything it drew.
  pcall(sh.send, sh, "ghost", 0)
  pcall(sh.send, sh, "ghostColor", Voxel3D.GHOST_COLOR)
  -- the hour's light, as the caller last set it (see Voxel3D.tint)
  pcall(sh.send, sh, "dayTint", Voxel3D.tint or { 1, 1, 1 })
  pcall(sh.send, sh, "fireflyNight", Voxel3D.fireflyNight or 0)
  -- and the map's haze (see Voxel3D.fog), density 0 when there is none
  local fog = Voxel3D.fog
  pcall(sh.send, sh, "fogColor", (fog and fog.color) or { 0, 0, 0 })
  pcall(sh.send, sh, "fogInfo", fog and
        { fog.density or 0, fog.start or 0, fog.heightK or 0, 0 }
        or { 0, 0, 0, 0 })
  -- and the viewport (see Voxel3D.cull), kind 0 when there is none --
  -- which is every frame that neither a headset's diorama (lib/Diorama)
  -- nor an orbit rung's window box (lib/ViewBox) has cut
  local cull = Voxel3D.cull
  pcall(sh.send, sh, "cullAt",
        cull and { cull.x, cull.y, cull.z } or { 0, 0, 0 })
  pcall(sh.send, sh, "cullShape",
        cull and { cull.r, cull.invFade, cull.kind } or { 0, 0, 0 })
  pcall(sh.send, sh, "cullRect",
        cull and { cull.rx or cull.r, cull.rz or cull.r } or { 0, 0 })
  -- the window glass: the tileset's mask (or the blank -- the sampler is
  -- declared either way, and unbound is a driver-dependent crash), how lit
  -- the panes are, and the movement-fed glint as the caller last set it
  local mask = Voxel3D.glassMask or GlassMask.blank()
  if mask then
    pcall(sh.send, sh, "glassMask", mask)
    local ok, mw, mh = pcall(mask.getDimensions, mask)
    pcall(sh.send, sh, "glassSize", { ok and mw or 1, ok and mh or 1 })
  end
  pcall(sh.send, sh, "glassNight", Voxel3D.glassNight or 0)
  pcall(sh.send, sh, "glassPhase", Voxel3D.glassPhase or 0)
  pcall(sh.send, sh, "glassGlint", Voxel3D.glassGlint or 0)
  -- on until a sprite pass says otherwise, reset per frame like `ghost`
  pcall(sh.send, sh, "glassOn", 1)
  -- still until the dedicated grass pass enables it
  pcall(sh.send, sh, "grassWind", { 0, 0, 0, 0 })
  pcall(sh.send, sh, "grassPlayer", { -100000, -100000, 1, 0 })
  pcall(sh.send, sh, "grassPrevious", { -100000, -100000 })
  -- the curved world bends about the camera's focus, so the horizon keeps
  -- a fixed distance ahead of the player rather than sitting on the map.
  -- A placed camera may decline it outright (Voxel3D.camera.curve = 0).
  local placed = Voxel3D.camera
  Voxel3D.curveK = (placed and placed.curve) or WorldCurve.k(vh)
  Voxel3D.curveX, Voxel3D.curveZ = cx, cy
  pcall(sh.send, sh, "curve", { cx, cy, Voxel3D.curveK })
  -- clip w at the focus point, the reference depth project() reports scale
  -- against (so scale == 1 for anything standing at the view centre)
  local m = Voxel3D.vp
  Voxel3D.focusW = m[13] * cx + m[14] * 0 + m[15] * cy + m[16]
  activeShader = sh
  active = true
  return true
end

-- Depth handling for the character pass. Gen 1 draws sprites over the
-- background unconditionally, so characters render with the depth test
-- forced to pass (still writing depth: the grass mesh drawn after them
-- tests against it to overdraw feet). "test" restores normal occlusion.
function Voxel3D.depth(mode)
  if not active then return end
  pcall(love.graphics.setDepthMode, mode == "always" and "always" or "lequal",
        true)
end

-- ------------------------------------------------ the player's own ghost --

-- The silhouette's colour, and how solid it is.
--
-- ONE flat grey rather than a dimmed copy of the sprite, so the shape reads
-- at a glance instead of competing with whatever is showing through it --
-- and translucent rather than opaque, so it stays a hint of where the
-- player is rather than a hole punched in the building. The wall it is
-- seen through still shows, which is what keeps it reading as "behind
-- that" instead of "in front of it".
Voxel3D.GHOST_COLOR = { 0.26, 0.26, 0.28 }
Voxel3D.GHOST_ALPHA = 0.5

-- Draw a character AGAIN wherever the ordinary draw LOST the depth test.
--
-- Honest occlusion is the point of this mode -- walk behind the Mart and the
-- Mart is genuinely in front of you -- but a player who cannot see their own
-- character has lost track of where they are standing, which the flat game
-- never allowed. So the figure is drawn a second time with the test
-- INVERTED: "greater" passes exactly where "lequal" failed, and LOVE hands
-- the compare straight to glDepthFunc, so the two are true complements.
-- Every texel of the sprite is therefore drawn once and once only -- solid
-- where it is visible, translucent where it is not -- with no seam where
-- they meet and no double-blending anywhere.
--
-- Nothing is drawn at all when nothing is in the way, and no code here ever
-- asks whether the player is occluded: the depth buffer already knows, and
-- the test is the question.
--
-- Depth WRITES are off. This pass is behind the scenery by definition, and
-- writing would file the hidden figure's depth in front of the building
-- hiding it -- the grass pass at the end of the frame reads that buffer.
--
-- The caller redraws through the ordinary character path, so the ghost keeps
-- the same mesh, matrix and camera-ward PULL as the real draw. The pull
-- matching is what keeps the leaning-over-a-near-wall case out of here: pull
-- already won that fight for the solid draw, so this pass finds nothing left
-- to paint and a character merely standing close to a wall does not shimmer
-- a ghost over it.
function Voxel3D.beginGhost()
  if not active then return end
  pcall(love.graphics.setDepthMode, "greater", false)
  love.graphics.setColor(1, 1, 1, Voxel3D.GHOST_ALPHA)
  if activeShader then
    pcall(activeShader.send, activeShader, "ghostColor", Voxel3D.GHOST_COLOR)
    pcall(activeShader.send, activeShader, "ghost", 1)
  end
end

-- Flatten whatever is drawn next to one solid colour, or nil to stop.
--
-- The same `ghost` path the silhouette uses, WITHOUT beginGhost's inverted
-- depth test and half alpha -- this is for something drawn normally that
-- simply wants to come out one colour, which is what a hit flash on a sprite
-- is. beginScene resets the uniform every frame, so a pass that forgets to
-- clear it cannot leak into the next one.
-- `amount` is how far toward that colour, 0..1; omitted is all the way.
-- Anything short of 1 leaves the sprite's own shading showing through, which
-- is the difference between a hit flash and a white cut-out.
function Voxel3D.flatten(color, amount)
  if not (active and activeShader) then return end
  local sh = activeShader
  if color then
    pcall(sh.send, sh, "ghostColor", color)
    pcall(sh.send, sh, "ghost", math.max(0, math.min(1, amount or 1)))
  else
    pcall(sh.send, sh, "ghost", 0)
  end
end

-- ------------------------------------------------------- the water pass --
--
-- A reflective surface has to READ the frame it is being drawn into: the
-- colour of what is standing around it and the depth that says where. Both
-- are attachments of the target this pass is bound to, and a texture cannot
-- be sampled while it is one -- so for the length of the water draw the
-- frame is taken apart:
--
--   the COLOUR is copied to a mirror canvas, which is a texture like any
--   other and is what the reflection samples.
--
--   the DEPTH is simply detached. The water shader does the test itself
--   against the texture (see Water), which is the same comparison the
--   hardware would have made -- what it gives up is depth WRITES, and water
--   is flat, never overlaps itself, and has nothing drawn under it later.
--
-- `paint`, when given, is called with the MIRROR bound and the scene shader
-- set, to add things that must be REFLECTED without being composited yet.
--
-- The characters are the whole reason it exists. Gen 1 draws people over
-- the world and water is world, so the cast has to composite AFTER the
-- water -- but a reflection can only contain what was drawn BEFORE it, and
-- a lake with everyone standing beside it and nobody in it reads as glass.
-- Painting them into the mirror alone settles both: they are in the picture
-- the water reflects and not yet in the picture the water is drawn into.
--
-- They go down depth-TESTED and depth-WRITE-FREE. Tested, so a figure behind
-- a building is behind it in the reflection too; write-free because the very
-- next thing to read that buffer is the water's own depth test, and a cast
-- that had written to it would punch itself out of the water it is standing
-- beside.
--
-- Returns the two textures, or nil when there is nothing to hand over: no
-- readable depth canvas on this driver, or no pass open. A caller that gets
-- nil draws its water like ordinary terrain, which is what this mode always
-- did.
--
-- MUST be paired with endWater, which puts the frame back together.
function Voxel3D.beginWater(paint)
  if not (active and canvas and held and held.depth) then return nil end
  if not held.mirror then
    -- through PixelCanvas, because this one is bound WITH held.depth a few
    -- lines down and the two must agree on pixel dimensions -- the same
    -- scale trap newDepth documents
    local ok, c = PixelCanvas.new(held.w, held.h)
    if not (ok and c) then return nil end
    pcall(c.setFilter, c, "nearest", "nearest")
    pcall(c.setWrap, c, "clamp", "clamp")
    held.mirror = c
  end
  love.graphics.setShader()
  -- the frame's own depth rides along, so the paint below can test against
  -- it; the copy underneath switches the test off rather than detaching it
  local ok = pcall(love.graphics.setCanvas,
                   { held.mirror, depthstencil = held.depth })
  if not ok then
    pcall(love.graphics.setCanvas, depthTarget())
    return nil
  end
  love.graphics.setDepthMode("always", false)
  -- COLOUR only. The last two arguments are what keep the depth buffer the
  -- frame's rather than this canvas's: cleared here, the water's own depth
  -- test a few lines later would find nothing in front of anything and every
  -- lake would draw straight through the buildings standing in it.
  love.graphics.clear(0, 0, 0, 0, false, false)
  -- premultiplied over a cleared target is a straight copy: every channel
  -- lands exactly as it stood, including the alpha, so the mirror is the
  -- frame rather than the frame composited against something
  love.graphics.setBlendMode("alpha", "premultiplied")
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(canvas)
  love.graphics.setBlendMode("alpha")
  if paint and activeShader then
    love.graphics.setDepthMode("lequal", false)
    love.graphics.setShader(activeShader)
    pcall(paint)
    love.graphics.setShader()
  end
  love.graphics.setDepthMode()
  -- and back to the scene canvas WITHOUT its depth: that texture is about
  -- to be read
  if not pcall(love.graphics.setCanvas, canvas) then
    pcall(love.graphics.setCanvas, depthTarget())
    return nil
  end
  return held.mirror, held.depth
end

-- Put the frame back: depth reattached, depth test and the scene shader as
-- the pass had them. Safe to call after a beginWater that returned nil.
function Voxel3D.endWater()
  if not active then return end
  pcall(love.graphics.setCanvas, depthTarget())
  pcall(love.graphics.setDepthMode, "lequal", true)
  love.graphics.setColor(1, 1, 1, 1)
  if activeShader then love.graphics.setShader(activeShader) end
end

-- A custom shader for the length of a draw, inside the pass. What makes
-- this a pair rather than a bare setShader at the call site is the way
-- BACK: the scene shader this pass bound is module-local (activeShader,
-- above), so only this file can restore it -- the same restore endWater
-- performs, without the canvas shuffle. Answers false when there is no
-- pass to come back to, and the caller skips its draw entirely.
function Voxel3D.beginEffect(shader)
  if not (active and shader) then return false end
  love.graphics.setShader(shader)
  love.graphics.setColor(1, 1, 1, 1)
  return true
end

function Voxel3D.endEffect()
  if not active then return end
  love.graphics.setColor(1, 1, 1, 1)
  if activeShader then love.graphics.setShader(activeShader) end
end

-- Whether a reflective water pass can run in this frame at all -- there is
-- a depth texture to read. Callers use it to choose between the water
-- shader and an ordinary terrain draw before they start moving canvases.
function Voxel3D.depthReadable()
  return (active and held and held.depth) and true or false
end

-- Whether what is drawn next carries the voxel wireframe. false for the
-- length of a draw, true to put it back.
--
-- The wireframe reads a mesh's OWN model space and darkens its integer
-- planes (see VoxelGrid), which is only a wireframe because every mesh in
-- this mode is built ONE UNIT PER VOXEL: terrain in world pixels, a
-- character card in the sprite's own pixels. A mesh whose model space does
-- not mean that gets no wireframe out of the same shader -- it gets
-- whichever of its integer planes happen to fall inside it, which is a
-- stray line rather than a seam.
--
-- So this is not a style switch. It is how a mesh that is not on the voxel
-- grid says so, and the alternative -- rescaling such a mesh until its
-- units happen to be voxels -- would change what it IS to satisfy a
-- shading pass.
--
-- Sent rather than branched because the plain scene shader has no such
-- uniform, and the send simply does not take there -- which is right: with
-- no wireframe compiled in there is nothing to suppress.
function Voxel3D.seams(on)
  if not (active and activeShader) then return end
  pcall(activeShader.send, activeShader, "gridDark",
        on and VoxelGrid.DARK or 0)
end

-- ADDITIVE for the length of a draw, or nil to put the pass back the way
-- it was found.
--
-- Exactly one thing asks for this: the flame and gas primitives on a
-- STADIUM battle model (Charmander's tail, Weezing's cloud -- see
-- StadiumRig). Those are light, not surface: they are drawn over a body
-- that is already in the depth buffer and they must ADD to it rather than
-- replace it, or the flame comes out as an opaque orange sticker.
--
-- Depth WRITES go off with the blend, and for the usual reason -- a
-- translucent thing that wrote depth would punch whatever comes after it
-- out of the frame. The test stays on, so a flame behind a tree is still
-- behind the tree.
function Voxel3D.blend(mode)
  if not active then return end
  if mode == "add" then
    pcall(love.graphics.setBlendMode, "add", "alphamultiply")
    pcall(love.graphics.setDepthMode, "lequal", false)
  else
    pcall(love.graphics.setBlendMode, "alpha", "alphamultiply")
    pcall(love.graphics.setDepthMode, "lequal", true)
  end
end

-- Whether what is drawn next may consult the glass mask. false for the
-- length of a sprite-sheet pass, true to put it back.
--
-- Same shape as seams(), for the same reason: the mask means "this ATLAS
-- texel is window glass", so it is only an answer for meshes textured from
-- the tileset atlas. A sprite sheet's coordinates land wherever they land
-- on it, and at night that painted lamplight stripes down whoever was
-- standing in the wrong part of their own sheet.
function Voxel3D.glass(on)
  if not (active and activeShader) then return end
  pcall(activeShader.send, activeShader, "glassOn", on and 1 or 0)
end

-- Enable wind only around tall-grass draws. px/pz are the current player's
-- feet in world pixels; previous values make collision continuous per frame.
function Voxel3D.grassWind(on, px, pz, previousX, previousZ)
  if not (active and activeShader) then return end
  if not on then
    pcall(activeShader.send, activeShader, "grassWind", { 0, 0, 0, 0 })
    return
  end
  local now = love.timer and love.timer.getTime and love.timer.getTime() or 0
  pcall(activeShader.send, activeShader, "grassWind",
        { 1, now, Voxel3D.GRASS_WIND_PIXELS, Voxel3D.GRASS_WIND_SPEED })
  pcall(activeShader.send, activeShader, "grassPlayer",
        { px or -100000, pz or -100000,
          Voxel3D.GRASS_INTERACT_RADIUS, Voxel3D.GRASS_INTERACT_PIXELS })
  pcall(activeShader.send, activeShader, "grassPrevious",
        { previousX or px or -100000, previousZ or pz or -100000 })
end

function Voxel3D.endGhost()
  if not active then return end
  pcall(love.graphics.setDepthMode, "lequal", true)
  love.graphics.setColor(1, 1, 1, 1)
  -- back to ordinary shading before anything else draws; leaving it set
  -- would flatten the grass pass that follows into one grey sheet
  if activeShader then
    pcall(activeShader.send, activeShader, "ghost", 0)
  end
end

-- -------------------------------------------------------------- shadows --

-- The sun. One direction, shared by everything that needs to know where
-- the light comes from: the shadow map, the flat fallback below, and the
-- baked contact shading in ChunkMesher. Both shears are negative, which
-- hangs it in the SOUTHEAST and throws every shadow northwest -- up and to
-- the left on screen.
Voxel3D.SHADOW_KX = ShadowMap.KX   -- west drift per pixel of height
Voxel3D.SHADOW_KZ = ShadowMap.KZ   -- north drift per pixel of height
Voxel3D.SHADOW_EPS = 0.25     -- float above the ground to dodge z-fighting
Voxel3D.SHADOW_ALPHA = 0.40   -- how far into black a shadowed surface goes

-- Whether real shadows are running this frame. False headless and on any
-- driver the sun pass could not start on, which is when VoxelScene falls
-- back to the flat decals below.
function Voxel3D.shadowsActive()
  return ShadowMap.active()
end

-- The upright card a character presents to the sun: its 16x16 sprite quad
-- (corners (0,0,0)..(16,16,0), feet at y = 0) standing on the middle of
-- the cell whose top-left is world (px, py), feet at height `y`.
--
-- This is the caster the shadow pass draws -- deliberately NOT the leaning
-- slab the camera sees. The slab tips back by the camera's pitch to read
-- face-on, which is a trick played on the viewer; letting the sun see it
-- too would shrink every shadow to nothing as the camera flattened toward
-- top-down. The sun sees the figure standing up, at every tilt.
--
-- The z-flatten matters when this is used the other way round, as the
-- lookup transform a lit slab reads its own shadowing with (Voxel3D.draw's
-- `sunModel`): it collapses the slab's side relief onto the card plane, so
-- every vertex asks about the exact surface the sun recorded rather than
-- one a few pixels behind it, and a figure cannot fringe itself. On the
-- caster itself it is a no-op -- that quad is already flat.
function Voxel3D.casterMatrix(px, py, y, mirror)
  local m = Mat4.translate(px + 8, y, py + 8)
  if mirror then m = Mat4.mul(m, Mat4.scale(-1, 1, 1)) end
  return Mat4.mul(Mat4.mul(m, Mat4.translate(-8, 0, 0)),
                  Mat4.scale(1, 1, 0))
end

-- FALLBACK ONLY (no shadow map: headless, or a driver that cannot make the
-- canvas). Character drop shadows as decals -- the sprite frame squashed
-- flat onto its ground plane and drawn translucent black. It can only ever
-- paint the floor, which is the whole reason ShadowMap exists.
--
-- Flattening is measured from the ground plane, so a hop slides the whole
-- shadow along the sun line while it stays glued to the ground -- the
-- classic jump-shadow tell.
function Voxel3D.shadowMatrix(px, py, gh, lift, mirror)
  local card = Voxel3D.casterMatrix(px, py, gh + (lift or 0), mirror)
  -- flatten about the ground plane: y' = 0, x/z shear by height above it
  local squash = { 1, Voxel3D.SHADOW_KX, 0, 0,
                   0, 0,                 0, 0,
                   0, Voxel3D.SHADOW_KZ, 1, 0,
                   0, 0,                 0, 1 }
  local m = Mat4.mul(squash, Mat4.mul(Mat4.translate(0, -gh, 0), card))
  return Mat4.mul(Mat4.translate(0, gh + Voxel3D.SHADOW_EPS, 0), m)
end

-- The decal pass draws between terrain and characters: depth-tested so a
-- building still hides a shadow behind it, but NOT depth-writing -- the
-- grass tufts drawn at the end of the frame must keep beating the ground
-- plane, and one quad per entity has no self-overlap to guard against.
function Voxel3D.beginShadows()
  if not active then return end
  pcall(love.graphics.setDepthMode, "lequal", false)
  love.graphics.setColor(0, 0, 0, Voxel3D.SHADOW_ALPHA)
end

function Voxel3D.endShadows()
  if not active then return end
  pcall(love.graphics.setDepthMode, "lequal", true)
  love.graphics.setColor(1, 1, 1, 1)
end

-- Draw one mesh with `model` (a Mat4) applied. Texture may be nil to keep
-- whatever the mesh already carries. `pull` moves every vertex toward the
-- eye along its own ray (see the shader) -- the artifact-free depth bias
-- the character and grass passes ride in front of the terrain.
--
-- `sunModel` is where the SHADOW PASS put this same geometry, and defaults
-- to `model` because for everything but a character the two are one matrix.
-- A character is drawn leaning and cast upright, so it must hand over the
-- upright transform or it reads its own shadow as falling on itself.
function Voxel3D.draw(mesh, texture, model, pull, sunModel)
  if not (active and mesh) then return end
  -- the variant beginScene actually bound, not whichever one is default:
  -- sending a uniform to the other shader would go nowhere
  local sh = activeShader
  if not sh then return end
  if texture then mesh:setTexture(texture) end
  -- LOVE defaults matrix uniforms to column-major; Mat4 is row-major
  pcall(sh.send, sh, "model", "row", model or IDENTITY)
  pcall(sh.send, sh, "sunModel", "row", sunModel or model or IDENTITY)
  pcall(sh.send, sh, "pull", pull or 0)
  love.graphics.draw(mesh)
end

-- Project a world point to canvas pixels: returns (x, y, scale), or nil
-- when the point is behind the camera. `scale` is how much bigger a thing
-- at that depth appears than one at the focus point, so a caller can size
-- with it -- or ignore it and draw unscaled, which is what tilt mode's
-- billboards do.
--
-- This is what lets the overworld's FX closures (the "!" bubble, the heal
-- machine, the Fly bird, the fishing rod) draw in voxel mode completely
-- unchanged: they stay ordinary 2D draws, anchored to wherever their ground
-- point lands under the same camera the 3D pass used.
function Voxel3D.project(wx, wy, wz)
  local m = Voxel3D.vp
  if not m then return nil end
  -- the same drop the vertex shader applies, or every FX anchored to a
  -- ground point floats off its own feet the moment that ground bends
  wy = wy - WorldCurve.drop(Voxel3D.curveK or 0, Voxel3D.curveX or 0,
                            Voxel3D.curveZ or 0, wx, wz)
  local cx = m[1] * wx + m[2] * wy + m[3] * wz + m[4]
  local cy = m[5] * wx + m[6] * wy + m[7] * wz + m[8]
  local cw = m[13] * wx + m[14] * wy + m[15] * wz + m[16]
  if cw <= 1e-6 then return nil end
  -- viewProjection already flipped clip-space Y into LOVE's Y-down canvas
  -- convention, so both axes map the same way here -- no second flip
  local x = (cx / cw * 0.5 + 0.5) * canvasW
  local y = (cy / cw * 0.5 + 0.5) * canvasH
  return x, y, (Voxel3D.focusW or cw) / cw
end

-- Re-bind the scene canvas for ordinary 2D drawing (no depth test), so
-- screen-space overlays can be composited into the same image the 3D pass
-- just filled. Pairs with endScene, which unbinds it.
function Voxel3D.beginOverlay()
  if not canvas then return false end
  love.graphics.setShader()
  love.graphics.setDepthMode()
  local ok = pcall(love.graphics.setCanvas, canvas)
  if not ok then return false end
  love.graphics.setColor(1, 1, 1, 1)
  return true
end

-- Close the overlay begun by beginOverlay.
function Voxel3D.endOverlay()
  love.graphics.setCanvas()
  active, activeShader = false, nil
end

-- End the pass and hand back the rendered canvas.
function Voxel3D.endScene()
  if not active then return nil end
  love.graphics.setShader()
  love.graphics.setDepthMode()
  love.graphics.setMeshCullMode("none")
  love.graphics.setCanvas()
  active, activeShader = false, nil
  return canvas
end

function Voxel3D.canvas()
  return canvas
end

-- The bound canvas's pixel size, for a pass that has to work in screen
-- coordinates (the water's reflection marches in them).
function Voxel3D.size()
  return canvasW, canvasH
end

-- Drop the GPU objects (window resize, hot reload).
function Voxel3D.invalidate()
  for name, slotHeld in pairs(slots) do
    releaseSlot(slotHeld)
    slots[name] = nil
  end
  canvas, canvasW, canvasH = nil, 0, 0
  held = nil
  -- the VR sky's disc mesh belongs to this context like the canvases do
  if discMesh and discMesh.release then pcall(discMesh.release, discMesh) end
  discMesh = nil
  ShadowMap.invalidate()
  -- the sky is part of this pass and holds a shader of its own
  Sky.invalidate()
  -- and so does the water, for the same reason
  V.require("effects/Water").invalidate()
  -- and the glass masks are textures of this context too
  GlassMask.invalidate()
end

return Voxel3D
