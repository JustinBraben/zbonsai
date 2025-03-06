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

    const name_template = blue("{s}") ++ yellow("::") ++ "\"" ++ cyan("{s}") ++ "\" ";

    pub fn init(test_fn: std.builtin.TestFn) Test {
        return if (std.mem.indexOf(u8, test_fn.name, ".test.")) |index|
            .{
                .function = test_fn.func,
                .module = test_fn.name[0..index],
                .name = test_fn.name[index + ".test.".len ..],
            }
        else
            .{ .function = test_fn.func, .name = test_fn.name };
    }

    pub fn run(self: *Test, allocator: std.mem.Allocator) !void {
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

        switch (self.result) {
            .success => {
                try self.printPassed(writer);
                if (self.leaked) try self.printLeaked(writer);
                try self.printDuration(writer);
            },
            .failure => |failure| {
                try self.printFailure(failure, writer);
                if (self.leaked) try self.printLeaked(writer);
            },
            .skipped => try self.printSkipped(writer),
        }

        try writer.writeByte('\n');
    }

    fn printPassed(self: Test, writer: anytype) !void {
        try writer.print(
            green("[PASS] ") ++ name_template,
            .{ self.module orelse "tests", self.name },
        );
    }

    fn printFailure(self: Test, failure: Failure, writer: anytype) !void {
        try writer.print(
            red("[FAIL] ") ++ name_template ++ yellow("({s})"),
            .{ self.module orelse "tests", self.name, @errorName(failure.err) },
        );
    }

    fn printFailureDetail(self: Test, failure: Failure, writer: anytype) !void {
        try writer.print("\n", .{});

        const count = " FAILURE: ".len + (self.module orelse "tests").len + ":".len + self.name.len + 4;

        try writer.writeAll(red("┌"));
        for (0..count) |_| try writer.writeAll(red("─"));
        try writer.writeAll(red("┐"));

        try writer.print(
            red("\n│ FAILURE: ") ++ name_template ++ red("│") ++ "\n",
            .{ self.module orelse "tests", self.name },
        );
        try writer.writeAll(red("├"));
        for (0..count) |_| try writer.writeAll(red("─"));
        try writer.writeAll(red("┘"));
        try writer.writeByte('\n');

        if (failure.trace) |trace| {
            try writer.writeAll(red("┆\n"));
            try indent(trace, red("┆ "), writer);
        }
    }

    fn printSkipped(self: Test, writer: anytype) !void {
        try writer.print(
            "[" ++ yellow("SKIP") ++ "]" ++ name_template,
            .{ self.module orelse "tests", self.name },
        );
    }

    fn printLeaked(self: Test, writer: anytype) !void {
        _ = self;
        try writer.print("[" ++ red("LEAKED") ++ "] ", .{});
    }

    fn printDuration(self: Test, writer: anytype) !void {
        var buf: [256]u8 = undefined;
        try writer.print(
            "[" ++ cyan("{s}") ++ "]",
            .{try duration(&buf, @intCast(self.duration), true)},
        );
    }
};

