const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const auth = @import("../auth/auth.zig");
const builtin = @import("builtin");
const common = @import("common.zig");
const parse = @import("parse.zig");
const storage = @import("storage.zig");
const storage_parse = @import("storage_parse.zig");
const account_ops = @import("account_ops.zig");
const version = @import("../version.zig");

const AccountRecord = common.AccountRecord;
const ApiConfig = common.ApiConfig;
const AutoSwitchConfig = common.AutoSwitchConfig;
const LiveConfig = common.LiveConfig;
const Registry = common.Registry;
const activeAuthPath = common.activeAuthPath;
const accountAuthPath = common.accountAuthPath;
const copyManagedFile = common.copyManagedFile;
const ensureAccountsDir = common.ensureAccountsDir;
const freeAccountRecord = common.freeAccountRecord;
const freeRateLimitSnapshot = common.freeRateLimitSnapshot;
const freeRolloutSignature = common.freeRolloutSignature;
const hardenSensitiveFile = common.hardenSensitiveFile;
const private_file_permissions = common.private_file_permissions;
const readFileAlloc = common.readFileAlloc;
const replaceOptionalStringAlloc = common.replaceOptionalStringAlloc;
const parseAutoSwitch = parse.parseAutoSwitch;
const parseApiConfig = parse.parseApiConfig;
const parseLiveConfig = parse.parseLiveConfig;
const parseAccountRecord = storage_parse.parseAccountRecord;
const findAccountIndexByAccountKey = account_ops.findAccountIndexByAccountKey;
const setActiveAccountKey = account_ops.setActiveAccountKey;

const bundle_format = "codex-auth.export.v1";
const bundle_schema_version: u32 = 1;

pub const BundleImportSummary = struct {
    imported: usize = 0,
    updated: usize = 0,
    removed: usize = 0,
};

const BundleAccount = struct {
    record: AccountRecord,
    auth_json: []u8,

    fn deinit(self: *BundleAccount, allocator: std.mem.Allocator) void {
        freeAccountRecord(allocator, &self.record);
        allocator.free(self.auth_json);
    }
};

const BundleData = struct {
    active_account_key: ?[]u8,
    auto_switch: AutoSwitchConfig,
    api: ApiConfig,
    live: LiveConfig,
    accounts: std.ArrayList(BundleAccount),

    fn deinit(self: *BundleData, allocator: std.mem.Allocator) void {
        if (self.active_account_key) |key| allocator.free(key);
        for (self.accounts.items) |*account| account.deinit(allocator);
        self.accounts.deinit(allocator);
    }
};

const FileRollback = struct {
    path: []u8,
    backup_path: ?[]u8,
};

const BundleAccountOut = struct {
    account_key: []const u8,
    chatgpt_account_id: []const u8,
    chatgpt_user_id: []const u8,
    email: []const u8,
    alias: []const u8,
    account_name: ?[]const u8,
    plan: ?common.PlanType,
    auth_mode: ?common.AuthMode,
    created_at: i64,
    last_used_at: ?i64 = null,
    last_usage: ?common.RateLimitSnapshot = null,
    last_usage_at: ?i64 = null,
    last_local_rollout: ?common.RolloutSignature = null,
    auth_json: []u8,
};

const BundleOut = struct {
    format: []const u8,
    bundle_schema_version: u32,
    app_version: []const u8,
    registry_schema_version: u32,
    active_account_key: ?[]const u8,
    auto_switch: AutoSwitchConfig,
    api: ApiConfig,
    live: LiveConfig,
    accounts: []const BundleAccountOut,
};

