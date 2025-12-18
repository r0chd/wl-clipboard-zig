const std = @import("std");
const builtin = @import("builtin");
const wlcb = @import("wl_clipboard");
const mem = std.mem;
const meta = std.meta;
const posix = std.posix;

var verbose_enabled = false;

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (level == .debug and !verbose_enabled) return;

    std.log.defaultLog(level, scope, format, args);
}

const Arguments = enum {
    @"--help",
    @"-h",
    @"--version",
    @"-V",
    @"--verbose",
    @"-v",

    @"--no-newline",
    @"-n",
    @"--list-types",
    @"-l",
    @"--primary",
    @"-p",
    @"--seat",
    @"-s",
    @"--type",
    @"-t",
    @"--backend",
    @"-b",
    @"--watch",
    @"-w",
};

const Cli = struct {
    type: ?[:0]const u8 = null,
    seat: ?[:0]const u8 = null,
    no_newline: bool = false,
    verbose: bool = false,
    list_types: bool = false,
    primary: bool = false,
    backend: ?wlcb.Backend = null,
    watch: ?[][:0]const u8 = null,

    const Self = @This();

    fn init(alloc: mem.Allocator) !Self {
        var self = Cli{};

        var args = std.process.args();
        var index: u8 = 0;
        while (args.next()) |arg| : (index += 1) {
            if (index == 0) continue;

            const argument = std.meta.stringToEnum(Arguments, arg) orelse {
                std.log.err("unexpected argument '{s}' found\n", .{arg});
                std.debug.print("Usage: wl-paste [OPTIONS]\n\n", .{});
                std.debug.print("For more information, try '--help'.\n", .{});
                std.process.exit(2);
            };
            switch (argument) {
                .@"--help", .@"-h" => {
                    std.log.info("{s}\n", .{help_message});
                    std.process.exit(0);
                },
                .@"--version", .@"-V" => {
                    std.log.info("wl-paste v0.1.0 \nBuild type: {any}\nZig {any}\n", .{ builtin.mode, builtin.zig_version });
                    std.process.exit(0);
                },
                .@"--verbose", .@"-v" => {
                    self.verbose = true;
                },

                .@"--no-newline", .@"-n" => {
                    self.no_newline = true;
                },
                .@"--list-types", .@"-l" => {
                    self.list_types = true;
                },
                .@"--primary", .@"-p" => {
                    self.primary = true;
                },
                .@"--watch", .@"-w" => {
                    var command: std.ArrayList([:0]const u8) = .empty;
                    while (args.next()) |str| {
                        try command.append(alloc, str);
                    }

                    self.watch = try command.toOwnedSlice(alloc);
                },
                .@"--seat", .@"-s" => {
                    if (args.next()) |flag_arg| {
                        self.seat = flag_arg;
                    } else {
                        std.log.err("the argument '--seat <SEAT>' requires a value but none was supplied\n", .{});
                        std.debug.print("Usage: wl-paste [OPTIONS]\n\n", .{});
                        std.debug.print("For more information, try '--help'.\n", .{});
                        std.process.exit(2);
                    }
                },
                .@"--type", .@"-t" => {
                    if (args.next()) |flag_arg| {
                        self.type = flag_arg;
                    } else {
                        std.log.err("the argument '--type <MIME/TYPE>' requires a value but none was supplied\n", .{});
                        std.debug.print("Usage: wl-paste [OPTIONS]\n\n", .{});
                        std.debug.print("For more information, try '--help'.\n", .{});
                        std.process.exit(2);
                    }
                },
                .@"--backend", .@"-b" => {
                    if (args.next()) |flag_arg| {
                        self.backend = meta.stringToEnum(wlcb.Backend, flag_arg) orelse {
                            std.log.err("invalid value '{s}' for '--backend <BACKEND>'\n", .{flag_arg});
                            std.debug.print("  [possible values: ", .{});
                            inline for (meta.fields(wlcb.Backend), 0..) |field, i| {
                                std.debug.print("{s}", .{field.name});
                                if (i != meta.fields(wlcb.Backend).len - 1) {
                                    std.debug.print(", ", .{});
                                }
                            }
                            std.debug.print("]\n\n", .{});
                            std.debug.print("Usage: wl-paste [OPTIONS]\n\n", .{});
                            std.debug.print("For more information, try '--help'.\n", .{});
                            std.process.exit(2);
                        };
                    } else {
                        std.log.err("the argument '--backend <BACKEND>' requires a value but none was supplied\n", .{});
                        std.debug.print("Usage: wl-paste [OPTIONS]\n\n", .{});
                        std.debug.print("For more information, try '--help'.\n", .{});
                        std.process.exit(2);
                    }
                },
            }
        }

        if (self.backend == null) {
            if (posix.getenv("WL_CLIPBOARD_BACKEND")) |backend| {
                self.backend = meta.stringToEnum(wlcb.Backend, backend);
            }
        }

        return self;
    }
};

