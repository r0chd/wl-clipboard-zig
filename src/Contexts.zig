// Initializing those contexts here to avoid heap allocation of them when passing to
// wayland callbacks

const std = @import("std");
const mem = std.mem;
const tmp = @import("tmpfile");
const Display = @import("wayland/Display.zig");
const Device = @import("Device.zig");
const Event = @import("root.zig").Event;

copy: CopyContext,
watch: WatchContext,

const Self = @This();

pub fn init(gpa: mem.Allocator, display: Display) !Self {
    return .{
        .copy = .{
            .display = display,
            .tmpfile = try tmp.TmpFile.init(gpa, .{
                .flags = .{ .read = true, .mode = 0o400 },
            }),
        },
        .watch = .{
            .offer = null,
            .gpa = gpa,
            .callback = undefined,
            .data = undefined,
            .mime_types = .empty,
            .display = display,
        },
    };
}

pub fn fixStopPointer(self: *Self, stop: *bool) void {
    self.copy.stop = stop;
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    self.copy.deinit(gpa);
    self.watch.mime_types.deinit(gpa);
}

pub const CopyContext = struct {
    stop: bool = false,
    tmpfile: tmp.TmpFile,
    display: Display,
    paste_once: bool = false,
    mime_type: ?[:0]const u8 = null,

    pub fn deinit(self: *CopyContext, gpa: mem.Allocator) void {
        if (self.mime_type) |mime_type| {
            gpa.free(mime_type);
            self.mime_type = null;
        }
        self.tmpfile.deinit(gpa);
    }
};

pub const WatchContext = struct {
    offer: ?*Device.DataOffer = null,
    gpa: mem.Allocator,
    callback: *const fn (Event, *anyopaque) void,
    data: *anyopaque,
    mime_types: std.ArrayList([:0]const u8) = .empty,
    display: Display,
};
