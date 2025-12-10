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
            shared_states: *SharedStates,

            const Self = @This();

            pub fn send(self: *Self, value: T) void {
                for (self.shared_states.array.items) |*shared_state| {
                    shared_state.mutex.lock();
                    defer shared_state.mutex.unlock();
                    shared_state.value = value;
                    shared_state.cond.signal();
                }
            }

            pub fn receiver(self: *Self, alloc: mem.Allocator) !Receiver {
                try self.shared_states.array.append(alloc, .{
                    .value = null,
                    .mutex = std.Thread.Mutex{},
                    .cond = std.Thread.Condition{},
                });

                return .{ .shared_state = &self.shared_states.array.items[self.shared_states.array.items.len - 1] };
            }

            pub fn clone(self: *Self) Self {
                self.shared_states.ref();

                return .{ .shared_states = self.shared_states };
            }

            pub fn deinit(self: *Self, alloc: mem.Allocator) void {
                for (0..self.shared_states.array.items.len) |_| {
                    self.shared_states.unref(alloc);
                }
            }
        };

        const SharedStates = struct {
            array: std.ArrayList(SharedState),
            ref_count: std.atomic.Value(u32),

            const Self = @This();

            pub fn init() Self {
                return .{
                    .array = .empty,
                    .ref_count = std.atomic.Value(u32).init(1),
                };
            }

            fn ref(self: *SharedStates) void {
                _ = self.ref_count.fetchAdd(1, .monotonic);
            }

            fn unref(self: *SharedStates, alloc: mem.Allocator) void {
                if (self.ref_count.fetchSub(1, .monotonic) == 1) {
                    self.array.deinit(alloc);
                    alloc.destroy(self);
                }
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
                .shared_states = try alloc.create(SharedStates),
            };
            sender.shared_states.* = SharedStates.init();

            return .{ sender, try sender.receiver(alloc) };
        }
    };
}
