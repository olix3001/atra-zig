const std = @import("std");

const common = @import("common.zig");
const Emitter = @import("Emitter.zig");

alloc: std.mem.Allocator,

const Self = @This();

pub fn init(alloc: std.mem.Allocator) Self {
    return Self{ .alloc = alloc };
}
pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn compileFromRoot(self: *Self, absolute_path: []const u8, target: std.io.AnyWriter) !void {
    const instant_start = try std.time.Instant.now();
    const source_file = try std.fs.openFileAbsolute(absolute_path, .{ .mode = .read_only });
    const source_data = try source_file.readToEndAlloc(self.alloc, std.math.maxInt(usize));
    defer self.alloc.free(source_data);
    source_file.close();

    const root_dir_path = std.fs.path.dirname(absolute_path);
    var root_dir = try std.fs.openDirAbsolute(root_dir_path.?, .{});
    defer root_dir.close();

    var pipeline = try common.Pipeline.init(self.alloc, .{
        .root_dir = &root_dir,
    });
    defer pipeline.deinit();
    var hir_result = try pipeline.processTextIntoHIR(source_data);
    defer hir_result.tree.deinit();

    var buffered_writer: std.io.BufferedWriter(1024 * 8, @TypeOf(target)) = .{ .unbuffered_writer = target };
    const emitter = Emitter{ .tree = &hir_result.tree, .writer = buffered_writer.writer().any() };
    try emitter.emitFromRoot(hir_result.root);
    try buffered_writer.flush();

    const instant_end = try std.time.Instant.now();
    const elapsed: f64 = @floatFromInt(instant_end.since(instant_start));
    std.log.info("Compiled in {d:.3}ms.", .{
        elapsed / std.time.ns_per_ms,
    });
}
