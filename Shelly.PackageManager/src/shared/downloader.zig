const std = @import("std");

pub const DownloadEventType = enum {
    Start,
    Progress,
    Complete,
    Error,
    Skipped,
};

pub const DownloadError = error{
    HttpError,
    NetworkError,
    FileError,
    InvalidUrl,
    Timeout,
    RetryExceeded,
    SslError,
};

pub const SkippedReason = enum {
    ExistsAndUpToDate,
    ForceDownloadDisabled,
};

pub const DownloadProgress = struct {
    bytes_downloaded: u64,
    bytes_total: ?u64,
    percent: u8,
    speed_bytes_per_sec: ?u64,
};

pub const DownloadConfiguration = struct {
    user_agent: ?[:0]const u8 = null,
    timeout_in_seconds: u32 = 30,
    max_retries: u8 = 3,
    retry_delay_secs: u32 = 1,
    verify_ssl: bool = true,
    parallel_downloads: u8 = 10,

    pub fn default() DownloadConfiguration {
        return .{ .user_agent = "ShellyPackageManager/2.0" };
    }
};

pub const DownloadEvent = struct {
    event_type: DownloadEventType,
    progress: ?DownloadProgress = null,
    download_error: ?DownloadError = null,
    destination_path: ?[]const u8 = null,
};

pub const DownloadEventCallback = *const fn (ctx: ?*anyopaque, event: DownloadEvent) void;

pub const DownloadResult = union(enum) {
    succes: struct { destination_path: []const u8 },
    failure: DownloadError,
    skipped: struct { destination_path: []const u8, reason: SkippedReason },
};

/// Size of the buffer used to copy body bytes from the socket to disk.
const copy_buffer_size = 64 * 1024;

