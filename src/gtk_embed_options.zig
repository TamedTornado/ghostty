const std = @import("std");

pub const SurfaceOptions = extern struct {
    struct_size: usize,
    command: ?[*:0]const u8,
    title: ?[*:0]const u8,
    working_directory: ?[*:0]const u8,
    environment: ?[*]const ?[*:0]const u8,
    environment_count: usize,
};

pub fn valid(options: *const SurfaceOptions) bool {
    return options.struct_size >= @offsetOf(SurfaceOptions, "environment");
}

pub fn environment(options: *const SurfaceOptions) ?[]const ?[*:0]const u8 {
    if (!valid(options)) return null;
    if (options.struct_size < @sizeOf(SurfaceOptions)) return &.{};
    if (options.environment_count > 128) return null;
    if (options.environment_count == 0) return &.{};
    const entries = (options.environment orelse return null)[0..options.environment_count];
    for (entries) |entry| {
        const value = std.mem.span(entry orelse return null);
        const equals = std.mem.indexOfScalar(u8, value, '=') orelse return null;
        if (equals == 0) return null;
    }
    return entries;
}

test "surface options reject truncated ABI and accept current layout" {
    var options: SurfaceOptions = .{
        .struct_size = @sizeOf(SurfaceOptions),
        .command = null,
        .title = null,
        .working_directory = "/tmp",
        .environment = null,
        .environment_count = 0,
    };
    try std.testing.expect(valid(&options));
    options.struct_size = @offsetOf(SurfaceOptions, "working_directory");
    try std.testing.expect(!valid(&options));
}

test "surface options preserve old ABI and validate environment extension" {
    var entries = [_]?[*:0]const u8{ "ZENTTY_PANE_ID=pane-a", "ZENTTY_PANE_TOKEN=secret" };
    var options: SurfaceOptions = .{
        .struct_size = @sizeOf(SurfaceOptions),
        .command = null,
        .title = null,
        .working_directory = null,
        .environment = &entries,
        .environment_count = entries.len,
    };
    try std.testing.expectEqual(@as(usize, 2), environment(&options).?.len);
    options.struct_size = @offsetOf(SurfaceOptions, "environment");
    try std.testing.expect(valid(&options));
    try std.testing.expectEqual(@as(usize, 0), environment(&options).?.len);
    options.struct_size = @sizeOf(SurfaceOptions);
    options.environment_count = 129;
    try std.testing.expect(environment(&options) == null);
    options.environment_count = 1;
    entries[0] = "missing-equals";
    try std.testing.expect(environment(&options) == null);
    entries[0] = null;
    try std.testing.expect(environment(&options) == null);
    options.environment = null;
    try std.testing.expect(environment(&options) == null);
}
