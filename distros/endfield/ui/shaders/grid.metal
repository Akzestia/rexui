// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
float gridline(float v, float cell, float px) {
    float d = abs(fract(v / cell + 0.5) - 0.5) * cell;
    return saturate(1.0 - d * px);
}

float4 shade(float2 p, constant Shader& u) {
    float cell = u.params[0] > 0 ? u.params[0] : 16.0;
    float every = u.params[1] > 0 ? floor(u.params[1]) : 5.0;
    float arm = u.params[2] == 0 ? 5.0 : u.params[2];
    float px = u.scale;
    float2 o = p + 0.5 / px;
    float minor = max(gridline(o.x, cell, px), gridline(o.y, cell, px));
    float big = cell * every;
    float major = max(gridline(o.x, big, px), gridline(o.y, big, px));
    float4 c = float4(u.colors[0].rgb, u.colors[0].a * minor);
    c = rx_over(c, float4(u.colors[1].rgb, u.colors[1].a * major));
    if (arm > 0) {
        float2 k = (fract(o / big + 0.5) - 0.5) * big;
        float plus = max(step(abs(k.x), arm) * saturate(1.5 - abs(k.y) * px),
                         step(abs(k.y), arm) * saturate(1.5 - abs(k.x) * px));
        c = rx_over(c, float4(u.colors[2].rgb, u.colors[2].a * plus));
    }
    if (u.params[3] > 0) {
        float at = fract(u.time / u.params[3]) * (u.size.y + 160.0) - 80.0;
        float band = exp(-pow((p.y - at) / 36.0, 2.0));
        float4 s = u.colors[3].a > 0 ? u.colors[3] : u.colors[1];
        c = rx_over(c, float4(s.rgb, s.a * band * max(minor, major * 1.5)));
    }
    return c;
}
