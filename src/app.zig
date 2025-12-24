//! app.zig
const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Allocator = mem.Allocator;
const io = std.io;

const Args = @import("args.zig");
const BaseType = Args.BaseType;
const Styles = @import("styles.zig");
const Dice = @import("dice.zig");

const vaxis = @import("vaxis");
const clap = @import("clap");

pub const BranchType = enum {
    trunk,
    shootLeft,
    shootRight,
    dying,
    dead,
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
};

const App = @This();

allocator: Allocator,
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
args: *const Args,
debug_buffer: [512]u8 = undefined,
initial_resize_handled: bool = false,

pub fn init(allocator: Allocator, args: *const Args, buffer: []u8) !App {
    return .{
        .allocator = allocator,
        .should_quit = false,
        .tty = try vaxis.Tty.init(buffer),
        .vx = try vaxis.init(allocator, .{}),
        .loop = undefined,
        .dice = Dice.init(args.seed),
        .args = args,
    };
}

pub fn deinit(self: *App) void {
    self.vx.deinit(self.allocator, self.tty.writer());
    self.tty.deinit();
}

pub fn run(self: *App) !void {
    self.loop = .{
        .tty = &self.tty,
        .vaxis = &self.vx,
    };
    try self.loop.init();
    try self.loop.start();

    try self.vx.enterAltScreen(self.tty.writer());
    try self.vx.queryTerminal(self.tty.writer(), 1 * std.time.ns_per_s);

    var myCounters: Counters = .{};

    // Outer loop for infinite mode - grows trees repeatedly
    while (!self.should_quit) {
        var pass_finished = false;

        // Inner loop - grows a single tree
        while (!self.should_quit) {
            // pollEvent blocks until we have an event
            self.loop.pollEvent();
            // tryEvent returns events if one is available
            // does not block
            while (self.loop.tryEvent()) |event| {
                try self.update(event, &myCounters, &pass_finished);
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
            } else {
                try self.renderScreen();
            }

            // Tree finished growing, break inner loop
            if (pass_finished) break;
        }

        // If not in infinite mode, exit after first tree
        if (!self.args.infinite) {
            break;
        }

        // In infinite mode: wait for timeWait seconds, checking for quit
        if (!self.should_quit) {
            const wait_ms: u64 = @intFromFloat(self.args.timeWait * std.time.ms_per_s);
            const check_interval_ms: u64 = 100; // Check for input every 100ms
            var waited: u64 = 0;

            while (waited < wait_ms and !self.should_quit) {
                // Check for key events during wait
                while (self.loop.tryEvent()) |event| {
                    switch (event) {
                        .key_press => |key| {
                            if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
                                self.should_quit = true;
                            }
                        },
                        else => {},
                    }
                }

                if (!self.should_quit) {
                    std.Thread.sleep(check_interval_ms * std.time.ns_per_ms);
                    waited += check_interval_ms;
                }
            }

            // Generate new seed for next tree
            if (!self.should_quit) {
                const new_seed = @as(u64, @intCast(std.time.timestamp()));
                self.dice = Dice.init(new_seed);
                myCounters = .{}; // Reset counters for new tree
            }
        }
    }

    // Save tree state if --save flag was passed
    if (self.args.save) {
        if (self.args.seed) |seed| {
            Args.saveToFile(self.allocator, self.args.saveFile, seed, myCounters.branches) catch |err| {
                std.debug.print("Warning: Could not save to {s}: {}\n", .{ self.args.saveFile, err });
            };
        }
    }

    // If -p flag passed to program, print the tree to terminal after completion
    if (self.args.printTree) {
        try self.vx.exitAltScreen(self.tty.writer());
        try self.vx.prettyPrint(self.tty.writer());
    }
}

/// Update our application state from an event
pub fn update(self: *App, event: Event, myCounters: *Counters, pass_finished: *bool) !void {
    switch (event) {
        .key_press => |key| {
            // Quit on Ctrl+C or 'q'
            if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
                self.should_quit = true;
            }
        },
        .winsize => |ws| {
            try self.vx.resize(self.allocator, self.tty.writer(), ws);
            // Only redraw if this isn't the initial resize
            if (self.initial_resize_handled) {
                const win = self.vx.window();
                win.clear();
                try self.drawWins();
                try self.drawMessage();
                myCounters.* = .{}; // Reset counters
                try self.growTree(myCounters);
                pass_finished.* = true; // Mark as finished to avoid duplicate drawing
            } else {
                self.initial_resize_handled = true;
            }
        },
        else => {},
    }
}

