const wl = @import("wayland").client.wl;
const ext = @import("wayland").client.ext;
const std = @import("std");
const mime = @import("mime");
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
const Channel = @import("Channel.zig").Channel;

pub const ClipboardContent = struct {
    content: []u8,
    mime_types: [][:0]const u8,
    arena: heap.ArenaAllocator,

    const Self = @This();

    pub fn deinit(self: *const Self) void {
        self.arena.deinit();
    }
};

const CopyContext = struct {
    channel: *Channel(void),
    stop: *atomic.Value(bool),
    file: fs.File,
};

const CopySignal = struct {
    channel: *Channel(void),
    thread: std.Thread,
    arena: heap.ArenaAllocator,

    const Self = @This();

    pub fn cancelAwait(self: *Self) void {
        self.channel.receive();
        self.thread.join();
    }

    pub fn cancelled(self: *Self) bool {
        return self.channel.tryReceive() orelse false;
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
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
        }
    }
};

pub const Source = union(enum) {
    stdin: void,
    bytes: []u8,
};

pub const WlClipboard = struct {
    display: *wl.Display,
    registry: *wl.Registry,
    wayland_context: WaylandContext,
    data_source: *ext.DataControlSourceV1,
    device: *ext.DataControlDeviceV1,
    seat: ?*[:0]const u8 = null,

    const Self = @This();

    pub fn init(options: struct { seat_name: ?[:0]const u8 = null }) !Self {
        const display = try wl.Display.connect(null);
        const registry = try display.getRegistry();

        var wayland_context = WaylandContext{
            .seat_name = options.seat_name,
        };
        registry.setListener(*WaylandContext, registryListener, &wayland_context);
        // Ensure registry state is synced
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        // Ensure seat state is synced
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        const data_control_manager = wayland_context.data_control_manager.?;
        const data_source = try data_control_manager.createDataSource();
        const device = try data_control_manager.getDataDevice(wayland_context.seat.?);

        return .{
            .wayland_context = wayland_context,
            .data_source = data_source,
            .registry = registry,
            .display = display,
            .device = device,
        };
    }

    pub fn deinit(self: *Self) void {
        self.data_source.destroy();
        self.device.destroy();
        self.wayland_context.deinit();
        self.registry.destroy();
        self.display.disconnect();
    }

    pub fn copy(
        self: *Self,
        alloc: mem.Allocator,
        source: Source,
    ) !CopySignal {
        const tmpfile = try tmp.tmpFile(.{});

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

        var arena = std.heap.ArenaAllocator.init(alloc);
        const arena_alloc = arena.allocator();

        const channel = try arena_alloc.create(Channel(void));
        channel.* = Channel(void).init();

        const stop = try arena_alloc.create(std.atomic.Value(bool));
        stop.* = std.atomic.Value(bool).init(false);

        const copy_context = try arena_alloc.create(CopyContext);
        copy_context.* = CopyContext{
            .channel = channel,
            .stop = stop,
            .file = tmpfile.f,
        };

        self.data_source.offer("text/plain;charset=utf-8");
        self.data_source.offer("text/plain");
        self.data_source.offer("TEXT");
        self.data_source.offer("STRING");
        self.data_source.offer("UTF8_STRING");

        self.data_source.setListener(*CopyContext, dataControlSourceListener, copy_context);
        self.device.setSelection(self.data_source);

        if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        const thread = try std.Thread.spawn(.{}, dispatchWayland, .{ self.display, stop });

        return .{
            .arena = arena,
            .channel = channel,
            .thread = thread,
        };
    }

    pub fn paste(
        self: *Self,
        alloc: mem.Allocator,
        options: struct {
            primary: bool = false,
            mime_type: ?[:0]const u8 = null,
        },
    ) !ClipboardContent {
        var arena = std.heap.ArenaAllocator.init(alloc);
        const arena_alloc = arena.allocator();

        var paste_context = PasteContext{
            .alloc = arena_alloc,
            .primary = options.primary,
        };
        defer paste_context.deinit();

        self.device.setListener(*PasteContext, deviceListener, &paste_context);

        if (self.display.dispatch() != .SUCCESS) return error.DispatchFailed;

        const offer = paste_context.offer orelse return error.NoClipboardContent;

        var mime_type = MimeType.init(paste_context.mime_types.items);
        const infered_mime_type = mime_type.infer(options.mime_type);

        const pipefd = try posix.pipe();
        offer.receive(infered_mime_type, pipefd[1]);
        posix.close(pipefd[1]);

        if (self.display.flush() != .SUCCESS) return error.FlushFailed;

        var buffer: std.ArrayList(u8) = .empty;

        var read_buf: [4096]u8 = undefined;
        while (true) {
            const bytes_read = posix.read(pipefd[0], &read_buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };

            if (bytes_read == 0) break;
            try buffer.appendSlice(arena_alloc, read_buf[0..bytes_read]);
        }

        return .{
            .content = try buffer.toOwnedSlice(arena_alloc),
            .mime_types = try paste_context.mime_types.toOwnedSlice(arena_alloc),
            .arena = arena,
        };
    }
};

