const std = @import("std");
const events = @import("events.zig");

pub const default_search_endpoint = "https://flathub.org/api/v2/search";
const max_response_size = 32 * 1024 * 1024;

pub const Error = error{
    Cancelled,
    EmptyQuery,
    HttpStatus,
    InvalidResponse,
};

pub const SearchFilter = struct {
    filter_type: []const u8,
    value: []const u8,
};

pub const SearchOptions = struct {
    page: usize = 1,
    limit: usize = 21,
    filters: ?[]const SearchFilter = null,
};

pub const SearchHit = struct {
    name: ?[]const u8 = null,
    keywords: []const []const u8 = &.{},
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    id: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    app_type: ?[]const u8 = null,
    project_license: ?[]const u8 = null,
    is_free_license: ?bool = null,
    icon: ?[]const u8 = null,
    main_categories: []const []const u8 = &.{},
    sub_categories: []const []const u8 = &.{},
    developer_name: ?[]const u8 = null,
    verification_verified: ?bool = null,
    verification_method: ?[]const u8 = null,
    verification_login_name: ?[]const u8 = null,
    verification_login_provider: ?[]const u8 = null,
    verification_website: ?[]const u8 = null,
    verification_timestamp: ?[]const u8 = null,
    runtime: ?[]const u8 = null,
    updated_at: ?i64 = null,
    arches: []const []const u8 = &.{},
    added_at: ?i64 = null,
    trending: ?f64 = null,
    installs_last_month: ?i64 = null,
    favorites_count: ?f64 = null,
    is_mobile_friendly: ?bool = null,
};

/// Typed search data plus the exact response body used by JSON output mode.
pub const SearchResponse = struct {
    owner_allocator: std.mem.Allocator,
    arena_state: *std.heap.ArenaAllocator,
    raw_json: []const u8,
    hits: []const SearchHit,
    query: ?[]const u8 = null,
    processing_time_ms: ?i64 = null,
    hits_per_page: ?i64 = null,
    page: ?i64 = null,
    total_pages: ?i64 = null,
    total_hits: ?i64 = null,

    pub fn deinit(self: *SearchResponse) void {
        self.arena_state.deinit();
        self.owner_allocator.destroy(self.arena_state);
        self.* = undefined;
    }
};