// Update screen for live view
pub fn updateScreen(self: *App, timeStep: f32) !void {
    try self.renderScreen();
    const ms: u64 = @intFromFloat(timeStep * std.time.ms_per_s);
    std.Thread.sleep(ms * std.time.ns_per_ms);
}

// Render the application to the screen
pub fn renderScreen(self: *App) !void {
    try self.vx.render(self.tty.writer());
    try self.tty.writer().flush();
}

/// For debugging, used to view args values in the terminal window
pub fn drawConfig(self: *App) !void {
    const win = self.vx.window();

    const msg = try std.fmt.bufPrint(
        &self.debug_buffer,
        \\live: {}
        \\infinite: {}
        \\screensaver: {}
        \\printTree: {}
        \\seed: {d}
        \\saveFile: {s}
        \\loadFile: {s}
        \\leafCount: {d}
    ,
        .{
            self.args.live,
            self.args.infinite,
            self.args.screensaver,
            self.args.printTree,
            self.args.seed,
            self.args.saveFile,
            self.args.loadFile,
            self.args.leafCount,
        },
    );
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
                    if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
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
        // Reduce dy if too close to the ground
        if (dy > 0 and y > (maxY -| 3)) dy = 0;

        // Boundary checks
        const maxX = self.getTreeWinMaxX();
        if (x < 2 or x > maxX -| 2) {
            // Redirect branches that are too close to screen edge
            if (x < 2) dx = 1;
            if (x > maxX -| 2) dx = -1;
        }

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

        // Decrement shoot cooldown
        shootCooldown -|= 1;

        const win = self.vx.window();

        if (self.args.verbosity != .none) {
            const msg = try std.fmt.bufPrint(
                &self.debug_buffer,
                \\maxX: {d}, maxY: {d}
                \\
                \\dx: {d}
                \\dy: {d}
                \\type: {s}
                \\shootCooldown: {d}
            ,
                .{ win.width, win.height, dx, dy, @tagName(branch_type), shootCooldown },
            );

            const verbose_child = win.child(.{
                .x_off = 5,
                .y_off = 2,
                .width = 30,
                .height = 6,
            });
            verbose_child.clear();

            _ = verbose_child.printSegment(.{ .text = msg }, .{});
        }

        // Move in x and y directions with boundary checking
        if (dx > 0) {
            x = @min(x +| @as(u16, @intCast(@abs(dx))), self.getTreeWinMaxX() -| 2);
        } else if (dx < 0) {
            x = if (x > @as(u16, @intCast(@abs(dx))))
                x -| @as(u16, @intCast(@abs(dx)))
            else
                1;
        }

        if (dy > 0) {
            y = @min(y +| @as(u16, @intCast(@abs(dy))), self.getTreeWinMaxY());
        } else if (dy < 0) {
            y = if (y > @as(u16, @intCast(@abs(dy))))
                y -| @as(u16, @intCast(@abs(dy)))
            else
                1;
        }

        // Choose color for this branch
        const style = self.chooseColor(branch_type);
        const branch_str = self.chooseString(branch_type, life, dx, dy);

        // Draw branch
        const tree_child = self.vx.window().child(.{
            .x_off = x,
            .y_off = y,
            .height = self.getTreeWinMaxY(),
        });

        // Draw branch only if we're within bounds
        if (x <= self.getTreeWinMaxX() and y <= self.getTreeWinMaxY()) {
            _ = tree_child.printSegment(.{ .text = branch_str, .style = style }, .{});
        }

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
            // Base trunk - straighter with slight variations
            if (age <= 2 or life < 4) {
                returnDy.* = 0; // More consistent upward growth at start
                returnDx.* = self.dice.rollI64(3) - 1; // Slight left/right variation
            }
            // Young trunk should grow more upward with some width
            else if (age < (multiplier * 3)) {
                // More consistent upward growth for young trunk
                if (age % 2 == 0) returnDy.* = -1 else returnDy.* = 0;

                dice = self.dice.rollI64(12);
                if (dice >= 0 and dice <= 1) {
                    returnDx.* = -2; // Occasional strong left
                } else if (dice >= 2 and dice <= 4) {
                    returnDx.* = -1; // Slight left
                } else if (dice >= 5 and dice <= 6) {
                    returnDx.* = 0; // Straight
                } else if (dice >= 7 and dice <= 9) {
                    returnDx.* = 1; // Slight right
                } else if (dice >= 10 and dice <= 11) {
                    returnDx.* = 2; // Occasional strong right
                }
            }
            // Middle-aged trunk - more upward growth
            else {
                dice = self.dice.rollI64(10);
                if (dice > 1) {
                    returnDy.* = -1; // More consistent upward growth (80%)
                } else {
                    returnDy.* = 0; // Occasional pause in height (20%)
                }

                // Less horizontal movement for mature trunk
                returnDx.* = if (self.dice.rollI64(5) == 0)
                    self.dice.rollI64(3) - 1 // Occasional horizontal movement
                else
                    0; // Usually straight up for mature trunk
            }
        },
        // Shoots trend left or right with some vertical variation
        .shootLeft => {
            // More sophisticated vertical movement
            dice = self.dice.rollI64(12);
            if (dice >= 0 and dice <= 2) {
                returnDy.* = -1; // 25% chance to grow upward
            } else if (dice >= 3 and dice <= 8) {
                returnDy.* = 0; // 50% chance to grow level
            } else if (dice >= 9 and dice <= 11) {
                returnDy.* = 1; // 25% chance to grow downward
            }

            // Strong left bias for left shoots
            dice = self.dice.rollI64(12);
            if (dice >= 0 and dice <= 2) {
                returnDx.* = -2; // Strong left
            } else if (dice >= 3 and dice <= 7) {
                returnDx.* = -1; // Moderate left
            } else if (dice >= 8 and dice <= 10) {
                returnDx.* = 0; // Sometimes straight
            } else if (dice == 11) {
                returnDx.* = 1; // Rarely right (natural variation)
            }
        },
        .shootRight => {
            // Similar vertical movement as shootLeft
            dice = self.dice.rollI64(12);
            if (dice >= 0 and dice <= 2) {
                returnDy.* = -1; // 25% chance to grow upward
            } else if (dice >= 3 and dice <= 8) {
                returnDy.* = 0; // 50% chance to grow level
            } else if (dice >= 9 and dice <= 11) {
                returnDy.* = 1; // 25% chance to grow downward
            }

            // Strong right bias for right shoots
            dice = self.dice.rollI64(12);
            if (dice >= 0 and dice <= 2) {
                returnDx.* = 2; // Strong right
            } else if (dice >= 3 and dice <= 7) {
                returnDx.* = 1; // Moderate right
            } else if (dice >= 8 and dice <= 10) {
                returnDx.* = 0; // Sometimes straight
            } else if (dice == 11) {
                returnDx.* = -1; // Rarely left (natural variation)
            }
        },
        // Dying branches - more random for leaf clusters
        .dying => {
            // More vertical variation for leaf clusters
            dice = self.dice.rollI64(15);
            if (dice >= 0 and dice <= 4) {
                returnDy.* = -1; // 33% up
            } else if (dice >= 5 and dice <= 9) {
                returnDy.* = 0; // 33% level
            } else if (dice >= 10 and dice <= 14) {
                returnDy.* = 1; // 33% down
            }

            // Wide horizontal spread for foliage
            dice = self.dice.rollI64(15);
            if (dice == 0) {
                returnDx.* = -3;
            } else if (dice >= 1 and dice <= 3) {
                returnDx.* = -2;
            } else if (dice >= 4 and dice <= 6) {
                returnDx.* = -1;
            } else if (dice >= 7 and dice <= 8) {
                returnDx.* = 0;
            } else if (dice >= 9 and dice <= 11) {
                returnDx.* = 1;
            } else if (dice >= 12 and dice <= 14) {
                returnDx.* = 2;
            } else if (dice == 15) {
                returnDx.* = 3;
            }
        },
        // Dead branches - leaf endpoints
        .dead => {
            // Even distribution of directions for leaves
            dice = self.dice.rollI64(12);
            if (dice >= 0 and dice <= 3) {
                returnDy.* = -1; // 33% up
            } else if (dice >= 4 and dice <= 7) {
                returnDy.* = 0; // 33% level
            } else if (dice >= 8 and dice <= 11) {
                returnDy.* = 1; // 33% down
            }

            // Wide but controlled spread
            dice = self.dice.rollI64(5);
            returnDx.* = dice - 2; // Range from -2 to +2
        },
    }

    // Age-based adjustments to prevent excessive width for old trunks
    if (branch_type == .trunk and age > multiplier * 5) {
        // Bias toward upward growth for older trunks
        if (self.dice.rollI64(10) > 2) {
            returnDy.* = -1;
            returnDx.* = 0;
        }
    }

    if (returnDx.* > 1) {
        returnDx.* = 1;
    } else if (returnDx.* < -1) {
        returnDx.* = -1;
    }

    if (returnDy.* > 1) {
        returnDy.* = 1;
    } else if (returnDy.* < -1) {
        returnDy.* = -1;
    }
}

