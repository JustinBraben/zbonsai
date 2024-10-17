const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const ArrayList = std.ArrayList;

const vaxis = @import("vaxis");
const Style = vaxis.Style;

const Dice = @import("dice.zig");

pub const TreeError = error{
    SproutOnNonEmptyTree,
};

pub const BranchType = enum {
    trunk,
    shootLeft,
    shootRight,
    dying,
    dead,
};

pub const Branch = struct {
    x: usize,
    y: usize,
    life: usize = 32,
    branch_type: BranchType = .trunk,
    style: Style = .{},
};

/// Configurable options for the Tree
pub const TreeOptions = struct {
    /// Set max_x based on window
    max_x: usize = 20,
    /// Set max_y based on window
    max_y: usize = 20,
    /// Pass in the seed for random tree generation
    seed: u64 = 0,
    multiplier: usize = 5,
    life_start: usize = 32,
};

const Tree = @This();

allocator: Allocator,
dice: Dice,
options: TreeOptions,
branches: ArrayList(Branch),
first_grow: bool = true,

pub fn init(allocator: Allocator, options: TreeOptions) Tree {
    return .{
        .allocator = allocator,
        .dice = Dice.initWithSeed(options.seed),
        .options = options,
        .branches = ArrayList(Branch).init(allocator),
        .first_grow = true,
    };
}

pub fn deinit(self: *Tree) void {
    self.branches.deinit();
}

/// Used to make the first trunk of the tree
pub fn sproutTree(self: *Tree, input_max_x: usize, input_max_y: usize) !void {
    if (self.branches.items.len > 0) {
        return TreeError.SproutOnNonEmptyTree;
    }

    try self.branches.append(Branch{
        .x = input_max_x / 2,
        .y = input_max_y,
        .life = self.options.life_start,
        .branch_type = .trunk,
    });

    self.options.max_x = input_max_x;
    self.options.max_x = input_max_y;
}

pub fn growTree(self: *Tree, input_max_x: usize, input_max_y: usize) !void {
    if (self.first_grow) {
        try self.sproutTree(input_max_x, input_max_y);
        self.first_grow = false;
    }

    var index: usize = self.branches.items.len;
    while (index > 0) {
        index -|= 1;

        const current_branch = self.branches.items[index];
        if (current_branch.life > 0) {
            try self.processBranch(current_branch);
        }
    }
}

/// Given a branch, roll some dice and determine if it will create a branch
pub fn processBranch(self: *Tree, branch: Branch) !void {
    // How long the branch has been around
    const age = self.options.life_start -| branch.life;

    // const growth_chance = @as(f32, @floatFromInt(self.options.multiplier)) / 20.0;

    var dx: i64 = 0;
    var dy: i64 = 0;

    dx = self.setDeltaX(branch, age);
    dy = self.setDeltaY(branch, age);

    if (dy > 0 and branch.y > (self.options.max_y -| 5)) dy -= 1;

    if (branch.life < 3) { try self.createNewBranch(branch, dx, dy, .dead); }
    // else if (branch.branch_type == .trunk and branch.life < (self.options.multiplier +| 2)) {
    //     try self.createNewBranch(branch, dx, dy, .dying);
    // }
    // else if ((branch.branch_type == .shootLeft or branch.branch_type == .shootRight) and branch.life < (self.options.multiplier +| 2)) {
    //     try self.createNewBranch(branch, dx, dy, .dying);
    // } else if ((branch.branch_type == .trunk and self.dice.rollUsize(3) == 0) or
    //     (branch.life % self.options.multiplier == 0))
    // {

    // }
}

