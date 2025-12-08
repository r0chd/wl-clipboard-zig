/// a small zig lib for creating and using sys temp files
const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const builtin = @import("builtin");
const testing = std.testing;
const ThisModule = @This();

const random_bytes_count = 12;
const random_path_len = std.fs.base64_encoder.calcSize(random_bytes_count);

/// return the sys temp dir as string. The return string is owned by user
pub fn getSysTmpDir(alloc: mem.Allocator) ![]const u8 {
    // cpp17's temp_directory_path gives good reference
    // https://en.cppreference.com/w/cpp/filesystem/temp_directory_path
    // POSIX standard, https://en.wikipedia.org/wiki/TMPDIR
    return std.process.getEnvVarOwned(alloc, "TMPDIR") catch {
        return std.process.getEnvVarOwned(alloc, "TMP") catch {
            return std.process.getEnvVarOwned(alloc, "TEMP") catch {
                return std.process.getEnvVarOwned(alloc, "TEMPDIR") catch {
                    std.log.debug("tried env TMPDIR/TMP/TEMP/TEMPDIR but not found, fallback to /tmp, caution it may not work!\n", .{});
                    return try alloc.dupe(u8, "/tmp");
                };
            };
        };
    };
}

/// TmpDir holds the info a new created tmp dir in sys temp dir, it can be created by TmpDir.init or module level tmpDir
pub const TmpDir = struct {
    pub const TmpDirArgs = struct {
        prefix: ?[]const u8 = null,
        opts: std.fs.File.CreateFlags = .{},
    };

    abs_path: []const u8,
    // parent_dir_path is slice of abs_path, and it is abs path
    parent_dir_path: []const u8,
    // sub_path is slice of abs_path
    sub_path: []const u8,
    parent_dir: std.fs.Dir,
    dir: std.fs.Dir,

    /// deinit will cleanup the files, close all file handle and then release resources
    pub fn deinit(self: *TmpDir, alloc: mem.Allocator) void {
        self.cleanup();
        alloc.free(self.abs_path);
        self.abs_path = undefined;
        self.parent_dir_path = undefined;
        self.sub_path = undefined;
    }

    /// cleanup will only clean the dir (deleting everything in it), but not release resources
    pub fn cleanup(self: *TmpDir) void {
        self.dir.close();
        self.dir = undefined;
        self.parent_dir.deleteTree(self.sub_path) catch {};
        self.parent_dir.close();
        self.parent_dir = undefined;
    }

    /// return a TmpDir created in system tmp folder
    pub fn init(alloc: mem.Allocator, args: TmpDirArgs) !TmpDir {
        var random_bytes: [ThisModule.random_bytes_count]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        var random_path: [ThisModule.random_path_len]u8 = undefined;
        _ = std.fs.base64_encoder.encode(&random_path, &random_bytes);

        const sys_tmp_dir_path = try getSysTmpDir(alloc);
        defer alloc.free(sys_tmp_dir_path);
        var sys_tmp_dir = try std.fs.openDirAbsolute(sys_tmp_dir_path, .{});

        const abs_path = brk: {
            var path_buf: std.ArrayList(u8) = .empty;
            defer path_buf.deinit(alloc);
            try path_buf.writer(alloc).print("{s}{c}{s}_{s}", .{
                sys_tmp_dir_path,
                std.fs.path.sep_posix,
                if (args.prefix != null) args.prefix.? else "tmpdir",
                random_path,
            });
            break :brk try path_buf.toOwnedSlice(alloc);
        };
        const sub_path = abs_path[sys_tmp_dir_path.len + 1 ..]; // +1 for the sep
        const parent_dir_path = abs_path[0..sys_tmp_dir_path.len];

        const tmp_dir = try sys_tmp_dir.makeOpenPath(sub_path, .{});

        return .{
            .abs_path = abs_path,
            .parent_dir_path = parent_dir_path,
            .sub_path = sub_path,
            .parent_dir = sys_tmp_dir,
            .dir = tmp_dir,
        };
    }
};

/// TmpFile holds the info a new created temp file in sys tmp dir, it can be created by TmpFile.init or module level
/// tmpFile
pub const TmpFile = struct {
    const TmpFileArgs = struct {
        prefix: ?[]const u8 = null,
        dir_prefix: ?[]const u8 = null,
        flags: std.fs.File.CreateFlags = .{ .read = true },
        dir_opts: std.fs.File.CreateFlags = .{},
        dir_args: TmpDir.TmpDirArgs = .{},
    };

    /// the tmp dir contains this file, it can be owned or not owned
    tmp_dir: TmpDir,
    abs_path: [:0]const u8,
    /// dir_path is slice of abs_path, and it is abs path
    dir_path: []const u8,
    /// sub_path is slice of abs_path
    sub_path: []const u8,
    f: std.fs.File,
    fclosed: bool,

    /// caution: this deinit only clears mem resources, will not close file or delete tmp files & tmp_dir
    /// need manually close file, and clean them with tmp_dir
    pub fn deinit(self: *TmpFile, alloc: mem.Allocator) void {
        defer {
            self.tmp_dir.deinit(alloc);
            self.tmp_dir = undefined;
        }
        self.close();
        alloc.free(self.abs_path);
        self.abs_path = undefined;
        self.dir_path = undefined;
        self.sub_path = undefined;
    }

    /// This method only close file handles, will not release the path resources
    pub fn close(self: *TmpFile) void {
        if (!self.fclosed) {
            self.f.close();
            self.f = undefined;
            self.fclosed = true;
        }
    }

    /// return a TmpFile created in tmp dir in sys temp dir. Tmp dir must be provided in args. If do not want to provide
    /// tmp dir and let system auto create, use module level tmpFile
    pub fn init(alloc: mem.Allocator, args: TmpFileArgs) !TmpFile {
        const tmp_dir = try TmpDir.init(alloc, .{ .opts = .{} });

        var random_bytes: [ThisModule.random_bytes_count]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        var random_path: [ThisModule.random_path_len]u8 = undefined;
        _ = std.fs.base64_encoder.encode(&random_path, &random_bytes);

        const abs_path = brk: {
            var path_buf: std.ArrayList(u8) = .empty;
            defer path_buf.deinit(alloc);

            try path_buf.writer(alloc).print("{s}{c}{s}_{s}", .{
                tmp_dir.abs_path,
                std.fs.path.sep_posix,
                if (args.prefix != null) args.prefix.? else "tmp",
                random_path,
            });

            break :brk try path_buf.toOwnedSliceSentinel(alloc, 0);
        };
        const sub_path = abs_path[tmp_dir.abs_path.len + 1 ..]; // +1 for sep
        const dir_path = abs_path[0..tmp_dir.abs_path.len];

        const tmp_file = try tmp_dir.dir.createFile(sub_path, args.flags);

        return .{
            .tmp_dir = tmp_dir,
            .abs_path = abs_path,
            .dir_path = dir_path,
            .sub_path = sub_path,
            .f = tmp_file,
            .fclosed = false,
        };
    }
};
