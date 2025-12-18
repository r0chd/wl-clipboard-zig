const std = @import("std");
const wl = @import("wayland").client.wl;

display: *wl.Display,

const Self = @This();

pub fn connect(name: ?[*:0]const u8) !Self {
    const display = try wl.Display.connect(name);

    return .{
        .display = display,
    };
}

pub fn disconnect(self: *Self) void {
    self.display.disconnect();
}

pub fn dispatch(self: *Self) !void {
    if (self.display.dispatch() != .SUCCESS) return error.DispatchFailed;
}

pub fn roundtrip(self: *Self) !void {
    if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
}

pub fn flush(self: *Self) !void {
    if (self.display.flush() != .SUCCESS) return error.FlushFailed;
}

pub fn getRegistry(self: *Self) !*wl.Registry {
    return self.display.getRegistry();
}
