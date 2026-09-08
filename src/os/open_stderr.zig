//! Bounded stderr records from the platform URL opener.
const std = @import("std");

pub fn next(reader: *std.Io.Reader) error{ReadFailed}!?[]u8 {
    // Exclusive leaves the newline unread and will return an empty record
    // forever. takeDelimiter consumes it and returns null at actual EOF.
    return reader.takeDelimiter('\n') catch |outer| switch (outer) {
        error.ReadFailed => error.ReadFailed,
        error.StreamTooLong => reader.take(reader.buffer.len) catch |inner| switch (inner) {
            error.ReadFailed => error.ReadFailed,
            error.EndOfStream => null,
        },
    };
}

test "opener stderr consumes delimiters and reaches EOF" {
    var reader = std.Io.Reader.fixed("first\n\nlast\n");
    try std.testing.expectEqualStrings("first", (try next(&reader)).?);
    try std.testing.expectEqualStrings("", (try next(&reader)).?);
    try std.testing.expectEqualStrings("last", (try next(&reader)).?);
    try std.testing.expectEqual(null, try next(&reader));
}

test "opener stderr empty and unterminated streams" {
    var empty = std.Io.Reader.fixed("");
    try std.testing.expectEqual(null, try next(&empty));
    var tail = std.Io.Reader.fixed("last without newline");
    try std.testing.expectEqualStrings("last without newline", (try next(&tail)).?);
    try std.testing.expectEqual(null, try next(&tail));
}

test "opener stderr real child pipe stays bounded and is reaped" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    // A real child writes more than one reader buffer, blank lines, and a
    // trailing partial line. No browser or desktop opener is launched.
    for (0..3) |_| {
        var child = try std.process.spawn(io, .{
            .argv = &.{ "/bin/sh", "-c", "printf 'first\\n\\n' >&2; i=0; while [ $i -lt 600 ]; do printf x >&2; i=$((i+1)); done; printf '\\nlast' >&2" },
            .stdout = .ignore,
            .stderr = .pipe,
        });
        defer child.kill(io);
        var buffer: [256]u8 = undefined;
        var stream = child.stderr.?.readerStreaming(io, &buffer);
        const reader = &stream.interface;
        try std.testing.expectEqualStrings("first", (try next(reader)).?);
        try std.testing.expectEqualStrings("", (try next(reader)).?);
        var payload: [604]u8 = undefined;
        var used: usize = 0;
        var chunks: usize = 0;
        while (try next(reader)) |chunk| {
            chunks += 1;
            // Fail promptly on non-progress; never hang the regression on the
            // very bug it is intended to detect.
            try std.testing.expect(chunks <= 5);
            try std.testing.expect(chunk.len <= buffer.len);
            try std.testing.expect(used + chunk.len <= payload.len);
            @memcpy(payload[used..][0..chunk.len], chunk);
            used += chunk.len;
        }
        try std.testing.expectEqual(payload.len, used);
        try std.testing.expectEqualStrings("x" ** 600 ++ "last", &payload);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
    }
}
