// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
float4 shade(float2 p, constant Shader& u) {
    int lanes = clamp(int(u.params[12] > 0 ? u.params[12] : 8), 1, 12);
    float speed = u.params[13] != 0 ? u.params[13] : 36.0;
    float lh = u.params[14] > 0 ? u.params[14] : u.size.y / lanes;
    int i = int(floor(p.y / lh));
    if (i < 0 || i >= lanes)
        return float4(0);
    float load = saturate(u.params[i]);
    float2 c = float2(u.size.x * 0.5, (i + 0.5) * lh);
    float bh = lh * 0.30;
    float2 hb = float2(u.size.x * 0.5 - 4.0, bh);
    float d = rx_box(p - c, hb, 2.0);
    float4 out = float4(0);
    float glow = exp(-max(d, 0.0) / 3.0) * (d > 0 ? 1.0 : 0.0);
    out = rx_over(out, float4(u.colors[1].rgb, u.colors[1].a * glow * 0.7));
    float inside = rx_fill(d, u);
    float x = p.x + u.time * speed * -1.0;
    x = p.x - u.time * speed;
    float tread = step(fract(x / 7.0), 0.12) * inside * 0.10;
    out = rx_over(out, float4(u.colors[0].rgb, u.colors[0].a * (inside * 0.06 + tread)));
    out = rx_over(out, float4(u.colors[0].rgb, u.colors[0].a * rx_stroke(d, 1.0, u)));
    float side = bh * 1.25;
    float pitch = side * 2.4;
    float slot = floor(x / pitch);
    float filled = step(rx_hash(float2(slot, i * 7.0 + 1.3)), load);
    float2 lc = float2((fract(x / pitch) - 0.5) * pitch, p.y - c.y);
    float cube = rx_fill(rx_box(lc, float2(side * 0.5), 1.0), u) * filled;
    out = rx_over(out, float4(u.colors[2].rgb, u.colors[2].a * cube * inside));
    out = rx_over(
        out,
        float4(u.colors[0].rgb,
               u.colors[0].a * 0.6 * rx_stroke(rx_box(lc, float2(side * 0.5), 1.0), 0.75, u) * filled * inside));
    float4 chev = u.colors[3].a > 0 ? u.colors[3] : u.colors[0];
    float cx = u.size.x - 4.0 - bh * 3.2;
    for (int k = 0; k < 2; k++) {
        float2 a = p - float2(cx + k * bh * 1.1, c.y);
        float dc = min(rx_segment(a, float2(-bh * 0.4, -bh * 0.6), float2(bh * 0.25, 0)),
                       rx_segment(a, float2(-bh * 0.4, bh * 0.6), float2(bh * 0.25, 0)));
        float beat = 0.45 + 0.55 * step(fract(u.time * 0.8 - k * 0.25), 0.5);
        out = rx_over(out, float4(chev.rgb, chev.a * rx_stroke(dc, 1.3, u) * beat));
    }
    return out;
}
