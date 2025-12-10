// Preallocated contexts that are free'd once at the end of the program to avoid unnecessary
// memory allocations and free's everytime WlClipboard.copy or WlClipboard.watch is called

const std = @import("std");
const mem = std.mem;
const channel = @import("channel.zig");
const tmp = @import("tmpfile.zig");
const Display = @import("wayland/Display.zig");
const Device = @import("Device.zig");
const Event = @import("root.zig").Event;
const broadcast = @import("channel.zig").broadcast;

copy: *CopyContext,
watch: *WatchContext,

const Self = @This();

pub fn init(alloc: mem.Allocator, display: Display, sender: broadcast(void).Sender) !Self {
    const copy = try alloc.create(CopyContext);
    copy.* = .{
        .display = display,
        .sender = sender,
        .tmpfile = try tmp.TmpFile.init(alloc, .{
            .prefix = null,
            .dir_prefix = null,
            .flags = .{ .read = true, .mode = 0o400 },
            .dir_opts = .{},
        }),
    };

    const watch = try alloc.create(WatchContext);
    watch.* = .{
        .offer = null,
        .alloc = alloc,
        .callback = undefined,
        .data = undefined,
        .mime_types = .empty,
        .display = display,
    };

    return .{ .copy = copy, .watch = watch };
}

pub fn deinit(self: *Self, alloc: mem.Allocator) void {
    self.copy.deinit(alloc);
    alloc.destroy(self.copy);
    self.watch.mime_types.deinit(alloc);
    alloc.destroy(self.watch);
}

pub const CopyContext = struct {
    sender: channel.broadcast(void).Sender,
    tmpfile: tmp.TmpFile,
    display: Display,
    paste_once: bool = false,
    mime_type: ?[:0]const u8 = null,

    pub fn deinit(self: *CopyContext, alloc: mem.Allocator) void {
        if (self.mime_type) |mime_type| {
            alloc.free(mime_type);
            self.mime_type = null;
        }
        self.tmpfile.deinit(alloc);
    }
};

pub const WatchContext = struct {
    offer: ?*Device.DataOffer = null,
    alloc: mem.Allocator,
    callback: *const fn (Event, *anyopaque) void,
    data: *anyopaque,
    mime_types: std.ArrayList([:0]const u8) = .empty,
    display: Display,
};
