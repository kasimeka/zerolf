const std = @import("std");
const Io = std.Io;

const TempDir = @This();

dir: Io.Dir,
parent_dir: Io.Dir,
sub_path: [sub_path_len]u8,

const random_bytes_count = 12;
const sub_path_len = std.fs.base64_encoder.calcSize(random_bytes_count);

pub fn cleanup(self: *TempDir, io: Io) void {
    self.dir.close(io);
    self.parent_dir.deleteTree(io, &self.sub_path) catch {};
    self.parent_dir.close(io);
    self.* = undefined;
}

pub fn init(io: Io, opts: Io.Dir.OpenOptions) TempDir {
    var random_bytes: [TempDir.random_bytes_count]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var sub_path: [TempDir.sub_path_len]u8 = undefined;
    _ = std.fs.base64_encoder.encode(&sub_path, &random_bytes);

    var cache_dir = Io.Dir.cwd().createDirPathOpen(io, ".zig-cache", .{}) catch
        @panic("unable to make temp dir: unable to make and open .zig-cache dir");
    defer cache_dir.close(io);
    const parent_dir = cache_dir.createDirPathOpen(io, "temp", .{}) catch
        @panic("unable to make temp dir: unable to make and open .zig-cache/temp dir");
    const dir = parent_dir.createDirPathOpen(io, &sub_path, .{ .open_options = opts }) catch
        @panic("unable to make temp dir for testing: unable to make and open the temp dir");

    return .{
        .dir = dir,
        .parent_dir = parent_dir,
        .sub_path = sub_path,
    };
}
