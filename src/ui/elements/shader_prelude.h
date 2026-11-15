// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <string>

static const char* kShaderPrelude = R"METAL(#include <metal_stdlib>
using namespace metal;

struct Shader {
    float2 size;
    float2 mouse;
    float time;
    float hover;
    float scale;
    float seed;
    float params[16];
    float4 colors[8];
    float nframes;
    float frames[128];
    texture2d<float> image;
    float2 imageSize;
    texture2d<float> last;
    texture2d<float> passes[4];
};

inline float rx_frame(constant Shader &u, int i) { return i >= 0 && i < int(u.nframes) ? u.frames[i] : 0.0; }
inline float rx_frames_at(constant Shader &u, float x) {
    if (u.nframes < 1) return 0.0;
    float f = clamp(x, 0.0, 1.0) * (u.nframes - 1);
    int i = int(f);
    return mix(rx_frame(u, i), rx_frame(u, i + 1), f - float(i));
}

inline float4 rx_image(constant Shader &u, float2 uv) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return is_null_texture(u.image) ? float4(0) : u.image.sample(s, uv);
}
inline float4 rx_image_fill(constant Shader &u, float2 p) {
    if (u.imageSize.x < 1 || u.imageSize.y < 1) return float4(0);
    float k = max(u.size.x / u.imageSize.x, u.size.y / u.imageSize.y);
    return rx_image(u, (p - u.size / 2) / (u.imageSize * k) + 0.5);
}

inline float4 rx_last(constant Shader &u, float2 uv) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    if (is_null_texture(u.last)) return float4(0);
    float4 c = u.last.sample(s, uv);
    return c.a > 0 ? float4(c.rgb / c.a, c.a) : float4(0);
}

inline float4 rx_pass(constant Shader &u, int i, float2 uv) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    if (i < 0 || i > 3 || is_null_texture(u.passes[i])) return float4(0);
    return u.passes[i].sample(s, uv);
}

inline float rx_hash(float2 p) {
    float3 q = fract(float3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}
inline float2 rx_hash2(float2 p) {
    float3 q = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yzx + 33.33);
    return fract((q.xx + q.yz) * q.zy);
}

inline float rx_noise(float2 p) {
    float2 i = floor(p), f = fract(p), w = f * f * (3 - 2 * f);
    return mix(mix(rx_hash(i), rx_hash(i + float2(1, 0)), w.x), mix(rx_hash(i + float2(0, 1)), rx_hash(i + 1), w.x), w.y);
}

inline float rx_corner(float2 i, float2 f, float2 c) {
    float a = rx_hash(i + c) * 6.2831853;
    return dot(float2(cos(a), sin(a)), f - c);
}
inline float rx_gnoise(float2 p) {
    float2 i = floor(p), f = fract(p), w = f * f * f * (f * (f * 6 - 15) + 10);
    return 0.5 + 0.75 * mix(mix(rx_corner(i, f, float2(0, 0)), rx_corner(i, f, float2(1, 0)), w.x),
                            mix(rx_corner(i, f, float2(0, 1)), rx_corner(i, f, float2(1, 1)), w.x), w.y);
}

inline float rx_fbm(float2 p, int octaves = 5) {
    const float2x2 turn = float2x2(0.8, 0.6, -0.6, 0.8);
    float v = 0, a = 0.5, total = 0;
    for (int i = 0; i < octaves; i++) {
        v += a * rx_gnoise(p);
        total += a;
        p = turn * p * 2.03 + 17.1;
        a *= 0.5;
    }
    return v / total;
}

inline float rx_fill(float d, constant Shader &u) { return saturate(0.5 - d * u.scale); }
inline float rx_stroke(float d, float w, constant Shader &u) { return saturate(0.5 - (abs(d) - w / 2) * u.scale); }

inline float rx_circle(float2 p, float r) { return length(p) - r; }
inline float rx_box(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
inline float rx_segment(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    return length(pa - ba * saturate(dot(pa, ba) / dot(ba, ba)));
}

inline float4 rx_over(float4 below, float4 above) {
    float a = above.a + below.a * (1 - above.a);
    if (a <= 0) return float4(0);
    return float4((above.rgb * above.a + below.rgb * below.a * (1 - above.a)) / a, a);
}

inline float2x2 rx_rotate(float a) { float c = cos(a), s = sin(a); return float2x2(c, s, -s, c); }

inline float rx_grain(float2 p, float t) { return rx_hash(p * 1.37 + fract(t * 7.13) * 113.0) - 0.5; }
)METAL";

static const char* kShaderEpilogue = R"METAL(
struct RXVertex { float4 position [[position]]; };

vertex RXVertex rx_vertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return { float4(p * 2 - 1, 0, 1) };
}

fragment float4 rx_fragment(RXVertex in [[stage_in]], constant Shader &u [[buffer(0)]]) {
    float4 c = shade(in.position.xy / u.scale, u);
    c.rgb += (rx_hash(in.position.xy) - 0.5) / 255.0;
    c = saturate(c);
    return float4(c.rgb * c.a, c.a);
}
)METAL";

inline std::string shader_pass_entry(int i, const std::string& fn) {
    return "\nfragment float4 rx_pass_" + std::to_string(i)
        + "(RXVertex in [[stage_in]], constant Shader &u [[buffer(0)]]) { return " + fn
        + "(in.position.xy / u.scale, u); }\n";
}
