-- Voxel world mode: water, and what it reflects.
--
-- Every other surface in this mode is opaque and is drawn once, inside the
-- terrain mesh, by the scene shader. Water is neither: it is a MIRROR, and
-- a mirror cannot be drawn until the thing it reflects already exists. So
-- the water surface is lifted out of the terrain mesh at build time
-- (ChunkMesher's water sink) and drawn as its own pass, after the world and
-- before the characters, by the shader below.
--
-- WHAT IT REFLECTS, in the order the shader resolves them:
--
--   the sky      the reflected direction is put through the SAME matrix the
--                frame is drawn with, as a point at infinity, and the canvas
--                row that lands on is looked up on Sky's own band ramp --
--                the identical texture, dither and display-mode transform
--                the painted sky uses. So the sky in the lake is the sky
--                over it: blue at noon, gold at dusk, navy under the moon,
--                and it meets the painted sky at the waterline with no seam.
--
--   the sun,     hung by ANGLE rather than by screen position, because a
--   the moon     reflected body is usually off the top of the frame and a
--                projected point is meaningless out there. The angular
--                radius is Sky.discRadius converted through the camera's own
--                field of view, so the disc on the water is exactly as big
--                as the disc in the sky -- craters, dithered rim, the
--                sunset's loom and all. This is also the specular: a low sun
--                lays a broken gold path across the water on its own, out of
--                the reflection rather than out of a highlight term.
--
--   the world    SCREEN SPACE. The reflected ray is walked forward in world
--                space, each step projected through the same matrix, looking
--                for where it passes behind what the depth buffer holds --
--                then binary-refined onto the contact and read out of a copy
--                of the frame as it stood before the water went down. Shore
--                trees, buildings, ledges and cliffs land in the water
--                because they are on screen; where the ray leaves the frame
--                or finds nothing, the sky above answers instead, which is
--                what makes the far half of a lake sky and the near half
--                scenery without a seam between them.
--
--   the cast     the walkers, the NPCs, the authored figures and a staged
--                battle's two Pokemon. Awkward, and settled by drawing them
--                twice: Gen 1 draws people OVER the world and water is
--                world, so a surfing player has to composite after the
--                water, and a reflection can only hold what came before it.
--                So they are painted into the reflection copy alone
--                (Voxel3D.beginWater), in the picture the water reflects and
--                not yet in the picture it is drawn into.
--
-- WHAT IT CANNOT REFLECT is what no screen-space reflection can: anything
-- that is not in the frame. A tree just off the top edge is not in the water
-- below it, and a ray that runs off the side of the screen fades into the
-- sky rather than ending on a line.
--
-- THE SURFACE ITSELF is not flat. It is a heightfield of one-world-pixel
-- columns, each standing a whole number of pixels tall and rising and
-- falling as waves, walked by the view ray in the pixel shader -- so the
-- bars occlude each other and show their sides without a single extra
-- vertex. See WAVE_HEIGHT and relief().
--
-- THE PASS ITSELF, and why it is shaped this way. The scene canvas carries a
-- READABLE depth canvas (Voxel3D), and a texture cannot be sampled while it
-- is bound as a render target -- so for the length of this pass the depth
-- buffer is DETACHED and the shader does the depth test itself, comparing
-- its own fragment depth against the texture it just stopped writing to.
-- That is the same test the hardware would have run, so a tree in front of a
-- pond still hides it; what it costs is depth WRITES, which water has no use
-- for anyway (it is flat, it never overlaps itself, and everything drawn
-- after it stands on top of it by construction).
--
-- Falls back all the way down. No readable depth canvas, a driver that will
-- not compile this, or the row set to OFF and the water mesh is simply drawn
-- by the ordinary scene shader -- flat animated water, exactly what the mode
-- drew before any of this existed.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ModSetting = V.require("ui/settings/ModSetting")
local Sky = V.require("effects/Sky")
local DayNight = V.require("effects/DayNight")
local ShadowMap = V.require("effects/ShadowMap")
local Mat4 = V.require("util/Mat4")

local Water = {}

-- ------- the row
--
-- Three rungs rather than a toggle, because the two halves of this cost
-- very different things. SKY is a handful of instructions per water pixel
-- and no extra buffers read; FULL adds the screen-space march, which is the
-- part that samples a depth texture twenty-odd times. A phone that wants the
-- sunset on the lake but not the ray march has somewhere to stand.
Water.KEY = "water"
Water.LABEL = "WATER"

Water.setting = ModSetting.new(Water.KEY, Water.LABEL,
                               { "full", "sky", "off" },
                               { "FULL", "SKY", "OFF" })

function Water.level()
  local v = Water.setting:get()
  if v == "off" then return 0 end
  if v == "sky" then return 1 end
  return 2
end

-- Whether the reflective pass should run at all (either rung above OFF).
function Water.enabled()
  return Water.level() > 0
end

-- ------- the look, in constants
--
-- FRESNEL. Water reflects almost nothing looked straight down at and almost
-- everything looked along, which is Schlick's curve -- and taken literally
-- it hands the top rung a mirror and the other four nothing at all. This
-- mode's rungs are named for the camera's tilt off VERTICAL, so 15 is a
-- near-overhead camera meeting the water at 15 degrees off its normal:
-- honest Schlick gives that about 2%, and even a generous floor of 0.14 was
-- invisible.
--
-- So the floor is lifted a long way above water's true 0.04 and the exponent
-- softened from 5 to 2: the SHAPE is still the honest one -- a low camera
-- still gets much more of it than a high one -- but the bottom of the curve
-- is a pond rather than a painted tile.
Water.FRESNEL_FLOOR = 0.34
Water.FRESNEL_CEIL = 0.92
Water.FRESNEL_POWER = 2.0

-- THE HORIZON LEAN, which is the other half of why the steeper rungs showed
-- nothing -- and the bigger half.
--
-- A reflection off flat water points as far ABOVE the horizon as the eye is
-- above the water. At the top rung that is 15 degrees: the reflected ray
-- grazes the sky's pale end, sweeps the sun's own path and travels far
-- enough across the screen for the march to find the shoreline. At the 15
-- rung it is 75 degrees -- straight up. Up there the sky's bands are at
-- their DARKEST (deep blue over blue water, which is no picture at all), the
-- sun and moon sit at about 6 degrees of squashed elevation and are nowhere
-- near it, and the screen-space ray leaves the top of the frame in two
-- steps. All three of those are correct, and together they are a lake with
-- nothing in it.
--
-- So the reflected direction LEANS toward the way this camera is looking, by
-- however far the camera is from having a horizon in frame. That is a
-- deliberate stylisation and it is worth being exact about what it costs and
-- what it does not:
--
--   at the rung where the horizon IS in frame the lean is ZERO, so the one
--   place the join can actually be seen -- the waterline, where the lake
--   meets the painted sky -- is still the exact reflection it was.
--
--   at the rungs where the horizon is above the top edge there is no join to
--   break, and what the lean buys is the whole of the effect: the pale bands,
--   the sunset, the moon's path, and a screen-space ray that travels ACROSS
--   the diorama instead of straight out of it.
--
-- It leans toward an ELEVATION rather than by a weight, and that matters.
-- Mixing the ray a fixed fraction of the way toward horizontal sounds like
-- the same thing and is not: the ray it starts from is different at every
-- rung, so a fixed fraction lands them all somewhere different, and the
-- middle rungs came out worst of all -- further from the sun than the
-- steepest one. Aimed at an elevation, every rung below the top one puts its
-- reflection where the TOP rung puts its own, which is the one place the
-- effect is known to work.
--
-- Measured off Voxel3D.descent -- the sine of how far below horizontal the
-- view runs -- so it answers for the battle's placed camera too, which has
-- no rung to be asked about.
Water.LEAN_FROM = 0.30         -- descent where the lean starts: the top rung's
Water.LEAN_FULL = 0.55         -- and where it is complete
-- the elevation it aims at: the one the top rung's own reflection sits at,
-- stated as that same descent so the two cannot drift apart
Water.LEAN_ELEV = math.asin(Water.LEAN_FROM)

function Water.lean(descent)
  local span = Water.LEAN_FULL - Water.LEAN_FROM
  local t = ((descent or 0) - Water.LEAN_FROM) / span
  if t <= 0 then return 0 end
  return t < 1 and t or 1
end

-- ------- the waves
--
-- Not a normal map. The surface is a HEIGHTFIELD of one-world-pixel columns
-- -- the same unit every other voxel in this mode is built from, and exactly
-- one texel of the water tile (a tile is 8 texels across 8 world pixels) --
-- and every column stands at a whole number of pixels. So the water is a
-- field of little square bars rising and falling on their own, which is what
-- water made of pixels should look like from a camera that can see it in 3D.
--
-- It is drawn without any extra geometry. The mesh is still one flat quad
-- per tile; the columns are found by walking the view ray down through the
-- slab in the pixel shader (relief mapping) and taking the first one it
-- meets. That is what makes them read as SOLID rather than as shading: a
-- tall bar hides the shorter ones behind it, you see the SIDE of the ones
-- facing you, and the whole field parallaxes against the plane as the camera
-- moves. The side faces wear the mesh's own direction shading
-- (Voxel3D.FACE_SHADE, sent in rather than restated) so a wave crest is lit
-- like every other voxel in the world.
--
-- HEIGHT is in world pixels: the tallest a column may stand above the plane
-- the quad is drawn on, and so both the amplitude and the number of rungs a
-- crest can climb through (five gives six).
--
-- It is well past the 2px recess TileShape sinks water into, which is a
-- deliberate look rather than an oversight: the crests are RELIEF, drawn
-- inside the water quad's own screen footprint, so a bar that reaches above
-- the shoreline cannot actually spill over the bank -- it is clipped at the
-- water's edge like everything else this pass draws. What it buys is a
-- surface with real swell in it instead of a two-rung terrace.
Water.WAVE_HEIGHT = 5

-- ------- the trains
--
-- Each is { fx, fz, speed, weight }. The vector is the train's DIRECTION and
-- its frequency in one -- the crest runs across it, and two pi over its
-- length is the wavelength in world pixels -- and `speed` is what walks it.
--
-- The first one dominates, and that weighting is the whole difference
-- between water and soup: a wave has a direction, and its crest is a line
-- running across it for as far as the surface goes. Three trains of equal
-- weight cancel and reinforce in patches instead, and the field comes out as
-- round islands of raised pixels with no travel to them.
--
-- Long, too: the dominant wavelength is about forty world pixels, five
-- tiles, so a crest is a run of hundreds of columns at one height with a
-- step down either side. Pitched anywhere near a pixel they stop being waves
-- and become static -- every column its own island.
--
-- Read into the shader source rather than sent as uniforms, so the rate
-- below can be derived from the same numbers the field is built out of.
Water.WAVE_TRAINS = {
  { 0.150, 0.062, 1.60, 0.60 },
  { 0.058, 0.132, -1.05, 0.29 },
  { -0.041, 0.033, 0.55, 0.11 },
}

-- ------- and what keeps them from reading as one pattern
--
-- Three fixed trains are still an exactly periodic field: every forty-odd
-- pixels of sea wears the same crest at the same height, and a lake's worth
-- of that reads as wallpaper. Real swell varies two ways a sum of sines
-- cannot: waves arrive in SETS -- a few tall ones, then a lull -- and a
-- crest line curves as it runs rather than ruling itself across the whole
-- surface. Both are put back with one long-wavelength field each, riding
-- the DOMINANT train only; the two lesser trains stay plain, because they
-- are texture rather than structure and three modulators is soup again.
--
-- Both wear the trains' own shape, { fx, fz, speed, x }: a direction whose
-- length is the spatial frequency, a phase rate, and what the field does.
-- Their wavelengths sit four to five times the carrier's, far enough apart
-- that neither reads as a wave itself -- the swell as slow weather over the
-- crests, the bend as the crests' own drift.
--
-- THE SWELL scales the dominant train's amplitude; `x` is the DEPTH of the
-- deepest lull, as the fraction of the train it takes away. It runs roughly
-- along the carrier's own direction and slower than it, which is a wave
-- group's honest habit (deep-water groups travel at about half the phase
-- speed) -- so sets of crests swell up, march a while, and hand over to a
-- calm patch that is itself moving.
Water.WAVE_SWELL = { 0.0325, 0.0134, 0.55, 0.35 }

