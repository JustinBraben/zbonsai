//! args.zig
const std = @import("std");
const builtin = @import("builtin");
const io = std.io;
const Allocator = std.mem.Allocator;
const clap = @import("clap");

const Args = @This();

pub const ArgsError = error{
    NotImplemented,
    MultiplierOutOfRange,
    InvalidSeed,
    TooManyLeaves,
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

pub const MAX_LEAVES = 64;

allocator: Allocator,

help: bool = false,

live: bool = false,
infinite: bool = false,
screensaver: bool = false,
printTree: bool = false,
verbosity: Verbosity = .none,
lifeStart: usize = 32,
multiplier: usize = 5,
baseType: BaseType = .large,
seed: ?u64 = null,
targetBranchCount: usize = 0,

timeWait: f32 = 4,
timeStep: f32 = 0.03,

message: ?[]const u8 = null,

// Leaf configuration
leaves: []const u8 = "&", // Raw input string for leaves
leafStrings: [MAX_LEAVES][]const u8 = undefined, // Parsed leaf options
leafCount: usize = 0,

load: bool = false,
save: bool = false,

saveFile: []const u8 = undefined,
loadFile: []const u8 = undefined,

/// Parse comma-delimited leaf string into individual leaf options
/// Example: "&,*,🌿,🍃" becomes ["&", "*", "🌿", "🍃"]
pub fn parseLeaves(self: *Args, leaf_input: []const u8) !void {
    self.leafCount = 0;
    
    var iter = std.mem.tokenizeScalar(u8, leaf_input, ',');
    while (iter.next()) |leaf| {
        if (self.leafCount >= MAX_LEAVES) {
            return ArgsError.TooManyLeaves;
        }
        // Trim whitespace from each leaf
        const trimmed = std.mem.trim(u8, leaf, " \t");
        if (trimmed.len > 0) {
            self.leafStrings[self.leafCount] = trimmed;
            self.leafCount += 1;
        }
    }
    
    // If no valid leaves were parsed, use default
    if (self.leafCount == 0) {
        self.leafStrings[0] = "&";
        self.leafCount = 1;
    }
}

/// Get a random leaf string for display
pub fn getRandomLeaf(self: *const Args, index: usize) []const u8 {
    if (self.leafCount == 0) {
        return "&";
    }
    return self.leafStrings[index % self.leafCount];
}

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
        \\                          for leaves [default: &].
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

    var timeWait: f32 = 4.0;
    if (res.args.wait) |tw|
        timeWait = tw;

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

    // Parse leaves - allocate and copy to ensure lifetime
    var leaves: []const u8 = "&";
    if (res.args.leaf) |leaf_input| {
        leaves = try ally.dupe(u8, leaf_input);
    } else {
        leaves = try ally.dupe(u8, "&");
    }

    var args = Args{
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
        .targetBranchCount = 0,

        .timeWait = timeWait,
        .timeStep = timeStep,

        .message = message,
        .leaves = leaves,
        .leafStrings = undefined,
        .leafCount = 0,

        .save = save,
        .load = load,

        .saveFile = saveFile,
        .loadFile = loadFile,
    };

    // Parse the leaves into individual strings
    try args.parseLeaves(leaves);

    return args;
}

