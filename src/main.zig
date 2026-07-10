const std = @import("std");
const App = @import("App.zig").App;

pub fn main(process: std.process.Init) !void {
    const allocator = process.arena.allocator();
    const io = process.io;

    var arg_iter = try std.process.Args.Iterator.initAllocator(process.minimal.args, process.gpa);
    defer arg_iter.deinit();

    _ = arg_iter.next(); // skip program name

    var single_prompt: ?[]const u8 = null;
    var model_override: ?[]const u8 = null;

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--prompt")) {
            if (arg_iter.next()) |val| {
                single_prompt = try allocator.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, arg, "--model")) {
            if (arg_iter.next()) |val| {
                model_override = try allocator.dupe(u8, val);
            }
        }
    }

    var app = App.init(allocator, io, single_prompt, model_override) catch |err| {
        if (err == error.NoProjectRoot or err == error.ProviderNotFound or err == error.ApiKeyNotSet) return;
        return err;
    };
    defer app.deinit();
    app.initAgent();
    try app.run();
}
