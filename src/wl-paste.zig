const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("helpers");
const wlcb = @import("wl_clipboard");
const mime = @import("mime");
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
};

const Cli = struct {
    type: ?[:0]const u8 = null,
    seat: ?[:0]const u8 = null,
    no_newline: bool = false,
    verbose: bool = false,
    list_types: bool = false,
    primary: bool = false,

    const Self = @This();

    fn init() Self {
        var self = Cli{};

        var args = std.process.args();
        var index: u8 = 0;
        while (args.next()) |arg| : (index += 1) {
            if (index == 0) continue;

            const argument = std.meta.stringToEnum(Arguments, arg) orelse {
                std.log.err("Argument {s} not found", .{arg});
                std.process.exit(1);
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
                .@"--seat", .@"-s" => {
                    if (args.next()) |flag_arg| {
                        self.seat = flag_arg;
                    } else {
                        std.log.err("option requires an argument -- 'seat'\n", .{});
                        std.log.info("{s}\n", .{help_message});
                        std.process.exit(0);
                    }
                },
                .@"--type", .@"-t" => {
                    if (args.next()) |flag_arg| {
                        self.type = flag_arg;
                    } else {
                        std.log.err("option requires an argument -- 'type'\n", .{});
                        std.log.info("{s}\n", .{help_message});
                        std.process.exit(0);
                    }
                },
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
    \\  -p, --primary  
    \\          Use the "primary" clipboard  
    \\  
    \\          Pasting to the "primary" clipboard requires the compositor to support the data-control protocol of version 2 or above.  
    \\  
    \\  -n, --no-newline  
    \\          Do not append a newline character  
    \\  
    \\          By default the newline character is appended automatically when pasting text MIME types.  
    \\  
    \\  -s, --seat <SEAT>  
    \\          Pick the seat to work with  
    \\  
    \\          By default the seat used is unspecified (it depends on the order returned by the compositor). This is perfectly fine when  
    \\          only a single seat is present, so for most configurations.  
    \\  
    \\  -t, --type <MIME/TYPE>  
    \\          Request the given MIME type instead of inferring the MIME type  
    \\  
    \\          As a special case, specifying "text" will look for a number of plain text types, prioritizing ones that are known to give  
    \\          UTF-8 text.  
    \\  
    \\  -v, --verbose...  
    \\          Enable verbose logging  
    \\  
    \\  -h, --help  
    \\          Print help (see a summary with '-h')  
    \\  
    \\  -V, --version  
    \\          Print version  
    \\  
;

pub fn main() !void {
    var dbg_gpa = if (@import("builtin").mode == .Debug) std.heap.GeneralPurposeAllocator(.{}){} else {};
    defer if (@TypeOf(dbg_gpa) != void) {
        _ = dbg_gpa.deinit();
    };
    const alloc = if (@TypeOf(dbg_gpa) != void) dbg_gpa.allocator() else std.heap.c_allocator;

    var stdout_buffer: [0x100]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const cli = Cli.init();
    verbose_enabled = cli.verbose;

    var wl_clipboard = try wlcb.WlClipboard.init(.{});
    defer wl_clipboard.deinit();

    var clipboard_content = try wl_clipboard.paste(alloc, .{ .mime_type = cli.type, .primary = cli.primary });
    defer clipboard_content.deinit();

    if (cli.list_types) {
        for (clipboard_content.mime_types) |mime_type| {
            try stdout.print("{s}\n", .{mime_type});
        }

        try stdout.flush();
        return;
    }

    try stdout.writeAll(clipboard_content.content);
    if (!cli.no_newline) {
        try stdout.writeAll("\n");
    }
    try stdout.flush();
}