-- THE BEND adds a slow wobble to the dominant train's phase; `x` is the
-- wobble's reach in RADIANS of carrier phase. 1.1 radians against a carrier
-- of about forty pixels bows a crest some seven pixels off its line over
-- the bend's own hundred-and-seventy-five -- a visible curve, not a
-- scribble -- and it runs ACROSS the carrier, which is the direction a
-- crest line actually wanders. What it costs is exactness in waveRate's
-- derivation: the carrier's local frequency now breathes around the number
-- the rate is derived from, so the one-pixel step is the average step
-- rather than every step's. The step CLOCK is untouched; only how far a
-- bowed stretch of crest moves on one tick varies, and by under a pixel.
Water.WAVE_BEND = { -0.0138, 0.0333, 0.35, 1.10 }

-- ------- and the beat they move on
--
-- The surface does not slide, it advances in STEPS, off the engine's own
-- frame counter -- the move that makes this read as art rather than as a
-- simulation someone forgot to stylise. A surface built out of whole pixels
-- that crawls between them smoothly gives away that the quantisation is
-- only skin deep.
--
-- 12 a second, a shade under the 15 hand-drawn pixel art is usually
-- animated at: the crests were hurrying, and a big wave is slower than a
-- sprite's walk cycle. Still a clean divisor of the engine's 60, so every
-- step spans the same whole number of frames.
Water.WAVE_FPS = 12

