const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Returns a JSON array string or empty if unavailable.
pub fn query(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const abs_path = try std.fs.realpathAlloc(allocator, path);
    defer allocator.free(abs_path);

    const request = try std.fmt.allocPrint(allocator, "666\x1F{s}\x1E", .{abs_path});
    defer allocator.free(request);

    // Open FIFOs non‑blocking
    const out_fd = posix.open("/tmp/tinu10k/gitstatusd.in", .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0) catch return "";
    const in_fd = posix.open("/tmp/tinu10k/gitstatusd.out", .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0) catch {
        posix.close(out_fd);
        return "";
    };
    defer posix.close(out_fd);
    defer posix.close(in_fd);

    _ = posix.write(out_fd, request) catch {
        return "";
    };

    // Wait up to 50 ms for a response
    var pollfd = [_]posix.pollfd{
        .{.fd = @intCast(in_fd), .events = posix.POLL.IN, .revents = 0},
    };
    _ = posix.poll(&pollfd, 50) catch 0;
    if (pollfd[0].revents & posix.POLL.IN == 0) return "";

    var buf: [16384]u8 = undefined;
    const n = posix.read(in_fd, &buf) catch return "";
    if (n == 0) return "";

    const response = buf[0..n];

    // Validate header
    if (response.len < 4 or !std.mem.eql(u8, response[0..4], "666\x1F"))
        return "";

    // Split by '\x1F'
    var fields = std.ArrayList([]const u8).init(allocator);
    defer fields.deinit();
    var it = std.mem.splitSequence(u8, response, "\x1F");
    while (it.next()) |part| {
        try fields.append(part);
    }
    if (fields.items.len < 21 or !std.mem.eql(u8, fields.items[1], "1"))
        return "";

    // f[4] is branch, f[3] full commit hash
    const branch_or_tag = fields.items[4];
    const commit_short = if (fields.items[3].len >= 7) fields.items[3][0..7] else fields.items[3];
    const display = if (std.mem.eql(u8, branch_or_tag, "HEAD")) commit_short else branch_or_tag;

    const st = struct {
        fn to_int(s: []const u8) u16 {
            return std.fmt.parseInt(u16, s, 10) catch 0;
        }
    };

    const staged    = st.to_int(fields.items[10]);
    const unstaged  = st.to_int(fields.items[11]);
    const untracked = st.to_int(fields.items[13]);
    const conflicts = st.to_int(fields.items[18]);
    const ahead_behind_empty = fields.items[5].len == 0;
    const ahead = st.to_int(fields.items[14]);
    const behind = st.to_int(fields.items[15]);
    const stash_size = st.to_int(fields.items[16]);
    const dirty = @intFromBool(staged + unstaged + untracked + conflicts > 0);

    const final = try std.fmt.allocPrint(allocator,
        \\["{s}",{d},{d},{d},{d},{d},{d},{d},{d},{d},"{s}"]
    , .{
        display,
        staged,
        unstaged,
        untracked,
        conflicts,
        @as(u8, if (ahead_behind_empty) 0 else 1),
        ahead,
        behind,
        stash_size,
        dirty,
        commit_short,
    });
    return final;
}
