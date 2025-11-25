const std = @import("std");
const mem = std.mem;
const builtin = @import("builtin");
const helpers = @import("helpers");
const wlcb = @import("wl_clipboard");

const Arguments = enum {
    @"--help",
    @"-h",
    @"--version",
    @"-v",
};

pub fn parseArgs() void {
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
            .@"--version", .@"-v" => {
                std.log.info("Seto v0.1.0 \nBuild type: {any}\nZig {any}\n", .{ builtin.mode, builtin.zig_version });
                std.process.exit(0);
            },
        }
    }
}

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
    _ = alloc;

    const wl_clipboard = try wlcb.WlClipboard.init();
    _ = wl_clipboard;

    parseArgs();
}