-- How far the dominant train advances each of those steps, in WORLD PIXELS.
-- One is the honest choice for a stepped surface: the whole field shifts by
-- exactly one pixel per frame, so nothing ever lands half-way between two.
-- The rate below is derived from it rather than tuned beside it, so changing
-- a wavelength moves the speed with it instead of quietly desynchronising.
Water.WAVE_PIXELS_PER_STEP = 1

-- Radians of wave phase per second. A train travels `speed / frequency`
-- world pixels per radian of phase, so the phase that moves the dominant one
-- a pixel is its frequency over its speed -- times the step rate.
function Water.waveRate()
  local t = Water.WAVE_TRAINS[1]
  local freq = math.sqrt(t[1] * t[1] + t[2] * t[2])
  local speed = math.abs(t[3])
  if not (freq > 0 and speed > 0) then return 0 end
  return Water.WAVE_PIXELS_PER_STEP * (freq / speed) * Water.WAVE_FPS
end
-- Relief samples down through the slab. With the stride pinned at one world
-- pixel (see WAVE_STRIDE) this is also how FAR the march can see: sixteen
-- samples, sixteen pixels of parallax, which covers the slab at every rung
-- but the very lowest and leaves the rest to fade out honestly.
--
-- The pass early-outs entirely (see relief) whenever the camera is steep
-- enough that the whole slab projects to under a pixel across, which is most
-- of the ladder -- so the cost of this only lands where it buys something.
Water.WAVE_STEPS = 16

