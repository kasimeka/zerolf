const std = @import("std");
const Io = std.Io;

const lfs = @import("lfs");

const IO_BUFSIZE = 4 * 1024;
pub fn main() !void {
    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var in_buf: [IO_BUFSIZE]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(io, &in_buf);

    var out_buf: [IO_BUFSIZE]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&out_buf);

    var args = std.process.args();
    _ = args.next();
    const mode = args.next() orelse std.process.exit(1);
    if (std.mem.eql(u8, mode, "clean"))
        _ = try lfs.clean(&stdin.interface, &stdout.interface)
    else if (std.mem.eql(u8, mode, "smudge"))
        _ = try lfs.smudge(io, &stdin.interface, &stdout.interface);
}