//         // // Roughly how the former recursive function operated
//         // // TODO: Implement in the non-recursive way
//         // if (branch.life < 3) {try createDeadBranch(branch);}
//         // else if (branch.branch_type == .trunk and branch.life < (self.options.multiplier + 2)) {try createDyingBranch(branch);}
//         // else if ((branch.branch_type == .shootLeft or branch.branch_type == .shootRight) and life < (self.options.multiplier + 2)) {try createDyingBranch(branch);}
//         // else if ((branch.branch_type == .trunk and ()) or (branch.life % self.options.multiplier == 0)){
//         //     // if trunk is branching and not about to die, create another trunk with random life
//         // 	if ((rand() % 8 == 0) && life > 7) {
//         // 		shootCooldown = conf->multiplier * 2;	// reset shoot cooldown
//         // 		branch(conf, objects, myCounters, y, x, trunk, life + (rand() % 5 - 2));
//         // 	}
//         //     // otherwise a shoot
//         //     else if (shootCooldown <= 0) {

//         //     }
//         // }
//     }
// }

fn createNewBranch(self: *Tree, branch: Branch, dx: i64, dy: i64, new_branch_type: BranchType) !void {
    var x = branch.x;
    var y = branch.y;

    // move in x and y directions
    if (dx > 0) {
        x +|= @as(usize, @intCast(@abs(dx)));
    } else {
        x -|= @as(usize, @intCast(@abs(dx)));
    }

    if (dy > 0) {
        y +|= @as(usize, @intCast(@abs(dy)));
    } else {
        y -|= @as(usize, @intCast(@abs(dy)));
    }

    const new_branch = Branch{
        .x = x,
        .y = y,
        .life = branch.life,
        .branch_type = new_branch_type,
        .style = self.chooseColor(new_branch_type),
    };

    try self.branches.append(new_branch);
}

/// Decrements the life of every tree branch
/// Should be called after every growTree
pub fn updateLife(self: *Tree) void {
    for (self.branches.items, 0..) |branch, index| {
        if (branch.life > 0) self.branches.items[index].life = self.branches.items[index].life -| 1;
    }
}

/// Determines if life has completed on the tree
/// If all branches have ran out of life, no need to grow the tree anymore
pub fn treeComplete(self: *Tree) bool {
    for (self.branches.items) |branch| {
        if (branch.life > 0) return false;
    }

    return true;
}

/// Count the `.trunk` branches in the tree
pub fn trunkCounter(self: *Tree) usize {
    var count: usize = 0;
    for (self.branches.items) |branch| {
        if (branch.branch_type == .trunk) count +|= 1;
    }
    return count;
}

/// Count all `.shootLeft` branches in the tree
pub fn shootLeftCounter(self: *Tree) usize {
    var count: usize = 0;
    for (self.branches.items) |branch| {
        if (branch.branch_type == .shootLeft) count +|= 1;
    }
    return count;
}

/// Count all `.shootRight` branches in the tree
pub fn shootRightCounter(self: *Tree) usize {
    var count: usize = 0;
    for (self.branches.items) |branch| {
        if (branch.branch_type == .shootRight) count +|= 1;
    }
    return count;
}

/// Count all `.dying` branches in the tree
pub fn dyingCounter(self: *Tree) usize {
    var count: usize = 0;
    for (self.branches.items) |branch| {
        if (branch.branch_type == .dying) count +|= 1;
    }
    return count;
}

