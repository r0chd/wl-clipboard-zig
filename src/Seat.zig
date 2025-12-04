const std = @import("std");
const mem = std.mem;
const wl = @import("wayland").client.wl;
const GlobalList = @import("GlobalList.zig");

wl_seat: *wl.Seat,

const Self = @This();

pub fn init(display: *wl.Display, globals: *const GlobalList, options: struct { name: ?[:0]const u8 }) ?Self {
    const seat_global = globals.bind(wl.Seat, wl.Seat.generated_version).?;

    if (options.name == null) {
        return .{
            .wl_seat = seat_global,
        };
    }

    var cb_state = CbState{ .name = options.name };
    seat_global.setListener(*CbState, seatListener, &cb_state);

    if (display.roundtrip() != .SUCCESS) return null;

    if (cb_state.wl_seat) |wl_seat| {
        return .{
            .wl_seat = wl_seat,
        };
    } else {
        return null;
    }
}

pub fn deinit(self: *Self) void {
    self.wl_seat.destroy();
}

const CbState = struct {
    name: ?[:0]const u8,
    wl_seat: ?*wl.Seat = null,
};

fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, state: *CbState) void {
    switch (event) {
        .capabilities => {},
        .name => |name| {
            if (state.name) |seat_name| {
                if (mem.eql(u8, seat_name, mem.span(name.name))) {
                    state.wl_seat = seat;
                } else {
                    seat.destroy();
                }
            }
        },
    }
}
