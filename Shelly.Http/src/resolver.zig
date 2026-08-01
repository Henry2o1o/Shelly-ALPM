const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const HostName = Io.net.HostName;
const posix = std.posix;
const use_libc = builtin.os.tag == .linux and builtin.link_libc;

/// Zig 0.16's native Linux resolver stores the complete `search` directive
/// from `/etc/resolv.conf` in a `HostName.max_len` buffer. A search list can
/// legally be much longer than one DNS name, so Tailscale/MagicDNS-style
/// configurations can panic while parsing it. On Linux, delegate name service
/// lookup to libc, which handles the system resolver configuration without
/// that fixed-size parser. Other targets retain Zig's normal I/O resolver.
pub fn lookup(
    host_name: HostName,
    io: Io,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) HostName.LookupError!void {
    if (comptime use_libc) {
        return lookupLibc(host_name, io, resolved, options);
    }
    return HostName.lookup(host_name, io, resolved, options);
}

fn lookupLibc(
    host_name: HostName,
    io: Io,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) HostName.LookupError!void {
    defer resolved.close(io);

    var name_buffer: [HostName.max_len:0]u8 = undefined;
    @memcpy(name_buffer[0..host_name.bytes.len], host_name.bytes);
    name_buffer[host_name.bytes.len] = 0;
    const name = name_buffer[0..host_name.bytes.len :0];

    const hints: posix.addrinfo = .{
        .flags = .{ .CANONNAME = options.canonical_name_buffer != null },
        .family = if (options.family) |family| switch (family) {
            .ip4 => posix.AF.INET,
            .ip6 => posix.AF.INET6,
        } else posix.AF.UNSPEC,
        .socktype = posix.SOCK.STREAM,
        .protocol = posix.IPPROTO.TCP,
        .canonname = null,
        .addr = null,
        .addrlen = 0,
        .next = null,
    };

    var result: ?*posix.addrinfo = null;
    while (true) {
        switch (std.c.getaddrinfo(name.ptr, null, &hints, &result)) {
            @as(std.c.EAI, @enumFromInt(0)) => break,
            .SYSTEM => switch (posix.errno(-1)) {
                .INTR => continue,
                else => return error.Unexpected,
            },
            .ADDRFAMILY, .FAMILY => return error.AddressFamilyUnsupported,
            .AGAIN, .FAIL => return error.NameServerFailure,
            .MEMORY => return error.SystemResources,
            .NODATA, .NONAME => return error.UnknownHostName,
            .CANCELED => return error.Canceled,
            else => return error.Unexpected,
        }
    }
    defer if (result) |head| std.c.freeaddrinfo(head);

    var address_count: usize = 0;
    var canonical_name: ?[*:0]const u8 = null;
    var current = result;
    while (current) |info| : (current = info.next) {
        const address = info.addr orelse continue;
        switch (address.family) {
            posix.AF.INET, posix.AF.INET6 => {},
            else => continue,
        }

        var ip_address = Io.Threaded.addressFromPosix(
            @alignCast(@fieldParentPtr("any", address)),
        );
        ip_address.setPort(options.port);
        try putResult(resolved, io, .{ .address = ip_address });
        address_count += 1;

        if (canonical_name == null) canonical_name = info.canonname;
    }

    if (options.canonical_name_buffer) |buffer| {
        if (canonical_name) |canonical| {
            const bytes = std.mem.sliceTo(canonical, 0);
            if (bytes.len <= buffer.len) {
                const destination = buffer[0..bytes.len];
                @memcpy(destination, bytes);
                try putResult(resolved, io, .{
                    .canonical_name = .{ .bytes = destination },
                });
            }
        }
    }

    if (address_count == 0) return error.NoAddressReturned;
}

fn putResult(
    resolved: *Io.Queue(HostName.LookupResult),
    io: Io,
    result: HostName.LookupResult,
) HostName.LookupError!void {
    resolved.putOne(io, result) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Closed => unreachable,
    };
}

test "Linux builds use libc instead of Zig's resolv.conf parser" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expect(use_libc);
}
