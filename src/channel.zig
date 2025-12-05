const std = @import("std");
const meta = std.meta;

pub fn spsc(comptime T: type) type {
    const SharedState = struct {
        value: ?T,
        mutex: std.Thread.Mutex,
        cond: std.Thread.Condition,
    };

    return struct {
        pub const Sender = struct {
            shared_state: SharedState,

            const Self = @This();

            pub fn send(self: *Self, value: T) void {
                self.shared_state.mutex.lock();
                defer self.shared_state.mutex.unlock();
                self.shared_state.value = value;
                self.shared_state.cond.signal();
            }
        };

        pub const Receiver = struct {
            shared_state: *SharedState,

            const Self = @This();

            pub fn tryReceive(self: *Self) ?T {
                self.shared_state.mutex.lock();
                defer self.shared_state.mutex.unlock();

                if (self.shared_state.value == null) return null;

                defer self.shared_state.value = null;

                return self.shared_state.value;
            }

            pub fn receive(self: *Self) T {
                self.shared_state.mutex.lock();
                defer self.shared_state.mutex.unlock();

                while (self.shared_state.value == null) {
                    self.shared_state.cond.wait(&self.shared_state.mutex);
                }

                defer self.shared_state.value = null;

                return self.shared_state.value.?;
            }
        };

        pub fn init() meta.Tuple(&.{ Sender, Receiver }) {
            var sender = Sender{
                .shared_state = .{
                    .value = null,
                    .mutex = std.Thread.Mutex{},
                    .cond = std.Thread.Condition{},
                },
            };

            return .{ sender, Receiver{ .shared_state = &sender.shared_state } };
        }
    };
}
