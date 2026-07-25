const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gdk = bindings.gdk;
const glib = bindings.glib;
const gobject = bindings.gobject;
const c_string = @import("../helpers/c_string.zig");
const support = @import("support.zig");
const SizeConverter = @import("../helpers/size_converts.zig").SizeConverter;
const ShellyOperation = @import("../services/shelly_operation.zig").ShellyOperation;
const Event = @import("../services/shelly_operation.zig").Event;
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const ConfirmDialog = @import("../dialog/page/yn_dialog.zig").ConfirmDialog;
const PendingQuestion = @import("../services/shelly_operation.zig").PendingQuestion;
const TransactionQuestion = @import("../services/shelly_operation.zig").TransactionQuestion;
const TransactionPackage = @import("../services/shelly_operation.zig").TransactionPackage;
const MultiSelectDialog = @import("../dialog/page/multiselect.zig").MultiSelectDialog;
const PkgbuildReviewDialog = @import("../dialog/page/pkg_build.zig").PkgbuildReviewDialog;
const PlanDialog = @import("../dialog/page/plan.zig").PlanDialog;

pub const TransactionRequest = struct {
    title: []const u8,
    argv: []const []const u8,
    packages: []const []const u8,
    privileged: bool = true,
    on_complete: ?*const fn (ctx: *anyopaque, success: bool) void = null,
    ctx: ?*anyopaque = null,
};

const PackageRow = struct {
    name: [:0]const u8,
    root: *gtk.Box,
    status_label: *gtk.Label,
    progress: *gtk.ProgressBar,
};

