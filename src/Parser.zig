const std = @import("std");

const ast = @import("ast.zig");
const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;
const RichError = @import("error.zig").RichError;

alloc: std.mem.Allocator,
tree: ast.Tree,
lexer: *Lexer,

cached_token: ?Token = null,

error_arena: std.heap.ArenaAllocator,
errors: std.ArrayList(RichError),

const Self = @This();
pub const ParserError = error{
    UnexpectedToken,
} || Lexer.LexerError || std.mem.Allocator.Error;
const log_scope = std.log.scoped(.parser);

pub fn init(alloc: std.mem.Allocator, lexer: *Lexer) Self {
    return Self{
        .alloc = alloc,
        .tree = .init(alloc),
        .lexer = lexer,

        .error_arena = .init(alloc),
        .errors = .init(alloc),
    };
}

pub fn deinit(self: *Self, leave_tree: bool) void {
    if (!leave_tree)
        self.tree.deinit();
    self.errors.deinit();
    self.error_arena.deinit();
}

// Helper/Utility functions.
fn peek(self: *Self) !Token {
    if (self.cached_token) |cached|
        return cached;
    self.cached_token = try self.lexer.next();
    return self.cached_token.?;
}

fn advance(self: *Self) !Token {
    const previous_token = self.peek();
    self.cached_token = null;
    return previous_token;
}

fn expect(self: *Self, expected_type: Lexer.TokenType) ParserError!Token {
    if ((try self.peek()).type == expected_type)
        return try self.advance();
    const found_token = try self.peek();
    try self.errors.append(.{
        .message = try std.fmt.allocPrint(
            self.error_arena.allocator(),
            "Expected token {any}, but got {any}.",
            .{ expected_type, found_token.type },
        ),
        .span = found_token.span,
    });
    return error.UnexpectedToken;
}

fn maybe(self: *Self, maybe_type: Lexer.TokenType) !?Token {
    if ((try self.peek()).type == maybe_type)
        return try self.advance();
    return null;
}

fn parseValue(self: *Self) ParserError!ast.Value {
    switch ((try self.peek()).type) {
        .STRING_LITERAL => {
            const string_value = (try self.advance()).lexeme;
            return ast.Value{
                .string = string_value[1 .. string_value.len - 1],
            };
        },
        .INT_LITERAL => {
            const int_value = (try self.advance()).lexeme;
            return ast.Value{
                .integer = std.fmt.parseInt(usize, int_value, 10) catch unreachable,
            };
        },
        .DOLLAR => {
            _ = try self.advance(); // Skip '$' sign.
            return ast.Value{
                .variable = (try self.advance()).lexeme,
            };
        },
        else => {
            const found_token = try self.peek();
            try self.errors.append(.{
                .message = try std.fmt.allocPrint(
                    self.error_arena.allocator(),
                    "Expected value literal, but got {any}.",
                    .{found_token.type},
                ),
                .span = found_token.span,
            });
            return error.UnexpectedToken;
        },
    }
}

fn parseNamedArguments(self: *Self) ParserError![]const ast.NamedArgument {
    if (try self.maybe(.LEFT_PAREN) == null)
        return &.{}; // No arguments provided.
    var argument_list = std.ArrayList(ast.NamedArgument).init(self.tree.allocator());
    errdefer argument_list.deinit();

    var current_token = try self.peek();
    while (current_token.type == .IDENTIFIER) : (current_token = try self.peek()) {
        _ = try self.advance(); // Consume ident token.
        _ = try self.expect(.EQUALS);
        const value = try self.parseValue();
        try argument_list.append(.{
            .name = current_token.lexeme,
            .value = value,
        });

        if (try self.maybe(.COMMA) == null) break;
    }

    log_scope.debug("Parsed named argument list: {}", .{std.json.fmt(argument_list.items, .{})});
    _ = try self.expect(.RIGHT_PAREN);
    return try argument_list.toOwnedSlice();
}

fn parseBodyBlock(self: *Self) ParserError![]const usize {
    if (try self.maybe(.LEFT_CURLY) == null)
        return &.{}; // No body provided.
    var children_list = std.ArrayList(usize).init(self.tree.allocator());
    errdefer children_list.deinit();

    while ((try self.peek()).type != .RIGHT_CURLY)
        try children_list.append(try self.parseNode());

    _ = try self.expect(.RIGHT_CURLY);
    return try children_list.toOwnedSlice();
}

