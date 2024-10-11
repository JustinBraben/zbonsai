const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const ArrayList = std.ArrayList;

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
    branch_type: BranchType,
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
    while(index > 0) {
        index -|= 1;

        const current_branch = self.branches.items[index];
        try self.processBranch(current_branch);
    }
}

/// Given a branch, roll some dice and determine if it will create a branch
pub fn processBranch(self: *Tree, branch: Branch) !void {
    if (branch.life > 0) {

        try self.createNewBranch(branch);

        // Depending on branch to process, determine what kind of branch it should create?
        switch (branch.branch_type) {
            .trunk => {},
            .shootLeft => {},
            .shootRight => {},
            .dying => {},
            .dead => {},
        }

        // // Roughly how the former recursive function operated
        // // TODO: Implement in the non-recursive way
        // if (branch.life < 3) {try createDeadBranch(branch);}
        // else if (branch.branch_type == .trunk and branch.life < (self.options.multiplier + 2)) {try createDyingBranch(branch);}
        // else if ((branch.branch_type == .shootLeft or branch.branch_type == .shootRight) and life < (self.options.multiplier + 2)) {try createDyingBranch(branch);}
        // else if ((branch.branch_type == .trunk and ()) or (branch.life % self.options.multiplier == 0)){
        //     // if trunk is branching and not about to die, create another trunk with random life
		// 	if ((rand() % 8 == 0) && life > 7) {
		// 		shootCooldown = conf->multiplier * 2;	// reset shoot cooldown
		// 		branch(conf, objects, myCounters, y, x, trunk, life + (rand() % 5 - 2));
		// 	}
        //     // otherwise a shoot
        //     else if (shootCooldown <= 0) {

        //     }
        // }
    }
}

fn createNewBranch(self: *Tree, branch: Branch) !void {
    if (self.dice.rollF32() < @as(f32, @floatFromInt(self.options.multiplier)) / 20.0) {
        var x = branch.x;
        var y = branch.y;

        var dx: i64 = 0;
        var dy: i64 = 0;

        const maxY = self.options.max_y;
        // reduce dy if too close to the ground
        if (dy > 0 and y > (maxY -| 2)) dy -= 1;

        const new_direction = self.dice.rollI64(4) - 2;
        switch (new_direction) {
            -2 => dy = -1,
            -1 => dx = 1,
            0 => dy = 1,
            1 => dx = -1,
            else => unreachable,
        }

        if (dy > 0 and branch.y > (self.options.max_y -| 5)) dy -= 1;

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

        var new_branch_type = branch.branch_type;
        if (dx != 0) {
            new_branch_type = if (dx < 0) .shootLeft else .shootRight;
        }


        try self.branches.append(Branch{ .x = x, .y = y, .life = branch.life -| 1, .branch_type = new_branch_type});
    }
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

/// Previous setDeltas when using recursion
fn setDeltas(self: *Tree, branch_type: BranchType, life: usize, age: usize, returnDx: *i64, returnDy: *i64) void {
    var dice: i64 = 0;

    switch (branch_type) {
        .trunk => {

            // new or dead trunk
            if (age <= 2 or life < 4) {
                returnDy.* = 0;
                returnDx.* = self.dice.rollI64(3) - 1;
            }
            // young trunk should grow wide
            else if (age < (self.options.multiplier * 3)) {
                const res = @as(f32, @floatFromInt(self.options.multiplier)) * 0.5;

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

test "Sprout tree" {
    const test_allocator = testing.allocator;

    var tree = Tree.init(test_allocator, .{});
    defer tree.deinit();

    try tree.sproutTree(20, 20);

    try testing.expectEqual(1, tree.branches.items.len);

    try testing.expectError(TreeError.SproutOnNonEmptyTree, tree.sproutTree(20, 20));
    try testing.expectError(TreeError.SproutOnNonEmptyTree, tree.growTree(20, 20));

    if (tree.branches.items.len > 0) {
        
    }
}

test "Grow tree" {
    const test_allocator = testing.allocator;

    var tree = Tree.init(test_allocator, .{ .seed = 1});
    defer tree.deinit();

    // try tree.growTree(20, 20);
    // try testing.expectEqual(1, tree.branches.items.len);
    // try testing.expect(tree.branches.items.len > 0);
    // try testing.expectEqual(31, tree.branches.items[0].life);

    // // With a seeded random we can determine how many items should be available every growTree
    // try tree.growTree(20, 20);
    // try testing.expectEqual(30, tree.branches.items[0].life);
    // try testing.expectEqual(1, tree.branches.items.len);
    // try tree.growTree(20, 20);
    // try testing.expectEqual(2, tree.branches.items.len);
    // try testing.expectEqual(29, tree.branches.items[0].life);
}