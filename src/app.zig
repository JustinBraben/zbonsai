const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const debug = std.debug;
const print = debug.print;
const io = std.io;
const builtin = std.builtin;

const Args = @import("args.zig");
const BaseType = Args.BaseType;
const Styles = @import("styles.zig");
const Dice = @import("dice.zig");
const Tree = @import("tree.zig");

const vaxis = @import("vaxis");
const gwidth = vaxis.gwidth.gwidth;
const clap = @import("clap");

const BranchType = Tree.BranchType;

/// Set the default panic handler to the vaxis panic_handler. This will clean up the terminal if any
/// panics occur
pub const panic = vaxis.panic_handler;

/// Set some scope levels for the vaxis scopes
pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .vaxis, .level = .warn },
        .{ .scope = .vaxis_parser, .level = .warn },
    },
};

/// Used to count tree properties
const Counters = struct {
    branches: usize = 0,
    shoots: usize = 0,
    shootCounter: usize = 0,
};

/// own custom events
const Event = union(enum) {
    key_press: vaxis.Key,
    key_release: vaxis.Key,
    /// Signals window size has changed.
    /// This event guarenteed sent when the loop is started.
    winsize: vaxis.Winsize,
    grow_tree: bool,
};

const App = @This();

allocator: Allocator,
arena: std.heap.ArenaAllocator,
/// A flag for if we should quit
should_quit: bool,
/// The tty we are talking to
tty: vaxis.Tty,
/// The vaxis instance
vx: vaxis.Vaxis,
loop: vaxis.Loop(Event),
/// Roll the dice for Random number generator
dice: Dice,
/// Arguments passed in from command line
args: Args,
/// Tree to draw
tree: Tree,

pub fn init(allocator: Allocator, args: Args) !App {
    return .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .should_quit = false,
        .tty = try vaxis.Tty.init(),
        .vx = try vaxis.init(allocator, .{}),
        .loop = undefined,
        .dice = Dice.initWithSeed(args.seed),
        .args = args,
        .tree = Tree.init(allocator, .{
            .life_start = args.lifeStart,
            .multiplier = args.multiplier,
        }),
    };
}

pub fn deinit(self: *App) void {
    self.vx.deinit(self.allocator, self.tty.anyWriter());
    self.tty.deinit();
    self.tree.deinit();

    // TODO: if printTree is set, print the final product of the tree
    // to the terminal window. Give back user access
    // if (!self.args.printTree) {}
}

pub fn run(self: *App) !void {
    self.loop = .{
        .tty = &self.tty,
        .vaxis = &self.vx,
    };
    try self.loop.init();
    try self.loop.start();

    try self.vx.enterAltScreen(self.tty.anyWriter());

    // Query the terminal to detect advanced features, such as kitty keyboard protocol, etc.
    // This will automatically enable the features in the screen you are in, so you will want to
    // call it after entering the alt screen if you are a full screen application. The second
    // arg is a timeout for the terminal to send responses. Typically the response will be very
    // fast, however it could be slow on ssh connections.
    try self.vx.queryTerminal(self.tty.anyWriter(), 1 * std.time.ns_per_s);

    var myCounters = std.mem.zeroes(Counters);

    var pass_finished = false;

    // Main event loop
    while (!self.should_quit) {
        // pollEvent blocks until we have an event
        self.loop.pollEvent();
        // tryEvent returns events until the queue is empty
        while (self.loop.tryEvent()) |event| {
            try self.update(event);
        }

        // Resets window, draws the base of the tree
        // then grows the tree. If -l passed it you will view
        // generation live. Once the tree has finished growing it will no longer draw anymore
        if (!pass_finished) {
            const win = self.vx.window();
            win.clear();
            try self.drawWins();
            try self.drawMessage();
            try self.growTree(&myCounters);
            pass_finished = true;
        }

        if (self.args.printTree) {
            self.should_quit = true;
        }
        else {
            var buffered = self.tty.bufferedWriter();
            try self.vx.render(buffered.writer().any());
            try buffered.flush();
        }
    }

    // If -p flag passed to program, print the tree to terminal after completion
    if (self.args.printTree) {
        try self.vx.exitAltScreen(self.tty.anyWriter());
        try self.vx.prettyPrint(self.tty.anyWriter());
    }
}

