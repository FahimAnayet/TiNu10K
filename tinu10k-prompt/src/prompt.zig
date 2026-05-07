const std = @import("std");
const fs = std.fs;
const git = @import("gitstatus.zig");
const version = @import("version.zig");

const marks = version.markers;
const root_mark = version.root_markers;
const allowed_commands = version.lang_cmd;

const Meta = struct {
    full: []const u8,
    short_: []const u8,
    current: []const u8,
    is_root: bool = false,
};

pub fn generate(allocator: std.mem.Allocator, raw_path: []const u8, term_width: usize, allowed_input: []const u8) !void {
    var allowed_langs = std.StringHashMap(void).init(allocator);
    defer allowed_langs.deinit();
    var it = std.mem.splitScalar(u8, allowed_input, ',');
    while (it.next()) |lang| if (lang.len > 0) try allowed_langs.put(lang, {});

    const home_env = std.posix.getenv("HOME") orelse "";
    var prefix: []const u8 = " ";
    var builder_path: []const u8 = "/";
    var display_path = raw_path;
    var is_home = false;

    if (home_env.len > 0 and std.mem.startsWith(u8, raw_path, home_env)) {
        prefix = " ~";
        builder_path = home_env;
        display_path = raw_path[home_env.len..];
        is_home = true;
    }

    var segments = std.ArrayList([]const u8).init(allocator);
    defer segments.deinit();
    var seg_it = std.mem.splitScalar(u8, display_path, '/');
    while (seg_it.next()) |seg| if (seg.len > 0) try segments.append(seg);

    var current = try allocator.dupe(u8, builder_path);
    defer allocator.free(current);

    var processed = std.ArrayList(Meta).init(allocator);
    defer processed.deinit();
    var anchor_path = try allocator.dupe(u8, current);
    defer allocator.free(anchor_path);

    var global_langs = std.StringHashMap(void).init(allocator);
    defer global_langs.deinit();
    var has_git = false;
    var found_root = false;

    for (segments.items, 0..) |seg, seg_idx| {
        const next_path = try fs.path.join(allocator, &.{ current, seg });
        defer allocator.free(next_path);

        var meta: Meta = .{
            .full = seg,
            .current = seg,
            .short_ = undefined,
            .is_root = false,
        };

        var siblings = std.ArrayList([]const u8).init(allocator);
        defer {
            for (siblings.items) |s| allocator.free(s);
            siblings.deinit();
        }

        // --- Single Pass: Sibling Collection + Marker Peeking ---
        if (fs.openDirAbsolute(current, .{ .iterate = true })) |dir| {
            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                try siblings.append(try allocator.dupe(u8, entry.name));

                // If this sibling IS our current segment, look inside it for markers
                if (std.mem.eql(u8, entry.name, seg)) {
                    if (dir.openDir(entry.name, .{ .iterate = true })) |sub_dir| {
                        var sub_iter = sub_dir.iterate();
                        while (sub_iter.next() catch null) |sub_entry| {
                            if (marks.get(sub_entry.name)) |lang_name| {
                                try global_langs.put(lang_name, {});
                                meta.is_root = true;
                            }
                            if (root_mark.has(sub_entry.name)) {
                                meta.is_root = true;
                                if (std.mem.eql(u8, sub_entry.name, ".git")) {
                                    has_git = true;
                                    try global_langs.put("git", {});
                                } else if (std.mem.eql(u8, sub_entry.name, ".jj")) {
                                    try global_langs.put("jj", {});
                                }
                            }
                        }
                    } else |_| {}
                }
            }
        } else |_| {}

        // --- Shortest Unique Prefix Calculation ---
        var short_len: usize = 1;
        if (is_home and seg_idx == 0) {
            short_len = if (seg.len > 3) 3 else seg.len;
        } else {
            while (short_len <= seg.len) : (short_len += 1) {
                const candidate = seg[0..short_len];
                var matches: usize = 0;
                for (siblings.items) |sib| {
                    if (std.mem.startsWith(u8, sib, candidate)) matches += 1;
                }
                if (matches <= 1) break;
            }
        }
        meta.short_ = seg[0..@min(short_len, seg.len)];

        if (meta.is_root and !found_root) {
            allocator.free(anchor_path);
            anchor_path = try allocator.dupe(u8, next_path);
            found_root = true;
        }

        try processed.append(meta);
        allocator.free(current);
        current = try allocator.dupe(u8, next_path);
    }

    // --- Output JSON ---
    const max_width = term_width / 2;
    var total_len: usize = 0;
    for (processed.items) |p| total_len += p.current.len + 1;
    if (total_len > max_width) {
        for (0..processed.items.len - 1) |i| {
            if (processed.items[i].is_root) continue;
            processed.items[i].current = processed.items[i].short_;
            var new_total: usize = 0;
            for (processed.items) |p| new_total += p.current.len + 1;
            if (new_total <= max_width) break;
        }
    }

    var path_hash_buf: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(if (found_root) anchor_path else raw_path);
    if (std.posix.getenv("PATH")) |env| hasher.update(env);
    hasher.final(&path_hash_buf);
    const path_hash = std.fmt.bytesToHex(&path_hash_buf, .lower);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{{\"prefix\":\"{s}\", \"segments\":[", .{prefix});

    for (processed.items, 0..) |p, idx| {
        try stdout.print("{{\"text\":\"{s}\",\"is_anchor\":{s},\"is_collapsed\":{s}}}", .{
            p.current,
            if (idx == processed.items.len - 1 or p.is_root) "true" else "false",
            if (!std.mem.eql(u8, p.current, p.full)) "true" else "false",
        });
        if (idx < processed.items.len - 1) try stdout.writeByte(',');
    }

    try stdout.print("],\"git\":{s}", .{if (has_git) (git.query(allocator, raw_path) catch "1") else "null"});
    try stdout.print(",\"languages\":{{", .{});
    var first_lang = true;
    var key_it = global_langs.keyIterator();
    while (key_it.next()) |lang| {
        if (allowed_langs.contains(lang.*) and allowed_commands.has(lang.*)) {
            const cache_file = try std.fmt.allocPrint(allocator, "/tmp/tinu10k/v_{s}_{s}", .{ path_hash, lang.* });
            defer allocator.free(cache_file);
            const ver = version.getCached(allocator, cache_file) catch "";
            if (!first_lang) try stdout.writeByte(',');
            try stdout.print("\"{s}\":\"{s}\"", .{ lang.*, ver });
            first_lang = false;
            version.updateCache(allocator, lang.*, cache_file) catch {};
        }
    }
    try stdout.print("}}\n}}", .{});
}
