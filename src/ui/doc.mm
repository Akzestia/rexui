// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/trace.h"
#include "web/web.h"

#include <dlfcn.h>
#include <notify.h>
#include "rex/rex.h"

NSString* default_ui_dir(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".config/rex/ui"];
}

static bool is_dir(NSString* p) {
    BOOL dir = NO;
    return p.length && [NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&dir] && dir;
}

static NSUserDefaults* choice(void) {
    static NSUserDefaults* d = [[NSUserDefaults alloc] initWithSuiteName:rexui_suite()];
    return d;
}

static NSString* tried(void) {
    NSString* t = [choice() stringForKey:@"try"].stringByExpandingTildeInPath;
    return t.length && [NSFileManager.defaultManager fileExistsAtPath:t] ? t : nil;
}

NSString* ui_dir(void) {
    if (NSString* t = tried(); is_dir(t))
        return t;
    NSString* d = [choice() stringForKey:@"distro"];
    if (d.length && ![d isEqualToString:@"default"]) {
        NSString* p = [d containsString:@"/"]
            ? d.stringByExpandingTildeInPath
            : [[NSHomeDirectory() stringByAppendingPathComponent:@".config/rex/distros"]
                  stringByAppendingPathComponent:d];
        if (is_dir(p))
            return p;
    }
    return default_ui_dir();
}

static void destroy_node(RXNode* n) {
    for (RXNode* c in [n.children copy])
        destroy_node(c);
    focus_gone(n);
    text_gone(n);
    close_web(n);
    if (is_elem(n, E::Process))
        stop(n);
    if (is_elem(n, E::Video))
        video_stop(n);
    if (is_elem(n, E::Shortcut) || is_drawer(n))
        keys_dirty();
    [n.cookie_timer invalidate];
    node_link(n, false);
    box_fx_gone(n);
    move_node_gone(n);
    {
        CALayer* going = n.layer;
        if (!is_drawer(n) && !is_native(n) && !disappear_play(n, ^{
                [going removeFromSuperlayer];
            }))
            [going removeFromSuperlayer];
        else if (is_drawer(n) || is_native(n))
            [going removeFromSuperlayer];
    }
    if (is_native(n))
        [n.clip ?: n.view removeFromSuperview];
    if (is_drawer(n))
        [n.host removeFromSuperview];
    [n.doc.natives removeObject:n];
    if (n.parent)
        invalidate(n.parent);
    if (NSMutableArray* kids = n.parent.children) {
        NSUInteger at = kids.count && kids.lastObject == n ? kids.count - 1 : [kids indexOfObjectIdenticalTo:n];
        if (at != NSNotFound)
            [kids removeObjectAtIndex:at];
    }
    kids_changed();
    RXDoc* was = n.doc;
    if (RXDoc* d = n.doc)
        d->index.erase(uint32_t(n.uid));
    [n.doc.nodes removeObjectForKey:@(n.uid)];
    n.doc = nil;
    debug_changed(was);
}

void native_create(RXDoc* doc, int uid, NSString* type, int parent) {
    RX_INTERVAL(apply, "create");
    RXNode* n = [RXNode new];
    n.uid = uid, n.type = type, n.doc = doc, n.stdin_fd = -1, n.appear_due = true;
    n.children = [NSMutableArray array];
    if (is_elem(n, E::Process))
        n.out = [NSMutableData data], n.err = [NSMutableData data];
    doc.nodes[@(uid)] = n;
    doc->index.put(uint32_t(uid), n);
    if (is_elem(n, E::MouseArea))
        doc.has_areas = true;
    if (RXNode* p = parent ? doc->index.find(uint32_t(parent)) : nil) {
        n.parent = p;
        [p.children addObject:n];
        kids_changed();
        invalidate(p);
    } else if (!doc.root) {
        doc.root = n;
    }
    if (n.parent && lazy_layer_kind(n) && lazy_layers_wanted()) {
        n.dormant = true;
        lazy_warm(n);
    } else {
        n.layer = make_layer(n);
        if (n.layer && n.parent && !is_drawer(n))
            [content_layer(n.parent) addSublayer:n.layer];
        if (is_elem(n, E::Text) || is_elem(n, E::Button) || is_elem(n, E::TextField) || is_elem(n, E::Icon))
            apply_color(n);
    }
    debug_changed(doc);
}

void native_set(RXDoc* doc, int uid, P p, NSString* name, const rx::ui::PVal& v) {
    RXNode* n = doc->index.find(uint32_t(uid));
    if (!n)
        return;
    id was_pane = nil;
    const bool pane_id = [name isEqualToString:@"paneId"];
    if (pane_id)
        was_pane = obj(n, @"paneId");
    apply(n, p, name, v);
    if (pane_id && [was_pane isKindOfClass:NSString.class] && [was_pane length]
        && ![obj(n, @"paneId") isEqual:was_pane])
        deco_retargeted(n);
    if (uid == g_debug_sel_uid && (__bridge const void*)doc == g_debug_sel_doc)
        debug_selected_changed();
}

NSString* native_source(RXDoc* doc, NSString* path) {
    if ([path hasPrefix:@"rexui/"]) {
        NSString* home = @(getenv("REXUI_HOME") ?: "");
        path = [home.stringByDeletingLastPathComponent
            stringByAppendingPathComponent:[@"src/ui/kit" stringByAppendingPathComponent:[path substringFromIndex:6]]];
    }
    if ([path hasPrefix:@"rexshared/"]) {
        NSString* home = @(getenv("REXUI_HOME") ?: "");
        path = [home.stringByDeletingLastPathComponent
            stringByAppendingPathComponent:[@"distros/shared"
                                               stringByAppendingPathComponent:[path substringFromIndex:10]]];
    }
    path = path.stringByExpandingTildeInPath.stringByStandardizingPath;
    if (![path.pathExtension isEqualToString:@"rui"])
        return nil;
    NSString* text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (doc)
        doc_wants_text(doc, text);
    return text;
}

void doc_wants_text(RXDoc* doc, NSString* text) {
    if (!text.length)
        return;
    doc.wants_fps |= [text containsString:@"rex.fps"];
    doc.wants_activity |= [text containsString:@"activity."];
    doc.wants_notices |= [text containsString:@"notices."];
    doc.wants_diagnostics |= [text containsString:@"diagnostics."];
    doc.wants_rexstate |= [text containsString:@"panes.zoomed"] || [text containsString:@"panes.busy"] ||
        [text containsString:@"panes.arriving"];
    doc.wants_hover |= [text containsString:@"hoveredLink"];
    doc.wants_fps_panes |= [text containsString:@"panes.fps"];
    doc.wants_hints |= [text containsString:@"keys.hints"];
    doc.wants_debug |= [text containsString:@"debug."];
}

