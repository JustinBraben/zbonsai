//! dice.zig
const std = @import("std");
const Random = std.Random;
const testing = std.testing;

/// Object used to generate Random numbers for the main App
const Dice = @This();

rand: Random.Xoshiro256,

/// Initialize Dice
/// If null is passed, create seed based on timestamp
pub fn init(seed: ?u64) Dice {
    if (seed) |s| {
        return .{
            .rand = Random.DefaultPrng.init(s),
        };
    } else {
        const timestamp = @as(u64, @intCast(std.time.timestamp()));
        return .{
            .rand = Random.DefaultPrng.init(timestamp),
        };
    }
}

/// Roll the dice for a usize
pub fn rollUsize(self: *Dice, less_than: usize) usize {
    return self.rand.random().intRangeLessThan(usize, 0, less_than);
}

/// Roll the dice for an i64
pub fn rollI64(self: *Dice, less_than: i64) i64 {
    return self.rand.random().intRangeLessThan(i64, 0, less_than);
}

/// Roll the fice for an f32
pub fn rollF32(self: *Dice) f32 {
    return self.rand.random().float(f32);
}

/// Function for testing
fn rollI64WithinBounds(actual: i64, lower: i64, upper: i64) bool {
    return (actual >= lower and actual < upper);
}

test "Dice rolls" {
    var dice = Dice.init(null);

    const roll_1 = dice.rollI64(10);
    const roll_2 = dice.rollI64(10);
    const roll_3 = dice.rollI64(10);
    const roll_4 = dice.rollI64(10);
    const roll_5 = dice.rollI64(10);

    try testing.expect(rollI64WithinBounds(roll_1, 0, 10));
    try testing.expect(rollI64WithinBounds(roll_2, 0, 10));
    try testing.expect(rollI64WithinBounds(roll_3, 0, 10));
    try testing.expect(rollI64WithinBounds(roll_4, 0, 10));
    try testing.expect(rollI64WithinBounds(roll_5, 0, 10));
}

test "Dice initialization with seed produces deterministic results" {
    var dice1 = Dice.init(12345);
    var dice2 = Dice.init(12345);
    
    try testing.expectEqual(dice1.rollUsize(100), dice2.rollUsize(100));
    try testing.expectEqual(dice1.rollI64(100), dice2.rollI64(100));
}

test "Dice roll ranges are within bounds" {
    var dice = Dice.init(42);
    
    for (0..1000) |_| {
        const roll = dice.rollUsize(10);
        try testing.expect(roll < 10);
    }
}
