const std = @import("std");
const daemon = @import("daemon.zig");
const prompt = @import("prompt.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Version 1.0 \n Usage: tinu10k <daemon|prompt> ...\n", .{});
        return error.InvalidArgs;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "daemon")) {
        if (args.len < 3) {
            std.debug.print("Usage: tinu10k daemon <start|stop>\n", .{});
            return error.InvalidArgs;
        }
        const action = args[2];
        if (std.mem.eql(u8, action, "start")) {
            try daemon.start(allocator);
        } else if (std.mem.eql(u8, action, "stop")) {
            try daemon.stop(allocator);
        } else {
            std.debug.print("Unknown daemon action: {s}\n", .{action});
            return error.InvalidArgs;
        }
    } else if (std.mem.eql(u8, cmd, "prompt")) {
        if (args.len != 5) {
            std.debug.print("Usage: tinu10k prompt <path> <term_width> <allowed_langs>\n", .{});
            return error.InvalidArgs;
        }
        const path = args[2];
        const term_width = try std.fmt.parseInt(usize, args[3], 10);
        const allowed = args[4];
        try prompt.generate(allocator, path, term_width, allowed);
    } else {
        std.debug.print("Unknown command: {s}\n", .{cmd});
        return error.InvalidArgs;
    }
}
