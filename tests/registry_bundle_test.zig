const std = @import("std");
const fs = @import("codex_auth").core.compat_fs;
const registry = @import("codex_auth").registry;
const fixtures = @import("support/fixtures.zig");

fn writeAccountSnapshot(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    email: []const u8,
    auth_json: []const u8,
) !void {
    const account_key = try fixtures.accountKeyForEmailAlloc(allocator, email);
    defer allocator.free(account_key);
    const auth_path = try registry.accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(auth_path);
    try fs.cwd().writeFile(.{ .sub_path = auth_path, .data = auth_json });
}

fn seedBundleSource(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
) !void {
    const accounts_dir = try fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts" });
    defer allocator.free(accounts_dir);
    try fs.cwd().makePath(accounts_dir);

    var reg = fixtures.makeEmptyRegistry();
    defer reg.deinit(allocator);
    reg.auto_switch.enabled = true;
    reg.auto_switch.threshold_5h_percent = 12;
    reg.api.usage = false;
    reg.live.interval_seconds = 45;
    try fixtures.appendAccount(allocator, &reg, "alpha@example.com", "work", .pro);
    try fixtures.appendAccount(allocator, &reg, "beta@example.com", "team", .team);

    const alpha_key = try fixtures.accountKeyForEmailAlloc(allocator, "alpha@example.com");
    defer allocator.free(alpha_key);
    try registry.setActiveAccountKey(allocator, &reg, alpha_key);
    try registry.saveRegistry(allocator, codex_home, &reg);

    const alpha_auth = try fixtures.authJsonWithEmailPlan(allocator, "alpha@example.com", "pro");
    defer allocator.free(alpha_auth);
    const beta_auth = try fixtures.authJsonWithEmailPlan(allocator, "beta@example.com", "team");
    defer allocator.free(beta_auth);
    try writeAccountSnapshot(allocator, codex_home, "alpha@example.com", alpha_auth);
    try writeAccountSnapshot(allocator, codex_home, "beta@example.com", beta_auth);
}

fn seedBundleTarget(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
) !void {
    const accounts_dir = try fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts" });
    defer allocator.free(accounts_dir);
    try fs.cwd().makePath(accounts_dir);

    var reg = fixtures.makeEmptyRegistry();
    defer reg.deinit(allocator);
    try fixtures.appendAccount(allocator, &reg, "alpha@example.com", "old", .plus);
    try fixtures.appendAccount(allocator, &reg, "local@example.com", "local", .free);
    reg.accounts.items[0].last_usage = .{
        .primary = .{ .used_percent = 25, .window_minutes = 300, .resets_at = null },
        .secondary = null,
        .credits = null,
        .plan_type = .plus,
    };
    reg.accounts.items[0].last_usage_at = 100;
    const local_key = try fixtures.accountKeyForEmailAlloc(allocator, "local@example.com");
    defer allocator.free(local_key);
    try registry.setActiveAccountKey(allocator, &reg, local_key);
    try registry.saveRegistry(allocator, codex_home, &reg);

    const alpha_auth = try fixtures.authJsonWithEmailPlan(allocator, "alpha@example.com", "plus");
    defer allocator.free(alpha_auth);
    const local_auth = try fixtures.authJsonWithEmailPlan(allocator, "local@example.com", "free");
    defer allocator.free(local_auth);
    try writeAccountSnapshot(allocator, codex_home, "alpha@example.com", alpha_auth);
    try writeAccountSnapshot(allocator, codex_home, "local@example.com", local_auth);
}

test "Scenario: Given exported bundle when importing with merge then local-only accounts remain and bundled settings apply" {
    const gpa = std.testing.allocator;
    var source_tmp = fs.tmpDir(.{});
    defer source_tmp.cleanup();
    var target_tmp = fs.tmpDir(.{});
    defer target_tmp.cleanup();

    const source_home = try source_tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(source_home);
    const target_home = try target_tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(target_home);
    try seedBundleSource(gpa, source_home);
    try seedBundleTarget(gpa, target_home);

    const bundle_path = try fs.path.join(gpa, &[_][]const u8{ source_home, "bundle.json" });
    defer gpa.free(bundle_path);
    var source_reg = try registry.loadRegistry(gpa, source_home);
    defer source_reg.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), try registry.exportBundle(gpa, source_home, &source_reg, bundle_path));

    const summary = try registry.importBundle(gpa, target_home, bundle_path, false);
    try std.testing.expectEqual(@as(usize, 1), summary.imported);
    try std.testing.expectEqual(@as(usize, 1), summary.updated);
    try std.testing.expectEqual(@as(usize, 0), summary.removed);

    var loaded = try registry.loadRegistry(gpa, target_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), loaded.accounts.items.len);
    try std.testing.expect(loaded.auto_switch.enabled);
    try std.testing.expectEqual(@as(u8, 12), loaded.auto_switch.threshold_5h_percent);
    try std.testing.expect(!loaded.api.usage);
    try std.testing.expectEqual(@as(u16, 45), loaded.live.interval_seconds);

    const alpha_idx = fixtures.findAccountIndexByEmail(&loaded, "alpha@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("work", loaded.accounts.items[alpha_idx].alias);
    try std.testing.expect(loaded.accounts.items[alpha_idx].last_usage != null);
    try std.testing.expectEqual(@as(i64, 100), loaded.accounts.items[alpha_idx].last_usage_at.?);
    try std.testing.expect(fixtures.findAccountIndexByEmail(&loaded, "local@example.com") != null);

    const active_key = try fixtures.accountKeyForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(active_key);
    try std.testing.expect(loaded.active_account_key != null);
    try std.testing.expectEqualStrings(active_key, loaded.active_account_key.?);
}

