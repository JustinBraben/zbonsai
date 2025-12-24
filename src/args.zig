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
    InvalidColorValue,
    InvalidColorCount,
    TooManyColors,
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

/// Color configuration for tree rendering
/// Indices are terminal color codes (0-255)
pub const ColorConfig = struct {
    dark_leaves: u8 = 2,    // Default green
    dark_wood: u8 = 3,      // Default dark brown/yellow
    light_leaves: u8 = 10,  // Default bright green
    light_wood: u8 = 11,    // Default bright brown/yellow
};

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

// Color configuration
colors: ColorConfig = .{},

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

/// Parse comma-delimited color string into ColorConfig
/// Format: "dark_leaves,dark_wood,light_leaves,light_wood"
/// Example: "2,3,10,11" (the default)
pub fn parseColors(color_input: []const u8) ArgsError!ColorConfig {
    var config = ColorConfig{};
    var iter = std.mem.tokenizeScalar(u8, color_input, ',');
    var index: usize = 0;

    while (iter.next()) |color_str| {
        const trimmed = std.mem.trim(u8, color_str, " \t");
        const color = std.fmt.parseInt(u8, trimmed, 10) catch {
            return ArgsError.InvalidColorValue;
        };

        switch (index) {
            0 => config.dark_leaves = color,
            1 => config.dark_wood = color,
            2 => config.light_leaves = color,
            3 => config.light_wood = color,
            else => return ArgsError.TooManyColors,
        }
        index += 1;
    }

    // Must have exactly 4 colors if any are provided
    if (index != 0 and index != 4) {
        return ArgsError.InvalidColorCount;
    }

    return config;
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
        \\-k, --color <STR>         List of 4 comma-delimited color indices (0-255) for
        \\                          dark leaves, dark wood, light leaves, light wood
        \\                          [default: 2,3,10,11].
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
    if (res.args.screensaver != 0) {
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

    // Parse colors
    var colors = ColorConfig{};
    if (res.args.color) |color_input| {
        colors = try parseColors(color_input);
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

        .colors = colors,

        .save = save,
        .load = load,

        .saveFile = saveFile,
        .loadFile = loadFile,
    };

    // If load flag is set, try to load seed and branch count from file
    if (args.load) {
        if (loadFromFile(args.loadFile)) |loaded| {
            args.seed = loaded.seed;
            args.targetBranchCount = loaded.branchCount;
        } else |err| {
            // If file not found, just continue with defaults (first run)
            // For other errors, we might want to warn but continue
            if (err != error.SaveFileNotFound) {
                std.debug.print("Warning: Could not load from {s}: {}\n", .{ args.loadFile, err });
            }
        }
    }

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

/// Creates platform-specific default cache path for save/load files
/// - macOS: ~/Library/Application Support/zbonsai/zbonsai.dat
/// - Linux: ~/.cache/zbonsai (XDG Base Directory spec)
/// - Windows: %APPDATA%\zbonsai\zbonsai.dat
fn createDefaultCachePath(ally: Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        // Windows: Use APPDATA environment variable
        const appdata = try std.process.getEnvVarOwned(ally, "APPDATA");
        const path = try std.fs.path.join(ally, &.{ appdata, "zbonsai", "zbonsai.dat" });
        return path;
    } else if (builtin.os.tag == .macos) {
        // macOS: Use ~/Library/Application Support/zbonsai/
        if (std.posix.getenv("HOME")) |home| {
            const path = try std.fs.path.join(ally, &.{ home, "Library", "Application Support", "zbonsai", "zbonsai.dat" });
            return path;
        }
        // Fallback
        return try ally.dupe(u8, "zbonsai.dat");
    } else {
        // Linux/Unix: Follow XDG Base Directory Specification
        // First try XDG_CACHE_HOME, then fall back to ~/.cache
        if (std.posix.getenv("XDG_CACHE_HOME")) |cache_home| {
            const path = try std.fs.path.join(ally, &.{ cache_home, "zbonsai" });
            return path;
        } else if (std.posix.getenv("HOME")) |home| {
            const path = try std.fs.path.join(ally, &.{ home, ".cache", "zbonsai" });
            return path;
        }
        // Final fallback
        return try ally.dupe(u8, "zbonsai");
    }
}

/// Ensures the parent directory of a file path exists, creating it if necessary
fn ensureParentDirExists(file_path: []const u8) !void {
    if (std.fs.path.dirname(file_path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                return err;
            }
        };
    }
}

