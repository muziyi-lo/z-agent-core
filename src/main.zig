const std = @import("std");
const cli = @import("frontends/cli/main.zig");

pub fn main(process: std.process.Init) !void {
    return cli.main(process);
}
