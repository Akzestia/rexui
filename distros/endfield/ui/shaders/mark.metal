// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
float4 shade(float2 p, constant Shader& u) {
    if (u.imageSize.x < 1 || u.imageSize.y < 1)
        return float4(0);
    float k = min(u.size.x / u.imageSize.x, u.size.y / u.imageSize.y);
    float2 shown = u.imageSize * k;
    float2 origin = (u.size - shown) * 0.5;
    float px = 1.0 / max(u.scale, 1.0);
    float a = 0;
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            float2 q = p + ((float2(i, j) + 0.5) / 4.0 - 0.5) * px;
            float2 uv = (q - origin) / shown;
            if (all(uv >= 0.0) && all(uv <= 1.0))
                a += rx_image(u, uv).a;
        }
    }
    return float4(u.colors[0].rgb, u.colors[0].a * a / 16.0);
}
