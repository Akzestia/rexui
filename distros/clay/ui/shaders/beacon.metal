// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
float4 shade(float2 p, constant Shader& u) {
    float r = u.params[0] > 0 ? u.params[0] : 12.0;
    float w = u.params[1] > 0 ? u.params[1] : 2.0;
    float laps = u.params[2] != 0 ? u.params[2] : 0.3;
    float4 base = u.colors[0].a > 0 ? u.colors[0] : float4(0.851, 0.467, 0.341, 1.0);
    float4 head = u.colors[1].a > 0 ? u.colors[1] : base;
    float2 half_ = u.size * 0.5;
    float2 q = p - half_;
    float d = rx_box(q, half_ - w * 0.5, r);
    float t = u.time;
    float breath = 0.72 + 0.28 * sin(t * 3.4);
    float ang = atan2(q.y / half_.y, q.x / half_.x);
    float at = fract(t * laps) * 6.2831853 - 3.14159265;
    float da = fmod(ang - at + 9.42477796, 6.2831853) - 3.14159265;
    float run = da < 0 ? exp(da * 1.5) : exp(-da * 14.0);
    float edge = rx_stroke(d, w, u);
    float inner = d < 0 ? exp(d / 26.0) : 0.0;
    float bloom = d < 0 ? exp(d / 7.0) : 0.0;
    float a = edge * (0.8 * breath + 0.6 * run) + inner * (0.26 * breath + 0.3 * run) + bloom * run * 0.55;
    float3 rgb = mix(base.rgb, head.rgb, saturate(run * (edge + bloom)));
    return float4(rgb, saturate(a) * base.a);
}
