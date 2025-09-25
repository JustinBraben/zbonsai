//! args.zig
const std = @import("std");
const io = std.io;
const Allocator = std.mem.Allocator;
const clap = @import("clap");

const Args = @This();

pub const ArgsError = error{
    NotImplemented,
    MultiplierOutOfRange,
    InvalidSeed,
};

pub const Verbosity = enum(u16) {
    none = 0,
    minimal = 1,
    detailed = 2,
};

pub const BaseType = enum {
    none,
    small,
    large,
};

allocator: Allocator,

help: bool = false,

live: bool = false,
infinite: bool = false,
screensaver: bool = false,
printTree: bool = false,
verbosity: Verbosity,
lifeStart: usize = 32,
multiplier: usize = 5,
baseType: BaseType,
seed: ?u64,
leavesSize: usize = 0,
targetBranchCount: usize = 0,

timeWait: f32,
timeStep: f32,

message: ?[]const u8 = null,
leaves: [64]u8,

load: bool = false,
save: bool = false,

saveFile: []const u8,
loadFile: []const u8,

pub fn parse_args(ally: Allocator) !Args {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Display this help and exit.
        \\-l, --live                Live mode: show each step of growth
        \\-t, --time <TIME>         In Live mode, wait TIME secs between
        \\                          steps of growth (must be larger than 0) [default: 0.03].
        \\
        \\-i, --infinite            Infinite mode: keep growing trees.
        \\-w, --wait <TIME>         In infinite mode, wait TIME between each tree
        \\                          generation [default: 4.00].
        \\
        \\-S, --screensaver         Screensaver mode; equivalent to -li and
        \\                          quit on any keypress.
        \\
        \\-m, --message <STR>       Attach message next to the tree.
        \\-b, --base <BASETYPE>     Ascii-art plant base to use, 0 is none.
        \\-c, --leaf <STR>          List of comma-delimited strings randomly chosen
        \\                          for leaves.
        \\
        \\-M, --multiplier <USIZE>  Branch multiplier; higher -> more
        \\                          branching (0-20) [default: 5].
        \\
        \\-L, --life <USIZE>        Life; higher -> more growth (0-200) [default: 32].
        \\-p, --print               Print tree to terminal when finished.
        \\-s, --seed <U64>          Seed random number generator.
        \\-W, --save <FILE>         Save progress to file [default: ~/.cache/cbonsai].
        \\-C, --load <FILE>         Load progress from file [default: ~/.cache/cbonsai].
        \\-v, --verbose <VERBOSITY> Increase output verbosity.
        \\<FILE>...
        \\
    );

    // Declare our own parsers which are used to map the argument strings to other
    // types.
    const parsers = comptime .{
        .STR = clap.parsers.string,
        .FILE = clap.parsers.string,
        .INT = clap.parsers.int(i64, 10),
        .U64 = clap.parsers.int(u64, 10),
        .USIZE = clap.parsers.int(usize, 10),
        .F32 = clap.parsers.float(f32),
        .TIME = clap.parsers.float(f32),
        .BASETYPE = clap.parsers.enumeration(BaseType),
        .VERBOSITY = clap.parsers.enumeration(Verbosity),
    };

    // const stderr_file = std.fs.File.stderr();
    // var buf: [1024]u8 = undefined;
    // var stderr_writer = stderr_file.writer(&buf);
    // const stderr_writer_interface: *std.io.Writer = &stderr_writer.interface;

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = ally,
    }) catch |err| {
         try diag.reportToFile(std.fs.File.stderr(), err);
        return err;
    };
    defer res.deinit();

    // Return errors on args not yet implemented
    if (res.args.infinite != 0 or
        res.args.screensaver != 0)
    {
        return ArgsError.NotImplemented;
    }

    // Write help if -h was passed
    if (res.args.help != 0) {
        try clap.helpToFile(.stderr(), clap.Help, &params, .{});
    }

    var multiplier: usize = 5;
    if (res.args.multiplier) |m| {
        if (m < 0 or m > 20) {
            return ArgsError.MultiplierOutOfRange;
        }
        multiplier = m;
    }

    var message: ?[]const u8 = null;
    if (res.args.message) |msg| {
        message = try std.fmt.allocPrint(ally, "{s}", .{msg});
    }

    var baseType: BaseType = .large;
    if (res.args.base) |bs|
        baseType = bs;

    var lifeStart: usize = 32;
    if (res.args.life) |ls|
        lifeStart = ls;

    var seed: ?u64 = null;
    if (res.args.seed) |s| {
        if (s == 0) return ArgsError.InvalidSeed;
        seed = s;
    } else {
        // If seed is null, no seed was passed
        // thus give the program a seed based on timestamp
        seed = @as(u64, @intCast(std.time.timestamp()));
    }

    var timeStep: f32 = 0.03;
    if (res.args.time) |ts|
        timeStep = ts;

    var save = false;
    var saveFile = try createDefaultCachePath(ally);
    if (res.args.save) |save_file| {
        ally.free(saveFile);
        saveFile = try ally.dupe(u8, save_file);
        save = true;
    }

    var load = false;
    var loadFile = try createDefaultCachePath(ally);
    if (res.args.load) |load_file| {
        ally.free(loadFile);
        loadFile = try ally.dupe(u8, load_file);
        load = true;
    }

    var verbosity = Verbosity.none;
    if (res.args.verbose) |v|
        verbosity = v;

    return Args{
        .allocator = ally,
        .help = res.args.help != 0,
        .live = res.args.live != 0,
        .infinite = res.args.infinite != 0,
        .screensaver = res.args.screensaver != 0,
        .printTree = res.args.print != 0,
        .verbosity = verbosity,
        .lifeStart = lifeStart,
        .multiplier = multiplier,
        .baseType = baseType,
        .seed = seed,
        .leavesSize = 0,
        .targetBranchCount = 0,

        .timeWait = 4,
        .timeStep = timeStep,

        .message = message,
        .leaves = @splat(0),

        .save = save,
        .load = load,

        .saveFile = saveFile,
        .loadFile = loadFile,
    };
}

