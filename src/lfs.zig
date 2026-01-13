const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const blob = @import("lfs/blob.zig");
const api = @import("lfs/api.zig");
const CacheDir = @import("lfs/CacheDir.zig");

const IO_BUFSIZE = 4 * 1024;
const HTTP_BUFSIZE = 1024 * 1024; // mostly to load and parse ca bundles
const MAX_GIT_REV_LIST_ARGS = 4; // git rev-list --objects <sha-or-range>
const GIT_SHA_RANGE_BUFSIZE = 40 + 2 + 40; // <sha>..<sha>
const GIT_SHA_HEX_LEN = 40;
const GIT_REV_LIST_LINE_BUFSIZE = 256; // <sha> <path>

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

pub fn smudge(io: Io, pointer: *Io.Reader, output: *Io.Writer) !void {
    defer output.flush() catch {};

    const oid, const size = blob.parsePointer(pointer) orelse {
        _ = try pointer.streamRemaining(output);
        return;
    };

    var alloc_buf: [HTTP_BUFSIZE]u8 = undefined;
    var gpa = std.heap.FixedBufferAllocator.init(&alloc_buf);

    var client = std.http.Client{ .allocator = gpa.allocator(), .io = io };
    defer client.deinit();

    var out_buf: [IO_BUFSIZE]u8 = undefined;
    const cwd = Io.Dir.cwd();
    const blobFile = cwd.openFile(io, &blob.fmtOutPath(oid), .{}) catch |e| switch (e) {
        error.FileNotFound => try api.download(&client, cwd, oid, size),
        else => return e,
    };
    defer blobFile.close(io);
    var blobReader = blobFile.reader(io, &out_buf);

    // manual copy loop - sendfile doesn't work with stdout on macos
    var bytes_written: blob.Size = 0;
    while (bytes_written < size) {
        const to_read: usize = @min(IO_BUFSIZE, size - bytes_written);
        const chunk = blobReader.interface.take(to_read) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        try output.writeAll(chunk);
        bytes_written += chunk.len;
    }
    try output.flush();
}

pub fn prepush(io: Io, input: *Io.Reader, auth: ?[]const u8) !void {
    var alloc_buf: [2 * HTTP_BUFSIZE]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);

    // Read refs from stdin: <local-ref> <local-sha> <remote-ref> <remote-sha>
    while (true) {
        const line = input.takeDelimiterExclusive('\n') catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (line.len == 0) break;

        var it = std.mem.splitScalar(u8, line, ' ');
        _ = it.next(); // local ref
        const local_sha = it.next() orelse continue;
        _ = it.next(); // remote ref
        const remote_sha = it.next() orelse continue;

        // Find LFS pointers in commits being pushed
        try uploadLfsObjects(io, fba.allocator(), local_sha, remote_sha, auth);
    }
}

fn uploadLfsObjects(
    io: Io,
    allocator: std.mem.Allocator,
    local_sha: []const u8,
    remote_sha: []const u8,
    auth: ?[]const u8,
) !void {
    // For new branches (remote_sha is all zeros), list all objects
    // Otherwise, list objects in the range remote_sha..local_sha
    const is_new_branch = std.mem.allEqual(u8, remote_sha, '0');

    var rev_list_args: [MAX_GIT_REV_LIST_ARGS][]const u8 = undefined;
    var arg_count: usize = 0;

    rev_list_args[arg_count] = "git";
    arg_count += 1;
    rev_list_args[arg_count] = "rev-list";
    arg_count += 1;
    rev_list_args[arg_count] = "--objects";
    arg_count += 1;

    if (is_new_branch) {
        rev_list_args[arg_count] = local_sha;
        arg_count += 1;
    } else {
        var range_buf: [GIT_SHA_RANGE_BUFSIZE]u8 = undefined;
        const range = std.fmt.bufPrint(&range_buf, "{s}..{s}", .{ remote_sha, local_sha }) catch return;
        rev_list_args[arg_count] = range;
        arg_count += 1;
    }

    var child = std.process.Child.init(rev_list_args[0..arg_count], allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn(io);

    var stdout_buf: [IO_BUFSIZE]u8 = undefined;
    var reader = child.stdout.?.reader(io, &stdout_buf);

    // Process each line from git rev-list output
    var line_buf: [GIT_REV_LIST_LINE_BUFSIZE]u8 = undefined;
    var line_len: usize = 0;

    while (true) {
        const byte = reader.interface.takeByte() catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };

        if (byte == '\n') {
            const obj_line = line_buf[0..line_len];
            line_len = 0;

            if (obj_line.len == 0) continue;

            // Lines with paths: "<sha> <path>" (blobs)
            // Lines without paths: "<sha>" (commits/trees) - skip these
            var obj_it = std.mem.splitScalar(u8, obj_line, ' ');
            const obj_sha = obj_it.next() orelse continue;
            const path = obj_it.next() orelse continue;

            if (path.len == 0) continue; // Skip tree objects (empty path)

            // Copy obj_sha to stable memory before reset
            var sha_buf: [GIT_SHA_HEX_LEN]u8 = undefined;
            @memcpy(sha_buf[0..obj_sha.len], obj_sha);

            try checkAndUploadBlob(io, allocator, sha_buf[0..obj_sha.len], auth);
        } else {
            if (line_len < line_buf.len) {
                line_buf[line_len] = byte;
                line_len += 1;
            }
        }
    }

    _ = try child.wait(io);
}

fn checkAndUploadBlob(
    io: Io,
    allocator: std.mem.Allocator,
    obj_sha: []const u8,
    auth: ?[]const u8,
) !void {
    var child = std.process.Child.init(&.{ "git", "cat-file", "blob", obj_sha }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn(io);

    var stdout_buf: [blob.POINTER_BUFSIZE]u8 = undefined;
    var stdout = child.stdout.?.reader(io, &stdout_buf);

    // Try to parse as LFS pointer
    if (blob.parsePointer(&stdout.interface)) |parsed| {
        const oid, const size = parsed;

        // Check if object exists locally before uploading
        const blob_path = blob.fmtOutPath(oid);
        const cwd = Io.Dir.cwd();
        const file = cwd.openFile(io, &blob_path, .{}) catch |e| switch (e) {
            error.FileNotFound => {
                _ = try child.wait(io);
                return;
            },
            else => return e,
        };
        file.close(io);

        var client = std.http.Client{ .allocator = allocator, .io = io };
        defer client.deinit();

        try api.upload(&client, &oid, size, auth);
    }

    _ = try child.wait(io);
}

test "end to end" {
    const testing = std.testing;

    const orig_cwd = Io.Dir.cwd();
    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    defer std.process.setCurrentDir(testing.io, orig_cwd) catch {};
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
