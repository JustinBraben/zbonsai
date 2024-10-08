const std = @import("std");
const ArrayList = std.ArrayList;

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

pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    rand: std.rand.Random,
    multiplier: usize,
    life_start: usize,
    branches: ArrayList(Branch),

    pub fn init(allocator: std.mem.Allocator, seed: u64, multiplier: usize, life_start: usize) Tree {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .rand = std.rand.DefaultPrng.init(seed).random(),
            .multiplier = multiplier,
            .life_start = life_start,
            .branches = ArrayList(Branch).init(allocator),
        };
    }

    pub fn deinit(self: *Tree) void {
        self.branches.deinit();
        self.arena.deinit();
    }

    pub fn growTree(self: *Tree, max_x: usize, max_y: usize) !void {
        try self.branches.append(Branch{
            .x = max_x / 2,
            .y = max_y,
            .life = self.life_start,
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

        while (life > 0) {
            life -|= 1;
            const age = self.life_start -| life;

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
            } else if (branch_type == .trunk and life < (self.multiplier +| 2)) {
                try self.branches.append(Branch{ .x = x, .y = y, .life = life, .branch_type = .dying });
            } else if ((branch_type == .shootLeft or branch_type == .shootRight) and life < (self.multiplier +| 2)) {
                try self.branches.append(Branch{ .x = x, .y = y, .life = life, .branch_type = .dying });
            } else if ((branch_type == .trunk and self.rand.intRangeLessThan(usize, 0, 3) == 0) or
                (life % self.multiplier == 0))
            {
                if (self.rand.intRangeLessThan(usize, 0, 8) == 0 and life > 7) {
                    try self.branches.append(Branch{
                        .x = x,
                        .y = y,
                        .life = life + (self.rand.intRangeLessThan(usize, 0, 5) -| 2),
                        .branch_type = .trunk,
                    });
                } else {
                    const new_branch_type = if (self.rand.intRangeLessThan(usize, 0, 2) == 0) BranchType.shootLeft else BranchType.shootRight;
                    try self.branches.append(Branch{
                        .x = x,
                        .y = y,
                        .life = life +| self.multiplier,
                        .branch_type = new_branch_type,
                    });
                }
            }

            // Here you would add the logic to draw the branch
            // For example: self.drawBranch(x, y, branch_type, life);
        }
    }

    fn setDeltas(self: *Tree, branch_type: BranchType, life: usize, age: usize, dx: *i64, dy: *i64) void {
        // Implement the delta calculation logic here
        // This would be similar to your original setDeltas function
        _ = &self;
        _ = branch_type;
        _ = life;
        _ = age;
        _ = &dx;
        _ = &dy;
    }

    // Add other necessary methods here, such as chooseColor, chooseString, etc.
};