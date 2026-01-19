const std = @import("std");
const wl = @import("wayland").client.wl;
const mem = std.mem;
const Display = @import("Display.zig");

registry: *wl.Registry,
inner: Inner,

const Self = @This();

pub fn init(display: *Display, gpa: mem.Allocator) !Self {
    const registry = try display.getRegistry();

    var inner = Inner{};

    registry.setListener(*const RegistryUserData, registryListener, &.{ .inner = &inner, .gpa = gpa });
    try display.roundtrip();

    return .{ .registry = registry, .inner = inner };
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    self.registry.destroy();
    for (self.inner.globals.items) |global| {
        gpa.free(global.interface);
    }
    self.inner.globals.deinit(gpa);
}

pub fn findGlobal(self: *const Self, comptime T: type) bool {
    for (self.inner.globals.items) |global| {
        if (std.mem.eql(u8, mem.span(T.interface.name), global.interface)) return true;
    }
    return false;
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

const RegistryUserData = struct { inner: *Inner, gpa: mem.Allocator };

fn registryListener(_: *wl.Registry, event: wl.Registry.Event, state: *const RegistryUserData) void {
    switch (event) {
        .global => |global| {
            state.inner.globals.append(state.gpa, .{
                .name = global.name,
                .interface = state.gpa.dupeZ(u8, mem.span(global.interface)) catch return,
                .version = global.version,
            }) catch return;
        },
        .global_remove => |removed| {
            for (state.inner.globals.items, 0..) |global, i| {
                if (global.name == removed.name) {
                    const removed_global = state.inner.globals.swapRemove(i);
                    state.gpa.free(removed_global.interface);
                }
            }
        },
    }
}