test "Scenario: Given exported bundle when importing with replace then local-only accounts are removed" {
    const gpa = std.testing.allocator;
    var source_tmp = fs.tmpDir(.{});
    defer source_tmp.cleanup();
    var target_tmp = fs.tmpDir(.{});
    defer target_tmp.cleanup();

    const source_home = try source_tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(source_home);
    const target_home = try target_tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(target_home);
    try seedBundleSource(gpa, source_home);
    try seedBundleTarget(gpa, target_home);

    const bundle_path = try fs.path.join(gpa, &[_][]const u8{ source_home, "bundle.json" });
    defer gpa.free(bundle_path);
    var source_reg = try registry.loadRegistry(gpa, source_home);
    defer source_reg.deinit(gpa);
    _ = try registry.exportBundle(gpa, source_home, &source_reg, bundle_path);

    const summary = try registry.importBundle(gpa, target_home, bundle_path, true);
    try std.testing.expectEqual(@as(usize, 2), summary.imported);
    try std.testing.expectEqual(@as(usize, 0), summary.updated);
    try std.testing.expectEqual(@as(usize, 2), summary.removed);

    var loaded = try registry.loadRegistry(gpa, target_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), loaded.accounts.items.len);
    try std.testing.expect(fixtures.findAccountIndexByEmail(&loaded, "local@example.com") == null);
    const alpha_idx = fixtures.findAccountIndexByEmail(&loaded, "alpha@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(loaded.accounts.items[alpha_idx].last_usage == null);

    const local_key = try fixtures.accountKeyForEmailAlloc(gpa, "local@example.com");
    defer gpa.free(local_key);
    const local_snapshot_path = try registry.accountAuthPath(gpa, target_home, local_key);
    defer gpa.free(local_snapshot_path);
    try std.testing.expectError(error.FileNotFound, fs.cwd().openFile(local_snapshot_path, .{}));
}

test "Scenario: Given bundle auth mismatch when importing then registry is unchanged" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try seedBundleTarget(gpa, codex_home);

    const alpha_key = try fixtures.accountKeyForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_key);
    const alpha_account_id = try fixtures.chatgptAccountIdForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_account_id);
    const alpha_user_id = try fixtures.chatgptUserIdForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_user_id);
    const beta_auth = try fixtures.authJsonWithEmailPlan(gpa, "beta@example.com", "team");
    defer gpa.free(beta_auth);
    var auth_json_writer: std.Io.Writer.Allocating = .init(gpa);
    defer auth_json_writer.deinit();
    try std.json.Stringify.value(beta_auth, .{}, &auth_json_writer.writer);

    const bad_bundle_path = try fs.path.join(gpa, &[_][]const u8{ codex_home, "bad-bundle.json" });
    defer gpa.free(bad_bundle_path);
    const bad_bundle = try std.fmt.allocPrint(
        gpa,
        \\{{
        \\  "format": "codex-auth.export.v1",
        \\  "bundle_schema_version": 1,
        \\  "registry_schema_version": {d},
        \\  "active_account_key": null,
        \\  "accounts": [
        \\    {{
        \\      "account_key": "{s}",
        \\      "chatgpt_account_id": "{s}",
        \\      "chatgpt_user_id": "{s}",
        \\      "email": "alpha@example.com",
        \\      "alias": "bad",
        \\      "account_name": null,
        \\      "plan": "pro",
        \\      "auth_mode": "chatgpt",
        \\      "created_at": 1,
        \\      "last_used_at": null,
        \\      "last_usage": null,
        \\      "last_usage_at": null,
        \\      "last_local_rollout": null,
        \\      "auth_json": {s}
        \\    }}
        \\  ]
        \\}}
    ,
        .{
            registry.current_schema_version,
            alpha_key,
            alpha_account_id,
            alpha_user_id,
            auth_json_writer.written(),
        },
    );
    defer gpa.free(bad_bundle);
    try fs.cwd().writeFile(.{ .sub_path = bad_bundle_path, .data = bad_bundle });

    try std.testing.expectError(error.BundleAccountKeyMismatch, registry.importBundle(gpa, codex_home, bad_bundle_path, false));

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), loaded.accounts.items.len);
    const alpha_idx = fixtures.findAccountIndexByEmail(&loaded, "alpha@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("old", loaded.accounts.items[alpha_idx].alias);
}