/// Return vaxis style for color of tree parts
/// Uses the color configuration from args:
/// - dark_leaves / light_leaves for dying/dead branches (leaves)
/// - dark_wood / light_wood for trunk and shoots
inline fn chooseColor(self: *App, branch_type: BranchType) vaxis.Style {
    const colors = self.args.colors;
    
    switch (branch_type) {
        .trunk, .shootLeft, .shootRight => {
            // Wood colors - 50/50 chance of light vs dark
            if (self.dice.rollI64(2) == 0) {
                return vaxis.Style{
                    .fg = .{ .index = colors.light_wood },
                    .bold = true,
                };
            } else {
                return vaxis.Style{
                    .fg = .{ .index = colors.dark_wood },
                    .bold = false,
                };
            }
        },
        .dying => {
            // Dying branches use leaf colors
            // 10% chance of bold/bright
            if (self.dice.rollI64(10) == 0) {
                return vaxis.Style{
                    .fg = .{ .index = colors.light_leaves },
                    .bold = true,
                };
            } else {
                return vaxis.Style{
                    .fg = .{ .index = colors.light_leaves },
                    .bold = false,
                };
            }
        },
        .dead => {
            // Dead branches (final leaves)
            // 33% chance of bold/dark leaves
            if (self.dice.rollI64(3) == 0) {
                return vaxis.Style{
                    .fg = .{ .index = colors.dark_leaves },
                    .bold = true,
                };
            } else {
                return vaxis.Style{
                    .fg = .{ .index = colors.dark_leaves },
                    .bold = false,
                };
            }
        },
    }
}

