//! test/test_runner.zig
//! Credit `jetzig` for this test_runner code

const std = @import("std");
const builtin = @import("builtin");

const Test = struct {
    name: []const u8,
    function: TestFn,
    module: ?[]const u8 = null,
    leaked: bool = false,
    result: Result = .success,
    stack_trace_buf: [8192]u8 = undefined,
    duration: usize = 0,
    ignored: bool = false,

    pub const TestFn = *const fn () anyerror!void;
    pub const Result = union(enum) {
        success: void,
        failure: Failure,
        skipped: void,
    };

    const Failure = struct {
        err: anyerror,
        trace: ?[]const u8,
    };

    pub fn init(test_fn: std.builtin.TestFn) Test {
        return if (std.mem.indexOf(u8, test_fn.name, ".test.")) |index|
            .{
                .function = test_fn.func,
                .module = test_fn.name[0..index],
                .name = test_fn.name[index + ".test.".len ..],
                .ignored = std.mem.indexOf(u8, test_fn.name, "ignored") != null,
            }
        else
            .{
                .function = test_fn.func,
                .name = test_fn.name,
                .ignored = std.mem.indexOf(u8, test_fn.name, "ignored") != null,
            };
    }

    pub fn run(self: *Test, allocator: std.mem.Allocator, run_ignored: bool, io: std.Io) !void {
        if (self.ignored and !run_ignored) {
            self.result = .skipped;
            return;
        }

        std.testing.allocator_instance = .init;
        const start = std.Io.Clock.now(.real, io).nanoseconds;

        self.function() catch |err| {
            switch (err) {
                error.SkipZigTest => self.result = .skipped,
                else => self.result = .{ .failure = .{
                    .err = err,
                    .trace = if (try self.formatStackTrace(@errorReturnTrace())) |trace|
                        try allocator.dupe(u8, trace)
                    else
                        null,
                } },
            }
        };

        self.duration = @intCast(std.Io.Clock.now(.real, io).nanoseconds - start);

        if (std.testing.allocator_instance.deinit() == .leak) self.leaked = true;
    }

    fn formatStackTrace(self: *Test, maybe_trace: ?*std.builtin.StackTrace) !?[]const u8 {
        return if (maybe_trace) |trace| blk: {
            var writer = std.Io.Writer.fixed(&self.stack_trace_buf);
            const terminal: std.Io.Terminal = .{ .writer = &writer, .mode = .escape_codes };
            try std.debug.writeErrorReturnTrace(trace, terminal);
            break :blk writer.buffered();
        } else null;
    }

    pub fn print(self: Test, writer: *std.Io.Writer) !void {
        const full_name = if (self.module) |module|
            try std.fmt.allocPrint(std.heap.page_allocator, "{s}::{s}", .{ module, self.name })
        else
            self.name;
        defer if (self.module != null) std.heap.page_allocator.free(full_name);

        try writer.print("test {s} ... ", .{full_name});

        switch (self.result) {
            .success => {
                try writer.writeAll(green("ok"));
                if (self.leaked) try writer.writeAll(red(" [LEAKED]"));
            },
            .failure => {
                try writer.writeAll(red("FAILED"));
            },
            .skipped => {
                try writer.writeAll(yellow("ignored"));
            },
        }

        try writer.writeByte('\n');
        try writer.flush();
    }

    fn printFailureDetail(self: Test, failure: Failure, writer: *std.Io.Writer) !void {
        try writer.print("\nfailures:\n\n", .{});

        const full_name = if (self.module) |module|
            try std.fmt.allocPrint(std.heap.page_allocator, "{s}::{s}", .{ module, self.name })
        else
            self.name;
        defer if (self.module != null) std.heap.page_allocator.free(full_name);

        try writer.print("---- {s} ----\n", .{full_name});
        try writer.print("Error: {s}\n", .{@errorName(failure.err)});

        if (failure.trace) |trace| {
            try writer.print("\n{s}\n", .{trace});
        }
        try writer.flush();
    }
};

pub fn main(init: std.process.Init) !void {
    const start = std.Io.Clock.now(.real, init.io).nanoseconds;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tests: std.ArrayList(Test) = .empty;
    defer tests.deinit(allocator);

    // Parse command line arguments using the new Args API
    var run_ignored = false;
    var args_it = try init.minimal.args.iterateAllocator(allocator);
    defer args_it.deinit();
    // Skip program name
    _ = args_it.next();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ignored")) {
            run_ignored = true;
            break;
        }
    }

    // Get built-in tests
    const test_fns = builtin.test_functions;
    try tests.ensureTotalCapacity(allocator, test_fns.len);

    for (test_fns) |test_fn| {
        try tests.append(allocator, Test.init(test_fn));
    }

    // Use new std.Io writer with larger buffer
    const stderr_file: std.Io.File = .stderr();
    var buf: [8192]u8 = undefined; // Increased buffer size
    var stderr_writer = stderr_file.writer(init.io, &buf);
    const writer = &stderr_writer.interface;

    // Print Rust-like header
    try writer.print("\nrunning {d} tests\n", .{tests.items.len});
    try writer.flush();

    // Run and print tests in Rust style
    for (tests.items) |*current_test| {
        try current_test.run(allocator, run_ignored, init.io);
        try current_test.print(writer);
    }

    try printSummary(tests.items, start, init.io, writer);
}

