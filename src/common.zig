const std = @import("std");

const ast = @import("ast.zig");
const hir = @import("hir.zig");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");

// Common template for a tree structure with nodes.
// This is used for both AST and HIR.
pub fn Tree(comptime NodeType: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,

        nodes: std.ArrayList(NodeType),

        const Self = @This();
        pub fn init(alloc: std.mem.Allocator) Self {
            return Self{
                .arena = .init(alloc),
                .nodes = .init(alloc),
            };
        }

        pub fn deinit(self: *Self) void {
            self.nodes.deinit();
            self.arena.deinit();
        }

        pub inline fn allocator(self: *Self) std.mem.Allocator {
            return self.arena.allocator();
        }

        pub fn addNode(self: *Self, node: NodeType) std.mem.Allocator.Error!usize {
            const old_len = self.nodes.items.len;
            try self.nodes.append(node);
            return old_len;
        }
    };
}

// Pipeline for lexing, parsing and transforming .atra files.
pub const PipelineOptions = struct {
    intrinsics: ?std.StringHashMap(Intrinsic) = null,
};
pub const Pipeline = struct {
    alloc: std.mem.Allocator,
    intrinsics: std.StringHashMap(Intrinsic),

    const Self = @This();
    const log_scope = std.log.scoped(.pipeline);
    pub fn init(alloc: std.mem.Allocator, options: PipelineOptions) !Self {
        return Self{
            .alloc = alloc,
            .intrinsics = options.intrinsics orelse try makeIntrinsics(alloc, DefaultIntrinsics),
        };
    }

    pub fn deinit(self: *Self) void {
        self.intrinsics.deinit();
    }

    pub fn processTextIntoAST(self: *Self, source: []const u8) !struct { root: usize, tree: ast.Tree } {
        var lexer = Lexer{ .source = source };
        var parser = Parser.init(self.alloc, &lexer);
        defer parser.deinit(true);

        const main_module = parser.parseAll() catch |err| {
            std.debug.print("Caught parser errors: {}\n", .{std.json.fmt(parser.errors.items, .{ .whitespace = .indent_2 })});
            return err;
        };
        log_scope.debug("Module AST tree:\n{}\n", .{std.json.fmt(parser.tree.nodes.items, .{})});

        return .{ .root = main_module, .tree = parser.tree };
    }

    pub fn processTextIntoHIR(self: *Self, source: []const u8) !struct { root: usize, tree: hir.Tree } {
        var processed_ast = try self.processTextIntoAST(source);
        defer processed_ast.tree.deinit();

        var hirgen = hir.HirGen.init(self.alloc, &processed_ast.tree, &self.intrinsics);
        defer hirgen.deinit(true);
        const main_module = hirgen.lowerNode(processed_ast.root) catch |err| {
            std.debug.print("Caught hirgen errors: {}\n", .{std.json.fmt(hirgen.errors.items, .{ .whitespace = .indent_2 })});
            return err;
        };

        log_scope.debug("Module HIR tree:\n{}\n", .{std.json.fmt(hirgen.hir_tree.nodes.items, .{})});
        return .{ .root = main_module, .tree = hirgen.hir_tree };
    }
};

// Intrinsic functions. Just a fancy word for 'builtin function'.
pub const IntrinsicArgs = struct {
    tree: *const ast.Tree,
    args: std.StringHashMap(ast.Value),
    children: []const usize,
    captures: []const []const u8,
    source_node: usize,
    hirgen: *hir.HirGen,

    pub fn get_arg(
        self: *const @This(),
        name: []const u8,
        comptime tag: std.meta.Tag(ast.Value),
    ) !std.meta.TagPayload(ast.Value, tag) {
        const arg_value = self.args.get(name).?;
        if (std.meta.activeTag(arg_value) == tag)
            return @field(arg_value, @tagName(tag))
        else {
            try self.hirgen.logError("'repeat' function expected integer but got {any}.", .{arg_value});
            return error.BadType;
        }
    }
};
pub const Intrinsic = struct {
    impl: *const fn (IntrinsicArgs) hir.HirGen.HirGenError!usize,
    required_args: []const []const u8,
};

