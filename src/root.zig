const wl = @import("wayland").client.wl;
const std = @import("std");
const tmp = @import("tmpfile.zig");
const mem = std.mem;
const posix = std.posix;
const os = std.os;
const fs = std.fs;
const channel = @import("channel.zig");
const mimeTypeIsText = @import("MimeType.zig").mimeTypeIsText;
const assert = std.debug.assert;
const MimeType = @import("MimeType.zig");
const GlobalList = @import("wayland/GlobalList.zig");
const Seat = @import("wayland/Seat.zig");
const Device = @import("Device.zig");
const Magic = @import("Magic.zig");
const Display = @import("wayland/Display.zig");
const Contexts = @import("Contexts.zig");
pub const Backend = @import("Device.zig").Backend;

const ClipboardContent = struct {
    pipe: i32,
    mime_types: std.ArrayList([:0]const u8),

    const Self = @This();

    pub fn mimeTypes(self: *Self) [][:0]const u8 {
        return self.mime_types.items;
    }

    pub fn deinit(self: *Self, alloc: mem.Allocator) void {
        for (self.mime_types.items) |mime_type| {
            alloc.free(mime_type);
        }
        self.mime_types.deinit(alloc);
    }
};

const CopySignal = struct {
    receiver: channel.broadcast(void).Receiver,

    const Self = @This();

    pub fn cancelAwait(self: *Self) void {
        self.receiver.receive();
    }

    pub fn cancelled(self: *Self) bool {
        return self.receiver.tryReceive() != null;
    }
};

const PasteContext = struct {
    offer: ?*Device.DataOffer = null,
    mime_types: std.ArrayList([:0]const u8) = .empty,
    alloc: mem.Allocator,
    primary: bool,

    const Self = @This();

    fn deinit(self: *Self) void {
        if (self.offer) |offer| {
            offer.deinit();
            self.offer = null;
        }
        self.mime_types.clearRetainingCapacity();
        self.primary = false;
        self.alloc = undefined;
    }
};

pub const Event = union(enum) {
    primary_selection: i32,
    selection: i32,
};

pub const Source = union(enum) {
    file: fs.File,
    bytes: []const u8,
};