/// Update our application state from an event
pub fn update(self: *App, event: Event) !void {
    switch (event) {
        .key_press => |key| {
            // key.matches does some basic matching algorithms. Key matching can be complex in
            // the presence of kitty keyboard encodings, this will generally be a good approach.
            // There are other matching functions available for specific purposes, as well
            if (key.matches('c', .{ .ctrl = true })) {
                self.should_quit = true;
            }
        },
        .winsize => |ws| {
            try self.vx.resize(self.allocator, self.tty.anyWriter(), ws);
            const win = self.vx.window();
            const center = vaxis.widgets.alignment.center(win, 50, 3);
            _ = center.printSegment(.{ .text = 
            \\Oops, resize needs to be implemented still...
            \\Press Ctrl+C to exit the program and run again
            }, .{});
        },
        .grow_tree => |gt| {
            _ = gt;
            try self.tree.growTree(self.getTreeWinMaxX(), self.getTreeWinMaxY());
            self.tree.updateLife();
        },
        else => {},
    }
}

pub fn updateScreen(self: *App, timeStep: f32) !void {
    // It's best to use a buffered writer for the render method. TTY provides one, but you
    // may use your own. The provided bufferedWriter has a buffer size of 4096
    var buffered = self.tty.bufferedWriter();
    // Render the application to the screen
    try self.vx.render(buffered.writer().any());
    try buffered.flush();

    const ms: u64 = @intFromFloat(timeStep * std.time.ms_per_s);
    std.time.sleep(ms * std.time.ns_per_ms);
}

/// For debugging, used to view args values in the terminal window
pub fn drawConfig(self: *App) !void {
    const win = self.vx.window();
    const msg = try std.fmt.allocPrint(self.arena.allocator(),
        \\live: {}
        \\infinite: {}
        \\screensaver: {}
        \\printTree: {}
        \\seed: {d}
        \\saveFile: {s}
        \\loadFile: {s}
    , .{
        self.args.live,
        self.args.infinite,
        self.args.screensaver,
        self.args.printTree,
        self.args.seed,
        self.args.saveFile,
        self.args.loadFile,
    });
    _ = win.printSegment(.{ .text = msg[0..], .style = .{} }, .{});
}

fn drawWins(self: *App) !void {
    try self.drawBase();
}

fn drawBase(self: *App) !void {
    const win = self.vx.window();

    switch (self.args.baseType) {
        .none => {},
        .small => {
            const msg =
                \\ (           ) 
                \\  (_________)  
            ;

            const x_pos = (win.width / 2) -| 7;
            const y_pos = (win.height -| 2);

            const pot_child = win.child(.{
                .x_off = x_pos,
                .y_off = y_pos,
                .width = 16,
                .height = 2,
            });

            _ = pot_child.printSegment(.{ .text = msg, .style = Styles.pot_style }, .{});

            const plant_base = &[_]vaxis.Segment{
                .{ .text = "(", .style = Styles.pot_style },
                .{ .text = "---", .style = Styles.green_bottom_style },
                .{ .text = "./~~~\\.", .style = Styles.tree_base_style },
                .{ .text = "---", .style = Styles.green_bottom_style },
                .{ .text = ")", .style = Styles.pot_style },
            };

            const plant_base_child = win.child(.{
                .x_off = x_pos,
                .y_off = y_pos -| 1,
                .width = 15,
                .height = 1,
            });

            var plant_base_offset: u16 = 0;
            for (plant_base) |seg| {
                _ = plant_base_child.printSegment(seg, .{
                    .col_offset = plant_base_offset,
                    .wrap = .none,
                });
                plant_base_offset += @truncate(seg.text.len);
            }
        },
        .large => {
            const msg =
                \\   \                           /
                \\    \_________________________/ 
                \\    (_)                     (_) 
            ;

            const x_pos = (win.width / 2) -| 16;
            const y_pos = (win.height -| 3);

            const pot_child = win.child(.{
                .x_off = x_pos,
                .y_off = y_pos,
                .width = 33,
                .height = 3,
            });

            _ = pot_child.printSegment(.{ .text = msg, .style = Styles.pot_style }, .{});

            const plant_base = &[_]vaxis.Segment{
                .{ .text = ":", .style = Styles.pot_style },
                .{ .text = "___________", .style = Styles.green_bottom_style },
                .{ .text = "./~~~\\.", .style = Styles.tree_base_style },
                .{ .text = "___________", .style = Styles.green_bottom_style },
                .{ .text = ":", .style = Styles.pot_style },
            };

            const plant_base_child = win.child(.{
                .x_off = x_pos +| 2,
                .y_off = y_pos -| 1,
                .width = 32,
                .height = 1,
            });

            var plant_base_offset: u16 = 0;
            for (plant_base) |seg| {
                _ = plant_base_child.printSegment(seg, .{
                    .col_offset = plant_base_offset,
                    .wrap = .none,
                });
                plant_base_offset += @truncate(seg.text.len);
            }
        },
    }
}

