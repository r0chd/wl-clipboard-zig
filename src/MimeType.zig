const std = @import("std");
const mime = @import("mime");
const mem = std.mem;
const ascii = std.ascii;
const posix = std.posix;

available_mime_types: [][:0]const u8,

const Self = @This();

const text_plain_utf8 = "text/plain;charset=utf-8";
const text_plain = "text/plain";

pub fn init(mime_types: [][:0]const u8) Self {
    return .{
        .available_mime_types = mime_types,
    };
}

const ClassifiedTypes = struct {
    explicit_available: bool = false,
    inferred_available: bool = false,
    plain_text_utf8_available: bool = false,
    plain_text_available: bool = false,
    any_text: ?[:0]const u8 = null,
    any: ?[:0]const u8 = null,
    having_explicit_as_prefix: ?[:0]const u8 = null,
};

fn classifyTypes(self: *Self, explicit_type: ?[:0]const u8, inferred_type: ?[:0]const u8) ClassifiedTypes {
    var types = ClassifiedTypes{};

    for (self.available_mime_types) |mime_type| {
        if (explicit_type) |explicit| {
            if (mem.eql(u8, mime_type, explicit)) {
                types.explicit_available = true;
            }
            if (types.having_explicit_as_prefix == null and mem.startsWith(u8, mime_type, explicit)) {
                types.having_explicit_as_prefix = mime_type;
            }
        }

        if (inferred_type) |inferred| {
            if (mem.eql(u8, mime_type, inferred)) {
                types.inferred_available = true;
            }
        }

        if (mem.eql(u8, mime_type, text_plain_utf8)) {
            types.plain_text_utf8_available = true;
        }

        if (mem.eql(u8, mime_type, text_plain)) {
            types.plain_text_available = true;
        }

        if (types.any_text == null and mimeTypeIsText(mime_type)) {
            types.any_text = mime_type;
        }

        if (types.any == null) {
            types.any = mime_type;
        }
    }

    return types;
}

pub fn infer(self: *Self, explicit_mime_type: ?[:0]const u8) ![:0]const u8 {
    var inferred_type: ?[:0]const u8 = null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const stdout_path = std.os.getFdPath(posix.STDOUT_FILENO, &buf) catch null;
    if (stdout_path) |path| {
        const ext = std.fs.path.extension(path);
        if (mime.extension_map.get(ext)) |mime_type_inner| {
            inferred_type = @tagName(mime_type_inner);
        }
    }

    const types = self.classifyTypes(explicit_mime_type, inferred_type);

    if (explicit_mime_type) |explicit| {
        if (mem.eql(u8, explicit, "text")) {
            if (types.plain_text_utf8_available) {
                return text_plain_utf8;
            }
            if (types.plain_text_available) {
                return text_plain;
            }
            if (types.any_text) |any_text| {
                return any_text;
            }
        } else if (mem.containsAtLeast(u8, explicit, 1, "/")) {
            if (types.explicit_available) {
                return explicit;
            }
        } else if (ascii.toUpper(explicit[0]) == explicit[0]) {
            if (types.explicit_available) {
                return explicit;
            }
        } else {
            if (types.explicit_available) {
                return explicit;
            }
            if (types.having_explicit_as_prefix) |prefixed| {
                return prefixed;
            }
        }
    } else {
        if (inferred_type == null) {
            if (types.plain_text_utf8_available) {
                return text_plain_utf8;
            }
            if (types.plain_text_available) {
                return text_plain;
            }
            if (types.any_text) |any_text| {
                return any_text;
            }
            if (types.any) |any| {
                return any;
            }
        } else if (mimeTypeIsText(inferred_type.?)) {
            if (types.inferred_available) {
                return inferred_type.?;
            }
            if (types.plain_text_utf8_available) {
                return text_plain_utf8;
            }
            if (types.plain_text_available) {
                return text_plain;
            }
            if (types.any_text) |any_text| {
                return any_text;
            }
        } else {
            if (types.inferred_available) {
                return inferred_type.?;
            }
        }
    }

    if (types.any) |any| {
        return any;
    }
    return self.available_mime_types[0];
}

pub fn mimeTypeIsText(mime_type: [:0]const u8) bool {
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
