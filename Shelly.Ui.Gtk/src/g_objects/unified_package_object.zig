const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gobject = bindings.gobject;
const UnifiedPackage = @import("../models/unified_package.zig").UnifiedPackage;
const Source = @import("../models/unified_package.zig").Source;

pub const UnifiedPackageObject = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gobject.Object;

    const Private = struct {
        arena: ?*std.heap.ArenaAllocator,
        package: UnifiedPackage,
        selected: bool = false,
        installed: bool = false,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyUnifiedPackageObject",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    fn priv(self: *Self) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const p = self.priv();
        p.arena = null;
        p.selected = false;
        p.installed = false;
        p.package = .{
            .Id = "",
            .Name = "",
            .Version = "",
            .Source = Source.repo,
            .Description = null,
            .Url = null,
            .Depends = null,
            .OptDepends = null,
            .CheckDepends = null,
            .Conflicts = null,
            .Provides = null,
            .Replaces = null,
            .Groups = null,
            .License = null,
        };
    }

    pub fn new(package: UnifiedPackage) error{OutOfMemory}!*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.as(gobject.Object).unref();

        const arena = try std.heap.c_allocator.create(std.heap.ArenaAllocator);
        errdefer std.heap.c_allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();

        const p = self.priv();
        p.package = try clonePackage(arena.allocator(), package);
        p.arena = arena;
        return self;
    }

    pub fn getPackage(self: *const Self) *const UnifiedPackage {
        return &@constCast(self).priv().package;
    }

    pub fn getId(self: *const Self) [:0]const u8 {
        return self.getPackage().Id;
    }

    pub fn getName(self: *const Self) [:0]const u8 {
        return self.getPackage().Name;
    }

    pub fn getVersion(self: *const Self) [:0]const u8 {
        return self.getPackage().Version;
    }

    pub fn getDescription(self: *const Self) [:0]const u8 {
        return if (self.getPackage().Description) |value| value else "";
    }

    pub fn getUrl(self: *const Self) ?[:0]const u8 {
        return self.getPackage().Url;
    }

    pub fn getDepends(self: *const Self) []const []const u8 {
        return self.getPackage().Depends orelse &.{};
    }

    pub fn getOptDepends(self: *const Self) []const []const u8 {
        return self.getPackage().OptDepends orelse &.{};
    }

    pub fn getCheckDepends(self: *const Self) []const []const u8 {
        return self.getPackage().CheckDepends orelse &.{};
    }

    pub fn getConflicts(self: *const Self) []const []const u8 {
        return self.getPackage().Conflicts orelse &.{};
    }

    pub fn getProvides(self: *const Self) []const []const u8 {
        return self.getPackage().Provides orelse &.{};
    }

    pub fn getReplaces(self: *const Self) []const []const u8 {
        return self.getPackage().Replaces orelse &.{};
    }

    pub fn getGroups(self: *const Self) []const []const u8 {
        return self.getPackage().Groups orelse &.{};
    }

    pub fn getLicense(self: *const Self) []const []const u8 {
        return self.getPackage().License orelse &.{};
    }

    pub fn getSource(self: *const Self) Source {
        return self.getPackage().Source orelse Source.repo;
    }

    pub fn isSelected(self: *const Self) bool {
        return @constCast(self).priv().selected;
    }

    pub fn setSelected(self: *Self, selected: bool) void {
        self.priv().selected = selected;
    }

    pub fn toggleSelected(self: *Self) bool {
        const p = self.priv();
        p.selected = !p.selected;
        return p.selected;
    }

    pub fn isInstalled(self: *const Self) bool {
        return @constCast(self).priv().installed;
    }

    pub fn setInstalled(self: *Self, installed: bool) void {
        self.priv().installed = installed;
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn clonePackage(allocator: std.mem.Allocator, source: UnifiedPackage) !UnifiedPackage {
        return .{
            .Id = try allocator.dupeZ(u8, source.Id),
            .Name = try allocator.dupeZ(u8, source.Name),
            .Version = try allocator.dupeZ(u8, source.Version),
            .Description = if (source.Description) |value| try allocator.dupeZ(u8, value) else null,
            .Url = if (source.Url) |value| try allocator.dupeZ(u8, value) else null,
            .Depends = try cloneOptionalStrings(allocator, source.Depends),
            .OptDepends = try cloneOptionalStrings(allocator, source.OptDepends),
            .CheckDepends = try cloneOptionalStrings(allocator, source.CheckDepends),
            .Conflicts = try cloneOptionalStrings(allocator, source.Conflicts),
            .Provides = try cloneOptionalStrings(allocator, source.Provides),
            .Replaces = try cloneOptionalStrings(allocator, source.Replaces),
            .Groups = try cloneOptionalStrings(allocator, source.Groups),
            .License = try cloneOptionalStrings(allocator, source.License),
        };
    }

    fn cloneOptionalStrings(
        allocator: std.mem.Allocator,
        source: ?[]const [:0]const u8,
    ) !?[]const [:0]const u8 {
        const values = source orelse return null;
        const result = try allocator.alloc([:0]const u8, values.len);
        for (values, 0..) |value, index| result[index] = try allocator.dupeZ(u8, value);
        return result;
    }

    fn asZ(value: []const u8) [:0]const u8 {
        return value.ptr[0..value.len :0];
    }

    fn finalize(object: *gobject.Object) callconv(.c) void {
        const self = gobject.ext.cast(Self, object) orelse {
            Class.parent.f_finalize.?(object);
            return;
        };
        const p = self.priv();
        if (p.arena) |arena| {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            p.arena = null;
        }
        Class.parent.f_finalize.?(object);
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            const object_class = class.as(gobject.Object.Class);
            object_class.f_finalize = &finalize;
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};

test "Unified GObject owns package data" {
    const source = UnifiedPackage{
        .Id = "2160856",
        .Name = "polymc",
        .Version = "7.1-2",
        .Description = "Minecraft launcher with the ability to manage multiple instances",
        .Url = "https://github.com/PolyMC/PolyMC",
        .Depends = &.{ "java-runtime", "libgl", "qt6-base" },
        .License = &.{"GPL3"},
    };

    const object = try UnifiedPackageObject.new(source);
    defer object.as(gobject.Object).unref();

    try std.testing.expectEqualStrings("2160856", object.getId());
    try std.testing.expectEqualStrings("polymc", object.getName());
    try std.testing.expectEqualStrings("7.1-2", object.getVersion());
    try std.testing.expectEqualStrings("Minecraft launcher with the ability to manage multiple instances", object.getDescription());
    try std.testing.expectEqualStrings("https://github.com/PolyMC/PolyMC", object.getUrl().?);
    try std.testing.expectEqualStrings("libgl", object.getDepends()[1]);
    try std.testing.expectEqualStrings("GPL3", object.getLicense()[0]);
    try std.testing.expect(!object.isSelected());
}

test "Unified GObject handles absent optional fields" {
    const object = try UnifiedPackageObject.new(.{
        .Id = "1",
        .Name = "x",
        .Version = "1-1",
    });
    defer object.as(gobject.Object).unref();

    try std.testing.expectEqualStrings("", object.getDescription());
    try std.testing.expect(object.getUrl() == null);
    try std.testing.expectEqual(@as(usize, 0), object.getConflicts().len);
}
