const std = @import("std");
const meta = std.meta;
const mem = std.mem;

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

pub fn broadcast(comptime T: type) type {
    const SharedState = struct {
        value: ?T,
        mutex: std.Thread.Mutex,
        cond: std.Thread.Condition,
    };

    return struct {
        pub const Sender = struct {
            shared_states: std.ArrayList(SharedState),

            const Self = @This();

            pub fn send(self: *Self, value: T) void {
                for (self.shared_states.items) |*shared_state| {
                    shared_state.mutex.lock();
                    defer shared_state.mutex.unlock();
                    shared_state.value = value;
                    shared_state.cond.signal();
                }
            }

            pub fn receiver(self: *Self, alloc: mem.Allocator) !Receiver {
                try self.shared_states.append(alloc, .{
                    .value = null,
                    .mutex = std.Thread.Mutex{},
                    .cond = std.Thread.Condition{},
                });

                return .{ .shared_state = &self.shared_states.items[self.shared_states.items.len - 1] };
            }

            pub fn deinit(self: *Self, alloc: mem.Allocator) void {
                self.shared_states.deinit(alloc);
            }
        };

        pub const Receiver = struct {
            shared_state: *SharedState,

            const Self = @This();

            pub fn tryReceive(self: *Self) ?T {
                if (!self.shared_state.mutex.tryLock()) return null;
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

        pub fn init(alloc: mem.Allocator) !meta.Tuple(&.{ Sender, Receiver }) {
            var sender = Sender{
                .shared_states = .empty,
            };
            try sender.shared_states.append(alloc, .{
                .value = null,
                .mutex = std.Thread.Mutex{},
                .cond = std.Thread.Condition{},
            });

            return .{ sender, Receiver{ .shared_state = &sender.shared_states.items[0] } };
        }
    };
}
