// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
float4 shade(float2 p, constant Shader& u) {
    float lines = u.params[0] > 0 ? u.params[0] : 16.0;
    float hill = u.params[1] > 0 ? u.params[1] : 220.0;
    float speed = u.params[2] != 0 ? u.params[2] : 0.015;
    float width = (u.params[3] > 0 ? u.params[3] : 0.75) * u.scale;
    float t = u.time * speed;
    float2 q = p / hill + u.seed * 13.0;
    float2 warp = float2(rx_fbm(q + float2(3.1, t), 2), rx_fbm(q + float2(7.3, -t), 2)) - 0.5;
    float h = rx_fbm(q + 0.8 * warp + float2(t * 0.6, -t * 0.4), 3);
    float f = h * lines;
    float d = abs(fract(f + 0.5) - 0.5) / max(fwidth(f), 1e-4);
    bool major = fmod(floor(f + 0.5) + 400.0, 5.0) < 0.5;
    float w = width * (major ? 1.7 : 1.0);
    float line = saturate(w * 0.5 + 0.5 - d);
    float near = u.hover * exp(-dot(p - u.mouse, p - u.mouse) / (2.0 * 110.0 * 110.0));
    float4 c = mix(u.colors[0], float4(u.colors[1].rgb, max(u.colors[1].a, u.colors[0].a)), near);
    float mask = 1.0;
    if (u.params[4] > 0) {
        float reach = u.params[4];
        float a = length(p) / reach, b = length(u.size - p) / reach;
        mask = max(1.0 - smoothstep(0.35, 1.0, a), 1.0 - smoothstep(0.35, 1.0, b));
    }
    float fade = mix(1.0, 1.0 - smoothstep(0.0, 1.0, p.y / u.size.y), saturate(u.params[5]));
    return float4(c.rgb, c.a * line * (major ? 1.0 : 0.55) * fade * mask);
}
