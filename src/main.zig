const std = @import("std");
const Io = std.Io;

const lfs = @import("lfs");

const IO_BUFSIZE = 4 * 1024;
const AUTH_BUFSIZE = 256;

pub fn main() !void {
    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var in_buf: [IO_BUFSIZE]u8 = undefined;
    var stdin = Io.File.stdin().reader(io, &in_buf);

    var out_buf: [IO_BUFSIZE]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);

    var args = std.process.args();
    _ = args.next();
    const mode = args.next() orelse std.process.exit(1);
    if (std.mem.eql(u8, mode, "clean"))
        _ = try lfs.clean(io, &stdin.interface, &stdout.interface)
    else if (std.mem.eql(u8, mode, "smudge"))
        _ = try lfs.smudge(io, &stdin.interface, &stdout.interface)
    else if (std.mem.eql(u8, mode, "pre-push")) {
        var auth_buf: [AUTH_BUFSIZE]u8 = undefined;
        try lfs.prepush(io, &stdin.interface, getAuth(&auth_buf) catch null);
    }
}

fn getAuth(token_buf: []u8) ![]u8 {
    const token = std.posix.getenv("GITHUB_TOKEN") orelse return error.EnvVarNotFound;
    return try std.fmt.bufPrint(token_buf, "Bearer {s}", .{token});
}
