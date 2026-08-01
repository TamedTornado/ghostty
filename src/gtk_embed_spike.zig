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
const state = &@import("global.zig").state;

const c = @cImport({
    @cInclude("adwaita.h");
    @cInclude("gtk/gtk.h");
});

const Host = struct {
    core_app: *CoreApp,
    runtime: *apprt.App,
    application: *c.GtkApplication,
    window: ?*c.GtkWindow = null,
    tick_source: c_uint = 0,
    default_is_plain_host: bool = false,
    surface_initialized: bool = false,
    child_exited: bool = false,
    tick_failed: bool = false,
};

pub fn main() !u8 {
    try state.init();
    defer state.deinit();

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
        !host.surface_initialized or
        !host.child_exited or
        host.tick_failed)
    {
        std.debug.print(
            "embed-spike: FAIL default_plain={} initialized={} child_exited={} tick_failed={}\n",
            .{
                host.default_is_plain_host,
                host.surface_initialized,
                host.child_exited,
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

    const surface = Surface.newWithApplication(host.runtime.app, .{
        .command = .{ .shell = "printf ghostty-embed-pty; sleep 2" },
        .title = "Embedded Ghostty surface",
    });
    std.debug.print("embed-spike: GhosttySurface constructed\n", .{});

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

    c.gtk_window_set_title(window, "Ghostty GTK embed spike");
    c.gtk_window_set_default_size(window, 800, 600);
    c.gtk_window_set_child(window, @ptrCast(surface));
    c.gtk_window_present(window);

    host.tick_source = c.g_timeout_add(1, tick, host);
    _ = c.g_timeout_add(5000, quit, host);
}

fn surfaceInitialized(_: *Surface, host: *Host) callconv(.c) void {
    host.surface_initialized = true;
    std.debug.print("embed-spike: core surface initialized\n", .{});
}

fn childExited(
    _: *Surface,
    _: *gobject.ParamSpec,
    host: *Host,
) callconv(.c) void {
    host.child_exited = true;
    std.debug.print("embed-spike: child-exited observed\n", .{});
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
