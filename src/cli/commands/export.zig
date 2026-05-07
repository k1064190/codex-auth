const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .export_auth } };
    }

    for (args) |raw_arg| {
        const arg = std.mem.sliceTo(raw_arg, 0);
        if (common.isHelpFlag(arg)) {
            return common.usageErrorResult(allocator, .export_auth, "`--help` must be used by itself for `export`.", .{});
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            return common.usageErrorResult(allocator, .export_auth, "unknown flag `{s}` for `export`.", .{arg});
        }
    }

    if (args.len > 1) {
        return common.usageErrorResult(allocator, .export_auth, "unexpected extra path `{s}` for `export`.", .{std.mem.sliceTo(args[1], 0)});
    }
    if (args.len == 0) {
        return common.usageErrorResult(allocator, .export_auth, "`export` requires a path.", .{});
    }

    const path = try allocator.dupe(u8, std.mem.sliceTo(args[0], 0));
    return .{ .command = .{ .export_auth = .{ .path = path } } };
}
