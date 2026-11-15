// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
float hexagon(float2 p, float r) {
    const float3 k = float3(-0.866025404, 0.5, 0.577350269);
    p = abs(p.yx);
    p -= 2.0 * min(dot(k.xy, p), 0.0) * k.xy;
    p -= float2(clamp(p.x, -k.z * r, k.z * r), r);
    return length(p) * sign(p.y);
}

float4 shade(float2 p, constant Shader& u) {
    float S = min(u.size.x, u.size.y);
    float2 q = p - u.size * 0.5;
    float notch = (u.params[0] > 0 ? u.params[0] : 0.07) * S;
    float bands = u.params[1] > 0 ? u.params[1] : 6.0;
    float glowAmt = u.params[2] > 0 ? u.params[2] : 0.6;
    float R = S * 0.415, tip = R / 0.866025404;
    float d = hexagon(q, R);
    d = max(d, -(q.y + tip - notch));
    float4 out = u.colors[2];
    out = rx_over(out, float4(u.colors[1].rgb, u.colors[1].a * glowAmt * exp(-max(d, 0.0) / 5.0) * step(0.0, d) * 0.6));
    float body = rx_fill(d, u);
    float brushed = 0.86 + 0.14 * rx_noise(float2(q.x * 0.05, q.y * 2.2));
    float light = 0.92 + 0.12 * (-q.y / R);
    float3 metal = u.colors[0].rgb * brushed * light;
    float2 m = (u.mouse - u.size * 0.5) / S;
    float h = dot(q / S, normalize(float2(0.8, -0.6))) * bands + (m.x * 1.4 + m.y * 0.8) * u.hover;
    float3 hue = mix(float3(1.0), 0.5 + 0.5 * cos(6.2831853 * (h + float3(0.0, 0.33, 0.67))), 0.55);
    float holo = (0.05 + 0.22 * u.hover) * smoothstep(0.3, 0.95, 0.5 + 0.5 * sin(h * 6.2831853 * 0.5));
    metal = mix(metal, hue, holo);
    out = rx_over(out, float4(metal, u.colors[0].a * body));
    out = rx_over(out, float4(u.colors[1].rgb, u.colors[1].a * rx_stroke(d + S * 0.06, 1.25, u)));
    out = rx_over(out, float4(metal * 0.7, u.colors[0].a * rx_stroke(d + 0.5, 1.0, u)));
    return out;
}
