varying float vShade;
varying vec3 vSun;          // this fragment's place in the sun's view
varying float vFog;         // how deep into the map's haze it stands
varying float vFirefly;     // zero normally, night glow on firefly cards

// Explicitly qualified, and it has to be: an unqualified float takes each
// STAGE's default precision, and those do not agree -- highp in the vertex
// stage, mediump in the fragment one.  LOVE 11 linked the pair anyway;
// LOVE 12 holds both declarations to the same qualifier and refuses the
// whole shader over it, which costs the entire 3D pass -- Voxel3D.available()
// is a shader that compiled, and the overworld falls back to flat 2D with
// nothing said anywhere.  Same macro the varyings below already use.
uniform LOVE_HIGHP_OR_MEDIUMP float fireflyNight;

#ifdef VOXEL_CULL
    // where this fragment stands in the FLAT world, for the diorama's
    // viewport to measure. Same precision reasoning as vGrid below: a
    // route's coordinates run to a few thousand and mediump has no
    // fraction left out there, which would make the rim crawl.
    varying LOVE_HIGHP_OR_MEDIUMP vec3 vWorld;
#endif

#ifdef VOXEL_GRID
    // model space, one unit per voxel -- see VoxelGrid. Precision matters
    // here in a way it does not for a colour: the seam is the FRACTIONAL
    // part of a coordinate that runs to a few thousand across a big route,
    // so a mediump varying would quantise the fraction away entirely.
    varying LOVE_HIGHP_OR_MEDIUMP vec3 vGrid;
#endif