fn printSummary(tests: []const Test, start: i96, io: std.Io, writer: *std.Io.Writer) !void {
    var success: usize = 0;
    var failure: usize = 0;
    var leaked: usize = 0;
    var skipped: usize = 0;

    for (tests) |t| {
        switch (t.result) {
            .success => success += 1,
            .failure => failure += 1,
            .skipped => skipped += 1,
        }
        if (t.leaked) leaked += 1;
    }

    var total_duration_buf: [1024]u8 = undefined;
    const total_duration = try duration(
        &total_duration_buf,
        @intCast(std.Io.Clock.now(.real, io).nanoseconds - start),
        false,
    );

    // Print test failures in detail
    var has_failures = false;
    for (tests) |t| {
        switch (t.result) {
            .success, .skipped => {},
            .failure => |capture| {
                if (!has_failures) has_failures = true;
                try t.printFailureDetail(capture, writer);
            },
        }
    }

    if (has_failures) {
        try writer.print("\nfailures:\n", .{});
        for (tests) |t| {
            if (t.result == .failure) {
                const full_name = if (t.module) |module|
                    try std.fmt.allocPrint(std.heap.page_allocator, "{s}::{s}", .{ module, t.name })
                else
                    t.name;
                defer if (t.module != null) std.heap.page_allocator.free(full_name);

                try writer.print("    {s}\n", .{full_name});
            }
        }
        try writer.flush();
    }

    // Print Rust-like summary line
    try writer.print("\ntest result: ", .{});

    if (failure == 0 and leaked == 0) {
        try writer.print("{s}. ", .{green("ok")});
    } else {
        try writer.print("{s}. ", .{red("FAILED")});
    }

    try writer.print("{d} passed; {d} failed; {d} ignored; 0 measured; 0 filtered out; finished in {s}\n\n", .{ success, failure, skipped, total_duration });

    if (leaked > 0) {
        try writer.print("\n{d} tests leaked memory\n", .{leaked});
    }

    try writer.flush();

    if (failure == 0 and leaked == 0) {
        std.process.exit(0);
    } else {
        std.process.exit(1);
    }
}

fn indent(message: []const u8, comptime indent_sequence: []const u8, writer: *std.Io.Writer) !void {
    var it = std.mem.tokenizeScalar(u8, message, '\n');
    var color: ?[]const u8 = null;

    const escape = codes.escape;

    while (it.next()) |line| {
        try writer.print(indent_sequence ++ "{s}{s}\n", .{ color orelse "", line });

        // Preserve last color used in previous line (including reset) in case indent changes color.
        if (std.mem.lastIndexOf(u8, line, escape)) |index| {
            inline for (std.meta.fields(@TypeOf(codes))) |field| {
                const code = @field(codes, field.name);
                if (std.mem.startsWith(u8, line[index..], escape ++ code)) {
                    color = escape ++ code;
                }
            }
        }
    }
}

/// Colorize a log message. Note that we force `.escape_codes` when we are a TTY even on Windows.
/// Credit `jetzig`
pub fn colorize(color: std.Io.Terminal.Color, buf: []u8, input: []const u8, is_colorized: bool) ![]const u8 {
    if (!is_colorized) return input;
    var writer = std.Io.Writer.fixed(buf);
    const terminal: std.Io.Terminal = .{ .writer = &writer, .mode = .escape_codes };
    try terminal.setColor(color);
    try writer.writeAll(input);
    try terminal.setColor(.reset);
    return writer.buffered();
}

// Color utility functions
pub fn wrap(comptime attribute: []const u8, comptime message: []const u8) []const u8 {
    return codes.escape ++ attribute ++ message ++ codes.escape ++ codes.reset;
}

pub fn green(comptime message: []const u8) []const u8 {
    return wrap(codes.green, message);
}

pub fn red(comptime message: []const u8) []const u8 {
    return wrap(codes.red, message);
}

pub fn yellow(comptime message: []const u8) []const u8 {
    return wrap(codes.yellow, message);
}

// ANSI color codes
pub const codes = .{
    .escape = "\x1b[",
    .black = "30m",
    .red = "31m",
    .green = "32m",
    .yellow = "33m",
    .blue = "34m",
    .magenta = "35m",
    .cyan = "36m",
    .white = "37m",
    .reset = "0m",
};

fn formatNs(buf: []u8, ns: i64) ![]const u8 {
    const abs: u64 = @intCast(if (ns < 0) -ns else ns);
    if (abs < 1_000) {
        return std.fmt.bufPrint(buf, "{}ns", .{ns});
    } else if (abs < 1_000_000) {
        return std.fmt.bufPrint(buf, "{d:.3}µs", .{@as(f64, @floatFromInt(ns)) / 1_000.0});
    } else if (abs < 1_000_000_000) {
        return std.fmt.bufPrint(buf, "{d:.3}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0});
    } else {
        return std.fmt.bufPrint(buf, "{d:.3}s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0});
    }
}

pub fn duration(buf: *[1024]u8, delta: i64, is_colorized: bool) ![]const u8 {
    var ns_buf: [32]u8 = undefined;
    const ns_str = try formatNs(&ns_buf, delta);

    if (!is_colorized) {
        return std.fmt.bufPrint(buf, "{s}", .{ns_str});
    }

    const color: std.Io.Terminal.Color = if (delta < 1_000_000)
        .green
    else if (delta < 5_000_000)
        .yellow
    else
        .red;

    return try colorize(color, buf, ns_str, true);
}
