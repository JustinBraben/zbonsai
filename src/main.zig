const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const debug = std.debug;
const print = debug.print;
const io = std.io;
const builtin = std.builtin;

const Args = @import("args.zig");
const App = @import("app.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var args = try Args.parse_args(allocator);
    defer args.deinit();

    // If -h was passed help will be displayed
    // program will exit gracefully
    if (args.help) {
        return;
    }

    // By default leaves will just be '&'
    var leavesInput: [128]u8 = .{'&'} ** 128;
    var tokens = std.mem.tokenize(u8, &leavesInput, ",");
    while (tokens.next()) |token| {
        if (args.leavesSize < 100) {
            args.leaves[args.leavesSize] = token[0];
            args.leavesSize += 1;
        }
    }

    // If seed is 0, assumed that no seed was passed
    // thus give the program a seed based on timestamp
    if (args.seed == 0) {
        args.seed = @as(u64, @intCast(std.time.timestamp()));
    }

    // Initialize our application
    var app = try App.init(allocator, args);
    defer app.deinit();

    // Run the application
    try app.run();
}