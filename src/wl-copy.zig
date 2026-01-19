const std = @import("std");
const builtin = @import("builtin");
const wlcb = @import("wl_clipboard");
const tmp = @import("tmpfile");

const mem = std.mem;
const meta = std.meta;
const fs = std.fs;
const posix = std.posix;
const os = std.os;
const log = std.log;
const process = std.process;

var verbose_enabled = false;

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

fn logFn(
    comptime level: log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (level == .debug and !verbose_enabled) return;

    log.defaultLog(level, scope, format, args);
}

const Arguments = enum {
    @"--help",
    @"-h",
    @"--version",
    @"-V",
    @"--verbose",
    @"-v",

    @"-o",
    @"--paste-once",
    @"-f",
    @"--foreground",
    @"-c",
    @"--clear",
    @"-p",
    @"--primary",
    @"-r",
    @"--regular",
    @"-n",
    @"--trim-newline",
    @"-s",
    @"--seat",
    @"-t",
    @"--type",
    @"-b",
    @"--backend",
};

const Cli = struct {
    data: ?[]u8 = null,
    verbose: bool = false,
    paste_once: bool = false,
    foreground: bool = false,
    clear: bool = false,
    primary: bool = false,
    trim_newline: bool = false,
    type: ?[:0]const u8 = null,
    seat: ?[:0]const u8 = null,
    regular: bool = false,
    backend: ?wlcb.Backend = null,

    const Self = @This();

    fn init(gpa: mem.Allocator) !Self {
        var self = Cli{};

        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);

        var args = process.args();
        var index: u8 = 0;
        while (args.next()) |arg| : (index += 1) {
            if (index == 0) continue;

            if (meta.stringToEnum(Arguments, arg)) |argument| {
                switch (argument) {
                    .@"--help", .@"-h" => {
                        log.info("{s}\n", .{help_message});
                        process.exit(0);
                    },
                    .@"--version", .@"-V" => {
                        log.info("wl-copy v0.1.0 \nBuild type: {any}\nZig {any}\n", .{ builtin.mode, builtin.zig_version });
                        process.exit(0);
                    },
                    .@"--verbose", .@"-v" => {
                        self.verbose = true;
                    },

                    .@"--paste-once", .@"-o" => {
                        self.paste_once = true;
                    },
                    .@"--foreground", .@"-f" => {
                        self.foreground = true;
                    },
                    .@"--clear", .@"-c" => {
                        self.clear = true;
                    },
                    .@"--primary", .@"-p" => {
                        self.primary = true;
                    },
                    .@"--trim-newline", .@"-n" => {
                        self.trim_newline = true;
                    },
                    .@"--type", .@"-t" => {
                        if (args.next()) |flag_arg| {
                            self.type = flag_arg;
                        } else {
                            log.err("the argument '--type <MIME/TYPE>' requires a value but none was supplied\n\n", .{});
                            std.debug.print("Usage: wl-copy [OPTIONS] [TEXT TO COPY]...\n\n", .{});
                            std.debug.print("For more information, try '--help'.\n", .{});
                            process.exit(2);
                        }
                    },
                    .@"--seat", .@"-s" => {
                        if (args.next()) |flag_arg| {
                            self.seat = flag_arg;
                        } else {
                            log.err("the argument '--seat <SEAT>' requires a value but none was supplied\n\n", .{});
                            std.debug.print("Usage: wl-copy [OPTIONS] [TEXT TO COPY]...\n\n", .{});
                            std.debug.print("For more information, try '--help'.\n", .{});
                            process.exit(2);
                        }
                    },
                    .@"--regular", .@"-r" => {
                        self.regular = true;
                    },
                    .@"--backend", .@"-b" => {
                        if (args.next()) |flag_arg| {
                            self.backend = meta.stringToEnum(wlcb.Backend, flag_arg) orelse {
                                log.err("invalid value '{s}' for '--backend <BACKEND>'\n", .{flag_arg});
                                std.debug.print("  [possible values: ", .{});
                                inline for (meta.fields(wlcb.Backend), 0..) |field, i| {
                                    std.debug.print("{s}", .{field.name});
                                    if (i != meta.fields(wlcb.Backend).len - 1) {
                                        std.debug.print(", ", .{});
                                    }
                                }
                                std.debug.print("]\n\n", .{});
                                std.debug.print("Usage: wl-copy [OPTIONS] [TEXT TO COPY]...\n\n", .{});
                                std.debug.print("For more information, try '--help'.\n", .{});
                                process.exit(2);
                            };
                        } else {
                            log.err("the argument '--backend <BACKEND>' requires a value but none was supplied\n\n", .{});
                            std.debug.print("Usage: wl-copy [OPTIONS] [TEXT TO COPY]...\n\n", .{});
                            std.debug.print("For more information, try '--help'.\n", .{});
                            process.exit(2);
                        }
                    },
                }
            } else {
                try list.appendSlice(gpa, arg);
                try list.append(gpa, 32);
            }
        }

        if (list.items.len > 0) {
            self.data = try list.toOwnedSlice(gpa);
        }

        if (self.backend == null) {
            if (posix.getenv("WL_CLIPBOARD_BACKEND")) |backend| {
                self.backend = meta.stringToEnum(wlcb.Backend, backend);
            }
        }

        return self;
    }

    fn deinit(self: Self, gpa: mem.Allocator) void {
        if (self.data) |data| {
            gpa.free(data);
        }
    }
};

