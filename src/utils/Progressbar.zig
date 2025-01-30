const std = @import("std");
const vaxis = @import("vaxis");
const Window = vaxis.Window;

// Consider removing, functionality in libvaxis now I believe

const Progressbar = @This();

/// character to use for the Progressbar
complete_character: vaxis.Cell.Character = .{ .grapheme = "█", .width = 1 },

/// character to use for the Progressbar
incomplete_character: vaxis.Cell.Character = .{ .grapheme = "▒", .width = 1 },

/// style to draw the bar character with
style: vaxis.Style = .{},

width: usize = 10,

height: usize = 1,

/// Current progress of Progressbar.
current_progress: usize = 0,
/// Max progress of Progressbar
max_progress: usize = 10,

pub fn draw(self: Progressbar, win: vaxis.Window) void {
    // Only height of 1 windows are supported for now
    if (win.height != 1) return;

    // const bar_height = std.math.clamp(self.height, 1, win.height);

    var i: usize = 0;
    while (i < self.max_progress and i < win.width) : (i +|= 1) {
        if (i <= self.current_progress) {
            win.writeCell(i, 0, .{ .char = self.complete_character, .style = self.style });
        } else {
            win.writeCell(i, 0, .{ .char = self.incomplete_character, .style = self.style });
        }
    }
}

/// Adds completed progress to the bar
pub fn addProgress(self: *Progressbar, progress: usize) void {
    self.current_progress +|= progress;
}

const sample =
    \\█░░░░░░░░░
;
