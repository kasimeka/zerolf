const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const blob = @import("lfs/blob.zig");
const api = @import("lfs/api.zig");
const CacheDir = @import("lfs/CacheDir.zig");

const IO_BUFSIZE = 4 * 1024;

pub fn clean(io: Io, input: *Io.Reader, pointer: *Io.Writer) ![blob.OUT_PATH_LEN]u8 {
    var cache = try CacheDir.init(io, .{});
    defer cache.cleanup(io) catch {}; // FIXME!

    const tmpfile_name = "lfs-blob";
    var tmpfile_buf: [blob.POINTER_BUFSIZE]u8 = undefined;
    var tmpfile = (try cache.dir.createFile(io, tmpfile_name, .{})).writer(io, &tmpfile_buf);

    const oid, const size = pointer_fields: {
        var hasher = Sha256.init(.{});
        var digest: [Sha256.digest_length]u8 = undefined;
        const size = hashed_bytes: {
            var size: blob.Size = 0;
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
    try pointer.print(blob.POINTER_FMT, .{ oid, size });
    try pointer.flush();

    const blob_path = blob.fmtOutPath(oid);

    // FIXME: must climb up to the repo's root, maybe by reading `$GIT_DIR`
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, blob_path[0..blob.OUT_DIR_LEN]);

    // TODO: atomic?
    {
        const blobFile = cwd.openFile(io, &blob_path, .{});
        if (blobFile == error.FileNotFound) {
            try Io.Dir.rename(cache.dir, tmpfile_name, cwd, &blob_path, io);
        } else (try blobFile).close(io);
    }

    return blob_path;
}

const ALLOC_BUFSIZE = 1024 * 1024; // mostly to load and parse ca bundles

pub fn smudge(io: Io, pointer: *Io.Reader, output: *Io.Writer) !void {
    defer output.flush() catch {};

    const oid, const size = blob.parsePointer(pointer) orelse {
        _ = try pointer.streamRemaining(output);
        return;
    };

    var alloc_buf: [ALLOC_BUFSIZE]u8 = undefined;
    var gpa = std.heap.FixedBufferAllocator.init(&alloc_buf);

    var out_buf: [IO_BUFSIZE]u8 = undefined;
    const b = Io.Dir.cwd().openFile(io, &blob.fmtOutPath(oid), .{}) catch |e| switch (e) {
        error.FileNotFound => try api.fetchBlob(io, gpa.allocator(), oid, size),
        else => return e,
    };
    var blobFile = b.reader(io, &out_buf);
    const bytes_written = try blobFile.interface.streamRemaining(output);
    try output.flush();
    if (bytes_written != size) return error.BlobSizeMismatch;
}

test "end to end" {
    const testing = std.testing;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try std.process.setCurrentDir(testing.io, tmpdir.dir);

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

    var pointer_buf: [POINTER.len]u8 = undefined;
    var pointer = Io.Writer.fixed(&pointer_buf);
    var blobFile = Io.Reader.fixed(BLOB);

    const path = try clean(testing.io, &blobFile, &pointer);
    try pointer.flush();

    try testing.expectEqualStrings(PATH, &path);
    try testing.expectEqualStrings(POINTER, &pointer_buf);
    var f = try tmpdir.dir.openFile(testing.io, PATH, .{});
    f.close(testing.io);

    var pointer_2 = Io.Reader.fixed(&pointer_buf);
    var blob_buf: [BLOB.len + 1]u8 = undefined; // FIXME?
    var blob_2 = Io.Writer.fixed(&blob_buf);

    try smudge(testing.io, &pointer_2, &blob_2);
    try blob_2.flush();

    try testing.expectEqualStrings(BLOB, blob_buf[0..BLOB.len]);
}