pub const CoreDownloader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    configuration: DownloadConfiguration,
    http_client: std.http.Client,
    event_callback: ?DownloadEventCallback = null,
    event_context: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: DownloadConfiguration) CoreDownloader {
        return .{
            .allocator = allocator,
            .io = io,
            .configuration = config,
            .http_client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn setEventCallback(self: *CoreDownloader, callback: DownloadEventCallback, context: ?*anyopaque) void {
        self.event_callback = callback;
        self.event_context = context;
    }

    pub fn deinit(self: *CoreDownloader) void {
        self.http_client.deinit();
    }

    pub fn downloadToFile(
        self: *CoreDownloader,
        url: []const u8,
        destination_path: []const u8,
        skip_if_exists: bool,
    ) DownloadResult {
        const already_present = std.Io.Dir.cwd().statFile(self.io, destination_path, .{}) catch null;
        if (skip_if_exists and already_present != null) {
            return .{ .skipped = .{ .destination_path = destination_path, .reason = .ExistsAndUpToDate } };
        }

        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            if (attempt > 0) {
                self.io.sleep(
                    std.Io.Duration.fromSeconds(@intCast(self.configuration.retry_delay_secs)),
                    .awake,
                ) catch {};
            }

            if (self.performDownload(url, destination_path)) {
                return .{ .succes = .{ .destination_path = destination_path } };
            } else |err| {
                const can_retry = isRetryable(err) and attempt < self.configuration.max_retries;
                if (!can_retry) {
                    const final_err = if (isRetryable(err)) DownloadError.RetryExceeded else err;
                    self.emitEvent(.{
                        .event_type = .Error,
                        .download_error = final_err,
                        .destination_path = destination_path,
                    });
                    return .{ .failure = final_err };
                }
            }
        }
    }

    fn performDownload(self: *CoreDownloader, url: []const u8, destination_path: []const u8) DownloadError!void {
        const uri = std.Uri.parse(url) catch return DownloadError.InvalidUrl;

        const user_agent: std.http.Client.Request.Headers.Value = if (self.configuration.user_agent) |agent|
            .{ .override = agent }
        else
            .default;

        var req = self.http_client.request(.GET, uri, .{
            .headers = .{ .user_agent = user_agent },
        }) catch |err| {
            std.log.err("HTTP request setup failed for {s}: {}", .{ url, err });
            return mapRequestError(err);
        };
        defer req.deinit();

        // Request the resource verbatim: disable compression so the bytes we
        // write to disk are exactly what the server serves and so Content-Length
        // reflects the real download size for progress reporting.
        req.accept_encoding[@intFromEnum(std.http.ContentEncoding.gzip)] = false;
        req.accept_encoding[@intFromEnum(std.http.ContentEncoding.deflate)] = false;

        req.sendBodiless() catch |err| {
            std.log.err("Failed to send request for {s}: {}", .{ url, err });
            return DownloadError.NetworkError;
        };

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            std.log.err("Failed to receive response head for {s}: {}", .{ url, err });
            return mapReceiveHeadError(err);
        };

        const status = response.head.status;
        switch (status.class()) {
            .success => {},
            .server_error => {
                std.log.err("Server error {d} for {s}", .{ @intFromEnum(status), url });
                // Retryable: transient server-side failure.
                return DownloadError.NetworkError;
            },
            else => {
                std.log.err("HTTP status {d} for {s}", .{ @intFromEnum(status), url });
                return DownloadError.HttpError;
            },
        }

        const total: ?u64 = response.head.content_length;

        self.emitEvent(.{
            .event_type = .Start,
            .destination_path = destination_path,
            .progress = .{
                .bytes_downloaded = 0,
                .bytes_total = total,
                .percent = 0,
                .speed_bytes_per_sec = null,
            },
        });

        var file = std.Io.Dir.cwd().createFile(self.io, destination_path, .{}) catch |err| {
            std.log.err("Failed to create file {s}: {}", .{ destination_path, err });
            return DownloadError.FileError;
        };
        defer file.close(self.io);

        const copy_buffer = self.allocator.alloc(u8, copy_buffer_size) catch return DownloadError.FileError;
        defer self.allocator.free(copy_buffer);

        // The transfer buffer is working space for the HTTP body reader
        // (e.g. chunked-transfer framing); the body itself streams into
        // `copy_buffer` directly.
        var transfer_buffer: [4 * 1024]u8 = undefined;
        const body_reader = response.reader(&transfer_buffer);

        const start_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        var downloaded: u64 = 0;
        var last_percent: i16 = -1;
        var last_reported: u64 = 0;

        while (true) {
            const n = body_reader.readSliceShort(copy_buffer) catch {
                std.log.err("Read failed while downloading {s}: {?}", .{ url, response.bodyErr() });
                return DownloadError.NetworkError;
            };
            if (n == 0) break;

            file.writeStreamingAll(self.io, copy_buffer[0..n]) catch |err| {
                std.log.err("Failed to write to {s}: {}", .{ destination_path, err });
                return DownloadError.FileError;
            };

            downloaded += n;

            if (self.shouldEmitProgress(downloaded, total, &last_percent, &last_reported)) {
                self.emitEvent(.{
                    .event_type = .Progress,
                    .destination_path = destination_path,
                    .progress = makeProgress(downloaded, total, self.speedBytesPerSec(downloaded, start_ns)),
                });
            }
        }

        self.emitEvent(.{
            .event_type = .Complete,
            .destination_path = destination_path,
            .progress = makeProgress(downloaded, total orelse downloaded, self.speedBytesPerSec(downloaded, start_ns)),
        });
    }

    /// Decides whether a `Progress` event should be emitted, throttling to
    /// avoid flooding the callback: on each whole-percent change when the total
    /// size is known, or every 256 KiB when it is not.
    fn shouldEmitProgress(
        self: *const CoreDownloader,
        downloaded: u64,
        total: ?u64,
        last_percent: *i16,
        last_reported: *u64,
    ) bool {
        _ = self;
        if (total) |t| {
            const percent: i16 = if (t == 0) 100 else @intCast(@min(@as(u64, 100), downloaded * 100 / t));
            if (percent != last_percent.*) {
                last_percent.* = percent;
                return true;
            }
            return false;
        }
        if (downloaded - last_reported.* >= 256 * 1024) {
            last_reported.* = downloaded;
            return true;
        }
        return false;
    }

    fn speedBytesPerSec(self: *const CoreDownloader, downloaded: u64, start_ns: i96) ?u64 {
        const now_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        const elapsed_ns = now_ns - start_ns;
        if (elapsed_ns <= 0) return null;
        const elapsed: u128 = @intCast(elapsed_ns);
        const bps = @as(u128, downloaded) * std.time.ns_per_s / elapsed;
        return std.math.cast(u64, bps) orelse std.math.maxInt(u64);
    }

    fn emitEvent(self: *const CoreDownloader, event: DownloadEvent) void {
        if (self.event_callback) |callback| callback(self.event_context, event);
    }
};

fn makeProgress(downloaded: u64, total: ?u64, speed: ?u64) DownloadProgress {
    const percent: u8 = if (total) |t|
        (if (t == 0) 100 else @intCast(@min(@as(u64, 100), downloaded * 100 / t)))
    else
        0;
    return .{
        .bytes_downloaded = downloaded,
        .bytes_total = total,
        .percent = percent,
        .speed_bytes_per_sec = speed,
    };
}

fn isRetryable(err: DownloadError) bool {
    return switch (err) {
        error.NetworkError, error.Timeout => true,
        else => false,
    };
}

fn mapRequestError(err: std.http.Client.RequestError) DownloadError {
    return switch (err) {
        error.UnsupportedUriScheme, error.UriMissingHost => DownloadError.InvalidUrl,
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => DownloadError.SslError,
        else => DownloadError.NetworkError,
    };
}

fn mapReceiveHeadError(err: std.http.Client.Request.ReceiveHeadError) DownloadError {
    return switch (err) {
        error.TooManyHttpRedirects,
        error.RedirectRequiresResend,
        error.HttpRedirectLocationMissing,
        error.HttpRedirectLocationOversize,
        error.HttpRedirectLocationInvalid,
        error.HttpHeadersInvalid,
        error.HttpHeadersOversize,
        error.HttpContentEncodingUnsupported,
        error.HttpChunkInvalid,
        error.HttpChunkTruncated,
        => DownloadError.HttpError,
        error.UnsupportedUriScheme => DownloadError.InvalidUrl,
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => DownloadError.SslError,
        else => DownloadError.NetworkError,
    };
}
