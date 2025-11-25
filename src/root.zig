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

        return .{ .wayland_context = wayland_context };
    }
};

pub const WaylandContext = struct {
    compositor: ?*wl.Compositor = null,
    seat: ?*wl.Seat = null,
    data_control_manager: ?*ext.DataControlManagerV1 = null,

    const Self = @This();
};

const EventInterfaces = enum {
    wl_compositor,
    wl_seat,
    ext_data_control_manager_v1,
};

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, state: *WaylandContext) void {
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

                    const data_control_device = state.data_control_manager.?.getDataDevice(state.seat.?) catch @panic("");
                    _ = data_control_device;
                },
            }
        },
        .global_remove => |_| {},
    }
}
