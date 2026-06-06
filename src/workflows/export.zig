const std = @import("std");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");

pub fn handleExport(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.ExportOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }

    const count = try registry.exportBundle(allocator, codex_home, &reg, opts.path);
    try cli.output.printExportSummary(count, opts.path);
}
