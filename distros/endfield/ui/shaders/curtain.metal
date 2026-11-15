// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
float4 shade(float2 p, constant Shader& u) {
    float pitch = u.params[0] > 0 ? u.params[0] : 4.0;
    float H = u.params[1] > 0 ? u.params[1] : u.size.y;
    float speed = u.params[2] != 0 ? u.params[2] : 0.35;
    float i = floor(p.x / pitch);
    float lx = (fract(p.x / pitch) - 0.5) * pitch;
    float line = rx_fill(abs(lx) - 0.5, u);
    float h = H * (0.35 + 0.65 * rx_noise(float2(i * 0.37, u.time * 0.25 + i * 0.11)));
    float up = u.size.y - p.y;
    float body = (1.0 - smoothstep(0.0, h, up)) * step(0.0, up);
    float wave = 0.45 + 0.55 * pow(0.5 + 0.5 * sin(p.x / 90.0 - u.time * speed * 6.2831853), 2.0);
    float base = exp(-up / 3.0) * 0.6;
    return float4(u.colors[0].rgb, u.colors[0].a * saturate(line * body * wave + base * line));
}
