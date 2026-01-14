const std = @import("std");
const Io = std.Io;

fn match_line_prefix(config: *Io.Reader, prefix: []const u8) !usize {
    if (config.peekDelimiterInclusive('\n')) |l| {
        if (l.len >= prefix.len and
            std.mem.eql(u8, l[0..prefix.len], prefix)) return l.len;
        return error.NoMatch;
    } else |_| return error.UnexpectedEof;
}
pub fn the_thing(config: *Io.Reader) !void {
    while (true) {
        const section_header_prefix = "[remote";
        if (match_line_prefix(config, section_header_prefix)) |line_len| {
            config.toss(line_len);
        } else |_| {
            _ = try config.takeDelimiterInclusive('\n');
            continue;
        }

        while (std.ascii.isWhitespace(try config.peekByte()))
            config.toss(1);

        const remote_prefix = "url = ";
        if (match_line_prefix(config, remote_prefix)) |_| {
            config.toss(remote_prefix.len);
        } else |_| {
            _ = try config.takeDelimiterInclusive('\n');
            continue;
        }

        if (config.peekDelimiterExclusive('\n')) |repo| {
            std.debug.print("{s}\n", .{repo});
            return;
        } else |_| return error.UnexpectedEof;
    }
}

test the_thing {
    const config_buf =
        \\[remote "origin"]
        \\  url = git@github.com:kasimeka/zerolf.git
        \\  fetch = +refs/heads/*:refs/remotes/origin/*
        \\
    ;

    var config = Io.Reader.fixed(config_buf);
    try the_thing(&config);
}

pub fn main() !void {
    const config_buf =
        \\[core]
        \\  repositoryformatversion = 0
        \\  filemode = true
        \\  bare = false
        \\  logallrefupdates = true
        \\  symlinks = true
        \\  ignorecase = false
        \\  precomposeunicode = true
        \\[remote "origin"]
        \\  url = git@github.com:kasimeka/zerolf.git
        \\  fetch = +refs/heads/*:refs/remotes/origin/*
    ;

    var config = Io.Reader.fixed(config_buf);
    try the_thing(&config);
}
