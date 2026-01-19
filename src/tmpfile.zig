const std = @import("std");
const mem = std.mem;

const random_bytes_count = 12;
const random_path_len = std.fs.base64_encoder.calcSize(random_bytes_count);

/// return the sys temp dir as string. The return string is owned by user
pub fn getSysTmpDir(gpa: mem.Allocator) ![]const u8 {
    // cpp17's temp_directory_path gives good reference
    // https://en.cppreference.com/w/cpp/filesystem/temp_directory_path
    // POSIX standard, https://en.wikipedia.org/wiki/TMPDIR
    return std.process.getEnvVarOwned(gpa, "TMPDIR") catch {
        return std.process.getEnvVarOwned(gpa, "TMP") catch {
            return std.process.getEnvVarOwned(gpa, "TEMP") catch {
                return std.process.getEnvVarOwned(gpa, "TEMPDIR") catch {
                    std.log.debug("tried env TMPDIR/TMP/TEMP/TEMPDIR but not found, fallback to /tmp, caution it may not work!\n", .{});
                    return try gpa.dupe(u8, "/tmp");
                };
            };
        };
    };
}

/// TmpFile holds the info a new created temp file in sys tmp dir, it can be created by TmpFile.init
pub const TmpFile = struct {
    const TmpFileArgs = struct {
        flags: std.fs.File.CreateFlags = .{ .read = true },
        dir_opts: std.fs.File.CreateFlags = .{},
    };

    abs_path: [:0]const u8,
    /// dir_path is slice of abs_path, and it is abs path
    dir_path: []const u8,
    /// sub_path is slice of abs_path
    sub_path: []const u8,
    f: std.fs.File,

    pub fn deinit(self: *TmpFile, gpa: mem.Allocator) void {
        self.f.close();
        std.fs.deleteFileAbsolute(self.abs_path) catch |err| std.log.warn("Failed to delete tmpfile {s}: {}\n", .{ self.abs_path, err });
        gpa.free(self.abs_path);
    }

    /// return a TmpFile created in sys temp dir.
    pub fn init(gpa: mem.Allocator, args: TmpFileArgs) !TmpFile {
        const sys_tmp_dir_path = try getSysTmpDir(gpa);
        defer gpa.free(sys_tmp_dir_path);
        var sys_tmp_dir = try std.fs.openDirAbsolute(sys_tmp_dir_path, .{});

        var random_bytes: [random_bytes_count]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        var random_path: [random_path_len]u8 = undefined;
        _ = std.fs.base64_encoder.encode(&random_path, &random_bytes);

        const abs_path = brk: {
            var path_buf: std.ArrayList(u8) = .empty;
            defer path_buf.deinit(gpa);

            try path_buf.writer(gpa).print("{s}{c}{s}_{s}", .{
                sys_tmp_dir_path,
                std.fs.path.sep_posix,
                "wl_copy",
                random_path,
            });

            break :brk try path_buf.toOwnedSliceSentinel(gpa, 0);
        };
        const sub_path = abs_path[sys_tmp_dir_path.len + 1 ..]; // +1 for sep
        const dir_path = abs_path[0..sys_tmp_dir_path.len];

        const tmp_file = try sys_tmp_dir.createFile(sub_path, args.flags);

        return .{
            .abs_path = abs_path,
            .dir_path = dir_path,
            .sub_path = sub_path,
            .f = tmp_file,
        };
    }
};