pub const TransactionPage = extern struct {
    parent_instance: Parent,
    const Self = @This();
    pub const Parent = gtk.Box;
    pub const title: [:0]const u8 = "Transaction";
    const resource_path = "/com/shellyorg/shelly/ui/transaction_page.ui";

    const Private = struct {
        title_label: *gtk.Label,
        terminal_toggle: *gtk.Button,
        close_button: *gtk.Button,
        paned: *gtk.Paned,
        rows_box: *gtk.Box,
        terminal_scroll: *gtk.ScrolledWindow,
        terminal_view: *gtk.TextView,
        question_layer: *gtk.Box,
        status_label: *gtk.Label,
        arena: ?*std.heap.ArenaAllocator,
        rows: std.StringHashMapUnmanaged(*PackageRow),
        on_complete: ?*const fn (ctx: *anyopaque, success: bool) void,
        on_complete_ctx: ?*anyopaque,
        operation: ?*ShellyOperation,
        finished: bool,
        cancelled: bool,
        terminal_visible: bool,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyTransactionPage",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    fn priv(self: *Self) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const p = self.priv();
        std.debug.print("terminal_view={*} rows_box={*}\n", .{ p.terminal_view, p.rows_box });

        p.on_complete = null;
        p.on_complete_ctx = null;
        p.arena = null;
        p.rows = .empty;
        p.operation = null;
        p.cancelled = false;
        p.terminal_visible = true;
    }

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn run(self: *Self, request: TransactionRequest) void {
        std.debug.print("request: {s}\n", .{request.title});

        const p = self.priv();
        self.reset();

        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        p.arena = arena_ptr;
        const alloc = arena_ptr.allocator();

        var buf: [256]u8 = undefined;
        gtk.Label.setLabel(p.title_label, c_string.cstr(&buf, request.title));

        for (request.packages) |name| {
            const owned = alloc.dupeZ(u8, name) catch continue;
            const row = build_row(alloc, owned) catch continue;
            gtk.Box.append(p.rows_box, row.root.as(gtk.Widget));
            p.rows.put(alloc, owned, row) catch {};
        }

        const argv = alloc.alloc([]const u8, request.argv.len) catch return;
        for (request.argv, 0..) |a, i| {
            argv[i] = alloc.dupe(u8, a) catch return;
        }

        const op = std.heap.c_allocator.create(ShellyOperation) catch return;
        op.* = ShellyOperation.init(
            std.heap.c_allocator,
            &on_op_event,
            &on_op_done,
            &on_op_question,
            self,
        );
        op.threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
        op.io = op.threaded.io();
        p.operation = op;

        p.on_complete = request.on_complete;
        p.on_complete_ctx = request.ctx;

        const started = if (request.privileged) op.startPrivileged(argv) else op.start(argv);
        started catch {
            append_terminal(self, "Failed to start operation.");
            op.threaded.deinit();
            std.heap.c_allocator.destroy(op);
            p.operation = null;
        };
    }

    fn reset(self: *Self) void {
        const p = self.priv();
        p.cancelled = false;
        while (gtk.Widget.getFirstChild(p.rows_box.as(gtk.Widget))) |c| {
            gtk.Box.remove(p.rows_box, c);
        }
        p.rows.clearRetainingCapacity();
        const buffer = gtk.TextView.getBuffer(p.terminal_view);
        gtk.TextBuffer.setText(buffer, "", 0);
        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }
    }

    fn build_row(alloc: std.mem.Allocator, name: [:0]const u8) !*PackageRow {
        const row = try alloc.create(PackageRow);

        const card = gtk.Box.new(.vertical, 6);
        gtk.Widget.addCssClass(card.as(gtk.Widget), "pkg-card");

        const row_top = gtk.Box.new(.horizontal, 8);

        const name_label = gtk.Label.new(name);
        gtk.Widget.setHalign(name_label.as(gtk.Widget), .start);
        gtk.Widget.setHexpand(name_label.as(gtk.Widget), 1);
        gtk.Label.setXalign(name_label, 0);
        gtk.Widget.addCssClass(name_label.as(gtk.Widget), "pkg-name");
        gtk.Label.setEllipsize(name_label, .end);
        gtk.Box.append(row_top, name_label.as(gtk.Widget));

        const status = gtk.Label.new("Pending");
        gtk.Widget.setHalign(status.as(gtk.Widget), .end);
        gtk.Label.setXalign(status, 1);
        gtk.Label.setEllipsize(status, .end);
        gtk.Label.setMaxWidthChars(status, 32);
        gtk.Widget.addCssClass(status.as(gtk.Widget), "pkg-status");
        gtk.Box.append(row_top, status.as(gtk.Widget));

        gtk.Box.append(card, row_top.as(gtk.Widget));

        const progress = gtk.ProgressBar.new();
        gtk.Widget.setHexpand(progress.as(gtk.Widget), 1);
        gtk.Box.append(card, progress.as(gtk.Widget));

        row.* = .{
            .name = name,
            .root = card,
            .status_label = status,
            .progress = progress,
        };
        return row;
    }

    fn on_op_event(ctx: *anyopaque, event: Event) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.handle_event(event);
    }

    fn on_op_done(ctx: *anyopaque, exit_code: u8) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.handle_done(exit_code);
    }

    fn handle_event(self: *Self, event: Event) void {
        //  std.debug.print("EVENT: {any}\n", .{event});
        switch (event) {
            .info => |i| {
                append_terminal(self, i.message);
                if (std.mem.eql(u8, i.event_type, "TransactionCancelled"))
                    self.priv().cancelled = true;

                if (std.mem.eql(u8, i.event_type, "TransactionStart")) {
                    // optionally set a global status line
                } else if (std.mem.eql(u8, i.event_type, "TransactionDone")) {
                    var it = self.priv().rows.valueIterator();
                    while (it.next()) |row| mark_row_done(row.*);
                } else if (std.mem.eql(u8, i.event_type, "TransactionFailed")) {
                    var it = self.priv().rows.valueIterator();
                    while (it.next()) |row| mark_row_failed(row.*);
                } else if (i.package_name) |name| {
                    if (find_row(self, name)) |row| {
                        var buf: [64]u8 = undefined;
                        const status = if (std.mem.eql(u8, i.event_type, "aur_build_output"))
                            i.message
                        else if (std.mem.eql(u8, i.event_type, "aur_build_error"))
                            "Build warning"
                        else if (std.mem.eql(u8, i.event_type, "aur_build_start"))
                            "Building"
                        else if (std.mem.eql(u8, i.event_type, "aur_build_done"))
                            "Built"
                        else if (std.mem.eql(u8, i.event_type, "aur_install_start"))
                            "Installing"
                        else if (std.mem.eql(u8, i.event_type, "aur_install_done"))
                            "Installed"
                        else if (std.mem.eql(u8, i.event_type, "aur_download_start"))
                            "Downloading"
                        else
                            i.event_type;
                        gtk.Label.setLabel(row.status_label, c_string.cstr(&buf, status));
                    }
                }
            },
            .err => |e| append_terminal(self, e.message),
            .alpm_progress => |pr| {
                if (find_row(self, pr.package_name)) |row| {
                    const is_download = std.mem.eql(u8, pr.progress_type, "PackageDownload") or
                        std.mem.eql(u8, pr.progress_type, "AurDownload");
                    const phase: []const u8 = if (std.mem.eql(u8, pr.progress_type, "MakepkgBuild"))
                        pr.message orelse "Building"
                    else if (std.mem.eql(u8, pr.progress_type, "MakepkgPackage"))
                        pr.message orelse "Packaging"
                    else if (is_download)
                        "Downloading"
                    else
                        "Installing";
                        
                if (is_transaction_phase(pr.progress_type)) {
                    var gbuf: [128]u8 = undefined;
                    gtk.Label.setLabel(
                        self.priv().status_label,
                        c_string.cstr(&gbuf, phase_label(pr.progress_type)),
                    );
                    return;
                }

                if (ensure_row(self, pr.package_name)) |row| {
                    const is_download = std.mem.eql(u8, pr.progress_type, "PackageDownload") or
                        std.mem.eql(u8, pr.progress_type, "AurDownload");
                    if (is_download and pr.total_download > 0) {
                        const fraction = @as(f64, @floatFromInt(pr.current_download)) /
                            @as(f64, @floatFromInt(pr.total_download));
                        gtk.ProgressBar.setFraction(row.progress, fraction);
                        var cur_buf: [32]u8 = undefined;
                        var tot_buf: [32]u8 = undefined;
                        var label_buf: [96]u8 = undefined;
                        const cur = SizeConverter.convert_null_term(&cur_buf, pr.current_download);
                        const tot = SizeConverter.convert_null_term(&tot_buf, pr.total_download);
                        if (std.fmt.bufPrintZ(&label_buf, "Downloading — {s} / {s}", .{ cur, tot })) |text| {
                            gtk.Label.setLabel(row.status_label, text);
                        } else |_| {
                            var buf: [64]u8 = undefined;
                            gtk.Label.setLabel(row.status_label, c_string.cstr(&buf, phase_label(pr.progress_type)));
                        }
                    } else {
                        var buf: [64]u8 = undefined;
                        gtk.Label.setLabel(row.status_label, c_string.cstr(&buf, phase_label(pr.progress_type)));
                        gtk.ProgressBar.pulse(row.progress);
                    }
                }
            },
            .flatpak_progress => |pr| {
                if (pr.status) |s| append_terminal(self, s);
                _ = pr.percentage;
            },
            .appimage_progress => |pr| {
                if (pr.status) |s| append_terminal(self, s);
                _ = pr.percentage;
            },
            .unknown => {},
        }
    }

    fn is_transaction_phase(progress_type: []const u8) bool {
        return std.mem.eql(u8, progress_type, "LoadStart") or
            std.mem.eql(u8, progress_type, "KeyringStart") or
            std.mem.eql(u8, progress_type, "IntegrityStart") or
            std.mem.eql(u8, progress_type, "ConflictsStart") or
            std.mem.eql(u8, progress_type, "DiskspaceStart") or
            std.mem.eql(u8, progress_type, "DatabaseDownload");
    }

    fn ensure_row(self: *Self, name: []const u8) ?*PackageRow {
        const p = self.priv();
        if (name.len == 0) return null;
        if (std.mem.startsWith(u8, name, "http")) return null;
        if (p.rows.get(name)) |row| return row;

        const arena = p.arena orelse return null;
        const alloc = arena.allocator();
        const owned = alloc.dupeZ(u8, name) catch return null;
        const row = build_row(alloc, owned) catch return null;
        gtk.Box.append(p.rows_box, row.root.as(gtk.Widget));
        p.rows.put(alloc, owned, row) catch return null;
        return row;
    }

    fn phase_label(progress_type: []const u8) []const u8 {
        if (std.mem.eql(u8, progress_type, "AurDownload")) return "Downloading";
        if (std.mem.eql(u8, progress_type, "MakepkgBuild")) return "Building";
        if (std.mem.eql(u8, progress_type, "MakepkgPackage")) return "Packaging";
        if (std.mem.eql(u8, progress_type, "PackageDownload")) return "Downloading";
        if (std.mem.eql(u8, progress_type, "AddStart")) return "Installing";
        if (std.mem.eql(u8, progress_type, "UpgradeStart")) return "Upgrading";
        if (std.mem.eql(u8, progress_type, "DowngradeStart")) return "Downgrading";
        if (std.mem.eql(u8, progress_type, "ReinstallStart")) return "Reinstalling";
        if (std.mem.eql(u8, progress_type, "RemoveStart")) return "Removing";
        return "Working";
    }

    fn find_row(self: *Self, name: []const u8) ?*PackageRow {
        return self.priv().rows.get(name);
    }

    fn mark_row_done(row: *PackageRow) void {
        gtk.Label.setLabel(row.status_label, "Done");
        gtk.ProgressBar.setFraction(row.progress, 1.0);
        gtk.Widget.addCssClass(row.status_label.as(gtk.Widget), "status-done");
    }

    fn mark_row_failed(row: *PackageRow) void {
        gtk.Label.setLabel(row.status_label, "Failed");
        gtk.ProgressBar.setFraction(row.progress, 1.0);
        gtk.Widget.addCssClass(row.status_label.as(gtk.Widget), "status-failed");
    }

    fn handle_done(self: *Self, exit_code: u8) void {
        const p = self.priv();
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Finished (exit {d})", .{exit_code}) catch "Finished";
        append_terminal(self, msg);

        gtk.Widget.setVisible(p.close_button.as(gtk.Widget), 1);
        p.finished = true;

        if (exit_code == 0 and !p.cancelled) {
            var it = p.rows.valueIterator();
            while (it.next()) |row_ptr| {
                mark_row_done(row_ptr.*);
            }
        } else if (!p.cancelled) {
            var it = p.rows.valueIterator();
            while (it.next()) |row_ptr| {
                mark_row_failed(row_ptr.*);
            }
        } else {
            var it = p.rows.valueIterator();
            while (it.next()) |row_ptr|
                gtk.Label.setLabel(row_ptr.*.status_label, "Cancelled");
        }

        if (p.on_complete) |cb| {
            std.debug.print("on_complete set, ctx={}\n", .{p.on_complete_ctx != null});
            if (p.on_complete_ctx) |c| cb(c, exit_code == 0 and !p.cancelled);
        } else {
            std.debug.print("on_complete is NULL\n", .{});
        }

        if (p.operation) |op| {
            if (op.reader) |t| t.join();
            op.threaded.deinit();
            std.heap.c_allocator.destroy(op);
            p.operation = null;
        }
    }

    fn append_terminal(self: *Self, text: []const u8) void {
        const p = self.priv();
        const buffer = gtk.TextView.getBuffer(p.terminal_view);
        var end: gtk.TextIter = undefined;
        gtk.TextBuffer.getEndIter(buffer, &end);

        var buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrintZ(&buf, "{s}\n", .{text}) catch {
            return;
        };
        gtk.TextBuffer.insert(buffer, &end, line.ptr, @intCast(line.len));

        gtk.TextBuffer.getEndIter(buffer, &end);
        const mark = gtk.TextBuffer.createMark(buffer, null, &end, 0);
        gtk.TextView.scrollToMark(p.terminal_view, mark, 0, 1, 0, 1);
    }

    fn on_terminal_toggle(self: *Self) callconv(.c) void {
        const p = self.priv();
        p.terminal_visible = !p.terminal_visible;
        gtk.Widget.setVisible(p.terminal_scroll.as(gtk.Widget), @intFromBool(p.terminal_visible));
    }

    fn on_close(self: *Self) callconv(.c) void {
        if (support.getWindow(ShellyWindow, self)) |win| {
            win.hideLockout();
        }
    }

    fn on_key_pressed(self: *Self, keyval: c_uint, keycode: c_uint, state: gdk.ModifierType) callconv(.c) c_int {
        const p = self.priv();
        if (!p.finished) return 0;
        if (keyval == gdk.KEY_Escape) {
            if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();
            return 1;
        }
        _ = keycode;
        _ = state;
        return 0;
    }

    fn on_op_question(ctx: *anyopaque, pending: *PendingQuestion) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.handle_question(pending);
    }

    fn handle_question(self: *Self, pending: *PendingQuestion) void {
        const p = self.priv();
        std.debug.print("handle_question: question_layer={*}\n", .{p.question_layer});

        switch (pending.request) {
            .yes_no => |q| {
                const qa = pending.arena.allocator();
                const text_z = qa.dupeZ(u8, q.question_text) catch {
                    pending.operation.answerYesNo(q.question_id, false) catch {};
                    pending.destroy();
                    return;
                };

                pending.on_dismiss = &dismiss_question;
                pending.dismiss_ctx = self;

                const dialog = ConfirmDialog.new("Confirm", text_z, &on_yesno_response, pending);
                dialog.setButtons("Yes", "No");

                gtk.Box.append(p.question_layer, dialog.as(gtk.Widget));
                gtk.Widget.setVisible(p.question_layer.as(gtk.Widget), 1);
                gtk.Widget.setVisible(dialog.as(gtk.Widget), 1);
                gtk.Widget.setHalign(p.question_layer.as(gtk.Widget), .center);
                gtk.Widget.setValign(p.question_layer.as(gtk.Widget), .center);
                std.debug.print("dialog widget: {*}, visible={}\n", .{ dialog, gtk.Widget.getVisible(dialog.as(gtk.Widget)) });
            },
            .select_many => |q| {
                pending.on_dismiss = &dismiss_question;
                pending.dismiss_ctx = self;

                const dialog = MultiSelectDialog.new(
                    pending.arena.allocator(),
                    q.prompt,
                    q.options,
                    &on_multiselect_response,
                    pending,
                );

                gtk.Box.append(p.question_layer, dialog.as(gtk.Widget));
                gtk.Widget.setVisible(p.question_layer.as(gtk.Widget), 1);
            },
            .select_one => |q| {
                _ = q;
            },
            .pkgbuild => |q| {
                var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
                defer arena.deinit();
                const a = arena.allocator();

                const name = a.dupeZ(u8, q.package_name) catch return;

                const lines = a.alloc([:0]const u8, q.diff_lines.len) catch return;
                for (q.diff_lines, 0..) |line, i| {
                    lines[i] = a.dupeZ(u8, line) catch return;
                }

                const warns = a.alloc(PkgbuildReviewDialog.Warning, q.warnings.len) catch return;
                for (q.warnings, 0..) |w, i| {
                    warns[i] = .{
                        .tool = a.dupeZ(u8, w.Tool) catch return,
                        .hook = a.dupeZ(u8, w.Hook) catch return,
                        .severity = a.dupeZ(u8, w.Severity) catch return,
                        .message = a.dupeZ(u8, w.Message) catch return,
                        .matched_line = a.dupeZ(u8, w.MatchedLine) catch return,
                    };
                }

                pending.on_dismiss = &dismiss_question;
                pending.dismiss_ctx = self;

                const dialog = PkgbuildReviewDialog.new(
                    name,
                    lines,
                    warns,
                    &.{},
                    &on_pkgbuild_response,
                    pending,
                );
                if (support.getWindow(ShellyWindow, self)) |win| {
                    gtk.Window.setTransientFor(dialog.as(gtk.Window), win.as(gtk.Window));
                }
                dialog.present();
            },
            .transaction => |q| {
                pending.on_dismiss = &dismiss_question;
                pending.dismiss_ctx = self;
                const dialog = PlanDialog.new(q, &on_plan_response, pending);
                gtk.Box.append(p.question_layer, dialog.as(gtk.Widget));
                gtk.Widget.setVisible(p.question_layer.as(gtk.Widget), 1);
            },
        }
    }

    fn on_plan_response(ctx: ?*anyopaque, confirmed: bool) void {
        const pending: *PendingQuestion = @ptrCast(@alignCast(ctx.?));
        respondToTransaction(pending, confirmed);
    }

    fn respondToTransaction(pending: *PendingQuestion, accepted: bool) void {
        if (pending.completed) return;
        pending.completed = true;
        pending.operation.answerTransaction(pending.questionId(), accepted) catch {
            pending.operation.cancel();
        };
        if (pending.on_dismiss) |cb| {
            if (pending.dismiss_ctx) |ctx| cb(ctx);
        }
        pending.destroy();
    }

    fn on_multiselect_response(ctx: ?*anyopaque, confirmed: bool, selected: []const usize) void {
        const pending: *PendingQuestion = @ptrCast(@alignCast(ctx.?));
        if (pending.completed) return;
        pending.completed = true;

        if (confirmed) {
            pending.operation.answerOptDeps(pending.questionId(), selected) catch {
                pending.operation.cancel();
            };
        } else {
            pending.operation.answerOptDeps(pending.questionId(), &.{}) catch {
                pending.operation.cancel();
            };
        }

        if (pending.on_dismiss) |cb| {
            if (pending.dismiss_ctx) |c| cb(c);
        }
        pending.destroy();
    }

    fn on_pkgbuild_response(ctx: ?*anyopaque, confirmed: bool) void {
        const pending: *PendingQuestion = @ptrCast(@alignCast(ctx.?));
        if (pending.completed) return;
        pending.completed = true;

        if (confirmed) {
            pending.operation.answerPkgbuildDiff(
                pending.questionId(),
                true,
            ) catch {
                pending.operation.cancel();
            };
        } else {
            pending.operation.answerPkgbuildDiff(pending.questionId(), false) catch {
                pending.operation.cancel();
            };
        }

        if (pending.on_dismiss) |cb| {
            if (pending.dismiss_ctx) |c| cb(c);
        }
        pending.destroy();
    }

    fn dismiss_question(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const p = self.priv();

        while (gtk.Widget.getFirstChild(p.question_layer.as(gtk.Widget))) |c| {
            gtk.Box.remove(p.question_layer, c);
        }
        gtk.Widget.setVisible(p.question_layer.as(gtk.Widget), 0);
    }

    fn on_yesno_response(ctx: ?*anyopaque, confirmed: bool) void {
        const pending: *PendingQuestion = @ptrCast(@alignCast(ctx.?));
        if (pending.completed) return;
        pending.completed = true;

        pending.operation.answerYesNo(pending.questionId(), confirmed) catch {
            pending.operation.cancel();
        };

        if (pending.on_dismiss) |cb| {
            if (pending.dismiss_ctx) |c| cb(c);
        }

        pending.destroy();
    }
    const template_children = .{
        .{ "title_label", @offsetOf(Private, "title_label") },
        .{ "terminal_toggle", @offsetOf(Private, "terminal_toggle") },
        .{ "paned", @offsetOf(Private, "paned") },
        .{ "rows_box", @offsetOf(Private, "rows_box") },
        .{ "terminal_scroll", @offsetOf(Private, "terminal_scroll") },
        .{ "terminal_view", @offsetOf(Private, "terminal_view") },
        .{ "close_button", @offsetOf(Private, "close_button") },
        .{ "question_layer", @offsetOf(Private, "question_layer") },
        .{ "status_label", @offsetOf(Private, "status_label") },
    };

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            const wc = gobject.ext.as(gtk.Widget.Class, class);
            gtk.Widget.Class.setTemplateFromResource(wc, resource_path);
            inline for (template_children) |c| {
                support.bindChild(class, Private.offset, c[0], c[1]);
            }
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_terminal_toggle", @ptrCast(&on_terminal_toggle));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_close", @ptrCast(&on_close));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_key_pressed", @ptrCast(&on_key_pressed));
        }
    };

    fn finalize(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.operation) |op| {
            op.cancel();
            if (op.reader) |t| t.join();
            op.threaded.deinit();
            std.heap.c_allocator.destroy(op);
            p.operation = null;
        }
        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }

        const parent_class: *gobject.Object.Class = @ptrCast(Class.parent);
        gobject.Object.virtual_methods.finalize.call(parent_class, self.as(gobject.Object));
    }
};
