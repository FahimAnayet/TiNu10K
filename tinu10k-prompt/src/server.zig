const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const net = std.net;
const fs = std.fs;
const gitstatus = @import("gitstatus.zig");
const version = @import("version.zig");
const prompt = @import("prompt.zig");

const SOCKET_PATH = "/tmp/tinu10k/server.sock";
const PID_FILE = "/tmp/tinu10k/server.pid";
const LOCK_FILE = "/tmp/tinu10k/server.lock";
const GIT_IN_FIFO = "/tmp/tinu10k/gitstatusd.in";
const GIT_OUT_FIFO = "/tmp/tinu10k/gitstatusd.out";
const GIT_PID_FILE = "/tmp/tinu10k/gitstatusd.pid";

// ---------- 辅助函数 ----------

fn ensure_dir() !void {
    std.fs.makeDirAbsolute("/tmp/tinu10k") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn read_pid(path: []const u8) ?linux.pid_t {
    const content = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 1024) catch return null;
    defer std.heap.page_allocator.free(content);
    const pid_str = std.mem.trim(u8, content, " \n\r\t");
    const pid = std.fmt.parseInt(linux.pid_t, pid_str, 10) catch return null;
    return pid;
}

fn is_alive(pid: linux.pid_t) bool {
    return linux.kill(pid, 0) == 0;
}

fn stop_server_logic() void {
    if (read_pid(PID_FILE)) |pid| {
        _ = linux.kill(pid, linux.SIG.TERM);
        std.time.sleep(10 * std.time.ns_per_ms);
    }
    std.fs.deleteFileAbsolute(PID_FILE) catch {};
    std.fs.deleteFileAbsolute(SOCKET_PATH) catch {};
}

fn stop_gitstatusd() void {
    if (read_pid(GIT_PID_FILE)) |pid| {
        _ = linux.kill(pid, linux.SIG.TERM);
        std.time.sleep(10 * std.time.ns_per_ms);
    }
    std.fs.deleteFileAbsolute(GIT_PID_FILE) catch {};
    std.fs.deleteFileAbsolute(GIT_IN_FIFO) catch {};
    std.fs.deleteFileAbsolute(GIT_OUT_FIFO) catch {};
}

fn write_pid(path: []const u8) !void {
    const pid = linux.getpid();
    var pf = try std.fs.createFileAbsolute(path, .{});
    defer pf.close();
    var buf: [20]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch unreachable;
    _ = try pf.write(pid_str);
}

fn start_gitstatusd() !void {
    // 检查是否已运行
    if (read_pid(GIT_PID_FILE)) |pid| {
        if (is_alive(pid)) return; // 已活
        stop_gitstatusd();
    }

    std.fs.deleteFileAbsolute(GIT_IN_FIFO) catch {};
    std.fs.deleteFileAbsolute(GIT_OUT_FIFO) catch {};

    const S = std.posix.S;
    {
        const res = std.os.linux.mknod(GIT_IN_FIFO, S.IFIFO | 0o666, 0);
        if (std.posix.errno(res) != .SUCCESS) return error.Unexpected;
    }
    {
        const res = std.os.linux.mknod(GIT_OUT_FIFO, S.IFIFO | 0o666, 0);
        if (std.posix.errno(res) != .SUCCESS) return error.Unexpected;
    }

    const fork1 = linux.fork();
    if (@as(isize, @bitCast(fork1)) == -1) return error.SystemResources;
    if (fork1 == 0) {
        _ = linux.setsid();
        const fork2 = linux.fork();
        if (@as(isize, @bitCast(fork2)) == -1) linux.exit(1);
        if (fork2 == 0) {
            const pid = linux.getpid();
            var pf = try std.fs.createFileAbsolute(GIT_PID_FILE, .{});
            defer pf.close();
            var buf: [20]u8 = undefined;
            const pid_str = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch unreachable;
            _ = try pf.write(pid_str);

            const in_fd = try posix.open(GIT_IN_FIFO, .{ .ACCMODE = .RDWR }, 0);
            const out_fd = try posix.open(GIT_OUT_FIFO, .{ .ACCMODE = .RDWR }, 0);
            const null_fd = try posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
            try posix.dup2(in_fd, posix.STDIN_FILENO);
            try posix.dup2(out_fd, posix.STDOUT_FILENO);
            try posix.dup2(null_fd, posix.STDERR_FILENO);
            posix.close(in_fd);
            posix.close(out_fd);
            posix.close(null_fd);

            var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const exe_path = std.fs.selfExePath(&exe_path_buf) catch { linux.exit(1); };
            const exe_dir = std.fs.path.dirname(exe_path) orelse { linux.exit(1); };
            var gitstatusd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const gitstatusd_path = std.fmt.bufPrint(&gitstatusd_buf, "{s}/gitstatusd", .{exe_dir}) catch { linux.exit(1); };
            gitstatusd_buf[gitstatusd_path.len] = 0;
            const gitstatusd_ptr: [*:0]const u8 = @ptrCast(gitstatusd_path.ptr);
            const args = [_:null]?[*:0]const u8{
                gitstatusd_ptr, "-v", "ERROR", "-s", "-1", "-u", "-1", "-d", "-1", "-t", "8",
            };
            _ = linux.execve(args[0].?, &args, &[_:null]?[*:0]const u8{null});
            linux.exit(1);
        }
        linux.exit(0);
    }
}