pub fn exportBundle(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *const Registry,
    export_path: []const u8,
) !usize {
    var accounts = std.ArrayList(BundleAccountOut).empty;
    defer {
        for (accounts.items) |account| allocator.free(account.auth_json);
        accounts.deinit(allocator);
    }

    for (reg.accounts.items) |rec| {
        const auth_path = try accountAuthPath(allocator, codex_home, rec.account_key);
        defer allocator.free(auth_path);

        const auth_json = try readFilePathAlloc(allocator, auth_path);
        errdefer allocator.free(auth_json);
        try validateAuthJsonForRecord(allocator, auth_json, &rec);

        try accounts.append(allocator, .{
            .account_key = rec.account_key,
            .chatgpt_account_id = rec.chatgpt_account_id,
            .chatgpt_user_id = rec.chatgpt_user_id,
            .email = rec.email,
            .alias = rec.alias,
            .account_name = rec.account_name,
            .plan = rec.plan,
            .auth_mode = rec.auth_mode,
            .created_at = rec.created_at,
            .auth_json = auth_json,
        });
    }

    const out = BundleOut{
        .format = bundle_format,
        .bundle_schema_version = bundle_schema_version,
        .app_version = version.app_version,
        .registry_schema_version = common.current_schema_version,
        .active_account_key = reg.active_account_key,
        .auto_switch = reg.auto_switch,
        .api = reg.api,
        .live = reg.live,
        .accounts = accounts.items,
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(out, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeAll("\n");
    try writeSensitiveFileAtomic(allocator, export_path, aw.written());
    return accounts.items.len;
}

pub fn importBundle(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    bundle_path: []const u8,
    replace: bool,
) !BundleImportSummary {
    const bundle_bytes = try readFilePathAlloc(allocator, bundle_path);
    defer allocator.free(bundle_bytes);

    var bundle = try parseBundleData(allocator, bundle_bytes);
    defer bundle.deinit(allocator);

    var reg = try storage.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    var summary = BundleImportSummary{};
    var replaced_account_keys = std.ArrayList([]u8).empty;
    defer freeOwnedStrings(allocator, &replaced_account_keys);
    var file_rollbacks = std.ArrayList(FileRollback).empty;
    defer cleanupFileRollbacks(allocator, &file_rollbacks);
    var rollback_pending = true;
    errdefer if (rollback_pending) rollbackFileChanges(file_rollbacks.items);

    if (replace) {
        summary.removed = reg.accounts.items.len;
        try cloneRegistryAccountKeys(allocator, &reg, &replaced_account_keys);
        clearRegistryAccountsOnly(allocator, &reg);
    }

    reg.auto_switch = bundle.auto_switch;
    reg.api = bundle.api;
    reg.live = bundle.live;

    try ensureAccountsDir(allocator, codex_home);
    for (bundle.accounts.items) |*account| {
        const existing_idx = findAccountIndexByAccountKey(&reg, account.record.account_key);
        const dest = try accountAuthPath(allocator, codex_home, account.record.account_key);
        defer allocator.free(dest);
        try writeFileWithRollback(allocator, &file_rollbacks, dest, account.auth_json);

        if (existing_idx) |idx| {
            try updateExistingAccountFromBundle(allocator, &reg.accounts.items[idx], &account.record);
            summary.updated += 1;
        } else {
            const cloned = try cloneAccountRecord(allocator, &account.record);
            try reg.accounts.append(allocator, cloned);
            summary.imported += 1;
        }
    }

    if (bundle.active_account_key) |key| {
        try setActiveAccountKey(allocator, &reg, key);
        const src = try accountAuthPath(allocator, codex_home, key);
        defer allocator.free(src);
        const dest = try activeAuthPath(allocator, codex_home);
        defer allocator.free(dest);
        try copyFileWithRollback(allocator, &file_rollbacks, src, dest);
    } else if (replace) {
        if (reg.active_account_key) |key| allocator.free(key);
        reg.active_account_key = null;
        reg.active_account_activated_at_ms = null;
        const active_path = try activeAuthPath(allocator, codex_home);
        defer allocator.free(active_path);
        try deleteFileWithRollback(allocator, &file_rollbacks, active_path);
    }

    try storage.saveRegistry(allocator, codex_home, &reg);
    rollback_pending = false;

    if (replace) try deleteReplacedAccountSnapshots(allocator, codex_home, replaced_account_keys.items, bundle.accounts.items);
    return summary;
}

fn parseBundleData(allocator: std.mem.Allocator, data: []const u8) !BundleData {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidBundleFormat,
    };

    const format = switch (root_obj.get("format") orelse return error.InvalidBundleFormat) {
        .string => |value| value,
        else => return error.InvalidBundleFormat,
    };
    if (!std.mem.eql(u8, format, bundle_format)) return error.InvalidBundleFormat;

    const schema = switch (root_obj.get("bundle_schema_version") orelse return error.InvalidBundleFormat) {
        .integer => |value| std.math.cast(u32, value) orelse return error.UnsupportedBundleVersion,
        else => return error.InvalidBundleFormat,
    };
    if (schema != bundle_schema_version) return error.UnsupportedBundleVersion;

    const registry_schema = switch (root_obj.get("registry_schema_version") orelse return error.InvalidBundleFormat) {
        .integer => |value| std.math.cast(u32, value) orelse return error.UnsupportedRegistryVersion,
        else => return error.InvalidBundleFormat,
    };
    if (registry_schema > common.current_schema_version) return error.UnsupportedRegistryVersion;

    var bundle = BundleData{
        .active_account_key = null,
        .auto_switch = common.defaultAutoSwitchConfig(),
        .api = common.defaultApiConfig(),
        .live = common.defaultLiveConfig(),
        .accounts = std.ArrayList(BundleAccount).empty,
    };
    errdefer bundle.deinit(allocator);

    if (root_obj.get("active_account_key")) |active| {
        switch (active) {
            .string => |value| bundle.active_account_key = try allocator.dupe(u8, value),
            .null => {},
            else => return error.InvalidBundleFormat,
        }
    }
    if (root_obj.get("auto_switch")) |value| parseAutoSwitch(allocator, &bundle.auto_switch, value);
    if (root_obj.get("api")) |value| parseApiConfig(&bundle.api, value);
    if (root_obj.get("live")) |value| parseLiveConfig(&bundle.live, value);

    const accounts = switch (root_obj.get("accounts") orelse return error.InvalidBundleFormat) {
        .array => |items| items,
        else => return error.InvalidBundleFormat,
    };
    for (accounts.items) |item| {
        const obj = switch (item) {
            .object => |value| value,
            else => return error.InvalidBundleFormat,
        };
        var record = try parseAccountRecord(allocator, obj);
        var record_owned = true;
        errdefer if (record_owned) freeAccountRecord(allocator, &record);
        discardRuntimeState(allocator, &record);

        const auth_json = switch (obj.get("auth_json") orelse return error.InvalidBundleFormat) {
            .string => |value| try allocator.dupe(u8, value),
            else => return error.InvalidBundleFormat,
        };
        var auth_json_owned = true;
        errdefer if (auth_json_owned) allocator.free(auth_json);
        try validateAuthJsonForRecord(allocator, auth_json, &record);
        if (findBundleAccountIndex(bundle.accounts.items, record.account_key) != null) {
            return error.DuplicateBundleAccount;
        }

        try bundle.accounts.append(allocator, .{
            .record = record,
            .auth_json = auth_json,
        });
        record_owned = false;
        auth_json_owned = false;
    }

    if (bundle.active_account_key) |key| {
        if (findBundleAccountIndex(bundle.accounts.items, key) == null) return error.InvalidBundleActiveAccount;
    }

    return bundle;
}

fn validateAuthJsonForRecord(
    allocator: std.mem.Allocator,
    auth_json: []const u8,
    rec: *const AccountRecord,
) !void {
    const info = try auth.parseAuthInfoData(allocator, auth_json);
    defer info.deinit(allocator);

    const record_key = info.record_key orelse return error.MissingAccountKey;
    const email = info.email orelse return error.MissingEmail;
    const chatgpt_account_id = info.chatgpt_account_id orelse return error.MissingAccountId;
    const chatgpt_user_id = info.chatgpt_user_id orelse return error.MissingChatgptUserId;

    if (!std.mem.eql(u8, record_key, rec.account_key)) return error.BundleAccountKeyMismatch;
    if (!std.mem.eql(u8, email, rec.email)) return error.BundleEmailMismatch;
    if (!std.mem.eql(u8, chatgpt_account_id, rec.chatgpt_account_id)) return error.BundleChatgptAccountIdMismatch;
    if (!std.mem.eql(u8, chatgpt_user_id, rec.chatgpt_user_id)) return error.BundleChatgptUserIdMismatch;
}

fn discardRuntimeState(allocator: std.mem.Allocator, rec: *AccountRecord) void {
    rec.last_used_at = null;
    if (rec.last_usage) |*usage| freeRateLimitSnapshot(allocator, usage);
    rec.last_usage = null;
    rec.last_usage_at = null;
    if (rec.last_local_rollout) |*signature| freeRolloutSignature(allocator, signature);
    rec.last_local_rollout = null;
}

fn findBundleAccountIndex(accounts: []const BundleAccount, account_key: []const u8) ?usize {
    for (accounts, 0..) |account, idx| {
        if (std.mem.eql(u8, account.record.account_key, account_key)) return idx;
    }
    return null;
}

fn readFilePathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(app_runtime.io(), path, .{});
    defer file.close(app_runtime.io());
    return try readFileAlloc(file, allocator, 10 * 1024 * 1024);
}

