const wl = @import("wayland").client.wl;
const ext = @import("wayland").client.ext;
const libmagic = @import("magic");
const c = @cImport(@cInclude("magic.h"));
const std = @import("std");
const tmp = @import("tmpfile.zig");
const mem = std.mem;
const heap = std.heap;
const ascii = std.ascii;
const meta = std.meta;
const atomic = std.atomic;
const posix = std.posix;
const os = std.os;
const fs = std.fs;
const MimeType = @import("MimeType.zig");
const channel = @import("channel.zig");
const GlobalList = @import("GlobalList.zig");
const Seat = @import("Seat.zig");
const Device = @import("Device.zig");
const Magic = @import("Magic.zig");
const mimeTypeIsText = @import("MimeType.zig").mimeTypeIsText;

pub const ClipboardContent = struct {
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
        self.mime_types = undefined;
    }
};

const CopyContext = struct {
    sender: channel.broadcast(void).Sender,
    tmpfile: tmp.TmpFile,
    display: *wl.Display,
    paste_once: bool,
};

const CopySignal = struct {
    receiver: channel.broadcast(void).Receiver,
    dispatch_receiver: channel.broadcast(void).Receiver,
    thread: ?std.Thread,
    copy_context: *CopyContext,

    const Self = @This();

    pub fn startDispatch(self: *Self) !void {
        if (self.copy_context.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        self.thread = try std.Thread.spawn(.{}, dispatchWayland, .{ self.copy_context.display, &self.dispatch_receiver });
    }

    pub fn cancelAwait(self: *Self) void {
        self.receiver.receive();
    }

    pub fn cancelled(self: *Self) bool {
        return self.receiver.tryReceive() != null;
    }

    pub fn deinit(self: *Self, alloc: mem.Allocator) void {
        if (self.thread) |thread| {
            thread.join();
        }
        self.copy_context.sender.deinit(alloc);
        self.copy_context.tmpfile.deinit(alloc);
        alloc.destroy(self.copy_context);
    }
};

const PasteContext = struct {
    offer: ?*ext.DataControlOfferV1 = null,
    mime_types: std.ArrayList([:0]const u8) = .empty,
    alloc: mem.Allocator,
    primary: bool,

    const Self = @This();

    fn deinit(self: *Self) void {
        if (self.offer) |offer| {
            offer.destroy();
            self.offer = null;
        }
        self.mime_types.clearRetainingCapacity();
        self.primary = false;
        self.alloc = undefined;
    }
};

pub const Source = union(enum) {
    stdin: void,
    bytes: []const u8,
};

pub const WlClipboard = struct {
    globals: GlobalList,
    display: *wl.Display,
    compositor: *wl.Compositor,
    seat: Seat,
    data_control_manager: *ext.DataControlManagerV1,
    regular_data_source: *ext.DataControlSourceV1,
    primary_data_source: *ext.DataControlSourceV1,
    device: *ext.DataControlDeviceV1,

    const Self = @This();

    pub fn init(alloc: mem.Allocator, opts: struct { seat_name: ?[:0]const u8 = null }) !Self {
        const display = try wl.Display.connect(null);
        const globals = try GlobalList.init(display, alloc);

        const compositor = globals.bind(wl.Compositor, wl.Compositor.generated_version).?;
        const seat = Seat.init(display, &globals, .{ .name = opts.seat_name }) orelse return error.SeatNotFound;

        const data_control_manager = globals.bind(ext.DataControlManagerV1, ext.DataControlManagerV1.generated_version).?;
        const regular_data_source = try data_control_manager.createDataSource();
        const primary_data_source = try data_control_manager.createDataSource();
        const device = try data_control_manager.getDataDevice(seat.wl_seat);

        return .{
            .display = display,
            .compositor = compositor,
            .seat = seat,
            .data_control_manager = data_control_manager,
            .globals = globals,
            .regular_data_source = regular_data_source,
            .primary_data_source = primary_data_source,
            .device = device,
        };
    }

    pub fn deinit(self: *Self, alloc: mem.Allocator) void {
        self.regular_data_source.destroy();
        self.primary_data_source.destroy();
        self.device.destroy();
        self.compositor.destroy();
        self.data_control_manager.destroy();
        self.globals.deinit(alloc);
        self.seat.deinit();
        self.display.disconnect();
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
        var tmpfile = try tmp.TmpFile.init(alloc, .{
            .prefix = null,
            .dir_prefix = null,
            .flags = .{ .read = true, .mode = 0o400, .exclusive = true, .lock = .exclusive },
            .dir_opts = .{},
        });

        var output_buffer: [4096]u8 = undefined;
        var output_writer = tmpfile.f.writer(&output_buffer);

        switch (source) {
            .stdin => {
                var stdin = std.fs.File.stdin();
                var reader = stdin.readerStreaming(&.{});

                _ = try output_writer.interface.sendFileAll(&reader, .unlimited);
            },
            .bytes => |data| {
                _ = try output_writer.interface.writeAll(data);
            },
        }

        try output_writer.interface.flush();

        var sender, const receiver = try channel.broadcast(void).init(alloc);
        const dispatch_receiver = try sender.receiver(alloc);

        const copy_context = try alloc.create(CopyContext);
        copy_context.* = CopyContext{
            .sender = sender,
            .tmpfile = tmpfile,
            .display = self.display,
            .paste_once = opts.paste_once,
        };

        var magic = Magic.open(.mime_type);
        defer magic.close();
        const mime = blk: {
            if (opts.mime_type) |mime| {
                break :blk mime;
            } else {
                magic.load(null);
                break :blk magic.file(tmpfile.abs_path);
            }
        };

        switch (opts.clipboard) {
            .primary => {
                self.primary_data_source.offer(mime);
                if (mimeTypeIsText(mime)) {
                    self.primary_data_source.offer("text/plain;charset=utf-8");
                    self.primary_data_source.offer("text/plain");
                    self.primary_data_source.offer("TEXT");
                    self.primary_data_source.offer("STRING");
                    self.primary_data_source.offer("UTF8_STRING");
                }

                self.primary_data_source.setListener(*CopyContext, dataControlSourceListener, copy_context);
                self.device.setPrimarySelection(self.primary_data_source);
            },
            .regular => {
                self.regular_data_source.offer(mime);
                if (mimeTypeIsText(mime)) {
                    self.regular_data_source.offer("text/plain;charset=utf-8");
                    self.regular_data_source.offer("text/plain");
                    self.regular_data_source.offer("TEXT");
                    self.regular_data_source.offer("STRING");
                    self.regular_data_source.offer("UTF8_STRING");
                }

                self.regular_data_source.setListener(*CopyContext, dataControlSourceListener, copy_context);
                self.device.setSelection(self.regular_data_source);
            },
            .both => {
                self.regular_data_source.offer(mime);
                if (mimeTypeIsText(mime)) {
                    self.regular_data_source.offer("text/plain;charset=utf-8");
                    self.regular_data_source.offer("text/plain");
                    self.regular_data_source.offer("TEXT");
                    self.regular_data_source.offer("STRING");
                    self.regular_data_source.offer("UTF8_STRING");
                }

                self.regular_data_source.setListener(*CopyContext, dataControlSourceListener, copy_context);
                self.device.setSelection(self.regular_data_source);

                self.primary_data_source.offer(mime);
                if (mimeTypeIsText(mime)) {
                    self.primary_data_source.offer("text/plain;charset=utf-8");
                    self.primary_data_source.offer("text/plain");
                    self.primary_data_source.offer("TEXT");
                    self.primary_data_source.offer("STRING");
                    self.primary_data_source.offer("UTF8_STRING");
                }

                self.primary_data_source.setListener(*CopyContext, dataControlSourceListener, copy_context);
                self.device.setPrimarySelection(self.primary_data_source);
            },
        }

        if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        return .{
            .receiver = receiver,
            .dispatch_receiver = dispatch_receiver,
            .thread = null,
            .copy_context = copy_context,
        };
    }

    pub fn copyToContext(
        self: *Self,
        copy_context: *CopyContext,
        opts: struct {
            clipboard: enum {
                regular,
                primary,
                both,
            } = .regular,
            paste_once: bool = false,
        },
    ) !void {
        copy_context.display = self.display;

        var magic = Magic.open(.mime_type);
        defer magic.close();
        magic.load(null);
        const mime = magic.file(copy_context.tmpfile.abs_path);

        switch (opts.clipboard) {
            .primary => {
                if (mimeTypeIsText(mime)) {
                    self.primary_data_source.offer("text/plain;charset=utf-8");
                    self.primary_data_source.offer("text/plain");
                    self.primary_data_source.offer("TEXT");
                    self.primary_data_source.offer("STRING");
                    self.primary_data_source.offer("UTF8_STRING");
                }

                self.primary_data_source.setListener(*CopyContext, dataControlSourceListener, copy_context);

                self.device.setPrimarySelection(self.primary_data_source);
            },
            .regular => {
                self.regular_data_source.offer(mime);
                if (mimeTypeIsText(mime)) {
                    self.regular_data_source.offer("text/plain;charset=utf-8");
                    self.regular_data_source.offer("text/plain");
                    self.regular_data_source.offer("TEXT");
                    self.regular_data_source.offer("STRING");
                    self.regular_data_source.offer("UTF8_STRING");
                }

                self.regular_data_source.setListener(*CopyContext, dataControlSourceListener, copy_context);

                self.device.setSelection(self.regular_data_source);
            },
            .both => {
                self.regular_data_source.offer(mime);
                if (mimeTypeIsText(mime)) {
                    self.regular_data_source.offer("text/plain;charset=utf-8");
                    self.regular_data_source.offer("text/plain");
                    self.regular_data_source.offer("TEXT");
                    self.regular_data_source.offer("STRING");
                    self.regular_data_source.offer("UTF8_STRING");
                }

                self.regular_data_source.setListener(*CopyContext, dataControlSourceListener, copy_context);

                self.device.setSelection(self.regular_data_source);

                self.regular_data_source.offer(mime);
                if (mimeTypeIsText(mime)) {
                    self.primary_data_source.offer("text/plain;charset=utf-8");
                    self.primary_data_source.offer("text/plain");
                    self.primary_data_source.offer("TEXT");
                    self.primary_data_source.offer("STRING");
                    self.primary_data_source.offer("UTF8_STRING");
                }

                self.primary_data_source.setListener(*CopyContext, dataControlSourceListener, copy_context);

                self.device.setPrimarySelection(self.primary_data_source);
            },
        }

        if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
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

        self.device.setListener(*PasteContext, deviceListener, &paste_context);

        if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        const offer = paste_context.offer orelse return error.NoClipboardContent;

        var mime_type = MimeType.init(paste_context.mime_types.items);
        const infered_mime_type = try mime_type.infer(opts.mime_type);

        const pipefd = try posix.pipe();
        offer.receive(infered_mime_type, pipefd[1]);

        if (self.display.flush() != .SUCCESS) return error.FlushFailed;

        posix.close(pipefd[1]);

        return .{
            .pipe = pipefd[0],
            .mime_types = paste_context.mime_types,
        };
    }
};

var repeats: u32 = 0;

fn dataControlSourceListener(data_control_source: *ext.DataControlSourceV1, event: ext.DataControlSourceV1.Event, state: *CopyContext) void {
    _ = data_control_source;
    switch (event) {
        .send => |data| {
            var buf: [4096]u8 = undefined;
            _ = state.tmpfile.f.seekTo(0) catch return;

            while (true) {
                const bytes_read = posix.read(state.tmpfile.f.handle, &buf) catch |err| {
                    std.log.err("Failed to read from temp file: {}", .{err});
                    break;
                };

                if (bytes_read == 0) break;

                _ = posix.write(data.fd, buf[0..bytes_read]) catch |err| {
                    std.log.err("Failed to write to pipe: {}", .{err});
                    break;
                };
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

fn deviceListener(data_control_device: *ext.DataControlDeviceV1, event: ext.DataControlDeviceV1.Event, state: *PasteContext) void {
    _ = data_control_device;

    switch (event) {
        .data_offer => |offer| {
            offer.id.setListener(*PasteContext, dataControlOfferListener, state);
        },
        .primary_selection => |offer| {
            if (state.primary) {
                state.offer = offer.id;
            }
        },
        .selection => |offer| {
            if (!state.primary) {
                state.offer = offer.id;
            }
        },
        .finished => {},
    }
}

fn dataControlOfferListener(data_control_offer: *ext.DataControlOfferV1, event: ext.DataControlOfferV1.Event, state: *PasteContext) void {
    _ = data_control_offer;

    switch (event) {
        .offer => |offer| {
            const mime_type_slice = mem.span(offer.mime_type);
            const mime_type_copy = state.alloc.dupeZ(u8, mime_type_slice) catch return;
            state.mime_types.append(state.alloc, mime_type_copy) catch return;
        },
    }
}

fn dispatchWayland(display: *wl.Display, receiver: *channel.broadcast(void).Receiver) void {
    while (receiver.tryReceive() == null) {
        if (display.dispatch() != .SUCCESS) return;
    }
}
