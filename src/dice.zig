const std = @import("std");
const testing = std.testing;

pub const Dice = struct {
    seed: u64 = 0, 
    rand: std.rand.Xoshiro256,

    pub fn initWithGeneratedSeed() Dice {
        return .{
            .rand = std.rand.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp()))),
        };
    }

    pub fn initWithSeed(input_seed: u64) Dice {
        return .{
            .rand = std.rand.DefaultPrng.init(input_seed),
        };
    }

    pub fn roll(self: *Dice, less_than: i64) i64 {
        return self.rand.random().intRangeLessThan(i64, 0, less_than);
    }
};

fn rollWithinBounds(actual: i64, lower: i64, upper: i64) bool {
    return (actual >= lower and actual < upper);
}

test "Dice rolls" {
    var dice = Dice.initWithGeneratedSeed();

    const roll_1 = dice.roll(10);
    const roll_2 = dice.roll(10);
    const roll_3 = dice.roll(10);
    const roll_4 = dice.roll(10);
    const roll_5 = dice.roll(10);

    try testing.expect(rollWithinBounds(roll_1, 0, 10));
    try testing.expect(rollWithinBounds(roll_2, 0, 10));
    try testing.expect(rollWithinBounds(roll_3, 0, 10));
    try testing.expect(rollWithinBounds(roll_4, 0, 10));
    try testing.expect(rollWithinBounds(roll_5, 0, 10));
}