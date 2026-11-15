// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
float4 shade(float2 p, constant Shader& u) {
    float3 base = u.colors[0].rgb;
    float light = u.params[0], grain = u.params[1], vignette = u.params[2];
    bool dark = dot(base, float3(0.299, 0.587, 0.114)) < 0.5;
    float2 uv = p / u.size;

    float tooth = rx_hash(floor(p * u.scale) + u.seed * 97.0) - 0.5;
    float clouds = rx_fbm(p / 90.0 + u.seed * 11.0, 4) - 0.5;
    float a = u.seed * 6.2831853;
    float fibres = smoothstep(0.78, 0.92, rx_gnoise(rx_rotate(a) * p * float2(0.045, 0.55)))
        + smoothstep(0.80, 0.93, rx_gnoise(rx_rotate(a + 1.9) * p * float2(0.05, 0.6) + 31.0));
    float3 c = base + (tooth * 0.030 + clouds * (dark ? 0.035 : 0.045)) * grain;
    c += (dark ? 0.014 : -0.016) * fibres * grain;

    float t = u.time * u.params[3];
    float2 at = u.size * float2(0.30 + 0.25 * sin(t * 0.21), 0.10 + 0.20 * cos(t * 0.17));
    float reach = max(u.size.x, u.size.y) * 0.55;
    float glow = exp(-dot(p - at, p - at) / (reach * reach));
    c = mix(c, u.colors[1].rgb, light * glow * u.colors[1].a);

    float2 v = (uv - 0.5) * float2(1.0, u.size.y / max(u.size.x, 1.0) + 0.5);
    c *= 1.0 - vignette * smoothstep(0.15, 0.85, length(v) * 1.3) * (dark ? 0.5 : 0.12);
    return float4(c, u.colors[0].a);
}