fn drawMessage(self: *App) !void {
    if (self.args.message) |msg| {
        const win = self.vx.window();

        // Get the 3/4 pos of X for the window
        const mid_x = (win.width / 2) +| (win.width / 4);

        // Bound size_x to 34 at most
        const child_size_x: u16 = if (msg.len > 30) 34 else @as(u16, @truncate(msg.len)) + 5;
        // Message box at least size_y of 3
        // Each 30 characters will add another line characters
        const child_size_y: u16 = @divFloor(@as(u16, @truncate(msg.len)), 30) + 3;

        const x_pos = mid_x -| (child_size_x / 4);
        const y_pos = (win.height / 2);

        const custom_border: [6][]const u8 = .{ "+", "-", "+", "│", "+", "+" };
        const message_child = win.child(.{
            .x_off = x_pos,
            .y_off = y_pos,
            .width = child_size_x,
            .height = child_size_y,
            .border = .{ .where = .all, .glyphs = .{ .custom = custom_border } },
        });

        var index: usize = 0;
        while (index < msg.len) : (index += 30) {
            const end = index + 30;
            if (end < msg.len) {
                _ = message_child.printSegment(.{ .text = msg[index..end] }, .{ .col_offset = 1, .row_offset = @divFloor(@as(u16, @truncate(index)), 30) });
            } else {
                _ = message_child.printSegment(.{ .text = msg[index..] }, .{ .col_offset = 1, .row_offset = @divFloor(@as(u16, @truncate(index)), 30) });
            }
        }
    }
}

/// Used to debug initial tree drawing placement
fn drawTree(self: *App) !void {
    const win = self.vx.window();

    switch (self.args.baseType) {
        .none => {
            const x_pos = (self.getTreeWinMaxX() / 2) -| 1;
            const y_pos = self.getTreeWinMaxY();
            const y_max = self.getTreeWinMaxY();

            const tree_child = win.child(.{
                .x_off = x_pos,
                .y_off = y_pos,
                .height = .{ .limit = y_max },
            });

            _ = tree_child.printSegment(.{ .text = "/~\\", .style = Styles.tree_base_style }, .{});
        },
        .small => {
            const x_pos = (self.getTreeWinMaxX() / 2) -| 1;
            const y_pos = self.getTreeWinMaxY();
            const y_max = self.getTreeWinMaxY();

            const tree_child = win.child(.{
                .x_off = x_pos,
                .y_off = y_pos,
                .height = .{ .limit = y_max },
            });

            _ = tree_child.printSegment(.{ .text = "/~\\", .style = Styles.tree_base_style }, .{});
        },
        .large => {
            const x_pos = (self.getTreeWinMaxX() / 2) -| 1;
            const y_pos = self.getTreeWinMaxY();
            const y_max = self.getTreeWinMaxY();

            const tree_child = win.child(.{
                .x_off = x_pos,
                .y_off = y_pos,
                .height = .{ .limit = y_max },
            });

            _ = tree_child.printSegment(.{ .text = "/~\\", .style = Styles.tree_base_style }, .{});
        },
    }
}

/// Gets the starting position to grow the tree,
/// calls self.branch which recursively draws the tree
fn growTree(self: *App, myCounters: *Counters) !void {
    var maxX: u16 = 0;
    var maxY: u16 = 0;

    maxX = self.getTreeWinMaxX();
    maxY = self.getTreeWinMaxY();

    myCounters.*.shoots = 0;
    myCounters.*.branches = 0;
    myCounters.*.shootCounter = self.dice.rollUsize(std.math.maxInt(u31));

    // recursively grow tree trunk and branches
    try self.branch(myCounters, (maxX / 2), (maxY), .trunk, self.args.lifeStart);

    const win = self.vx.window();
    win.hideCursor();
}

