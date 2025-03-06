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
    ignored: bool = false, // Add a field to track if a test is ignored

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
                // Check if test name contains "ignored" or has an @ignore attribute
                .ignored = std.mem.indexOf(u8, test_fn.name, "ignored") != null,
            }
        else
            .{ 
                .function = test_fn.func, 
                .name = test_fn.name,
                .ignored = std.mem.indexOf(u8, test_fn.name, "ignored") != null,
            };
    }

    pub fn run(self: *Test, allocator: std.mem.Allocator, run_ignored: bool) !void {
        // Skip ignored tests unless specifically requested to run them
        if (self.ignored and !run_ignored) {
            self.result = .skipped;
            return;
        }

        std.testing.allocator_instance = .{};
        const start = std.time.nanoTimestamp();

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

        self.duration = @intCast(std.time.nanoTimestamp() - start);

        if (std.testing.allocator_instance.deinit() == .leak) self.leaked = true;
    }

    fn formatStackTrace(self: *Test, maybe_trace: ?*std.builtin.StackTrace) !?[]const u8 {
        return if (maybe_trace) |trace| blk: {
            var stream = std.io.fixedBufferStream(&self.stack_trace_buf);
            const writer = stream.writer();
            try trace.format("", .{}, writer);
            break :blk stream.getWritten();
        } else null;
    }

    pub fn print(self: Test, stream: anytype) !void {
        const writer = stream.writer();

        // Format test name like "module::name"
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
            .failure => |_| {
                try writer.writeAll(red("FAILED"));
            },
            .skipped => {
                try writer.writeAll(yellow("ignored"));
            },
        }

        try writer.writeByte('\n');
    }

    fn printFailureDetail(self: Test, failure: Failure, writer: anytype) !void {
        try writer.print("\nfailures:\n\n", .{});
        
        // Format similar to Rust's failure output
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
    }
};

pub fn main() !void {
    const start = std.time.nanoTimestamp();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var tests = std.ArrayList(Test).init(allocator);
    defer tests.deinit();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    var run_ignored = false;
    if (args.len > 1) {
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--ignored")) {
                run_ignored = true;
                break;
            }
        }
    }

    // Get built-in tests
    const test_fns = builtin.test_functions;
    try tests.ensureTotalCapacity(test_fns.len);
    
    for (test_fns) |test_fn| {
        try tests.append(Test.init(test_fn));
    }

    const stderr = std.io.getStdErr().writer();

    // Print Rust-like header
    try stderr.print("\nrunning {d} tests\n", .{tests.items.len});

    // Run and print tests in Rust style
    for (tests.items) |*current_test| {
        try current_test.run(allocator, run_ignored);
        try current_test.print(std.io.getStdErr());
    }

    try printSummary(tests.items, start);
}

fn printSummary(tests: []const Test, start: i128) !void {
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
    
    const writer = std.io.getStdErr().writer();
    var total_duration_buf: [256]u8 = undefined;
    const total_duration = try duration(
        &total_duration_buf,
        @intCast(std.time.nanoTimestamp() - start),
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
    }

    // Print Rust-like summary line
    try writer.print("\ntest result: ", .{});
    
    if (failure == 0 and leaked == 0) {
        try writer.print("{s}. ", .{green("ok")});
    } else {
        try writer.print("{s}. ", .{red("FAILED")});
    }
    
    try writer.print("{d} passed; {d} failed; {d} ignored; 0 measured; 0 filtered out; finished in {s}\n\n", 
        .{success, failure, skipped, total_duration});

    if (leaked > 0) {
        try writer.print("\n{d} tests leaked memory\n", .{leaked});
    }

    // TODO: Doc-tests section like in Rust
    // try writer.print("   Doc-tests\n\n", .{});
    // try writer.print("running 0 tests\n\n", .{});
    // try writer.print("test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n", .{});

    if (failure == 0 and leaked == 0) {
        std.process.exit(0);
    } else {
        std.process.exit(1);
    }
}

fn indent(message: []const u8, comptime indent_sequence: []const u8, writer: anytype) !void {
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
pub fn colorize(color: std.io.tty.Color, buf: []u8, input: []const u8, is_colorized: bool) ![]const u8 {
    if (!is_colorized) return input;

    const config: std.io.tty.Config = .escape_codes;
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    try config.setColor(writer, color);
    try writer.writeAll(input);
    try config.setColor(writer, .reset);

    return stream.getWritten();
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

pub fn duration(buf: *[256]u8, delta: i64, is_colorized: bool) ![]const u8 {
    if (!is_colorized) {
        return try std.fmt.bufPrint(
            buf,
            "{}",
            .{std.fmt.fmtDurationSigned(delta)},
        );
    }

    const color: std.io.tty.Color = if (delta < 1000000)
        .green
    else if (delta < 5000000)
        .yellow
    else
        .red;
    var duration_buf: [256]u8 = undefined;
    const formatted_duration = try std.fmt.bufPrint(
        &duration_buf,
        "{}",
        .{std.fmt.fmtDurationSigned(delta)},
    );
    return try colorize(color, buf, formatted_duration, true);
}
