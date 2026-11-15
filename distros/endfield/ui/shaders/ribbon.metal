// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
float4 shade(float2 p, constant Shader& u) {
    int n = clamp(int(u.params[0] > 0 ? u.params[0] : 2), 1, 3);
    float ang = (u.params[1] != 0 ? u.params[1] : -22.0) * 0.01745329;
    float S = max(u.size.x, u.size.y);
    float2 dir = float2(cos(ang), sin(ang)), nrm = float2(-dir.y, dir.x);
    float2 q = p - u.size * float2(0.5, 0.65);
    float along = dot(q, dir), across = dot(q, nrm);
    float4 out = u.colors[2];
    for (int k = 0; k < n; k++) {
        float h1 = rx_hash(float2(k, 4.2)), h2 = rx_hash(float2(k, 9.1));
        float mid = (k - (n - 1) * 0.5) * S * 0.22 + S * 0.05 * sin(along / S * 3.0 + h1 * 6.0);
        float half_w = S * (0.07 + 0.05 * h2) * (0.6 + 0.4 * smoothstep(-0.6 * S, 0.5 * S, along));
        float d = abs(across - mid) - half_w;
        float fill = rx_fill(d, u);
        float fade = smoothstep(-0.55 * S, 0.25 * S, along) * (0.55 + 0.45 * (k == 0 ? 1.0 : 0.6));
        float edge = rx_stroke(d, 1.0, u);
        float2 e = float2(along + u.time * u.params[2], across) / (S * 0.16) + float2(h1 * 10.0, k * 3.0);
        float hgt = rx_fbm(e, 2) * 5.0;
        float etch = saturate(1.0 - abs(fract(hgt + 0.5) - 0.5) / max(fwidth(hgt), 1e-4)) * fill;
        out = rx_over(out, float4(u.colors[0].rgb, u.colors[0].a * fill * fade));
        out = rx_over(out, float4(u.colors[1].rgb, u.colors[1].a * (etch * 0.22 + edge * 0.8) * fade));
    }
    return out;
}