/// Recursively draws the parts of the tree
fn branch(self: *App, myCounters: *Counters, x_input: u16, y_input: u16, branch_type: BranchType, life_input: usize) !void {
    var x = x_input;
    var y = y_input;
    var life = life_input;

    myCounters.*.branches +|= 1;
    var dx: i64 = 0;
    var dy: i64 = 0;
    var age: usize = 0;
    var shootCooldown = self.args.multiplier;

    while (life > 0) {
        // tryEvent returns events until the queue is empty
        while (self.loop.tryEvent()) |event| {
            switch (event) {
                .key_press => |key| {
                    if (key.matches('c', .{ .ctrl = true })) {
                        self.should_quit = true;
                        return;
                    }
                },
                else => {},
            }
        }

        // decrement remaining life counter
        life -|= 1;
        age = self.args.lifeStart -| life;

        self.setDeltas(branch_type, life, age, self.args.multiplier, &dx, &dy);

        const maxY = self.getTreeWinMaxY();
        // reduce dy if too close to the ground
        if (dy > 0 and y > (maxY -| 2)) dy -= 1;

        // near-dead branch should branch into a lot of leaves
        if (life < 3) {
            try self.branch(myCounters, x, y, .dead, life);
        }
        // dying trunk should branch into a lot of leaves
        else if (branch_type == .trunk and life < (self.args.multiplier +| 2)) {
            try self.branch(myCounters, x, y, .dying, life);
        }
        // dying shoot should branch into a lot of leaves
        else if ((branch_type == .shootLeft or branch_type == .shootRight) and life < (self.args.multiplier +| 2)) {
            try self.branch(myCounters, x, y, .dying, life);
        } else if ((branch_type == .trunk and self.dice.rollUsize(3) == 0) or
            (life % self.args.multiplier == 0))
        {
            if (self.dice.rollUsize(8) == 0 and life > 7) {
                shootCooldown = self.args.multiplier * 2;

                const life_offset = self.dice.rollI64(5) - 2;
                if (life_offset < 0) {
                    try self.branch(myCounters, x, y, .trunk, life -| @as(usize, @abs(life_offset)));
                } else {
                    try self.branch(myCounters, x, y, .trunk, life +| @as(usize, @intCast(life_offset)));
                }
            } else if (shootCooldown == 0) {
                shootCooldown = self.args.multiplier * 2;

                myCounters.*.shoots +|= 1;
                myCounters.*.shootCounter +|= 1;

                // 50/50 branch shootLeft or shootRight
                if (self.dice.rollUsize(2) == 0) {
                    try self.branch(myCounters, x, y, .shootLeft, (life +| self.args.multiplier));
                } else {
                    try self.branch(myCounters, x, y, .shootRight, (life +| self.args.multiplier));
                }
            }
        }

        shootCooldown -|= 1;

        const win = self.vx.window();

        if (self.args.verbosity != .none) {
            var buffer: [200]u8 = undefined;
            const buf = buffer[0..];

            const msg = try std.fmt.bufPrint(buf, 
            \\maxX: {d}, maxY: {d}
                \\
                \\dx: {d}
                \\dy: {d}
                \\type: {s}
                \\shootCooldown: {d}
            , .{ win.width, win.height, dx, dy, @tagName(branch_type), shootCooldown });

            const verbose_child = win.child(.{
                .x_off = 5,
                .y_off = 2,
                .width = 30,
                .height = 6,
            });
            verbose_child.clear();

            _ = verbose_child.printSegment(.{ .text = msg }, .{});
        }

        // move in x and y directions
        if (dx > 0) {
            x +|= @as(u16, @intCast(@abs(dx)));
        } else {
            x -|= @as(u16, @intCast(@abs(dx)));
        }

        if (dy > 0) {
            y +|= @as(u16, @intCast(@abs(dy)));
        } else {
            y -|= @as(u16, @intCast(@abs(dy)));
        }

        // Choose color for this branch
        const style = self.chooseColor(branch_type);

        const branch_str = try self.chooseString(branch_type, life, dx, dy);

        const x_pos = x;
        const y_pos = y;
        const y_max = self.getTreeWinMaxY();

        const tree_child = win.child(.{
            .x_off = x_pos,
            .y_off = y_pos,
            .height = y_max,
        });

        // TODO: Only print segments that don't overlap too harshly with
        // other parts of the tree
        // const branch_str_width = try gwidth(branch_str, .wcwidth, &self.vx.unicode.width_data);
        // if (branch_str_width > 0 and x % branch_str_width == 0) {
        //     _ = try tree_child.printSegment(.{ .text = branch_str, .style = style }, .{});
        // }

        // Draw branch regardless of string length
        _ = tree_child.printSegment(.{ .text = branch_str, .style = style }, .{});

        // if live, update screen
        // skip updating if we're still loading from file
        if (self.args.live and !(self.args.load and myCounters.*.branches < self.args.targetBranchCount)) {
            try self.updateScreen(self.args.timeStep);
        }
    }
}