-- The furthest one relief sample may travel ACROSS the surface, in world
-- pixels -- which is what bounds how far the march runs in total.
--
-- The march's reach is the slab's depth over the ray's descent, so it grows
-- without limit as the camera flattens: at the top rung, fragments near the
-- horizon look along the water at a few degrees and the reach runs to
-- hundreds of world pixels. Spread over a fixed number of samples that steps
-- clean over whole crests, and the surface comes apart into streaks running
-- away from the eye. Capping the span is what keeps a sample worth taking;
-- what it costs is parallax on the far water, where the columns are under a
-- pixel across and there was nothing left to see anyway.
--
-- This is the FLOOR on it. The stride the march actually takes is a SCREEN
-- pixel's worth of surface, which is the only rate that makes sense:
--
--   up close, a screen pixel is a fraction of a world pixel, so the stride
--   sits on this floor of one world pixel and the march visits every column
--   on its path. It has to: a column is one world pixel wide, a longer
--   stride steps over columns, and which ones it misses changes from
--   fragment to fragment -- neighbouring pixels landing on different columns
--   at different heights wearing different faces. That is peppery noise.
--
--   far away, a screen pixel already spans several world pixels, so a stride
--   that matches it skips columns the screen could not have resolved anyway.
--   Holding it at one world pixel out there does not buy detail, it just
--   runs out of samples -- and a march that runs out stops part-way down the
--   slab and reports the surface as flat, which is why the lowest rung lost
--   its waves entirely across the whole middle distance.
Water.WAVE_STRIDE = 1

-- How far the wave field's own gradient tilts the REFLECTION. A multiplier
-- on the SMOOTH surface's slope, not on the stepped one -- see waveNormal
-- for why that distinction is the whole difference between a moon on the
-- water and confetti. The field's gradient peaks around 0.06 per world
-- pixel, so this lands the steepest faces about twelve degrees off vertical:
-- enough to sweep a low sun or moon into a broken glitter path down the
-- lake, and not so much that the sky's own bands come apart.
Water.WAVE_SLOPE = 3.5
-- and how far the horizon lean is allowed to open that up, since it squashes
-- the same tilt on its way past (see LEAN_FROM)
Water.WAVE_SLOPE_LEAN = 1.5

