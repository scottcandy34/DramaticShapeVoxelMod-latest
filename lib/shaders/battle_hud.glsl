uniform vec2 dir;

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 sum = Texel(tex, tc) * 0.2270270270;
    sum += (Texel(tex, tc + dir) + Texel(tex, tc - dir)) * 0.1945945946;
    sum += (Texel(tex, tc + 2.0 * dir) + Texel(tex, tc - 2.0 * dir)) * 0.1216216216;
    sum += (Texel(tex, tc + 3.0 * dir) + Texel(tex, tc - 3.0 * dir)) * 0.0540540541;
    sum += (Texel(tex, tc + 4.0 * dir) + Texel(tex, tc - 4.0 * dir)) * 0.0162162162;
    return sum * color;
}