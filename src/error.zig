const std = @import("std");

const Lexer = @import("Lexer.zig");

pub const RichError = struct {
    message: []const u8,
    span: Lexer.Span,
};
