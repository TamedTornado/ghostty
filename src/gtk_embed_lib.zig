//! Experimental GTK embedding boundary for non-Ghostty applications.
//!
//! The C exports intentionally keep Ghostty and Zig implementation details
//! opaque. The host owns the GTK application and widgets; this runtime owns
//! the Ghostty core that backs each returned GhosttySurface.

const std = @import("std");
const apprt = @import("apprt.zig");
const CoreApp = @import("App.zig");
const gobject = @import("gobject");
const Surface = @import("apprt/gtk/class/surface.zig").Surface;
const Binding = @import("input/Binding.zig");
const global = @import("global.zig");
const xev = global.xev;

const AsyncBackend = enum(c_int) {
    default = 0,
    epoll = 1,
    io_uring = 2,
};

var active_runtime: ?*Runtime = null;
var runtime_was_created = false;
var embed_argv = [_][*:0]u8{@constCast("ghostty-gtk-embed")};

pub const Runtime = struct {
    core_app: *CoreApp,
    apprt_app: apprt.App,

    pub fn create(async_backend: AsyncBackend) !*Runtime {
        try global.init(.{ .c = .{
            .argc = embed_argv.len,
            .argv = &embed_argv,
            .environ = .{ .block = .{ .slice = std.c.environ[0..environmentLength() :null] } },
        } });
        errdefer global.deinit();

        const backend_available = switch (async_backend) {
            .default => true,
            .epoll => if (comptime xev.dynamic) xev.prefer(.epoll) else false,
            .io_uring => if (comptime xev.dynamic) xev.prefer(.io_uring) else false,
        };
        if (!backend_available) return error.AsyncBackendUnavailable;

        const self = try std.heap.c_allocator.create(Runtime);
        errdefer std.heap.c_allocator.destroy(self);

        const core_app = try CoreApp.create(global.alloc());
        errdefer core_app.destroy();

        self.* = .{
            .core_app = core_app,
            .apprt_app = undefined,
        };
        try self.apprt_app.init(core_app, .{});
        return self;
    }

    pub fn destroy(self: *Runtime) void {
        self.apprt_app.terminate();
        self.core_app.destroy();
        global.deinit();
        std.heap.c_allocator.destroy(self);
    }

    pub fn tick(self: *Runtime) !void {
        try self.core_app.tick(&self.apprt_app);
    }

    pub fn newSurface(
        self: *Runtime,
        command: ?[:0]const u8,
        title: ?[:0]const u8,
    ) *Surface {
        return Surface.newWithApplication(self.apprt_app.app, .{
            .command = if (command) |value| .{ .shell = value } else null,
            .title = title,
        });
    }
};

export fn ghostty_gtk_embed_runtime_new() ?*Runtime {
    return createRuntime(.default);
}

export fn ghostty_gtk_embed_runtime_new_with_async_backend(
    backend: c_int,
) ?*Runtime {
    const value = std.enums.fromInt(AsyncBackend, backend) orelse return null;
    return createRuntime(value);
}

fn createRuntime(async_backend: AsyncBackend) ?*Runtime {
    if (runtime_was_created) return null;
    const runtime = Runtime.create(async_backend) catch |err| {
        std.log.err("failed to initialize GTK embedding runtime err={}", .{err});
        return null;
    };
    active_runtime = runtime;
    runtime_was_created = true;
    return runtime;
}

fn environmentLength() usize {
    var len: usize = 0;
    while (std.c.environ[len]) |_| : (len += 1) {}
    return len;
}

export fn ghostty_gtk_embed_runtime_free(runtime: ?*Runtime) void {
    const value = runtime orelse return;
    if (active_runtime != value) return;
    active_runtime = null;
    value.destroy();
}

export fn ghostty_gtk_embed_runtime_tick(runtime: ?*Runtime) bool {
    const value = runtime orelse return false;
    if (active_runtime != value) return false;
    value.tick() catch |err| {
        std.log.err("GTK embedding runtime tick failed err={}", .{err});
        return false;
    };
    return true;
}

export fn ghostty_gtk_embed_surface_new(
    runtime: ?*Runtime,
    command: ?[*:0]const u8,
    title: ?[*:0]const u8,
) ?*anyopaque {
    const value = runtime orelse return null;
    if (active_runtime != value) return null;
    return @ptrCast(value.newSurface(
        if (command) |v| std.mem.span(v) else null,
        if (title) |v| std.mem.span(v) else null,
    ));
}

export fn ghostty_gtk_embed_surface_grab_focus(surface: ?*anyopaque) void {
    const value = getSurface(surface) orelse return;
    value.grabFocus();
}

export fn ghostty_gtk_embed_surface_close(surface: ?*anyopaque) bool {
    const value = getSurface(surface) orelse return false;
    value.deinitCore();
    return true;
}

export fn ghostty_gtk_embed_surface_send_text(
    surface: ?*anyopaque,
    text: ?[*:0]const u8,
) bool {
    const value = getSurface(surface) orelse return false;
    const core = value.core() orelse return false;
    const input = std.mem.span(text orelse return false);
    core.textCallback(input) catch return false;
    return true;
}

/// Parses and invokes one of Ghostty's public binding actions on an embedded
/// terminal surface. This keeps host applications on the same command path as
/// Ghostty's own keybindings instead of duplicating terminal behavior.
export fn ghostty_gtk_embed_surface_binding_action(
    surface: ?*anyopaque,
    action_ptr: ?[*]const u8,
    action_len: usize,
) bool {
    const value = getSurface(surface) orelse return false;
    const core = value.core() orelse return false;
    const ptr = action_ptr orelse return false;
    const action_text = ptr[0..action_len];
    const action = Binding.Action.parse(action_text) catch return false;
    return core.performBindingAction(action) catch false;
}

export fn ghostty_gtk_embed_surface_request_paste(
    surface: ?*anyopaque,
) bool {
    const value = getSurface(surface) orelse return false;
    return value.clipboardRequest(.standard, .paste) catch false;
}

fn getSurface(surface: ?*anyopaque) ?*Surface {
    const instance: *gobject.TypeInstance = @ptrCast(@alignCast(
        surface orelse return null,
    ));
    return gobject.ext.cast(Surface, instance);
}