#ifdef VERTEX
    uniform mat4 vp;
    uniform mat4 model;
    uniform mat4 sunModel;      // where the SUN sees this vertex (see below)
    uniform mat4 sunVP;         // world -> the shadow map's unit cube
    uniform vec3 eye;
    uniform float pull;
    uniform vec3 curve;         // xy = the focus in world XZ, z = k; 0 = off
    uniform vec4 fogInfo;       // density, start, heightK; density 0 = clear
    uniform vec4 grassWind;     // enabled, time, wind pixels, speed
    uniform vec4 grassPlayer;   // world x, world z, radius, push pixels
    uniform vec2 grassPrevious; // previous player world xz for swept contact
    attribute float VertexShade;
    attribute vec4 VertexGrass;

    vec4 position(mat4 transform_projection, vec4 vertex_position) {
        vShade = VertexShade;
        vFirefly = 0.0;

    #ifdef VOXEL_GRID
        // MODEL space, deliberately: every mesh here is built a unit per
        // voxel in its own frame, so the seams ride the model however it is
        // posed rather than the world's grid sliding across a leaning sprite
        vGrid = vertex_position.xyz;
    #endif

        vec4 w = model * vertex_position;

        // The shadow lookup runs off `sunModel`, not `model`. For terrain the
        // two are the same matrix, but a character is drawn as a slab LEANING
        // back by the camera's pitch -- a trick played on the viewer, which
        // the sun never saw: it lit the upright card. Looking up with the
        // leaned position asks whether the sun reached a place the figure is
        // not, and since the lean tips the body north and shadows now fall
        // north, every sprite's own card fell across its front. Looking up
        // with the card's position asks the question the sun actually
        // answered. (The pull below is excluded for the same reason: it is a
        // depth trick aimed at the camera's own buffer.)
        vSun = (sunVP * (sunModel * vertex_position)).xyz;

        // Wind and player contact are applied in world space, before the curved
        // world and camera pull. vertex y is 0..8 for these tuft meshes, which
        // pins the root and lets the tip receive the full displacement.
        if (grassWind.x > 0.5) {
            float bend = clamp(vertex_position.y / 8.0, 0.0, 1.0);
            bend *= bend;
            float wave = sin(grassWind.y * grassWind.w + VertexGrass.x);

            if (VertexGrass.w > 1.5) {
                // One-pixel firefly with a full behaviour loop: a long rest on the
                // grass, smooth take-off, an irregular short flight, descent, landing
                // and another pause. The baked phase keeps every insect independent.
                float cycle = fract(grassWind.y * 0.052 + VertexGrass.x * 0.173);
                float takeoff = smoothstep(0.30, 0.39, cycle);
                float landing = 1.0 - smoothstep(0.68, 0.79, cycle);
                float airborne = takeoff * landing;
                float drift = grassWind.y * 0.83 + VertexGrass.x * 3.7;
                float wander = sin(drift) * 2.8 + sin(drift * 0.37 + 1.3) * 1.5;
                float lift = 2.5 + sin(drift * 1.19) * 1.1
                        + sin(drift * 0.53 + 0.8) * 0.7;
                w.x += airborne * wander;
                w.y += airborne * lift;
                // Mostly dim while resting, visibly brighter in flight, with a soft
                // asynchronous pulse rather than a hard on/off blink.
                float blink = 0.68 + 0.32 * (sin(drift * 2.11) * 0.5 + 0.5);
                vFirefly = fireflyNight * blink * mix(0.14, 0.92, airborne);
            } else if (VertexGrass.w > 0.5) {
                // The first 72% of the cycle is airborne. A leaf gets an initial
                // upward lift, travels with the wind, then gravity accelerates it
                // down to the ground. It rests there for the remainder before a new
                // leaf is emitted. Z remains fixed, preserving sprite depth order.
                float life = fract(grassWind.y * 0.085 + VertexGrass.x * 0.159);
                float fall = min(life / 0.72, 1.0);
                float travel = fall * 44.0 - 6.0;
                float flutter = grassWind.y * 3.0 + VertexGrass.x * 4.7;
                float lift = sin(fall * 3.14159265) * 5.0;
                float gravity = 9.0 * fall * fall;
                float flutterFade = 1.0 - smoothstep(0.62, 1.0, fall);
                w.x += travel + sin(flutter) * 1.2 * flutterFade;
                w.y += lift - gravity
                    + sin(flutter * 0.61) * 0.8 * flutterFade;
            } else {
                vec2 offset = vec2(wave * grassWind.z, 0.0);
                vec2 clump = VertexGrass.yz;
                float bodyDist = length(clump - grassPlayer.xy);
                float touch = 1.0 - smoothstep(grassPlayer.z * 0.45,
                                            grassPlayer.z, bodyDist);
                float side = clump.x < grassPlayer.x ? -1.0 : 1.0;
                if (abs(clump.x - grassPlayer.x) < 0.5)
                    side = sin(VertexGrass.x) < 0.0 ? -1.0 : 1.0;
                w.xz += offset * bend;
                w.x += side * touch * grassPlayer.w;
            }
        }

        // THE MAP'S HAZE (see ForestAtmos): how much fog stands between the
        // eye and this vertex -- distance dissolves into it, altitude climbs
        // out of it. Worked out on the FLAT world like the shadow lookup
        // above (the curve is a trick played on the viewer, not weather),
        // and per VERTEX: on meshes built a face per voxel the interpolated
        // answer is indistinguishable from per-fragment fog at a fraction of
        // the cost.
        vFog = 0.0;
        if (fogInfo.x > 0.0) {
            float fogRun = max(0.0, length(w.xyz - eye) - fogInfo.y);
            vFog = (1.0 - exp(-fogInfo.x * fogRun))
                * exp(-max(w.y, 0.0) * fogInfo.z);
        }

    #ifdef VOXEL_CULL
        // THE DIORAMA'S VIEWPORT (see lib/Diorama) is measured per FRAGMENT,
        // so this stage's only job is to hand the position over -- and to hand
        // over the FLAT one, like the fog and the shadow lookup above: the
        // curve is a trick played on the viewer, and letting it drag geometry
        // in and out of the viewport would make the rim breathe with the bend.
        //
        // Per fragment rather than per vertex because the diorama's own base
        // is cut into cells far coarser than the rim is wide, and interpolating
        // the rim across one of those spilled a whole cell of ground past the
        // edge of a staged fight's disc.
        vWorld = w.xyz;
    #endif

        // The curved world (see WorldCurve): drop every vertex by the square
        // of how far its column stands from the camera's focus. Applied AFTER
        // the shadow lookup above and clear of the wireframe's model space, so
        // both are worked out on the flat world and the bend carries them
        // along -- which is why neither has to know this exists. Along Y only,
        // so a column moves as one piece: the world tips away and the
        // buildings standing on it stay upright.
        if (curve.z > 0.0) {
            vec2 cd = w.xz - curve.xy;
            w.y -= dot(cd, cd) * curve.z;
        }

        // camera-ward pull: move the vertex along ITS OWN ray to the eye.
        // This is a pure depth bias -- the projection of a point moved along
        // its eye ray is bit-identical, so there is no screen drift at all.
        // (An earlier CPU version translated along the central view axis,
        // which preserved only the screen centre and made off-centre sprites
        // and grass swim against the ground while the camera scrolled.)
        //
        // NEVER PAST THE EYE, which is the one way this can stop being a pure
        // depth bias: a vertex nearer the lens than `pull` is carried through
        // it and out the other side, where the projection turns inside out and
        // the thing lands wherever the far side of the frame happens to be --
        // a single tuft of grass smeared across the whole picture. Impossible
        // on an orbit rung, where the eye is a screen height away and the pull
        // is tens of pixels; ordinary for a staged fight's seat, which stands
        // a couple of cells from what it is looking at, and for a first-person
        // eye standing in the grass. Half the range is the ceiling: at that
        // distance nothing is losing a depth fight the other half would win.
        if (pull > 0.0) {
            vec3 toEye = eye - w.xyz;
            float range = length(toEye);
            w.xyz += toEye / max(range, 1e-4) * min(pull, range * 0.5);
        }

        return vp * w;
    }
    #endif

