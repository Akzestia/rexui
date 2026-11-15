// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
float4 shade(float2 p, constant Shader& u) {
    float R = min(u.size.x, u.size.y) * 0.5 - 2.0;
    float2 c = u.size * 0.5, q = p - c;
    float t = u.time * (u.params[1] != 0 ? u.params[1] : 1.0);
    float level = saturate(u.params[0]);
    float calm = 4.0 * level * (1.0 - level);
    float surface = c.y + R - level * 2.0 * R
        + calm
            * (3.2 * sin(q.x * 0.035 + t * 1.3) + 1.6 * sin(q.x * 0.083 - t * 2.1) + 0.8 * sin(q.x * 0.17 + t * 3.3));
    float glass = length(q) - R;
    float inside = rx_fill(glass, u);
    float wet = rx_fill(surface - p.y, u);

    float2 s = q / R;
    float2 w = float2(rx_fbm(s * 1.4 + float2(t * 0.06, 0.0), 4), rx_fbm(s * 1.4 + float2(5.2, -t * 0.05), 4)) - 0.5;
    float band = sin((s.y * 2.6 + s.x * 1.1) * 3.14159 + 5.0 * (w.x + w.y) + t * 0.22);
    float3 ink = mix(u.colors[0].rgb, u.colors[1].rgb, smoothstep(-0.8, 0.8, band));
    ink = mix(ink, u.colors[2].rgb, 0.45 * exp(-abs(band) * u.scale * 6.0));
    ink *= 1.0 - 0.16 * saturate((p.y - surface) / (2.0 * R));
    float meniscus = rx_stroke(p.y - surface, 1.6, u) * wet * 0.0 + rx_stroke(p.y - surface - 0.8, 1.6, u);

    float4 col = rx_over(float4(u.colors[4].rgb, u.colors[4].a * inside), float4(ink, wet * inside));
    col = rx_over(col,
                  float4(u.colors[2].rgb, u.colors[2].a * meniscus * inside * step(0.001, level) * step(level, 0.999)));
    float rim = rx_stroke(glass, u.params[2] > 0 ? u.params[2] : 1.0, u);
    return rx_over(col, float4(u.colors[3].rgb, u.colors[3].a * rim));
}