void native_log(NSString* name, NSString* msg, NSString* level) {
    NSString* mark = [level isEqualToString:@"warn"] ? @"warning: "
        : [level isEqualToString:@"error"]           ? @"error: "
                                                     : @"";
    rexui_log_file([NSString stringWithFormat:@"%@: %@%@", name, mark, msg]);
    debug_console_add(name, level.length ? level : @"log", msg);
}

void native_call(RXDoc* doc, int uid, NSString* method, NSString* arg) {
    RXNode* n = uid > 0 ? doc->index.find(uint32_t(uid)) : nil;
    if (!n)
        return;
    if (n.dormant && ![method isEqualToString:@"destroy"] && ![method isEqualToString:@"order"]
        && ![method isEqualToString:@"loaderDue"])
        (void)ensure_layer(n);
    if ([method isEqualToString:@"destroy"]) {
        RXDoc* in = n.doc;
        destroy_node(n);
        if (in)
            schedule_layout(in, false);
    } else if ([method isEqualToString:@"focus"]) {
        if (is_native(n))
            [n.view.window makeFirstResponder:n.view];
        else
            focus_node(n, false);
    } else if ([method isEqualToString:@"select"] || [method isEqualToString:@"selectAll"] ||
               [method isEqualToString:@"insert"] || [method isEqualToString:@"find"] ||
               [method isEqualToString:@"findBack"]) {
        if (is_elem(n, E::TextField) || is_elem(n, E::TextArea))
            editor_call(n, method, arg);
    } else if ([method isEqualToString:@"seek"]) {
        if (is_elem(n, E::Video))
            video_seek(n, arg.doubleValue);
    } else if ([method isEqualToString:@"order"]) {
        NSMutableArray<RXNode*>* now = [NSMutableArray array];
        for (NSString* u in [arg componentsSeparatedByString:@","])
            if (RXNode* c = doc.nodes[@(u.intValue)])
                [now addObject:c];
        if (now.count == n.children.count) {
            [n.children setArray:now];
            kids_changed();
            invalidate(n);
            schedule_layout(n.doc, false);
        }
    } else if ([method isEqualToString:@"loaderDue"]) {
        __weak RXNode* weak = n;
        __weak RXDoc* weak_doc = doc;
        dispatch_async(dispatch_get_main_queue(), ^{
            RXNode* m = weak;
            RXDoc* d = weak_doc;
            if (m && d)
                doc_call(d, @"update", @[@(m.uid), @{@"loadNow": @YES}]);
            if (m && d)
                doc_call(d, @"update", @[@(m.uid), @{@"loadNow": @NO}]);
        });
    } else if ([method isEqualToString:@"scrollTo"]) {
        if (is_list(n)) {
            NSArray<NSString*>* at = [arg componentsSeparatedByString:@","];
            RXScrollLayer* sv = (RXScrollLayer*)n.layer;
            sv.offset = (sv.horizontal ? at.firstObject : at.lastObject).doubleValue;
        }
    } else if ([method isEqualToString:@"releaseFocus"]) {
        focus_release(n);
    } else if ([method isEqualToString:@"append"]) {
        if (RXEditor* e = is_elem(n, E::TextArea) ? node_editor(n, true) : nil)
            [e appendText:arg];
    } else if ([method isEqualToString:@"save"]) {
        if (is_elem(n, E::TextArea))
            editor_save(n);
    } else if ([method isEqualToString:@"recordKey"]) {
        record_key(n, ![arg isEqualToString:@"stop"]);
    } else if (is_elem(n, E::FileDialog)) {
        if ([method isEqualToString:@"open"])
            open_file_dialog(n);
    } else if (is_elem(n, E::WebView)) {
        WKWebView* w = (WKWebView*)n.view;
        if ([method isEqualToString:@"back"])
            [w goBack];
        else if ([method isEqualToString:@"forward"])
            [w goForward];
        else if ([method isEqualToString:@"reload"])
            web_reload(n, false);
        else if ([method isEqualToString:@"stop"])
            [w stopLoading];
        else if ([method isEqualToString:@"load"])
            web_load(n, arg);
        else if ([method isEqualToString:@"adblockSettings"])
            web_adblock_settings(n);
    }
}

static void shared_put(NSString* key, id value);
static id arg_at(NSArray* a, NSUInteger i) {
    id x = i < a.count ? a[i] : nil;
    return x == NSNull.null ? nil : x;
}
static NSString* arg_str(NSArray* a, NSUInteger i) {
    id x = arg_at(a, i);
    return [x isKindOfClass:NSString.class] ? x : x ? [x description] : nil;
}

static id api_process(RXDoc* doc, NSArray* a) {
    RXNode* n = doc.nodes[@([arg_at(a, 1) intValue])];
    if (![arg_str(a, 0) isEqualToString:@"call"] || !is_elem(n, E::Process))
        return nil;
    id v = arg_at(a, 2) ?: NSNull.null;
    NSData* j = [NSJSONSerialization dataWithJSONObject:v options:NSJSONWritingFragmentsAllowed error:nil];
    return process_call(n, j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : @"null");
}