fn spawn_reaper(shell_pid: linux.pid_t) !void {
    const fork1 = linux.fork();
    if (@as(isize, @bitCast(fork1)) == -1) return error.SystemResources;
    if (fork1 == 0) {
        const fork2 = linux.fork();
        if (@as(isize, @bitCast(fork2)) == -1) linux.exit(1);
        if (fork2 == 0) {
            _ = linux.setsid();
            posix.close(posix.STDIN_FILENO);
            posix.close(posix.STDOUT_FILENO);
            posix.close(posix.STDERR_FILENO);
            const fd = try posix.open(LOCK_FILE, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = false }, 0o666);
            _ = linux.syscall2(.flock, @as(usize, @bitCast(@as(isize, fd))), 1);
            defer posix.close(fd);
            while (linux.kill(shell_pid, 0) == 0) {
                std.time.sleep(5 * std.time.ns_per_s);
            }
            if (linux.syscall2(.flock, @as(usize, @bitCast(@as(isize, fd))), 2 | 4) == 0) {
                stop_gitstatusd();
                stop_server_logic();
                posix.close(fd);
                std.fs.deleteFileAbsolute(LOCK_FILE) catch {};
            }
            linux.exit(0);
        }
        linux.exit(0);
    }
}

const PathCache = struct {
    paths: std.ArrayList(prompt.CachedPath),
    max: usize,

    fn init(a: std.mem.Allocator, max: usize) PathCache {
        return .{ .paths = std.ArrayList(prompt.CachedPath).init(a), .max = max };
    }

    fn deinit(self: *PathCache, a: std.mem.Allocator) void {
        for (self.paths.items) |*cp| cp.deinit(a);
        self.paths.deinit();
    }

    fn find(self: *const PathCache, path: []const u8) ?*prompt.CachedPath {
        for (self.paths.items) |*cp| {
            if (std.mem.eql(u8, cp.path, path)) return cp;
        }
        return null;
    }

    fn put(self: *PathCache, a: std.mem.Allocator, cp: prompt.CachedPath) !void {
        for (self.paths.items, 0..) |*existing, i| {
            if (std.mem.eql(u8, existing.path, cp.path)) {
                var old = self.paths.orderedRemove(i);
                old.deinit(a);
                break;
            }
        }
        if (self.paths.items.len >= self.max) {
            var old = self.paths.orderedRemove(0);
            old.deinit(a);
        }
        try self.paths.append(cp);
    }
};

// ---------- 请求处理 ----------

