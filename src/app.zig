const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const vaxis = @import("vaxis");

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

const App = @This();

allocator: Allocator,
arena: std.heap.ArenaAllocator,
// A flag for if we should quit
should_quit: bool,
/// The tty we are talking to
tty: vaxis.Tty,
/// The vaxis instance
vx: vaxis.Vaxis,
/// A mouse event that we will handle in the draw cycle
mouse: ?vaxis.Mouse,

pub fn init(allocator: Allocator) !App {
    return .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .should_quit = false,
        .tty = try vaxis.Tty.init(),
        .vx = try vaxis.init(allocator, .{}),
        .mouse = null,
    };
}

pub fn deinit(self: *App) void {
    // Deinit takes an optional allocator. You can choose to pass an allocator to clean up
    // memory, or pass null if your application is shutting down and let the OS clean up the
    // memory
    self.vx.deinit(self.allocator, self.tty.anyWriter());
    self.tty.deinit();
    self.arena.deinit();
}

pub fn run(self: *App) !void {
    // Initialize our event loop. This particular loop requires intrusive init
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
        try self.draw();

        // It's best to use a buffered writer for the render method. TTY provides one, but you
        // may use your own. The provided bufferedWriter has a buffer size of 4096
        var buffered = self.tty.bufferedWriter();
        // Render the application to the screen
        try self.vx.render(buffered.writer().any());
        try buffered.flush();
    }
}

/// Update our application state from an event
pub fn update(self: *App, event: Event) !void {
    switch (event) {
        .key_press => |key| {
            // key.matches does some basic matching algorithms. Key matching can be complex in
            // the presence of kitty keyboard encodings, this will generally be a good approach.
            // There are other matching functions available for specific purposes, as well
            if (key.matches('c', .{ .ctrl = true }))
                self.should_quit = true;
        },
        .mouse => |mouse| self.mouse = mouse,
        .winsize => |ws| {
            try self.vx.resize(self.allocator, self.tty.anyWriter(), ws);
        },
        else => {},
    }
}

/// Draw our current state
pub fn draw(self: *App) !void {
    const win = self.vx.window();
    const msg = "Hello";
    _ = try win.printSegment(.{.text = msg}, .{});
}