static id api_rex(RXDoc* doc, NSArray* a) {
    NSString* op = arg_str(a, 0);
    NSString* name = arg_str(a, 1);
    id args_o = arg_at(a, 2);
    NSDictionary* args_d = [args_o isKindOfClass:NSDictionary.class] ? args_o : nil;
    if ([op isEqualToString:@"set"]) {
        id v = [args_d objectForKey:@"value"];
        static NSSet<NSString*>* updater = [NSSet setWithObjects:@"SUEnableAutomaticChecks", nil];
        if ([name hasPrefix:@"SU"] && ![updater containsObject:name]) {
            rexui_log([NSString stringWithFormat:@"%@: rex.set(\"%@\") refused: of the updater's preferences only "
                                                 @"SUEnableAutomaticChecks is a distro's",
                                                 doc.path.lastPathComponent, name]);
            return nil;
        }
        bool ours = [name hasPrefix:RXNS(RXN_181)] || [name hasPrefix:@"rex."] || [name hasPrefix:@"SU"];
        if (!ours)
            return nil;
        if (!v || v == NSNull.null)
            [NSUserDefaults.standardUserDefaults removeObjectForKey:name];
        else
            [NSUserDefaults.standardUserDefaults setObject:v forKey:name];
        return nil;
    }
    NSArray* path = [args_d objectForKey:@"path"];
    if (![path isKindOfClass:NSArray.class])
        path = nil;
    if ([op isEqualToString:@"menu"])
        return @(path && rex_menu(path));
    if ([op isEqualToString:@"checked"])
        return path ? rex_menu_checked(path) : nil;
    if ([op isEqualToString:@"shortcuts"])
        return menu_shortcuts();
    if ([op isEqualToString:@"block"])
        return panes_last_block();
    if ([op isEqualToString:@"closeTab"]) {
        rex_close_tab(int_of([args_d objectForKey:@"index"]));
        return nil;
    }
    if ([op isEqualToString:@"terminal"])
        return @(context_terminal(name));
    if ([op isEqualToString:@"dock"]) {
        NSString* file = name.copy;
        const bool show = truthy_of([args_d objectForKey:@"show"]);
        dispatch_async(dispatch_get_main_queue(), ^{
            dock_key(file, show);
        });
        return @YES;
    }
    if ([op isEqualToString:@"paneData"]) {
        NSDictionary* a2 = args_d;
        pane_data_set(name, a2[@"key"], a2[@"value"]);
        return nil;
    }
    if ([op isEqualToString:@"present"]) {
        if (rex_present(name.UTF8String))
            return @YES;
        NSDictionary* actions = @{
            @"renameTab": @"client.tab.rename",
            @"renameSession": @"session.rename",
            @"addHost": @"client.host.add",
            @"find": @"client.find.open",
            @"tearOff": @"client.tab.move_to_new_window",
            @"themeChange": @"client.theme.change",
            @"themeImport": @"client.theme.import",
            @"editShortcuts": @"client.shortcuts.edit",
            @"goToDirectory": @"pane.go_to_directory",
            @"movePaneToTab": @"pane.move_to_tab",
            @"switchHost": @"client.host.switch",
            @"removeHost": @"client.host.remove",
            @"activity": @"client.sidebar.activity.toggle",
            @"commandPalette": @"client.palette.toggle"
        };
        if ([name isEqualToString:@"tearOff"] && g_config.single_window) {
            rexui_log(@"rex.present(\"tearOff\"): not with single_window (a TabPreview with interactive: true is the "
                      @"tab in a dock)");
            return @NO;
        }
        if (NSString* a2 = actions[name]) {
            rex_run(a2, @{});
            return @YES;
        }
        return @NO;
    }
    if ([op isEqualToString:@"find"]) {
        NSString* text = [args_d objectForKey:@"text"];
        rex_run(@"client.find.open", @{});
        if ([text isKindOfClass:NSString.class] && text.length)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                NSResponder* fr = NSApp.keyWindow.firstResponder;
                if (![fr isKindOfClass:NSTextView.class])
                    return rexui_log(@"rex.find: the find field doesn't have the keyboard");
                NSTextView* tv = (NSTextView*)fr;
                [tv selectAll:nil];
                [tv insertText:text replacementRange:tv.selectedRange];
            });
        return nil;
    }
    if ([op isEqualToString:@"openPane"]) {
        ui_open_pane(name, (args_d ?: @{}));
        return nil;
    }
    if ([op isEqualToString:@"takePaste"]) {
        if (doc)
            doc.takes_paste = truthy_of([args_d objectForKey:@"on"]);
        return nil;
    }
    if ([op isEqualToString:@"paste"]) {
        NSDictionary* a2 = (args_d ?: @{});
        NSDictionary* last = panes_last_block() ?: @{};
        NSString* block = [a2[@"block"] length] ? a2[@"block"] : last[@"block"];
        NSString* session = [a2[@"session"] length] ? a2[@"session"]
            : [a2[@"block"] length]                 ? g_session_id
                                                    : last[@"session"];
        if ([a2[@"text"] isKindOfClass:NSString.class])
            agent_send(session ?: g_session_id, block, a2[@"text"], false, false);
        return nil;
    }
    if ([op isEqualToString:@"takeLinks"]) {
        if (doc)
            doc.takes_links = truthy_of([args_d objectForKey:@"on"]);
        return nil;
    }
    if ([op isEqualToString:@"appIcon"]) {
        id p = [args_d objectForKey:@"path"];
        icon_set([p isKindOfClass:NSString.class] ? p : nil);
        return nil;
    }
    if ([op isEqualToString:@"closeSession"]) {
        rex_close_session(name);
        return nil;
    }
    if ([op isEqualToString:@"original"])
        rex_original(name);
    else
        rex_run(name, args_d);
    return nil;
}

static id api_clipboard(RXDoc* doc, NSArray* a) {
    NSString* op = arg_str(a, 0);
    NSPasteboard* pb = ui_pasteboard();
    if ([op isEqualToString:@"read"])
        return [pb stringForType:NSPasteboardTypeString] ?: @"";
    if ([op isEqualToString:@"write"]) {
        id args_o = arg_at(a, 1);
        NSString* text = [args_o isKindOfClass:NSDictionary.class] ? args_o[@"text"] : nil;
        [pb clearContents];
        if ([text isKindOfClass:NSString.class])
            [pb setString:text forType:NSPasteboardTypeString];
        return nil;
    }
    if ([op isEqualToString:@"clear"])
        return [pb clearContents], nil;
    if ([op isEqualToString:@"changeCount"])
        return @(pb.changeCount);
    if ([op isEqualToString:@"files"]) {
        NSMutableArray* paths = [NSMutableArray array];
        for (NSURL* u in [pb readObjectsForClasses:@[NSURL.class]
                                           options:@{
                                               NSPasteboardURLReadingFileURLsOnlyKey: @YES
                                           }])
            if (u.path)
                [paths addObject:u.path];
        return paths;
    }
    return nil;
}

static id api_rexstate(RXDoc* doc, NSArray* a) {
    NSString* op = arg_str(a, 0);
    id args_o = arg_at(a, 1);
    NSDictionary* args_d = [args_o isKindOfClass:NSDictionary.class] ? args_o : nil;
    return rexstate_native(op, (args_d ?: @{}));
}

