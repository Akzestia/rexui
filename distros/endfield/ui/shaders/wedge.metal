// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
float tri_inside(float2 p, float2 s) {
    float2 nl = normalize(float2(s.y, -s.x * 0.5));
    float2 nr = normalize(float2(-s.y, -s.x * 0.5));
    return min(p.y, min(dot(p, nl), dot(p - float2(s.x, 0.0), nr)));
}

float4 shade(float2 p, constant Shader& u) {
    float2 s = u.size;
    float heat = smoothstep(0.0, 1.0, saturate(u.params[0]));
    float open = smoothstep(0.0, 1.0, saturate(u.params[1]));
    float2 o = float2(u.params[2], u.params[3]) * s;
    float march = u.params[4];
    float t = u.time;

    float inside = tri_inside(p, s);
    float reach = max(max(length(o), length(o - float2(s.x, 0.0))), length(o - float2(s.x * 0.5, s.y)));
    float r = length(p - o);

    float4 glass = u.colors[0];
    float scan = step(fract(p.y / 3.0), 1.0 / 3.0);
    glass = rx_over(glass, float4(u.colors[2].rgb, u.colors[2].a * 0.06 * scan));
    glass = rx_over(glass, float4(u.colors[2].rgb, u.colors[2].a * 0.35 * exp(-max(inside, 0.0) / 4.0)));

    float soft = 12.0;
    float at = r - (open * (reach + 2.0 * soft) - soft);
    float shown = smoothstep(soft * 0.5, -soft * 0.5, at);
    float4 c = float4(glass.rgb, glass.a * shown);
    c = rx_over(c, float4(u.colors[1].rgb, u.colors[1].a * 0.18 * exp(-pow(at / soft, 2.0)) * (1.0 - open)));

    float past = r - (heat * (reach + 2.0 * soft) - soft);
    float flood = smoothstep(soft * 0.5, -soft * 0.5, past) * step(0.001, heat);
    float glow = 0.22 * exp(-pow(past / soft, 2.0)) * step(0.001, heat) * (1.0 - heat);
    float4 sig = u.colors[1];
    float h = (p.x + p.y + t * march) / 6.0;
    float w = fwidth(h);
    float on = smoothstep(0.0, w, fract(h)) * (1.0 - smoothstep(0.32 - w, 0.32, fract(h)));
    sig = rx_over(sig, float4(u.colors[3].rgb, u.colors[3].a * on));
    c = rx_over(c, float4(u.colors[1].rgb, u.colors[1].a * glow * shown));
    c = rx_over(c, float4(sig.rgb, sig.a * flood * shown));
    return c;
}
