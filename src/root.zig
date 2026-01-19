const wl = @import("wayland").client.wl;
const zmime = @import("zmime");
const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const fs = std.fs;
const mimeTypeIsText = @import("MimeType.zig").mimeTypeIsText;
const MimeType = @import("MimeType.zig");
const GlobalList = @import("wayland/GlobalList.zig");
const Seat = @import("wayland/Seat.zig");
const Device = @import("Device.zig");
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

    pub fn deinit(self: *Self, gpa: mem.Allocator) void {
        for (self.mime_types.items) |mime_type| {
            gpa.free(mime_type);
        }
        self.mime_types.deinit(gpa);
    }
};

const PasteContext = struct {
    offer: ?*Device.DataOffer = null,
    mime_types: std.ArrayList([:0]const u8) = .empty,
    gpa: mem.Allocator,
    primary: bool,

    const Self = @This();

    fn deinit(self: *Self) void {
        if (self.offer) |offer| {
            offer.deinit();
            self.offer = null;
        }
        self.mime_types.clearRetainingCapacity();
        self.primary = false;
        self.gpa = undefined;
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
    contexts: Contexts,
    stop: bool = false,

    const Self = @This();

    pub fn init(gpa: mem.Allocator, opts: struct {
        seat_name: ?[:0]const u8 = null,
        force_backend: ?Backend = null,
    }) !Self {
        var display = try Display.connect(null);
        const globals = try GlobalList.init(&display, gpa);

        const compositor = globals.bind(wl.Compositor, wl.Compositor.generated_version).?;
        const seat = Seat.init(&display, &globals, .{ .name = opts.seat_name }) orelse return error.SeatNotFound;

        var device = try Device.init(&globals, seat.wl_seat, .{ .force_backend = opts.force_backend });
        const regular_data_source = try device.createDataSource();
        const primary_data_source = try device.createDataSource();

        return .{
            .display = display,
            .compositor = compositor,
            .seat = seat,
            .device = device,
            .globals = globals,
            .regular_data_source = regular_data_source,
            .primary_data_source = primary_data_source,
            .contexts = try Contexts.init(gpa, display),
        };
    }

    pub fn deinit(self: *Self, gpa: mem.Allocator) void {
        self.regular_data_source.deinit();
        self.primary_data_source.deinit();
        self.device.deinit();
        self.compositor.destroy();
        self.seat.deinit();
        self.globals.deinit(gpa);
        self.display.disconnect();
        self.contexts.deinit(gpa);
    }

    pub fn copy(
        self: *Self,
        gpa: mem.Allocator,
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
    ) !void {
        var output_buffer: [4096]u8 = undefined;

        var tmpfile = &self.contexts.copy.tmpfile;
        var output_writer = tmpfile.f.writer(&output_buffer);
        var output_iowriter = &output_writer.interface;

        switch (source) {
            .file => |file| {
                var buffer: [4098]u8 = undefined;
                var reader = file.readerStreaming(&buffer);

                _ = try output_iowriter.sendFileAll(&reader, .unlimited);
            },
            .bytes => |data| {
                _ = try output_iowriter.writeAll(data);
            },
        }

        try output_iowriter.flush();

        const mime = blk: {
            if (opts.mime_type) |mime_opt| {
                break :blk mime_opt;
            } else if (zmime.detectFileInfo(tmpfile.abs_path)) |file_info| {
                break :blk zmime.mimeToString(file_info.mime);
            } else |_| {
                break :blk "text/plain;charset=utf-8";
            }
        };

        self.contexts.copy.paste_once = opts.paste_once;
        self.contexts.copy.mime_type = try gpa.dupeZ(u8, mime);

        switch (opts.clipboard) {
            .primary => {
                if (mimeTypeIsText(mime)) {
                    self.primary_data_source.set_mime_types(&[_][]const u8{ "text/plain;charset=utf-8", "text/plain", "TEXT", "STRING", "UTF8_STRING" });
                } else {
                    self.primary_data_source.set_mime_types(&[_][]const u8{mime});
                }

                self.primary_data_source.setListener(*Contexts.CopyContext, dataControlSourceListener, &self.contexts.copy);
                self.device.setPrimarySelection(&self.primary_data_source);
            },
            .regular => {
                if (mimeTypeIsText(mime)) {
                    self.regular_data_source.set_mime_types(&[_][]const u8{ "text/plain;charset=utf-8", "text/plain", "TEXT", "STRING", "UTF8_STRING" });
                } else {
                    self.regular_data_source.set_mime_types(&[_][]const u8{mime});
                }

                self.regular_data_source.setListener(*Contexts.CopyContext, dataControlSourceListener, &self.contexts.copy);
                self.device.setSelection(&self.regular_data_source);
            },
            .both => {
                if (mimeTypeIsText(mime)) {
                    self.regular_data_source.set_mime_types(&[_][]const u8{ "text/plain;charset=utf-8", "text/plain", "TEXT", "STRING", "UTF8_STRING" });
                    self.primary_data_source.set_mime_types(&[_][]const u8{ "text/plain;charset=utf-8", "text/plain", "TEXT", "STRING", "UTF8_STRING" });
                } else {
                    self.regular_data_source.set_mime_types(&[_][]const u8{mime});
                    self.primary_data_source.set_mime_types(&[_][]const u8{mime});
                }

                self.regular_data_source.setListener(*Contexts.CopyContext, dataControlSourceListener, &self.contexts.copy);
                self.device.setSelection(&self.regular_data_source);

                self.primary_data_source.setListener(*Contexts.CopyContext, dataControlSourceListener, &self.contexts.copy);
                self.device.setPrimarySelection(&self.primary_data_source);
            },
        }

        try self.display.roundtrip();

        while (!self.contexts.copy.stop) {
            try self.display.dispatch();
        }
    }

    pub fn paste(
        self: *Self,
        gpa: mem.Allocator,
        opts: struct {
            primary: bool = false,
            mime_type: ?[:0]const u8 = null,
        },
    ) !ClipboardContent {
        var paste_context = PasteContext{
            .gpa = gpa,
            .primary = opts.primary,
        };
        defer paste_context.deinit();
        errdefer {
            for (paste_context.mime_types.items) |mime_type| {
                gpa.free(mime_type);
            }
            paste_context.mime_types.deinit(gpa);
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
        gpa: mem.Allocator,
        comptime T: type,
        callback: *const fn (Event, T) void,
        data: T,
    ) !void {
        self.contexts.watch.callback = @ptrCast(callback);
        self.contexts.watch.data = @ptrCast(data);
        self.contexts.watch.gpa = gpa;

        self.device.setListener(*Contexts.WatchContext, deviceListenerWatch, &self.contexts.watch);

        while (true) {
            try self.display.dispatch();
        }
    }
};

var initialized: bool = false;

fn dataControlSourceListener(data_source: *Device.DataSource, event: Device.DataSource.Event, state: *Contexts.CopyContext) void {
    _ = data_source;
    switch (event) {
        .send => |data| {
            _ = state.tmpfile.f.seekTo(0) catch return;

            var read_buffer: [4098]u8 = undefined;
            var reader = state.tmpfile.f.reader(&read_buffer);

            var buffer: [4098]u8 = undefined;
            var file = fs.File{ .handle = data.fd };
            defer file.close();
            var writer = file.writerStreaming(&buffer);
            var io_writer = &writer.interface;
            _ = io_writer.sendFileAll(&reader, .unlimited) catch |err| std.debug.panic("{s}\n", .{@errorName(err)});

            if (state.paste_once) {
                if (initialized) {
                    state.stop = true;
                } else {
                    initialized = true;
                }
            }
        },
        .cancelled => {
            state.stop = true;
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
            const mime_type_copy = state.gpa.dupeZ(u8, mime_type) catch return;
            state.mime_types.append(state.gpa, mime_type_copy) catch return;
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
            const mime_type_copy = state.gpa.dupeZ(u8, mime_type) catch return;
            state.mime_types.append(state.gpa, mime_type_copy) catch return;
        },
    }
}
