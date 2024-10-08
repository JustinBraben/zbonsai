const clap = @import("clap");
const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const BaseType = @import("base_type.zig").BaseType;
const Verbosity = @import("verbosity.zig").Verbosity;

const io = std.io;

pub const Args = struct {
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
    seed: u64,
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
            \\                              generation [default: 4.00].
            \\
            \\-S, --screensaver         Screensaver mode; equivalent to -liWC and
            \\                              quit on any keypress.
            \\
            \\-m, --message <STR>       Attach message next to the tree.
            \\-b, --base <BASETYPE>     Ascii-art plant base to use, 0 is none.
            \\-c, --leaf <STR>          List of comma-delimited strings randomly chosen
            \\                          for leaves.
            \\
            \\-M, --multiplier <USIZE>  Branch multiplier; higher -> more
            \\                              branching (0-20) [default: 5].
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
            .TIME = clap.parsers.float(f32),
            .BASETYPE = clap.parsers.enumeration(BaseType),
            .VERBOSITY = clap.parsers.enumeration(Verbosity),
        };

        var diag = clap.Diagnostic{};
        var res = clap.parse(clap.Help, &params, parsers, .{
            .diagnostic = &diag,
            .allocator = ally,
        }) catch |err| {
            diag.report(io.getStdErr().writer(), err) catch {};
            return err;
        };
        defer res.deinit();

        if (res.args.help != 0) {
            try clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
            // return errors.ControlledExit.Help;
        }

        var multiplier: usize = 5;
        if (res.args.multiplier) |m|
            multiplier = m;

        var message: ?[]const u8 = null;
        if (res.args.message) |msg|
            message = msg;

        var baseType: BaseType = .large;
        if (res.args.base) |bs|
            baseType = bs;

        var lifeStart: usize = 32;
        if (res.args.life) |ls|
            lifeStart = ls;

        var seed: u64 = 0;
        if (res.args.seed) |s|
            seed = s;

        var timeStep: f32 = 0.03;
        if (res.args.time) |ts|
            timeStep = ts;

        var save = false;
        var saveFile = try createDefaultCachePath(ally);
        if (res.args.save) |save_file| {
            ally.free(saveFile);
            saveFile = try ally.alloc(u8, save_file.len);
            @memcpy(saveFile, save_file);
            save = true;
        }

        var load = false;
        var loadFile = try createDefaultCachePath(ally);
        if (res.args.load) |load_file| {
            ally.free(loadFile);
            loadFile = try ally.alloc(u8, load_file.len);
            @memcpy(saveFile, loadFile);
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
            .leaves = std.mem.zeroes([64]u8),

            .save = save,
            .load = load,

            .saveFile = saveFile,
            .loadFile = loadFile,
        };
    }

    pub fn deinit(self: *Args) void {
        self.allocator.free(self.saveFile);
        self.allocator.free(self.loadFile);
    }

    fn createDefaultCachePath(ally: Allocator) ![]u8 {
        const toAppend = "cbonsai";
        const res = try ally.alloc(u8, toAppend.len);
        @memcpy(res, toAppend);
        return res;
    }

    fn saveToFile(ally: Allocator, file_name: []const u8, seed: u64, branchCount: u64) !void {
        const file = try std.fs.cwd().createFile(file_name, .{ .read = true });
        defer file.close();

        _ = try file.writeAll(std.fmt.allocPrint(ally, "{d} {d}", .{ seed, branchCount }));
    }

    fn loadFromFile(file_name: []const u8) !void {
        const file = try std.fs.cwd().openFile(file_name, .{});
        defer file.close();

        var buffer: [100]u8 = undefined;
        try file.seekTo(0);
        _ = try file.readAll(&buffer);

        // var tokens = std.mem.tokenizeAny(u8, &buffer, " ");

        // self.args.seed = std.fmt.parseInt(usize, tokens.next());
    }
};
