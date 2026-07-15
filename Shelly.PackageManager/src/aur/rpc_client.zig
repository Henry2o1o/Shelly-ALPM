const std = @import("std");
const models = @import("models.zig");

pub const default_rpc_url = "https://aur.archlinux.org/rpc/";
pub const default_cgit_url = "https://aur.archlinux.org/cgit/aur.git/plain";
const max_response_size = 32 * 1024 * 1024;

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    http: std.http.Client,
    rpc_url: []const u8 = default_rpc_url,
    cgit_url: []const u8 = default_cgit_url,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Client {
        return .{
            .allocator = allocator,
            .io = io,
            .http = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
        self.* = undefined;
    }

    pub fn search(self: *Client, query: []const u8) !models.Response {
        const url = try buildSearchUrl(self.allocator, self.rpc_url, query, "name-desc");
        defer self.allocator.free(url);
        const payload = try self.get(url);
        defer self.allocator.free(payload);
        return models.Response.parse(self.allocator, payload);
    }

    pub fn suggest(self: *Client, query: []const u8) ![][]u8 {
        return self.suggestType("suggest", query);
    }

    pub fn suggestPackageBases(self: *Client, query: []const u8) ![][]u8 {
        return self.suggestType("suggest-pkgbase", query);
    }

    fn suggestType(self: *Client, request_type: []const u8, query: []const u8) ![][]u8 {
        const encoded = try percentEncode(self.allocator, query);
        defer self.allocator.free(encoded);
        const url = try std.fmt.allocPrint(self.allocator, "{s}?v=5&type={s}&arg={s}", .{ self.rpc_url, request_type, encoded });
        defer self.allocator.free(url);
        const payload = try self.get(url);
        defer self.allocator.free(payload);
        return parseSuggestions(self.allocator, payload);
    }

    pub fn getInfo(self: *Client, package_names: []const []const u8) !models.Response {
        if (package_names.len == 0) return emptyResponse(self.allocator, "info");

        var all_packages: std.ArrayList(models.Package) = .empty;
        errdefer {
            for (all_packages.items) |*package| package.deinit(self.allocator);
            all_packages.deinit(self.allocator);
        }
        var response_type = try self.allocator.dupe(u8, "info");
        errdefer self.allocator.free(response_type);

        var offset: usize = 0;
        while (offset < package_names.len) : (offset += 100) {
            const end = @min(offset + 100, package_names.len);
            const body = try buildInfoFormBody(self.allocator, package_names[offset..end]);
            defer self.allocator.free(body);
            const payload = try self.postForm(self.rpc_url, body);
            defer self.allocator.free(payload);
            var response = try models.Response.parse(self.allocator, payload);

            if (std.mem.eql(u8, response.response_type, "error")) {
                for (all_packages.items) |*package| package.deinit(self.allocator);
                all_packages.deinit(self.allocator);
                self.allocator.free(response_type);
                return response;
            }

            all_packages.appendSlice(self.allocator, response.results) catch |err| {
                response.deinit(self.allocator);
                return err;
            };
            self.allocator.free(response.results);
            self.allocator.free(response_type);
            response_type = response.response_type;
            if (response.error_message) |message| self.allocator.free(message);
        }

        return .{
            .version = 5,
            .response_type = response_type,
            .result_count = all_packages.items.len,
            .results = try all_packages.toOwnedSlice(self.allocator),
        };
    }

    pub fn getPackageBase(self: *Client, package_name: []const u8) ![]u8 {
        if (std.mem.trim(u8, package_name, " \t\r\n").len == 0)
            return self.allocator.dupe(u8, package_name);
        var response = try self.getInfo(&.{package_name});
        defer response.deinit(self.allocator);
        if (response.results.len > 0 and response.results[0].package_base.len != 0)
            return self.allocator.dupe(u8, response.results[0].package_base);
        return self.allocator.dupe(u8, package_name);
    }

    pub fn findProviders(self: *Client, dependency_name: []const u8) ![][]u8 {
        if (std.mem.trim(u8, dependency_name, " \t\r\n").len == 0)
            return self.allocator.alloc([]u8, 0);

        var direct = try self.getInfo(&.{dependency_name});
        defer direct.deinit(self.allocator);
        if (direct.results.len > 0 and direct.results[0].name.len != 0) {
            const result = try self.allocator.alloc([]u8, 1);
            result[0] = try self.allocator.dupe(u8, direct.results[0].name);
            return result;
        }

        const url = try buildSearchUrl(self.allocator, self.rpc_url, dependency_name, "provides");
        defer self.allocator.free(url);
        const payload = try self.get(url);
        defer self.allocator.free(payload);
        var response = try models.Response.parse(self.allocator, payload);
        defer response.deinit(self.allocator);

        var names: std.ArrayList([]u8) = .empty;
        errdefer deinitStrings(self.allocator, names.items);
        for (response.results) |package| {
            var duplicate = false;
            for (names.items) |name| {
                if (std.mem.eql(u8, name, package.name)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) try names.append(self.allocator, try self.allocator.dupe(u8, package.name));
        }
        return names.toOwnedSlice(self.allocator);
    }

    pub fn fetchPkgbuild(self: *Client, package_base: []const u8) ![]u8 {
        const encoded = try percentEncode(self.allocator, package_base);
        defer self.allocator.free(encoded);
        const url = try std.fmt.allocPrint(self.allocator, "{s}/PKGBUILD?h={s}", .{ self.cgit_url, encoded });
        defer self.allocator.free(url);
        return self.get(url);
    }

    pub fn fetchSourceFile(self: *Client, package_base: []const u8, file_name: []const u8) ![]u8 {
        const encoded_base = try percentEncode(self.allocator, package_base);
        defer self.allocator.free(encoded_base);
        const encoded_file = try percentEncode(self.allocator, file_name);
        defer self.allocator.free(encoded_file);
        const url = try std.fmt.allocPrint(self.allocator, "{s}/{s}?h={s}", .{ self.cgit_url, encoded_file, encoded_base });
        defer self.allocator.free(url);
        return self.get(url);
    }

    fn get(self: *Client, url: []const u8) ![]u8 {
        const uri = try std.Uri.parse(url);
        var request = try self.http.request(.GET, uri, .{
            .headers = .{
                .user_agent = .{ .override = "Shelly-ALPM/3" },
                .accept_encoding = .{ .override = "identity" },
            },
            .redirect_behavior = .init(10),
        });
        defer request.deinit();
        request.accept_encoding[@intFromEnum(std.http.ContentEncoding.gzip)] = false;
        request.accept_encoding[@intFromEnum(std.http.ContentEncoding.deflate)] = false;
        try request.sendBodiless();
        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        if (response.head.status.class() != .success) return error.AurHttpStatus;
        var transfer_buffer: [8 * 1024]u8 = undefined;
        return response.reader(&transfer_buffer).allocRemaining(self.allocator, .limited(max_response_size));
    }

    fn postForm(self: *Client, url: []const u8, body: []u8) ![]u8 {
        const uri = try std.Uri.parse(url);
        const headers = [_]std.http.Header{.{
            .name = "content-type",
            .value = "application/x-www-form-urlencoded",
        }};
        var request = try self.http.request(.POST, uri, .{
            .headers = .{
                .user_agent = .{ .override = "Shelly-ALPM/3" },
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = &headers,
            .redirect_behavior = .init(10),
        });
        defer request.deinit();
        request.accept_encoding[@intFromEnum(std.http.ContentEncoding.gzip)] = false;
        request.accept_encoding[@intFromEnum(std.http.ContentEncoding.deflate)] = false;
        try request.sendBodyComplete(body);
        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        if (response.head.status.class() != .success) return error.AurHttpStatus;
        var transfer_buffer: [8 * 1024]u8 = undefined;
        return response.reader(&transfer_buffer).allocRemaining(self.allocator, .limited(max_response_size));
    }
};

pub fn buildSearchUrl(allocator: std.mem.Allocator, base_url: []const u8, query: []const u8, by: []const u8) ![]u8 {
    const encoded = try percentEncode(allocator, query);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "{s}?v=5&type=search&arg={s}&by={s}", .{ base_url, encoded, by });
}

pub fn buildInfoFormBody(allocator: std.mem.Allocator, package_names: []const []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("v=5&type=info");
    for (package_names) |name| {
        const encoded = try percentEncode(allocator, name);
        defer allocator.free(encoded);
        try output.writer.print("&arg%5B%5D={s}", .{encoded});
    }
    return output.toOwnedSlice();
}

pub fn percentEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const hex = "0123456789ABCDEF";
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (input) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.' or char == '~') {
            try output.writer.writeByte(char);
        } else {
            try output.writer.writeAll(&.{ '%', hex[char >> 4], hex[char & 0x0f] });
        }
    }
    return output.toOwnedSlice();
}

