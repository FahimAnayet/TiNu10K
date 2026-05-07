const std = @import("std");

pub const markers = std.StaticStringMap([]const u8).initComptime(.{
    .{".lua-version",         "lua"},
    .{".ruby-version",       "ruby"},
    .{"build.zig",           "zig"},
    .{"build.zig.zon",       "zig"},
    .{".go-version",         "go"},
    .{"go.mod",              "go"},
    .{"v.mod",               "v"},
    .{"Cargo.toml",          "rust"},
    .{"pyproject.toml",      "python"},
    .{"requirements.txt",    "python"},
    .{".python-version",     "python"},
    .{"package.json",        "node"},
    .{".node-version",       "node"},
    .{"bun.lockb",           "node"},
    .{".java-version",       "java"},
    .{".perl-version",       "perl"},
    .{".php-version",        "php"},
    .{"composer.json",       "php"},
    .{"stack.yaml",          "haskell"},
});

pub const root_markers = std.StaticStringMap(void).initComptime(.{
    .{".svn", {}},
    .{".hg", {}},
    .{".bzr", {}},
    .{".shorten_folder_marker", {}},
    .{".git", {}},
    .{".jj", {}},
    .{".mise.toml", {}},
    .{".citc", {}},
    .{".terraform", {}},
    .{".tool-versions", {}},
    .{"CVS", {}},
});

pub const lang_cmd = std.StaticStringMap([]const u8).initComptime(.{
    .{"python",     "python3 --version"},
    .{"rust",       "rustc --version"},
    .{"v",          "v --version"},
    .{"node",       "node -v"},
    .{"zig",        "zig version"},
    .{"go",         "go version"},
    .{"lua",        "lua -v"},
});

/// Parse version string according to the language convention.
fn parseVersion(lang: []const u8, raw: []const u8) []const u8 {
    if (raw.len == 0) return "";

    // Split by whitespace to get tokens
    var parts = std.mem.splitAny(u8, raw, " \t\r\n");
    var tokens = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer tokens.deinit();
    while (parts.next()) |tok| {
        tokens.append(tok) catch return "";
    }

    if (tokens.items.len == 0) return "";

    if (std.mem.eql(u8, lang, "python") or std.mem.eql(u8, lang, "rust")) {
        return if (tokens.items.len > 1) tokens.items[1] else tokens.items[0];
    } else if (std.mem.eql(u8, lang, "node")) {
        var v = tokens.items[0];
        if (v.len > 0 and v[0] == 'v') v = v[1..];
        return v;
    } else if (std.mem.eql(u8, lang, "go")) {
        // "go version go1.26.2-X:nodwarf5 ..."
        var v = if (tokens.items.len > 2) tokens.items[2] else return "";
        if (std.mem.startsWith(u8, v, "go")) v = v[2..];
        if (std.mem.indexOfScalar(u8, v, '-')) |hyphen| {
            v = v[0..hyphen];
        }
        return v;
    } else {
        return raw;
    }
}

/// Update the version cache file if older than 5 seconds.
pub fn updateCache(allocator: std.mem.Allocator, lang: []const u8, cache_file: []const u8) !void {
    const cmd = lang_cmd.get(lang) orelse return;

    // Skip if cache is fresh
    if (std.fs.cwd().statFile(cache_file)) |stat| {
        const now = std.time.nanoTimestamp();
        const age = now - @as(i128, @intCast(stat.mtime)) * std.time.ns_per_s;
        if (age < 5 * std.time.ns_per_s) return;
    } else |_| {}

    // Run external command
    var child = std.process.Child.init(&.{ "/bin/sh", "-c", cmd }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;
    const output = child.stdout.?.reader().readAllAlloc(allocator, 128) catch {
        _ = child.kill() catch {};
        return;
    };
    defer allocator.free(output);
    _ = child.wait() catch {};

    const clean = parseVersion(lang, output);
    if (clean.len == 0) return;

    var file = try std.fs.createFileAbsolute(cache_file, .{});
    defer file.close();
    try file.writeAll(clean);
}

/// Read cached version string.
pub fn getCached(allocator: std.mem.Allocator, cache_file: []const u8) ![]const u8 {
    const data = try std.fs.cwd().readFileAlloc(allocator, cache_file, 128);
    return std.mem.trim(u8, data, " \n\r\t");
}
