varying float vDepth;

#ifdef VERTEX
        uniform mat4 lightVP;
        uniform mat4 model;

        vec4 position(mat4 transform_projection, vec4 vertex_position) {
            vec4 c = lightVP * (model * vertex_position);
            // the projection is orthographic, so w is 1 and clip z IS the depth,
            // linear in world units along the sun line
            vDepth = c.z * 0.5 + 0.5;
            return c;
        }
#endif

#ifdef PIXEL
    uniform float sprite;   // 1 while the CAST is being drawn; see ShadowMap.sprites

    vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
        // the same alpha discard the main pass uses: a sprite card casts its
        // silhouette, not its 16x16 bounding box
        if (Texel(tex, tc).a < 0.5) discard;

        // pack into two channels: the high byte in red, the low in green.
        // Blue says WHAT cast this, which costs a channel that was zero anyway
        // and lets a surface decline one kind of caster -- water does, for the
        // people (see Water's sunLit).
        float d = clamp(vDepth, 0.0, 1.0) * 255.0;
        return vec4(floor(d) / 255.0, fract(d), sprite, 1.0);
    }
#endif