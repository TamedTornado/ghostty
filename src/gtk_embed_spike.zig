//! Minimal alternate GTK host used to drive the embedding extraction.
//!
//! This intentionally uses a plain GtkApplication rather than
//! GhosttyApplication. It is an executable integration probe, not a proposed
//! public API.

const std = @import("std");
const apprt = @import("apprt.zig");
const CoreApp = @import("App.zig");
const Surface = @import("apprt/gtk/class/surface.zig").Surface;
const gobject = @import("gobject");
const global = @import("global.zig");
const terminal = @import("terminal/main.zig");

const c = @import("adw_c");

const Host = struct {
    core_app: *CoreApp,
    runtime: *apprt.App,
    application: *c.GtkApplication,
    expected_surfaces: usize = 4,
    interaction: bool = false,
    window: ?*c.GtkWindow = null,
    surfaces: [16]?*Surface = .{null} ** 16,
    tick_source: c_uint = 0,
    default_is_plain_host: bool = false,
    surfaces_initialized: usize = 0,
    children_exited: usize = 0,
    tick_failed: bool = false,
    keyboard_sent: bool = false,
    keyboard_acknowledged: bool = false,
    clipboard_write: bool = false,
    clipboard_read: bool = false,
    clipboard_acknowledged: bool = false,
    progress_report: bool = false,
    focus_index: usize = 0,
    focus_confirmed: usize = 0,
    resize_width_before: c_int = 0,
    resize_requested: bool = false,
    resize_observed: bool = false,
    valid_content_scales: usize = 0,
    minimum_content_scale: f32 = 0,
};

pub fn main(minimal: std.process.Init.Minimal) !u8 {
    try global.init(.{ .main = minimal });
    defer global.deinit();
    if (c.g_getenv("GHOSTTY_EMBED_SPIKE_EPOLL") != null) {
        _ = global.xev.prefer(.epoll);
    }

    const core_app = try CoreApp.create(global.alloc());
    defer core_app.destroy();

    var runtime: apprt.App = undefined;
    try runtime.init(core_app, .{});
    defer runtime.terminate();

    const app = c.gtk_application_new(
        "com.tamedtornado.GhosttyEmbedSpike",
        c.G_APPLICATION_NON_UNIQUE,
    ) orelse return 1;

    var host: Host = .{
        .core_app = core_app,
        .runtime = &runtime,
        .application = app,
    };
    host.interaction = c.g_getenv("GHOSTTY_EMBED_SPIKE_INTERACTION") != null;
    if (c.g_getenv("GHOSTTY_EMBED_SPIKE_SURFACES")) |value| {
        const parsed = std.fmt.parseInt(usize, std.mem.span(value), 10) catch return 3;
        if (parsed == 0 or parsed > 16) return 3;
        host.expected_surfaces = parsed;
    }
    if (c.g_getenv("GHOSTTY_EMBED_MIN_SCALE")) |value| {
        host.minimum_content_scale = std.fmt.parseFloat(f32, std.mem.span(value)) catch return 3;
    }

    _ = c.g_signal_connect_data(
        app,
        "activate",
        @ptrCast(&activate),
        &host,
        null,
        0,
    );

    const result = c.g_application_run(@ptrCast(app), 0, null);
    c.g_object_unref(app);
    while (c.g_main_context_iteration(null, 0) != 0) {}

    if (!host.default_is_plain_host or
        host.surfaces_initialized != host.expected_surfaces or
        host.children_exited != host.expected_surfaces or
        host.tick_failed or
        (host.interaction and
            (!host.keyboard_sent or
                !host.keyboard_acknowledged or
                !host.clipboard_write or
                !host.clipboard_read or
                !host.clipboard_acknowledged or
                !host.progress_report or
                host.focus_confirmed != host.expected_surfaces or
                !host.resize_requested or
                !host.resize_observed or
                host.valid_content_scales != host.expected_surfaces)))
    {
        std.debug.print(
            "embed-spike: FAIL default_plain={} initialized={}/{} child_exited={}/{} tick_failed={} keyboard={}/{} clipboard={}/{}/{} progress={} focus={}/{} resize={}/{} scales={}/{}\n",
            .{
                host.default_is_plain_host,
                host.surfaces_initialized,
                host.expected_surfaces,
                host.children_exited,
                host.expected_surfaces,
                host.tick_failed,
                host.keyboard_sent,
                host.keyboard_acknowledged,
                host.clipboard_write,
                host.clipboard_read,
                host.clipboard_acknowledged,
                host.progress_report,
                host.focus_confirmed,
                host.expected_surfaces,
                host.resize_requested,
                host.resize_observed,
                host.valid_content_scales,
                host.expected_surfaces,
            },
        );
        return 2;
    }

    std.debug.print("embed-spike: PASS\n", .{});
    return @intCast(result);
}

