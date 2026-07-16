const std = @import("std");
const types = @import("../../types.zig");
const App = @import("App.zig").App;

pub fn main(process: std.process.Init) !void {
    const allocator = process.arena.allocator();
    const io = process.io;

    var arg_iter = try std.process.Args.Iterator.initAllocator(process.minimal.args, process.gpa);
    defer arg_iter.deinit();

    _ = arg_iter.next(); // skip program name

    var single_prompt: ?[]const u8 = null;
    var model_override: ?[]const u8 = null;
    var show_help = false;
    var show_version = false;
    var list_models = false;

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            show_version = true;
        } else if (std.mem.eql(u8, arg, "--prompt")) {
            if (arg_iter.next()) |val| {
                single_prompt = try allocator.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, arg, "--list-models")) {
            list_models = true;
        } else if (std.mem.eql(u8, arg, "--model")) {
            if (arg_iter.next()) |val| {
                model_override = try allocator.dupe(u8, val);
            }
        }
    }

    if (show_help) {
        var sbuf: [512]u8 = undefined;
        var sw: std.Io.File.Writer = .init(.stderr(), io, &sbuf);
        try sw.interface.print(
            \\z-agent-core v{s}
            \\
            \\  --prompt <text>    单次模式，直接提交一条消息
            \\  --model <spec>     指定模型，格式: provider/model_id
            \\  --list-models       列出所有可用模型
            \\  --help, -h         显示此帮助
            \\  --version, -v      显示版本号
            \\
        , .{types.VERSION});
        try sw.interface.flush();
        return;
    }

    if (show_version) {
        var sbuf: [128]u8 = undefined;
        var sw: std.Io.File.Writer = .init(.stderr(), io, &sbuf);
        try sw.interface.print("z-agent-core v{s}\n", .{types.VERSION});
        try sw.interface.flush();
        return;
    }

    if (list_models) {
        const config_mod = @import("../../config.zig");
        const project_root = config_mod.findZagentRoot(allocator, io) orelse blk: {
            var pr_buf: [4096]u8 = undefined;
            const len = std.Io.Dir.cwd().realPath(io, &pr_buf) catch {
                var sbuf: [256]u8 = undefined;
                var sw: std.Io.File.Writer = .init(.stderr(), io, &sbuf);
                sw.interface.print("z-agent-core: error: cannot resolve working directory\n", .{}) catch {};
                return;
            };
            break :blk try allocator.dupe(u8, pr_buf[0..len]);
        };
        var cfg = config_mod.Config.load(allocator, project_root, io) catch {
            var sbuf: [256]u8 = undefined;
            var sw: std.Io.File.Writer = .init(.stderr(), io, &sbuf);
            sw.interface.print("z-agent-core: error: cannot load config\n", .{}) catch {};
            return;
        };
        defer cfg.deinit();

        var obuf: [256]u8 = undefined;
        var ow: std.Io.File.Writer = .init(.stdout(), io, &obuf);
        for (cfg.providers) |p| {
            for (p.models) |m| {
                try ow.interface.print("{s}/{s}  {s}\n", .{ p.name, m.id, m.name });
            }
        }
        try ow.interface.flush();
        return;
    }

    var app = App.init(allocator, io, single_prompt, model_override) catch return;
    defer app.deinit();
    app.pipe_mode = !(std.Io.File.isTty(.stdout(), io) catch false);
    app.initAgent();
    try app.run();
}
