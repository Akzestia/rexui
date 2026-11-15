// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
float ray(float2 p, float r1, float r2, float h) {
    p.x = abs(p.x);
    float b = (r1 - r2) / h, a = sqrt(1.0 - b * b), k = dot(p, float2(-b, a));
    if (k < 0.0)
        return length(p) - r1;
    if (k > a * h)
        return length(p - float2(0.0, h)) - r2;
    return dot(p, float2(a, b)) - r1;
}

float4 shade(float2 p, constant Shader& u) {
    float R = min(u.size.x, u.size.y) * 0.5;
    float2 q = (p - u.size * 0.5) / R;
    int n = clamp(int(u.params[0] > 0 ? u.params[0] : 12), 3, 24);
    float think = saturate(u.params[1]);
    float turns = u.params[2] != 0 ? u.params[2] : 1.0;
    float width = u.params[3] > 0 ? u.params[3] : 1.0;
    float t = u.time;
    float spin = t * turns * 6.2831853 / 60.0;
    float2 toward = (u.mouse - u.size * 0.5) / R;
    float lean = u.hover * 0.10;
    float d = 1e9, along = 0;
    for (int i = 0; i < n; i++) {
        float h1 = rx_hash(float2(i, 3.1)), h2 = rx_hash(float2(i, 7.7)), h3 = rx_hash(float2(i, 1.9));
        float a = spin + 6.2831853 * (i + 0.22 * (h1 - 0.5)) / n;
        if (u.hover > 0.001)
            a += lean * sin(atan2(toward.x, -toward.y) - a);
        float len = 0.60 + 0.20 * h2;
        len *= 1.0 + 0.03 * sin(t * 1.1 + i * 1.7) + 0.04 * u.hover;
        len *= 1.0 + think * 0.14 * pow(max(0.0, sin(t * 3.2 - i * 6.2831853 / n)), 3.0);
        float r1 = 0.03 * width, r2 = (0.062 + 0.02 * h3) * width;
        float2 rp = rx_rotate(-a) * q;
        float di = ray(rp, r1, r2, len - r2);
        if (di < d)
            d = di, along = saturate(rp.y / len);
    }
    float cover = rx_fill(d * R, u);
    float4 tip = u.colors[1].a > 0 ? u.colors[1] : u.colors[0];
    float4 c = mix(u.colors[0], tip, smoothstep(0.35, 1.0, along));
    return float4(c.rgb, c.a * cover);
}
