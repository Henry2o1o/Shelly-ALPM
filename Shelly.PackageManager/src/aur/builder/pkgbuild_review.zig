const std = @import("std");
const operation_api = @import("operation_context");
const pkgbuild_parser = @import("../../pkgbuild/pkgbuild_parser.zig");
const pkgbuild_validation = @import("pkgbuild_validation.zig");
const review_integrity = @import("../review_integrity.zig");

pub const Digest = [std.crypto.hash.sha2.Sha256.digest_length]u8;

const binary_review_message =
    "Binary file (content is not displayed). Review the file's source and checksum before proceeding.";

pub const PreparedPkgbuildReview = struct {
    arena: std.heap.ArenaAllocator,
    validations: []pkgbuild_validation.PkgbuildValidation,
    findings: []operation_api.ReviewFinding,
    related_files: []operation_api.QuestionAttachment,
    reviewed_file_names: []const []const u8,
    digest: Digest,

    pub fn deinit(self: *PreparedPkgbuildReview) void {
        const allocator = self.arena.allocator();
        for (self.validations) |*validation| validation.deinit(allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Re-reads the PKGBUILD and every related local file immediately before
    /// execution and rejects any review/build race.
    pub fn verifyCurrent(
        self: *const PreparedPkgbuildReview,
        backing_allocator: std.mem.Allocator,
        io: std.Io,
        pkgbuild_path: []const u8,
        build_directory: []const u8,
    ) !void {
        var scratch = std.heap.ArenaAllocator.init(backing_allocator);
        defer scratch.deinit();
        const allocator = scratch.allocator();
        const current_pkgbuild = try std.Io.Dir.cwd().readFileAlloc(
            io,
            pkgbuild_path,
            allocator,
            .limited(32 * 1024 * 1024),
        );
        const current = try digestReview(
            allocator,
            io,
            build_directory,
            current_pkgbuild,
            self.reviewed_file_names,
        );
        if (!std.mem.eql(u8, &self.digest, &current))
            return error.ReviewedPkgbuildChanged;
    }
};

pub fn preparePkgbuildReview(
    backing_allocator: std.mem.Allocator,
    io: std.Io,
    build_directory: []const u8,
    pkgbuild_content: []const u8,
    package_builds: []const pkgbuild_parser.Pkgbuild,
) !PreparedPkgbuildReview {
    if (package_builds.len == 0) return error.MissingPackageName;

    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const validations = try allocator.alloc(pkgbuild_validation.PkgbuildValidation, package_builds.len);
    var validation_count: usize = 0;
    var findings: std.ArrayList(operation_api.ReviewFinding) = .empty;
    var reviewed_names = std.StringHashMap(void).init(allocator);

    for (package_builds, validations) |*package_build, *validation| {
        validation.* = try pkgbuild_validation.validatePkgbuildInfo(
            allocator,
            io,
            package_build,
            build_directory,
            pkgbuild_content,
        );
        validation_count += 1;
        try appendValidationFindings(allocator, &findings, validation);

        if (package_build.install_file) |install_file|
            try reviewed_names.put(install_file, {});
        if (package_build.local_source_files) |files| for (files) |file_name|
            try reviewed_names.put(file_name, {});
    }

    const file_names = try allocator.alloc([]const u8, reviewed_names.count());
    var name_index: usize = 0;
    var name_iterator = reviewed_names.keyIterator();
    while (name_iterator.next()) |name| : (name_index += 1)
        file_names[name_index] = try allocator.dupe(u8, name.*);
    std.mem.sort([]const u8, file_names, {}, stringBefore);

    const related_files = try allocator.alloc(operation_api.QuestionAttachment, file_names.len);
    for (file_names, related_files) |file_name, *attachment| {
        try review_integrity.requireReviewedFile(allocator, io, build_directory, file_name);
        const path = try std.fs.path.join(allocator, &.{ build_directory, file_name });
        const content = try std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            allocator,
            .limited(32 * 1024 * 1024),
        );
        attachment.* = .{
            .name = file_name,
            .content = if (std.unicode.utf8ValidateSlice(content)) content else binary_review_message,
        };
    }

    // Finish every arena-backed allocation before copying the arena into the
    // returned owner. Allocating after the copy can leave its chunk list stale.
    const owned_findings = try findings.toOwnedSlice(allocator);
    const digest = try digestReview(
        allocator,
        io,
        build_directory,
        pkgbuild_content,
        file_names,
    );
    return .{
        .arena = arena,
        .validations = validations[0..validation_count],
        .findings = owned_findings,
        .related_files = related_files,
        .reviewed_file_names = file_names,
        .digest = digest,
    };
}

fn appendValidationFindings(
    allocator: std.mem.Allocator,
    destination: *std.ArrayList(operation_api.ReviewFinding),
    validation: *const pkgbuild_validation.PkgbuildValidation,
) !void {
    for ([_][]const pkgbuild_validation.ValidationFinding{
        validation.post_install.findings.items,
        validation.homograph.findings.items,
        validation.local_source.findings.items,
    }) |source| for (source) |finding| try destination.append(allocator, .{
        .tool = finding.tool,
        .severity = switch (finding.severity) {
            .info => .info,
            .warning => .warning,
            .critical => .critical,
        },
        .hook = finding.hook,
        .matched_line = finding.matched_line,
        .message = finding.message,
    });
}

fn digestReview(
    allocator: std.mem.Allocator,
    io: std.Io,
    build_directory: []const u8,
    pkgbuild_content: []const u8,
    file_names: []const []const u8,
) !Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashReviewField(&hash, "PKGBUILD", pkgbuild_content);
    for (file_names) |file_name| {
        try review_integrity.requireReviewedFile(allocator, io, build_directory, file_name);
        const path = try std.fs.path.join(allocator, &.{ build_directory, file_name });
        defer allocator.free(path);
        const content = try std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            allocator,
            .limited(32 * 1024 * 1024),
        );
        defer allocator.free(content);
        hashReviewField(&hash, file_name, content);
    }
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn hashReviewField(
    hash: *std.crypto.hash.sha2.Sha256,
    name: []const u8,
    content: []const u8,
) void {
    const name_length: u64 = @intCast(name.len);
    const content_length: u64 = @intCast(content.len);
    hash.update(std.mem.asBytes(&name_length));
    hash.update(name);
    hash.update(std.mem.asBytes(&content_length));
    hash.update(content);
}

