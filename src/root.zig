const std = @import("std");
const TempDir = @import("TempDir");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const IO_BUFSIZE = 4 * 1024;

const LFS_DIR = ".git/lfs/objects";
const POINTER_PREFIX = "version https://git-lfs.github.com/spec/v1\noid sha256:";
const POINTER_FMT = POINTER_PREFIX ++ "{s}\nsize {d}\n";

const POINTER_BUFSIZE = POINTER_FMT.len + BLOB_HASH_LEN; // it's actually 1024 in spec, we're much lower

const OUT_DIR_LEN = (LFS_DIR ++ "/xx/yy/").len;
const BLOB_HASH_LEN = Sha256.digest_length * 2; // hex representation doubles the size
const BLOB_PATH_LEN = OUT_DIR_LEN + BLOB_HASH_LEN;

const Size = u128;
pub fn clean(io: Io, input: *Io.Reader, pointer: *Io.Writer) ![BLOB_PATH_LEN]u8 {
    var tempdir = TempDir.init(io, .{});
    defer tempdir.cleanup(io);

    const tmpfile_name = "lfs-blob";
    var tmpfile_buf: [POINTER_BUFSIZE]u8 = undefined;
    var tmpfile = (try tempdir.dir.createFile(io, tmpfile_name, .{})).writer(io, &tmpfile_buf);

    const oid, const size = pointer_fields: {
        var hasher = Sha256.init(.{});
        var digest: [Sha256.digest_length]u8 = undefined;
        const size = hashed_bytes: {
            var size: Size = 0;
            var c: u8 = undefined;
            while (true) {
                c =
                    input.takeByte() catch |e|
                        if (e == error.EndOfStream) break else return e;
                hasher.update(@ptrCast(&c));
                try tmpfile.interface.writeByte(c);
                size += 1;
            }
            break :hashed_bytes size;
        };
        hasher.final(&digest);
        const hexdigest = std.fmt.bytesToHex(digest, .lower);

        try tmpfile.interface.flush();

        break :pointer_fields .{ hexdigest, size };
    };
    try pointer.print(POINTER_FMT, .{ oid, size });
    try pointer.flush();

    const blob_path = fmtBlobPath(oid);

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, blob_path[0..OUT_DIR_LEN]);

    const blob = cwd.openFile(io, &blob_path, .{});
    if (blob == error.FileNotFound) {
        try Io.Dir.rename(tempdir.dir, tmpfile_name, cwd, &blob_path, io);
    } else (try blob).close(io);

    return blob_path;
}

pub fn smudge(io: Io, pointer: *Io.Reader, output: *Io.Writer) !void {
    defer output.flush() catch {};

    const oid, const size = parsePointer(pointer) orelse {
        _ = try pointer.streamRemaining(output);
        return;
    };

    var out_buf: [IO_BUFSIZE]u8 = undefined;
    const b = try Io.Dir.cwd().openFile(io, &fmtBlobPath(oid), .{});
    var blob = b.reader(io, &out_buf);
    const bytes_written = try blob.interface.streamRemaining(output);
    try output.flush();
    if (bytes_written != size) return error.BlobSizeMismatch;
}

fn parsePointer(pointer: *Io.Reader) ?struct { [BLOB_HASH_LEN]u8, Size } {
    const peek = pointer.take(POINTER_PREFIX.len + BLOB_HASH_LEN) catch return null;
    const prefix = peek[0..POINTER_PREFIX.len];

    var oid: [BLOB_HASH_LEN]u8 = undefined;
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
fn fmtBlobPath(oid: [BLOB_HASH_LEN]u8) [BLOB_PATH_LEN]u8 {
    var outpath: [BLOB_PATH_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(
        &outpath,
        "{s}/{s}/{s}/{s}",
        .{ LFS_DIR, oid[0..2], oid[2..4], oid },
    ) catch unreachable;
    return outpath;
}

test "end to end" {
    const testing = std.testing;

    const BLOB =
        \\hysm and mazen
        \\
    ;
    const POINTER =
        \\version https://git-lfs.github.com/spec/v1
        \\oid sha256:c698018e93b875c0f69916888842b0c79365bad3e6036b90261566018803c293
        \\size 15
        \\
    ;
    const PATH = ".git/lfs/objects/c6/98/c698018e93b875c0f69916888842b0c79365bad3e6036b90261566018803c293";

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try std.process.setCurrentDir(testing.io, tmpdir.dir);

    var pointer_buf: [POINTER.len]u8 = undefined;
    var pointer = Io.Writer.fixed(&pointer_buf);
    var blob = Io.Reader.fixed(BLOB);

    const path = try clean(testing.io, &blob, &pointer);
    try pointer.flush();

    try testing.expectEqualStrings(PATH, &path);
    try testing.expectEqualStrings(POINTER, &pointer_buf);
    var f = try tmpdir.dir.openFile(testing.io, PATH, .{});
    f.close(testing.io);

    var pointer_2 = Io.Reader.fixed(&pointer_buf);
    var blob_buf: [BLOB.len + 1]u8 = undefined;
    var blob_2 = Io.Writer.fixed(&blob_buf);

    try smudge(testing.io, &pointer_2, &blob_2);
    try blob_2.flush();

    try testing.expectEqualStrings(BLOB, blob_buf[0..BLOB.len]);
}