/// Determine which way the tree shoot draw towards
fn setDeltas(self: *App, branch_type: BranchType, life: usize, age: usize, multiplier: usize, returnDx: *i64, returnDy: *i64) void {
    var dice: i64 = 0;

    switch (branch_type) {
        .trunk => {

            // new or dead trunk
            if (age <= 2 or life < 4) {
                returnDy.* = 0;
                returnDx.* = self.dice.rollI64(3) - 1;
            }
            // young trunk should grow wide
            else if (age < (multiplier * 3)) {
                const res = @as(f32, @floatFromInt(multiplier)) * 0.5;

                // every (multiplier * 0.5) steps, raise tree to next level
                if (age % @as(usize, @intFromFloat(res)) == 0) returnDy.* = -1 else returnDy.* = 0;

                dice = self.dice.rollI64(10);
                if (dice >= 0 and dice <= 0) {
                    returnDx.* = -2;
                } else if (dice >= 1 and dice <= 3) {
                    returnDx.* = -1;
                } else if (dice >= 4 and dice <= 5) {
                    returnDx.* = 0;
                } else if (dice >= 6 and dice <= 8) {
                    returnDx.* = 1;
                } else if (dice >= 9 and dice <= 9) {
                    returnDx.* = 2;
                }
            }
            // middle-age trunk
            else {
                dice = self.dice.rollI64(10);
                if (dice > 2) {
                    returnDy.* = -1;
                } else {
                    returnDy.* = 0;
                }
                returnDx.* = self.dice.rollI64(3) - 1;
            }
        },
        // trend left and a little vertical movement
        .shootLeft => {
            dice = self.dice.rollI64(10);
            if (dice >= 0 and dice <= 1) {
                returnDy.* = -1;
            } else if (dice >= 2 and dice <= 7) {
                returnDy.* = 0;
            } else if (dice >= 8 and dice <= 9) {
                returnDy.* = 1;
            }

            dice = self.dice.rollI64(10);
            if (dice >= 0 and dice <= 1) {
                returnDx.* = -2;
            } else if (dice >= 2 and dice <= 5) {
                returnDx.* = -1;
            } else if (dice >= 6 and dice <= 8) {
                returnDx.* = 0;
            } else if (dice >= 9 and dice <= 9) {
                returnDx.* = 1;
            }
        },
        // trend right and a little vertical movement
        .shootRight => {
            dice = self.dice.rollI64(10);
            if (dice >= 0 and dice <= 1) {
                returnDy.* = -1;
            } else if (dice >= 2 and dice <= 7) {
                returnDy.* = 0;
            } else if (dice >= 8 and dice <= 9) {
                returnDy.* = 1;
            }

            dice = self.dice.rollI64(10);
            if (dice >= 0 and dice <= 1) {
                returnDx.* = 2;
            } else if (dice >= 2 and dice <= 5) {
                returnDx.* = 1;
            } else if (dice >= 6 and dice <= 8) {
                returnDx.* = 0;
            } else if (dice >= 9 and dice <= 9) {
                returnDx.* = -1;
            }
        },
        // discourage vertical growth(?); trend left/right (-3,3)
        .dying => {
            dice = self.dice.rollI64(10);
            if (dice >= 0 and dice <= 1) {
                returnDy.* = -1;
            } else if (dice >= 2 and dice <= 8) {
                returnDy.* = 0;
            } else if (dice >= 9 and dice <= 9) {
                returnDy.* = 1;
            }

            dice = self.dice.rollI64(15);
            if (dice >= 0 and dice <= 0) {
                returnDx.* = -3;
            } else if (dice >= 1 and dice <= 2) {
                returnDx.* = -2;
            } else if (dice >= 3 and dice <= 5) {
                returnDx.* = 1;
            } else if (dice >= 6 and dice <= 8) {
                returnDx.* = 0;
            } else if (dice >= 9 and dice <= 11) {
                returnDx.* = 1;
            } else if (dice >= 12 and dice <= 13) {
                returnDx.* = 2;
            } else if (dice >= 14 and dice <= 14) {
                returnDx.* = 3;
            }
        },
        .dead => {
            dice = self.dice.rollI64(10);
            if (dice >= 0 and dice <= 2) {
                returnDy.* = -1;
            } else if (dice >= 3 and dice <= 6) {
                returnDy.* = 0;
            } else if (dice >= 7 and dice <= 9) {
                returnDy.* = 1;
            }
            returnDx.* = self.dice.rollI64(3) - 1;
        },
    }
}

