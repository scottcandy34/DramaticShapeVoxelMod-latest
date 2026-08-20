uniform vec2 tap;        // half a SOURCE texel, in uv

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 a = Texel(tex, tc + vec2(-tap.x, -tap.y));
    vec4 b = Texel(tex, tc + vec2( tap.x, -tap.y));
    vec4 c = Texel(tex, tc + vec2(-tap.x,  tap.y));
    vec4 d = Texel(tex, tc + vec2( tap.x,  tap.y));

    float al = (a.a + b.a + c.a + d.a) * 0.25;
    if (al <= 0.0) return vec4(0.0);

    vec3 sum = a.rgb * a.a + b.rgb * b.a + c.rgb * c.a + d.rgb * d.a;
    return vec4(sum * 0.25 / al, al) * color;
}