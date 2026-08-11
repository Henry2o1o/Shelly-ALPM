const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gobject = bindings.gobject;
const search = @import("../models/search_result.zig");

pub const SearchResultObject = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gobject.Object;

    const Private = struct {
        arena: ?*std.heap.ArenaAllocator,
        result: search.SearchResult,
        selected: bool = false,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellySearchResultObject",
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
        p.result = .{};
    }

    pub fn new(result: search.SearchResult) error{OutOfMemory}!*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.as(gobject.Object).unref();

        const arena = try std.heap.c_allocator.create(std.heap.ArenaAllocator);
        errdefer std.heap.c_allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();

        const p = self.priv();
        p.result = try cloneResult(arena.allocator(), result);
        p.arena = arena;
        return self;
    }

    pub fn getResult(self: *const Self) *const search.SearchResult {
        return &@constCast(self).priv().result;
    }

    pub fn getSource(self: *const Self) search.Source {
        return self.getResult().source;
    }

    pub fn getName(self: *const Self) [:0]const u8 {
        return asZ(self.getResult().name);
    }

    pub fn getInstallTarget(self: *const Self) [:0]const u8 {
        return asZ(self.getResult().install_target);
    }

    pub fn getVersion(self: *const Self) [:0]const u8 {
        return asZ(self.getResult().version);
    }

    pub fn getDescription(self: *const Self) [:0]const u8 {
        return asZ(self.getResult().description);
    }

    pub fn getRepository(self: *const Self) [:0]const u8 {
        return asZ(self.getResult().repository);
    }

    pub fn isInstalled(self: *const Self) bool {
        return self.getResult().installed;
    }

    pub fn isOutOfDate(self: *const Self) bool {
        return self.getResult().out_of_date;
    }

    pub fn isVerified(self: *const Self) bool {
        return self.getResult().verified;
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

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn cloneResult(allocator: std.mem.Allocator, source: search.SearchResult) !search.SearchResult {
        return .{
            .source = source.source,
            .name = try allocator.dupeZ(u8, source.name),
            .install_target = try allocator.dupeZ(u8, source.install_target),
            .version = try allocator.dupeZ(u8, source.version),
            .description = try allocator.dupeZ(u8, source.description),
            .repository = try allocator.dupeZ(u8, source.repository),
            .installed = source.installed,
            .out_of_date = source.out_of_date,
            .verified = source.verified,
        };
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

test "search GObject owns result data" {
    const object = try SearchResultObject.new(.{
        .source = .aur,
        .name = "polymc",
        .install_target = "polymc",
        .version = "7.1-2",
        .description = "Minecraft launcher with the ability to manage multiple instances",
        .repository = "AUR",
        .out_of_date = true,
    });
    defer object.as(gobject.Object).unref();

    try std.testing.expectEqual(search.Source.aur, object.getSource());
    try std.testing.expectEqualStrings("polymc", object.getName());
    try std.testing.expectEqualStrings("polymc", object.getInstallTarget());
    try std.testing.expectEqualStrings("7.1-2", object.getVersion());
    try std.testing.expectEqualStrings("AUR", object.getRepository());
    try std.testing.expect(object.isOutOfDate());
    try std.testing.expect(!object.isInstalled());
    try std.testing.expect(!object.isSelected());
}

test "search GObject handles defaults" {
    const object = try SearchResultObject.new(.{});
    defer object.as(gobject.Object).unref();

    try std.testing.expectEqual(search.Source.standard, object.getSource());
    try std.testing.expectEqualStrings("", object.getName());
    try std.testing.expectEqualStrings("", object.getDescription());
}