#ifdef PIXEL
    #ifdef VOXEL_CULL
        // The viewport, declared in THIS STAGE ALONE. A uniform declared in both
        // defaults to highp in the vertex stage and mediump here, and GLSL ES
        // refuses to link a uniform the two stages disagree about -- which is
        // not a broken cut but no scene shader at all (lib/Water states the same
        // trap at length for `vp`).
        uniform vec3 cullAt;        // the viewport's centre, in world pixels
        uniform vec3 cullShape;     // half-size, 1/fade, kind: 1 box, 2 ball,
                                    // 3 the staged fight's pillar
        uniform vec2 cullRect;      // the BOX's half-extents in x and z, which
                                    // the round kinds have no use for. Two
                                    // numbers because the flat screen's box is
                                    // the WINDOW's own footprint and a window is
                                    // not square (lib/ViewBox); a headset's is,
                                    // and lib/Diorama sends the same half-size
                                    // twice.

        // 1 well inside the viewport, 0 outside it, and the rim in between --
        // which is a HARD edge for the box (its band is half a pixel wide, so
        // the ramp is just the antialiasing) and a dissolve for the other two.
        //
        // Every kind is unbounded upward and downward on purpose: what is wanted
        // is a rectangular (or round) piece cut OUT OF THE MAP, and a cut with a
        // lid would take the tops off the trees standing in it.
        float dioramaCull(vec3 p) {
            if (cullShape.z <= 0.5) return 1.0;
            vec3 cd = p - cullAt;
            // how far INSIDE the cut this point is, in world pixels: the nearest
            // side for the rectangle, the rim for the two round kinds
            float inside;
            if (cullShape.z < 1.5) {
                inside = min(cullRect.x - abs(cd.x), cullRect.y - abs(cd.z));
            } else if (cullShape.z < 2.5) {
                inside = cullShape.x - length(cd);     // the ball, under V-CURVE
            } else {
                inside = cullShape.x - length(cd.xz);  // the fight's pillar
            }
            return clamp(inside * cullShape.y, 0.0, 1.0);
        }
    #endif

    uniform Image sunMap;
    uniform float sunDark;      // how far into black a shadow goes; 0 = off
    uniform float sunBias;
    uniform vec2 sunTexel;

    // the two-channel pack ShadowMap writes: high byte, then low
    float sunDepth(vec2 uv) {
        vec4 c = Texel(sunMap, uv);
        return c.r + c.g * (1.0 / 255.0);
    }

    // 1.0 in full sun, 1.0 - sunDark in full shadow. Four taps half a texel
    // out on the diagonals: a 2x2 box filter, which is what turns the
    // shadow map's texel staircase into a one-pixel soft edge.
    float sunlight(vec3 p) {
        if (sunDark <= 0.0) return 1.0;
        // outside the sun's frustum nothing was recorded, so nothing occludes
        if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0 || p.z > 1.0) {
            return 1.0;
        }
        // Ease the shadows off at the frustum's rim. The map covers the ground
        // the camera can see out to a cap, and past the low rungs -- 75 degrees
        // especially -- the horizon is further than any box worth paying for.
        // Without this the covered region simply ENDS, drawing a hard line
        // across the middle distance where every shadow stops at once; with it
        // the far field just loses them, which reads as distance.
        vec2 e = min(p.xy, 1.0 - p.xy);
        float edge = smoothstep(0.0, 0.06, min(e.x, e.y));
        if (edge <= 0.0) return 1.0;
        float z = p.z - sunBias;
        float lit = step(z, sunDepth(p.xy + sunTexel * vec2(-0.5, -0.5)))
                + step(z, sunDepth(p.xy + sunTexel * vec2( 0.5, -0.5)))
                + step(z, sunDepth(p.xy + sunTexel * vec2(-0.5,  0.5)))
                + step(z, sunDepth(p.xy + sunTexel * vec2( 0.5,  0.5)));
        return 1.0 - sunDark * edge * (1.0 - lit * 0.25);
    }

    #ifdef VOXEL_GRID
        uniform float gridDark;     // how far toward black a seam pulls; 0 = off
        uniform float gridWidth;    // seam width, in display pixels

        // How much of this fragment a voxel seam covers, 0 to 1.
        float voxelSeam(vec3 p) {
            // how much of `p` this fragment spans on screen, per axis: the
            // conversion from model units to display pixels, measured rather than
            // derived, so it holds under any camera pitch or zoom
            vec3 w = fwidth(p);
            vec3 d = abs(fract(p + 0.5) - 0.5);      // distance to the nearest plane
            // The axis a face does not vary along is that face's own normal, and
            // its distance is a constant zero -- take it at face value and every
            // face floods solid. Push those axes out of reach instead of dividing
            // by their zero.
            vec3 live = step(1e-4, w);
            vec3 px = d / max(w, vec3(1e-6)) + (1.0 - live) * 1e6;
            float near = min(min(px.x, px.y), px.z);
            // Fade out where a voxel is too small to hold a line. Survey zoom
            // draws a world pixel at about a display pixel, and a wall seen nearly
            // edge-on squashes one to nothing at any zoom -- either way the seams
            // land closer together than they are wide, and drawn anyway they stop
            // being a wireframe and become a flat 45% dimming of the whole scene.
            // The tightest axis decides, which is the honest test of whether the
            // grid can be resolved at all.
            float span = 1.0 / max(max(w.x, max(w.y, w.z)), 1e-6);
            float fade = clamp((span - 2.0) * 0.5, 0.0, 1.0);
            // the textbook antialiased line: solid within the half-width, fading
            // over the one pixel outside it
            return fade * clamp(gridWidth * 0.5 + 0.5 - near, 0.0, 1.0);
        }
    #endif

    uniform vec3 ghostColor;    // the flat silhouette colour
    uniform float ghost;        // 0 = shade normally, 1 = flatten to it
    uniform vec3 dayTint;       // the hour's light on the world; 1,1,1 = noon
    uniform vec3 fogColor;      // what the haze is made of (see Voxel3D.fog)
    uniform Image glassMask;    // opaque where the atlas texel is window glass
    uniform vec2 glassSize;     // the mask's dimensions: tc -> atlas texels
    uniform float glassNight;   // 0 = daylight .. 1 = the lamps are on
    uniform float glassPhase;   // the glint's phase: advances with TRAVEL
    uniform float glassGlint;   // and its strength: 0 while standing still
    uniform float glassOn;      // 0 for sprite-sheet draws (see Voxel3D.glass)

    vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
        vec4 p = Texel(tex, tc);
        // sprite sheets key GB OBJ color 0 to alpha 0; discarding rather than
        // blending keeps those texels out of the depth buffer, so a model never
        // carves a transparent hole out of whatever stands behind it
        if (p.a < 0.5) discard;

        // and the same for anything the diorama's viewport has faded out
        // entirely: past the rim there is no world, and a fully faded fragment
        // that still wrote depth would punch a hole in the sky behind it
    #ifdef VOXEL_CULL
        float cull = dioramaCull(vWorld);
        if (cull <= 0.0) discard;
    #else
        float cull = 1.0;
    #endif

        // the hour's tint multiplies like the sun terms do: it is LIGHT, the
        // same warm or moonlit cast on every surface, not a palette swap
        vec3 rgb = p.rgb * vShade * sunlight(vSun) * dayTint;

    #ifdef VOXEL_GRID
        // darken what is there rather than painting a colour, so a seam across
        // dark grass and one across a white roof each stay in their own palette
        rgb *= 1.0 - gridDark * voxelSeam(vGrid);
    #endif

        // WINDOW GLASS, marked per atlas texel by the mask (see GlassMask).
        // By day a thin diagonal glint crosses the panes WHILE THE VIEW MOVES
        // -- the phase is fed by the camera's own travel and the strength dies
        // within a beat of standing still, because a reflection is something
        // the viewpoint does: still camera, still glass. It lifts the texel
        // toward sky-white and leaves the art visible through it. After dark
        // the pane is LIT: the texel's own shine pattern carried into a warm
        // lamp colour, replacing the shaded answer above -- so a lit window
        // ignores the sun, every shadow and the hour's tint, exactly as a
        // window with a lamp behind it does.
        // glassOn gates the whole thing per DRAW: the mask is shaped like the
        // tileset atlas, and only meshes textured FROM that atlas may consult
        // it -- a character samples its own sprite sheet, whose coordinates
        // land on the mask's pane rectangles by accident and would stripe the
        // cast with lamplight at night.
        float glass = Texel(glassMask, tc).a * glassOn;
        if (glass > 0.0) {
            // the sweep lives in the PANE's own space (atlas texels), not the
            // screen's: a pattern anchored to the screen has the world sliding
            // through it at zoom speed whenever the camera pans, which strobed --
            // worst where the pan and the phase ran opposite ways. Anchored to
            // the glass, panning moves nothing; only the phase does, a fraction
            // of a texel per step, the same in every walking direction.
            float sweep = sin(tc.x * glassSize.x * 0.8 - glassPhase);
            float glint = pow(max(sweep, 0.0), 20.0) * 0.55 * glassGlint;
            vec3 pane = mix(rgb, vec3(0.93, 0.97, 1.0), glint * glass);
            float shine = dot(p.rgb, vec3(0.299, 0.587, 0.114));
            vec3 lamp = vec3(1.0, 0.84, 0.5) * (0.5 + 0.55 * shine);
            rgb = mix(pane, lamp, glassNight * glass);
        }

        // the haze stands between the eye and the SURFACE, so it lands after
        // every surface term -- sun, seams, glass -- and before only the
        // ghost, which must stay one solid readable shape whatever the
        // weather (see below)
        rgb = mix(rgb, fogColor, vFog);

        // The hidden player is a SHAPE, not a dimmed picture of itself. Tinting
        // through `color` could only multiply the sprite's own pixels, which
        // darkens each one by its own amount and keeps the character's internal
        // detail; replacing the colour outright is what makes it read as one
        // solid silhouette. Last in the chain, so neither the sun nor a voxel
        // seam can mottle it.
        rgb = mix(rgb, ghostColor, ghost);

        // Emissive but still coloured: increasingly visible as Lua raises the
        // night factor, without adding more insects or washing the scene white.
        rgb = mix(rgb, vec3(0.82, 1.00, 0.22), vFirefly);

        // the viewport's rim is an ALPHA, so the last of the model blends into
        // whatever the frame opened with -- the sky, or the chroma key. 1
        // everywhere without the cut compiled in, which is every flat frame.
        return vec4(rgb, cull) * color;
    }
#endif