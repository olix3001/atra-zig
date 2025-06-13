const std = @import("std");

const common = @import("common.zig");
const Emitter = @import("Emitter.zig");

pub fn main() !void {
    const example_source = @embedFile("example.atra");

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var pipeline = try common.Pipeline.init(alloc, .{});
    defer pipeline.deinit();
    var hir_result = try pipeline.processTextIntoHIR(example_source);
    defer hir_result.tree.deinit();

    const stdout = std.io.getStdOut();
    const emitter = Emitter{ .tree = &hir_result.tree, .writer = stdout.writer().any() };
    try emitter.emitFromRoot(hir_result.root);
}

test {
    // Ensure tests from all modules (even unused) run.
    std.testing.refAllDecls(@This());
}
