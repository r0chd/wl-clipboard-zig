const c = @cImport(@cInclude("magic.h"));
const std = @import("std");
const mem = std.mem;

const Self = @This();

magic: ?*c.struct_magic_set,

pub const Flag = enum(c_int) {
    mime_type = c.MAGIC_MIME_TYPE,
};

pub fn open(flag: Flag) Self {
    const magic = c.magic_open(@intFromEnum(flag));

    return .{ .magic = magic };
}

pub fn close(self: *Self) void {
    c.magic_close(self.magic);
}

pub fn load(self: *Self, magic_file: ?[:0]const u8) void {
    if (magic_file) |mf| {
        _ = c.magic_load(self.magic, mf);
    } else {
        _ = c.magic_load(self.magic, null);
    }
}

pub fn file(self: *Self, path: []const u8) [:0]const u8 {
    return mem.span(c.magic_file(self.magic, path.ptr));
}
