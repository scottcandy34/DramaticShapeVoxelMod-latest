uniform Image ramp;     // the bands, one texel each, top of the sky first
uniform float count;    // how many texels wide that ramp is
uniform float edge;     // the sky's bottom, in canvas pixels
uniform float top;      // where the deepest band begins, in canvas pixels --
                        // 0 glues the gradient to the frame (the flat
                        // screen); an anchored caller passes the row its
                        // fixed elevation span starts on, often negative
uniform float cell;     // the diorama's pixel size, in canvas pixels
uniform float start;    // where the checker begins inside a band
uniform float axisX;    // the "toward the ground" direction on the canvas:
uniform float axisY;    // (0,1) for a level camera; a rolled VR eye tips
                        // it, and edge/top are distances along it
uniform vec3 rayBase;   // the eye's ray fan (VRRig eyeCamera.skyRay): a
uniform vec3 rayDu;     // canvas point at fractions (u, v) looks along
uniform vec3 rayDv;     // base + u*du + v*dv, world axes -- so each pixel
                        // knows its TRUE elevation and the gradient is a
                        // real skybox, untouched by any head motion
uniform float raySpan;  // radians of elevation the gradient covers
uniform vec2 invSize;   // 1/w, 1/h: canvas pixels to fractions
uniform float useRay;   // 0 = the flat screen's frame-linear gradient
uniform float cellAng;  // one checker cell in RADIANS (ray path): the
                        // dither's own grid, laid on azimuth/elevation so
                        // the pattern is glued to the SKY -- a screen-cell
                        // parity flips under every head motion and the
                        // whole gradient shimmers
uniform float alpha;
uniform float glowAmt;  // twilight warmth around the low sun; 0 = none
uniform vec2 glowPos;   // the sun disc, in canvas pixels (flat path)
uniform float glowInvR; // 1 / the glow's reach in pixels (flat path)
uniform vec3 glowDir;   // the sun's world direction (ray path)
uniform float glowInvA; // 1 / the glow's reach in radians (ray path)
uniform vec3 glowColor;

// Band `i`, read from its own texel centre. The index is clamped rather than
// trusted: `pos` below can land exactly on `count` when the arithmetic is
// carried at mediump -- which is the fragment default on GLSL ES -- and a
// sample past the last band must be the last band, not whatever is off the
// end of the image.
vec3 bandAt(float i) {
    return Texel(ramp, vec2((clamp(i, 0.0, count - 1.0) + 0.5) / count, 0.5)).rgb;
}

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    float tn;
    float parity;
    float glowD = 2.0;                                  // past the reach

    if (useRay > 0.5) {
        // A SKYBOX, computed instead of stored: the pixel's own ray lands in
        // a cell of the sky's angular grid (azimuth columns and elevation
        // rows, cellAng square), and EVERYTHING -- the band, the checker's
        // parity, the glow -- is answered from that cell's centre. The
        // screen grid quantises nothing here; that is the point. A screen
        // quantisation of similar pitch laid under the sky grid beats
        // against it (moire), and every subpixel head motion re-snaps the
        // beat -- the fizz. Sampled per pixel, the picture is exactly a
        // nearest-filtered texture on a dome: its cells slide smoothly with
        // the world and no motion of the head recomputes the pattern. The
        // one seam, where azimuth wraps behind the camera, is a single cell
        // column of a dither pattern.
        vec3 dir = rayBase + rayDu * (sc.x * invSize.x)
                           + rayDv * (sc.y * invSize.y);
        float elev = atan(dir.y, length(dir.xz));
        float ei = floor(elev / cellAng);                 // elevation row
        if (ei < 0.0) { discard; }                        // below the horizon
        float ai = floor(atan(dir.x, dir.z) / cellAng);   // azimuth column
        float elc = (ei + 0.5) * cellAng;                 // the row's centre
        tn = 1.0 - clamp(elc / max(raySpan, 0.001), 0.0, 1.0);
        parity = mod(ai + ei, 2.0);
        if (glowAmt > 0.0) {
            // the glow by the angle between the CELL's centre direction and
            // the sun's own, so its rings are pinned to the same sky grid
            float azc = (ai + 0.5) * cellAng;
            vec3 cd = vec3(cos(elc) * sin(azc), sin(elc), cos(elc) * cos(azc));
            glowD = acos(clamp(dot(cd, glowDir), -1.0, 1.0)) * glowInvA;
        }
    } else {
        vec2 cc0 = floor(sc / cell) * cell;               // top of this cell
        float row = cc0.x * axisX + cc0.y * axisY;        // along the axis
        if (row > edge) { discard; }                      // below the horizon
        tn = clamp((row - top) / max(edge - top, 1.0), 0.0, 1.0);
        parity = mod(floor(sc.x / cell) + floor(sc.y / cell), 2.0);
        if (glowAmt > 0.0) {
            vec2 cc = (floor(sc / cell) + 0.5) * cell;
            glowD = length(cc - glowPos) * glowInvR;
        }
    }

    float pos = tn * count;
    float base = min(floor(pos), count - 1.0);
    vec3 c = bandAt(base);
    if (base < count - 1.0 && (pos - base) > start) {
        if (parity < 0.5) { c = bandAt(base + 1.0); }
    }

    // The sunset's warmth, radiating from the disc: posterised to a few rungs
    // and checker-dithered between them -- the same 8-bit move as the bands,
    // so the glow reads as painted light rather than as a smooth airbrush --
    // measured cell-to-cell on the flat frame and angle-to-angle on the
    // skybox, so its rings ride whichever grid the checker itself is on.
    if (glowAmt > 0.0) {
        float g = glowAmt * pow(clamp(1.0 - glowD, 0.0, 1.0), 2.0);
        float lvl = floor(g * 4.0);
        if (g * 4.0 - lvl > 0.5 && parity < 0.5) { lvl += 1.0; }
        c = mix(c, glowColor, min(lvl / 3.0, 1.0) * 0.65);
    }

    return vec4(c, alpha);
}