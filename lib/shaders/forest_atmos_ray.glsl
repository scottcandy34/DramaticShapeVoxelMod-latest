varying vec3 vRay;

#ifdef VERTEX
    attribute vec3 RayDir;

    vec4 position(mat4 transform_projection, vec4 vertex_position) {
        vRay = RayDir;
        return transform_projection * vertex_position;
    }
#endif

#ifdef PIXEL
    uniform Image depthTex;    // the frame's own depth, detached to read
    uniform Image sunMap;      // the sun's answer (see ShadowMap)
    uniform Image leafTex;     // the unseen foliage, tiling
    uniform mat4 vp;
    uniform mat4 sunVP;
    uniform float sunBias;
    uniform vec3 eye;
    uniform vec3 curve;        // xy = the focus in world XZ, z = k; 0 = off
    uniform vec2 screen;       // canvas size, for the pixel's own uv
    uniform vec4 fogW;         // density, heightK, canopyY, fadeTo
    uniform vec3 shear;        // the noon shear kx, kz; z = reach
    uniform vec3 rayColor;
    uniform float strength;
    uniform vec3 sunward;      // unit, toward the unseen sun
    uniform vec2 wind;         // leaf-field drift, uv per second
    uniform float time;

    // the viewport, as the scene shader takes it (see Voxel3D): air outside
    // the model is not air, so a sample out there contributes nothing and
    // the beams end with the world they fall through
    uniform vec3 cullAt;
    uniform vec3 cullShape;
    uniform vec2 cullRect;     // the box's half-extents in x and z

    float dioramaCull(vec3 p) {
        if (cullShape.z <= 0.5) return 1.0;
        vec3 cd = p - cullAt;
        float inside;
        if (cullShape.z < 1.5) {                 // the box
            inside = min(cullRect.x - abs(cd.x), cullRect.y - abs(cd.z));
        } else if (cullShape.z < 2.5) {
            inside = cullShape.x - length(cd);     // the ball
        } else {
            inside = cullShape.x - length(cd.xz);  // the fight's pillar
        }
        return clamp(inside * cullShape.y, 0.0, 1.0);
    }

    float sunDepth(vec2 uv) {
        vec4 c = Texel(sunMap, uv);
        return c.r + c.g * (1.0 / 255.0);
    }

    vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
        vec2 uv = sc / screen;
        float sceneD = Texel(depthTex, uv).r;
        vec3 dir = normalize(vRay);

        // Spend every sample where a sample can glow. Above the canopy no
        // beam exists, and below the floor there is no air at all -- so the
        // march runs from where this ray first dips under the leaves to
        // where it would pass the ground, however long or short that
        // stretch is. From the orbit camera that is the last few dozen
        // pixels of a mostly-vertical ray, and dividing the WHOLE reach by
        // the step count there starved the beams to nothing.
        float t0 = 0.0;
        if (eye.y > fogW.z) {
            if (dir.y >= -0.01) return vec4(0.0);
            t0 = (eye.y - fogW.z) / -dir.y;
        }
        float tEnd = shear.z;
        if (dir.y < -0.01) {
            tEnd = min(tEnd, (eye.y + 8.0) / -dir.y);
        }
        if (tEnd <= t0) return vec4(0.0);

        // interleaved gradient noise staggers neighbouring pixels' steps,
        // which is what turns 20-odd samples into a smooth volume instead
        // of an onion of banded slices
        float jitter = fract(52.9829189
                            * fract(dot(sc, vec2(0.06711056, 0.00583715))));
        float dt = (tEnd - t0) / float(STEPS);

        // HALF the fog's own extinction, on the way in and per step: the
        // full rate is what the surfaces sink by, and beams that obeyed it
        // too died before the orbit camera ever saw them. Half keeps the
        // depth cue and leaves the light alive.
        float trans = exp(-fogW.x * 0.5 * t0);
        float acc = 0.0;

        for (int i = 0; i < STEPS; i++) {
            float t = t0 + (float(i) + jitter) * dt;
            vec3 p = eye + dir * t;

            // stop at the surface: bend the sample the way the geometry bent
            vec2 cd = p.xz - curve.xy;
            vec4 c = vp * vec4(p.x, p.y - dot(cd, cd) * curve.z, p.z, 1.0);
            if (c.w <= 1e-6) break;
            if (c.z / c.w * 0.5 + 0.5 > sceneD) break;

            if (p.y < fogW.z) {
                // the sun's question: is this air behind a tree? Outside the
                // frustum nothing was recorded and the air counts as lit, eased
                // at the rim exactly like the scene shader's shadows
                float lit = 1.0;
                vec3 su = (sunVP * vec4(p, 1.0)).xyz;
                if (su.x > 0.0 && su.x < 1.0 && su.y > 0.0 && su.y < 1.0
                    && su.z < 1.0) {
                    vec2 e2 = min(su.xy, 1.0 - su.xy);
                    float edge = smoothstep(0.0, 0.06, min(e2.x, e2.y));
                    lit = mix(1.0, step(su.z - sunBias, sunDepth(su.xy)), edge);
                }

                // the canopy's question: where did this thread of light pierce
                // the leaves? Every step of air on one sun ray shares the
                // answer -- that shared point is what makes a shaft a shaft --
                // and the two drifting reads of the field are the wind moving
                // the foliage overhead, opening and closing the beams
                float up = fogW.z - p.y;
                vec2 gap = (p.xz - shear.xy * up) * (1.0 / 96.0);
                float n = Texel(leafTex, gap + wind * time).r * 0.65
                        + Texel(leafTex, gap * 2.3 - wind * (time * 0.7)
                                + vec2(0.37, 0.61)).r * 0.35;
                float dapple = 0.08 + 0.92 * smoothstep(0.45, 0.85, n);

                // the beam fades IN below the invisible canopy, thins with
                // altitude like the haze it is made of, and kisses the floor
                float y = max(p.y, 0.0);
                float fadeIn = clamp(up / max(fogW.z - fogW.w, 1.0), 0.0, 1.0);
                float foot = 0.55 + 0.45 * clamp(y / 16.0, 0.0, 1.0);
                float dens = fogW.x * exp(-y * fogW.y);
                acc += trans * lit * dapple * fadeIn * foot * dens * dt
                    * dioramaCull(p);
            }
            trans *= exp(-fogW.x * 0.5 * dt);
        }

        // forward scattering: beams bloom for a camera looking up into the
        // light, which is most of what makes them read as light IN air
        float phase = 0.35 + 0.65 * pow(max(dot(dir, sunward), 0.0), 6.0);
        return vec4(rayColor * (acc * strength * phase), 1.0) * color;
    }
#endif