fn dataControlSourceListener(data_control_source: *ext.DataControlSourceV1, event: ext.DataControlSourceV1.Event, state: *CopyContext) void {
    _ = data_control_source;
    switch (event) {
        .send => |data| {
            var buf: [4096]u8 = undefined;
            _ = state.file.seekTo(0) catch return;
            const bytes_read = posix.read(state.file.handle, &buf) catch |err| {
                std.log.err("Failed to read from temp file: {}", .{err});
                return;
            };
            _ = posix.write(data.fd, buf[0..bytes_read]) catch |err| {
                std.log.err("Failed to write to pipe: {}", .{err});
                return;
            };

            posix.close(data.fd);
        },
        .cancelled => {
            state.channel.send({});
            state.stop.store(true, .unordered);
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

pub const WaylandContext = struct {
    seat_name: ?[:0]const u8,
    compositor: ?*wl.Compositor = null,
    seat: ?*wl.Seat = null,
    data_control_manager: ?*ext.DataControlManagerV1 = null,

    const Self = @This();

    fn deinit(self: *Self) void {
        if (self.compositor) |compositor| {
            compositor.destroy();
        }
        if (self.seat) |seat| {
            seat.destroy();
        }
        if (self.data_control_manager) |data_control_manager| {
            data_control_manager.destroy();
        }
    }
};

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, state: *WaylandContext) void {
    const EventInterfaces = enum {
        wl_compositor,
        wl_seat,
        ext_data_control_manager_v1,
    };

    switch (event) {
        .global => |global| {
            const event_str = std.meta.stringToEnum(EventInterfaces, mem.span(global.interface)) orelse return;
            switch (event_str) {
                .wl_compositor => {
                    state.compositor = registry.bind(
                        global.name,
                        wl.Compositor,
                        wl.Compositor.generated_version,
                    ) catch @panic("Failed to bind wl_compositor");
                },
                .ext_data_control_manager_v1 => {
                    state.data_control_manager = registry.bind(global.name, ext.DataControlManagerV1, ext.DataControlManagerV1.generated_version) catch @panic("Failed to bind");
                },
                .wl_seat => {
                    const wl_seat = registry.bind(
                        global.name,
                        wl.Seat,
                        wl.Seat.generated_version,
                    ) catch @panic("Failed to bind seat global");
                    wl_seat.setListener(*WaylandContext, seatListener, state);
                },
            }
        },
        .global_remove => |_| {},
    }
}

fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, state: *WaylandContext) void {
    switch (event) {
        .capabilities => {},
        .name => |name| {
            if (state.seat_name) |seat_name| {
                if (mem.eql(u8, seat_name, mem.span(name.name)))
                    state.seat = seat;
            } else {
                state.seat = seat;
            }
        },
    }
}

fn dispatchWayland(display: *wl.Display, stop: *atomic.Value(bool)) void {
    while (!stop.load(.unordered)) {
        if (display.dispatch() != .SUCCESS) return;
    }
}
