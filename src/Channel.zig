const std = @import("std");
const meta = std.meta;

pub fn Channel(comptime T: type) type {
    return struct {
        value: ?T,
        mutex: std.Thread.Mutex,
        cond: std.Thread.Condition,

        const Self = @This();

        pub fn init() Self {
            return Self{ .value = null, .mutex = std.Thread.Mutex{}, .cond = std.Thread.Condition{} };
        }

        pub fn send(self: *Self, value: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.value = value;
            self.cond.signal();
        }

        pub fn tryReceive(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            defer self.value = null;

            if (self.value == null) return null;

            return self.value;
        }

        pub fn receive(self: *Self) T {
            self.mutex.lock();
            defer self.mutex.unlock();
            defer self.value = null;

            self.cond.wait(&self.mutex);

            // If we received then it's safe to assume that value isnt null
            return self.value.?;
        }
    };
}