/// Return a String for the tree branch or leaf
fn chooseString(self: *App, branch_type_input: BranchType, life: usize, dx: i64, dy: i64) []const u8 {
    var branch_type = branch_type_input;
    if (life < 4) branch_type = .dying;

    switch (branch_type) {
        .trunk => {
            if (dy < 0) { // Going up
                if (dx < 0) { // Up and left
                    return if (self.dice.rollI64(2) == 0) "/|" else "\\|";
                } else if (dx == 0) { // Straight up
                    const choices = [_][]const u8{ "|", "│", "║", "/|\\", "/|", "|\\", "|" };
                    const idx = self.dice.rollUsize(choices.len);
                    return choices[idx];
                } else { // Up and right
                    return if (self.dice.rollI64(2) == 0) "|/" else "|\\";
                }
            } else if (dy == 0) { // Horizontal
                if (dx < 0) { // Left
                    return "/~";
                } else if (dx == 0) { // No movement
                    return "/~\\";
                } else { // Right
                    return "~\\";
                }
            } else { // Going down (rare for trunk)
                return "|";
            }
        },
        .shootLeft => {
            if (dy < 0) { // Up and left
                const choices = [_][]const u8{ "/", "\\|", "\\" };
                const idx = self.dice.rollUsize(choices.len);
                return choices[idx];
            } else if (dy == 0) { // Horizontal left
                const choices = [_][]const u8{ "\\_", "\\", "\\~" };
                const idx = self.dice.rollUsize(choices.len);
                return choices[idx];
            } else { // Down and left
                return "\\";
            }
        },
        .shootRight => {
            if (dy < 0) { // Up and right
                const choices = [_][]const u8{ "\\", "|/", "/" };
                const idx = self.dice.rollUsize(choices.len);
                return choices[idx];
            } else if (dy == 0) { // Horizontal right
                const choices = [_][]const u8{ "_/", "/", "~/" };
                const idx = self.dice.rollUsize(choices.len);
                return choices[idx];
            } else { // Down and right
                return "/";
            }
        },
        .dying, .dead => {
            // Use the parsed leaf strings from args
            if (self.args.leafCount == 0) {
                return "&";
            }
            const idx = self.dice.rollUsize(self.args.leafCount);
            return self.args.leafStrings[idx];
        },
    }
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