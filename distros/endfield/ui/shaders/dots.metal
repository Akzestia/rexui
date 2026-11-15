// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
float4 shade(float2 p, constant Shader& u) {
    float cell = u.params[0] > 0 ? u.params[0] : 12.0;
    float r = u.params[1] > 0 ? u.params[1] : 0.9;
    float2 g = (fract(p / cell) - 0.5) * cell;
    float cover = rx_fill(length(g) - r, u);
    float y = p.y / u.size.y;
    float fade = 1.0;
    if (u.params[2] > 0)
        fade *= smoothstep(0.0, u.params[2], y);
    if (u.params[3] > 0)
        fade *= 1.0 - smoothstep(1.0 - u.params[3], 1.0, y);
    return float4(u.colors[0].rgb, u.colors[0].a * cover * fade);
}
