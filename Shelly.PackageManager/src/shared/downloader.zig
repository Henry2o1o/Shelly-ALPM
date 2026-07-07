const std = @import("std");
const http = std.http;

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
    allocator: std.mem.Allocator,
    user_agent: ?[:0]const u8 = null,
    timeout_in_seconds: u32 = 30,
    max_retries: u8 = 3,
    retry_delay_secs: u32 = 1,
    verify_ssl: bool = true,
    parallel_downloads: u8 = 10,

    pub fn default(allocator: std.mem.Allocator) DownloadConfiguration {
        return DownloadConfiguration{
            .allocator = allocator,
            .user_agent = "ShellyPackageManager/2.0",
            .timeout_in_seconds = 30,
            .max_retries = 3,
            .retry_delay_secs = 1,
            .verify_ssl = true,
            .parallel_downloads = 10,
        };
    }
};

pub const DownloadResult = union(enum) {
    succes: struct {
        destination_path: []const u8,
    },
    failure: DownloadError,
    skipped: struct { destination_path: []const u8, reason: SkippedReason },
};

pub const CoreDownloader = struct {
    configuration: DownloadConfiguration,
};