static id api_activity(RXDoc* doc, NSArray* a) {
    NSString* op = arg_str(a, 0);
    id args_o = arg_at(a, 1);
    NSDictionary* args_d = [args_o isKindOfClass:NSDictionary.class] ? args_o : nil;
    if ([op isEqualToString:@"delegate"]) {
        if (doc)
            doc.activity_delegate = truthy_of([args_d objectForKey:@"on"]);
        rex_wrap_closures();
        return nil;
    }
    return activity_native(op, (args_d ?: @{}));
}

static id api_shared(RXDoc* doc, NSArray* a) {
    NSString* key = arg_str(a, 0);
    id value_o = arg_at(a, 1);
    shared_put(key, value_o);
    return nil;
}

static id api_diagnostics(RXDoc* doc, NSArray* a) {
    NSString* op = arg_str(a, 0);
    id args_o = arg_at(a, 1);
    NSDictionary* args_d = [args_o isKindOfClass:NSDictionary.class] ? args_o : nil;
    return diagnostics_native(doc, op, (args_d ?: @{}));
}

static id api_files(RXDoc* doc, NSArray* a) {
    NSString* op = arg_str(a, 0);
    id args_o = arg_at(a, 1);
    NSDictionary* args_d = [args_o isKindOfClass:NSDictionary.class] ? args_o : nil;
    return files_native(doc, op, (args_d ?: @{}));
}

static id api_loading(RXDoc* doc, NSArray* a) {
    NSString* op = arg_str(a, 0);
    return loading_native(op);
}

static id api_windows(RXDoc* doc, NSArray* a) {
    NSString* op = arg_str(a, 0);
    id args_o = arg_at(a, 1);
    NSDictionary* args_d = [args_o isKindOfClass:NSDictionary.class] ? args_o : nil;
    if ([op isEqualToString:@"delegate"]) {
        if (doc)
            doc.window_delegate = truthy_of([args_d objectForKey:@"on"]);
        return nil;
    }
    return windows_native(op, (args_d ?: @{}));
}

static id api_notices(RXDoc* doc, NSArray* a) {
    NSString* op = arg_str(a, 0);
    id args_o = arg_at(a, 1);
    NSDictionary* args_d = [args_o isKindOfClass:NSDictionary.class] ? args_o : nil;
    if ([op isEqualToString:@"delegate"])
        if (doc)
            doc.notice_delegate = truthy_of([args_d objectForKey:@"on"]);
    return notices_native(op, (args_d ?: @{}));
}

static id api_debug(RXDoc* doc, NSArray* a) {
    NSString* op = arg_str(a, 0);
    id arg_o = arg_at(a, 1);
    if ([op isEqualToString:@"tree"] && [arg_o isKindOfClass:NSString.class])
        if (id rows = debug_tree_rows(arg_o))
            return rows;
    return debug_native(op, arg_o);
}

id native_api(RXDoc* doc, NSString* fn, NSArray* a) {
    using Api = id (*)(RXDoc*, NSArray*);
    static NSDictionary<NSString*, NSValue*>* table = @{
        @"process": [NSValue valueWithPointer:reinterpret_cast<const void*>(&api_process)],
        @"rex": [NSValue valueWithPointer:reinterpret_cast<const void*>(&api_rex)],
        @"clipboard": [NSValue valueWithPointer:reinterpret_cast<const void*>(&api_clipboard)],
        @"rexstate": [NSValue valueWithPointer:reinterpret_cast<const void*>(&api_rexstate)],
        @"activity": [NSValue valueWithPointer:reinterpret_cast<const void*>(&api_activity)],
        @"shared": [NSValue valueWithPointer:reinterpret_cast<const void*>(&api_shared)],
        @"diagnostics": [NSValue valueWithPointer:reinterpret_cast<const void*>(&api_diagnostics)],
        @"files": [NSValue valueWithPointer:reinterpret_cast<const void*>(&api_files)],
        @"loading": [NSValue valueWithPointer:reinterpret_cast<const void*>(&api_loading)],
        @"windows": [NSValue valueWithPointer:reinterpret_cast<const void*>(&api_windows)],
        @"notices": [NSValue valueWithPointer:reinterpret_cast<const void*>(&api_notices)],
        @"debug": [NSValue valueWithPointer:reinterpret_cast<const void*>(&api_debug)],
    };
    NSValue* f = table[fn];
    return f ? reinterpret_cast<Api>(const_cast<void*>(f.pointerValue))(doc, a) : nil;
}

id doc_call(RXDoc* doc, NSString* method, NSArray* args) {
    RX_INTERVAL(flush, "call");
    return doc.engine ? engine_call(doc, method, args) : nil;
}

void unload(RXDoc* doc) {
    picker_unloaded(doc);
    if (doc.reloading)
        process_park(doc);
    engine_detach(doc);
    keys_dirty();
    dispatch_async(dispatch_get_main_queue(), ^{
        rexstate_docs_changed();
    });
    NSMutableDictionary<NSString*, NSString*>* pages = [NSMutableDictionary dictionary];
    for (RXNode* n in doc.nodes.allValues)
        if (is_elem(n, E::WebView) && n.session && ((WKWebView*)n.view).URL.absoluteString.length)
            pages[n.session.lastPathComponent] = ((WKWebView*)n.view).URL.absoluteString;
    doc.restore_pages = pages;
    for (RXNode* n in doc.nodes.allValues) {
        if (is_elem(n, E::WebView))
            session_save(n);
        close_web(n);
        if (is_elem(n, E::Process) && !n.parked)
            stop(n);
        if (is_elem(n, E::Video))
            video_stop(n);
        [n.cookie_timer invalidate];
        node_link(n, false);
        n.doc = nil;
    }
    for (RXNode* n in doc.nodes.allValues) {
        if (is_drawer(n))
            [n.host removeFromSuperview];
        [n.clip removeFromSuperview];
    }
    [doc.root.host removeFromSuperview];
    [pane_root(doc, false) removeFromSuperview];
    doc.nodes = nil;
    doc.root = nil;
    doc.ctx = nil;
    debug_changed(doc);
}

int g_tab;
NSArray<NSString*>* g_tab_titles = @[];
NSString *g_session = @"", *g_session_id = @"";
NSArray<NSDictionary*>* g_sessions = @[];