pub const WlClipboard = struct {
    globals: GlobalList,
    display: Display,
    compositor: *wl.Compositor,
    seat: Seat,
    device: Device,
    regular_data_source: Device.DataSource,
    primary_data_source: Device.DataSource,
    dispatch_thread: ?std.Thread = null,
    sender: channel.broadcast(void).Sender,
    contexts: Contexts,

    const Self = @This();

    pub fn init(alloc: mem.Allocator, opts: struct {
        seat_name: ?[:0]const u8 = null,
        force_backend: ?Backend = null,
    }) !Self {
        var display = try Display.connect(null);
        const globals = try GlobalList.init(&display, alloc);

        const compositor = globals.bind(wl.Compositor, wl.Compositor.generated_version).?;
        const seat = Seat.init(&display, &globals, .{ .name = opts.seat_name }) orelse return error.SeatNotFound;

        var device = try Device.init(&globals, seat.wl_seat, .{ .force_backend = opts.force_backend });
        const regular_data_source = try device.createDataSource();
        const primary_data_source = try device.createDataSource();

        var sender, _ = try channel.broadcast(void).init(alloc);

        return .{
            .display = display,
            .compositor = compositor,
            .seat = seat,
            .device = device,
            .globals = globals,
            .regular_data_source = regular_data_source,
            .primary_data_source = primary_data_source,
            .sender = sender,
            .contexts = try Contexts.init(alloc, display, sender.clone()),
        };
    }

    pub fn deinit(self: *Self, alloc: mem.Allocator) void {
        if (self.dispatch_thread) |thread| {
            thread.join();
        }
        self.sender.deinit(alloc);
        self.regular_data_source.deinit();
        self.primary_data_source.deinit();
        self.device.deinit();
        self.compositor.destroy();
        self.globals.deinit(alloc);
        self.seat.deinit();
        self.display.disconnect();
        self.contexts.deinit(alloc);
    }

    pub fn copy(
        self: *Self,
        alloc: mem.Allocator,
        source: Source,
        opts: struct {
            clipboard: enum {
                regular,
                primary,
                both,
            } = .regular,
            paste_once: bool = false,
            mime_type: ?[:0]const u8 = null,
        },
    ) !CopySignal {
        var output_buffer: [4096]u8 = undefined;

        var tmpfile = &self.contexts.copy.tmpfile;
        try tmpfile.f.seekTo(0);
        var output_writer = tmpfile.f.writer(&output_buffer);

        switch (source) {
            .file => |file| {
                var reader = file.readerStreaming(&.{});

                _ = try output_writer.interface.sendFileAll(&reader, .unlimited);
            },
            .bytes => |data| {
                _ = try output_writer.interface.writeAll(data);
            },
        }

        try output_writer.interface.flush();

        var magic = Magic.open(.mime_type);
        defer if (magic) |*m| {
            m.close();
        };
        const mime = blk: {
            if (opts.mime_type) |mime_opt| {
                break :blk mime_opt;
            } else if (magic) |*m| {
                if (m.file(tmpfile.abs_path)) |man| {
                    break :blk man;
                } else {
                    break :blk "text/plain;charset=utf-8";
                }
            } else {
                break :blk "text/plain;charset=utf-8";
            }
        };

        self.contexts.copy.paste_once = opts.paste_once;
        self.contexts.copy.mime_type = try alloc.dupeZ(u8, mime);

        switch (opts.clipboard) {
            .primary => {
                if (mimeTypeIsText(mime)) {
                    self.primary_data_source.offer("text/plain;charset=utf-8");
                    self.primary_data_source.offer("text/plain");
                    self.primary_data_source.offer("TEXT");
                    self.primary_data_source.offer("STRING");
                    self.primary_data_source.offer("UTF8_STRING");
                } else {
                    self.primary_data_source.offer(mime);
                }

                self.primary_data_source.setListener(*Contexts.CopyContext, dataControlSourceListener, self.contexts.copy);
                self.device.setPrimarySelection(&self.primary_data_source);
            },
            .regular => {
                if (mimeTypeIsText(mime)) {
                    self.regular_data_source.offer("text/plain;charset=utf-8");
                    self.regular_data_source.offer("text/plain");
                    self.regular_data_source.offer("TEXT");
                    self.regular_data_source.offer("STRING");
                    self.regular_data_source.offer("UTF8_STRING");
                } else {
                    self.regular_data_source.offer(mime);
                }

                self.regular_data_source.setListener(*Contexts.CopyContext, dataControlSourceListener, self.contexts.copy);
                self.device.setSelection(&self.regular_data_source);
            },
            .both => {
                if (mimeTypeIsText(mime)) {
                    self.regular_data_source.offer("text/plain;charset=utf-8");
                    self.regular_data_source.offer("text/plain");
                    self.regular_data_source.offer("TEXT");
                    self.regular_data_source.offer("STRING");
                    self.regular_data_source.offer("UTF8_STRING");

                    self.primary_data_source.offer("text/plain;charset=utf-8");
                    self.primary_data_source.offer("text/plain");
                    self.primary_data_source.offer("TEXT");
                    self.primary_data_source.offer("STRING");
                    self.primary_data_source.offer("UTF8_STRING");
                } else {
                    self.regular_data_source.offer(mime);
                    self.primary_data_source.offer(mime);
                }

                self.regular_data_source.setListener(*Contexts.CopyContext, dataControlSourceListener, self.contexts.copy);
                self.device.setSelection(&self.regular_data_source);

                self.primary_data_source.setListener(*Contexts.CopyContext, dataControlSourceListener, self.contexts.copy);
                self.device.setPrimarySelection(&self.primary_data_source);
            },
        }

        try self.display.roundtrip();

        return .{
            .receiver = try self.sender.receiver(alloc),
        };
    }

    pub fn paste(
        self: *Self,
        alloc: mem.Allocator,
        opts: struct {
            primary: bool = false,
            mime_type: ?[:0]const u8 = null,
        },
    ) !ClipboardContent {
        var paste_context = PasteContext{
            .alloc = alloc,
            .primary = opts.primary,
        };
        defer paste_context.deinit();
        errdefer {
            for (paste_context.mime_types.items) |mime_type| {
                alloc.free(mime_type);
            }
            paste_context.mime_types.deinit(alloc);
        }

        self.device.setListener(*PasteContext, deviceListener, &paste_context);

        try self.display.roundtrip();

        const offer = paste_context.offer orelse return error.NoClipboardContent;

        var mime_type = MimeType.init(paste_context.mime_types.items);
        const infered_mime_type = try mime_type.infer(opts.mime_type);

        const pipefd = try posix.pipe();
        offer.receive(infered_mime_type, pipefd[1]);

        try self.display.flush();

        posix.close(pipefd[1]);

        return .{
            .pipe = pipefd[0],
            .mime_types = paste_context.mime_types,
        };
    }

    pub fn watch(
        self: *Self,
        alloc: mem.Allocator,
        comptime T: type,
        callback: *const fn (Event, T) void,
        data: T,
    ) !void {
        self.contexts.watch.callback = @ptrCast(callback);
        self.contexts.watch.data = @ptrCast(data);
        self.contexts.watch.alloc = alloc;

        self.device.setListener(*Contexts.WatchContext, deviceListenerWatch, self.contexts.watch);

        try self.display.roundtrip();
    }

    pub fn dispatchLoop(self: *Self, alloc: mem.Allocator, variant: enum { blocking, threaded }) !void {
        if (variant == .threaded) {
            assert(self.dispatch_thread == null);

            const dispatch_receiver = try self.sender.receiver(alloc);
            self.dispatch_thread = try std.Thread.spawn(.{}, dispatchWayland, .{ &self.display, dispatch_receiver });
        } else {
            assert(self.dispatch_thread == null);
            while (true) {
                try self.display.dispatch();
            }
        }
    }
};

