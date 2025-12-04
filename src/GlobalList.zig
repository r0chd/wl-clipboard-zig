const std = @import("std");
const wl = @import("wayland").client.wl;
const mem = std.mem;

registry: *wl.Registry,
inner: Inner,

const Self = @This();

pub fn init(display: *wl.Display, alloc: mem.Allocator) !Self {
    const registry = try display.getRegistry();

    var inner = Inner{};

    registry.setListener(*const RegistryUserData, registryListener, &.{ .inner = &inner, .alloc = alloc });
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    return .{ .registry = registry, .inner = inner };
}

pub fn deinit(self: *Self, alloc: mem.Allocator) void {
    self.registry.destroy();
    for (self.inner.globals.items) |global| {
        alloc.free(global.interface);
    }
    self.inner.globals.deinit(alloc);
}

pub fn bind(self: *const Self, comptime T: type, version: u32) ?*T {
    for (self.inner.globals.items) |global| {
        if (std.mem.eql(u8, mem.span(T.interface.name), global.interface)) {
            return self.registry.bind(global.name, T, version) catch return null;
        }
    }

    return null;
}

const Inner = struct {
    globals: std.ArrayList(Global) = .empty,
};

const Global = struct { name: u32, interface: [:0]const u8, version: u32 };

const RegistryUserData = struct { inner: *Inner, alloc: mem.Allocator };

fn registryListener(_: *wl.Registry, event: wl.Registry.Event, state: *const RegistryUserData) void {
    switch (event) {
        .global => |global| {
            state.inner.globals.append(state.alloc, .{
                .name = global.name,
                .interface = state.alloc.dupeZ(u8, mem.span(global.interface)) catch return,
                .version = global.version,
            }) catch return;
        },
        .global_remove => |removed| {
            for (state.inner.globals.items, 0..) |global, i| {
                if (global.name == removed.name) {
                    const removed_global = state.inner.globals.swapRemove(i);
                    state.alloc.free(removed_global.interface);
                }
            }
        },
    }
}