fn stringBefore(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

test "aggregate split-package review includes member-specific files and detects changes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const build_directory = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(build_directory);
    try temporary.dir.writeFile(io, .{ .sub_path = "one.patch", .data = "one\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "two.install", .data = "post_install() { true; }\n" });
    const content =
        \\pkgbase=review-demo
        \\pkgname=('review-one' 'review-two')
        \\pkgver=1
        \\pkgrel=1
        \\source=('one.patch')
        \\package_review-one() { true; }
        \\package_review-two() {
        \\  install=two.install
        \\}
    ;
    const names = [_][]const u8{ "review-one", "review-two" };
    var builds: [2]pkgbuild_parser.Pkgbuild = undefined;
    var parsed: usize = 0;
    defer for (builds[0..parsed]) |*build| build.deinit(allocator);
    for (names, &builds) |name, *build| {
        build.* = try (pkgbuild_parser.PkgbuildParser{
            .allocator = allocator,
            .io = io,
            .selected_package_name = name,
        }).parser_content(content, build_directory);
        parsed += 1;
    }

    var review = try preparePkgbuildReview(allocator, io, build_directory, content, &builds);
    defer review.deinit();
    try std.testing.expectEqual(@as(usize, 2), review.related_files.len);

    const pkgbuild_path = try std.fs.path.join(allocator, &.{ build_directory, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    try temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = content });
    try review.verifyCurrent(allocator, io, pkgbuild_path, build_directory);
    try temporary.dir.writeFile(io, .{ .sub_path = "one.patch", .data = "changed\n" });
    try std.testing.expectError(
        error.ReviewedPkgbuildChanged,
        review.verifyCurrent(allocator, io, pkgbuild_path, build_directory),
    );
}
