const std = @import("std");

const clap = @import("clap");

const common = @import("common.zig");
const Compiler = @import("Compiler.zig");

// pub fn main() !void {
//     const example_source = @embedFile("example.atra");

//     var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
//     defer std.debug.assert(gpa.deinit() == .ok);
//     const alloc = gpa.allocator();

//     var pipeline = try common.Pipeline.init(alloc, .{});
//     defer pipeline.deinit();
//     var hir_result = try pipeline.processTextIntoHIR(example_source);
//     defer hir_result.tree.deinit();

//     const stdout = std.io.getStdOut();
//     const emitter = Emitter{ .tree = &hir_result.tree, .writer = stdout.writer().any() };
//     try emitter.emitFromRoot(hir_result.root);
// }

pub const std_options: std.Options = .{
    .log_level = .info,
};

const Subcommands = enum { help, build };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var args_iter = try std.process.ArgIterator.initWithAllocator(alloc);
    defer args_iter.deinit();
    _ = args_iter.next(); // Skip executable name.

    const subcommand_name = args_iter.next() orelse {
        std.debug.print("Too few arguments. 'atra' command requires at least one subcommand.", .{});
        std.process.exit(1);
    };

    const subcommand = std.meta.stringToEnum(Subcommands, subcommand_name) orelse {
        std.debug.print("Invalid subcommand '{s}'. Use 'atra help' to list all possible subcommands.", .{subcommand_name});
        std.process.exit(1);
    };

    switch (subcommand) {
        .help => try printHelp(),
        .build => try handleBuildCommand(alloc, &args_iter),
    }
}

fn printHelp() !void {
    const stdout = std.io.getStdOut();
    try stdout.writeAll(
        \\Atra CLI. Tool for compiling Atra language.
        \\Here is a list of all possible subcommands:
        \\
        \\help - Prints this help message.
        \\build <file_or_directory> - Build given file or all files in a given directory.
    );
}

fn handleBuildCommand(alloc: std.mem.Allocator, args_iter: *std.process.ArgIterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\-o, --out <str> Set output file/directory for the compiled output.
        \\<str> File or directory to compile.
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, args_iter, .{
        .diagnostic = &diag,
        .allocator = alloc,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});

    const path_to_compile = res.positionals[0] orelse return error.MissingArg1;
    const path_stat = try std.fs.cwd().statFile(path_to_compile);
    const absolute_path = try std.fs.cwd().realpathAlloc(alloc, path_to_compile);
    defer alloc.free(absolute_path);

    const out_absolute_path = try std.fs.cwd().realpathAlloc(alloc, res.args.out orelse path_to_compile);
    defer alloc.free(out_absolute_path);

    var compiler = Compiler.init(alloc);
    defer compiler.deinit();

    switch (path_stat.kind) {
        .file => {
            std.log.info("Compiling single file: {s}", .{absolute_path});
            const parent_path = std.fs.path.dirname(absolute_path).?;
            const out_path_dir = std.fs.path.dirname(out_absolute_path).?;
            const artifact = try getOutputArtifactName(
                alloc,
                parent_path,
                absolute_path,
                out_path_dir,
            );
            defer alloc.free(artifact);

            try ensureParentExists(artifact);
            const target_file = try std.fs.createFileAbsolute(artifact, .{});
            defer target_file.close();

            try compiler.compileFromRoot(absolute_path, target_file.writer().any());
        },
        .directory => {
            std.log.info("Compiling project in directory: {s}", .{absolute_path});

            const dir_iterator = try std.fs.openDirAbsolute(absolute_path, .{
                .access_sub_paths = true,
                .iterate = true,
            });
            var walker = try dir_iterator.walk(alloc);
            defer walker.deinit();

            while (try walker.next()) |subpath| {
                if (subpath.kind != .file) continue;
                if (subpath.basename[0] != '+') continue;

                const source_file_absolute = try std.fs.path.join(alloc, &.{ absolute_path, subpath.path });
                defer alloc.free(source_file_absolute);
                std.log.info("Compiling project root: {s}", .{source_file_absolute});

                const out_path_dir = try std.fs.path.join(alloc, &.{ out_absolute_path, "atra-out" });
                defer alloc.free(out_path_dir);
                const artifact = try getOutputArtifactName(
                    alloc,
                    absolute_path,
                    source_file_absolute,
                    out_path_dir,
                );
                defer alloc.free(artifact);

                try ensureParentExists(artifact);
                const target_file = try std.fs.createFileAbsolute(artifact, .{});
                defer target_file.close();

                try compiler.compileFromRoot(source_file_absolute, target_file.writer().any());
            }
        },
        else => return error.InvalidPathKind,
    }
}

fn getOutputArtifactName(
    alloc: std.mem.Allocator,
    compilation_root: []const u8,
    source: []const u8,
    output_path: []const u8,
) ![]const u8 {
    const output_basename = try std.mem.concat(
        alloc,
        u8,
        &.{ std.fs.path.stem(source), ".html" },
    );
    defer alloc.free(output_basename);

    const output_relative_full = try std.fs.path.relative(alloc, compilation_root, source);
    defer alloc.free(output_relative_full);
    const output_relative_dirname = std.fs.path.dirname(output_relative_full) orelse ".";

    const final = try std.fs.path.join(alloc, &.{
        output_path,
        output_relative_dirname,
        if (output_basename[0] == '+') output_basename[1..] else output_basename,
    });
    defer alloc.free(final);
    return try std.fs.path.resolve(alloc, &.{final});
}

fn ensureParentExists(source: []const u8) !void {
    var path_iter = std.fs.path.NativeComponentIterator{ .path = source };
    var current = path_iter.next();
    while (current != null) : (current = path_iter.next()) {
        if (path_iter.peekNext() != null) {
            if (std.fs.accessAbsolute(current.?.path, .{})) |ok| {
                _ = ok;
            } else |err| {
                if (err == error.FileNotFound)
                    try std.fs.makeDirAbsolute(current.?.path);
            }
        }
    }
}

test {
    // Ensure tests from all modules (even unused) run.
    std.testing.refAllDecls(@This());
}