pub fn deinit(self: *Args) void {
    if (self.message) |msg| {
        self.allocator.free(msg);
    }
    self.allocator.free(self.saveFile);
    self.allocator.free(self.loadFile);
}

fn createDefaultCachePath(ally: Allocator) ![]u8 {
    const toAppend = "cbonsai";
    const res = try ally.alloc(u8, toAppend.len);
    @memcpy(res, toAppend);
    return res;
}

// TODO: implement saveToFile
fn saveToFile(ally: Allocator, file_name: []const u8, seed: u64, branchCount: u64) !void {
    const file = try std.fs.cwd().createFile(file_name, .{ .read = true });
    defer file.close();

    const content = try std.fmt.allocPrint(ally, "{d} {d}", .{ seed, branchCount });
    defer ally.free(content);

    _ = try file.writeAll(content);
}

// TODO: implement loadFromFile
fn loadFromFile(self: *Args, file_name: []const u8) !void {
    const file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();

    var buffer: [100]u8 = undefined;
    try file.seekTo(0);
    const bytes_read = try file.readAll(&buffer);
    
    if (bytes_read == 0) {
        return error.EmptyFile;
    }
    
    var tokens = std.mem.tokenizeScalar(u8, buffer[0..bytes_read], ' ');
    
    const seed_str = tokens.next() orelse return error.InvalidFileFormat;
    const branch_count_str = tokens.next() orelse return error.InvalidFileFormat;
    
    self.seed = try std.fmt.parseInt(u64, seed_str, 10);
    self.targetBranchCount = try std.fmt.parseInt(usize, branch_count_str, 10);
}