fn activate(app: *c.GtkApplication, userdata: ?*anyopaque) callconv(.c) void {
    const host: *Host = @ptrCast(@alignCast(userdata orelse return));
    // Make the ownership boundary unambiguous: the host application is the
    // process default, while the Ghostty runtime passed to the surface is not.
    c.g_application_set_default(@ptrCast(app));
    host.default_is_plain_host = c.g_application_get_default() == @as(*c.GApplication, @ptrCast(app));
    std.debug.print("embed-spike: plain GtkApplication activated\n", .{});
    const window: *c.GtkWindow = @ptrCast(c.gtk_application_window_new(app));
    host.window = window;

    const box: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0));
    for (0..host.expected_surfaces) |i| {
        const surface = Surface.newWithApplication(host.runtime.app, .{
            .command = .{ .shell = if (!host.interaction)
                "printf ghostty-embed-pty; sleep 2"
            else switch (i) {
                0 => "value=$(dd bs=1 count=22 2>/dev/null); [ \"$value\" = ghostty-embed-keyboard ] || sleep 30; IFS= read -r blank; printf '\\033]2;ghostty-keyboard-ack\\a'; sleep 1",
                1 => "value=$(dd bs=1 count=23 2>/dev/null); if [ \"$value\" = ghostty-embed-clipboard ]; then printf '\\033]2;ghostty-clipboard-ack\\a'; else printf '\\033]2;ghostty-clipboard-fail\\a'; fi; sleep 1",
                2 => "trap 'exit 0' WINCH; while :; do sleep 1; done",
                3 => "printf '\\033]52;c;Z2hvc3R0eS1lbWJlZC1jbGlwYm9hcmQ=\\a\\033]9;4;1;73\\a'; sleep 2",
                else => "sleep 2",
            } },
            .title = "Embedded Ghostty surface",
        });
        host.surfaces[i] = surface;
        std.debug.print("embed-spike: GhosttySurface constructed index={}\n", .{i});

        _ = Surface.signals.init.connect(
            surface,
            *Host,
            surfaceInitialized,
            host,
            .{},
        );
        _ = gobject.Object.signals.notify.connect(
            surface,
            *Host,
            childExited,
            host,
            .{ .detail = "child-exited" },
        );
        if (host.interaction) {
            _ = gobject.Object.signals.notify.connect(
                surface,
                *Host,
                titleChanged,
                host,
                .{ .detail = "title" },
            );
        }
        if (host.interaction) {
            _ = Surface.signals.@"clipboard-write".connect(
                surface,
                *Host,
                clipboardWrite,
                host,
                .{},
            );
            _ = Surface.signals.@"clipboard-read".connect(
                surface,
                *Host,
                clipboardRead,
                host,
                .{},
            );
            _ = Surface.signals.@"progress-report".connect(
                surface,
                *Host,
                progressReport,
                host,
                .{},
            );
        }
        c.gtk_box_append(box, @ptrCast(surface));
    }

    c.gtk_window_set_title(window, "Ghostty GTK embed spike");
    c.gtk_window_set_default_size(window, 1000, 800);
    c.gtk_window_set_child(window, @ptrCast(box));
    c.gtk_window_present(window);

    host.tick_source = c.g_timeout_add(1, tick, host);
    _ = c.g_timeout_add(if (host.interaction) 6500 else 5000, quit, host);
}