fn writeSensitiveFileAtomic(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    if (builtin.os.tag == .windows) return writeSensitiveFileReplace(allocator, path, data);

    var buf: [4096]u8 = undefined;
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(app_runtime.io(), path, .{
        .replace = true,
        .permissions = private_file_permissions,
    });
    defer atomic_file.deinit(app_runtime.io());
    var file_writer = atomic_file.file.writer(app_runtime.io(), &buf);
    try file_writer.interface.writeAll(data);
    try file_writer.interface.flush();
    try atomic_file.replace(app_runtime.io());
    try hardenSensitiveFile(path);
}

fn writeSensitiveFileReplace(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const timestamp = @as(i128, std.Io.Timestamp.now(app_runtime.io(), .real).toNanoseconds());
    const temp_path = try writeUniqueSidecarFile(allocator, path, "tmp", data);
    defer allocator.free(temp_path);
    errdefer std.Io.Dir.cwd().deleteFile(app_runtime.io(), temp_path) catch {};
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.bak.{d}.{d}", .{ path, timestamp, temp_path.len });
    defer allocator.free(backup_path);

    const had_original = blk: {
        std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), backup_path, app_runtime.io()) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    errdefer {
        std.Io.Dir.cwd().deleteFile(app_runtime.io(), temp_path) catch {};
        if (had_original) {
            std.Io.Dir.cwd().rename(backup_path, std.Io.Dir.cwd(), path, app_runtime.io()) catch {};
        }
    }
    try std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), path, app_runtime.io());
    if (had_original) {
        std.Io.Dir.cwd().deleteFile(app_runtime.io(), backup_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    try hardenSensitiveFile(path);
}

fn writeUniqueSidecarFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    label: []const u8,
    data: []const u8,
) ![]u8 {
    const timestamp = @as(i128, std.Io.Timestamp.now(app_runtime.io(), .real).toNanoseconds());
    var counter: usize = 0;
    while (counter < 64) : (counter += 1) {
        const sidecar_path = try std.fmt.allocPrint(allocator, "{s}.{s}.{d}.{d}", .{ path, label, timestamp, counter });
        errdefer allocator.free(sidecar_path);
        var file = std.Io.Dir.cwd().createFile(app_runtime.io(), sidecar_path, .{
            .truncate = false,
            .exclusive = true,
            .permissions = private_file_permissions,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(sidecar_path);
                continue;
            },
            else => return err,
        };
        defer file.close(app_runtime.io());
        try file.writeStreamingAll(app_runtime.io(), data);
        try file.sync(app_runtime.io());
        return sidecar_path;
    }
    return error.TemporaryFileCollision;
}

