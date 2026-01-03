const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const CacheDir = @import("CacheDir.zig");

const blob = @This();

const IO_BUFSIZE = 4 * 1024;

const LFS_DIR = ".git/lfs/objects";
const POINTER_PREFIX = "version https://git-lfs.github.com/spec/v1\noid sha256:";
pub const POINTER_FMT = POINTER_PREFIX ++ "{s}\nsize {d}\n";

pub const POINTER_BUFSIZE = POINTER_FMT.len + HASH_LEN; // it's actually 1024 in spec, we're much lower

const HASH_LEN = Sha256.digest_length * 2; // hex representation doubles the size
pub const OUT_DIR_LEN = (LFS_DIR ++ "/xx/yy/").len;
pub const OUT_PATH_LEN = OUT_DIR_LEN + HASH_LEN;

pub const Size = u128;

pub fn parsePointer(pointer: *Io.Reader) ?struct { [HASH_LEN]u8, Size } {
    const peek = pointer.take(POINTER_PREFIX.len + HASH_LEN) catch return null;
    const prefix = peek[0..POINTER_PREFIX.len];

    var oid: [HASH_LEN]u8 = undefined;
    @memcpy(&oid, peek[POINTER_PREFIX.len..]);

    if (!std.mem.eql(u8, prefix, POINTER_PREFIX)) return null;
    for (oid) |c| if (!std.ascii.isHex(c)) return null;

    pointer.toss(1);
    const size_str = pointer.takeDelimiterExclusive('\n') catch return null;
    pointer.toss(1);
    const SIZE_LEN = "size ".len;
    if (size_str.len <= SIZE_LEN) return null;
    if (!std.mem.eql(u8, size_str[0.."size ".len], "size ")) return null;
    const size = std.fmt.parseInt(Size, size_str["size ".len..], 10) catch return null;

    return .{ oid, size };
}

pub fn fmtOutPath(oid: [HASH_LEN]u8) [OUT_PATH_LEN]u8 {
    var outpath: [OUT_PATH_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(
        &outpath,
        "{s}/{s}/{s}/{s}",
        .{ LFS_DIR, oid[0..2], oid[2..4], oid },
    ) catch unreachable;
    return outpath;
}