void set_rex(RXDoc* doc) {
    doc_call(doc, @"setRex", @[@{
                 @"tab": @(g_tab),
                 @"tabs": @(g_tab_titles.count),
                 @"titles": g_tab_titles,
                 @"fps": @(g_fps),
                 @"session": g_session,
                 @"sessionId": g_session_id,
                 @"sessions": g_sessions
             }]);
}

void set_conf(RXDoc* doc) {
    doc_call(doc, @"setConf", @[@{@"values": g_config.values ?: @{}}]);
}

static NSMutableDictionary* g_shared;
static void set_shared(RXDoc* doc) {
    doc_call(doc, @"setShared", @[@{@"values": g_shared ?: @{}}]);
}
static void shared_put(NSString* key, id value) {
    if (!key.length)
        return;
    if (!g_shared)
        g_shared = [NSMutableDictionary dictionary];
    id was = g_shared[key];
    if (value == was || [value isEqual:was])
        return;
    if (value)
        g_shared[key] = value;
    else
        [g_shared removeObjectForKey:key];
    static bool queued;
    if (queued)
        return;
    queued = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        queued = false;
        for (RXDoc* d in [g_docs copy])
            if (d.ctx)
                set_shared(d);
    });
}

void set_theme(RXDoc* doc) {
    doc_call(doc, @"setTheme",
             @[@{@"background": hex(g_theme.bg),
                 @"foreground": hex(g_theme.fg),
                 @"dark": @(g_theme.dark)}]);
}

static void show_error(RXDoc* doc, NSString* message) {
    rexui_log_file(message);
    doc.error = message;
    debug_console_add(doc.path.lastPathComponent, @"error", message);
    RXNode* root = [RXNode new];
    root.type = @"Dock";
    prop_put(root, @"side", @"right"), prop_put(root, @"width", @320), prop_put(root, @"padding", @16);
    root.children = [NSMutableArray array];
    root.doc = doc;
    doc.natives = [NSHashTable weakObjectsHashTable];
    root.layer = make_layer(root);
    root.stdin_fd = -1;
    RXNode* text = [RXNode new];
    text.type = @"Text";
    prop_put(text, @"wrap", @YES), prop_put(text, @"color", @"#ff6b6b"), prop_put(text, @"font.mono", @YES),
        prop_put(text, @"font.size", @11);
    text.children = [NSMutableArray array];
    text.layer = make_layer(text);
    text.stdin_fd = -1;
    for (NSString* k in @[@"wrap", @"color", @"font.size"])
        apply(text, k, obj(text, k));
    apply(text, @"text", [@"rexui: " stringByAppendingString:message]);
    [root.layer addSublayer:text.layer];
    [root.children addObject:text];
    text.parent = root;
    doc.root = root;
    doc.nodes = [@{@0: root} mutableCopy];
}

static NSString* load_begin(RXDoc* doc) {
    NSString* src = [NSString stringWithContentsOfFile:doc.path encoding:NSUTF8StringEncoding error:nil];
    doc.wants_fps = [src containsString:@"rex.fps"];
    doc.wants_activity = [src containsString:@"activity."];
    doc.wants_diagnostics = [src containsString:@"diagnostics."];
    doc.wants_rexstate = [src containsString:@"panes.zoomed"] || [src containsString:@"panes.busy"] ||
        [src containsString:@"panes.arriving"];
    doc.wants_hover = [src containsString:@"hoveredLink"];
    doc.wants_fps_panes = [src containsString:@"panes.fps"];
    doc.wants_hints = [src containsString:@"keys.hints"];
    doc.wants_notices = [src containsString:@"notices."];
    doc.wants_debug = [src containsString:@"debug."];
    NSString* dbg = debug_ui_dir();
    doc.devtools = dbg &&
        [doc.path.stringByDeletingLastPathComponent.stringByStandardizingPath
                       isEqualToString:dbg.stringByStandardizingPath];
    doc.error = nil;
    doc.notice_delegate = false;
    doc.window_delegate = false;
    doc.activity_delegate = false;
    doc.nodes = [NSMutableDictionary dictionary];
    doc.natives = [NSHashTable weakObjectsHashTable];
    if (!src) {
        show_error(doc, [NSString stringWithFormat:@"%@: cannot read the file", doc.path.lastPathComponent]);
        return nil;
    }
    NSString* name = doc.path.lastPathComponent;
    engine_detach(doc);
    if (!engine_attach(doc)) {
        show_error(doc, [NSString stringWithFormat:@"%@: the engine couldn't start (out of memory)", name]);
        return nil;
    }
    set_theme(doc);
    set_rex(doc);
    set_power(doc);
    set_conf(doc);
    if (g_shared.count)
        set_shared(doc);
    set_keys(doc);
    notices_doc_loaded(doc);
    windows_doc_loaded(doc);
    loading_doc_loaded(doc);
    diagnostics_doc_loaded(doc);
    activity_doc_loaded(doc);
    panes_doc_loaded(doc);
    set_lang(doc);
    set_debug(doc);
    if (doc.pane)
        doc_call(doc, @"setPane", @[@{@"id": doc.pane_block ?: @"", @"args": doc.pane_args ?: @[]}]);
    return src;
}

static void load_end(RXDoc* doc, NSString* error, double t0) {
    NSString* name = doc.path.lastPathComponent;
    NSMutableDictionary* uses = [NSMutableDictionary dictionary];
    for (NSString* p in array_of(doc_call(doc, @"used", @[]))) {
        NSString* full = p.stringByExpandingTildeInPath.stringByStandardizingPath;
        uses[full] = [NSFileManager.defaultManager attributesOfItemAtPath:full error:nil].fileModificationDate
            ?: NSDate.distantPast;
    }
    doc.uses = uses;
    if (!error.length && doc.pane && doc.root && !is_elem(doc.root, E::Dock))
        error = [name stringByAppendingString:@": a pane shows a Dock"];
    if (!error.length && doc.root && is_elem(doc.root, E::Panes)) {
        if (doc.pane)
            error = [name stringByAppendingString:@": a pane shows a Dock"];
        else {
            pane_styles_new_doc();
            dispatch_async(dispatch_get_main_queue(), ^{
                pane_styles_changed(true);
            });
        }
    }
    if (error.length || !doc.root) {
        unload(doc);
        show_error(doc, error.length ? error : [NSString stringWithFormat:@"%@: no Dock", name]);
    }
    if (doc.restore_state && doc.engine && doc.root) {
        unsigned kept = engine_restore(doc, doc.restore_state);
        if (kept)
            rexui_log([NSString stringWithFormat:@"%@: %u values kept across the reload", name, kept]);
    }
    doc.restore_state = nil;
    process_adopt(doc);
    rexui_log([NSString stringWithFormat:@"%@: loaded (%.1f ms)", name, (CACurrentMediaTime() - t0) * 1000]);
    debug_changed(doc);
    rexstate_docs_changed();
}

