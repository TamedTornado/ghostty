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
const state = &global.state;

const c = @cImport({
    @cInclude("adwaita.h");
    @cInclude("gtk/gtk.h");
});

const Host = struct {
    core_app: *CoreApp,
    runtime: *apprt.App,
    application: *c.GtkApplication,
    expected_surfaces: usize = 4,
    window: ?*c.GtkWindow = null,
    tick_source: c_uint = 0,
    default_is_plain_host: bool = false,
    surfaces_initialized: usize = 0,
    children_exited: usize = 0,
    tick_failed: bool = false,
};

pub fn main() !u8 {
    try state.init();
    defer state.deinit();
    if (c.g_getenv("GHOSTTY_EMBED_SPIKE_EPOLL") != null) {
        _ = global.xev.prefer(.epoll);
    }

    const core_app = try CoreApp.create(state.alloc);
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
    if (c.g_getenv("GHOSTTY_EMBED_SPIKE_SURFACES")) |value| {
        const parsed = std.fmt.parseInt(usize, std.mem.span(value), 10) catch return 3;
        if (parsed == 0 or parsed > 16) return 3;
        host.expected_surfaces = parsed;
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
        host.tick_failed)
    {
        std.debug.print(
            "embed-spike: FAIL default_plain={} initialized={}/{} child_exited={}/{} tick_failed={}\n",
            .{
                host.default_is_plain_host,
                host.surfaces_initialized,
                host.expected_surfaces,
                host.children_exited,
                host.expected_surfaces,
                host.tick_failed,
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
            .command = .{ .shell = "printf ghostty-embed-pty; sleep 2" },
            .title = "Embedded Ghostty surface",
        });
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
        c.gtk_box_append(box, @ptrCast(surface));
    }

    c.gtk_window_set_title(window, "Ghostty GTK embed spike");
    c.gtk_window_set_default_size(window, 1000, 800);
    c.gtk_window_set_child(window, @ptrCast(box));
    c.gtk_window_present(window);

    host.tick_source = c.g_timeout_add(1, tick, host);
    _ = c.g_timeout_add(5000, quit, host);
}

fn surfaceInitialized(_: *Surface, host: *Host) callconv(.c) void {
    host.surfaces_initialized += 1;
    std.debug.print("embed-spike: core surface initialized count={}\n", .{host.surfaces_initialized});
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
