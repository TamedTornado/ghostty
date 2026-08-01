//! Minimal alternate GTK host used to drive the embedding extraction.
//!
//! This intentionally uses a plain GtkApplication rather than
//! GhosttyApplication. It is an executable integration probe, not a proposed
//! public API.

const std = @import("std");
const apprt = @import("apprt.zig");
const CoreApp = @import("App.zig");
const Surface = @import("apprt/gtk/class/surface.zig").Surface;
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
    return @intCast(result);
}

fn activate(app: *c.GtkApplication, userdata: ?*anyopaque) callconv(.c) void {
    const host: *Host = @ptrCast(@alignCast(userdata orelse return));
    std.debug.print("embed-spike: plain GtkApplication activated\n", .{});
    const window: *c.GtkWindow = @ptrCast(c.gtk_application_window_new(app));
    host.window = window;

    const surface = Surface.newWithApplication(host.runtime.app, .{
        .command = .{ .shell = "printf ghostty-embed-pty; sleep 2" },
        .title = "Embedded Ghostty surface",
    });
    std.debug.print("embed-spike: GhosttySurface constructed\n", .{});

    c.gtk_window_set_title(window, "Ghostty GTK embed spike");
    c.gtk_window_set_default_size(window, 800, 600);
    c.gtk_window_set_child(window, @ptrCast(surface));
    c.gtk_window_present(window);

    host.tick_source = c.g_timeout_add(1, tick, host);
    _ = c.g_timeout_add(5000, quit, host);
}

fn tick(userdata: ?*anyopaque) callconv(.c) c_int {
    const host: *Host = @ptrCast(@alignCast(userdata orelse return 0));
    host.core_app.tick(host.runtime) catch |err| {
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