void load(RXDoc* doc) {
    RX_INTERVAL(load, "load");
    const double t0 = CACurrentMediaTime();
    NSString* src = load_begin(doc);
    if (src)
        load_end(doc, string_of(doc_call(doc, @"load", @[src, doc.path.lastPathComponent, doc.path])), t0);
}

@interface RXStage : NSObject
@property(nonatomic, copy) NSString* ui;
@property(nonatomic) NSMutableArray<NSString*>* paths;
@property(nonatomic) NSDictionary<NSString*, NSDate*>* found;
@property(nonatomic) NSMutableArray<RXDoc*>*fresh, *stale;
@property(nonatomic) NSMutableArray* then;
@property(nonatomic) double t0;
@end
@implementation RXStage
@end
static RXStage* g_stage;

static bool g_scanning, g_scan_again;
static NSMutableArray* g_scan_then;
void scan_then(void (^then)(void)) {
    if (g_stage)
        [g_stage.then addObject:[then copy]];
    else if (g_scanning)
        [g_scan_then ?: (g_scan_then = [NSMutableArray array]) addObject:[then copy]];
    else
        then();
}

static void stage_swap(RXStage* s) {
    g_stage = nil;
    bool styled = false;
    for (RXDoc* doc in s.stale) {
        unload(doc);
        [g_docs removeObject:doc];
    }
    for (RXDoc* doc in s.fresh) {
        [g_docs addObject:doc];
        set_theme(doc);
        set_rex(doc);
        set_power(doc);
        set_keys(doc);
        styled |= doc.root && is_elem(doc.root, E::Panes);
    }
    [g_docs sortUsingComparator:^NSComparisonResult(RXDoc* a, RXDoc* b) {
        return [a.path compare:b.path];
    }];
    chrome_relayout();
    ui_keys_changed();
    if (styled)
        pane_styles_new_doc();
    pane_styles_changed(styled);
    for (void (^then)(void) in s.then)
        then();
    rexui_log(
        [NSString stringWithFormat:@"ui: %@ in %.0f ms", s.ui.lastPathComponent, (CACurrentMediaTime() - s.t0) * 1000]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        engine_pace(false);
    });
    scan();
}

static void stage_step(RXStage* s) {
    if (![ui_dir() isEqual:s.ui]) {
        g_stage = nil;
        for (RXDoc* doc in s.fresh)
            unload(doc);
        engine_pace(false);
        scan();
        for (void (^then)(void) in s.then)
            scan_then(then);
        return;
    }
    NSString* path = s.paths.firstObject;
    if (!path)
        return stage_swap(s);
    [s.paths removeObjectAtIndex:0];
    RXDoc* doc = [RXDoc new];
    doc.path = path;
    doc.mtime = s.found[path];
    [s.fresh addObject:doc];
    const double t0 = CACurrentMediaTime();
    void (^next)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            stage_step(s);
        });
    };
    NSString* src = load_begin(doc);
    if (!src)
        return next();
    engine_load_async(doc, src, path.lastPathComponent, path, ^(NSString* error) {
        load_end(doc, error, t0);
        next();
    });
}