const help_message =
    \\Usage: wl-copy [OPTIONS] [TEXT TO COPY]...
    \\
    \\Arguments:
    \\  [TEXT TO COPY]...
    \\          Text to copy
    \\
    \\          If not specified, wl-copy will use data from the standard input
    \\
    \\Options:
    \\  -o, --paste-once
    \\          Serve only a single paste request and then exit
    \\
    \\          This option effectively clears the clipboard after the first paste. It can be used when copying e.g. sensitive data, like passwords. Note however that certain apps may have issues pasting when this option is used, in particular XWayland clients are known to suffer from this
    \\
    \\  -f, --foreground
    \\          Stay in the foreground instead of forking
    \\
    \\  -c, --clear
    \\          Clear the clipboard instead of copying
    \\
    \\  -p, --primary
    \\          Use the "primary" clipboard
    \\
    \\          Copying to the "primary" clipboard requires the compositor to support the data-control protocol of version 2 or above
    \\
    \\  -r, --regular
    \\          Use the regular clipboard
    \\
    \\          Set this flag together with --primary to operate on both clipboards at once. Has no effect otherwise (since the regular clipboard is the default clipboard)
    \\
    \\  -n, --trim-newline
    \\          Trim the trailing newline character before copying
    \\
    \\          This flag is only applied for text MIME types
    \\
    \\  -s, --seat <SEAT>
    \\          Pick the seat to work with
    \\
    \\          By default wl-copy operates on all seats at once
    \\
    \\  -t, --type <MIME/TYPE>
    \\          Override the inferred MIME type for the content
    \\
    \\  -b, --backend <BACKEND>
    \\          Force clipboard backend 
    \\
    \\          [env: WL_CLIPBOARD_BACKEND=]
    \\
    \\  -v, --verbose
    \\          Enable verbose logging
    \\
    \\  -h, --help
    \\          Print help (see a summary with '-h')
    \\
    \\  -V, --version
    \\          Print version
;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    const cli = try Cli.init(alloc);
    verbose_enabled = cli.verbose;
    defer cli.deinit(alloc);

    var stdin_file: fs.File = fs.File.stdin();
    var stdin_tmpfile: ?tmp.TmpFile = null;
    defer if (stdin_tmpfile) |*file| file.deinit(alloc);

    if (cli.data == null and !cli.clear and !cli.foreground) {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin = fs.File.stdin();
        var stdin_reader = stdin.readerStreaming(&stdin_buffer);

        var tmp_buffer: [4098]u8 = undefined;
        var tmpfile = try tmp.TmpFile.init(alloc, .{
            .flags = .{ .read = true, .mode = 0o400 },
        });
        var writer = tmpfile.f.writer(&tmp_buffer);
        var iowriter = &writer.interface;

        _ = try iowriter.sendFileAll(&stdin_reader, .unlimited);
        try iowriter.flush();

        stdin_file = tmpfile.f;
        stdin_tmpfile = tmpfile;
    }

    if (!cli.foreground and !cli.clear) {
        if (fs.openFileAbsolute("/dev/null", .{ .mode = .read_write })) |dev_null| {
            _ = os.linux.dup2(dev_null.handle, posix.STDIN_FILENO);
            _ = os.linux.dup2(dev_null.handle, posix.STDOUT_FILENO);
            dev_null.close();
        } else |_| {
            fs.File.stdout().close();
            fs.File.stdin().close();
        }

        var root = try fs.openDirAbsolute("/", .{});
        defer root.close();
        try root.setAsCwd();

        const sa = posix.Sigaction{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.HUP, &sa, null);

        const pid = try posix.fork();
        if (pid < 0) {
            log.err("fork\n", .{});
        } else if (pid > 0) {
            posix.exit(0);
        }
    }

    var wl_clipboard = try wlcb.WlClipboard.init(alloc, .{
        .force_backend = cli.backend,
        .seat_name = cli.seat,
    });
    defer wl_clipboard.deinit(alloc);

    if (cli.clear) {
        _ = try wl_clipboard.copy(alloc, .{ .bytes = "" }, .{
            .clipboard = if (!cli.regular and cli.primary)
                .primary
            else if ((cli.regular and !cli.primary) or (!cli.regular and !cli.primary))
                .regular
            else
                .both,
            .mime_type = "text/plain",
        });

        return;
    }

    try wl_clipboard.copy(
        alloc,
        if (cli.data) |data|
            .{ .bytes = data }
        else
            .{ .file = stdin_file },
        .{
            .clipboard = if (!cli.regular and cli.primary)
                .primary
            else if ((cli.regular and !cli.primary) or (!cli.regular and !cli.primary))
                .regular
            else
                .both,
            .mime_type = cli.type,
            .paste_once = cli.paste_once,
        },
    );
}
