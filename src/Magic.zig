const c = @cImport(@cInclude("magic.h"));
const std = @import("std");
const mem = std.mem;

const Self = @This();

magic: ?*c.struct_magic_set,

pub const Flag = enum(c_int) {
    mime_type = c.MAGIC_MIME_TYPE,
};

pub fn open(flag: Flag) ?Self {
    const magic = c.magic_open(@intFromEnum(flag));
    if (magic == null) {
        return null;
    }

    _ = c.magic_load(magic, null);

    return .{ .magic = magic };
}

pub fn close(self: *Self) void {
    c.magic_close(self.magic);
}

pub fn file(self: *Self, path: [:0]const u8) ?[:0]const u8 {
    const mime_type = c.magic_file(self.magic, path.ptr);
    return if (mime_type) |mime| mem.span(mime) else return null;
}