static void stage_start(NSString* ui, NSDictionary<NSString*, NSDate*>* found, NSArray<RXDoc*>* stale) {
    RXStage* s = [RXStage new];
    s.ui = ui;
    s.found = found;
    s.stale = [stale mutableCopy];
    s.fresh = [NSMutableArray array];
    s.then = [NSMutableArray array];
    s.t0 = CACurrentMediaTime();
    s.paths = [NSMutableArray array];
    for (NSString* path in [found.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        bool have = false;
        for (RXDoc* doc in g_docs)
            have |= !doc.pane && [doc.path isEqualToString:path];
        if (!have)
            [s.paths addObject:path];
    }
    g_stage = s;
    engine_pace(true);
    dispatch_async(dispatch_get_main_queue(), ^{
        stage_step(s);
    });
}

@interface RXScanLook : NSObject
@property(nonatomic, copy) NSArray<NSString*>*dirs, *debug_files;
@property(nonatomic, copy) NSString* tried;
@property(nonatomic) bool all_files;
@property(nonatomic, copy) NSArray<NSString*>* doc_paths;
@property(nonatomic, copy) NSArray<NSDate*>* doc_mtimes;
@property(nonatomic, copy) NSArray<NSDictionary<NSString*, NSDate*>*>* doc_uses;
@end
@implementation RXScanLook
@end
@interface RXScanFound : NSObject
@property(nonatomic) NSMutableDictionary<NSString*, NSDate*>* found;
@property(nonatomic) NSMutableDictionary<NSString*, NSDate*>* mtimes;
@property(nonatomic) NSMutableDictionary<NSString*, NSString*>* texts;
@end
@implementation RXScanFound
@end

static dispatch_queue_t scan_queue(void) {
    static dispatch_queue_t q = dispatch_queue_create(
        "rexui.scan", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    return q;
}

static RXScanFound* scan_look(RXScanLook* ask) {
    NSFileManager* fm = NSFileManager.defaultManager;
    RXScanFound* f = [RXScanFound new];
    f.found = [NSMutableDictionary dictionary], f.mtimes = [NSMutableDictionary dictionary],
    f.texts = [NSMutableDictionary dictionary];
    auto mtime = [&](NSString* p) -> NSDate* {
        if (NSDate* m = f.mtimes[p])
            return m == (id)NSNull.null ? nil : m;
        NSDate* m = [fm attributesOfItemAtPath:p error:nil].fileModificationDate;
        f.mtimes[p] = m ?: (NSDate*)NSNull.null;
        return m;
    };
    NSMutableArray<NSString*>* paths = [NSMutableArray array];
    for (NSString* dir in ask.dirs)
        for (NSString* name in [fm contentsOfDirectoryAtPath:dir error:nil])
            [paths addObject:[dir stringByAppendingPathComponent:name]];
    if (ask.tried)
        [paths addObject:ask.tried];
    [paths addObjectsFromArray:ask.debug_files];
    for (NSString* path in paths) {
        NSString* name = path.lastPathComponent;
        if (![name.pathExtension isEqualToString:@"rui"] || [name hasPrefix:@"."])
            continue;
        if ([NSCharacterSet.uppercaseLetterCharacterSet characterIsMember:[name characterAtIndex:0]])
            continue;
        if (!ask.all_files) {
            NSString* src = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            static NSRegularExpression* takes =
                [NSRegularExpression regularExpressionWithPattern:@"\\bcommand:[^\\n]*\"client\\." options:0 error:nil];
            if (!src || ![takes firstMatchInString:src options:0 range:NSMakeRange(0, src.length)])
                continue;
        }
        if (NSDate* m = mtime(path))
            f.found[path] = m;
    }
    for (NSUInteger i = 0; i < ask.doc_paths.count; i++) {
        NSString* path = ask.doc_paths[i];
        NSDate* m = f.found[path] ?: mtime(path);
        bool changed = m && ![m isEqual:ask.doc_mtimes[i]];
        for (NSString* u in ask.doc_uses[i]) {
            NSDate* um = mtime(u) ?: NSDate.distantPast;
            if (![um isEqual:ask.doc_uses[i][u]])
                changed = true;
        }
        if (changed && m)
            if (NSString* src = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil])
                f.texts[path] = src;
    }
    return f;
}

static NSDate* found_mtime(RXScanFound* f, NSString* p) {
    id m = f.mtimes[p];
    return m == NSNull.null ? nil : m;
}

static bool uses_changed(RXDoc* doc, RXScanFound* f) {
    for (NSString* p in doc.uses) {
        NSDate* m = found_mtime(f, p) ?: NSDate.distantPast;
        if (![m isEqual:doc.uses[p]])
            return true;
    }
    return false;
}

static void keep_last_good(RXDoc* doc, NSDate* mtime, NSString* error, RXScanFound* f) {
    doc.mtime = mtime;
    NSMutableDictionary* uses = [doc.uses mutableCopy];
    for (NSString* p in doc.uses)
        uses[p] = found_mtime(f, p) ?: NSDate.distantPast;
    doc.uses = uses;
    NSString* name = doc.path.lastPathComponent;
    rexui_log_file([NSString stringWithFormat:@"%@: not reloaded, the last good version runs on: %@", name, error]);
    debug_console_add(name, @"error",
                      [error stringByAppendingString:@" (not reloaded: the last good version runs on)"]);
}

static bool triable(RXDoc* doc, NSDate* mtime) {
    return doc.engine && doc.root && !doc.error && mtime;
}

static void scan_finish(RXScanFound* f, bool switching, NSSet<RXDoc*>* kept);

static void scan_apply(RXScanFound* f, bool switching) {
    NSMutableArray<RXDoc*>* trials = [NSMutableArray array];
    for (RXDoc* doc in g_docs) {
        NSDate* m = doc.pane ? found_mtime(f, doc.path) : f.found[doc.path];
        bool changed = doc.pane ? ((m && ![m isEqual:doc.mtime]) || uses_changed(doc, f))
                                : !(m && [m isEqual:doc.mtime] && !uses_changed(doc, f));
        if (!changed || (!doc.pane && switching && !m))
            continue;
        if (triable(doc, m) && f.texts[doc.path])
            [trials addObject:doc];
    }
    if (!trials.count)
        return scan_finish(f, switching, [NSSet set]);
    NSMutableSet<RXDoc*>* kept = [NSMutableSet set];
    __block NSUInteger left = trials.count;
    for (RXDoc* doc in trials) {
        NSDate* m = doc.pane ? found_mtime(f, doc.path) : f.found[doc.path];
        engine_trial_async(doc.path, f.texts[doc.path], ^(NSString* error) {
            if (error.length && [g_docs containsObject:doc]) {
                keep_last_good(doc, m, error, f);
                [kept addObject:doc];
            }
            if (--left == 0)
                scan_finish(f, switching, kept);
        });
    }
}

void scan(void) {
    if (g_stage)
        return;
    if (g_scanning) {
        g_scan_again = true;
        return;
    }
    RX_INTERVAL(scan, "scan");
    bool switching = false;
    lang_check();
    RXScanLook* ask = [RXScanLook new];
    {
        NSString* ui = ui_dir();
        ask.dirs = @[ui, [ui stringByAppendingPathComponent:@"ui"], tabs_dir()];
        if (NSString* t = tried(); t && !is_dir(t))
            ask.tried = t;
        NSMutableArray* dbg_files = [NSMutableArray array];
        if (NSString* dbg = debug_ui_dir()) {
            for (NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dbg error:nil])
                if (debug_file_loads(name))
                    [dbg_files addObject:[dbg stringByAppendingPathComponent:name]];
        }
        ask.debug_files = dbg_files;
        static NSString* last;
        ui_fonts_for(ui);
        if (![ui isEqual:last]) {
            rexui_log([@"ui: " stringByAppendingString:ui]);
            if (last)
                debug_native(@"theme", @{});
            build_backends(ui);
            if (last)
                dispatch_async(dispatch_get_main_queue(), ^{
                    watch_config();
                });
            switching = last && !loading_staging();
        }
        last = ui;
    }
    ask.all_files = g_config.ui;
    NSMutableArray *paths = [NSMutableArray array], *mtimes = [NSMutableArray array], *uses = [NSMutableArray array];
    for (RXDoc* doc in g_docs) {
        [paths addObject:doc.path ?: @""];
        [mtimes addObject:doc.mtime ?: NSDate.distantPast];
        [uses addObject:doc.uses ?: @{}];
    }
    ask.doc_paths = paths, ask.doc_mtimes = mtimes, ask.doc_uses = uses;
    g_scanning = true;
    dispatch_async(scan_queue(), ^{
        RXScanFound* f = scan_look(ask);
        dispatch_async(dispatch_get_main_queue(), ^{
            scan_apply(f, switching);
        });
    });
}

