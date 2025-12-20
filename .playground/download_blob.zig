const std = @import("std");

const Pointer = struct {
    version: []const u8 = "https://git-lfs.github.com/spec/v1",
    oid: []const u8,
};
const BatchRequest = struct {
    operation: []const u8 = "download",
    objects: []const Pointer = &[_]Pointer{},
};
const BatchResponse = struct {
    objects: []const struct {
        actions: struct { download: struct { href: []const u8 } },
    },
};

const IO_BUFSIZE = 4 * 1024;
const ALLOC_BUFSIZE = 15 * 1024 * 1024;
const REQBODY_BUFSIZE = 256;
const RESBODY_BUFSIZE = 4 * REQBODY_BUFSIZE;

const OID = "7a74de3317b04a679ae706064a4c72b217e8fff1047516d0202bb60aff512de8";
pub fn main() !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var alloc_buf: [ALLOC_BUFSIZE]u8 = undefined;
    var gpa = std.heap.FixedBufferAllocator.init(&alloc_buf);
    const allocator = gpa.allocator();

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var request_buf: [RESBODY_BUFSIZE]u8 = undefined;
    var response = std.Io.Writer.fixed(&request_buf);

    var body_buf: [REQBODY_BUFSIZE]u8 = undefined;
    var body = std.Io.Writer.fixed(&body_buf);
    var body_json = std.json.Stringify{ .writer = &body };
    try body_json.write(BatchRequest{ .objects = &[_]Pointer{.{ .oid = OID }} });

    const fetch_result = try client.fetch(.{
        .method = std.http.Method.POST,
        .location = .{ .uri = comptime try .parse(
            "https://gitlab.com/balatro-mod-index/repo.git/info/lfs/objects/batch",
        ) },
        .headers = .{ .content_type = .{ .override = "application/vnd.git-lfs+json" } },
        .payload = body.buffered(),
        .response_writer = &response,
    });
    try body.flush();
    const response_json = try std.json.parseFromSlice(
        BatchResponse,
        allocator,
        response.buffered(),
        .{ .ignore_unknown_fields = true },
    );
    defer response_json.deinit();

    std.debug.print("status: {d}\ndownload href: {s}\n", .{
        fetch_result.status,
        response_json.value.objects[0].actions.download.href,
    });

    var out_buf: [IO_BUFSIZE]u8 = undefined;
    var outfile = try std.fs.cwd().createFile(OID, .{ .truncate = true });
    var out = outfile.writer(&out_buf);

    var blob = std.Io.Writer.Allocating.init(allocator);
    _ = try client.fetch(.{
        .method = std.http.Method.GET,
        .location = .{ .uri = try .parse(response_json.value.objects[0].actions.download.href) },
        .response_writer = &blob.writer,
    });

    try out.interface.writeAll(blob.writer.buffered());
    try out.interface.flush();
    std.debug.print("wrote ./{s}\n", .{OID});
    try blob.writer.flush();
}