-- THE MARCH. Steps are in world pixels and lengthen as they go: near the
-- surface the reflection needs precision (a shoreline is a few pixels), far
-- from it reach matters more than accuracy, and a geometric ramp gets both
-- out of one loop. RAY_STEPS is compiled in -- GLSL wants a constant bound.
Water.RAY_STEPS = 24
Water.RAY_REFINE = 5           -- halvings once a crossing is found
Water.RAY_STEP = 3.0           -- world pixels in the first step
-- and the ratio each step after it. 3 x (1.18^24 - 1) / 0.18 is about 930
-- world pixels of reach -- three view-heights, past which a reflection is
-- faded out anyway (see the tail fade in march) and the sky is the honest
-- answer: distant water reflects haze, which is what the bands already are.
Water.RAY_GROW = 1.18
-- How far behind the depth buffer a crossing may land and still count, as a
-- multiple of the depth the step itself covered. A ray that dives far past
-- what it crossed went BEHIND a thin thing rather than hitting it -- the
-- classic screen-space smear, where a tree between the camera and the pond
-- paints itself across the water -- and this is the test that drops it.
Water.RAY_THICK = 1.6
Water.EDGE_FADE = 0.14         -- reflection eased off over this much of the frame

-- ------- the shader
--
-- The scene shader's own vertex path, plus the world position the geometry
-- was actually DRAWN at -- after the world curve, because that is the space
-- the surface the eye MEETS lives in: which wave column a screen pixel is
-- looking at is a question about the geometry as drawn, and relief() answers
-- it there. (The curve only ever moves Y, so a fragment's world XZ is the
-- same on both sides of it and the ripple can be measured off this one too.)
--
-- WHAT IT REFLECTS is worked out on the other side of the bend, in the FLAT
-- world, and this is the same rule the rest of the mode keeps: the curve
-- tips the world away and the things standing on it do not lean with it (see
-- WorldCurve -- buildings stay upright, shadows are resolved before the bend
-- and ride along). A lake is one of those things. Reflect off the bowl the
-- bend has made instead and the far half of a pond is a mirror tilted twenty
-- degrees: it throws the ray past the vertical, where the sky ramp's own
-- measure -- a screen row, through the frame's matrix -- swings from one end
-- of the ramp to the other across a single column, and the pond comes out
-- with hard-edged patches of the wrong sky stamped into it -- the overhead
-- band and the horizon band abutting in the middle of a lake, which reads as
-- something other than water showing through. The same tilt sends the
-- screen-space march grazing along the bank instead of over it, which is the
-- other half: the dock and the roofs smeared across the harbour.
--
-- So the reflection is taken with the flat view ray about the flat normal,
-- exactly as it would be with the curve off -- and the MARCH still has to
-- walk the world as drawn, because that is what the depth buffer holds. Both
-- at once: the ray is straight in the flat world, and project() bends each
-- sample on its way to the screen, which is the same displacement the vertex
-- stage applies and therefore lands in the same place the geometry did.
-- Water shader source (moved out of this file for readability).
-- Loaded once; variants are built by prepending #defines.
local SHADER_SRC = V.mod:read("lib/shaders/water.glsl")
if not SHADER_SRC then
  error("DRAMATIC_SHAPE: lib/shaders/water.glsl is missing -- reinstall the mod", 0)
end

