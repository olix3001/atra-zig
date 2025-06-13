const std = @import("std");

// AST Tree. This is used for function calls and
// macro expansions. It will be later converted to HIR (Html Intermediate Representation).
pub const Tree = @import("common.zig").Tree(Node);

pub const Node = union(enum) {
    basic_tag: BasicTag,
    func_call: FuncCall,
    fragment: []const usize,
    value: Value,
    macro_decl: MacroDecl,
};

// Argument is representation of name=value.
// It can be used in basic tags or macro/function calls.
pub const NamedArgument = struct {
    name: []const u8,
    value: Value,
};
// All possible value types.
pub const Value = union(enum) {
    string: []const u8,
    integer: usize,
    variable: []const u8,
    node: usize,
};

// Basic html tag, It will be directly transfered to HIR.
pub const BasicTag = struct {
    name: []const u8,
    attributes: []const NamedArgument,
    children: []const usize,
};

// Function call. This can be either intrinsic or macro.
pub const FuncCall = struct {
    name: []const u8,
    arguments: []const NamedArgument,
    captures: []const []const u8,
    children: []const usize,
};

// Macro declaration. This allows user to declare
// their own simple functions that expand into some
// predefined AST.
pub const MacroDecl = struct {
    name: []const u8,
    arguments: []const []const u8,
    children_arg: ?[]const u8,
    children: []const usize,
};