/// Return vaxis style for color of tree parts
fn chooseColor(self: *App, branch_type: BranchType) vaxis.Style {
    switch (branch_type) {
        .trunk, .shootLeft, .shootRight => {
            if (self.dice.rollI64(2) == 0) {
                return vaxis.Style{
                    .fg = .{ .index = 11 },
                    .bold = true,
                };
            } else {
                return vaxis.Style{
                    .fg = .{ .index = 3 },
                };
            }
        },
        .dying => {
            if (self.dice.rollI64(10) == 0) {
                return vaxis.Style{
                    .fg = .{ .index = 2 },
                    .bold = true,
                };
            } else {
                return vaxis.Style{
                    .fg = .{ .index = 2 },
                };
            }
        },
        .dead => {
            if (self.dice.rollI64(3) == 0) {
                return vaxis.Style{
                    .fg = .{ .index = 10 },
                    .bold = true,
                };
            } else {
                return vaxis.Style{
                    .fg = .{ .index = 10 },
                };
            }
        },
    }
}

/// Return a String for the tree
fn chooseString(self: *App, branch_type_input: BranchType, life: usize, dx: i64, dy: i64) ![]const u8 {
    var branch_type = branch_type_input;
    if (life < 4) branch_type = .dying;

    var result: []const u8 = undefined;
    
    switch (branch_type) {
        .trunk => {
            if (dy == 0) {
                result = "/~";
            } else if (dx < 0) {
                result = "\\|";
            } else if (dx == 0) {
                result = "/|\\";
            } else if (dx > 0) {
                result = "|/";
            } else {
                result = "?";
            }
        },
        .shootLeft => {
            if (dy > 0) {
                result = "\\";
            } else if (dy == 0) {
                result = "\\_";
            } else if (dx < 0) {
                result = "\\|";
            } else if (dx == 0) {
                result = "/|";
            } else if (dx > 0) {
                result = "/";
            } else {
                result = "?";
            }
        },
        .shootRight => {
            if (dy > 0) {
                result = "/";
            } else if (dy == 0) {
                result = "_/";
            } else if (dx < 0) {
                result = "\\|";
            } else if (dx == 0) {
                result = "/|";
            } else if (dx > 0) {
                result = "/";
            } else {
                result = "?";
            }
        },
        .dying, .dead => {
            const rand_index = self.dice.rollUsize(self.args.leaves.len);
            result = self.args.leaves[0..rand_index];
        },
    }
    
    // Create a durable copy in the arena
    return try self.arena.allocator().dupe(u8, result);
}

/// Get Max Y bounds for the tree, based on baseType
fn getTreeWinMaxY(self: *App) u16 {
    const win = self.vx.window();

    return switch (self.args.baseType) {
        .none => (win.height -| 1),
        .small => (win.height -| 4),
        .large => (win.height -| 5),
    };
}

/// Get Max X bounds for the tree, based on baseType
fn getTreeWinMaxX(self: *App) u16 {
    const win = self.vx.window();

    return switch (self.args.baseType) {
        .none, .small, .large => (win.width),
    };
}

fn saveToFile(file_absolute_path: []const u8, seed: u64, branch_count: u64) !void {
    var file = try std.fs.createFileAbsolute(file_absolute_path, .{});
    defer file.close();

    var buffer: [100]u8 = undefined;
    const buf = buffer[0..];
    const file_contents = try std.fmt.bufPrint(buf, "{d} {d}", .{seed, branch_count});

    try file.writeAll(file_contents);
}

fn loadFromFile(args: *Args) !void {
    var file = try std.fs.openFileAbsolute(args.loadFile, .{ .mode = .read_only });
    defer file.close();

    // Read from file using a buffered reader
    var buf_reader = std.io.bufferedReader(file.reader());
    const reader = buf_reader.reader();

    // Read values from file
    var buffer: [100]u8 = undefined;
    const line = try reader.readUntilDelimiterOrEof(&buffer, '\n') orelse return error.EmptyFile;

    // Parse the values
    var iter = std.mem.tokenizeScalar(u8, line, ' ');
    
    const seedStr = iter.next() orelse return error.InvalidFormat;
    const branchCountStr = iter.next() orelse return error.InvalidFormat;
    
    args.*.seed = try std.fmt.parseInt(i32, seedStr, 10);
    args.*.targetBranchCount = try std.fmt.parseInt(i32, branchCountStr, 10);
}