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

    // Initialize our application
    var buffer: [1024]u8 = undefined;
    var app = try App.init(allocator, &args, &buffer);
    defer app.deinit();

    // Run the application
    try app.run();
}

test "Main - run all tests" {
    _ = @import("app.zig");
    _ = @import("args.zig");
    _ = @import("dice.zig");
}