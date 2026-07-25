const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gdk = bindings.gdk;
const glib = bindings.glib;
const gobject = bindings.gobject;
const c_string = @import("../helpers/c_string.zig");
const support = @import("support.zig");
const ShellyOperation = @import("../services/shelly_operation.zig").ShellyOperation;
const Event = @import("../services/shelly_operation.zig").Event;
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const ConfirmDialog = @import("../dialog/page/yn_dialog.zig").ConfirmDialog;
const PendingQuestion = @import("../services/shelly_operation.zig").PendingQuestion;
const TransactionQuestion = @import("../services/shelly_operation.zig").TransactionQuestion;
const TransactionPackage = @import("../services/shelly_operation.zig").TransactionPackage;
const MultiSelectDialog = @import("../dialog/page/multiselect.zig").MultiSelectDialog;

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
        std.debug.print("EVENT: {any}\n", .{event});
        switch (event) {
            .info => |i| {
                append_terminal(self, i.message);
                if (std.mem.eql(u8, i.event_type, "TransactionCancelled"))
                    self.priv().cancelled = true;

                if (i.package_name) |name| {
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

                    if (!is_download and pr.percent >= 100) {
                        mark_row_done(row);
                    } else {
                        var buf: [64]u8 = undefined;
                        gtk.Label.setLabel(row.status_label, c_string.cstr(&buf, phase));
                        gtk.ProgressBar.setFraction(row.progress, @as(f64, @floatFromInt(pr.percent)) / 100.0);
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
            .transaction => |q| {
                pending.on_dismiss = &dismiss_question;
                pending.dismiss_ctx = self;
                self.addPlanRows(q.packages);
                const dialog = buildTransactionDialog(pending, q);
                gtk.Box.append(p.question_layer, dialog.as(gtk.Widget));
                gtk.Widget.setVisible(p.question_layer.as(gtk.Widget), 1);
            },
        }
    }

    fn addPlanRows(self: *Self, packages: []const TransactionPackage) void {
        const p = self.priv();
        const allocator = if (p.arena) |arena| arena.allocator() else return;
        for (packages) |package| {
            if (p.rows.get(package.name)) |row| {
                gtk.Label.setLabel(row.status_label, "Awaiting confirmation");
                continue;
            }
            const owned = allocator.dupeZ(u8, package.name) catch continue;
            const row = build_row(allocator, owned) catch continue;
            gtk.Label.setLabel(row.status_label, "Awaiting confirmation");
            gtk.Box.append(p.rows_box, row.root.as(gtk.Widget));
            p.rows.put(allocator, owned, row) catch {};
        }
    }

    fn buildTransactionDialog(
        pending: *PendingQuestion,
        question: TransactionQuestion,
    ) *gtk.Box {
        const card = gtk.Box.new(.vertical, 12);
        gtk.Widget.addCssClass(card.as(gtk.Widget), "pkg-card");
        gtk.Widget.setSizeRequest(card.as(gtk.Widget), 720, -1);
        gtk.Widget.setMarginStart(card.as(gtk.Widget), 16);
        gtk.Widget.setMarginEnd(card.as(gtk.Widget), 16);
        gtk.Widget.setMarginTop(card.as(gtk.Widget), 16);
        gtk.Widget.setMarginBottom(card.as(gtk.Widget), 16);

        const title_label = gtk.Label.new("Confirm transaction");
        gtk.Widget.setHalign(title_label.as(gtk.Widget), .start);
        gtk.Label.setXalign(title_label, 0);
        gtk.Widget.addCssClass(title_label.as(gtk.Widget), "detail-title");
        gtk.Box.append(card, title_label.as(gtk.Widget));

        var question_buffer: [512]u8 = undefined;
        const prompt = gtk.Label.new(c_string.cstr(&question_buffer, question.question_text));
        gtk.Widget.setHalign(prompt.as(gtk.Widget), .start);
        gtk.Label.setXalign(prompt, 0);
        gtk.Label.setWrap(prompt, 1);
        gtk.Box.append(card, prompt.as(gtk.Widget));

        const package_box = gtk.Box.new(.vertical, 8);
        for (question.packages) |package|
            gtk.Box.append(package_box, buildPlanPackageRow(package).as(gtk.Widget));

        const scroll = gtk.ScrolledWindow.new();
        gtk.ScrolledWindow.setMinContentHeight(scroll, 220);
        gtk.ScrolledWindow.setMaxContentHeight(scroll, 480);
        gtk.ScrolledWindow.setPropagateNaturalHeight(scroll, 1);
        gtk.ScrolledWindow.setChild(scroll, package_box.as(gtk.Widget));
        gtk.Box.append(card, scroll.as(gtk.Widget));

        const totals = gtk.Box.new(.vertical, 2);
        appendPlanTotal(totals, "Total download", question.total_download_size);
        appendPlanTotal(totals, "Total installed", question.total_installed_size);
        if (question.net_installed_size) |net| {
            var text_buffer: [128]u8 = undefined;
            const absolute: u64 = @abs(net);
            var size_buffer: [64]u8 = undefined;
            const text = std.fmt.bufPrint(
                &text_buffer,
                "Net installed-size change: {s}{s}",
                .{ if (net < 0) "-" else "+", formatBytes(&size_buffer, absolute) },
            ) catch "Net installed-size change: unknown";
            var c_buffer: [128]u8 = undefined;
            const label = gtk.Label.new(c_string.cstr(&c_buffer, text));
            gtk.Widget.setHalign(label.as(gtk.Widget), .start);
            gtk.Label.setXalign(label, 0);
            gtk.Widget.addCssClass(label.as(gtk.Widget), "dim-label");
            gtk.Box.append(totals, label.as(gtk.Widget));
        }
        gtk.Box.append(card, totals.as(gtk.Widget));

        const buttons = gtk.Box.new(.horizontal, 8);
        gtk.Widget.setHalign(buttons.as(gtk.Widget), .end);
        const cancel = gtk.Button.newWithLabel("Cancel");
        const confirm = gtk.Button.newWithLabel("Install");
        gtk.Widget.addCssClass(confirm.as(gtk.Widget), "suggested-action");
        _ = gtk.Button.signals.clicked.connect(cancel, *PendingQuestion, &on_transaction_cancel, pending, .{});
        _ = gtk.Button.signals.clicked.connect(confirm, *PendingQuestion, &on_transaction_confirm, pending, .{});
        gtk.Box.append(buttons, cancel.as(gtk.Widget));
        gtk.Box.append(buttons, confirm.as(gtk.Widget));
        gtk.Box.append(card, buttons.as(gtk.Widget));
        return card;
    }

    fn buildPlanPackageRow(package: TransactionPackage) *gtk.Box {
        const row = gtk.Box.new(.vertical, 2);
        gtk.Widget.addCssClass(row.as(gtk.Widget), "pkg-card");

        const heading = gtk.Box.new(.horizontal, 8);
        var name_buffer: [256]u8 = undefined;
        const name = gtk.Label.new(c_string.cstr(&name_buffer, package.name));
        gtk.Widget.setHalign(name.as(gtk.Widget), .start);
        gtk.Widget.setHexpand(name.as(gtk.Widget), 1);
        gtk.Label.setXalign(name, 0);
        gtk.Widget.addCssClass(name.as(gtk.Widget), "pkg-name");
        gtk.Box.append(heading, name.as(gtk.Widget));

        var role_buffer: [128]u8 = undefined;
        const role_text = std.fmt.bufPrint(&role_buffer, "{s} · {s}", .{
            displayRole(package.role),
            displaySource(package.source),
        }) catch package.role;
        var role_c_buffer: [128]u8 = undefined;
        const role = gtk.Label.new(c_string.cstr(&role_c_buffer, role_text));
        gtk.Widget.addCssClass(role.as(gtk.Widget), "dim-label");
        gtk.Box.append(heading, role.as(gtk.Widget));
        gtk.Box.append(row, heading.as(gtk.Widget));

        var detail_buffer: [512]u8 = undefined;
        var download_buffer: [64]u8 = undefined;
        var installed_buffer: [64]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buffer, "Version: {s}    Download: {s}    Installed: {s}", .{
            package.version orelse if (std.mem.eql(u8, package.source, "aur"))
                "Determined during build"
            else
                "Resolved by standard transaction",
            packageSizeText(&download_buffer, package.download_size, package.source),
            packageSizeText(&installed_buffer, package.installed_size, package.source),
        }) catch "";
        var detail_c_buffer: [512]u8 = undefined;
        const details = gtk.Label.new(c_string.cstr(&detail_c_buffer, detail));
        gtk.Widget.setHalign(details.as(gtk.Widget), .start);
        gtk.Label.setXalign(details, 0);
        gtk.Label.setWrap(details, 1);
        gtk.Widget.addCssClass(details.as(gtk.Widget), "dim-label");
        gtk.Box.append(row, details.as(gtk.Widget));
        return row;
    }

    fn appendPlanTotal(box: *gtk.Box, label_text: []const u8, size: ?u64) void {
        const value = size orelse return;
        var size_buffer: [64]u8 = undefined;
        var text_buffer: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&text_buffer, "{s}: {s}", .{
            label_text,
            formatBytes(&size_buffer, value),
        }) catch return;
        var c_buffer: [128]u8 = undefined;
        const label = gtk.Label.new(c_string.cstr(&c_buffer, text));
        gtk.Widget.setHalign(label.as(gtk.Widget), .start);
        gtk.Label.setXalign(label, 0);
        gtk.Widget.addCssClass(label.as(gtk.Widget), "dim-label");
        gtk.Box.append(box, label.as(gtk.Widget));
    }

    fn packageSizeText(buffer: []u8, size: ?u64, source: []const u8) []const u8 {
        if (size) |value| return formatBytes(buffer, value);
        return if (std.mem.eql(u8, source, "aur") or std.mem.eql(u8, source, "local"))
            "Determined during build"
        else
            "Resolved by standard transaction";
    }

    fn formatBytes(buffer: []u8, bytes: u64) []const u8 {
        const mib = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buffer, "{d:.2} MiB", .{mib}) catch "?";
    }

    fn displayRole(role: []const u8) []const u8 {
        if (std.mem.eql(u8, role, "runtime_dependency")) return "Runtime dependency";
        if (std.mem.eql(u8, role, "build_dependency")) return "Build dependency";
        if (std.mem.eql(u8, role, "check_dependency")) return "Check dependency";
        if (std.mem.eql(u8, role, "optional_dependency")) return "Optional dependency";
        if (std.mem.eql(u8, role, "requested")) return "Requested";
        return "Dependency";
    }

    fn displaySource(source: []const u8) []const u8 {
        if (std.mem.eql(u8, source, "aur")) return "AUR";
        if (std.mem.eql(u8, source, "local")) return "Local";
        return "Repository";
    }

    fn on_transaction_confirm(_: *gtk.Button, pending: *PendingQuestion) callconv(.c) void {
        respondToTransaction(pending, true);
    }

    fn on_transaction_cancel(_: *gtk.Button, pending: *PendingQuestion) callconv(.c) void {
        respondToTransaction(pending, false);
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
