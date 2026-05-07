const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const auth = @import("../auth/auth.zig");
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
const ensureAccountsDir = common.ensureAccountsDir;
const freeAccountRecord = common.freeAccountRecord;
const freeRateLimitSnapshot = common.freeRateLimitSnapshot;
const freeRolloutSignature = common.freeRolloutSignature;
const readFileAlloc = common.readFileAlloc;
const replaceOptionalStringAlloc = common.replaceOptionalStringAlloc;
const writeFile = common.writeFile;
const parseAutoSwitch = parse.parseAutoSwitch;
const parseApiConfig = parse.parseApiConfig;
const parseLiveConfig = parse.parseLiveConfig;
const parseAccountRecord = storage_parse.parseAccountRecord;
const findAccountIndexByAccountKey = account_ops.findAccountIndexByAccountKey;
const replaceActiveAuthWithAccountByKey = account_ops.replaceActiveAuthWithAccountByKey;
const removeAccounts = account_ops.removeAccounts;

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
    try writeFile(export_path, aw.written());
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
    if (replace) {
        summary.removed = reg.accounts.items.len;
        if (reg.accounts.items.len > 0) {
            const indices = try allocator.alloc(usize, reg.accounts.items.len);
            defer allocator.free(indices);
            for (indices, 0..) |*slot, idx| slot.* = idx;
            try removeAccounts(allocator, codex_home, &reg, indices);
        }
    }

    reg.auto_switch = bundle.auto_switch;
    reg.api = bundle.api;
    reg.live = bundle.live;

    try ensureAccountsDir(allocator, codex_home);
    for (bundle.accounts.items) |*account| {
        const existing_idx = findAccountIndexByAccountKey(&reg, account.record.account_key);
        const dest = try accountAuthPath(allocator, codex_home, account.record.account_key);
        defer allocator.free(dest);
        try writeFile(dest, account.auth_json);

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
        try replaceActiveAuthWithAccountByKey(allocator, codex_home, &reg, key);
    } else if (replace) {
        if (reg.active_account_key) |key| allocator.free(key);
        reg.active_account_key = null;
        reg.active_account_activated_at_ms = null;
        const active_path = try activeAuthPath(allocator, codex_home);
        defer allocator.free(active_path);
        std.Io.Dir.cwd().deleteFile(app_runtime.io(), active_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    try storage.saveRegistry(allocator, codex_home, &reg);
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

    if (!std.mem.eql(u8, record_key, rec.account_key)) return error.BundleAccountMismatch;
    if (!std.mem.eql(u8, email, rec.email)) return error.BundleAccountMismatch;
    if (!std.mem.eql(u8, chatgpt_account_id, rec.chatgpt_account_id)) return error.BundleAccountMismatch;
    if (!std.mem.eql(u8, chatgpt_user_id, rec.chatgpt_user_id)) return error.BundleAccountMismatch;
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
