const std = @import("std");
const Io = std.Io;

const blob = @import("blob.zig");

const IO_BUFSIZE = 4 * 1024;
const ALLOC_BUFSIZE = 1024 * 1024; // mostly to load and parse ca bundles
const REQBODY_BUFSIZE = 256;
const RESBODY_BUFSIZE = 4 * 1024; // upload responses can be larger due to presigned URLs

const Pointer = struct {
    oid: []const u8,
    size: blob.Size,
};

const BatchRequest = struct {
    operation: []const u8 = "download",
    objects: []const Pointer = &[_]Pointer{},
};

const BatchResponseDownload = struct {
    objects: []const struct {
        actions: struct { download: struct { href: []const u8 } },
    },
};

const UploadHeader = struct {
    Authorization: []const u8,
    @"x-amz-content-sha256": []const u8,
    @"x-amz-date": []const u8,
};

const BatchResponseUpload = struct {
    objects: []const struct {
        actions: ?struct {
            upload: struct {
                href: []const u8,
                header: UploadHeader,
            },
        } = null,
    },
};

pub fn fetchBlob(io: Io, allocator: std.mem.Allocator, oid: [blob.HASH_LEN]u8, size: blob.Size) !Io.File {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var response_buf: [RESBODY_BUFSIZE]u8 = undefined;
    var response = Io.Writer.fixed(&response_buf);

    var body_buf: [REQBODY_BUFSIZE]u8 = undefined;
    var body = Io.Writer.fixed(&body_buf);
    var body_json = std.json.Stringify{ .writer = &body };
    try body_json.write(BatchRequest{ .objects = &[_]Pointer{.{ .oid = &oid, .size = size }} });

    _ = try client.fetch(.{
        .method = std.http.Method.POST,
        .location = .{ .uri = comptime try .parse(
            "https://github.com/kasimeka/zerolf.git/info/lfs/objects/batch",
        ) },
        .headers = .{ .content_type = .{ .override = "application/vnd.git-lfs+json" } },
        .payload = body.buffered(),
        .response_writer = &response,
    });

    const response_json = try std.json.parseFromSlice(
        BatchResponseDownload,
        allocator,
        response.buffered(),
        .{ .ignore_unknown_fields = true },
    );
    defer response_json.deinit();

    const blob_path = blob.fmtOutPath(oid);
    try Io.Dir.cwd().createDirPath(io, blob_path[0..blob.OUT_DIR_LEN]);

    var outfile = try Io.Dir.cwd().createFile(
        io,
        &blob_path,
        .{ .truncate = true }, // TODO: don't trucate and refetch blobs!
    );
    errdefer outfile.close(io);

    var out_buf: [IO_BUFSIZE]u8 = undefined;
    var out = outfile.writer(io, &out_buf);

    _ = try client.fetch(.{
        .method = std.http.Method.GET,
        .location = .{ .uri = try .parse(response_json.value.objects[0].actions.download.href) },
        .response_writer = &out.interface,
    });
    try out.interface.flush();

    return outfile;
}

pub fn uploadBlob(io: Io, allocator: std.mem.Allocator, oid: *const [blob.HASH_LEN]u8, size: blob.Size, auth_token: ?[]const u8) !void {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var response_buf: [RESBODY_BUFSIZE]u8 = undefined;
    var response = Io.Writer.fixed(&response_buf);

    var body_buf: [REQBODY_BUFSIZE]u8 = undefined;
    var body = Io.Writer.fixed(&body_buf);
    var body_json = std.json.Stringify{ .writer = &body };
    try body_json.write(BatchRequest{
        .operation = "upload",
        .objects = &[_]Pointer{.{ .oid = oid, .size = size }},
    });

    const fetch_result = try client.fetch(.{
        .method = std.http.Method.POST,
        .location = .{ .uri = comptime try .parse(
            "https://github.com/kasimeka/zerolf.git/info/lfs/objects/batch",
        ) },
        .headers = .{
            .content_type = .{ .override = "application/vnd.git-lfs+json" },
            .authorization = if (auth_token) |token| .{ .override = token } else .default,
        },
        .extra_headers = &.{
            .{ .name = "Accept", .value = "application/vnd.git-lfs+json" },
        },
        .payload = body.buffered(),
        .response_writer = &response,
    });

    if (fetch_result.status != .ok) {
        return error.BatchRequestFailed;
    }

    const response_json = try std.json.parseFromSlice(
        BatchResponseUpload,
        allocator,
        response.buffered(),
        .{ .ignore_unknown_fields = true },
    );
    defer response_json.deinit();

    const upload_action = response_json.value.objects[0].actions orelse return; // already exists

    const blob_path = blob.fmtOutPath(oid.*);
    var infile = try Io.Dir.cwd().openFile(io, &blob_path, .{});
    defer infile.close(io);
    var in_buf: [IO_BUFSIZE]u8 = undefined;
    var input = infile.reader(io, &in_buf);

    const upload_buf = try input.interface.take(@intCast(size));

    const header = upload_action.upload.header;
    _ = try client.fetch(.{
        .method = std.http.Method.PUT,
        .location = .{ .uri = try .parse(upload_action.upload.href) },
        .headers = .{
            .content_type = .{ .override = "application/octet-stream" },
            .authorization = .{ .override = header.Authorization },
        },
        .extra_headers = &.{
            .{ .name = "x-amz-content-sha256", .value = header.@"x-amz-content-sha256" },
            .{ .name = "x-amz-date", .value = header.@"x-amz-date" },
        },
        .payload = upload_buf,
    });
}

test "upload to github" {
    if (true) return; // don't really use this as a test :)

    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const CONTENT = "hysm and mazen\n";
    const OID = "c698018e93b875c0f69916888842b0c79365bad3e6036b90261566018803c293";
    const SIZE = 15;

    const blob_path = blob.fmtOutPath(OID.*);
    try Io.Dir.cwd().createDirPath(io, blob_path[0..blob.OUT_DIR_LEN]);
    var outfile = try Io.Dir.cwd().createFile(io, &blob_path, .{ .truncate = true });
    var out_buf: [IO_BUFSIZE]u8 = undefined;
    var out = outfile.writer(io, &out_buf);
    try out.interface.writeAll(CONTENT);
    try out.interface.flush();
    outfile.close(io);
    defer Io.Dir.cwd().deleteTree(io, ".git") catch {};

    var alloc_buf: [ALLOC_BUFSIZE]u8 = undefined;
    var gpa = std.heap.FixedBufferAllocator.init(&alloc_buf);

    const github_token = std.posix.getenv("GITHUB_TOKEN") orelse // FIXME: nonposix
        return error.MissingGithubToken;
    var auth_buf: [256]u8 = undefined;
    const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{github_token}) catch unreachable;
    try uploadBlob(io, gpa.allocator(), OID, SIZE, auth_header);
}
