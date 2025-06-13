const std = @import("std");

const hir = @import("hir.zig");

tree: *const hir.Tree,
writer: std.io.AnyWriter,

indent: usize = 0,

const Self = @This();
// List of html tags that immediately close, eg. <meta ... />.
const void_tags = [_][]const u8{
    "area",  "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source",
    "track", "wbr",
};

fn isVoidTag(tag: []const u8) bool {
    for (void_tags) |void_tag|
        if (std.mem.eql(u8, void_tag, tag))
            return true;
    return false;
}

pub const EmitterError = error{} || std.io.AnyWriter.Error;
pub fn emitFromRoot(self: *const Self, root: usize) EmitterError!void {
    const node = self.tree.nodes.items[root];

    switch (node) {
        .basic_tag => |tag| {
            // Opening tag with attributes.
            try self.writer.writeByte('<');
            try self.writer.writeAll(tag.name);
            for (tag.attributes) |attrib| {
                try self.writer.writeByte(' ');
                try self.writer.writeAll(attrib.name);
                try self.writer.writeAll("=\"");
                try self.writer.writeAll(attrib.value);
                try self.writer.writeByte('"');
            }
            if (isVoidTag(tag.name)) {
                try self.writer.writeAll(" />");
                return;
            }
            try self.writer.writeByte('>');

            // Body.
            for (tag.children) |child|
                try self.emitFromRoot(child);

            // Closing tag.
            try self.writer.writeAll("</");
            try self.writer.writeAll(tag.name);
            try self.writer.writeByte('>');
        },
        .fragment => |frag| for (frag) |child|
            try self.emitFromRoot(child),
        .text => |text| try self.escapeText(text),
        .raw_html => |raw_text| try self.writer.writeAll(raw_text),
    }
}

fn writeIndent(self: *const Self) !void {
    try self.writer.writeByteNTimes(' ', self.indent * 4);
}

fn escapeText(self: *const Self, text: []const u8) !void {
    for (text) |char| {
        switch (char) {
            // '\t' => try builder.appendSlice("&#9;"),
            // '\n' => try builder.appendSlice("<br>"),
            // ' ' => try builder.appendSlice("&nbsp;"),
            '&' => try self.writer.writeAll("&amp;"),
            '<' => try self.writer.writeAll("&lt;"),
            '>' => try self.writer.writeAll("&gt;"),
            else => try self.writer.writeByte(char),
        }
    }
}
