const tmpfile = @import("tmpfile.zig");
const wl = @import("wayland").client.wl;
const ext = @import("wayland").client.ext;
const std = @import("std");
const mem = std.mem;

pub const WlClipboard = struct {
    wayland_context: WaylandContext,

    const Self = @This();

    pub fn init() !Self {
        const display = try wl.Display.connect(null);
        defer display.disconnect();

        const registry = try display.getRegistry();
        defer registry.destroy();

        var wayland_context = WaylandContext{};
        registry.setListener(*WaylandContext, registryListener, &wayland_context);
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        const data_control_manager = wayland_context.data_control_manager.?;

        const data_source = try data_control_manager.createDataSource();
        //data_source.offer(_mime_type: [*:0]const u8)

        const device = try data_control_manager.getDataDevice(wayland_context.seat.?);
        device.setPrimarySelection(data_source);

        var file = try tmpfile.tmpFile(.{});
        defer file.deinit();

        try file.f.writeAll("hello world");

        std.debug.print("{s}\n", .{file.abs_path});

        return .{ .wayland_context = wayland_context };
    }
};

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
