//! Experimental GTK embedding boundary for non-Ghostty applications.
//!
//! The C exports intentionally keep Ghostty and Zig implementation details
//! opaque. The host owns the GTK application and widgets; this runtime owns
//! the Ghostty core that backs each returned GhosttySurface.

const std = @import("std");
const apprt = @import("apprt.zig");
const CoreApp = @import("App.zig");
const gobject = @import("gobject");
const gtk = @import("gtk");
const Surface = @import("apprt/gtk/class/surface.zig").Surface;
const Binding = @import("input/Binding.zig");
const global = @import("global.zig");
const terminal = @import("terminal/main.zig");
const xev = global.xev;
const surface_options = @import("gtk_embed_options.zig");

const AsyncBackend = enum(c_int) {
    default = 0,
    epoll = 1,
    io_uring = 2,
};

const TextExtent = enum(u32) {
    viewport = 0,
    screen = 1,
};

const TextCallback = *const fn ([*]const u8, usize, ?*anyopaque) callconv(.c) void;

const CellSize = extern struct {
    width: f64,
    height: f64,
};

const SurfaceOptions = surface_options.SurfaceOptions;

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
        working_directory: ?[:0]const u8,
        environment: []const ?[*:0]const u8,
    ) *Surface {
        var environment_spans: [128][:0]const u8 = undefined;
        for (environment, 0..) |entry, index| {
            environment_spans[index] = std.mem.span(entry.?);
        }
        return Surface.newWithApplication(self.apprt_app.app, .{
            .command = if (command) |value| .{ .shell = value } else null,
            .title = title,
            .working_directory = working_directory,
            .environment = environment_spans[0..environment.len],
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
    if (gtk.isInitialized() != 0) {
        std.log.err("GTK embedding runtime must be created before GTK initialization", .{});
        return null;
    }
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
        null,
        &.{},
    ));
}

export fn ghostty_gtk_embed_surface_new_with_options(
    runtime: ?*Runtime,
    options: ?*const SurfaceOptions,
) ?*anyopaque {
    const value = runtime orelse return null;
    if (active_runtime != value) return null;
    const opts = options orelse return null;
    const environment = surface_options.environment(opts) orelse return null;
    return @ptrCast(value.newSurface(
        if (opts.command) |v| std.mem.span(v) else null,
        if (opts.title) |v| std.mem.span(v) else null,
        if (opts.working_directory) |v| std.mem.span(v) else null,
        environment,
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

export fn ghostty_gtk_embed_surface_cell_size(
    surface: ?*anyopaque,
    output: ?*CellSize,
) bool {
    const value = getSurface(surface) orelse return false;
    const core = value.core() orelse return false;
    const result = output orelse return false;
    const size = core.size.cell;
    if (size.width == 0 or size.height == 0) return false;
    const scale = value.getContentScale();
    if (scale.x <= 0 or scale.y <= 0) return false;
    result.* = .{
        .width = @as(f64, @floatFromInt(size.width)) / scale.x,
        .height = @as(f64, @floatFromInt(size.height)) / scale.y,
    };
    return true;
}

export fn ghostty_gtk_embed_surface_read_text(
    surface: ?*anyopaque,
    extent_raw: u32,
    callback: ?TextCallback,
    userdata: ?*anyopaque,
) bool {
    const value = getSurface(surface) orelse return false;
    const core = value.core() orelse return false;
    const extent = std.enums.fromInt(TextExtent, extent_raw) orelse return false;
    const invoke = callback orelse return false;

    var text = text: {
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        break :text readTextLocked(core, extent) catch return false;
    };
    defer text.deinit(global.alloc());

    invoke(text.text.ptr, text.text.len, userdata);
    return true;
}

export fn ghostty_gtk_embed_surface_read_selection(
    surface: ?*anyopaque,
    callback: ?TextCallback,
    userdata: ?*anyopaque,
) bool {
    const value = getSurface(surface) orelse return false;
    const core = value.core() orelse return false;
    const invoke = callback orelse return false;
    const text = (core.selectionString(global.alloc()) catch return false) orelse return false;
    defer global.alloc().free(text);
    invoke(text.ptr, text.len, userdata);
    return true;
}

fn readTextLocked(
    core: *@import("Surface.zig"),
    extent: TextExtent,
) !@import("Surface.zig").Text {
    const screen = core.io.terminal.screens.active;
    const tag: terminal.point.Tag = switch (extent) {
        .viewport => .viewport,
        .screen => .screen,
    };
    const selection: terminal.Selection = .{
        .bounds = .{ .untracked = .{
            .start = screen.pages.getTopLeft(tag),
            .end = screen.pages.getBottomRight(tag) orelse return error.EmptyScreen,
        } },
        .rectangle = false,
    };
    return core.dumpTextLocked(global.alloc(), selection);
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