fn parseMockCommandLine(allocator: std.mem.Allocator, mock_args: []const []const u8) !Args {
    // Create a SliceIterator that will simulate argv
    var iter = clap.args.SliceIterator{
        .args = mock_args,
    };

    // Parse using the same parameters and parsers defined in Args.parse_args
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Display this help and exit.
        \\-l, --live                Live mode: show each step of growth
        \\-t, --time <TIME>         In Live mode, wait TIME secs between
        \\                          steps of growth (must be larger than 0) [default: 0.03].
        \\
        \\-i, --infinite            Infinite mode: keep growing trees.
        \\-w, --wait <TIME>         In infinite mode, wait TIME between each tree
        \\                          generation [default: 4.00].
        \\
        \\-S, --screensaver         Screensaver mode; equivalent to -li and
        \\                          quit on any keypress.
        \\
        \\-m, --message <STR>       Attach message next to the tree.
        \\-b, --base <BASETYPE>     Ascii-art plant base to use, 0 is none.
        \\-c, --leaf <STR>          List of comma-delimited strings randomly chosen
        \\                          for leaves.
        \\
        \\-M, --multiplier <USIZE>  Branch multiplier; higher -> more
        \\                          branching (0-20) [default: 5].
        \\
        \\-L, --life <USIZE>        Life; higher -> more growth (0-200) [default: 32].
        \\-p, --print               Print tree to terminal when finished.
        \\-s, --seed <U64>          Seed random number generator.
        \\-W, --save <FILE>         Save progress to file [default: ~/.cache/cbonsai].
        \\-C, --load <FILE>         Load progress from file [default: ~/.cache/cbonsai].
        \\-v, --verbose <VERBOSITY> Increase output verbosity.
        \\<FILE>...
        \\
    );

    const parsers = comptime .{
        .STR = clap.parsers.string,
        .FILE = clap.parsers.string,
        .INT = clap.parsers.int(i64, 10),
        .U64 = clap.parsers.int(u64, 10),
        .USIZE = clap.parsers.int(usize, 10),
        .F32 = clap.parsers.float(f32),
        .TIME = clap.parsers.float(f32),
        .BASETYPE = clap.parsers.enumeration(BaseType),
        .VERBOSITY = clap.parsers.enumeration(Verbosity),
    };

    var diag = clap.Diagnostic{};
    var res = try clap.parseEx(clap.Help, &params, parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    });
    defer res.deinit();

    // Return errors on args not yet implemented
    if (res.args.infinite != 0 or
        res.args.screensaver != 0)
    {
        return ArgsError.NotImplemented;
    }

    var multiplier: usize = 5;
    if (res.args.multiplier) |m| {
        if (m < 0 or m > 20) {
            return ArgsError.MultiplierOutOfRange;
        }
        multiplier = m;
    }

    var message: ?[]const u8 = null;
    if (res.args.message) |msg| {
        message = try std.fmt.allocPrint(allocator, "{s}", .{msg});
    }

    var baseType: BaseType = .large;
    if (res.args.base) |bs|
        baseType = bs;

    var lifeStart: usize = 32;
    if (res.args.life) |ls|
        lifeStart = ls;

    var seed: ?u64 = null;
    if (res.args.seed) |s| {
        if (s == 0) return ArgsError.InvalidSeed;
        seed = s;
    } else {
        // If seed is null, no seed was passed
        // thus give the program a seed based on timestamp
        seed = @as(u64, @intCast(std.time.timestamp()));
    }

    var timeStep: f32 = 0.03;
    if (res.args.time) |ts|
        timeStep = ts;

    var save = false;
    var saveFile = try createDefaultCachePath(allocator);
    if (res.args.save) |save_file| {
        allocator.free(saveFile);
        saveFile = try allocator.dupe(u8, save_file);
        save = true;
    }

    var load = false;
    var loadFile = try createDefaultCachePath(allocator);
    if (res.args.load) |load_file| {
        allocator.free(loadFile);
        loadFile = try allocator.dupe(u8, load_file);
        load = true;
    }

    var verbosity = Verbosity.none;
    if (res.args.verbose) |v|
        verbosity = v;

    return Args{
        .allocator = allocator,
        .help = res.args.help != 0,
        .live = res.args.live != 0,
        .infinite = res.args.infinite != 0,
        .screensaver = res.args.screensaver != 0,
        .printTree = res.args.print != 0,
        .verbosity = verbosity,
        .lifeStart = lifeStart,
        .multiplier = multiplier,
        .baseType = baseType,
        .seed = seed,
        .leavesSize = 0,
        .targetBranchCount = 0,

        .timeWait = 4,
        .timeStep = timeStep,

        .message = message,
        .leaves = std.mem.zeroes([64]u8),

        .save = save,
        .load = load,

        .saveFile = saveFile,
        .loadFile = loadFile,
    };
}

test "Args parsing - default values" {
    const test_alloc = std.testing.allocator;
    
    // Test with empty/minimal arguments
    var empty_args = try Args.parse_args(test_alloc);
    defer empty_args.deinit();
    
    try std.testing.expectEqual(false, empty_args.help);
    try std.testing.expectEqual(false, empty_args.live);
    try std.testing.expectEqual(Verbosity.none, empty_args.verbosity);
    try std.testing.expectEqual(@as(usize, 32), empty_args.lifeStart);
    try std.testing.expectEqual(@as(usize, 5), empty_args.multiplier);
    try std.testing.expectEqual(BaseType.large, empty_args.baseType);
}

test "Args parsing - explicit values" {
    const test_alloc = std.testing.allocator;
    
    // Mock command line arguments
    const args = [_][]const u8{ "zbonsai", "--live", "--multiplier", "10", "--seed", "42" };
    
    var parsed_args = try parseMockCommandLine(test_alloc, &args);
    defer parsed_args.deinit();
    
    try std.testing.expectEqual(true, parsed_args.live);
    try std.testing.expectEqual(@as(usize, 10), parsed_args.multiplier);
    try std.testing.expectEqual(@as(u64, 42), parsed_args.seed.?);
}

test "Args parsing - error handling - invalid multiplier" {
    const test_alloc = std.testing.allocator;
    
    // Mock command line with invalid multiplier value
    const args = [_][]const u8{ "zbonsai", "--multiplier", "25" }; // Above maximum of 20
    
    // This should return MultiplierOutOfRange error
    try std.testing.expectError(ArgsError.MultiplierOutOfRange, parseMockCommandLine(test_alloc, &args));
}