// Convert struct into intrinsics map. This builds a vtable for all possible calls.
pub fn makeIntrinsics(alloc: std.mem.Allocator, comptime Source: type) !std.StringHashMap(Intrinsic) {
    var map = std.StringHashMap(Intrinsic).init(alloc);
    errdefer map.deinit();
    switch (@typeInfo(Source)) {
        .@"struct" => |source| {
            inline for (source.decls) |decl| {
                const fn_field = @field(Source, decl.name);
                const required_args = try alloc.dupe([]const u8, &.{});
                try map.put(decl.name, .{ .impl = &fn_field, .required_args = required_args });
            }
        },
        else => @compileError("makeIntrinsics takes only struct arguments."),
    }
    return map;
}

pub const DefaultIntrinsics = struct {
    // Includes another atra file. This includes the AST of the provided file
    // without introducing new scope, which means all top-level macros from that file
    // will be available to the caller.
    pub fn include(args: IntrinsicArgs) hir.HirGen.HirGenError!usize {
        const path = try args.get_arg("src", .string);
        const full_path = try std.fs.cwd().realpathAlloc(args.hirgen.alloc, path);
        defer args.hirgen.alloc.free(full_path);

        var maybe_included: ?hir.HirGen.CachedTree = null;
        if (args.hirgen.includes_cache.get(full_path)) |cached_tree| {
            maybe_included = cached_tree;
        } else {
            var pipeline = try Pipeline.init(args.hirgen.alloc, .{});
            defer pipeline.deinit();

            var file = try std.fs.cwd().openFile(path, .{});
            defer file.close();

            const contents = try file.readToEndAlloc(args.hirgen.hir_tree.allocator(), std.math.maxInt(usize));
            const included_ast = try pipeline.processTextIntoAST(contents);
            try args.hirgen.includes_cache.put(full_path, .{ .tree = included_ast.tree, .root = included_ast.root });
            maybe_included = args.hirgen.includes_cache.get(full_path);
        }
        const included = maybe_included.?;

        // Expand this new AST using some trickery, without introducing a new scope.
        var new_fragment = std.ArrayList(usize).init(args.hirgen.hir_tree.allocator());
        const prev_ast_tree = args.hirgen.ast_tree;
        args.hirgen.ast_tree = &included.tree;
        const included_root_fragment = included.tree.nodes.items[included.root].fragment;
        for (included_root_fragment) |ast_item| {
            try new_fragment.append(try args.hirgen.lowerNode(ast_item));
        }
        args.hirgen.ast_tree = prev_ast_tree; // Go back to original state.

        return try args.hirgen.hir_tree.addNode(hir.Node{ .fragment = try new_fragment.toOwnedSlice() });
    }

    // Repeats the given body 'n' times, providing one capture being repetition index.
    pub fn repeat(args: IntrinsicArgs) hir.HirGen.HirGenError!usize {
        const n = try args.get_arg("n", .integer);
        const children_fragment = try args.hirgen.hir_tree.allocator().alloc(usize, n);
        const scope_stack = &args.hirgen.scope_stack;
        try scope_stack.push();
        for (0..n) |repetition_index| {
            // Re-set variables on the scope.
            if (args.captures.len > 0)
                try scope_stack.newVariable(args.captures[0], .{ .integer = repetition_index + 1 });

            // Expand the subtree again.
            const expanded = try args.hirgen.lowerSlice(args.children);
            children_fragment[repetition_index] = try args.hirgen.hir_tree.addNode(
                hir.Node{ .fragment = expanded },
            );
        }
        scope_stack.pop();
        return try args.hirgen.hir_tree.addNode(hir.Node{ .fragment = children_fragment });
    }

    // Embeds file content in a place of that call. Provided text will be escaped!
    // If embedding raw html is necessary use 'embedRaw' intrinsic.
    pub fn embedText(args: IntrinsicArgs) hir.HirGen.HirGenError!usize {
        const path = try args.get_arg("src", .string);

        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(args.hirgen.hir_tree.allocator(), std.math.maxInt(usize));
        return try args.hirgen.hir_tree.addNode(hir.Node{ .text = contents });
    }

    // Embeds file content in a place of that call. This embeds raw html, so
    // only use It to include non-atra html files.
    pub fn embedRaw(args: IntrinsicArgs) hir.HirGen.HirGenError!usize {
        const path = try args.get_arg("src", .string);

        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(args.hirgen.hir_tree.allocator(), std.math.maxInt(usize));
        return try args.hirgen.hir_tree.addNode(hir.Node{ .raw_html = contents });
    }
};