pub fn main() !void {
    const start = std.time.nanoTimestamp();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var tests = std.ArrayList(Test).init(allocator);
    defer tests.deinit();

    try std.io.getStdErr().writer().writeAll("\n Launching Test Runner...\n\n");

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
    const tick = green("✔");
    const cross = red("✗");

    const writer = std.io.getStdErr().writer();

    var total_duration_buf: [256]u8 = undefined;
    const total_duration = try duration(
        &total_duration_buf,
        @intCast(std.time.nanoTimestamp() - start),
        false,
    );

    for (tests) |t| {
        switch (t.result) {
            .success, .skipped => {},
            .failure => |capture| try t.printFailureDetail(capture, writer),
        }
    }

    try writer.print(
        "\n {s}{s}{}" ++
            "\n {s}{s}{}" ++
            "\n  {s}{}" ++
            "\n " ++ cyan("    tests ") ++ "{}" ++
            "\n " ++ cyan(" duration ") ++ "{s}" ++ "\n\n",
        .{
            if (failure == 0) tick else cross,
            if (failure == 0) blue("  failed ") else red("  failed "),
            failure,
            if (leaked == 0) tick else cross,
            if (leaked == 0) blue("  leaked ") else red("  leaked "),
            leaked,
            if (skipped == 0) blue(" skipped ") else yellow(" skipped "),
            skipped,
            success + failure,
            total_duration,
        },
    );

    if (failure == 0 and leaked == 0) {
        try writer.print(green("      PASS   ") ++ "\n", .{});
        try writer.print(green("      ▔▔▔▔") ++ "\n", .{});
        std.process.exit(0);
    } else {
        try writer.print(red("      FAIL   ") ++ "\n", .{});
        try writer.print(red("      ▔▔▔▔") ++ "\n", .{});
        try writer.print("Server logs: " ++ cyan("log/test.log") ++ "\n\n", .{});
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

pub const Color = enum {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
};

// Must be consistent with `std.io.tty.Color` for Windows compatibility.
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
    .bright_black = "90m",
    .bright_red = "91m",
    .bright_green = "92m",
    .bright_yellow = "93m",
    .bright_blue = "94m",
    .bright_magenta = "95m",
    .bright_cyan = "96m",
    .bright_white = "97m",
    .bold = "1m",
    .dim = "2m",
    .reset = "0m",
};

/// Map color codes generated by `std.io.tty.Config.setColor` back to `std.io.tty.Color`
const ansi_colors = .{
    .{ "30", .black },
    .{ "31", .red },
    .{ "32", .green },
    .{ "33", .yellow },
    .{ "34", .blue },
    .{ "35", .magenta },
    .{ "36", .cyan },
    .{ "37", .white },
    .{ "90", .bright_black },
    .{ "91", .bright_red },
    .{ "92", .bright_green },
    .{ "93", .bright_yellow },
    .{ "94", .bright_blue },
    .{ "95", .bright_magenta },
    .{ "96", .bright_cyan },
    .{ "97", .bright_white },
    .{ "1", .bold },
    .{ "2", .dim },
    .{ "0", .reset },
};
pub const codes_map = std.StaticStringMap(std.io.tty.Color).initComptime(ansi_colors);

// Map basic ANSI color codes to Windows TextAttribute colors
// used by std.os.windows.SetConsoleTextAttribute()
const windows_colors = .{
    .{ "30", 0 },
    .{ "31", 4 },
    .{ "32", 2 },
    .{ "33", 6 },
    .{ "34", 1 },
    .{ "35", 5 },
    .{ "36", 3 },
    .{ "37", 7 },
    .{ "90", 8 },
    .{ "91", 12 },
    .{ "92", 10 },
    .{ "93", 14 },
    .{ "94", 9 },
    .{ "95", 13 },
    .{ "96", 11 },
    .{ "97", 15 },
    .{ "1", 7 },
    .{ "2", 7 },
    .{ "0", 7 },
};
pub const windows_map = std.StaticStringMap(u16).initComptime(windows_colors);

/// Colorize a log message. Note that we force `.escape_codes` when we are a TTY even on Windows.
/// `jetzig.loggers.LogQueue` parses the ANSI codes and uses `std.io.tty.Config.setColor` to
/// invoke the appropriate Windows API call to set the terminal color before writing each token.
/// We must do it this way because Windows colors are set by API calls at the time of write, not
/// encoded into the message string.
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

fn wrap(comptime attribute: []const u8, comptime message: []const u8) []const u8 {
    return codes.escape ++ attribute ++ message ++ codes.escape ++ codes.reset;
}

fn runtimeWrap(allocator: std.mem.Allocator, attribute: []const u8, message: []const u8) ![]const u8 {
    return try std.mem.join(
        allocator,
        "",
        &[_][]const u8{ codes.escape, attribute, message, codes.escape, codes.reset },
    );
}

pub fn bold(comptime color: Color, comptime message: []const u8) []const u8 {
    return codes.escape ++ @field(codes, @tagName(color)) ++ codes.escape ++ codes.bold ++ message ++ codes.escape ++ codes.reset;
}

pub fn black(comptime message: []const u8) []const u8 {
    return wrap(codes.black, message);
}

pub fn runtimeBlack(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    return try runtimeWrap(allocator, codes.black, message);
}

pub fn red(comptime message: []const u8) []const u8 {
    return wrap(codes.red, message);
}

pub fn runtimeRed(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    return try runtimeWrap(allocator, codes.red, message);
}

pub fn green(comptime message: []const u8) []const u8 {
    return wrap(codes.green, message);
}

pub fn runtimeGreen(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    return try runtimeWrap(allocator, codes.green, message);
}

pub fn yellow(comptime message: []const u8) []const u8 {
    return wrap(codes.yellow, message);
}

pub fn runtimeYellow(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    return try runtimeWrap(allocator, codes.yellow, message);
}

pub fn blue(comptime message: []const u8) []const u8 {
    return wrap(codes.blue, message);
}

pub fn runtimeBlue(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    return try runtimeWrap(allocator, codes.blue, message);
}

pub fn magenta(comptime message: []const u8) []const u8 {
    return wrap(codes.magenta, message);
}

pub fn runtimeMagenta(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    return try runtimeWrap(allocator, codes.magenta, message);
}

pub fn cyan(comptime message: []const u8) []const u8 {
    return wrap(codes.cyan, message);
}

pub fn runtimeCyan(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    return try runtimeWrap(allocator, codes.cyan, message);
}

pub fn white(comptime message: []const u8) []const u8 {
    return wrap(codes.white, message);
}

pub fn runtimeWhite(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    return try runtimeWrap(allocator, codes.white, message);
}

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