-- The crater list is Sky's (Sky.MOON_CRATERS), pasted in as source rather
-- than sent as a uniform array: GLSL ES has no array constructors worth
-- relying on, and the driver bug that cost the sky its bands is exactly
-- what a uniform array of vectors buys. Built from the one list, so the
-- moon on the water can never grow craters the moon in the sky has not.
local function craterSource()
  local out = {}
  for _, c in ipairs(Sky.MOON_CRATERS) do
    out[#out + 1] = ("    k += crater(dc, vec2(%.4f, %.4f), %.4f);")
      :format(c[1], c[2], Sky.CRATER_FRAC)
  end
  return table.concat(out, "\n")
end

Water._craterSource = craterSource     -- named for the suite

-- and the wave trains, pasted in for the same reason: the rate is derived
-- from this table (Water.waveRate), so the field the shader sums has to be
-- the one that table describes rather than a copy of it kept in step by hand.
--
-- The dominant train carries the swell and the bend (see WAVE_SWELL): its
-- phase wobbles by the bend field and its amplitude breathes with the swell
-- envelope, both off the same tables the constants above document. One
-- statement per train either way, which is what the suite counts.
local function trainSource()
  local out = {}
  for i, t in ipairs(Water.WAVE_TRAINS) do
    if i == 1 then
      local s = Water.WAVE_SWELL
      local b = Water.WAVE_BEND
      out[#out + 1] = (
        "  h += sin(dot(q, vec2(%.4f, %.4f)) + waveT * %.4f\n"
        .. "           + %.4f * sin(dot(q, vec2(%.4f, %.4f)) + waveT * %.4f))\n"
        .. "       * %.4f * (1.0 - %.4f * (0.5 + 0.5 *\n"
        .. "           sin(dot(q, vec2(%.4f, %.4f)) + waveT * %.4f)));")
        :format(t[1], t[2], t[3],
                b[4], b[1], b[2], b[3],
                t[4], s[4], s[1], s[2], s[3])
    else
      out[#out + 1] = ("  h += sin(dot(q, vec2(%.4f, %.4f)) + waveT * %.4f)"
                       .. " * %.4f;"):format(t[1], t[2], t[3], t[4])
    end
  end
  return table.concat(out, "\n")
end

Water._trainSource = trainSource       -- named for the suite

local function source(grid, bare)
  local src = SHADER_SRC:gsub("//@CRATERS", (craterSource():gsub("%%", "%%%%")))
  src = src:gsub("//@TRAINS", (trainSource():gsub("%%", "%%%%")))
  local head = ("#define RAY_STEPS %d\n#define RAY_REFINE %d\n"
                .. "#define WAVE_STEPS %d\n#define WAVE_STRIDE %.1f\n")
    :format(Water.RAY_STEPS, Water.RAY_REFINE, Water.WAVE_STEPS,
            Water.WAVE_STRIDE)
  if grid then head = head .. "#define VOXEL_GRID 1\n" end
  -- effect()'s parameter precision -- see the signature for why it cannot
  -- simply be spelled there. Empty is a define all the same: the params
  -- then carry the stage default, which is what a prototype declared
  -- without qualifiers wants.
  head = head .. (bare and "#define EFFECT_PREC\n"
                        or "#define EFFECT_PREC mediump\n")
  return head .. src
end

Water._source = source                 -- named for the suite

-- Two compilations, exactly as Voxel3D keeps two of the scene shader: the
-- wireframe variant needs derivatives, the one thing a driver can refuse,
-- and a refusal must cost the seams on the water and nothing else.
-- nil = untried, false = unavailable.
local shaders = { [false] = nil, [true] = nil }

function Water.shader(grid)
  grid = grid and true or false
  if shaders[grid] == nil then
    if not (love.graphics and love.graphics.newShader) then
      shaders[grid] = false
    else
      local ok, sh = pcall(love.graphics.newShader, source(grid))
      if not ok then
        -- the pinned prototype was the wrong one for this runtime; the bare
        -- one is the only other shape there is, and a driver that refuses
        -- both was never going to draw this water anyway
        local bareOk, bareSh = pcall(love.graphics.newShader, source(grid, true))
        if bareOk then ok, sh = bareOk, bareSh end
      end
      if not ok then
        -- once, where it can be read: the fallback is flat water, which is
        -- easy to look at and impossible to diagnose without this line
        local msg = ("water shader did not compile: %s -- lakes draw flat"):format(
          tostring(sh))
        if V and V.log then V.log:warn("%s", msg)
        elseif V and V.dlog then V.dlog(msg)
        elseif V and V.mod and V.mod.log then V.mod.log:warn("%s", msg) end
      end
      shaders[grid] = (ok and sh) or false
    end
  end
  return shaders[grid] or nil
end

-- ------- the pass

local active = nil        -- the shader this pass bound, or nil

-- The ripple phase. Driven by the ENGINE's tile-animation clock, the same
-- 60Hz counter the water tiles rotate on, so the ripple and the art it
-- ripples move off one number rather than drifting against each other.
local function waveTime()
  -- lazily, and through the mod namespace: TerrainAtlas reaches into the
  -- engine's renderer at load time, and nothing about a settings row should
  -- depend on that having happened yet
  local ok, frame = pcall(function()
    return V.require("voxel/TerrainAtlas")._animFrame()
  end)
  if not (ok and type(frame) == "number") then return 0 end
  -- floored to the wave beat (see WAVE_FPS). The engine's counter runs at
  -- 60, so this is the frame that step began on.
  local period = 60 / math.max(1, Water.WAVE_FPS)
  return (math.floor(frame / period) * period / 60) * Water.waveRate()
end

Water._waveTime = waveTime

-- Begin the reflective pass.
--
-- `ctx` is everything the pass cannot work out for itself, all of it already
-- computed by whoever set the camera up this frame:
--
--   reflect   the frame so far, as a texture (Voxel3D.beginWater)
--   depth     its depth, likewise
--   vp, eye, curve, screen, cell   the camera, as beginScene sent it
--   skyEdge   where the sky's bottom is, or nil indoors / with no bands
--   grid      whether the voxel wireframe is compiled into this frame
--
-- Returns false when the pass cannot run, in which case the caller draws the
-- water mesh through the ordinary scene shader instead.
function Water.begin(ctx)
  if not (ctx and ctx.reflect and ctx.depth) then return false end
  local level = Water.level()
  if level <= 0 then return false end
  local sh = ctx.grid and Water.shader(true) or nil
  if not sh then sh = Water.shader(false) end
  if not sh then return false end

  love.graphics.setShader(sh)
  love.graphics.setColor(1, 1, 1, 1)
  local function send(name, ...)
    pcall(sh.send, sh, name, ...)
  end

  send("vp", "row", ctx.vp)
  send("eye", ctx.eye)
  send("curve", ctx.curve)
  -- the viewport, as beginScene sent it to the scene shader; kind 0 --
  -- every frame neither the diorama nor the orbit's box has cut -- is
  -- "no cut"
  local cull = V.require("voxel/Voxel3D").cull
  send("cullAt", cull and { cull.x, cull.y, cull.z } or { 0, 0, 0 })
  send("cullShape", cull and { cull.r, cull.invFade, cull.kind }
                    or { 0, 0, 0 })
  send("cullRect", cull and { cull.rx or cull.r, cull.rz or cull.r }
                   or { 0, 0 })
  send("screen", { ctx.screen[1], ctx.screen[2] })
  send("cell", math.max(1, ctx.cell or 1))
  -- how much of the view one screen pixel is worth: what sets the relief
  -- march's stride, so a sample is always about a pixel of surface
  send("pxAngle", (ctx.fov or 1) / math.max(1, ctx.screen[2]))
  send("reflectTex", ctx.reflect)
  send("depthTex", ctx.depth)

  -- the sun's pass, sent the same way and for the same reason the scene
  -- shader sends it: the sampler is declared either way, and leaving one
  -- unbound is a driver-dependent crash rather than a fallback
  local map = ShadowMap.active()
  send("sunVP", "row", map and ShadowMap.uvVP or Mat4.identity())
  local tex = ShadowMap.texture()
  if tex then send("sunMap", tex) end
  local Voxel3D = V.require("voxel/Voxel3D")
  send("sunDark", map and Voxel3D.SHADOW_ALPHA or 0)
  send("sunBias", ShadowMap.bias)
  local texel = 1 / ShadowMap.res
  send("sunTexel", { texel, texel })
  send("dayTint", Voxel3D.tint or { 1, 1, 1 })

  send("rays", level >= 2 and 1 or 0)
  -- the horizon lean, and the direction it leans toward (see Water.lean)
  send("lookFlat", ctx.lookFlat or { 0, 0, -1 })
  send("lean", Water.lean(ctx.descent))
  send("leanElev", Water.LEAN_ELEV)
  send("waveHeight", Water.WAVE_HEIGHT)
  send("waveSlope", Water.WAVE_SLOPE)
  send("waveSlopeLean", Water.WAVE_SLOPE_LEAN)
  send("waveT", waveTime())
  -- the columns' side faces wear the MESH's own direction shading, sent in
  -- rather than restated, so a wave crest is lit like every other voxel
  local fs = Voxel3D.FACE_SHADE
  send("faceShade", { fs[1], fs[2], fs[5], fs[6] })   -- east, west, south, north
  send("fresnelFloor", Water.FRESNEL_FLOOR)
  send("fresnelCeil", Water.FRESNEL_CEIL)
  send("fresnelPower", Water.FRESNEL_POWER)
  send("rayStep", Water.RAY_STEP)
  send("rayGrow", Water.RAY_GROW)
  send("rayThick", Water.RAY_THICK)
  send("edgeFade", Water.EDGE_FADE)
  if ctx.grid then
    local VoxelGrid = V.require("voxel/VoxelGrid")
    send("gridDark", VoxelGrid.DARK)
    send("gridWidth", VoxelGrid.width())
  end

  Water.sendSky(sh, ctx)
  active = sh
  return true
end

-- The sky half of the uniforms: the band ramp, and whatever hangs in it.
--
-- Split out because it is the part with a "there is none" answer -- indoors,
-- and on any frame whose ramp could not be built -- and that answer has to
-- leave every sampler bound anyway. skyOn 0 reflects the water's own colour
-- back at itself, which is what a pond in a cave does.
function Water.sendSky(sh, ctx)
  local function send(name, ...)
    pcall(sh.send, sh, name, ...)
  end
  local ramp, count = Sky.ramp()
  local edge = ctx.skyEdge
  if not (ramp and count and edge and edge > 0) then
    -- the sampler still has to hold something; the ramp is the only image
    -- this shader has for the job, so bind the frame copy and switch it off
    send("skyRamp", ctx.reflect)
    send("skyCount", 1)
    send("skyEdge", 1)
    send("skyStart", 2)
    send("skyOn", 0)
    send("bodyOn", 0)
    send("glowAmt", 0)
    return
  end
  send("skyRamp", ramp)
  send("skyCount", count)
  send("skyEdge", edge)
  send("skyStart", Sky.DITHER and Sky.DITHER_START or 2)
  send("skyOn", 1)

  local body = DayNight.body()
  if not body then
    send("bodyOn", 0)
    send("glowAmt", 0)
    return
  end
  local amt, glowColor = DayNight.glow()
  local h = ctx.screen[2]
  local cell = math.max(1, ctx.cell or 1)
  -- Sky sizes the disc in canvas pixels; out here the reflected body is
  -- usually off the top of the frame, where a pixel is not a unit any more
  -- -- so it is converted to the ANGLE it subtends through this camera's
  -- own field of view, which is the same number wherever it is looked at.
  local perRadian = h / math.max(1e-4, ctx.fov or 1)
  local rpx = Sky.discRadius(h, cell,
                             { moon = body.moon, glowAmt = amt })
  local shades = Sky.discShades(body.moon)
  local function shade(i)
    local c = shades[i] or shades[#shades] or { 255, 255, 255 }
    return { c[1] / 255, c[2] / 255, c[3] / 255 }
  end
  local twilight = (amt or 0) > 0.25 and not body.moon
  send("bodyOn", 1)
  send("bodyMoon", body.moon and 1 or 0)
  send("bodyDir", { body.dx, body.dy, body.dz })
  send("bodyAng", rpx / perRadian)
  send("bodyCore", shade(1))
  send("bodyMain", shade(twilight and 3 or 2))
  send("bodyDark", shade(3))
  send("glowAmt", (not body.moon) and (amt or 0) or 0)
  send("glowColor", glowColor
       and { glowColor[1] / 255, glowColor[2] / 255, glowColor[3] / 255 }
       or { 1, 0.88, 0.66 })
  send("glowReach", (ctx.screen[1] * Sky.GLOW_REACH) / perRadian)
end

-- Draw one water mesh with `model` applied. Mirrors Voxel3D.draw, minus the
-- camera-ward pull (a flat sheet has nothing to lean over) and the separate
-- sun transform (water is terrain: the sun saw the same matrix).
function Water.draw(mesh, texture, model)
  if not (active and mesh) then return end
  if texture then mesh:setTexture(texture) end
  pcall(active.send, active, "model", "row", model or Mat4.identity())
  -- Per draw rather than per pass, and read off the TEXTURE rather than
  -- assumed: it is what converts a world pixel of the columns' parallax into
  -- the texel of art standing on it, and two maps in one frame can be drawn
  -- from atlases of different sizes.
  if texture and texture.getDimensions then
    local ok, w, h = pcall(texture.getDimensions, texture)
    if ok and w and h then
      pcall(active.send, active, "atlasSize", { w, h })
    end
  end
  love.graphics.draw(mesh)
end

function Water.finish()
  active = nil
end

-- Drop the compiled shaders (window resize, hot reload): they are GPU
-- objects on a context that may not exist any more.
function Water.invalidate()
  for k, sh in pairs(shaders) do
    if sh and sh.release then pcall(sh.release, sh) end
    shaders[k] = nil
  end
  active = nil
end

return Water
