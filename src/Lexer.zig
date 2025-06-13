//! Lexer for Atra markup language.
//! This takes string as an input and works like an iterator that provides a list of tokens.
//! It is architected to *NOT* allocate anything in order to be as fast as possible.

const std = @import("std");

start: usize = 0,
current: usize = 0,
source: []const u8,

const Self = @This();
const log_scope = std.log.scoped(.lexer);

pub const LexerError = error{
    InvalidToken,
    UnterminatedString,
};

pub const Span = struct {
    start: usize,
    end: usize,
};
pub const Token = struct {
    type: TokenType,
    span: Span,
    lexeme: []const u8,
};
pub const TokenType = enum {
    // All kinds of parentheses.
    LEFT_PAREN,
    RIGHT_PAREN,
    LEFT_CURLY,
    RIGHT_CURLY,
    LEFT_SQUARE,
    RIGHT_SQUARE,

    // Special symbols.
    EQUALS,
    AT,
    STAR,
    PERCENT,
    DOLLAR,
    PIPE,
    COMMA,

    // Values and literals.
    IDENTIFIER,
    STRING_LITERAL,
    INT_LITERAL,

    // Other useful stuff.
    EOF,
};

pub inline fn isAtEnd(self: *Self) bool {
    return self.current >= self.source.len;
}

pub fn next(self: *Self) LexerError!Token {
    const eof_token = Token{
        .type = TokenType.EOF,
        .span = .{ .start = self.source.len, .end = self.source.len },
        .lexeme = &.{},
    };
    // Return EOF when there are no more tokens.
    if (self.isAtEnd()) return eof_token;

    // Skip whitespace characters and comments.
    var ws_char = self.source[self.current];
    while (std.ascii.isWhitespace(ws_char) or ws_char == '#') : (ws_char = self.source[self.current]) {
        // Skip until newline if comment.
        if (ws_char == '#') {
            while (self.source[self.current] != '\n')
                self.current += 1;
        } else self.current += 1;

        if (self.isAtEnd()) return eof_token;
    }
    self.start = self.current;

    // Scan the next token.
    const token_type: TokenType = switch (self.source[self.current]) {
        '(' => .LEFT_PAREN,
        ')' => .RIGHT_PAREN,
        '{' => .LEFT_CURLY,
        '}' => .RIGHT_CURLY,
        '[' => .LEFT_SQUARE,
        ']' => .RIGHT_SQUARE,

        '=' => .EQUALS,
        '@' => .AT,
        '*' => .STAR,
        '%' => .PERCENT,
        '$' => .DOLLAR,
        '|' => .PIPE,
        ',' => .COMMA,

        '"' => try self.string(),
        '0'...'9' => self.integer(),
        'A'...'Z', 'a'...'z', '_' => self.identifier(),

        else => return error.InvalidToken,
    };

    // Generate token and advance the lexer.
    self.current += 1;
    const generated_token = Token{
        .type = token_type,
        .span = .{ .start = self.start, .end = self.current },
        .lexeme = self.source[self.start..self.current],
    };
    self.start = self.current;
    log_scope.debug("Parsed token: {any}@{d}:{d} - \"{s}\"", .{ token_type, generated_token.span.start, generated_token.span.end, generated_token.lexeme });
    return generated_token;
}

fn string(self: *Self) LexerError!TokenType {
    self.current += 1; // Skip opening '"' token.
    while (!self.isAtEnd() and self.source[self.current] != '"') {
        if (self.source[self.current] == '\\')
            self.current += 1; // Skip the next character.
        self.current += 1;
    }
    if (self.isAtEnd())
        return error.UnterminatedString;
    return TokenType.STRING_LITERAL;
}

fn integer(self: *Self) TokenType {
    while (!self.isAtEnd() and std.ascii.isDigit(self.source[self.current]))
        self.current += 1;
    self.current -= 1; // This will be adjusted.
    return TokenType.INT_LITERAL;
}

fn identifier(self: *Self) TokenType {
    var char = self.source[self.current];
    while (!self.isAtEnd() and std.ascii.isAlphanumeric(char) or char == '-' or char == '_') : (char = self.source[self.current])
        self.current += 1;
    self.current -= 1; // This will be adjusted.
    return TokenType.IDENTIFIER;
}

test "Lex basic tokens" {
    const source = "(){}[]=@*%$|,";
    var lexer = Self{ .source = source };

    for ([_]TokenType{ .LEFT_PAREN, .RIGHT_PAREN, .LEFT_CURLY, .RIGHT_CURLY, .LEFT_SQUARE, .RIGHT_SQUARE, .EQUALS, .AT, .STAR, .PERCENT, .DOLLAR, .PIPE, .COMMA }, 0..) |expected_token_type, i| {
        const expected_token = Token{
            .type = expected_token_type,
            .span = .{ .start = i, .end = i + 1 },
            .lexeme = source[i .. i + 1],
        };
        try std.testing.expectEqual(expected_token, try lexer.next());
    }
}

test "Lex identifier, number, and whitespace" {
    const source = "hello_beautiful-world\n\t 1234";
    var lexer = Self{ .source = source };

    try std.testing.expectEqual(Token{
        .type = .IDENTIFIER,
        .span = .{ .start = 0, .end = 21 },
        .lexeme = source[0..21],
    }, try lexer.next());

    try std.testing.expectEqual(Token{
        .type = .INT_LITERAL,
        .span = .{ .start = 24, .end = 28 },
        .lexeme = source[24..28],
    }, try lexer.next());
}

test "Fail at unterminated string literal" {
    const source = "\"hello world!";
    var lexer = Self{ .source = source };

    try std.testing.expectError(error.UnterminatedString, lexer.next());
}

test "Lex correct string literal with escapes" {
    const source = "\"hello\\\"world\\\"!\"";
    var lexer = Self{ .source = source };

    try std.testing.expectEqual(Token{
        .type = .STRING_LITERAL,
        .span = .{ .start = 0, .end = 17 },
        .lexeme = source,
    }, try lexer.next());
}

test "Lex EOF at the end" {
    const source = "";
    var lexer = Self{ .source = source };

    try std.testing.expectEqual(Token{
        .type = .EOF,
        .span = .{ .start = 0, .end = 0 },
        .lexeme = &.{},
    }, try lexer.next());
}
