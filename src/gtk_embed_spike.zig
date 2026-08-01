//! Minimal alternate GTK host used to drive the embedding extraction.
//!
//! This intentionally uses a plain GtkApplication rather than
//! GhosttyApplication. It is an executable integration probe, not a proposed
//! public API.

const Surface = @import("apprt/gtk/class/surface.zig").Surface;
const std = @import("std");

const c = @cImport({
    @cInclude("adwaita.h");
    @cInclude("gtk/gtk.h");
});

pub fn main() u8 {
    const app = c.gtk_application_new(
        "com.tamedtornado.GhosttyEmbedSpike",
        c.G_APPLICATION_NON_UNIQUE,
    ) orelse return 1;
    defer c.g_object_unref(app);

    _ = c.g_signal_connect_data(
        app,
        "activate",
        @ptrCast(&activate),
        null,
        null,
        0,
    );

    return @intCast(c.g_application_run(@ptrCast(app), 0, null));
}

fn activate(app: *c.GtkApplication, _: ?*anyopaque) callconv(.c) void {
    std.debug.print("embed-spike: plain GtkApplication activated\n", .{});
    const window = c.gtk_application_window_new(app);
    const surface = Surface.new(.none);
    std.debug.print("embed-spike: GhosttySurface constructed\n", .{});

    c.gtk_window_set_title(@ptrCast(window), "Ghostty GTK embed spike");
    c.gtk_window_set_default_size(@ptrCast(window), 800, 600);
    c.gtk_window_set_child(@ptrCast(window), @ptrCast(surface));
    c.gtk_window_present(@ptrCast(window));
    _ = c.g_timeout_add(3000, quit, app);
}

fn quit(app: ?*anyopaque) callconv(.c) c_int {
    std.debug.print("embed-spike: timed shutdown\n", .{});
    c.g_application_quit(@ptrCast(@alignCast(app)));
    return c.G_SOURCE_REMOVE;
}
