// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#import <Metal/Metal.h>

#include <cstddef>
#include <cstdint>

namespace rx::gpu {

id<MTLDevice> device();
id<MTLCommandQueue> queue();

inline constexpr std::size_t k_job_bytes = 320;
struct Job {
    void (*encode)(Job& job, id<MTLCommandBuffer> cb);
    bool control = false;
    alignas(16) unsigned char data[k_job_bytes];
};

bool render_start();
bool render_push(const Job& job);

using TickDraw = bool (*)(void* ctx, double now, id<MTLCommandBuffer> cb);
using TickGone = void (*)(void* ctx);
struct LinkId {
    std::uint32_t v = 0;
};
LinkId link_add(double fps, TickDraw draw, TickGone gone, void* ctx);
bool link_rate(LinkId id, double fps);
bool link_remove(LinkId id);
id link_target();
bool clock_attach(id display_link);

}