const SearchRequest = struct {
    query: []const u8,
    filters: ?[]const SearchFilter,
    hits_per_page: usize,
    page: usize,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    endpoint: []const u8 = default_search_endpoint,
    dispatcher: ?*events.Dispatcher = null,
    cancellation: ?events.Cancellation = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Client {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn setEventDispatcher(self: *Client, dispatcher: ?*events.Dispatcher) void {
        self.dispatcher = dispatcher;
    }

    pub fn setCancellation(self: *Client, cancellation: ?events.Cancellation) void {
        self.cancellation = cancellation;
    }

    /// Perform a Flathub v2 search and return typed, owned results.
    pub fn search(self: Client, query: []const u8, options: SearchOptions) !SearchResponse {
        const raw = try self.searchJson(query, options);
        defer self.allocator.free(raw);
        return parseSearchResponse(self.allocator, raw);
    }

    /// Perform a Flathub v2 search and preserve its exact JSON response.
    /// The caller owns the returned slice.
    pub fn searchJson(self: Client, query: []const u8, options: SearchOptions) ![]u8 {
        if (std.mem.trim(u8, query, " \t\r\n").len == 0) return Error.EmptyQuery;
        try self.checkCancelled();

        const payload = try std.json.Stringify.valueAlloc(self.allocator, SearchRequest{
            .query = query,
            .filters = options.filters,
            .hits_per_page = options.limit,
            .page = options.page,
        }, .{ .emit_null_optional_fields = false });
        defer self.allocator.free(payload);

        var http: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer http.deinit();
        const uri = try std.Uri.parse(self.endpoint);
        const headers = [_]std.http.Header{
            .{ .name = "accept", .value = "application/json" },
        };
        var request = try http.request(.POST, uri, .{
            .headers = .{
                .user_agent = .{ .override = "ShellyPackageManager/3.0" },
                .accept_encoding = .{ .override = "identity" },
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = &headers,
            .redirect_behavior = .init(10),
        });
        defer request.deinit();
        request.accept_encoding[@intFromEnum(std.http.ContentEncoding.gzip)] = false;
        request.accept_encoding[@intFromEnum(std.http.ContentEncoding.deflate)] = false;
        try request.sendBodyComplete(payload);

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        if (response.head.status.class() != .success) {
            self.emitStatus(.err, "Flathub search returned a non-success HTTP status");
            return Error.HttpStatus;
        }

        var transfer_buffer: [8 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            try self.checkCancelled();
            const amount = try reader.readSliceShort(&buffer);
            if (amount == 0) break;
            if (output.items.len + amount > max_response_size) return error.StreamTooLong;
            try output.appendSlice(self.allocator, buffer[0..amount]);
        }
        self.emitStatus(.success, "Flathub search completed");
        return output.toOwnedSlice(self.allocator);
    }

    fn checkCancelled(self: Client) !void {
        if (self.cancellation) |cancellation| {
            if (cancellation.isCancelled()) return Error.Cancelled;
        }
    }

    fn emitStatus(self: Client, event_type: events.EventType, message: []const u8) void {
        if (self.dispatcher) |dispatcher| dispatcher.raiseStatus(.{
            .event_type = event_type,
            .message = message,
        });
    }
};

pub fn parseSearchResponse(allocator: std.mem.Allocator, raw_json: []const u8) !SearchResponse {
    const arena_state = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena_state);
    arena_state.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw_json, .{});
    if (root != .object) return Error.InvalidResponse;
    const object = root.object;

    var hits: std.ArrayList(SearchHit) = .empty;
    if (object.get("hits")) |hit_values| {
        if (hit_values != .array) return Error.InvalidResponse;
        for (hit_values.array.items) |hit_value| {
            if (hit_value != .object) continue;
            const hit = hit_value.object;
            try hits.append(arena, .{
                .name = stringField(hit, "name"),
                .keywords = try stringListField(arena, hit, "keywords"),
                .summary = stringField(hit, "summary"),
                .description = stringField(hit, "description"),
                .id = stringField(hit, "id"),
                .app_id = stringField(hit, "app_id") orelse stringField(hit, "appId"),
                .app_type = stringField(hit, "type"),
                .project_license = stringField(hit, "project_license") orelse stringField(hit, "projectLicense"),
                .is_free_license = boolField(hit, "is_free_license") orelse boolField(hit, "isFreeLicense"),
                .icon = stringField(hit, "icon"),
                .main_categories = try stringListFieldAliases(arena, hit, "main_categories", "mainCategories"),
                .sub_categories = try stringListFieldAliases(arena, hit, "sub_categories", "subCategories"),
                .developer_name = stringField(hit, "developer_name") orelse stringField(hit, "developerName"),
                .verification_verified = boolField(hit, "verification_verified") orelse boolField(hit, "verificationVerified"),
                .verification_method = stringField(hit, "verification_method") orelse stringField(hit, "verificationMethod"),
                .verification_login_name = stringField(hit, "verification_login_name") orelse stringField(hit, "verificationLoginName"),
                .verification_login_provider = stringField(hit, "verification_login_provider") orelse stringField(hit, "verificationLoginProvider"),
                .verification_website = stringField(hit, "verification_website") orelse stringField(hit, "verificationWebsite"),
                .verification_timestamp = stringField(hit, "verification_timestamp") orelse stringField(hit, "verificationTimestamp"),
                .runtime = stringField(hit, "runtime"),
                .updated_at = integerField(hit, "updated_at") orelse integerField(hit, "updatedAt"),
                .arches = try stringListField(arena, hit, "arches"),
                .added_at = integerField(hit, "added_at") orelse integerField(hit, "addedAt"),
                .trending = floatField(hit, "trending"),
                .installs_last_month = integerField(hit, "installs_last_month") orelse integerField(hit, "installsLastMonth"),
                .favorites_count = floatField(hit, "favorites_count") orelse floatField(hit, "favoritesCount"),
                .is_mobile_friendly = boolField(hit, "isMobileFriendly") orelse boolField(hit, "is_mobile_friendly"),
            });
        }
    }

    return .{
        .owner_allocator = allocator,
        .arena_state = arena_state,
        .raw_json = try arena.dupe(u8, raw_json),
        .hits = try hits.toOwnedSlice(arena),
        .query = stringField(object, "query"),
        .processing_time_ms = integerField(object, "processingTimeMs") orelse integerField(object, "processing_time_ms"),
        .hits_per_page = integerField(object, "hitsPerPage") orelse integerField(object, "hits_per_page"),
        .page = integerField(object, "page"),
        .total_pages = integerField(object, "totalPages") orelse integerField(object, "total_pages"),
        .total_hits = integerField(object, "totalHits") orelse integerField(object, "total_hits"),
    };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn boolField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn integerField(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        else => null,
    };
}

