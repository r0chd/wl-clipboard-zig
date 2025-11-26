const wl = @import("wayland").client.wl;
const ext = @import("wayland").client.ext;
const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const mime = @import("mime");

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
    alloc: ?mem.Allocator = null,
};

pub const WlClipboard = struct {
    display: *wl.Display,
    registry: *wl.Registry,
    wayland_context: WaylandContext,
    data_source: ?*ext.DataControlSourceV1 = null,
    device: *ext.DataControlDeviceV1,
    paste_context: PasteContext,
    mime_type: ?mime.Type = null,

    const Self = @This();

    pub fn init() !Self {
        const display = try wl.Display.connect(null);
        const registry = try display.getRegistry();

        var wayland_context = WaylandContext{};
        registry.setListener(*WaylandContext, registryListener, &wayland_context);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        const data_control_manager = wayland_context.data_control_manager.?;
        const device = try data_control_manager.getDataDevice(wayland_context.seat.?);

        return .{
            .paste_context = .{},
            .wayland_context = wayland_context,
            .registry = registry,
            .display = display,
            .device = device,
        };
    }

    pub fn paste(self: *Self, alloc: mem.Allocator) !ClipboardContent {
        var arena = std.heap.ArenaAllocator.init(alloc);
        const arena_alloc = arena.allocator();

        self.paste_context.alloc = arena_alloc;
        self.device.setListener(*PasteContext, deviceListener, &self.paste_context);

        if (self.display.dispatch() != .SUCCESS) return error.DispatchFailed;

        const offer = self.paste_context.offer orelse return error.NoClipboardContent;

        const pipefd = try std.posix.pipe();
        offer.receive("text/plain;charset=utf-8", pipefd[1]);
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
            .mime_types = try self.paste_context.mime_types.toOwnedSlice(arena_alloc),
            .arena = arena,
        };
    }

    pub fn mimeType(self: *Self, mime_type: mime.Type) void {
        self.mime_type = mime_type;
    }

    pub fn deinit(self: *Self) void {
        self.registry.destroy();
        self.display.disconnect();
    }
};

fn deviceListener(data_control_device: *ext.DataControlDeviceV1, event: ext.DataControlDeviceV1.Event, state: *PasteContext) void {
    _ = data_control_device;

    switch (event) {
        .data_offer => |offer| {
            state.offer = offer.id;
            offer.id.setListener(*PasteContext, dataControlOfferListener, state);
        },
        .primary_selection => |offer| {
            state.offer = offer.id;
        },
        .selection => |offer| {
            state.offer = offer.id;
        },
        .finished => {},
    }
}

fn dataControlOfferListener(data_control_offer: *ext.DataControlOfferV1, event: ext.DataControlOfferV1.Event, state: *PasteContext) void {
    _ = data_control_offer;

    std.debug.assert(state.alloc != null);

    switch (event) {
        .offer => |offer| {
            const mime_type = mem.span(offer.mime_type);
            state.mime_types.append(state.alloc.?, mime_type) catch @panic("OOM");
        },
    }
}

pub const WaylandContext = struct {
    compositor: ?*wl.Compositor = null,
    seat: ?*wl.Seat = null,
    data_control_manager: ?*ext.DataControlManagerV1 = null,

    const Self = @This();
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
                    state.seat = wl_seat;
                },
            }
        },
        .global_remove => |_| {},
    }
}
