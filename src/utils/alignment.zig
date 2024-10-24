const vaxis = @import("vaxis");
const Window = vaxis.Window;

pub fn topLeft(parent: Window, cols: usize, rows: usize) Window {
    const y_off = 0;
    const x_off = 0;
    return parent.child(.{ .x_off = x_off, .y_off = y_off, .width = .{ .limit = cols }, .height = .{ .limit = rows } });
}

pub fn topRight(parent: Window, cols: usize, rows: usize) Window {
    const y_off = 0;
    const x_off = parent.width -| cols;
    return parent.child(.{ .x_off = x_off, .y_off = y_off, .width = .{ .limit = cols }, .height = .{ .limit = rows } });
}

pub fn bottomLeft(parent: Window, cols: usize, rows: usize) Window {
    const y_off = parent.height -| rows;
    const x_off = 0;
    return parent.child(.{ .x_off = x_off, .y_off = y_off, .width = .{ .limit = cols }, .height = .{ .limit = rows } });
}

pub fn bottomRight(parent: Window, cols: usize, rows: usize) Window {
    const y_off = parent.height -| rows;
    const x_off = parent.width -| cols;
    return parent.child(.{ .x_off = x_off, .y_off = y_off, .width = .{ .limit = cols }, .height = .{ .limit = rows } });
}