/// Return vaxis style for color of tree parts
fn chooseColor(self: *Tree, branch_type: BranchType) vaxis.Style {
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

fn setDeltaX(self: *Tree, branch: Branch, age: usize) i64 {
    switch (branch.branch_type) {
        .trunk => {
            // new or dead trunk
            if (age <= 2 or branch.life < 4) {
                return self.dice.rollI64(3) - 1;
            }
            // young trunk should grow wide
            else if (age < (self.options.multiplier * 3)) {

                switch (self.dice.rollI64(10)) {
                    0 => return -2,
                    1,2,3 => return -1,
                    4,5 => return 0,
                    6,7,8 => return 1,
                    9 => return 2,
                    else => unreachable,
                }
            }
            // middle-aged trunk
            else {
                return self.dice.rollI64(3) - 1;
            }
        },
        .shootLeft => {
            switch (self.dice.rollI64(10)) {
                0,1 => return -2,
                2,3,4,5 => return -1,
                6,7,8 => return 0,
                9 => return 1,
                else => unreachable,
            }
        },
        .shootRight => {
            switch (self.dice.rollI64(10)) {
                0,1 => return 2,
                2,3,4,5 => return 1,
                6,7,8 => return 0,
                9 => return -1,
                else => unreachable,
            }
        },
        .dying => {
            switch (self.dice.rollI64(15)) {
                0 => return -3,
                1,2 => return -2,
                3,4,5 => return -1,
                6,7,8 => return 0,
                9,10,11 => return 1,
                12,13 => return 2,
                14 => return 3,
                else => unreachable,
            }
        },
        .dead => return self.dice.rollI64(3) - 1,
    }
}

fn setDeltaY(self: *Tree, branch: Branch, age: usize) i64 {
    switch (branch.branch_type) {
        .trunk => {
            // new or dead trunk
            if (age <= 2 or branch.life < 4) {
                return 0;
            }
            // young trunk should grow wide
            else if (age < (self.options.multiplier * 3)) {
                const res = @as(f32, @floatFromInt(self.options.multiplier)) * 0.5;
                // every (multiplier * 0.5) steps, raise tree to next level
                if (age % @as(usize, @intFromFloat(res)) == 0) return -1 else return 0;
            }
            // middle-aged trunk
            else {
                if (self.dice.rollI64(10) > 2) return -1 else return 0;
            }
        },
        .shootLeft => {
            switch (self.dice.rollI64(10)) {
                0,1 => return -1,
                2,3,4,5,6,7  => return 0,
                8,9 => return 1,
                else => unreachable,
            }
        },
        .shootRight => {
            switch (self.dice.rollI64(10)) {
                0,1 => return -1,
                2,3,4,5,6,7  => return 0,
                8,9 => return 1,
                else => unreachable,
            }
        },
        .dying => {
            switch (self.dice.rollI64(10)) {
                0,1 => return -1,
                2,3,4,5,6,7,8  => return 0,
                9 => return 1,
                else => unreachable,
            }
        },
        .dead => {
            switch (self.dice.rollI64(10)) {
                0,1,2 => return -1,
                3,4,5,6  => return 0,
                7,8,9 => return 1,
                else => unreachable,
            }
        },
    }
}

test "Sprout tree" {
    const test_allocator = testing.allocator;

    var tree = Tree.init(test_allocator, .{});
    defer tree.deinit();

    try tree.sproutTree(20, 20);

    try testing.expectEqual(1, tree.branches.items.len);

    try testing.expectError(TreeError.SproutOnNonEmptyTree, tree.sproutTree(20, 20));
    try testing.expectError(TreeError.SproutOnNonEmptyTree, tree.growTree(20, 20));

    if (tree.branches.items.len > 0) {}
}

test "Grow tree" {
    const test_allocator = testing.allocator;

    // With a seeded random we can determine how many items should be available every growTree
    var tree = Tree.init(test_allocator, .{ .seed = 1 });
    defer tree.deinit();

    try tree.growTree(20, 20);
    tree.updateLife();
    // try testing.expectEqual(1, tree.branches.items.len);
    // try testing.expect(tree.branches.items.len > 0);
    // try testing.expectEqual(32, tree.branches.items[0].life);

    var index: usize = 0;
    while (!tree.treeComplete()) {
        try tree.growTree(20, 20);
        tree.updateLife();

        switch (index) {
            0...28 => try testing.expectEqual(1, tree.branches.items.len),
            29 => try testing.expectEqual(2, tree.branches.items.len),
            30 => try testing.expectEqual(4, tree.branches.items.len),
            // 31...5000 => try testing.expectEqual(2, tree.branches.items.len),
            // 32 => try testing.expectEqual(2, tree.branches.items.len),
            // 33 => try testing.expectEqual(2, tree.branches.items.len),
            else => unreachable,
        }

        index +|= 1;
    }
    
    // try tree.growTree(20, 20);
    // tree.updateLife();
    // try testing.expectEqual(1, tree.branches.items.len);
    // try testing.expect(tree.branches.items.len > 0);

    // try tree.growTree(20, 20);
    // tree.updateLife();
}
