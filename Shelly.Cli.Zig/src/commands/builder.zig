const std = @import("std");
const Zigalpm = @import("Zigalpm");
const runtime = @import("../runtime/context.zig");
const parser = @import("../cli/parser.zig");
const test_support = @import("test_support.zig");
const PackageBuilder = Zigalpm.builder.PackageBuilder;
const standard_single_pane = @import("../output/standard_single_pane.zig");
const ui_operation = @import("../output/ui_operation.zig");
const MakePackageConfiguration = Zigalpm.builder.MakePackageConfiguration;

const command_path = "shelly build build";

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;
    return try executeWithRunner(context, invocation, Real{});
}

fn executeWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
) !u8 {
    if (invocation.globals.ui_mode) {
        return try ui_operation.runTransaction(
            context,
            invocation,
            .{
                .opening = "Preparing PKGBUILD...",
                .success_message = "Build completed.",
                .failure_message = "Build failed.",
                .failure_label = "Build failed",
                .cancelled_message = "Build cancelled.",
            },
            runner,
        );
    }

    const succeeded = try standard_single_pane.output(
        context,
        "Preparing PKGBUILD...",
        invocation.globals.no_confirm,
        runner,
        invocation,
        "Build completed.",
        "Build failed.",
    );
    return if (succeeded) 0 else 1;
}

