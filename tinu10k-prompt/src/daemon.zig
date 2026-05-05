const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

const IN_FIFO = "/tmp/tinu10k/gitstatusd.in";
const OUT_FIFO = "/tmp/tinu10k/gitstatusd.out";
const PID_FILE = "/tmp/tinu10k/gitstatusd.pid";
const LOCK_FILE = "/tmp/tinu10k/gitstatusd.lock";

fn ensure_dir() !void {
    std.fs.makeDirAbsolute("/tmp/tinu10k") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn is_alive() bool {
    const pid = get_pid_from_file() orelse return false;
    // kill(pid, 0) checks existence
    return (linux.kill(pid, 0) == 0);
}

fn get_pid_from_file() ?linux.pid_t {
    const content = std.fs.cwd().readFileAlloc(std.heap.page_allocator, PID_FILE, 1024) catch return null;
    defer std.heap.page_allocator.free(content);
    const pid_str = std.mem.trim(u8, content, " \n\r\t");
    const pid = std.fmt.parseInt(linux.pid_t, pid_str, 10) catch return null;
    return pid;
}

fn start_server() !void {
    // Clean stale FIFOs and re‑create
    std.fs.deleteFileAbsolute(IN_FIFO) catch {};
    std.fs.deleteFileAbsolute(OUT_FIFO) catch {};

    const S = std.posix.S;
    {
        const res = std.os.linux.mknod(IN_FIFO, S.IFIFO | 0o666, 0);
        if (std.posix.errno(res) != .SUCCESS) return error.Unexpected;
    }
    {
        const res = std.os.linux.mknod(OUT_FIFO, S.IFIFO | 0o666, 0);
        if (std.posix.errno(res) != .SUCCESS) return error.Unexpected;
    }
    const fork1 = linux.fork();
    if (@as(isize, @bitCast(fork1)) == -1) return error.SystemResources;
    if (fork1 == 0) {
        // Child: setsid, double fork, exec
        _ = linux.setsid();
        const fork2 = linux.fork();
        if (@as(isize, @bitCast(fork2)) == -1) linux.exit(1);
        if (fork2 == 0) {
            // Grandchild – real daemon
            const pid = linux.getpid();
            var pf = try std.fs.createFileAbsolute(PID_FILE, .{});
            defer pf.close();
            var buf: [20]u8 = undefined;
            const pid_str = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch unreachable;
            _ = try pf.write(pid_str);

            // Open FIFOs and /dev/null for redirection
            const in_fd = try posix.open(IN_FIFO, .{ .ACCMODE = .RDWR }, 0);
            const out_fd = try posix.open(OUT_FIFO, .{ .ACCMODE = .RDWR }, 0);
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
                gitstatusd_ptr,
                "-v",
                "ERROR",
                "-s",
                "-1",
                "-u",
                "-1",
                "-d",
                "-1",
                "-t",
                "8",
            };
            _ = linux.execve(args[0].?, &args, &[_:null]?[*:0]const u8{null});
            // execve failed
            linux.exit(1);
        }
        // intermediate parent exits
        linux.exit(0);
    }
    // parent continues
}

fn stop_server_logic() void {
    if (get_pid_from_file()) |pid| {
        _ = linux.kill(pid, linux.SIG.TERM);
        // Give it a moment to shutdown gracefully
        std.time.sleep(10 * std.time.ns_per_ms);
    }
    // Remove control files
    std.fs.deleteFileAbsolute(PID_FILE) catch {};
    std.fs.deleteFileAbsolute(IN_FIFO) catch {};
    std.fs.deleteFileAbsolute(OUT_FIFO) catch {};
}

fn spawn_reaper(shell_pid: linux.pid_t) !void {
    // Double fork to fully detach
    const fork1 = linux.fork();
    if (@as(isize, @bitCast(fork1)) == -1) return error.SystemResources;
    if (fork1 == 0) {
        const fork2 = linux.fork();
        if (@as(isize, @bitCast(fork2)) == -1) linux.exit(1);
        if (fork2 == 0) {
            // Grandchild – the reaper
            _ = linux.setsid();
            // Close all stdio to avoid holding shell's tty
            posix.close(posix.STDIN_FILENO);
            posix.close(posix.STDOUT_FILENO);
            posix.close(posix.STDERR_FILENO);

            const fd = try posix.open(LOCK_FILE, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = false }, 0o666);
            _ = linux.syscall2(.flock, @as(usize, @bitCast(@as(isize, fd))), 1); // LOCK_SH
            defer posix.close(fd);

            // Wait until the shell PID disappears
            while (linux.kill(shell_pid, 0) == 0) {
                std.time.sleep(5 * std.time.ns_per_s);
            }

            // Shell exited – try to take exclusive lock
            if (linux.syscall2(.flock, @as(usize, @bitCast(@as(isize, fd))), 2 | 4) == 0) { // LOCK_EX | LOCK_NB
                stop_server_logic();
                posix.close(fd);
                std.fs.deleteFileAbsolute(LOCK_FILE) catch {};
            }
            linux.exit(0);
        }
        // Intermediate parent exits
        linux.exit(0);
    }
    // Parent continues
}

pub fn start(allocator: std.mem.Allocator) !void {
    _ = allocator;
    try ensure_dir();

    if (!is_alive()) {
        try start_server();
    }

    // Spawn the reaper that monitors the shell that invoked this command
    const shell_pid = linux.getppid();
    try spawn_reaper(shell_pid);
}

pub fn stop(allocator: std.mem.Allocator) !void {
    _ = allocator;
    // The stop command is used for manual teardown.
    // We don't bother with locks here.
    stop_server_logic();
    std.fs.deleteFileAbsolute(LOCK_FILE) catch {};
}
