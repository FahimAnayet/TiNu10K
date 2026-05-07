const std = @import("std");
const posix = std.posix;
const fs = std.fs;
const version = @import("version.zig");
const gitstatus = @import("gitstatus.zig");

pub const Segment = struct {
    full: []const u8,
    short: []const u8,
    full_len: u16,
    short_len: u16,
    is_root: bool,

    pub fn deinit(self: *Segment, a: std.mem.Allocator) void {
        a.free(self.full);
        a.free(self.short);
    }
};

pub const CachedPath = struct {
    path: []const u8,
    segments: []Segment,
    git: bool,
    langs: std.StringHashMap(void),
    anchor: []const u8,
    prefix: []const u8,
    full_total_len: usize,
    segment_dirs: []const []const u8,
    segment_mtimes: []const i128,

    pub fn deinit(self: *CachedPath, a: std.mem.Allocator) void {
        a.free(self.path);
        for (self.segments) |*seg| seg.deinit(a);
        a.free(self.segments);
        var it = self.langs.keyIterator();
        while (it.next()) |k| a.free(k.*);
        self.langs.deinit();
        a.free(self.anchor);
        a.free(self.prefix);
        for (self.segment_dirs) |d| a.free(d);
        a.free(self.segment_dirs);
        a.free(self.segment_mtimes);
    }
};

pub fn compute_path(allocator: std.mem.Allocator, raw_path: []const u8) !CachedPath {
    const home = posix.getenv("HOME") orelse "";
    var prefix: []const u8 = " ";
    var display = raw_path;
    var is_home = false;

    if (home.len > 0 and std.mem.startsWith(u8, raw_path, home)) {
        prefix = " ~";
        display = raw_path[home.len..];
        is_home = true;
    }

    var segs = std.ArrayList([]const u8).init(allocator);
    defer segs.deinit();
    var it = std.mem.splitScalar(u8, display, '/');
    while (it.next()) |s| {
        if (s.len > 0) try segs.append(s);
    }

    var processed = std.ArrayList(Segment).init(allocator);
    errdefer {
        for (processed.items) |*seg| seg.deinit(allocator);
        processed.deinit();
    }

    var dir_paths = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (dir_paths.items) |d| allocator.free(d);
        dir_paths.deinit();
    }
    var dir_mtimes = std.ArrayList(i128).init(allocator);
    errdefer dir_mtimes.deinit();

    var has_git = false;
    var langs = std.StringHashMap(void).init(allocator);
    errdefer {
        var lit = langs.keyIterator();
        while (lit.next()) |k| allocator.free(k.*);
        langs.deinit();
    }

    var current: []const u8 = if (is_home) try fs.realpathAlloc(allocator, home) else try fs.realpathAlloc(allocator, "/");
    errdefer allocator.free(current);
    var anchor: []const u8 = try allocator.dupe(u8, current);
    errdefer allocator.free(anchor);
    var found_root = false;

    for (segs.items, 0..) |seg, idx| {
        const next = try fs.path.join(allocator, &.{ current, seg });
        defer allocator.free(next);

        const full = try allocator.dupe(u8, seg);
        var short_len: usize = 1;
        if (is_home and idx == 0 and seg.len > 3) short_len = 3;

        var siblings = std.ArrayList([]const u8).init(allocator);
        defer siblings.deinit();
        if (!(is_home and idx == 0)) {
            if (fs.openDirAbsolute(current, .{ .iterate = true })) |raw_dir| {
                var dir = raw_dir;
                defer dir.close();
                var iter = dir.iterate();
                while (iter.next() catch null) |entry| {
                    try siblings.append(entry.name);
                }
            } else |_| {}
        }

        while (short_len <= full.len) : (short_len += 1) {
            const cand = full[0..short_len];
            var matches: usize = 0;
            for (siblings.items) |s| {
                if (std.mem.startsWith(u8, s, cand)) matches += 1;
            }
            if (matches <= 1) break;
        }
        const short = try allocator.dupe(u8, full[0..short_len]);

        var is_root_seg = false;
        {
            var marker_buf: [std.fs.max_path_bytes]u8 = undefined;
            for (version.root_markers.keys()) |marker| {
                const marker_path = std.fmt.bufPrint(&marker_buf, "{s}/{s}", .{next, marker}) catch continue;
                if (fs.accessAbsolute(marker_path, .{})) |_| {
                    is_root_seg = true;
                    if (std.mem.eql(u8, marker, ".git")) has_git = true;
                } else |_| {}
            }
            for (version.markers.keys()) |marker| {
                const marker_path = std.fmt.bufPrint(&marker_buf, "{s}/{s}", .{next, marker}) catch continue;
                if (fs.accessAbsolute(marker_path, .{})) |_| {
                    is_root_seg = true;
                    try langs.put(try allocator.dupe(u8, version.markers.get(marker).?), {});
                } else |_| {}
            }
        }

        try dir_paths.append(try allocator.dupe(u8, next));
        if (fs.cwd().statFile(next)) |st| {
            try dir_mtimes.append(st.mtime);
        } else |_| {
            try dir_mtimes.append(0);
        }

        if (is_root_seg and !found_root) {
            allocator.free(anchor);
            anchor = try allocator.dupe(u8, next);
            found_root = true;
        }

        try processed.append(Segment{
            .full = full,
            .short = short,
            .full_len = @intCast(full.len),
            .short_len = @intCast(short.len),
            .is_root = is_root_seg,
        });

        allocator.free(current);
        current = try allocator.dupe(u8, next);
    }

    var full_total_len: usize = 0;
    for (processed.items) |seg| {
        full_total_len += seg.full_len + 1;
    }

    return CachedPath{
        .path = try allocator.dupe(u8, raw_path),
        .segments = try processed.toOwnedSlice(),
        .git = has_git,
        .langs = langs,
        .anchor = anchor,
        .prefix = try allocator.dupe(u8, prefix),
        .full_total_len = full_total_len,
        .segment_dirs = try dir_paths.toOwnedSlice(),
        .segment_mtimes = try dir_mtimes.toOwnedSlice(),
    };
}

