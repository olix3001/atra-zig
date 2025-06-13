const std = @import("std");

const ast = @import("ast.zig");
const common = @import("common.zig");
const RichError = @import("error.zig").RichError;

// HIR Tree. This is much more primitive than AST tree,
// but can be converted directly into HTML.
pub const Tree = common.Tree(Node);

pub const Node = union(enum) {
    basic_tag: BasicTag,
    fragment: []const usize,
    text: []const u8,
    raw_html: []const u8,
};

pub const NamedAttribute = struct {
    name: []const u8,
    value: []const u8,
};
pub const BasicTag = struct {
    name: []const u8,
    attributes: []const NamedAttribute,
    children: []const usize,
};

pub const ScopeStack = struct {
    arena: std.heap.ArenaAllocator,
    alloc: std.mem.Allocator,
    stack: std.ArrayList(Scope),

    const Scope = struct {
        variables: std.StringHashMap(ast.Value),
        macros: std.StringHashMap(ast.MacroDecl),
    };
    const Self = @This();
    pub fn init(alloc: std.mem.Allocator) Self {
        return Self{ .arena = .init(alloc), .alloc = alloc, .stack = .init(alloc) };
    }
    pub fn deinit(self: *Self) void {
        self.stack.deinit();
        self.arena.deinit();
    }

    pub fn push(self: *Self) !void {
        const arena = self.arena.allocator();
        try self.stack.append(.{ .variables = .init(arena), .macros = .init(arena) });
    }

    pub fn pop(self: *Self) void {
        var top_scope = self.stack.pop();
        top_scope.?.variables.deinit();
    }

    pub inline fn top(self: *Self) *Scope {
        return &self.stack.items[self.stack.items.len - 1];
    }

    pub fn newVariable(self: *Self, name: []const u8, value: ast.Value) !void {
        try self.top().variables.put(name, value);
    }

    pub fn findVariable(self: *Self, name: []const u8) ?ast.Value {
        for (0..self.stack.items.len) |n| {
            const i = self.stack.items.len - n - 1;
            const scope = &self.stack.items[i];
            if (scope.variables.get(name)) |value|
                return value;
        }
        return null;
    }

    fn newMacro(self: *Self, name: []const u8, decl: ast.MacroDecl) !void {
        try self.top().macros.put(name, decl);
    }

    fn findMacro(self: *Self, name: []const u8) ?ast.MacroDecl {
        for (0..self.stack.items.len) |n| {
            const i = self.stack.items.len - n - 1;
            const scope = &self.stack.items[i];
            if (scope.macros.get(name)) |value|
                return value;
        }
        return null;
    }
};