const Real = struct {
    pub fn run(
        _: Real,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        invocation: *const parser.Invocation,
    ) !void {
        try Zigalpm.builder.secureBuilderProcess();
        const requested_path = if (invocation.positionals.len == 0) "PKGBUILD" else invocation.positionals[0];
        const pkgbuild_path = try std.Io.Dir.cwd().realPathFileAlloc(
            context.io,
            requested_path,
            context.allocator,
        );
        defer context.allocator.free(pkgbuild_path);
        const build_directory = std.fs.path.dirname(pkgbuild_path) orelse
            return error.InvalidPkgbuildPath;

        var operation = operation_context.begin(.{
            .backend = .aur,
            .kind = .build,
            .subject = pkgbuild_path,
        });

        var completion: Zigalpm.OperationCompletionStatus = .failed;
        defer operation.finish(completion);

        const makepkg = try MakePackageConfiguration.init(
            context.io,
            context.allocator,
        );
        defer makepkg.deinit();

        const pkgbuild_content = try std.Io.Dir.cwd().readFileAlloc(
            context.io,
            pkgbuild_path,
            context.allocator,
            .limited(32 * 1024 * 1024),
        );
        defer context.allocator.free(pkgbuild_content);
        const pkgbuild_parser = Zigalpm.pkgbuild.Parser{
            .allocator = context.allocator,
            .io = context.io,
            .package_carch = makepkg.package_carch,
        };

        var names = try pkgbuild_parser.package_names_content(pkgbuild_content);
        defer names.deinit(context.allocator);

        var requested_names: std.ArrayList([]const u8) = .empty;
        defer requested_names.deinit(context.allocator);
        for (invocation.options) |option| {
            if (!std.mem.eql(u8, option.name, "--package")) continue;
            const requested_name = option.value orelse return error.MissingPackageName;
            if (!containsString(names.items, requested_name))
                return error.SelectedPackageNotFound;
            if (!containsString(requested_names.items, requested_name))
                try requested_names.append(context.allocator, requested_name);
        }
        if (requested_names.items.len == 0)
            try requested_names.appendSlice(context.allocator, names.items);

        const package_builds = try context.allocator.alloc(
            Zigalpm.pkgbuild.parser.Pkgbuild,
            requested_names.items.len,
        );

        var parsed_count: usize = 0;
        defer {
            for (package_builds[0..parsed_count]) |*pkgbuild|
                pkgbuild.deinit(context.allocator);
            context.allocator.free(package_builds);
        }

        for (requested_names.items, package_builds) |name, *pkgbuild| {
            pkgbuild.* = try (Zigalpm.pkgbuild.Parser{
                .allocator = context.allocator,
                .io = context.io,
                .selected_package_name = name,
                .package_carch = makepkg.package_carch,
            }).parser_content(pkgbuild_content, build_directory);

            parsed_count += 1;
        }
        var review = try Zigalpm.builder.preparePkgbuildReview(
            context.allocator,
            context.io,
            build_directory,
            pkgbuild_content,
            package_builds,
        );
        defer review.deinit();

        const coordinator_child = optionEnabled(invocation, "--coordinator-child");
        const expected_digest = if (coordinator_child) digest: {
            const encoded = optionValue(invocation, "--review-digest") orelse
                return error.MissingReviewDigest;
            const parsed = try parseReviewDigest(encoded);
            if (!std.mem.eql(u8, &parsed, &review.digest))
                return error.ReviewedPkgbuildChanged;
            break :digest parsed;
        } else review.digest;

        if (!coordinator_child and !optionEnabled(invocation, "--reviewed")) {
            var answer = try operation.ask(.{
                .kind = .review_changes,
                .prompt = "Build packages from this PKGBUILD?",
                .review = .{
                    .subject = pkgbuild_path,
                    .findings = review.findings,
                    .old_content = "",
                    .new_content = pkgbuild_content,
                    .related_files = review.related_files,
                },
                .default_response = if (review.findings.len == 0)
                    .accepted
                else
                    .declined,
            });

            defer answer.deinit(context.allocator);

            if (answer.response != .accepted) {
                completion = .cancelled;
                return error.Cancelled;
            }
        }

        try review.verifyCurrent(
            context.allocator,
            context.io,
            pkgbuild_path,
            build_directory,
        );

        const builder = try PackageBuilder.init(
            context.allocator,
            package_builds,
            operation_context,
            makepkg.*,
            requested_names.items,
            .{
                .build_directory = build_directory,
                .pkgbuild_path = pkgbuild_path,
                .clean_after_success = !optionEnabled(invocation, "--keep-workdirs"),
                .overwrite = !optionEnabled(invocation, "--no-overwrite"),
                .run_check = optionEnabled(invocation, "--check"),
                .run_verify = !optionEnabled(invocation, "--noverify"),
                .skip_source_pgp_verification = optionEnabled(invocation, "--skip-source-pgp-verification"),
                .reviewed_pkgbuild_digest = expected_digest,
                .install_scripts = review.install_scripts,
                .sources_prepared = false,
            },
            context.environ,
            context.io,
        );
        defer builder.deinit();
        const artifacts = builder.runWithOperation(&operation) catch |err| {
            operation.reportError(
                err,
                "Failed to build",
                "build",
                null,
                false,
            );
            return err;
        };
        defer Zigalpm.builder.deinitArtifacts(context.allocator, artifacts);
        for (artifacts) |artifact| {
            const message = try std.fmt.allocPrint(
                context.allocator,
                "Built {s}: {s}",
                .{ artifact.package_name, artifact.path },
            );
            defer context.allocator.free(message);
            operation.status(.success, message, "build.artifact", null);
        }
        completion = .success;
    }
};

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        const value = option.value orelse return true;
        return !std.ascii.eqlIgnoreCase(value, "false");
    }
    return false;
}

fn optionValue(invocation: *const parser.Invocation, name: []const u8) ?[]const u8 {
    for (invocation.options) |option|
        if (std.mem.eql(u8, option.name, name)) return option.value;
    return null;
}

fn containsString(values: []const []const u8, wanted: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, wanted)) return true;
    return false;
}

fn parseReviewDigest(encoded: []const u8) ![std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    if (encoded.len != digest.len * 2) return error.InvalidReviewDigest;
    _ = std.fmt.hexToBytes(&digest, encoded) catch return error.InvalidReviewDigest;
    return digest;
}