fn writeFileWithRollback(
    allocator: std.mem.Allocator,
    rollbacks: *std.ArrayList(FileRollback),
    path: []const u8,
    data: []const u8,
) !void {
    try beginFileRollback(allocator, rollbacks, path);
    try writeSensitiveFileAtomic(allocator, path, data);
}

fn copyFileWithRollback(
    allocator: std.mem.Allocator,
    rollbacks: *std.ArrayList(FileRollback),
    src: []const u8,
    dest: []const u8,
) !void {
    try beginFileRollback(allocator, rollbacks, dest);
    try copyManagedFile(src, dest);
}

fn deleteFileWithRollback(
    allocator: std.mem.Allocator,
    rollbacks: *std.ArrayList(FileRollback),
    path: []const u8,
) !void {
    try beginFileRollback(allocator, rollbacks, path);
    std.Io.Dir.cwd().deleteFile(app_runtime.io(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn beginFileRollback(
    allocator: std.mem.Allocator,
    rollbacks: *std.ArrayList(FileRollback),
    path: []const u8,
) !void {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);

    var backup_path: ?[]u8 = null;
    const existing = readFilePathAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |bytes| {
        defer allocator.free(bytes);
        backup_path = try writeUniqueSidecarFile(allocator, path, "rollback", bytes);
    }
    errdefer if (backup_path) |backup| {
        std.Io.Dir.cwd().deleteFile(app_runtime.io(), backup) catch {};
        allocator.free(backup);
    };

    try rollbacks.append(allocator, .{
        .path = owned_path,
        .backup_path = backup_path,
    });
}

fn rollbackFileChanges(rollbacks: []const FileRollback) void {
    var idx = rollbacks.len;
    while (idx > 0) {
        idx -= 1;
        const rollback = rollbacks[idx];
        if (rollback.backup_path) |backup_path| {
            copyManagedFile(backup_path, rollback.path) catch {};
        } else {
            std.Io.Dir.cwd().deleteFile(app_runtime.io(), rollback.path) catch {};
        }
    }
}

fn cleanupFileRollbacks(allocator: std.mem.Allocator, rollbacks: *std.ArrayList(FileRollback)) void {
    for (rollbacks.items) |rollback| {
        if (rollback.backup_path) |backup_path| {
            std.Io.Dir.cwd().deleteFile(app_runtime.io(), backup_path) catch {};
            allocator.free(backup_path);
        }
        allocator.free(rollback.path);
    }
    rollbacks.deinit(allocator);
}

fn cloneRegistryAccountKeys(allocator: std.mem.Allocator, reg: *const Registry, keys: *std.ArrayList([]u8)) !void {
    for (reg.accounts.items) |rec| {
        const key = try allocator.dupe(u8, rec.account_key);
        errdefer allocator.free(key);
        try keys.append(allocator, key);
    }
}

fn clearRegistryAccountsOnly(allocator: std.mem.Allocator, reg: *Registry) void {
    for (reg.accounts.items) |*rec| freeAccountRecord(allocator, rec);
    reg.accounts.clearRetainingCapacity();
    if (reg.active_account_key) |key| allocator.free(key);
    reg.active_account_key = null;
    reg.active_account_activated_at_ms = null;
}

fn deleteReplacedAccountSnapshots(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    replaced_keys: []const []const u8,
    bundle_accounts: []const BundleAccount,
) !void {
    for (replaced_keys) |key| {
        if (findBundleAccountIndex(bundle_accounts, key) != null) continue;
        const path = try accountAuthPath(allocator, codex_home, key);
        defer allocator.free(path);
        std.Io.Dir.cwd().deleteFile(app_runtime.io(), path) catch {};
    }
}

fn freeOwnedStrings(allocator: std.mem.Allocator, strings: *std.ArrayList([]u8)) void {
    for (strings.items) |value| allocator.free(value);
    strings.deinit(allocator);
}

fn replaceOwnedString(allocator: std.mem.Allocator, target: *[]u8, value: []const u8) !void {
    if (std.mem.eql(u8, target.*, value)) return;
    const replacement = try allocator.dupe(u8, value);
    allocator.free(target.*);
    target.* = replacement;
}

fn updateExistingAccountFromBundle(
    allocator: std.mem.Allocator,
    dest: *AccountRecord,
    source: *const AccountRecord,
) !void {
    try replaceOwnedString(allocator, &dest.chatgpt_account_id, source.chatgpt_account_id);
    try replaceOwnedString(allocator, &dest.chatgpt_user_id, source.chatgpt_user_id);
    try replaceOwnedString(allocator, &dest.email, source.email);
    try replaceOwnedString(allocator, &dest.alias, source.alias);
    _ = try replaceOptionalStringAlloc(allocator, &dest.account_name, source.account_name);
    dest.plan = source.plan;
    dest.auth_mode = source.auth_mode;
}

fn cloneAccountRecord(allocator: std.mem.Allocator, source: *const AccountRecord) !AccountRecord {
    const account_key = try allocator.dupe(u8, source.account_key);
    var account_key_owned = true;
    errdefer if (account_key_owned) allocator.free(account_key);
    const chatgpt_account_id = try allocator.dupe(u8, source.chatgpt_account_id);
    var chatgpt_account_id_owned = true;
    errdefer if (chatgpt_account_id_owned) allocator.free(chatgpt_account_id);
    const chatgpt_user_id = try allocator.dupe(u8, source.chatgpt_user_id);
    var chatgpt_user_id_owned = true;
    errdefer if (chatgpt_user_id_owned) allocator.free(chatgpt_user_id);
    const email = try allocator.dupe(u8, source.email);
    var email_owned = true;
    errdefer if (email_owned) allocator.free(email);
    const alias = try allocator.dupe(u8, source.alias);
    var alias_owned = true;
    errdefer if (alias_owned) allocator.free(alias);
    const account_name = try common.cloneOptionalStringAlloc(allocator, source.account_name);
    var account_name_owned = true;
    errdefer if (account_name_owned) {
        if (account_name) |value| allocator.free(value);
    };

    var rec = AccountRecord{
        .account_key = account_key,
        .chatgpt_account_id = chatgpt_account_id,
        .chatgpt_user_id = chatgpt_user_id,
        .email = email,
        .alias = alias,
        .account_name = account_name,
        .plan = source.plan,
        .auth_mode = source.auth_mode,
        .created_at = source.created_at,
        .last_used_at = source.last_used_at,
        .last_usage = null,
        .last_usage_at = source.last_usage_at,
        .last_local_rollout = null,
    };
    account_key_owned = false;
    chatgpt_account_id_owned = false;
    chatgpt_user_id_owned = false;
    email_owned = false;
    alias_owned = false;
    account_name_owned = false;
    errdefer freeAccountRecord(allocator, &rec);

    if (source.last_usage) |usage| rec.last_usage = try common.cloneRateLimitSnapshot(allocator, usage);
    if (source.last_local_rollout) |signature| rec.last_local_rollout = try common.cloneRolloutSignature(allocator, signature);
    return rec;
}
