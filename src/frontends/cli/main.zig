const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../types.zig");
const init_mod = @import("../init.zig");
const App = @import("App.zig").App;

pub fn main(process: std.process.Init) !void {
    if (builtin.os.tag == .windows) {
        const win32 = struct {
            extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) callconv(.winapi) i32;
        };
        _ = win32.SetConsoleOutputCP(65001);
    }

    const allocator = process.arena.allocator();
    const io = process.io;

    var arg_iter = try std.process.Args.Iterator.initAllocator(process.minimal.args, process.gpa);
    defer arg_iter.deinit();

    _ = arg_iter.next(); // skip program name

    var single_prompt: ?[]const u8 = null;
    var model_override: ?[]const u8 = null;
    var thinking_level: ?types.ThinkingLevel = null;
    var show_help = false;
    var show_version = false;
    var list_models = false;
    var launch_web = false;

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            show_version = true;
        } else if (std.mem.eql(u8, arg, "--web")) {
            launch_web = true;
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
        } else if (std.mem.eql(u8, arg, "--thinking")) {
            if (arg_iter.next()) |val| {
                thinking_level = types.ThinkingLevel.fromString(val);
            }
        }
    }

    if (launch_web) {
        const web = @import("../web/server.zig");
        return web.main(process);
    }

    if (show_help) {
        var sbuf: [512]u8 = undefined;
        var sw: std.Io.File.Writer = .init(.stderr(), io, &sbuf);
        try sw.interface.print(
            \\z-agent-core v{s}
            \\
            \\  --prompt <text>    单次模式，直接提交一条消息
            \\  --model <spec>     指定模型，格式: provider/model_id
            \\  --thinking <level> 设置思考强度: none|minimal|low|medium|high|xhigh|max
            \\  --list-models       列出所有可用模型
            \\  --web              启动 Web 前端 (默认 http://127.0.0.1:8090)
            \\  --port <port>      指定 Web 端口 (配合 --web)
            \\  --address <ip>     指定 Web 监听地址 (配合 --web)
            \\  --root <path>      指定项目根目录
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
            // N23: config errors must be visible to scripts/CI — nonzero exit.
            std.process.exit(1);
        };
        defer cfg.deinit();

        var obuf: [256]u8 = undefined;
        var ow: std.Io.File.Writer = .init(.stdout(), io, &obuf);
        for (cfg.providers) |p| {
            for (p.models) |m| {
                // input modality column: lets users/AI confirm a vision model
                // actually loaded with image input (config mistakes like an
                // input line swallowed by a [models.compat] header show up
                // here as text-only).
                var list = std.ArrayListAligned(u8, null).empty;
                for (m.input) |mod| {
                    if (list.items.len > 0) try list.append(allocator, ',');
                    try list.appendSlice(allocator, @tagName(mod));
                }
                defer list.deinit(allocator);
                try ow.interface.print("{s}/{s}  {s}  input=[{s}]\n", .{ p.name, m.id, m.name, list.items });
            }
        }
        try ow.interface.flush();
        return;
    }

    var app = App.init(allocator, io, single_prompt, model_override, thinking_level) catch |err| {
        init_mod.reportInitError(io, err, null, model_override);
        // N23: init/config errors must be visible to scripts/CI — nonzero exit.
        std.process.exit(1);
    };
    defer app.deinit();
    app.pipe_mode = !(std.Io.File.isTty(.stdout(), io) catch false);
    app.initAgent();
    try app.run();
}
