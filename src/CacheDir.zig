const std = @import("std");
const Io = std.Io;
const base64_encoder = std.fs.base64_encoder;

const CacheDir = @This();

const IO_BUFSIZE = 4 * 1024;
const BASENAME = "zerolf-cache";

dir: Io.Dir,
parent_dir: Io.Dir,
sub_path: [sub_path_len]u8,

const random_bytes_count = 12;
const sub_path_len = base64_encoder.calcSize(random_bytes_count);

pub fn cleanup(self: *CacheDir, io: Io) !void {
    self.dir.close(io);
    try self.parent_dir.deleteTree(io, &self.sub_path);
    self.parent_dir.close(io);
    self.* = undefined;
}

pub fn init(io: Io, opts: Io.Dir.OpenOptions) !CacheDir {
    var random_bytes: [CacheDir.random_bytes_count]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    var cache_dir = try Io.Dir.cwd().createDirPathOpen(
        io,
        if (std.process.hasEnvVarConstant("ZEROLF_IS_HOOK"))
            ".git/" ++ BASENAME
        else
            "/tmp/" ++ BASENAME,
        .{},
    );

    var sub_path: [CacheDir.sub_path_len]u8 = undefined;
    _ = base64_encoder.encode(&sub_path, &random_bytes);
    const dir = try cache_dir.createDirPathOpen(io, &sub_path, .{ .open_options = opts });

    return .{
        .dir = dir,
        .parent_dir = cache_dir,
        .sub_path = sub_path,
    };
}
