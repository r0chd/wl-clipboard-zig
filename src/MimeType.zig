const std = @import("std");
const mime = @import("mime");
const mem = std.mem;
const ascii = std.ascii;
const fs = std.fs;
const posix = std.posix;

available_mime_types: [][:0]const u8,

const Self = @This();

pub fn init(mime_types: [][:0]const u8) Self {
    return .{
        .available_mime_types = mime_types,
    };
}

pub fn infer(self: *Self, explicit_mime_type: ?[:0]const u8) ![:0]const u8 {
    if (explicit_mime_type) |selected_mime_type| {
        if (mem.eql(u8, selected_mime_type, "text")) {
            if (sliceContains(self.available_mime_types, "text/plain;charset=utf-8")) {
                return "text/plain;charset=utf-8";
            } else if (sliceContains(self.available_mime_types, "text/plain")) {
                return "text/plain";
            } else {
                for (self.available_mime_types) |item| {
                    if (mimeTypeIsText(item)) {
                        return item;
                    }
                }
            }
        } else if (mem.containsAtLeast(u8, selected_mime_type, 1, "/")) {
            return selected_mime_type;
        } else if (ascii.toUpper(selected_mime_type[0]) == selected_mime_type[0]) {
            return selected_mime_type;
        } else {
            for (self.available_mime_types) |item| {
                if (mem.eql(u8, item, selected_mime_type)) {
                    return item;
                }
            }

            for (self.available_mime_types) |item| {
                if (mem.startsWith(u8, item, selected_mime_type)) {
                    return selected_mime_type;
                }
            }
        }
    } else {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const stdout_path = try std.os.getFdPath(posix.STDOUT_FILENO, &buf);
        const mime_type = mime.extension_map.get(std.fs.path.extension(stdout_path));
        if (mime_type) |mime_type_inner| {
            if (sliceContains(self.available_mime_types, @tagName(mime_type_inner))) {
                return @tagName(mime_type_inner);
            }

            if (mimeTypeIsText(@tagName(mime_type_inner))) {
                if (sliceContains(self.available_mime_types, "text/plain;charset=utf-8")) {
                    return "text/plain;charset=utf-8";
                } else if (sliceContains(self.available_mime_types, "text/plain")) {
                    return "text/plain";
                } else {
                    for (self.available_mime_types) |item| {
                        if (mimeTypeIsText(item)) {
                            return item;
                        }
                    }
                }
            }
        }
    }

    if (sliceContains(self.available_mime_types, "text/plain;charset=utf-8")) {
        return "text/plain;charset=utf-8";
    } else if (sliceContains(self.available_mime_types, "text/plain")) {
        return "text/plain";
    } else {
        for (self.available_mime_types) |mime_type| {
            if (mimeTypeIsText(mime_type)) {
                return mime_type;
            }
        }
    }

    return self.available_mime_types[0];
}

pub fn sliceContains(haystack: []const [:0]const u8, needle: [:0]const u8) bool {
    for (haystack) |thing| {
        if (mem.eql(u8, thing, needle)) {
            return true;
        }
    }
    return false;
}

fn mimeTypeIsText(mime_type: []const u8) bool {
    const basic = mem.startsWith(u8, mime_type, "text/") or
        mem.eql(u8, mime_type, "TEXT") or
        mem.eql(u8, mime_type, "STRING") or
        mem.eql(u8, mime_type, "UTF8_STRING");
    const common = mem.containsAtLeast(u8, mime_type, 1, "json") or
        mem.endsWith(u8, mime_type, "script") or
        mem.endsWith(u8, mime_type, "xml") or
        mem.endsWith(u8, mime_type, "yaml") or
        mem.endsWith(u8, mime_type, "csv") or
        mem.endsWith(u8, mime_type, "ini");
    const special = mem.containsAtLeast(u8, mime_type, 1, "application/vnd.ms-publisher") or
        mem.endsWith(u8, mime_type, "pgp-keys");

    return basic or common or special;
}
