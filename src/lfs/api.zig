const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = std.json;

const blob = @import("blob.zig");

const IO_BUFSIZE = 4 * 1024;
const REQBODY_BUFSIZE = 256;
const RESBODY_BUFSIZE = 4 * REQBODY_BUFSIZE;
const ALLOC_BUFSIZE = 1024 * 1024; // mainly used to parse system ca bundle

const CONTENT_TYPE = "application/vnd.git-lfs+json";
const BATCH_URL = std.Uri.parse("https://github.com/kasimeka/zerolf.git/info/lfs/objects/batch") catch unreachable;

const Pointer = struct { oid: []const u8, size: blob.Size };

const DownloadResponse = struct {
    objects: []const struct {
        actions: ?struct { download: struct { href: []const u8 } } = null,
    },
};

const UploadResponse = struct {
    objects: []const struct {
        actions: ?struct { upload: UploadAction, verify: ?UploadAction = null } = null,
    },
};
const UploadAction = struct { href: []const u8, header: struct {
    Authorization: []const u8,
    @"x-amz-content-sha256": ?[]const u8 = null,
    @"x-amz-date": ?[]const u8 = null,
    Accept: ?[]const u8 = null,
} };

pub fn download(client: *http.Client, cwd: Io.Dir, oid: [blob.HASH_LEN]u8, size: blob.Size) !Io.File {
    var res_buf: [RESBODY_BUFSIZE]u8 = undefined;
    var res = Io.Writer.fixed(&res_buf);

    _ = try client.fetch(.{
        .method = .POST,
        .location = .{ .uri = BATCH_URL },
        .headers = .{ .content_type = .{ .override = CONTENT_TYPE } },
        .extra_headers = &.{.{ .name = "Accept", .value = CONTENT_TYPE }},
        .payload = try batchRequestBody(&oid, size, "download"),
        .response_writer = &res,
    });

    const parsed = try json.parseFromSlice(
        DownloadResponse,
        client.allocator,
        res.buffered(),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const href =
        (parsed.value.objects[0].actions orelse return error.ObjectNotFound)
            .download.href;
    return fetchToCache(client, cwd, href, oid);
}

pub fn upload(
    client: *http.Client,
    oid: *const [blob.HASH_LEN]u8,
    size: blob.Size,
    auth: ?[]const u8,
) !void {
    var res_buf: [RESBODY_BUFSIZE]u8 = undefined;
    var res = Io.Writer.fixed(&res_buf);

    const result = try client.fetch(.{
        .method = .POST,
        .location = .{ .uri = BATCH_URL },
        .headers = .{
            .content_type = .{ .override = CONTENT_TYPE },
            .authorization = if (auth) |a| .{ .override = a } else .default,
        },
        .extra_headers = &.{.{ .name = "Accept", .value = CONTENT_TYPE }},
        .payload = try batchRequestBody(oid, size, "upload"),
        .response_writer = &res,
    });
    if (result.status != .ok) return error.BatchRequestFailed;

    const parsed = try json.parseFromSlice(
        UploadResponse,
        client.allocator,
        res.buffered(),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const actions = parsed.value.objects[0].actions orelse return;
    try putObject(client, oid, size, actions.upload);
    if (actions.verify) |v| try verifyObject(client, oid, size, v);
}

fn fetchToCache(
    client: *http.Client,
    cwd: Io.Dir,
    url: []const u8,
    oid: [blob.HASH_LEN]u8,
) !Io.File {
    const io = client.io;
    const path = blob.fmtOutPath(oid);
    try Io.Dir.cwd().createDirPath(io, path[0..blob.OUT_DIR_LEN]);

    var file = try cwd.createFile(io, &path, .{ .truncate = true });
    defer file.close(io);
    var buf: [IO_BUFSIZE]u8 = undefined;
    var w = file.writer(io, &buf);

    _ = try client.fetch(.{
        .method = .GET,
        .location = .{ .uri = try .parse(url) },
        .response_writer = &w.interface,
    });
    try w.interface.flush();

    return cwd.openFile(io, &path, .{});
}

fn putObject(
    client: *http.Client,
    oid: *const [blob.HASH_LEN]u8,
    size: blob.Size,
    action: UploadAction,
) !void {
    const io = client.io;
    const path = blob.fmtOutPath(oid.*);

    var file = try Io.Dir.cwd().openFile(io, &path, .{});
    defer file.close(io);
    var buf: [IO_BUFSIZE]u8 = undefined;
    var r = file.reader(io, &buf);

    var extra_headers_buf: [2]std.http.Header = undefined;
    var extra_header_count: usize = 0;
    if (action.header.@"x-amz-content-sha256") |v| {
        extra_headers_buf[extra_header_count] = .{ .name = "x-amz-content-sha256", .value = v };
        extra_header_count += 1;
    }
    if (action.header.@"x-amz-date") |v| {
        extra_headers_buf[extra_header_count] = .{ .name = "x-amz-date", .value = v };
        extra_header_count += 1;
    }

    const result = try client.fetch(.{
        .method = .PUT,
        .location = .{ .uri = try .parse(action.href) },
        .headers = .{
            .content_type = .{ .override = "application/octet-stream" },
            .authorization = .{ .override = action.header.Authorization },
        },
        .extra_headers = extra_headers_buf[0..extra_header_count],
        .payload = try r.interface.take(@intCast(size)),
    });
    if (result.status != .ok) return error.UploadFailed;
}

fn verifyObject(
    client: *http.Client,
    oid: *const [blob.HASH_LEN]u8,
    size: blob.Size,
    action: UploadAction,
) !void {
    var buf: [REQBODY_BUFSIZE]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    var jw = json.Stringify{ .writer = &w };
    try jw.write(Pointer{ .oid = oid, .size = size });

    const result = try client.fetch(.{
        .method = .POST,
        .location = .{ .uri = try .parse(action.href) },
        .headers = .{
            .content_type = .{ .override = CONTENT_TYPE },
            .authorization = .{ .override = action.header.Authorization },
        },
        .extra_headers = &.{.{ .name = "Accept", .value = action.header.Accept orelse CONTENT_TYPE }},
        .payload = w.buffered(),
    });
    if (result.status != .ok) return error.VerifyFailed;
}

fn batchRequestBody(oid: []const u8, size: blob.Size, op: []const u8) ![]const u8 {
    var buf: [REQBODY_BUFSIZE]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    var jw = json.Stringify{ .writer = &w };
    try jw.write(.{
        .operation = op,
        .objects = &[_]Pointer{.{ .oid = oid, .size = size }},
    });
    return w.buffered();
}

test "upload to github" {
    if (true) return; // manual test only

    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const OID = "c698018e93b875c0f69916888842b0c79365bad3e6036b90261566018803c293";
    const SIZE = 15;
    const CONTENT = "hysm and mazen\n";

    try Io.Dir.cwd().createDirPath(io, ".playground/.git/lfs/objects/c6/98");
    defer Io.Dir.cwd().deleteTree(io, ".playground/.git") catch {};

    var outfile = try Io.Dir.cwd().createFile(
        io,
        ".playground/" ++ blob.fmtOutPath(OID.*),
        .{ .truncate = true },
    );
    var out_buf: [CONTENT.len]u8 = undefined;
    var out = outfile.writer(io, &out_buf);
    try out.interface.writeAll(CONTENT);
    try out.interface.flush();
    outfile.close(io);

    var alloc_buf: [ALLOC_BUFSIZE]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);
    var client = http.Client{ .allocator = fba.allocator(), .io = io };
    defer client.deinit();

    var auth_buf: [REQBODY_BUFSIZE]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{std.posix.getenv("GITHUB_TOKEN") orelse return error.MissingGithubToken}) catch unreachable; // FIXME: nonposix
    try upload(&client, OID, SIZE, auth);
}
