const std = @import("std");
const conch = @import("zsn");

const Service = conch.Service;

pub const AppRunner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,

    activation_token: ?[:0]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: *std.process.Environ.Map,
    ) AppRunner {
        return .{ .allocator = allocator, .io = io, .environ_map = environ_map };
    }

    pub fn setActivationToken(self: *AppRunner, token: []const u8) !void {
        if (self.activation_token) |old| self.allocator.free(old);
        self.activation_token = try self.allocator.dupeZ(u8, token);
    }

    pub fn takeActivationToken(self: *AppRunner) ?[]const u8 {
        const t = self.activation_token;
        self.activation_token = null;
        return t;
    }

    pub fn deinit(self: *AppRunner) void {
        if (self.activation_token) |t| self.allocator.free(t);
    }

    const terminal_candidates = [_][]const u8{
        "alacritty",  "rio",   "ghostty",        "kitty",
        "konsole",    "kgx",   "gnome-terminal", "xfce4-terminal",
        "lxterminal", "xterm", "st",             "foot",
        "terminator",
    };

    pub fn isCommandAvailable(self: *AppRunner, cmd: []const u8) bool {
        if (std.fs.path.isAbsolute(cmd)) {
            return self.isExecutable(cmd);
        }
        const path_env = self.environ_map.get("PATH") orelse "/usr/bin:/bin";
        var it = std.mem.tokenizeScalar(u8, path_env, ':');
        while (it.next()) |dir| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, cmd }) catch continue;
            if (self.isExecutable(full)) return true;
        }
        return false;
    }

    fn isExecutable(self: *AppRunner, path: []const u8) bool {
        std.Io.Dir.cwd().access(self.io, path, .{ .execute = true }) catch return false;
        return true;
    }

    fn findTerminalNoAlloc(self: *AppRunner) ?[]const u8 {
        if (self.environ_map.get("TERMINAL")) |t| {
            if (t.len > 0 and self.isCommandAvailable(t)) return t;
        }

        for (terminal_candidates) |cand| {
            if (self.isCommandAvailable(cand)) return cand;
        }
        return null;
    }

    pub fn spawnFixedUpdate(self: *AppRunner) !void {
        const bash_cmd = "shelly; echo; read -rp 'Press Enter to close...'";

        const terminal = self.findTerminalNoAlloc() orelse return error.NoTerminal;

        const use_dashdash = std.mem.eql(u8, terminal, "gnome-terminal") or
            std.mem.eql(u8, terminal, "kgx");

        const argv: []const []const u8 = if (use_dashdash)
            &.{ "setsid", terminal, "--", "bash", "-c", bash_cmd }
        else
            &.{ "setsid", terminal, "-e", "bash", "-c", bash_cmd };

        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .environ_map = self.environ_map,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        _ = &child;
    }

    pub fn activateOrLaunch(self: *AppRunner, service: *Service) !void {
        service.activateApplication(
            "com.shellyorg.shelly",
            "/com/shellyorg/shelly",
            self.activation_token,
        ) catch {
            std.debug.print("[runner] shelly-ui not running, spawning\n", .{});
            try self.spawnWithToken();
            return;
        };
        std.debug.print("[runner] activated existing shelly-ui window\n", .{});
    }

    fn spawnWithToken(self: *AppRunner) !void {
        const argv: []const []const u8 = &.{ "setsid", self.shellyUiBin() };

        if (self.activation_token) |token| {
            var env = try self.environ_map.clone(self.allocator);
            defer env.deinit();
            try env.put("XDG_ACTIVATION_TOKEN", token);
            var child = try std.process.spawn(self.io, .{
                .argv = argv,
                .environ_map = &env,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            _ = &child;
        } else {
            var child = try std.process.spawn(self.io, .{
                .argv = argv,
                .environ_map = self.environ_map,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            _ = &child;
        }
    }

    pub fn quitUi(self: *AppRunner, service: *Service) !void {
        const pid = service.getProcessId("com.shellyorg.shelly") catch {
            std.debug.print("[runner] shelly-ui not running, nothing to quit\n", .{});
            return;
        };
        _ = self;
        try std.posix.kill(@intCast(pid), std.posix.SIG.TERM);
        std.debug.print("[runner] sent SIGTERM to shelly-ui (pid {d})\n", .{pid});
    }

    fn shellyUiBin(self: *AppRunner) []const u8 {
        _ = self;
        return "shelly-ui";
    }
};
