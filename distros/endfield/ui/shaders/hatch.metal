// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
float4 shade(float2 p, constant Shader& u) {
    float ang = (u.params[0] != 0 ? u.params[0] : 45.0) * 0.01745329;
    float period = u.params[1] > 0 ? u.params[1] : 9.0;
    float duty = u.params[2] > 0 ? saturate(u.params[2]) : 0.33;
    float along = dot(p, float2(cos(ang), sin(ang))) + u.time * u.params[3];
    float f = along / period;
    float x = fract(f);
    float w = fwidth(f);
    float on = smoothstep(0.0, w, x) * (1.0 - smoothstep(duty - w, duty, x));
    float fade = 1.0;
    if (u.params[4] != 0 || u.params[5] != 0)
        fade = smoothstep(u.params[4], u.params[5], p.x / u.size.x);
    if (u.params[4] > u.params[5])
        fade = 1.0 - smoothstep(u.params[5], u.params[4], p.x / u.size.x);
    float4 c = rx_over(u.colors[1], float4(u.colors[0].rgb, u.colors[0].a * on));
    return float4(c.rgb, c.a * fade);
}