// Hir gen transcribes AST into HIR.
// It is responsible for all variable and call expansion.
pub const HirGen = struct {
    alloc: std.mem.Allocator,
    hir_tree: Tree,
    ast_tree: *const ast.Tree,
    scope_stack: ScopeStack,

    intrinsics: *const std.StringHashMap(common.Intrinsic),
    includes_cache: std.StringHashMap(CachedTree),

    error_arena: std.heap.ArenaAllocator,
    errors: std.ArrayList(RichError),

    pub const CachedTree = struct { tree: ast.Tree, root: usize };
    const Self = @This();
    pub const HirGenError = error{
        MissingArgument,
        UnknownVariable,
        UnknownFunctionOrMacro,
        BadType,
        Unimplemented,
    } || anyerror;
    const log_scope = std.log.scoped(.hirgen);

    pub fn init(alloc: std.mem.Allocator, ast_tree: *const ast.Tree, intrinsics: *const std.StringHashMap(common.Intrinsic)) Self {
        return Self{
            .alloc = alloc,
            .hir_tree = .init(alloc),
            .ast_tree = ast_tree,
            .scope_stack = .init(alloc),

            .intrinsics = intrinsics,
            .includes_cache = .init(alloc),

            .error_arena = .init(alloc),
            .errors = .init(alloc),
        };
    }

    pub fn deinit(self: *Self, leave_tree: bool) void {
        if (!leave_tree)
            self.hir_tree.deinit();
        var cache_iter = self.includes_cache.valueIterator();
        while (cache_iter.next()) |cached_module|
            cached_module.tree.deinit();
        self.includes_cache.deinit();
        self.scope_stack.deinit();
        self.errors.deinit();
        self.error_arena.deinit();
    }

    pub fn logError(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        log_scope.debug("Logging error: " ++ fmt, args);
        try self.errors.append(.{
            .message = try std.fmt.allocPrint(self.error_arena.allocator(), fmt, args),
            .span = .{ .start = 0, .end = 0 }, // TODO: Add proper span.
        });
    }

    pub fn lowerSlice(self: *Self, slice: []const usize) HirGenError![]const usize {
        try self.scope_stack.push();
        const child_nodes = try self.hir_tree.allocator().alloc(usize, slice.len);
        for (slice, 0..) |ast_item, i| {
            child_nodes[i] = try self.lowerNode(ast_item);
        }
        self.scope_stack.pop();
        return child_nodes;
    }

    fn lowerAttributes(self: *Self, attributes: []const ast.NamedArgument) HirGenError![]const NamedAttribute {
        const new_attributes = try self.hir_tree.allocator().alloc(NamedAttribute, attributes.len);
        for (attributes, 0..) |attribute, i|
            new_attributes[i] = .{
                .name = attribute.name,
                .value = switch (attribute.value) {
                    .string => |text| text,
                    else => unreachable, // This should never happen.
                },
            };

        return new_attributes;
    }

    fn lowerValueToNode(self: *Self, value: ast.Value) HirGenError!usize {
        switch (value) {
            .string => |text| return try self.hir_tree.addNode(.{ .text = text }),
            .integer => |number| return try self.hir_tree.addNode(
                .{ .text = try std.fmt.allocPrint(self.hir_tree.allocator(), "{d}", .{number}) },
            ),
            .variable => |var_name| {
                const variable_value = self.scope_stack.findVariable(var_name);
                if (variable_value) |some_value|
                    return try self.lowerValueToNode(some_value)
                else {
                    try self.logError("Unknown variable '{s}'.", .{var_name});
                    return error.UnknownVariable;
                }
            },
            .node => |value_node_id| {
                const value_node_slice = try self.hir_tree.allocator().alloc(usize, 1);
                value_node_slice[0] = value_node_id;
                return try self.hir_tree.addNode(.{ .fragment = value_node_slice });
            },
        }
    }

    // Translate AST node into HIR node.
    pub fn lowerNode(self: *Self, node_id: usize) HirGenError!usize {
        const node = &self.ast_tree.nodes.items[node_id];
        log_scope.debug("Lowering node {any}", .{node});
        switch (node.*) {
            .basic_tag => |tag| {
                return try self.hir_tree.addNode(.{ .basic_tag = .{
                    .name = tag.name,
                    .attributes = try self.lowerAttributes(tag.attributes),
                    .children = try self.lowerSlice(tag.children),
                } });
            },
            .func_call => |call| return try self.expandFunctionCall(call, node_id),
            .fragment => |items| {
                const child_nodes = try self.lowerSlice(items);
                return try self.hir_tree.addNode(.{ .fragment = child_nodes });
            },
            .value => |value| return try self.lowerValueToNode(value),
            .macro_decl => |decl| {
                try self.scope_stack.newMacro(decl.name, decl);
                return self.hir_tree.addNode(.{ .fragment = &.{} }); // This does not introduce a new HIR node.
            },
        }
    }

    fn expandFunctionCall(self: *Self, call: ast.FuncCall, call_node_id: usize) HirGenError!usize {
        // Remap arguments into a hashmap for easier access.
        var call_args_hm = std.StringHashMap(ast.Value).init(self.alloc);
        defer call_args_hm.deinit();
        for (call.arguments) |call_arg| {
            var value = call_arg.value;
            // Resolve potential variable.
            switch (call_arg.value) {
                .variable => |var_name| value = self.scope_stack.findVariable(var_name) orelse {
                    try self.logError("Unknown variable '{s}'.", .{var_name});
                    return error.UnknownVariable;
                },
                else => {},
            }
            try call_args_hm.put(call_arg.name, value);
        }

        if (self.scope_stack.findMacro(call.name)) |macro_decl| {
            // Check if all required arguments are provided.
            for (macro_decl.arguments) |required_arg| {
                if (!call_args_hm.contains(required_arg)) {
                    try self.logError(
                        "Missing argument '{s}' on '{s}' macro call.",
                        .{ required_arg, call.name },
                    );
                    return error.MissingArgument;
                }
            }

            // Expand macro with provided variables.
            const lowered_children = try self.lowerSlice(call.children);
            const children_fragment = try self.hir_tree.addNode(.{ .fragment = lowered_children });

            try self.scope_stack.push();
            for (macro_decl.arguments) |decl_arg|
                try self.scope_stack.newVariable(decl_arg, call_args_hm.get(decl_arg).?);
            if (macro_decl.children_arg) |children_arg_name|
                try self.scope_stack.newVariable(children_arg_name, .{ .node = children_fragment });

            // Expand subtree.
            const expanded = try self.lowerSlice(macro_decl.children);
            const expanded_fragment = try self.hir_tree.addNode(
                Node{ .fragment = expanded },
            );
            self.scope_stack.pop();
            return expanded_fragment;
        } else if (self.intrinsics.get(call.name)) |intrinsic| {
            // Check if all required arguments are provided.
            for (intrinsic.required_args) |required_arg| {
                if (!call_args_hm.contains(required_arg)) {
                    try self.logError(
                        "Missing argument '{s}' on '{s}' function call.",
                        .{ required_arg, call.name },
                    );
                    return error.MissingArgument;
                }
            }

            // Call the function implementation.
            const generated_node_id = try intrinsic.impl(common.IntrinsicArgs{
                .tree = self.ast_tree,
                .args = call_args_hm,
                .captures = call.captures,
                .children = call.children,
                .source_node = call_node_id,
                .hirgen = self,
            });

            return generated_node_id;
        }

        try self.logError("Unknown function/macro name '{s}'", .{call.name});
        return error.UnknownFunctionOrMacro;
    }
};
