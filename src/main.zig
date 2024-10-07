const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const debug = std.debug;
const print = debug.print;
const io = std.io;
const builtin = std.builtin;

const BaseType = @import("base_type.zig").BaseType;
const Styles = @import("styles.zig");
const Args = @import("args.zig").Args;
const errors = @import("errors.zig");

const vaxis = @import("vaxis");

const branchType = enum {
    trunk,
    shootLeft,
    shootRight,
    dying,
    dead
};

const vaxisObjects = struct {
    baseWin: ?*vaxis.Window = null,
    treeWin: ?*vaxis.Window = null,
    messageBorderWin: ?*vaxis.Window = null,
    messageWin: ?*vaxis.Window = null,
};

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

/// own custom events
const Event = union(enum) {
    key_press: vaxis.Key,
    key_release: vaxis.Key,
    mouse: vaxis.Mouse,
    focus_in, // window has gained focus
    focus_out, // window has lost focus
    paste_start, // bracketed paste start
    paste_end, // bracketed paste end
    paste: []const u8, // osc 52 paste, caller must free
    color_report: vaxis.Color.Report, // osc 4, 10, 11, 12 response
    color_scheme: vaxis.Color.Scheme, // light / dark OS theme changes
    winsize: vaxis.Winsize, // the window size has changed. This event is always sent when the loop
    // is started
};