fn handle_req(allocator: std.mem.Allocator, conn: posix.fd_t, cache: *PathCache) !void {
    var buf: [4096]u8 = undefined;
    const n = posix.read(conn, &buf) catch return;
    if (n == 0) return;

    const request = std.mem.trim(u8, buf[0..n], " \n\r\t");
    var it = std.mem.splitScalar(u8, request, ' ');
    const path = it.next() orelse return;
    const term_width_str = it.next() orelse return;
    _ = it.next(); // allowed langs, unused yet

    const term_width = std.fmt.parseInt(usize, term_width_str, 10) catch return;

    const cp = blk: {
        if (cache.find(path)) |cached| {
            var valid = true;
            for (cached.segment_dirs, cached.segment_mtimes) |dir_path, mtime| {
                const st = std.fs.cwd().statFile(dir_path) catch { valid = false; break; };
                if (st.mtime != mtime) { valid = false; break; }
            }
            if (valid) break :blk cached;
        }
        var new_cp = prompt.compute_path(allocator, path) catch {
            const resp = "{\"error\":\"compute failed\"}\n";
            _ = posix.write(conn, resp) catch {};
            return;
        };
        cache.put(allocator, new_cp) catch {
            new_cp.deinit(allocator);
            return;
        };
        break :blk cache.find(path).?;
    };

    // 用长度快速计算哪些segment需collapse
    const max_width = term_width / 2;
    var collapsed = try allocator.alloc(bool, cp.segments.len);
    defer allocator.free(collapsed);
    @memset(collapsed, false);

    // 用预存总长
    var total_len = cp.full_total_len;

    // 超宽则前面非root段换short，逐步减长度
    if (total_len > max_width) {
        var i: usize = 0;
        while (i < cp.segments.len - 1) : (i += 1) {
            if (cp.segments[i].is_root) continue;
            total_len -= cp.segments[i].full_len - cp.segments[i].short_len;
            collapsed[i] = true;
            if (total_len <= max_width) break;
        }
    }

    // 构建JSON
    var resp_buf: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&resp_buf);
    const writer = stream.writer();

    writer.print("{{\"prefix\":\"{s}\",\"segments\":[", .{cp.prefix}) catch return;
    for (cp.segments, 0..) |seg, idx| {
        const text = if (collapsed[idx]) seg.short else seg.full;
        writer.print("{{\"text\":\"{s}\",\"is_anchor\":{s},\"is_collapsed\":{s}}}", .{
            text,
            if (idx == cp.segments.len - 1 or seg.is_root) "true" else "false",
            if (collapsed[idx]) "true" else "false",
        }) catch return;
        if (idx < cp.segments.len - 1) writer.writeByte(',') catch return;
    }

    // Git
    if (cp.git) {
        const git_json = gitstatus.query(allocator, path) catch "";
        writer.print("],\"git\":{s}", .{if (git_json.len > 0) git_json else "1"}) catch return;
    } else {
        writer.print("],\"git\":null", .{}) catch return;
    }

    // Languages with version caching
    writer.print(",\"languages\":{{", .{}) catch return;
    var first_lang = true;
    var key_it = cp.langs.keyIterator();
    while (key_it.next()) |lang| {
        if (!first_lang) writer.writeByte(',') catch return;
        first_lang = false;

        // Build cache file path
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
            writer.print("\"{s}\":\"{s}\"", .{ lang.*, ver }) catch return;
        }
    }
    writer.print("}}\n}}\n", .{}) catch return;

    _ = posix.write(conn, stream.getWritten()) catch {};
}

// ---------- 主入口 ----------

pub fn start() !void {
    // 单例检查：PID活→退
    if (read_pid(PID_FILE)) |pid| {
        if (is_alive(pid)) return;
        stop_server_logic(); // PID存但进程死，清理
    }

    try ensure_dir();

    // 确保gitstatusd启动
    try start_gitstatusd();

    const shell_pid = linux.getppid();
    try spawn_reaper(shell_pid);

    // 删除旧socket
    std.fs.deleteFileAbsolute(SOCKET_PATH) catch {};

    // 双重fork创建守护进程
    const f1 = linux.fork();
    if (@as(isize, @bitCast(f1)) == -1) return error.SystemResources;
    if (f1 == 0) {
        const f2 = linux.fork();
        if (@as(isize, @bitCast(f2)) == -1) linux.exit(1);
        if (f2 == 0) {
            _ = linux.setsid();

            write_pid(PID_FILE) catch { linux.exit(10); };

            // Redirect stdio to /dev/null since we closed them
            const devnull = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch { linux.exit(2); };
            posix.dup2(devnull, posix.STDIN_FILENO) catch {};
            posix.dup2(devnull, posix.STDOUT_FILENO) catch {};
            posix.dup2(devnull, posix.STDERR_FILENO) catch {};
            posix.close(devnull);

            var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
            defer _ = gpa.deinit();
            const allocator = gpa.allocator();

            var cache = PathCache.init(allocator, 10);
            defer cache.deinit(allocator);

            const addr = net.Address.initUnix(SOCKET_PATH) catch { linux.exit(3); };
            const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch { linux.exit(4); };
            defer posix.close(sock);
            posix.bind(sock, &addr.any, addr.getOsSockLen()) catch { linux.exit(5); };
            posix.listen(sock, 10) catch { linux.exit(6); };

            const logf = std.fs.createFileAbsolute("/tmp/tinu10k/server.log", .{ .truncate = false }) catch null;
            if (logf) |lf| {
                const writer = lf.writer();
                writer.print("server listening on {s}\n", .{SOCKET_PATH}) catch {};
            }

            while (true) {
                const conn = posix.accept(sock, null, null, 0) catch |err| {
                    if (logf) |lf| {
                        const writer = lf.writer();
                        writer.print("accept error: {}\n", .{err}) catch {};
                    }
                    continue;
                };
                handle_req(allocator, conn, &cache) catch |err| {
                    if (logf) |lf| {
                        const writer = lf.writer();
                        writer.print("handle_req error: {}\n", .{err}) catch {};
                    }
                };
                posix.close(conn);
            }
        }
        linux.exit(0);
    }
}

pub fn stop() void {
    stop_server_logic();
    stop_gitstatusd();
    std.fs.deleteFileAbsolute(LOCK_FILE) catch {};
}
