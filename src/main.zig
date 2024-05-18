const std = @import("std");
const remote_module = @import("remote_module");

pub fn main() void {
    const result = remote_module.hello();
    std.debug.print("Hello {s}\n", .{result});
}
