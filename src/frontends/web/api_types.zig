const std = @import("std");
const types = @import("../../types.zig");

pub const SessionListItem = struct {
    id: []const u8,
    name: []const u8,
    model: []const u8,
    message_count: u32,
};

pub const CreateSessionRequest = struct {
    name: ?[]const u8 = null,
    default_model: []const u8,
};

pub const PatchSessionRequest = struct {
    name: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

pub const PromptRequest = struct {
    prompt: []const u8,
};