fn surfaceInitialized(_: *Surface, host: *Host) callconv(.c) void {
    host.surfaces_initialized += 1;
    std.debug.print("embed-spike: core surface initialized count={}\n", .{host.surfaces_initialized});
    if (host.interaction and host.surfaces_initialized == host.expected_surfaces) {
        _ = c.g_timeout_add(100, sendKeyboard, host);
        _ = c.g_timeout_add(250, cycleFocus, host);
        _ = c.g_timeout_add(500, verifyContentScales, host);
        _ = c.g_timeout_add(1600, captureResizeWidth, host);
        _ = c.g_timeout_add(2000, requestResize, host);
        _ = c.g_timeout_add(2300, verifyResize, host);
    }
}

fn verifyContentScales(userdata: ?*anyopaque) callconv(.c) c_int {
    const host: *Host = @ptrCast(@alignCast(userdata orelse return 0));
    host.valid_content_scales = 0;
    for (host.surfaces[0..host.expected_surfaces]) |surface_| {
        const surface = surface_ orelse continue;
        const scale = surface.getContentScale();
        if (scale.x > 0 and scale.y > 0 and
            scale.x >= host.minimum_content_scale and
            scale.y >= host.minimum_content_scale) host.valid_content_scales += 1;
        std.debug.print("embed-spike: content scale x={d:.2} y={d:.2}\n", .{ scale.x, scale.y });
    }
    return 0;
}

fn sendKeyboard(userdata: ?*anyopaque) callconv(.c) c_int {
    const host: *Host = @ptrCast(@alignCast(userdata orelse return 0));
    const surface = host.surfaces[0] orelse return 0;
    const core = surface.core() orelse return 0;
    core.textCallback("ghostty-embed-keyboard") catch |err| {
        std.debug.print("embed-spike: keyboard injection failed: {}\n", .{err});
        return 0;
    };
    _ = core.keyCallback(.{ .key = .enter }) catch |err| {
        std.debug.print("embed-spike: enter key injection failed: {}\n", .{err});
        return 0;
    };
    host.keyboard_sent = true;
    std.debug.print("embed-spike: keyboard text sent\n", .{});
    return 0;
}

fn clipboardWrite(
    _: *Surface,
    clipboard_type: apprt.Clipboard,
    text: [*:0]const u8,
    host: *Host,
) callconv(.c) void {
    if (clipboard_type != .standard or
        !std.mem.eql(u8, std.mem.span(text), "ghostty-embed-clipboard")) return;
    host.clipboard_write = true;
    const reader = host.surfaces[1] orelse return;
    const started = reader.clipboardRequest(.standard, .paste) catch return;
    std.debug.print("embed-spike: clipboard write observed read_started={}\n", .{started});
}

fn clipboardRead(surface: *Surface, host: *Host) callconv(.c) void {
    host.clipboard_read = true;
    if (surface.core()) |core| {
        _ = core.keyCallback(.{ .key = .enter }) catch |err| {
            std.debug.print("embed-spike: clipboard enter injection failed: {}\n", .{err});
        };
    }
    std.debug.print("embed-spike: clipboard read observed\n", .{});
}

fn progressReport(
    surface: *Surface,
    state: c_int,
    progress: c_int,
    host: *Host,
) callconv(.c) void {
    if (surface != host.surfaces[3] or
        state != @intFromEnum(terminal.osc.Command.ProgressReport.State.set) or
        progress != 73) return;
    host.progress_report = true;
    std.debug.print("embed-spike: progress report observed state={} progress={}\n", .{ state, progress });
}

