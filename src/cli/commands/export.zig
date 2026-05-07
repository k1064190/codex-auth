const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .export_auth } };
    }

    var export_path: ?[]u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.sliceTo(args[i], 0);
        if (common.isHelpFlag(arg)) {
            if (export_path) |path| allocator.free(path);
            return common.usageErrorResult(allocator, .export_auth, "`--help` must be used by itself for `export`.", .{});
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            if (export_path) |path| allocator.free(path);
            return common.usageErrorResult(allocator, .export_auth, "unknown flag `{s}` for `export`.", .{arg});
        }
        if (export_path != null) {
            if (export_path) |path| allocator.free(path);
            return common.usageErrorResult(allocator, .export_auth, "unexpected extra path `{s}` for `export`.", .{arg});
        }
        export_path = try allocator.dupe(u8, arg);
    }

    const path = export_path orelse {
        return common.usageErrorResult(allocator, .export_auth, "`export` requires a path.", .{});
    };
    return .{ .command = .{ .export_auth = .{ .path = path } } };
}
