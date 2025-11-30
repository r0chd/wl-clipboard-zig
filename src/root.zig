const std = @import("std");
const wl = @import("wayland").client.wl;
const ext = @import("wayland").client.ext;
const mime = @import("mime");
const mem = std.mem;
const heap = std.heap;
const ascii = std.ascii;
const meta = std.meta;
const MimeType = @import("MimeType.zig");

pub const ClipboardContent = struct {
    content: []u8,
    mime_types: [][:0]const u8,
    arena: heap.ArenaAllocator,

    const Self = @This();

    pub fn deinit(self: *const Self) void {
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

pub const WlClipboard = struct {
    display: *wl.Display,
    registry: *wl.Registry,
    wayland_context: WaylandContext,
    data_source: ?*ext.DataControlSourceV1 = null,
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
        const device = try data_control_manager.getDataDevice(wayland_context.seat.?);

        return .{
            .wayland_context = wayland_context,
            .registry = registry,
            .display = display,
            .device = device,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.data_source) |source| {
            source.destroy();
        }
        self.device.destroy();
        self.wayland_context.deinit();
        self.registry.destroy();
        self.display.disconnect();
    }

    pub fn copy(self: *Self) void {
        _ = self;
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

        const pipefd = try std.posix.pipe();
        offer.receive(infered_mime_type, pipefd[1]);
        std.posix.close(pipefd[1]);

        if (self.display.flush() != .SUCCESS) return error.FlushFailed;

        var buffer: std.ArrayList(u8) = .empty;

        var read_buf: [4096]u8 = undefined;
        while (true) {
            const bytes_read = std.posix.read(pipefd[0], &read_buf) catch |err| switch (err) {
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
