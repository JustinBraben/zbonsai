//! main.zig
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

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
    var leavesInput: [128]u8 = @splat('&');
    var tokens = std.mem.tokenizeScalar(u8, &leavesInput, ',');
    while (tokens.next()) |token| {
        if (args.leavesSize < 100) {
            args.leaves[args.leavesSize] = token[0];
            args.leavesSize += 1;
        }
    }

    // Initialize our application
    var buffer: [1024]u8 = undefined;
    var app = try App.init(allocator, args, &buffer);
    defer app.deinit();

    // Run the application
    try app.run();
}

test "Main - run all tests" {
    _ = @import("app.zig");
    _ = @import("args.zig");
    _ = @import("dice.zig");
}