const help_message =
    \\Usage: wl-paste [OPTIONS]
    \\
    \\Options:
    \\  -l, --list-types
    \\          List the offered MIME types instead of pasting
    \\
    \\          Pasting to the "primary" clipboard requires the compositor to support the data-control protocol of version 2 or above
    \\
    \\  -p, --primary
    \\          Use the "primary" clipboard
    \\
    \\  -n, --no-newline
    \\          Do not append a newline character
    \\
    \\          By default the newline character is appended automatically when pasting text MIME types
    \\
    \\  -s, --seat <SEAT>
    \\          Pick the seat to work with
    \\
    \\          By default the seat used is unspecified (it depends on the order returned by the compositor). This is perfectly fine when only a single seat is present, so for most configurations
    \\
    \\  -t, --type <MIME/TYPE>
    \\          Request the given MIME type instead of inferring the MIME type
    \\
    \\          As a special case, specifying "text" will look for a number of plain text types, prioritizing ones that are known to give UTF-8 text
    \\
    \\  -b, --backend <BACKEND>
    \\          Force clipboard backend 
    \\
    \\          [env: WL_CLIPBOARD_BACKEND=]
    \\
    \\  -w, --watch <STRING>
    \\          Run a command each time the selection changes
    \\
    \\  -v, --verbose
    \\          Enable verbose logging
    \\
    \\  -h, --help
    \\          Print help (see a summary with '-h')
    \\
    \\  -V, --version
    \\          Print version
    \\
;

const CallbackData = struct { command: [][:0]const u8, alloc: mem.Allocator, clipboard: enum { primary, regular } };

fn clipboardCallback(event: wlcb.Event, data: *CallbackData) void {
    var read_buf: [4096]u8 = undefined;
    var wrote_anything = false;

    var data_buf: [4096 * 16]u8 = undefined;
    var data_len: usize = 0;

    switch (event) {
        .primary_selection => |pipe| {
            if (data.clipboard == .primary) {
                while (true) {
                    const bytes_read = posix.read(pipe, &read_buf) catch |err| switch (err) {
                        error.WouldBlock => continue,
                        else => return,
                    };

                    if (bytes_read == 0) break;
                    wrote_anything = true;

                    if (data_len + bytes_read <= data_buf.len) {
                        @memcpy(data_buf[data_len .. data_len + bytes_read], read_buf[0..bytes_read]);
                        data_len += bytes_read;
                    }
                }
            }
        },
        .selection => |pipe| {
            if (data.clipboard == .regular) {
                while (true) {
                    const bytes_read = posix.read(pipe, &read_buf) catch |err| switch (err) {
                        error.WouldBlock => continue,
                        else => return,
                    };

                    if (bytes_read == 0) break;
                    wrote_anything = true;

                    if (data_len + bytes_read <= data_buf.len) {
                        @memcpy(data_buf[data_len .. data_len + bytes_read], read_buf[0..bytes_read]);
                        data_len += bytes_read;
                    }
                }
            }
        },
    }

    if (wrote_anything) {
        var child = std.process.Child.init(data.command, data.alloc);
        child.stdin_behavior = .Pipe;

        child.spawn() catch return;
        child.stdin.?.writeAll(data_buf[0..data_len]) catch return;
        child.stdin.?.close();
        child.stdin = null;

        _ = child.wait() catch return;
    }
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const cli = try Cli.init(alloc);
    verbose_enabled = cli.verbose;

    var wl_clipboard = try wlcb.WlClipboard.init(alloc, .{});
    defer wl_clipboard.deinit(alloc);

    if (cli.watch) |command| {
        var callback_data = CallbackData{
            .command = command,
            .alloc = alloc,
            .clipboard = if (cli.primary) .primary else .regular,
        };
        try wl_clipboard.watch(alloc, *CallbackData, clipboardCallback, &callback_data);
    }

    var clipboard_content = try wl_clipboard.paste(alloc, .{ .mime_type = cli.type, .primary = cli.primary });
    defer clipboard_content.deinit(alloc);

    if (cli.list_types) {
        for (clipboard_content.mimeTypes()) |mime_type| {
            try stdout.print("{s}\n", .{mime_type});
        }

        try stdout.flush();
        return;
    }

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = posix.read(clipboard_content.pipe, &read_buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };

        if (bytes_read == 0) break;
        try stdout.writeAll(read_buf[0..bytes_read]);
    }

    if (!cli.no_newline) {
        try stdout.writeAll("\n");
    }
    try stdout.flush();
}
