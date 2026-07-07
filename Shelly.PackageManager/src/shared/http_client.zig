const std = @import("std");
const http = std.http;

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    io: std.Io,
    user_agent: ?[:0]const u8,
    timeout_seconds: u32,
    verify_ssl: bool = false,

    pub fn init(self: *HttpClient, allocator: std.mem.Allocator, userAgent: ?[:0]const u8, timeout_seconds: u32, verify_ssl: bool) !void {
        self.client = http.Client{ .allocator = allocator };
        self.io = self.client.io;
        self.user_agent = userAgent;
        self.timeout_seconds = timeout_seconds;
        self.verify_ssl = verify_ssl;
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    pub fn get(self: *HttpClient, url: []const u8, progress_callback: ?ProgressCallback) !DownloadResponse {}
};

pub const ProgressCallback = *const fn (bytes_downloaded: u64, bytes_total: ?u64) void;

pub const DownloadResponse = struct {
    status_code: u16,
    content_length: ?u64,
    content_type: ?[:0]const u8,
    body: []u8, // Owned by caller
    deinit: *const fn (self: *DownloadResponse) void,
};
