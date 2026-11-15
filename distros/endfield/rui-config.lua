-- Copyright (c) 2026-present アクゼスティア
-- SPDX-License-Identifier: MIT
return {
    transparency = true,
    background_opacity = 0.9,
    background_blur = 24,
    traffic_lights = false,
    tab_bar = false,
    pane_buttons = false,
    pane_scrollbars = false,
    window_padding_y = { 6, 10 },

    tab_slide = true,
    tab_slide_duration = 260,
    tab_slide_axis = "vertical",
    tab_slide_curve = { 0.16, 1.0, 0.3, 1.0 },
    pane_glide = true,
    pane_glide_duration = 240,
    pane_glide_curve = { 0.16, 1.0, 0.3, 1.0 },
    pane_resize = false,
    pane_drag = true,
    pane_keep = true,
    quit_key = "cmd+shift+q",
    web_scrollbars = false,
    pane_drop_links = true,
    lazy_layers = true,

    command_palette = "rexui",
    single_window = true,
    tab_preview_zoom = 1,
    tab_peek_width = 520,

    notifications = "rexui",
    notifications_system = "inactive",
    rex_windows = "rexui",
    file_manager = "rexui",

    loading_screen = "ui/loading.rui",
    endfield_loading = "",

    app_icon = "assets/icon.png",

    language = "en",
    locales = { "en-GB", "ja-JP" },

    endfield_accent = "valley",
    endfield_motion = true,
    endfield_boot = true,
    endfield_callsign = "",
    endfield_logo = "game",
    endfield_pane_background = "blueprint",
    endfield_pane_frame = "cut",
    pane_inherit = true,
    missions_folder = "~/Documents/Missions",
    skport_browser = "zen",
    skport_demo = true,
    skport_every = 5,
    endfield_game_keys = "dvorak",
}