var repeats: u32 = 0;

fn dataControlSourceListener(data_source: *Device.DataSource, event: Device.DataSource.Event, state: *Contexts.CopyContext) void {
    _ = data_source;
    switch (event) {
        .send => |data| {
            _ = state.tmpfile.f.seekTo(0) catch return;

            var offset: i64 = 0;
            while (true) {
                const sent = os.linux.sendfile(data.fd, state.tmpfile.f.handle, &offset, 65536);

                if (sent == 0) break;
                offset += 0;
            }

            posix.close(data.fd);

            if (state.paste_once) {
                repeats += 1;
                if (repeats == 3) {
                    state.sender.send({});
                }
            }
        },
        .cancelled => {
            state.sender.send({});
        },
    }
}

fn deviceListener(device: *Device, event: Device.DeviceEvent, state: *PasteContext) void {
    _ = device;

    switch (event) {
        .data_offer => |offer| {
            offer.setListener(*PasteContext, dataControlOfferListener, state);
        },
        .primary_selection => |offer| {
            if (state.primary) {
                state.offer = offer;
            }
        },
        .selection => |offer| {
            if (!state.primary) {
                state.offer = offer;
            }
        },
        .finished => {},
    }
}

fn dataControlOfferListenerWatch(data_offer: *Device.DataOffer, event: Device.DataOffer.Event, state: *Contexts.WatchContext) void {
    _ = data_offer;

    switch (event) {
        .offer => |mime_type| {
            for (state.mime_types.items) |existing| {
                if (mem.eql(u8, existing, mime_type)) {
                    return;
                }
            }
            const mime_type_copy = state.alloc.dupeZ(u8, mime_type) catch return;
            state.mime_types.append(state.alloc, mime_type_copy) catch return;
        },
    }
}

fn deviceListenerWatch(device: *Device, event: Device.DeviceEvent, state: *Contexts.WatchContext) void {
    _ = device;

    switch (event) {
        .data_offer => |offer| {
            offer.setListener(*Contexts.WatchContext, dataControlOfferListenerWatch, state);
        },
        .primary_selection => |offer| {
            if (offer) |o| {
                var mime_type = MimeType.init(state.mime_types.items);
                const infered_mime_type = mime_type.infer(null) catch return;

                const pipefd = posix.pipe() catch return;
                o.receive(infered_mime_type, pipefd[1]);

                state.display.flush() catch return;

                posix.close(pipefd[1]);

                state.callback(.{ .primary_selection = pipefd[0] }, state.data);
            }
        },
        .selection => |offer| {
            if (offer) |o| {
                var mime_type = MimeType.init(state.mime_types.items);
                const infered_mime_type = mime_type.infer(null) catch return;

                const pipefd = posix.pipe() catch return;
                o.receive(infered_mime_type, pipefd[1]);

                state.display.flush() catch return;

                posix.close(pipefd[1]);

                state.callback(.{ .selection = pipefd[0] }, state.data);
            }
        },
        .finished => {},
    }
}

fn dataControlOfferListener(data_offer: *Device.DataOffer, event: Device.DataOffer.Event, state: *PasteContext) void {
    _ = data_offer;

    switch (event) {
        .offer => |mime_type| {
            for (state.mime_types.items) |existing| {
                if (mem.eql(u8, existing, mime_type)) {
                    return;
                }
            }
            const mime_type_copy = state.alloc.dupeZ(u8, mime_type) catch return;
            state.mime_types.append(state.alloc, mime_type_copy) catch return;
        },
    }
}

fn dispatchWayland(display: *Display, receiver: channel.broadcast(void).Receiver) void {
    var recv = receiver;
    while (recv.tryReceive() == null) {
        display.dispatch() catch continue;
    }
}

test "copy" {
    const alloc = std.testing.allocator;

    var wl_clipboard = try WlClipboard.init(alloc, .{});
    defer wl_clipboard.deinit(alloc);

    var signal = try wl_clipboard.copy(alloc, .{ .bytes = "test" }, .{});
    defer signal.deinit(alloc);
    try signal.startDispatch();

    var res = try wl_clipboard.paste(alloc, .{});
    res.deinit(alloc);

    signal.copy_context.sender.send({});
}
