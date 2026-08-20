uniform vec2 dir;        // one texel step along the axis being blurred
uniform float focusY;
uniform float band;
uniform float range;
uniform float spacing;   // gap between taps at full blur, in texels
uniform float boost;     // 0 = plain blur pass, 1 = final pass (color pop)
uniform float saturation;

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    float d = abs(tc.y - focusY) - band;
    float s = clamp(d / range, 0.0, 1.0);
    s = s * s;             // ease in, so the band edge has no visible seam

    // 9 taps a small step apart: dense enough that even the strongest
    // preset blurs smoothly instead of ghosting into streaks
    vec2 o = dir * (s * spacing);

    vec4 sum = Texel(tex, tc) * 0.2270270270;
    sum += (Texel(tex, tc + o) + Texel(tex, tc - o)) * 0.1945945946;
    sum += (Texel(tex, tc + 2.0 * o) + Texel(tex, tc - 2.0 * o)) * 0.1216216216;
    sum += (Texel(tex, tc + 3.0 * o) + Texel(tex, tc - 3.0 * o)) * 0.0540540541;
    sum += (Texel(tex, tc + 4.0 * o) + Texel(tex, tc - 4.0 * o)) * 0.0162162162;

    if (boost > 0.5) {
        float luma = dot(sum.rgb, vec3(0.299, 0.587, 0.114));
        sum.rgb = mix(vec3(luma), sum.rgb, saturation);
    }

    return sum * color;
}