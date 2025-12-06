const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("helpers");
const wlcb = @import("wl_clipboard");
const mem = std.mem;
const meta = std.meta;
const fs = std.fs;
const posix = std.posix;
const os = std.os;

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

    const Self = @This();

    fn init(alloc: mem.Allocator) !Self {
        var self = Cli{};

        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(alloc);

        var args = std.process.args();
        var index: u8 = 0;
        while (args.next()) |arg| : (index += 1) {
            if (index == 0) continue;

            if (meta.stringToEnum(Arguments, arg)) |argument| {
                switch (argument) {
                    .@"--help", .@"-h" => {
                        std.log.info("{s}\n", .{help_message});
                        std.process.exit(0);
                    },
                    .@"--version", .@"-V" => {
                        std.log.info("wl-copy v0.1.0 \nBuild type: {any}\nZig {any}\n", .{ builtin.mode, builtin.zig_version });
                        std.process.exit(0);
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
                            std.log.err("option requires an argument -- 'type'\n", .{});
                            std.log.info("{s}\n", .{help_message});
                            std.process.exit(0);
                        }
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
                    .@"--regular", .@"-r" => {
                        self.regular = true;
                    },
                }
            } else {
                try list.appendSlice(alloc, arg);
                try list.append(alloc, 32);
            }
        }

        if (list.items.len > 0) {
            self.data = try list.toOwnedSlice(alloc);
        }

        return self;
    }

    fn deinit(self: Self, alloc: std.mem.Allocator) void {
        if (self.data) |data| {
            alloc.free(data);
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
    \\          If not specified, wl-copy will use data from the standard input.  
    \\  
    \\Options:  
    \\  -o, --paste-once  
    \\          Serve only a single paste request and then exit  
    \\  
    \\          This option effectively clears the clipboard after the first paste. It can be used when copying e.g. sensitive data, like  
    \\          passwords. Note however that certain apps may have issues pasting when this option is used, in particular XWayland clients  
    \\          are known to suffer from this.  
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
    \\          Copying to the "primary" clipboard requires the compositor to support the data-control protocol of version 2 or above.  
    \\  
    \\  -r, --regular  
    \\          Use the regular clipboard  
    \\  
    \\          Set this flag together with --primary to operate on both clipboards at once. Has no effect otherwise (since the regular  
    \\          clipboard is the default clipboard).  
    \\  
    \\  -n, --trim-newline  
    \\          Trim the trailing newline character before copying  
    \\  
    \\          This flag is only applied for text MIME types.  
    \\  
    \\  -s, --seat <SEAT>  
    \\          Pick the seat to work with  
    \\  
    \\          By default wl-copy operates on all seats at once.  
    \\  
    \\  -t, --type <MIME/TYPE>  
    \\          Override the inferred MIME type for the content  
    \\  
    \\  -v, --verbose...  
    \\          Enable verbose logging  
    \\  
    \\  -h, --help  
    \\          Print help (see a summary with '-h')  
    \\  
    \\  -V, --version  
    \\          Print version  
;

pub fn main() !void {
    var dbg_gpa = if (@import("builtin").mode == .Debug) std.heap.GeneralPurposeAllocator(.{}){} else {};
    defer if (@TypeOf(dbg_gpa) != void) {
        _ = dbg_gpa.deinit();
    };
    const alloc = if (@TypeOf(dbg_gpa) != void) dbg_gpa.allocator() else std.heap.page_allocator;

    const cli = try Cli.init(alloc);
    verbose_enabled = cli.verbose;
    defer cli.deinit(alloc);

    var stdin_data: ?[]u8 = null;
    defer if (stdin_data) |data| alloc.free(data);

    const source: wlcb.Source = if (cli.data) |data|
        wlcb.Source{ .bytes = data }
    else blk: {
        var stdin = std.fs.File.stdin();
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(alloc);

        var buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = try stdin.read(&buffer);
            if (bytes_read == 0) break;
            try list.appendSlice(alloc, buffer[0..bytes_read]);
        }

        stdin_data = try list.toOwnedSlice(alloc);
        break :blk wlcb.Source{ .bytes = stdin_data.? };
    };

    var wl_clipboard = try wlcb.WlClipboard.init(alloc, .{});
    defer wl_clipboard.deinit(alloc);

    var close_channel = try wl_clipboard.copy(alloc, source, .{
        .clipboard = if (!cli.regular and cli.primary)
            .primary
        else if ((cli.regular and !cli.primary) or (!cli.regular and !cli.primary))
            .regular
        else
            .both,
        .mime_type = cli.type,
    });
    defer close_channel.deinit(alloc);

    if (!cli.foreground) {
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

        const sa = std.posix.Sigaction{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.HUP, &sa, null);

        const pid = try posix.fork();
        if (pid < 0) {
            std.log.err("fork\n", .{});
        } else if (pid > 0) {
            posix.exit(0);
        }

        wl_clipboard.display.disconnect();
        // GPA is not fork-safe
        wl_clipboard = try wlcb.WlClipboard.init(std.heap.page_allocator, .{});
        try wl_clipboard.copyToContext(close_channel.copy_context, .{});

        try close_channel.startDispatch();
        close_channel.cancelAwait();

        // Exit without running defers (they'd free with wrong allocator)
        posix.exit(0);
    }

    try close_channel.startDispatch();

    close_channel.cancelAwait();
}
