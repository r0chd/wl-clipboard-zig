const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const builtin = @import("builtin");
const helpers = @import("helpers");
const wlcb = @import("wl_clipboard");

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
    data: []u8,

    const Self = @This();

    fn init(alloc: mem.Allocator) !Self {
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
                        @panic("TODO");
                    },

                    .@"--paste-once", .@"-o" => {
                        @panic("TODO");
                    },
                    .@"--foreground", .@"-f" => {
                        @panic("TODO");
                    },
                    .@"--clear", .@"-c" => {
                        @panic("TODO");
                    },
                    .@"--primary", .@"-p" => {
                        @panic("TODO");
                    },
                    .@"--trim-newline", .@"-n" => {
                        @panic("TODO");
                    },
                    .@"--type", .@"-t" => {
                        @panic("TODO");
                    },
                    .@"--seat", .@"-s" => {
                        @panic("TODO");
                    },
                    .@"--regular", .@"-r" => {
                        @panic("TODO");
                    },
                }
            } else {
                try list.appendSlice(alloc, arg);
                try list.append(alloc, 32);
            }
        }

        if (list.items.len == 0) {
            const stdin = std.fs.File.stdin();
            var reader = stdin.reader(list.items);
            const data = try reader.interface.allocRemaining(alloc, .unlimited);
            defer alloc.free(data);

            try list.appendSlice(alloc, data);
        }

        return Cli{
            .data = try list.toOwnedSlice(alloc),
        };
    }

    fn deinit(self: Self, alloc: std.mem.Allocator) void {
        alloc.free(self.data);
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
    const alloc = if (@TypeOf(dbg_gpa) != void) dbg_gpa.allocator() else std.heap.c_allocator;

    const cli = try Cli.init(alloc);
    defer cli.deinit(alloc);

    const wl_clipboard = try wlcb.WlClipboard.init();
    _ = wl_clipboard;

    std.debug.print("{s}", .{cli.data});
}