fn parseDelimitedIdentifierList(
    self: *Self,
    delim_start: Lexer.TokenType,
    delim_end: Lexer.TokenType,
) ParserError![]const []const u8 {
    var idents: []const []const u8 = &.{};
    if (try self.maybe(delim_start) != null) {
        var idents_list = std.ArrayList([]const u8).init(self.tree.allocator());
        errdefer idents_list.deinit();

        var current_token = try self.peek();
        while (current_token.type == .IDENTIFIER) : (current_token = try self.peek()) {
            _ = try self.advance(); // Consume ident token.
            try idents_list.append(current_token.lexeme);

            if (try self.maybe(.COMMA) == null) break;
        }

        _ = try self.expect(delim_end);
        idents = try idents_list.toOwnedSlice();
    }
    return idents;
}

fn parseDelimitedIdentifierListWithStar(
    self: *Self,
    delim_start: Lexer.TokenType,
    delim_end: Lexer.TokenType,
) ParserError!struct { []const []const u8, ?[]const u8 } {
    var idents: []const []const u8 = &.{};
    var star_ident: ?[]const u8 = null;
    if (try self.maybe(delim_start) != null) {
        var idents_list = std.ArrayList([]const u8).init(self.tree.allocator());
        errdefer idents_list.deinit();

        var current_token = try self.peek();
        while (current_token.type == .IDENTIFIER) : (current_token = try self.peek()) {
            _ = try self.advance(); // Consume ident token.
            try idents_list.append(current_token.lexeme);

            if (try self.maybe(.COMMA) == null) break;
            if (try self.maybe(.STAR) != null) {
                star_ident = (try self.expect(.IDENTIFIER)).lexeme;
                break;
            }
        }

        _ = try self.expect(delim_end);
        idents = try idents_list.toOwnedSlice();
    }
    return .{ idents, star_ident };
}

// Real parsing stuff.

// Parse everything in the current lexer.
// This method returns id of the topmost fragment.
pub fn parseAll(self: *Self) ParserError!usize {
    var module_nodes = std.ArrayList(usize).init(self.tree.allocator());
    while ((try self.peek()).type != .EOF)
        try module_nodes.append(try self.parseNode());
    return try self.tree.addNode(ast.Node{
        .fragment = try module_nodes.toOwnedSlice(),
    });
}

// Parse the next node. It can be anything from ast.Node.
// This returns id of the parsed node.
fn parseNode(self: *Self) ParserError!usize {
    return switch ((try self.peek()).type) {
        .IDENTIFIER => try self.parseBasicTag(),
        .PERCENT => try self.parseFunctionCall(),
        .AT => try self.parseMacroDeclaration(),

        .STRING_LITERAL, .DOLLAR => try self.tree.addNode(.{ .value = try self.parseValue() }),

        else => { // Throw UnexpectedToken error.
            const found_token = try self.peek();
            try self.errors.append(.{
                .message = try std.fmt.allocPrint(
                    self.error_arena.allocator(),
                    "Expected item, but got {any}.",
                    .{found_token.type},
                ),
                .span = found_token.span,
            });
            return error.UnexpectedToken;
        },
    };
}

fn parseBasicTag(self: *Self) ParserError!usize {
    const name_token = try self.expect(.IDENTIFIER);
    const arguments = try self.parseNamedArguments();
    const body = try self.parseBodyBlock();

    return try self.tree.addNode(.{ .basic_tag = .{
        .name = name_token.lexeme,
        .attributes = arguments,
        .children = body,
    } });
}

fn parseFunctionCall(self: *Self) ParserError!usize {
    _ = try self.expect(.PERCENT);
    const name_token = try self.expect(.IDENTIFIER);
    const arguments = try self.parseNamedArguments();
    const captures = try self.parseDelimitedIdentifierList(.PIPE, .PIPE);
    const body = try self.parseBodyBlock();

    return try self.tree.addNode(.{ .func_call = .{
        .name = name_token.lexeme,
        .arguments = arguments,
        .captures = captures,
        .children = body,
    } });
}

fn parseMacroDeclaration(self: *Self) ParserError!usize {
    _ = try self.expect(.AT);
    const name_token = try self.expect(.IDENTIFIER);
    const arguments = try self.parseDelimitedIdentifierListWithStar(.LEFT_PAREN, .RIGHT_PAREN);
    const body = try self.parseBodyBlock();

    return try self.tree.addNode(.{ .macro_decl = .{
        .name = name_token.lexeme,
        .arguments = arguments[0],
        .children_arg = arguments[1],
        .children = body,
    } });
}
