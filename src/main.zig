const std = @import("std");
const module = @import("module");

pub fn main() void {
    const result = module.hello();
    std.debug.print("Hello {s}\n", .{result});
}