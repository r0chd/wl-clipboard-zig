const std = @import("std");
const wl = @import("wayland").client.wl;

display: *wl.Display,
mutex: std.Thread.Mutex,

const Self = @This();

pub fn connect(name: ?[*:0]const u8) !Self {
    const display = try wl.Display.connect(name);

    return .{
        .display = display,
        .mutex = std.Thread.Mutex{},
    };
}

pub fn disconnect(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    self.display.disconnect();
}

pub fn dispatch(self: *Self) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.display.dispatch() != .SUCCESS) return error.DispatchFailed;
}

pub fn roundtrip(self: *Self) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
}

pub fn flush(self: *Self) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.display.flush() != .SUCCESS) return error.FlushFailed;
}

pub fn getRegistry(self: *Self) !*wl.Registry {
    self.mutex.lock();
    defer self.mutex.unlock();

    return self.display.getRegistry();
}