pub fn main() !void {
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer {
    //     const deinit_status = gpa.deinit();
    //     //fail test; can't try in defer as defer is executed after we return
    //     if (deinit_status == .leak) {
    //         std.log.err("memory leak", .{});
    //     }
    // }
    const allocator = std.heap.c_allocator;

    var args = try Args.parse_args(allocator);
    defer args.deinit();

    if (args.seed == 0){
        args.seed = @as(u64, @intCast(std.time.timestamp()));
    }

    // print("args.lifeStart: {d}\n", .{args.lifeStart});
    // print("args.timeStep: {d}\n", .{args.timeStep});

    // var objects = vaxisObjects{};
    // _ = &objects;

    // Initialize our application
    var app = try App.init(allocator, args);
    defer app.deinit();

    // Run the application
    try app.run();
}

const App = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    // A flag to show config
    show_config: bool,
    // A flag for if we should quit
    should_quit: bool,
    /// The tty we are talking to
    tty: vaxis.Tty,
    /// The vaxis instance
    vx: vaxis.Vaxis,
    /// A mouse event that we will handle in the draw cycle
    mouse: ?vaxis.Mouse,
    rand: std.rand.Xoshiro256,
    args: Args,

    pub fn init(allocator: Allocator, args: Args) !App {
        // var tty = try vaxis.Tty.init();
        // var vx = try vaxis.init(allocator, .{});

        // // Initialize our event loop. This particular loop requires intrusive init
        // var loop: vaxis.Loop(Event) = .{
        //     .tty = &tty,
        //     .vaxis = &vx,
        // };
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .show_config = false,
            .should_quit = false,
            .tty = try vaxis.Tty.init(),
            .vx = try vaxis.init(allocator, .{}),
            .mouse = null,
            .rand = std.rand.DefaultPrng.init(0),
            .args = args,
        };
    }

    pub fn deinit(self: *App) void {
        // Deinit takes an optional allocator. You can choose to pass an allocator to clean up
        // memory, or pass null if your application is shutting down and let the OS clean up the
        // memory

        if (!self.args.printTree) {
            self.vx.deinit(self.allocator, self.tty.anyWriter());
            self.tty.deinit();
        }
        else {
            var buffered = self.tty.bufferedWriter();
            self.vx.render(buffered.writer().any()) catch {};
            self.vx.resetState(self.tty.anyWriter()) catch {};
            self.tty.deinit();
        }
        self.arena.deinit();
    }

    pub fn run(self: *App) !void {

        var loop: vaxis.Loop(Event) = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };
        try loop.init();
        
        // Start the event loop. Events will now be queued
        try loop.start();

        try self.vx.enterAltScreen(self.tty.anyWriter());

        // Query the terminal to detect advanced features, such as kitty keyboard protocol, etc.
        // This will automatically enable the features in the screen you are in, so you will want to
        // call it after entering the alt screen if you are a full screen application. The second
        // arg is a timeout for the terminal to send responses. Typically the response will be very
        // fast, however it could be slow on ssh connections.
        try self.vx.queryTerminal(self.tty.anyWriter(), 1 * std.time.ns_per_s);

        // Enable mouse events
        try self.vx.setMouseMode(self.tty.anyWriter(), true);

        var myCounters = std.mem.zeroes(Counters);
        // _ = &myCounters;

        // This is the main event loop. The basic structure is
        // 1. Handle events
        // 2. Draw application
        // 3. Render
        while (!self.should_quit) {
            // pollEvent blocks until we have an event
            loop.pollEvent();
            // tryEvent returns events until the queue is empty
            while (loop.tryEvent()) |event| {
                try self.update(event);
            }

            // Draw our application after handling events
            // try self.draw();

            // if (self.show_config){
            //     try self.drawConfig();
            // }

            try self.drawWins();

            try self.growTree(&myCounters);

            // It's best to use a buffered writer for the render method. TTY provides one, but you
            // may use your own. The provided bufferedWriter has a buffer size of 4096
            var buffered = self.tty.bufferedWriter();
            // Render the application to the screen
            try self.vx.render(buffered.writer().any());

            // Should quit after one run
            // self.should_quit = true;

            if (!self.args.printTree){
                try buffered.flush();
            }   
        }
    }

    /// Update our application state from an event
    pub fn update(self: *App, event: Event) !void {
        switch (event) {
            .key_press => |key| {
                // key.matches does some basic matching algorithms. Key matching can be complex in
                // the presence of kitty keyboard encodings, this will generally be a good approach.
                // There are other matching functions available for specific purposes, as well
                if (key.matches('c', .{ .ctrl = true })){
                    self.should_quit = true;
                }
                // else if (key.matches('e', .{})){
                //     self.show_config = true;
                // }
                // else if (key.matches('r', .{})){
                //     self.show_config = false;
                // }
            },
            .mouse => |mouse| self.mouse = mouse,
            .winsize => |ws| {
                try self.vx.resize(self.allocator, self.tty.anyWriter(), ws);
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

    /// Draw our current state
    pub fn draw(self: *App) !void {
        const win = self.vx.window();
        if (win.width == 0) {
            return;
        }

        win.clear();

        self.vx.setMouseShape(.default);

        try self.drawWins();
    }

    pub fn drawConfig(self: *App) !void {
        const win = self.vx.window();
        const msg = try std.fmt.allocPrint(
            self.arena.allocator(), 
            \\live: {}
                \\infinite: {}
                \\screensaver: {}
                \\printTree: {}
                \\seed: {d}
                \\saveFile: {s}
                \\loadFile: {s}
            , 
            .{
                self.args.live, 
                self.args.infinite, 
                self.args.screensaver,
                self.args.printTree,
                self.args.seed,
                self.args.saveFile,
                self.args.loadFile,
            }
        );
        _ = try win.printSegment(.{ .text = msg[0..], .style = .{} }, .{});
    }

    fn drawWins(self: *App) !void {
        try self.drawBase();
        // try self.drawTree();
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
                    .width = .{ .limit = 16 },
                    .height = .{ .limit = 2 },
                });

                _ = try pot_child.printSegment(.{ .text = msg, .style = Styles.pot_style }, .{});

                const plant_base = &[_]vaxis.Segment{
                    .{ .text = "(", .style = Styles.pot_style},
                    .{ .text = "---", .style = Styles.green_bottom_style},
                    .{ .text = "./~~~\\.", .style = Styles.tree_base_style},
                    .{ .text = "---", .style = Styles.green_bottom_style},
                    .{ .text = ")", .style = Styles.pot_style},
                };

                const plant_base_child = win.child(.{
                    .x_off = x_pos,
                    .y_off = y_pos -| 1,
                    .width = .{ .limit = 15 },
                    .height = .{ .limit = 1 },
                });

                var plant_base_offset: usize = 0;
                for (plant_base) |seg| {
                    _ = try plant_base_child.printSegment(seg, .{
                        .col_offset = plant_base_offset,
                        .wrap = .none,
                    });
                    plant_base_offset += seg.text.len;
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
                    .width = .{ .limit = 33 },
                    .height = .{ .limit = 3 },
                });

                _ = try pot_child.printSegment(.{ .text = msg, .style = Styles.pot_style }, .{});

                const plant_base = &[_]vaxis.Segment{
                    .{ .text = ":", .style = Styles.pot_style},
                    .{ .text = "___________", .style = Styles.green_bottom_style},
                    .{ .text = "./~~~\\.", .style = Styles.tree_base_style},
                    .{ .text = "___________", .style = Styles.green_bottom_style},
                    .{ .text = ":", .style = Styles.pot_style},
                };

                const plant_base_child = win.child(.{
                    .x_off = x_pos +| 2,
                    .y_off = y_pos -| 1,
                    .width = .{ .limit = 32 },
                    .height = .{ .limit = 1 },
                });

                var plant_base_offset: usize = 0;
                for (plant_base) |seg| {
                    _ = try plant_base_child.printSegment(seg, .{
                        .col_offset = plant_base_offset,
                        .wrap = .none,
                    });
                    plant_base_offset += seg.text.len;
                }
            }
        }
    }

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

                _ = try tree_child.printSegment(.{ .text = "/~\\", .style = Styles.tree_base_style }, .{});
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

                _ = try tree_child.printSegment(.{ .text = "/~\\", .style = Styles.tree_base_style }, .{});
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

                _ = try tree_child.printSegment(.{ .text = "/~\\", .style = Styles.tree_base_style }, .{});
            },
        }
    }

    fn growTree(self: *App, myCounters: *Counters) !void {
        var maxX: usize = 0;
        var maxY: usize = 0;

        maxX = self.getTreeWinMaxX();
        maxY = self.getTreeWinMaxY();

        myCounters.*.shoots = 0;
        myCounters.*.branches = 0;
        myCounters.*.shootCounter = self.rand.random().int(usize);

        // recursively grow tree trunk and branches
	    try self.branch(myCounters, (maxX / 2), (maxY), .trunk, self.args.lifeStart);

        // if live, update screen
        // skip updating if we're still loading from file
        if (self.args.live and !(self.args.load and myCounters.*.branches < self.args.targetBranchCount)) {
            try self.updateScreen(self.args.timeStep);
        }
    }

    fn branch(self: *App, myCounters: *Counters, x_input: usize, y_input: usize, branch_type_input: branchType, life_input: usize) !void {
        var x = x_input;
        var y = y_input;
        var life = life_input;
        var branch_type = branch_type_input;

        myCounters.*.branches +|= 1;
        var dx: i64 = 0;
        var dy: i64 = 0;
        var age: usize = 0;
        var shootCooldown = self.args.multiplier;

        while (life > 0) {
            // Use the loop to check for key presses here. And set up exit if necessary

            life -|= 1;
            age = self.args.lifeStart - life;

            self.setDeltas(branch_type, life, age, self.args.multiplier, &dx, &dy);

            const maxY = self.getTreeWinMaxY();
            if (dy > 0 and y > (maxY -| 2)) dy -= 1;

            if (life < 3) {
                try self.branch(myCounters, x, y, .dead, life);
            }
            // else if (branch_type == .trunk and life < (self.args.multiplier +| 2)) {
            //     try self.branch(myCounters, x, y, .dying, life);
            // }
            // else if ((branch_type == .shootLeft or branch_type == .shootRight) and life < (self.args.multiplier +| 2)){
            //     try self.branch(myCounters, x, y, .dying, life);
            // }
            // else if((branch_type == .trunk and self.rand.random().intRangeLessThan(usize, 0, 3) == 0) or 
            //         (life % self.args.multiplier == 0)) {
                
            //     if (self.rand.random().intRangeLessThan(usize, 0, 8) == 0 and life > 7) {
            //         shootCooldown = self.args.multiplier * 2;
            //         try self.branch(myCounters, x, y, .trunk, life + (self.rand.random().intRangeLessThan(usize, 0, 5) -| 2));
            //     }
            //     else if (shootCooldown == 0) {
            //         shootCooldown = self.args.multiplier * 2;

            //         myCounters.*.shoots +|= 1;
            //         myCounters.*.shootCounter +|= 1;

            //         try self.branch(myCounters, x, y, .shootLeft, (life +| self.args.multiplier));
            //     }
            // }

            shootCooldown -|= 1;

            // move in x and y directions
            if (@as(usize, @intCast(@abs(dx))) > x) {
                x = 0;
            }
            else {
                x -|= @as(usize, @intCast(@abs(dx)));
            }

            if (@as(usize, @intCast(@abs(dy))) > y) {
                y = 0;
            }
            else {
                y -|= @as(usize, @intCast(@abs(dx)));
            }

            // Choose color for this branch
            // branch_type = self.chooseColor(branch_type);
            _ = &branch_type;

            // const branch_str = try self.chooseString(branch_type, life, dx, dy);
            const branch_str = "/|";
            
            const win = self.vx.window();

            const x_pos = x;
            const y_pos = y;
            const y_max = self.getTreeWinMaxY();

            const tree_child = win.child(.{
                .x_off = x_pos,
                .y_off = y_pos,
                .height = .{ .limit = y_max },
            });

            _ = try tree_child.printSegment(.{ .text = branch_str, .style = Styles.tree_base_style}, .{});
        }
    }

    fn setDeltas(self: *App, branch_type: branchType, life: usize, age: usize, multiplier: usize, returnDx: *i64, returnDy: *i64) void {
        var dx: i64 = 0;
        var dy: i64 = 0;
        var dice: i64 = 0;

        switch (branch_type) {
            .trunk => {
                
                // new or dead trunk
                if (age <= 2 or life < 4) {
                    dy = 0;
                    dx = self.rand.random().intRangeLessThan(i64, -1, 2);
                }
                // young trunk should grow wide
                else if (age < (multiplier * 3)) {

                    const res = @as(f32, @floatFromInt(multiplier)) * 0.5;

                    // every (multiplier * 0.8) steps, raise tree to next level
                    if (age % @as(usize, @intFromFloat(res)) == 0) dy = -1 else dy = 0;

                    self.roll(&dice, 10);
                    if (dice >= 0 and dice <= 0) { dx = -2; }
                    else if (dice >= 1 and dice <= 3) { dx = -1; }
                    else if (dice >= 4 and dice <= 5) { dx = 0; }
                    else if (dice >= 6 and dice <= 8) { dx = 1; }
                    else if (dice >= 9 and dice <= 9) { dx = 2; }
                }
                // middle-age trunk
                else {
                    self.roll(&dice, 10);
                    if (dice > 2) { dy = -1; }
                    else { dy = 0; }
                    dx = self.rand.random().intRangeLessThan(i64, -1, 2);
                }
            },
            // trend left and a little vertical movement
            .shootLeft => {
                self.roll(&dice, 10);
                if (dice >= 0 and dice <= 1) { dy = -1; }
                else if (dice >= 2 and dice <= 7) { dy = 0; }
                else if (dice >= 8 and dice <= 9) { dy = 1; }

                self.roll(&dice, 10);
                if (dice >= 0 and dice <= 1) { dx = -2; }
                else if (dice >= 2 and dice <= 5) { dx = -1; }
                else if (dice >= 6 and dice <= 8) { dy = 0; }
                else if (dice >= 9 and dice <= 9) { dx = 1; }
            },
            // tren right and a little vertical movement
            .shootRight => {
                self.roll(&dice, 10);
                if (dice >= 0 and dice <= 1) { dy = -1; }
                else if (dice >= 2 and dice <= 7) { dy = 0; }
                else if (dice >= 8 and dice <= 9) { dy = 1; }

                self.roll(&dice, 10);
                if (dice >= 0 and dice <= 1) { dx = 2; }
                else if (dice >= 2 and dice <= 5) { dx = 1; }
                else if (dice >= 6 and dice <= 8) { dy = 0; }
                else if (dice >= 9 and dice <= 9) { dx = -1; }
            },
            // discourage vertical growth(?); trend left/right (-3,3)
            .dying => {
                self.roll(&dice, 10);
                if (dice >= 0 and dice <= 1) { dy = -1; }
                else if (dice >= 2 and dice <= 8) { dy = 0; }
                else if (dice >= 9 and dice <= 9) { dy = 1; }

                self.roll(&dice, 15);
                if (dice >= 0 and dice <= 0) { dx = -3; }
                else if (dice >= 1 and dice <= 2) { dx = -2; }
                else if (dice >= 3 and dice <= 5) { dy = 1; }
                else if (dice >= 6 and dice <= 8) { dx = 0; }
                else if (dice >= 9 and dice <= 11) { dx = 1; }
                else if (dice >= 12 and dice <= 13) { dx = 2; }
                else if (dice >= 14 and dice <= 14) { dx = 3; }
            },
            .dead => {
                self.roll(&dice, 10);
                if (dice >= 0 and dice <= 2) { dy = -1; }
                else if (dice >= 3 and dice <= 6) { dy = 0; }
                else if (dice >= 7 and dice <= 9) { dy = 1; }
                dx = self.rand.random().intRangeLessThan(i64, -1, 2);
            }
        }

        returnDx.* = dx;
        returnDy.* = dy;
    }

    fn chooseString(self: *App, branch_type_input: branchType, life: usize, dx: i64, dy: i64) ![]const u8 {
        var branch_type = branch_type_input;

        const max_str_len: usize = 32;
        var branch_str: []u8 = undefined;
        branch_str = try self.arena.allocator().alloc(u8, max_str_len);
        std.mem.copyForwards(u8, branch_str, "?");

        if (life < 4) branch_type = .dying;

        switch (branch_type) {
            .trunk => {
                if (dy == 0) { std.mem.copyForwards(u8, branch_str, "/~"); }
                else if (dx < 0) { std.mem.copyForwards(u8, branch_str, "\\|"); }
                else if (dx == 0) { std.mem.copyForwards(u8, branch_str, "/|\\"); }
                else if (dx > 0) { std.mem.copyForwards(u8, branch_str, "|/"); }
            },
            .shootLeft => {
                if (dy > 0) { std.mem.copyForwards(u8, branch_str, "\\"); }
                else if (dy == 0) { std.mem.copyForwards(u8, branch_str, "\\_"); }
                else if (dx < 0) { std.mem.copyForwards(u8, branch_str, "\\|"); }
                else if (dx == 0) { std.mem.copyForwards(u8, branch_str, "/|"); }
                else if (dx > 0) { std.mem.copyForwards(u8, branch_str, "/"); }
            },
            .shootRight => {
                if (dy > 0) { std.mem.copyForwards(u8, branch_str, "/"); }
                else if (dy == 0) { std.mem.copyForwards(u8, branch_str, "_/"); }
                else if (dx < 0) { std.mem.copyForwards(u8, branch_str, "\\|"); }
                else if (dx == 0) { std.mem.copyForwards(u8, branch_str, "/|"); }
                else if (dx > 0) { std.mem.copyForwards(u8, branch_str, "/"); }
            },
            .dying, .dead => {
                const rand_index = self.rand.random().intRangeLessThan(usize, 0, max_str_len);
                std.mem.copyForwards(u8, branch_str, self.args.leaves[0..rand_index]);
            }

        }

        return branch_str;
    }

    fn roll(self: *App, dice: *i64, mod: i64) void {
        dice.* = self.rand.random().intRangeLessThan(i64, 0, mod);
    }

    fn getTreeWinMaxY(self: *App) usize {
        const win = self.vx.window();

        return switch (self.args.baseType) {
            .none => (win.height -| 1),
            .small => (win.height -| 4),
            .large => (win.height -| 5),
        };
    }

    fn getTreeWinMaxX(self: *App) usize {
        const win = self.vx.window();

        return switch (self.args.baseType) {
            .none, .small, .large => (win.width),
        };
    }
};

const Counters = struct {
	branches: usize = 0,
	shoots: usize = 0,
	shootCounter: usize = 0,
};