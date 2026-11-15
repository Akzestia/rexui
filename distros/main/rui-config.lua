-- Copyright (c) 2026-present アクゼスティア
-- SPDX-License-Identifier: GPL-3.0-only
return {
    transparency = true,
    background_opacity = 0.85,
    background_blur = 32,

    traffic_lights = false,
    tab_bar = false,
    pane_buttons = false,
    pane_scroll = "smooth",
    pane_scroll_lines = 3,
    pane_scroll_duration = 150,
    pane_scroll_trackpad_duration = 40,
    pane_scroll_speed = 1,
    pane_scroll_bounce = true,
    pane_scroll_bounce_size = 80,
    pane_scroll_bounce_spring = { 11, 0.72 },
    tab_slide = true,
    tab_slide_duration = 300,
    tab_slide_curve = { 0.05, 0.9, 0.1, 1.05 },
    pane_motion = true,
    pane_glide = true,
    pane_glide_duration = 300,
    pane_glide_curve = { 0.05, 0.9, 0.1, 1.05 },
    pane_drag = true,
    pane_drag_modifier = "cmd",
    pane_keep = false,
    quit_key = "cmd+shift+q",
    lazy_layers = true,

    window_padding_x = 0,
    window_padding_y = { 10, 10 },

    background_gif = "",
    background_gif_height = 160,
    background_gif_position = "bottom-right",
    background_gif_margin = 16,
    background_gif_opacity = 1,

    ui = true,

    language = "en",
    locales = { "en-GB", "ja-JP" },

    github_user = "",

    pane_scrollbars = false,
    tab_preview_zoom = 1,
    command_palette = "rexui",
    single_window = true,
    tab_peek_width = 1200,

    notifications = "rexui",
    notifications_system = "inactive",
    notification_sound = "Tink",
    notification_sound_done = "Glass",
    notification_sound_blocked = "Funk",
    notification_sound_error = "Basso",
}
