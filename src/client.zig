const std = @import("std");
const net = @import("net");
const mecha = @import("mecha");

const Position = @import("server.zig").Position;

const Cmd = enum { host, join };
const Event = union(enum) {
    move: Position,
    insert: struct {
        start: u32,
        added: u32,
    },
    delete: struct {
        start: u32,
        end: u32,
    },
    change: struct {
        start: u32,
    },
};

const two_nums = .{
    mecha.int(u32, 10),
    mecha.char(' '),
    mecha.int(u32, 10),
    mecha.eos,
};

const move = mecha.convert(Event, toMove, mecha.combine(.{mecha.string("mov ")} ++ two_nums));
const insert = mecha.convert(Event, toInsert, mecha.combine(.{mecha.string("ins ")} ++ two_nums));
const delete = mecha.convert(Event, toDelete, mecha.combine(.{mecha.string("del ")} ++ two_nums));
const change = mecha.convert(Event, toChange, mecha.combine(.{ mecha.string("chg "), mecha.int(u32, 10) }));
const event_parser = mecha.oneOf(.{ move, insert, delete, change });

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = &gpa.allocator;

    const file = try std.fs.createFileAbsolute("/tmp/collusion.log", .{ .truncate = true });
    defer file.close();

    const log = file.writer();
    const stdin = std.io.getStdIn().reader();

    var args = std.process.args();
    _ = args.skip();

    const cmd = try args.next(allocator) orelse error.MissingCmd;
    defer allocator.free(cmd);

    const room = try args.next(allocator) orelse error.MissingRoom;
    defer allocator.free(room);

    const server = try args.next(allocator) orelse error.MissingServer;
    defer allocator.free(server);

    const port = try args.next(allocator) orelse error.MissingPort;
    defer allocator.free(port);

    var buf: [80]u8 = undefined;
    while (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        const event = (event_parser(line) orelse {
            try log.print("I did bad: {}\n", .{line});
            return error.WhatYouThinkin;
        }).value;

        // do stuff
        try log.print("{}\n", .{event});
    }
}

fn toMove(tuple: anytype) ?Event {
    return Event{ .move = .{ .line = tuple[0], .col = tuple[1] } };
}

fn toInsert(tuple: anytype) ?Event {
    return Event{ .insert = .{ .start = tuple[0], .added = tuple[1] } };
}

fn toDelete(tuple: anytype) ?Event {
    return Event{ .delete = .{ .start = tuple[0], .end = tuple[1] } };
}

fn toChange(val: anytype) ?Event {
    return Event{ .change = .{ .start = val } };
}