static void scan_finish(RXScanFound* f, bool switching, NSSet<RXDoc*>* kept) {
    NSMutableDictionary<NSString*, NSDate*>* found = f.found;
    for (NSString* path in found.allKeys)
        if (loading_is_cover(path))
            [found removeObjectForKey:path];
    bool changed = false;
    NSMutableDictionary<NSString*, NSMutableDictionary*>* pages = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSString*>* states = [NSMutableDictionary dictionary];
    NSMutableArray<RXDoc*>* stale = [NSMutableArray array];
    for (RXDoc* doc in [g_docs copy]) {
        if ([kept containsObject:doc])
            continue;
        if (doc.pane) {
            NSDate* m = found_mtime(f, doc.path);
            if ((m && ![m isEqual:doc.mtime]) || uses_changed(doc, f)) {
                doc.restore_state = engine_snapshot(doc);
                doc.reloading = m != nil;
                unload(doc);
                doc.reloading = false;
                doc.mtime = m;
                load(doc);
            }
            continue;
        }
        NSDate* mtime = found[doc.path];
        if (mtime && [mtime isEqual:doc.mtime] && !uses_changed(doc, f))
            continue;
        if (switching && !mtime) {
            [stale addObject:doc];
            continue;
        }
        if (NSString* state = engine_snapshot(doc))
            states[doc.path] = state;
        doc.reloading = mtime != nil;
        unload(doc);
        doc.reloading = false;
        if (doc.restore_pages)
            pages[doc.path] = doc.restore_pages;
        [g_docs removeObject:doc];
        changed = true;
    }
    g_scanning = false;
    NSArray* thens = g_scan_then;
    g_scan_then = nil;
    if (switching) {
        stage_start(ui_dir(), found, stale);
        for (void (^then)(void) in thens)
            scan_then(then);
        return;
    }
    bool staged = loading_staging(), more = false;
    NSString* last = nil;
    for (NSString* path in [found.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        bool have = false;
        for (RXDoc* doc in g_docs)
            have |= !doc.pane && [doc.path isEqualToString:path];
        if (have)
            continue;
        if (staged && last) {
            more = true;
            break;
        }
        last = path;
        RXDoc* doc = [RXDoc new];
        doc.path = path;
        doc.mtime = found[path];
        doc.restore_pages = pages[path];
        doc.restore_state = states[path];
        [g_docs addObject:doc];
        load(doc);
        changed = true;
    }
    if (changed) {
        [g_docs sortUsingComparator:^NSComparisonResult(RXDoc* a, RXDoc* b) {
            return [a.path compare:b.path];
        }];
        chrome_relayout();
        ui_keys_changed();
        pane_styles_changed(false);
    }
    if (staged) {
        NSUInteger have = 0;
        for (RXDoc* doc in g_docs)
            have += !doc.pane && found[doc.path] != nil;
        loading_scanned(have, found.count, last, more);
    }
    for (void (^then)(void) in thens)
        then();
    if (g_scan_again) {
        g_scan_again = false;
        scan();
    }
}

extern NSHashTable<RXNode*>* g_spawned;
void check_backends(void) {
    static bool out;
    if (out)
        return;
    NSMutableArray<NSString*>* paths = [NSMutableArray array];
    for (RXNode* n in g_spawned.allObjects)
        if (n.doc && n.pid && n.exe)
            [paths addObject:n.exe];
    if (!paths.count)
        return;
    out = true;
    stat_files(paths, ^(NSDictionary<NSString*, id>* when) {
        out = false;
        for (RXNode* n in g_spawned.allObjects) {
            RXDoc* doc = n.doc;
            if (!doc || ![g_docs containsObject:doc] || !n.pid || !n.exe)
                continue;
            NSDate* m = [when[n.exe] isKindOfClass:NSDate.class] ? when[n.exe] : nil;
            if (!m || [m isEqual:n.exe_mtime])
                continue;
            if (-m.timeIntervalSinceNow < 0.5)
                continue;
            rexui_log([NSString stringWithFormat:@"%@: %@ changed, restarting it", doc.path.lastPathComponent,
                                                 n.exe.lastPathComponent]);
            spawn(n);
        }
    });
}

void watch_config(void) {
    static FSEventStreamRef stream;
    static NSArray<NSString*>* watched;
    NSString* home = [NSHomeDirectory() stringByAppendingPathComponent:@".config/rex"];
    NSMutableArray<NSString*>* paths = [NSMutableArray arrayWithObject:home];
    NSString* real = ui_dir().stringByResolvingSymlinksInPath;
    if (real.length && ![real hasPrefix:[home stringByAppendingString:@"/"]] && ![paths containsObject:real])
        [paths addObject:real];
    NSString* bin = distro_backends_bin(ui_dir());
    [NSFileManager.defaultManager createDirectoryAtPath:bin withIntermediateDirectories:YES attributes:nil error:nil];
    if (![paths containsObject:bin])
        [paths addObject:bin];
    NSString* dbg = debug_ui_dir().stringByResolvingSymlinksInPath;
    bool inside = false;
    for (NSString* p in paths)
        inside |= [dbg isEqualToString:p] || [dbg hasPrefix:[p stringByAppendingString:@"/"]];
    if (dbg.length && !inside)
        [paths addObject:dbg];
    if ([paths isEqual:watched])
        return;
    if (stream) {
        FSEventStreamStop(stream);
        FSEventStreamInvalidate(stream);
        FSEventStreamRelease(stream);
    }
    watched = paths;
    FSEventStreamContext ctx = {};
    stream = FSEventStreamCreate(
        nullptr,
        [](ConstFSEventStreamRef, void*, size_t, void*, const FSEventStreamEventFlags*, const FSEventStreamEventId*) {
            dispatch_async(dispatch_get_main_queue(), ^{
                scan();
                scan_then(^{
                    chrome_reload_config();
                });
                shader_check();
                syntax_check();
                check_backends();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    check_backends();
                });
            });
        },
        &ctx, (__bridge CFArrayRef)paths, kFSEventStreamEventIdSinceNow, 0.05, kFSEventStreamCreateFlagNoDefer);
    FSEventStreamSetDispatchQueue(stream, dispatch_get_main_queue());
    g_watching = FSEventStreamStart(stream);
    if (!g_watching)
        rexui_log(@"ui: FSEvents didn't start: the docks' folder is scanned every second");
}

bool g_watching;

void scan_notify_init(void) {
    int token;
    notify_register_dispatch("com.rexui.scan", &token, dispatch_get_main_queue(), ^(int) {
        [choice() synchronize];
        scan();
        scan_then(^{
            chrome_reload_config();
        });
    });
}