fn floatField(object: std.json.ObjectMap, name: []const u8) ?f64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        .number_string, .string => |number| std.fmt.parseFloat(f64, number) catch null,
        else => null,
    };
}

fn stringListField(arena: std.mem.Allocator, object: std.json.ObjectMap, name: []const u8) ![]const []const u8 {
    const value = object.get(name) orelse return &.{};
    if (value == .string) return arena.dupe([]const u8, &.{value.string});
    if (value != .array) return &.{};
    var strings: std.ArrayList([]const u8) = .empty;
    for (value.array.items) |item| {
        if (item == .string) try strings.append(arena, item.string);
    }
    return strings.toOwnedSlice(arena);
}

fn stringListFieldAliases(
    arena: std.mem.Allocator,
    object: std.json.ObjectMap,
    first: []const u8,
    second: []const u8,
) ![]const []const u8 {
    if (object.contains(first)) return stringListField(arena, object, first);
    return stringListField(arena, object, second);
}

test "Flathub request payload preserves strict page limit and filters" {
    const filters = [_]SearchFilter{.{ .filter_type = "category", .value = "Game" }};
    const payload = try std.json.Stringify.valueAlloc(std.testing.allocator, SearchRequest{
        .query = "music",
        .filters = &filters,
        .hits_per_page = 7,
        .page = 3,
    }, .{ .emit_null_optional_fields = false });
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"query\":\"music\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"hits_per_page\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"page\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"filter_type\":\"category\"") != null);
}

test "Flathub response parser returns typed hits and exact JSON" {
    const source =
        \\{"hits":[{"name":"Example","app_id":"org.example.App","main_categories":"Utility","trending":"4.5","arches":["x86_64"]}],"query":"exa","hitsPerPage":21,"page":1,"totalPages":2,"totalHits":22}
    ;
    var response = try parseSearchResponse(std.testing.allocator, source);
    defer response.deinit();

    try std.testing.expectEqualStrings(source, response.raw_json);
    try std.testing.expectEqual(@as(usize, 1), response.hits.len);
    try std.testing.expectEqualStrings("org.example.App", response.hits[0].app_id.?);
    try std.testing.expectEqualStrings("Utility", response.hits[0].main_categories[0]);
    try std.testing.expectEqual(@as(?f64, 4.5), response.hits[0].trending);
    try std.testing.expectEqual(@as(?i64, 22), response.total_hits);
}

test "Flathub client exposes typed and exact JSON search" {
    _ = Client.search;
    _ = Client.searchJson;
    _ = Client.setCancellation;
    _ = Client.setEventDispatcher;
}

test "Flathub search honors cancellation before network access" {
    const Cancel = struct {
        fn requested(_: ?*anyopaque) bool {
            return true;
        }
    };
    var client = Client.init(std.testing.allocator, std.testing.io);
    client.setCancellation(.{ .function = Cancel.requested });
    try std.testing.expectError(Error.Cancelled, client.searchJson("example", .{}));
}
