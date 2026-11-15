// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
float4 shade(float2 p, constant Shader& u) {
    float day = fract(u.params[0]);
    float cell = u.params[1] > 0 ? u.params[1] : 6.0;
    float hy = u.size.y * (u.params[2] > 0 ? u.params[2] : 0.8);
    float th = (day - 0.25) * 6.2831853;
    bool sun = sin(th) >= 0.0;
    float a = sun ? th : th - 3.14159265;
    float2 arc = float2(u.size.x * 0.40, hy * 0.78);
    float2 body = float2(u.size.x * 0.5 - arc.x * cos(a), hy - arc.y * sin(a));
    float rb = min(u.size.x, u.size.y) * 0.13;

    float2x2 turn = rx_rotate(0.785398), back = rx_rotate(-0.785398);
    float2 g = turn * p / cell;
    float2 centre = back * ((floor(g) + 0.5) * cell);
    float2 rel = centre - body;
    float disc = smoothstep(rb + 1.0, rb - 1.0, length(rel));
    if (!sun)
        disc *= smoothstep(rb * 0.92 - 1.0, rb * 0.92 + 1.0, length(rel - float2(rb * 0.45, -rb * 0.25)));
    float glow = exp(-max(0.0, length(rel) - rb) / (rb * (sun ? 1.1 : 0.6))) * (sun ? 0.55 : 0.30);
    float sky = sun ? 0.12 * pow(saturate(centre.y / hy), 2.0) : 0.0;
    float L = saturate(disc + glow + sky);
    L *= smoothstep(hy + cell * 0.5, hy - cell * 0.5, centre.y);
    float r = cell * 0.5 * sqrt(L) * 1.05;
    float spot = rx_fill(length(back * ((fract(g) - 0.5) * cell)) - r, u) * smoothstep(0.0, 0.04, L);
    float4 ink = sun ? u.colors[0] : u.colors[1];
    float4 c = float4(ink.rgb, ink.a * spot);
    float line = rx_stroke(p.y - hy, 1.0, u) * u.colors[2].a;
    return rx_over(c, float4(u.colors[2].rgb, line));
}
