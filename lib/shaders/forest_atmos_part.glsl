varying vec2 vCorner;
varying float vGlow;

#ifdef VERTEX
    uniform mat4 vp;
    uniform vec3 curve;
    uniform vec3 cullAt;     // the viewport (see Voxel3D.cull): a mote
    uniform vec3 cullShape;  // outside the model is not in the air
    uniform vec2 cullRect;   // the box's half-extents in x and z
    uniform vec3 axisR;      // the camera's right, world space
    uniform vec3 axisU;      // and its up: the billboard's own frame
    uniform float time;
    uniform float size;
    uniform vec2 sway;       // wander amplitude: horizontal, vertical
    uniform float blinky;    // 0 = steady motes, 1 = blinking fireflies
    attribute vec4 AtmosData;    // corner x, corner y, phase, rate

    vec4 position(mat4 transform_projection, vec4 vertex_position) {
        float ph = AtmosData.z;
        float rt = AtmosData.w;
        float t = time * (0.5 + rt);

        // bounded wander only -- three incommensurate sines, so nothing ever
        // walks off the map or needs a CPU tick to bring it home
        vec3 base = vertex_position.xyz + vec3(
            sin(t * 0.23 + ph) * sway.x,
            sin(t * 0.17 + ph * 2.7) * sway.y,
            cos(t * 0.19 + ph * 1.3) * sway.x);

        float s = 0.5 + 0.5 * sin(t * 1.6 + ph * 9.0);
        vGlow = mix(1.0, smoothstep(0.35, 0.75, s), blinky);

        // a whole mote at once: these are points, so the rim can dim them
        // rather than having to cut one in half
        if (cullShape.z > 0.5) {
            vec3 cd = base - cullAt;
            float inside;
            if (cullShape.z < 1.5) {
                inside = min(cullRect.x - abs(cd.x), cullRect.y - abs(cd.z));
            } else if (cullShape.z < 2.5) {
                inside = cullShape.x - length(cd);
            } else {
                inside = cullShape.x - length(cd.xz);
            }
            vGlow *= clamp(inside * cullShape.y, 0.0, 1.0);
        }

        vCorner = AtmosData.xy;
        vec4 w = vec4(base + axisR * (AtmosData.x * size)
                        + axisU * (AtmosData.y * size), 1.0);

        if (curve.z > 0.0) {
            vec2 cd = w.xz - curve.xy;
            w.y -= dot(cd, cd) * curve.z;
        }

        return vp * w;
    }
#endif

#ifdef PIXEL
    uniform vec3 dotColor;
    uniform float level;

    vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
        float d = dot(vCorner, vCorner);
        float glow = max(0.0, 1.0 - d);
        glow *= glow;
        return vec4(dotColor, glow * level * vGlow) * color;
    }
#endif