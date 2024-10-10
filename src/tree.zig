const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const ArrayList = std.ArrayList;

const Dice = @import("dice.zig");

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
    life: usize,
    branch_type: BranchType,
};

/// Configurable options for the Tree
pub const TreeOptions = struct {
    /// Pass in the seed for random tree generation
    seed: u64 = 0,
    multiplier: usize = 5,
    life_start: usize = 32,
};

pub const Tree = struct {
    allocator: Allocator,
    dice: Dice,
    options: TreeOptions,
    branches: ArrayList(Branch),

    pub fn init(allocator: Allocator, options: TreeOptions) Tree {
        return .{
            .allocator = allocator,
            .dice = Dice.initWithSeed(options.seed),
            .options = options,
            .branches = ArrayList(Branch).init(allocator),
        };
    }

    pub fn deinit(self: *Tree) void {
        self.branches.deinit();
    }

    pub fn growTree(self: *Tree, max_x: usize, max_y: usize) !void {
        try self.branches.append(Branch{
            .x = max_x / 2,
            .y = max_y,
            .life = self.options.life_start,
            .branch_type = .trunk,
        });

        while (self.branches.items.len > 0) {
            const current_branch = self.branches.pop();
            try self.processBranch(current_branch);
        }
    }

    fn processBranch(self: *Tree, branch: Branch) !void {
        var x = branch.x;
        var y = branch.y;
        var life = branch.life;
        const branch_type = branch.branch_type;
        var shootCooldown = self.options.multiplier;

        while (life > 0) {
            life -|= 1;
            const age = self.options.life_start -| life;

            var dx: i64 = 0;
            var dy: i64 = 0;
            self.setDeltas(branch_type, life, age, &dx, &dy);

            // Update x and y
            if (dx > 0) {
                x +|= @as(usize, @abs(dx));
            } else {
                x -|= @as(usize, @abs(dx));
            }
            if (dy > 0) {
                y +|= @as(usize, @abs(dy));
            } else {
                y -|= @as(usize, @abs(dy));
            }

            // Branch creation logic
            if (life < 3) {
                try self.branches.append(Branch{ .x = x, .y = y, .life = life, .branch_type = .dead });
            } else if (branch_type == .trunk and life < (self.options.multiplier +| 2)) {
                try self.branches.append(Branch{ .x = x, .y = y, .life = life, .branch_type = .dying });
            } else if ((branch_type == .shootLeft or branch_type == .shootRight) and life < (self.options.multiplier +| 2)) {
                try self.branches.append(Branch{ .x = x, .y = y, .life = life, .branch_type = .dying });
            }
            } else if ((branch_type == .trunk and self.dice.rollUsize(3) == 0) or
                (life % self.options.multiplier == 0))
            {
                if (self.dice.rollUsize(8) == 0 and life > 7) {
                    shootCooldown = self.options.multiplier * 2;
                    const life_offset = self.dice.rollI64(5) - 2;
                    if (life_offset < 0) {
                        try self.branches.append(Branch{
                            .x = x,
                            .y = y,
                            .life = life -| @as(usize, @intCast(@abs(life_offset))),
                            .branch_type = .trunk,
                        });
                    }
                    else {
                        try self.branches.append(Branch{
                            .x = x,
                            .y = y,
                            .life = life +| @as(usize, @intCast(life_offset)),
                            .branch_type = .trunk,
                        });
                    }
                } else if (shootCooldown == 0) {
                    shootCooldown = self.options.multiplier * 2;

                    const new_branch_type = if (self.dice.rollUsize(2) == 0) BranchType.shootLeft else BranchType.shootRight;
                    try self.branches.append(Branch{
                        .x = x,
                        .y = y,
                        .life = life +| self.options.multiplier,
                        .branch_type = new_branch_type,
                    });
                }

                shootCooldown -|= 1;
            }

            // Here you would add the logic to draw the branch
            // For example: self.drawBranch(x, y, branch_type, life);
    }

    fn setDeltas(self: *Tree, branch_type: BranchType, life: usize, age: usize, returnDx: *i64, returnDy: *i64) void {
        // Implement the delta calculation logic here
        // This would be similar to your original setDeltas function
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

    // Add other necessary methods here, such as chooseColor, chooseString, etc.
};

test "Basic tree" {
    const test_allocator = testing.allocator;

    var tree = Tree.init(test_allocator, .{});
    defer tree.deinit();

    try tree.growTree(20, 20);
}