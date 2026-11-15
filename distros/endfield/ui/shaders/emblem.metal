// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
float rhombus(float2 p, float2 h) {
    p = abs(p);
    return (p.x / h.x + p.y / h.y - 1.0) * (h.x * h.y) / length(h);
}

float4 shade(float2 p, constant Shader& u) {
    float S = min(u.size.x, u.size.y);
    float2 c = u.size * 0.5;
    float2 q = p - c;
    float busy = saturate(u.params[0]);
    float turns = u.params[1] != 0 ? u.params[1] : 1.0;
    float glintAmt = u.params[2] == 0 ? 1.0 : max(0.0, u.params[2]);
    float lw = (u.params[3] > 0 ? u.params[3] : 1.5) * max(1.0, S / 24.0);
    float t = u.time;
    float4 mark = u.colors[0];
    float4 glint = u.colors[1].a > 0 ? u.colors[1] : mark;
    float4 inner = u.colors[2].a > 0 ? u.colors[2] : mark;

    float2 H = float2(0.34, 0.47) * S;
    float d = rhombus(q, H);
    float ring = rx_stroke(d + lw * 0.5, lw, u);
    float2 e = float2(H.x, -H.y);
    float along = dot(q - float2(0.0, -H.y), normalize(float2(H.x, H.y))) / length(H);
    float gap = smoothstep(0.30, 0.31, along) * (1.0 - smoothstep(0.52, 0.53, along));
    ring *= 1.0 - gap * step(0.0, q.x) * step(q.y, 0.0);

    float2 ic = float2(-0.07, 0.10) * S;
    float di = rhombus(q - ic, float2(0.15, 0.21) * S);
    float flick = rx_hash(float2(floor(t * 12.0), 3.7)) > 0.45 ? 1.0 : 0.25;
    float facet = rx_fill(di, u) * mix(1.0, flick, busy);

    float2 gc = ic + float2(0.0, -0.21 * S);
    float2 g = rx_rotate(t * turns * 6.2831853 / 60.0) * (p - c - gc);
    float r = length(g) / S;
    float a = atan2(g.y, g.x);
    float rays = pow(abs(cos(2.0 * a)), 60.0) * exp(-r * 16.0) + 0.5 * pow(abs(sin(2.0 * a)), 90.0) * exp(-r * 26.0);
    float core = exp(-r * r * 900.0);
    float pulse = 1.0 + busy * 0.8 * (0.5 + 0.5 * sin(t * 5.0));
    float gl = saturate((rays + core) * glintAmt * pulse);

    float4 out = float4(mark.rgb, mark.a * ring);
    out = rx_over(out, float4(inner.rgb, inner.a * facet));
    out = rx_over(out, float4(glint.rgb, glint.a * gl));
    return out;
}