/// Save tree state (seed and branch count) to file
/// Creates parent directories if they don't exist
pub fn saveToFile(ally: Allocator, file_path: []const u8, seed: u64, branchCount: usize) !void {
    // Ensure the directory exists
    try ensureParentDirExists(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    const content = try std.fmt.allocPrint(ally, "{d} {d}", .{ seed, branchCount });
    defer ally.free(content);

    try file.writeAll(content);
}

/// Load tree state (seed and branch count) from file
/// Returns error if file doesn't exist or has invalid format
pub fn loadFromFile(file_path: []const u8) !struct { seed: u64, branchCount: usize } {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return error.SaveFileNotFound;
        }
        return err;
    };
    defer file.close();

    var buffer: [100]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);

    if (bytes_read == 0) {
        return error.EmptyFile;
    }

    // Trim any trailing whitespace/newlines
    const content = std.mem.trimRight(u8, buffer[0..bytes_read], " \t\n\r");

    var tokens = std.mem.tokenizeScalar(u8, content, ' ');

    const seed_str = tokens.next() orelse return error.InvalidFileFormat;
    const branch_count_str = tokens.next() orelse return error.InvalidFileFormat;

    return .{
        .seed = try std.fmt.parseInt(u64, seed_str, 10),
        .branchCount = try std.fmt.parseInt(usize, branch_count_str, 10),
    };
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

test "loadFromFile functionality" {
    const test_alloc = std.testing.allocator;
    const test_file = "test_load.dat";

    // First save a file
    try saveToFile(test_alloc, test_file, 99999, 42);

    // Now load it back
    const loaded = try loadFromFile(test_file);

    try std.testing.expectEqual(@as(u64, 99999), loaded.seed);
    try std.testing.expectEqual(@as(usize, 42), loaded.branchCount);

    // Clean up test file
    try std.fs.cwd().deleteFile(test_file);
}

test "loadFromFile - file not found returns error" {
    const result = loadFromFile("nonexistent_file_12345.dat");
    try std.testing.expectError(error.SaveFileNotFound, result);
}

test "saveToFile creates parent directories" {
    const test_alloc = std.testing.allocator;
    const test_file = "test_subdir/nested/test_save.dat";

    // This should create the directories and the file
    try saveToFile(test_alloc, test_file, 11111, 22);

    // Verify it worked by loading
    const loaded = try loadFromFile(test_file);
    try std.testing.expectEqual(@as(u64, 11111), loaded.seed);
    try std.testing.expectEqual(@as(usize, 22), loaded.branchCount);

    // Clean up
    try std.fs.cwd().deleteFile(test_file);
    std.fs.cwd().deleteDir("test_subdir/nested") catch {};
    std.fs.cwd().deleteDir("test_subdir") catch {};
}

test "createDefaultCachePath returns valid path" {
    const test_alloc = std.testing.allocator;

    const path = try createDefaultCachePath(test_alloc);
    defer test_alloc.free(path);

    // Path should not be empty
    try std.testing.expect(path.len > 0);

    // Path should contain 'zbonsai' somewhere
    try std.testing.expect(std.mem.indexOf(u8, path, "zbonsai") != null);
}

// ============================================================================
// Color Parsing Tests
// ============================================================================

test "parseColors - default values" {
    const config = try parseColors("");
    
    // When empty string passed, should return defaults
    try std.testing.expectEqual(@as(u8, 2), config.dark_leaves);
    try std.testing.expectEqual(@as(u8, 3), config.dark_wood);
    try std.testing.expectEqual(@as(u8, 10), config.light_leaves);
    try std.testing.expectEqual(@as(u8, 11), config.light_wood);
}

test "parseColors - valid 4 colors" {
    const config = try parseColors("1,2,3,4");
    
    try std.testing.expectEqual(@as(u8, 1), config.dark_leaves);
    try std.testing.expectEqual(@as(u8, 2), config.dark_wood);
    try std.testing.expectEqual(@as(u8, 3), config.light_leaves);
    try std.testing.expectEqual(@as(u8, 4), config.light_wood);
}

test "parseColors - with whitespace" {
    const config = try parseColors(" 100 , 150 , 200 , 250 ");
    
    try std.testing.expectEqual(@as(u8, 100), config.dark_leaves);
    try std.testing.expectEqual(@as(u8, 150), config.dark_wood);
    try std.testing.expectEqual(@as(u8, 200), config.light_leaves);
    try std.testing.expectEqual(@as(u8, 250), config.light_wood);
}

test "parseColors - 256 color range" {
    const config = try parseColors("0,127,128,255");
    
    try std.testing.expectEqual(@as(u8, 0), config.dark_leaves);
    try std.testing.expectEqual(@as(u8, 127), config.dark_wood);
    try std.testing.expectEqual(@as(u8, 128), config.light_leaves);
    try std.testing.expectEqual(@as(u8, 255), config.light_wood);
}

test "parseColors - too few colors" {
    const result = parseColors("1,2,3");
    try std.testing.expectError(ArgsError.InvalidColorCount, result);
}

test "parseColors - too many colors" {
    const result = parseColors("1,2,3,4,5");
    try std.testing.expectError(ArgsError.TooManyColors, result);
}

test "parseColors - invalid color value (not a number)" {
    const result = parseColors("1,2,abc,4");
    try std.testing.expectError(ArgsError.InvalidColorValue, result);
}

test "parseColors - color value out of u8 range" {
    const result = parseColors("1,2,3,256");
    try std.testing.expectError(ArgsError.InvalidColorValue, result);
}

test "parseColors - negative color value" {
    const result = parseColors("1,2,-3,4");
    try std.testing.expectError(ArgsError.InvalidColorValue, result);
}