test "Args parsing - error handling - invalid seed" {
    const test_alloc = std.testing.allocator;
    
    // Mock command line with invalid seed value
    const args = [_][]const u8{ "zbonsai", "--seed", "0" }; // Invalid seed
    
    try std.testing.expectError(ArgsError.InvalidSeed, parseMockCommandLine(test_alloc, &args));
}

test "Args memory management - with message" {
    const test_alloc = std.testing.allocator;
    
    // Test with message allocation
    const mock_args = [_][]const u8{ "zbonsai", "--message", "Hello World" };
    var args = try parseMockCommandLine(test_alloc, &mock_args);
    defer args.deinit();
    
    try std.testing.expect(args.message != null);
    try std.testing.expectEqualStrings("Hello World", args.message.?);
}

test "Args - save file path" {
    const test_alloc = std.testing.allocator;
    
    const mock_args = [_][]const u8{ "zbonsai", "--save", "./test_save_path.dat" };
    var args = try parseMockCommandLine(test_alloc, &mock_args);
    defer args.deinit();
    
    try std.testing.expectEqualStrings("./test_save_path.dat", args.saveFile);
    try std.testing.expect(args.save);
    try std.testing.expectEqualStrings("cbonsai", args.loadFile); // Default path
    try std.testing.expect(!args.load);
}

test "Args - load file path" {
    const test_alloc = std.testing.allocator;
    
    const mock_args = [_][]const u8{ "zbonsai", "--load", "./test_load_path.dat" };
    var args = try parseMockCommandLine(test_alloc, &mock_args);
    defer args.deinit();
    
    try std.testing.expectEqualStrings("./test_load_path.dat", args.loadFile);
    try std.testing.expect(args.load);
    try std.testing.expectEqualStrings("cbonsai", args.saveFile); // Default path
    try std.testing.expect(!args.save);
}

test "Args - both save and load file paths" {
    const test_alloc = std.testing.allocator;
    
    const mock_args = [_][]const u8{ 
        "zbonsai", 
        "--save", "./test_save_both.dat", 
        "--load", "./test_load_both.dat" 
    };
    var args = try parseMockCommandLine(test_alloc, &mock_args);
    defer args.deinit();
    
    try std.testing.expectEqualStrings("./test_save_both.dat", args.saveFile);
    try std.testing.expect(args.save);
    try std.testing.expectEqualStrings("./test_load_both.dat", args.loadFile);
    try std.testing.expect(args.load);
}

test "Args - verbose flag" {
    const test_alloc = std.testing.allocator;
    
    const mock_args = [_][]const u8{ "zbonsai", "--verbose", "minimal" };
    var args = try parseMockCommandLine(test_alloc, &mock_args);
    defer args.deinit();
    
    try std.testing.expectEqual(Verbosity.minimal, args.verbosity);
}

test "Args - full command line parsing" {
    const test_alloc = std.testing.allocator;
    
    // Test a complex set of arguments
    const args = [_][]const u8{ 
        "zbonsai", 
        "--live", 
        "--time", "0.05", 
        "--multiplier", "10", 
        "--life", "50",
        "--base", "small",
        "--seed", "12345",
        "--message", "Test Bonsai",
        "--verbose", "minimal"
    };
    
    var parsed = try parseMockCommandLine(test_alloc, &args);
    defer parsed.deinit();
    
    // Verify all arguments are correctly parsed
    try std.testing.expect(parsed.live);
    try std.testing.expectEqual(@as(f32, 0.05), parsed.timeStep);
    try std.testing.expectEqual(@as(usize, 10), parsed.multiplier);
    try std.testing.expectEqual(@as(usize, 50), parsed.lifeStart);
    try std.testing.expectEqual(BaseType.small, parsed.baseType);
    try std.testing.expectEqual(@as(u64, 12345), parsed.seed.?);
    try std.testing.expectEqualStrings("Test Bonsai", parsed.message.?);
    try std.testing.expectEqual(Verbosity.minimal, parsed.verbosity);
}

test "saveToFile functionality" {
    const test_alloc = std.testing.allocator;
    const test_file = "test_save.dat";
    
    // Test writing to file
    try saveToFile(test_alloc, test_file, 12345, 67);
    
    // Verify file contents
    const file = try std.fs.cwd().openFile(test_file, .{});
    defer file.close();
    
    var buf: [100]u8 = undefined;
    const bytes_read = try file.readAll(&buf);
    const content = buf[0..bytes_read];
    
    try std.testing.expectEqualStrings("12345 67", content);
    
    // Clean up test file
    try std.fs.cwd().deleteFile(test_file);
}