// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
float4 shade(float2 p, constant Shader& u) {
    float2 uv = p / u.size;
    float mode = u.params[0];
    float period = u.params[2] > 0 ? u.params[2] : 1.8;
    float hov = max(u.hover, u.params[3]);
    float t = fract(u.time / period);
    float x = (uv.x + (1.0 - uv.y) * 0.45) - (t * 2.2 - 0.6);
    float band = exp(-x * x / 0.006) * 0.55 + exp(-x * x / 0.05) * 0.18;
    float sweep = band * hov * smoothstep(0.0, 0.08, t) * (1.0 - smoothstep(0.75, 0.95, t));
    if (mode > 0.5)
        return float4(u.colors[2].rgb, saturate(sweep) * u.colors[2].a);
    float h = u.params[1] > 0 ? u.params[1] : 0.75;
    float glow = pow(saturate(1.0 - (1.0 - uv.y) / h), 2.2);
    float side = 1.0 - pow(abs(uv.x - 0.5) * 2.0, 3.0) * 0.5;
    float3 c = mix(u.colors[1].rgb, u.colors[0].rgb, glow * side * 0.42);
    float hatch = rx_fill(abs(fract((p.x + p.y) / 6.0) - 0.5) * 6.0 - 0.5, u);
    c += u.colors[0].rgb * hatch * 0.05 * (0.4 + glow);
    float scan = 0.5 + 0.5 * sin(p.y * 3.14159 / 1.5);
    c *= 0.97 + 0.03 * scan;
    c += u.colors[0].rgb * hov * 0.08 * glow;
    return float4(c, 1.0);
}