pub fn parseSuggestions(allocator: std.mem.Allocator, payload: []const u8) ![][]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidAurResponse;
    var suggestions: std.ArrayList([]u8) = .empty;
    errdefer {
        for (suggestions.items) |suggestion| allocator.free(suggestion);
        suggestions.deinit(allocator);
    }
    for (parsed.value.array.items) |item| {
        if (item != .string) return error.InvalidAurResponse;
        try suggestions.append(allocator, try allocator.dupe(u8, item.string));
    }
    return suggestions.toOwnedSlice(allocator);
}

pub fn deinitStrings(allocator: std.mem.Allocator, strings: []const []u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

fn emptyResponse(allocator: std.mem.Allocator, response_type: []const u8) !models.Response {
    const owned_type = try allocator.dupe(u8, response_type);
    errdefer allocator.free(owned_type);
    return .{
        .response_type = owned_type,
        .results = try allocator.alloc(models.Package, 0),
    };
}

test "AUR RPC URL and form encoding matches the C# requests" {
    const allocator = std.testing.allocator;
    const search_url = try buildSearchUrl(allocator, default_rpc_url, "foo bar+git", "name-desc");
    defer allocator.free(search_url);
    try std.testing.expectEqualStrings(
        "https://aur.archlinux.org/rpc/?v=5&type=search&arg=foo%20bar%2Bgit&by=name-desc",
        search_url,
    );

    const form = try buildInfoFormBody(allocator, &.{ "one", "split package" });
    defer allocator.free(form);
    try std.testing.expectEqualStrings("v=5&type=info&arg%5B%5D=one&arg%5B%5D=split%20package", form);
}

test "AUR suggestions are returned as owned strings" {
    const suggestions = try parseSuggestions(std.testing.allocator, "[\"yay\",\"yay-bin\"]");
    defer deinitStrings(std.testing.allocator, suggestions);
    try std.testing.expectEqual(@as(usize, 2), suggestions.len);
    try std.testing.expectEqualStrings("yay-bin", suggestions[1]);
}