pub fn generate(allocator: std.mem.Allocator, path: []const u8, term_width: usize, allowed: []const u8) !void {
    _ = allowed;
    var cp = try compute_path(allocator, path);
    defer cp.deinit(allocator);

    const max_width = term_width / 2;
    var collapsed = try allocator.alloc(bool, cp.segments.len);
    defer allocator.free(collapsed);
    @memset(collapsed, false);

    var total_len = cp.full_total_len;
    if (total_len > max_width) {
        var i: usize = 0;
        while (i < cp.segments.len - 1) : (i += 1) {
            if (cp.segments[i].is_root) continue;
            total_len -= cp.segments[i].full_len - cp.segments[i].short_len;
            collapsed[i] = true;
            if (total_len <= max_width) break;
        }
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{{\"prefix\":\"{s}\",\"segments\":[", .{cp.prefix});
    for (cp.segments, 0..) |seg, idx| {
        const text = if (collapsed[idx]) seg.short else seg.full;
        try stdout.print("{{\"text\":\"{s}\",\"is_anchor\":{s},\"is_collapsed\":{s}}}", .{
            text,
            if (idx == cp.segments.len - 1 or seg.is_root) "true" else "false",
            if (collapsed[idx]) "true" else "false",
        });
        if (idx < cp.segments.len - 1) try stdout.writeByte(',');
    }

    if (cp.git) {
        const git_json = gitstatus.query(allocator, path) catch "";
        try stdout.print("],\"git\":{s}", .{if (git_json.len > 0) git_json else "1"});
    } else {
        try stdout.print("],\"git\":null", .{});
    }

    try stdout.print(",\"languages\":{{", .{});
    var first_lang = true;
    var key_it = cp.langs.keyIterator();
    while (key_it.next()) |lang| {
        if (!first_lang) try stdout.writeByte(',');
        first_lang = false;

        var hash_buf: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(cp.path);
        hasher.update(lang.*);
        hasher.final(&hash_buf);
        const hash_hex = std.fmt.bytesToHex(&hash_buf, .lower);
        const cache_file = std.fmt.allocPrint(allocator, "/tmp/tinu10k/v_{s}_{s}", .{hash_hex, lang.*}) catch "";
        defer if (cache_file.len > 0) allocator.free(cache_file);

        if (cache_file.len > 0) {
            version.updateCache(allocator, lang.*, cache_file) catch {};
            const ver = version.getCached(allocator, cache_file) catch "";
            try stdout.print("\"{s}\":\"{s}\"", .{ lang.*, ver });
        }
    }
    try stdout.print("}}\n}}\n", .{});
}
