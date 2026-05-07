const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .import_auth } };
    }

    var auth_path: ?[]u8 = null;
    var alias: ?[]u8 = null;
    var purge = false;
    var replace = false;
    var source: types.ImportSource = .standard;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.sliceTo(args[i], 0);
        if (std.mem.eql(u8, arg, "--alias")) {
            if (i + 1 >= args.len) {
                common.freeImportOptions(allocator, auth_path, alias);
                return common.usageErrorResult(allocator, .import_auth, "missing value for `--alias`.", .{});
            }
            if (alias != null) {
                common.freeImportOptions(allocator, auth_path, alias);
                return common.usageErrorResult(allocator, .import_auth, "duplicate `--alias` for `import`.", .{});
            }
            alias = try allocator.dupe(u8, std.mem.sliceTo(args[i + 1], 0));
            i += 1;
        } else if (std.mem.eql(u8, arg, "--purge")) {
            if (purge) {
                common.freeImportOptions(allocator, auth_path, alias);
                return common.usageErrorResult(allocator, .import_auth, "duplicate `--purge` for `import`.", .{});
            }
            purge = true;
        } else if (std.mem.eql(u8, arg, "--cpa")) {
            if (source == .cpa) {
                common.freeImportOptions(allocator, auth_path, alias);
                return common.usageErrorResult(allocator, .import_auth, "duplicate `--cpa` for `import`.", .{});
            }
            if (source == .bundle) {
                common.freeImportOptions(allocator, auth_path, alias);
                return common.usageErrorResult(allocator, .import_auth, "`--cpa` cannot be combined with `--bundle`.", .{});
            }
            source = .cpa;
        } else if (std.mem.eql(u8, arg, "--bundle")) {
            if (source == .bundle) {
                common.freeImportOptions(allocator, auth_path, alias);
                return common.usageErrorResult(allocator, .import_auth, "duplicate `--bundle` for `import`.", .{});
            }
            if (source == .cpa) {
                common.freeImportOptions(allocator, auth_path, alias);
                return common.usageErrorResult(allocator, .import_auth, "`--bundle` cannot be combined with `--cpa`.", .{});
            }
            source = .bundle;
        } else if (std.mem.eql(u8, arg, "--replace")) {
            if (replace) {
                common.freeImportOptions(allocator, auth_path, alias);
                return common.usageErrorResult(allocator, .import_auth, "duplicate `--replace` for `import`.", .{});
            }
            replace = true;
        } else if (common.isHelpFlag(arg)) {
            common.freeImportOptions(allocator, auth_path, alias);
            return common.usageErrorResult(allocator, .import_auth, "`--help` must be used by itself for `import`.", .{});
        } else if (std.mem.startsWith(u8, arg, "-")) {
            common.freeImportOptions(allocator, auth_path, alias);
            return common.usageErrorResult(allocator, .import_auth, "unknown flag `{s}` for `import`.", .{arg});
        } else {
            if (auth_path != null) {
                common.freeImportOptions(allocator, auth_path, alias);
                return common.usageErrorResult(allocator, .import_auth, "unexpected extra path `{s}` for `import`.", .{arg});
            }
            auth_path = try allocator.dupe(u8, arg);
        }
    }
    if (purge and source == .cpa) {
        common.freeImportOptions(allocator, auth_path, alias);
        return common.usageErrorResult(allocator, .import_auth, "`--purge` cannot be combined with `--cpa`.", .{});
    }
    if (purge and source == .bundle) {
        common.freeImportOptions(allocator, auth_path, alias);
        return common.usageErrorResult(allocator, .import_auth, "`--purge` cannot be combined with `--bundle`.", .{});
    }
    if (source == .bundle and alias != null) {
        common.freeImportOptions(allocator, auth_path, alias);
        return common.usageErrorResult(allocator, .import_auth, "`--alias` cannot be combined with `--bundle`.", .{});
    }
    if (replace and source != .bundle) {
        common.freeImportOptions(allocator, auth_path, alias);
        return common.usageErrorResult(allocator, .import_auth, "`--replace` can only be used with `--bundle`.", .{});
    }
    if (source == .bundle and auth_path == null) {
        common.freeImportOptions(allocator, auth_path, alias);
        return common.usageErrorResult(allocator, .import_auth, "`import --bundle` requires a path.", .{});
    }
    if (auth_path == null and !purge and source == .standard) {
        common.freeImportOptions(allocator, auth_path, alias);
        return common.usageErrorResult(allocator, .import_auth, "`import` requires a path unless `--purge` or `--cpa` is used.", .{});
    }
    return .{ .command = .{ .import_auth = .{
        .auth_path = auth_path,
        .alias = alias,
        .purge = purge,
        .replace = replace,
        .source = source,
    } } };
}