test "build command routes review questions through standard and UI lifecycles" {
    const spec = @import("../cli/spec.zig");
    var test_context: test_support.TestContext = .{};
    test_context.init();
    defer test_context.deinit();
    const manifest = try spec.Manifest.load(test_context.arena.allocator());

    const ReviewRunner = struct {
        response: ?Zigalpm.OperationQuestionResponse = null,

        pub fn run(
            self: *@This(),
            context: *runtime.RuntimeContext,
            operation_context: *Zigalpm.OperationContext,
            _: *const parser.Invocation,
        ) !void {
            var operation = operation_context.begin(.{
                .backend = .aur,
                .kind = .build,
                .subject = "PKGBUILD",
            });
            defer operation.finish(.success);
            var answer = try operation.ask(.{
                .kind = .review_changes,
                .prompt = "Build packages from this PKGBUILD?",
                .review = .{
                    .subject = "PKGBUILD",
                    .old_content = "",
                    .new_content = "pkgname=demo\n",
                },
                .default_response = .accepted,
            });
            defer answer.deinit(context.allocator);
            self.response = answer.response;
        }
    };

    const standard = try parser.parse(
        test_context.arena.allocator(),
        &manifest,
        &.{ "build", "--no-confirm" },
    );
    var standard_runner: ReviewRunner = .{};
    try std.testing.expectEqual(
        @as(u8, 0),
        try executeWithRunner(&test_context.context, &standard.dispatch, &standard_runner),
    );
    try std.testing.expectEqual(
        Zigalpm.OperationQuestionResponse.accepted,
        standard_runner.response.?,
    );

    test_context.stdout.writer.end = 0;
    const ui = try parser.parse(
        test_context.arena.allocator(),
        &manifest,
        &.{ "build", "--ui-mode", "--no-confirm" },
    );
    var ui_runner: ReviewRunner = .{};
    try std.testing.expectEqual(
        @as(u8, 0),
        try executeWithRunner(&test_context.context, &ui.dispatch, &ui_runner),
    );
    try std.testing.expectEqual(
        Zigalpm.OperationQuestionResponse.accepted,
        ui_runner.response.?,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        test_context.stdout.writer.buffered(),
        "TransactionDone",
    ) != null);
}

test "reviewed option only controls whether build approval is requested" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const reviewed = try parser.parse(arena.allocator(), &manifest, &.{ "build", "--reviewed" });
    const normal = try parser.parse(arena.allocator(), &manifest, &.{"build"});
    try std.testing.expect(optionEnabled(&reviewed.dispatch, "--reviewed"));
    try std.testing.expect(!optionEnabled(&normal.dispatch, "--reviewed"));
}

test "coordinator build options preserve selected packages and reviewed digest" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const encoded = "5a" ** std.crypto.hash.sha2.Sha256.digest_length;
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "build",
        "--coordinator-child",
        "--review-digest",
        encoded,
        "--package",
        "demo",
        "--package",
        "demo-docs",
        "--check",
        "--noverify",
        "/tmp/PKGBUILD",
    });
    try std.testing.expect(optionEnabled(&outcome.dispatch, "--coordinator-child"));
    try std.testing.expect(optionEnabled(&outcome.dispatch, "--check"));
    try std.testing.expect(optionEnabled(&outcome.dispatch, "--noverify"));
    try std.testing.expectEqualStrings(encoded, optionValue(&outcome.dispatch, "--review-digest").?);
    var selected: usize = 0;
    for (outcome.dispatch.options) |option| {
        if (std.mem.eql(u8, option.name, "--package")) selected += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), selected);
    try std.testing.expectEqualStrings("/tmp/PKGBUILD", outcome.dispatch.positionals[0]);

    const digest = try parseReviewDigest(encoded);
    try std.testing.expectEqualSlices(u8, &([_]u8{0x5a} ** digest.len), &digest);
    try std.testing.expectError(error.InvalidReviewDigest, parseReviewDigest("abc"));
}
