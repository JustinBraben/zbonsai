const std = @import("std");
const vaxis = @import("vaxis");
const Window = vaxis.Window;
const Cell = vaxis.Cell;

const Spinner = @This();

/// Windows doesn't have access to these by default, although
/// can be supported with unicode
const posix_characters = &[_][]const u8{
    "⠋",
    "⠙",
    "⠹",
    "⠸",
    "⠼",
    "⠴",
    "⠦",
    "⠧",
    "⠇",
    "⠏",
};

const windows_characters = &[_][]const u8{
    "+",
    "-",
    "x",
    "|",
};

/// character to use for the Progressbar
character: vaxis.Cell.Character = .{ .grapheme = "+", .width = 1 },

/// style to draw the bar character with
style: vaxis.Style = .{},

width: usize = 1,

height: usize = 1,

index: usize = 0,

pub fn draw(self: Spinner, win: vaxis.Window) void {
    // Only height of 1 windows are supported for now
    // if (win.height != 1 or win.width != 0) return;

    win.writeCell(0, 0, .{ .char = self.character, .style = self.style });
}

/// Adds completed progress to the bar
pub fn update(self: *Spinner) void {
    self.index +%= 1;
    if (self.index >= posix_characters.len) self.index = 0;
    self.character = .{ .grapheme = posix_characters[self.index], .width = 1 };
}

const sample =
    \\⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏
;