fn titleChanged(surface: *Surface, _: *gobject.ParamSpec, host: *Host) callconv(.c) void {
    const title = surface.getTitle() orelse return;
    if (surface == host.surfaces[0] and std.mem.eql(u8, title, "ghostty-keyboard-ack")) {
        host.keyboard_acknowledged = true;
        std.debug.print("embed-spike: keyboard input acknowledged by child\n", .{});
    } else if (surface == host.surfaces[1] and std.mem.eql(u8, title, "ghostty-clipboard-ack")) {
        host.clipboard_acknowledged = true;
        std.debug.print("embed-spike: clipboard paste acknowledged by child\n", .{});
    } else if (surface == host.surfaces[1] and std.mem.eql(u8, title, "ghostty-clipboard-fail")) {
        std.debug.print("embed-spike: clipboard paste rejected by child\n", .{});
    }
}

fn cycleFocus(userdata: ?*anyopaque) callconv(.c) c_int {
    const host: *Host = @ptrCast(@alignCast(userdata orelse return 0));
    if (host.focus_index > 0) {
        const prior = host.surfaces[host.focus_index - 1] orelse return 0;
        if (!prior.getFocused()) {
            prior.grabFocus();
            return 1;
        }
        host.focus_confirmed += 1;
    }
    if (host.focus_index == host.expected_surfaces) {
        std.debug.print("embed-spike: focus transitions confirmed={}\n", .{host.focus_confirmed});
        return 0;
    }
    const surface = host.surfaces[host.focus_index] orelse return 0;
    surface.grabFocus();
    host.focus_index += 1;
    return 1;
}

fn captureResizeWidth(userdata: ?*anyopaque) callconv(.c) c_int {
    const host: *Host = @ptrCast(@alignCast(userdata orelse return 0));
    const surface = host.surfaces[2] orelse return 0;
    host.resize_width_before = c.gtk_widget_get_width(@ptrCast(surface));
    return 0;
}

fn requestResize(userdata: ?*anyopaque) callconv(.c) c_int {
    const host: *Host = @ptrCast(@alignCast(userdata orelse return 0));
    const window = host.window orelse return 0;
    c.gtk_window_set_default_size(window, 1200, 950);
    host.resize_requested = true;
    return 0;
}

fn verifyResize(userdata: ?*anyopaque) callconv(.c) c_int {
    const host: *Host = @ptrCast(@alignCast(userdata orelse return 0));
    const surface = host.surfaces[2] orelse return 0;
    const width = c.gtk_widget_get_width(@ptrCast(surface));
    host.resize_observed = host.resize_width_before > 0 and width != host.resize_width_before;
    std.debug.print("embed-spike: resize width {} -> {} observed={}\n", .{
        host.resize_width_before,
        width,
        host.resize_observed,
    });
    return @intFromBool(!host.resize_observed);
}

fn childExited(
    _: *Surface,
    _: *gobject.ParamSpec,
    host: *Host,
) callconv(.c) void {
    host.children_exited += 1;
    std.debug.print("embed-spike: child-exited observed count={}\n", .{host.children_exited});
}

fn tick(userdata: ?*anyopaque) callconv(.c) c_int {
    const host: *Host = @ptrCast(@alignCast(userdata orelse return 0));
    host.core_app.tick(host.runtime) catch |err| {
        host.tick_failed = true;
        std.debug.print("embed-spike: core tick failed: {}\n", .{err});
        return 0;
    };
    return 1;
}

fn quit(userdata: ?*anyopaque) callconv(.c) c_int {
    const host: *Host = @ptrCast(@alignCast(userdata orelse return 0));
    std.debug.print("embed-spike: timed shutdown\n", .{});
    if (host.tick_source != 0) {
        _ = c.g_source_remove(host.tick_source);
        host.tick_source = 0;
    }
    if (host.window) |window| {
        c.gtk_window_destroy(window);
        host.window = null;
    }
    c.g_application_quit(@ptrCast(host.application));
    return 0;
}