pub fn deinit(self: *Args) void {
    if (self.message) |msg| {
        self.allocator.free(msg);
    }
    // Free the leaves string if it was allocated
    if (self.leaves.len > 0) {
        self.allocator.free(self.leaves);
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

// ============================================================================
// Tests
// ============================================================================

test "parseLeaves - single leaf" {
    const test_alloc = std.testing.allocator;
    
    var args = Args{
        .allocator = test_alloc,
        .saveFile = try test_alloc.dupe(u8, "test"),
        .loadFile = try test_alloc.dupe(u8, "test"),
        .leaves = try test_alloc.dupe(u8, "&"),
    };
    defer args.deinit();
    
    try args.parseLeaves("&");
    
    try std.testing.expectEqual(@as(usize, 1), args.leafCount);
    try std.testing.expectEqualStrings("&", args.leafStrings[0]);
}

test "parseLeaves - multiple ASCII leaves" {
    const test_alloc = std.testing.allocator;
    
    var args = Args{
        .allocator = test_alloc,
        .saveFile = try test_alloc.dupe(u8, "test"),
        .loadFile = try test_alloc.dupe(u8, "test"),
        .leaves = try test_alloc.dupe(u8, "&,*,#,@"),
    };
    defer args.deinit();
    
    try args.parseLeaves("&,*,#,@");
    
    try std.testing.expectEqual(@as(usize, 4), args.leafCount);
    try std.testing.expectEqualStrings("&", args.leafStrings[0]);
    try std.testing.expectEqualStrings("*", args.leafStrings[1]);
    try std.testing.expectEqualStrings("#", args.leafStrings[2]);
    try std.testing.expectEqualStrings("@", args.leafStrings[3]);
}

test "parseLeaves - with whitespace" {
    const test_alloc = std.testing.allocator;
    
    var args = Args{
        .allocator = test_alloc,
        .saveFile = try test_alloc.dupe(u8, "test"),
        .loadFile = try test_alloc.dupe(u8, "test"),
        .leaves = try test_alloc.dupe(u8, "& , * , #"),
    };
    defer args.deinit();
    
    try args.parseLeaves("& , * , #");
    
    try std.testing.expectEqual(@as(usize, 3), args.leafCount);
    try std.testing.expectEqualStrings("&", args.leafStrings[0]);
    try std.testing.expectEqualStrings("*", args.leafStrings[1]);
    try std.testing.expectEqualStrings("#", args.leafStrings[2]);
}

test "parseLeaves - unicode/emoji leaves" {
    const test_alloc = std.testing.allocator;
    
    var args = Args{
        .allocator = test_alloc,
        .saveFile = try test_alloc.dupe(u8, "test"),
        .loadFile = try test_alloc.dupe(u8, "test"),
        .leaves = try test_alloc.dupe(u8, "🌿,🍃,🌸,✿"),
    };
    defer args.deinit();
    
    try args.parseLeaves("🌿,🍃,🌸,✿");
    
    try std.testing.expectEqual(@as(usize, 4), args.leafCount);
    try std.testing.expectEqualStrings("🌿", args.leafStrings[0]);
    try std.testing.expectEqualStrings("🍃", args.leafStrings[1]);
    try std.testing.expectEqualStrings("🌸", args.leafStrings[2]);
    try std.testing.expectEqualStrings("✿", args.leafStrings[3]);
}

test "parseLeaves - mixed ASCII and unicode" {
    const test_alloc = std.testing.allocator;
    
    var args = Args{
        .allocator = test_alloc,
        .saveFile = try test_alloc.dupe(u8, "test"),
        .loadFile = try test_alloc.dupe(u8, "test"),
        .leaves = try test_alloc.dupe(u8, "&,🌿,*,🍃"),
    };
    defer args.deinit();
    
    try args.parseLeaves("&,🌿,*,🍃");
    
    try std.testing.expectEqual(@as(usize, 4), args.leafCount);
    try std.testing.expectEqualStrings("&", args.leafStrings[0]);
    try std.testing.expectEqualStrings("🌿", args.leafStrings[1]);
    try std.testing.expectEqualStrings("*", args.leafStrings[2]);
    try std.testing.expectEqualStrings("🍃", args.leafStrings[3]);
}

test "parseLeaves - empty input uses default" {
    const test_alloc = std.testing.allocator;
    
    var args = Args{
        .allocator = test_alloc,
        .saveFile = try test_alloc.dupe(u8, "test"),
        .loadFile = try test_alloc.dupe(u8, "test"),
        .leaves = try test_alloc.dupe(u8, ""),
    };
    defer args.deinit();
    
    try args.parseLeaves("");
    
    try std.testing.expectEqual(@as(usize, 1), args.leafCount);
    try std.testing.expectEqualStrings("&", args.leafStrings[0]);
}

test "parseLeaves - only commas uses default" {
    const test_alloc = std.testing.allocator;
    
    var args = Args{
        .allocator = test_alloc,
        .saveFile = try test_alloc.dupe(u8, "test"),
        .loadFile = try test_alloc.dupe(u8, "test"),
        .leaves = try test_alloc.dupe(u8, ",,,"),
    };
    defer args.deinit();
    
    try args.parseLeaves(",,,");
    
    try std.testing.expectEqual(@as(usize, 1), args.leafCount);
    try std.testing.expectEqualStrings("&", args.leafStrings[0]);
}

test "getRandomLeaf - returns valid leaves" {
    const test_alloc = std.testing.allocator;
    
    var args = Args{
        .allocator = test_alloc,
        .saveFile = try test_alloc.dupe(u8, "test"),
        .loadFile = try test_alloc.dupe(u8, "test"),
        .leaves = try test_alloc.dupe(u8, "A,B,C"),
    };
    defer args.deinit();
    
    try args.parseLeaves("A,B,C");
    
    // Test that getRandomLeaf wraps around properly
    try std.testing.expectEqualStrings("A", args.getRandomLeaf(0));
    try std.testing.expectEqualStrings("B", args.getRandomLeaf(1));
    try std.testing.expectEqualStrings("C", args.getRandomLeaf(2));
    try std.testing.expectEqualStrings("A", args.getRandomLeaf(3)); // wraps
    try std.testing.expectEqualStrings("B", args.getRandomLeaf(4)); // wraps
}

test "getRandomLeaf - empty leafCount returns default" {
    const test_alloc = std.testing.allocator;
    
    var args = Args{
        .allocator = test_alloc,
        .saveFile = try test_alloc.dupe(u8, "test"),
        .loadFile = try test_alloc.dupe(u8, "test"),
        .leaves = try test_alloc.dupe(u8, ""),
        .leafCount = 0, // explicitly zero
    };
    defer args.deinit();
    
    try std.testing.expectEqualStrings("&", args.getRandomLeaf(0));
    try std.testing.expectEqualStrings("&", args.getRandomLeaf(100));
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