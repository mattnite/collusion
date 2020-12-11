const std = @import("std");
const mecha = @import("mecha");
const pike = @import("pike");
const zap = @import("zap");
const protocol = @import("protocol.zig");

const os = std.os;
const Message = protocol.Message(std.fs.File.Reader, std.fs.File.Writer);

const two_nums = .{
    mecha.int(u32, 10),
    mecha.char(' '),
    mecha.int(u32, 10),
    mecha.eos,
};

const move = mecha.map(Event, toMove, mecha.combine(.{mecha.string("mov ")} ++ two_nums));
const insert = mecha.map(Event, toInsert, mecha.combine(.{mecha.string("ins ")} ++ two_nums));
const delete = mecha.map(Event, toDelete, mecha.combine(.{mecha.string("del ")} ++ two_nums));
const change = mecha.map(Event, toChange, mecha.combine(.{ mecha.string("chg "), mecha.int(u32, 10) }));
const event_parser = mecha.oneOf(.{ move, insert, delete, change });

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = &gpa.allocator;

    var args = std.process.args();
    _ = args.skip();

    const cmd = blk: {
        const str = try args.next(allocator) orelse error.MissingCmd;
        defer allocator.free(str);

        if (std.mem.eql(u8, str, "host")) {
            break :blk protocol.Cmd.host;
        } else if (std.mem.eql(u8, str, "join")) {
            break :blk protocol.Cmd.join;
        } else return error.InvalidCmd;
    };

    const room = try args.next(allocator) orelse error.MissingRoom;
    defer allocator.free(room);

    const server = try args.next(allocator) orelse error.MissingServer;
    defer allocator.free(server);

    const port = try args.next(allocator) orelse error.MissingPort;
    defer allocator.free(port);

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    const socket = try std.net.tcpConnectToHost(allocator, server, try std.fmt.parseUnsigned(u16, port, 10));
    defer socket.close();

    while (true) {
        var msg = try Message.deserialize(socket.reader());
        switch (msg.event) {
            .ok => break,
            .request => |req| {
                const payload = try msg.readPayload(allocator);
                defer allocator.free(payload);

                switch (req.style) {
                    .prompt_echo_off => {
                        try stdout.print("inputsecret(\"{}\")\n", .{payload});
                        const line = try stdin.readUntilDelimiterAlloc(allocator, '\n', 0x200);
                        defer allocator.free(line);
                        try Message.serialize(.{ .response = .{} }, line, socket.writer());
                    },
                    .prompt_echo_on => {
                        try stdout.print("input(\"{}\")\n", .{payload});
                        const line = try stdin.readUntilDelimiterAlloc(allocator, '\n', 0x200);
                        defer allocator.free(line);
                        try Message.serialize(.{ .response = .{} }, line, socket.writer());
                    },
                    .text_info => {
                        try stdout.print("echo \"{}\"\n", .{payload});
                        try Message.serialize(.{ .response = .{} }, "", socket.writer());
                    },
                    .error_msg => {
                        try stdout.print("echo \"{}\"\n", .{payload});
                        try Message.serialize(.{ .response = .{} }, "", socket.writer());
                    },
                    else => return error.UnknownMessageType,
                }
            },
            else => return error.UnexpectedMessageType,
        }
    }

    try Message.serialize(.{ .start = .{ .cmd = cmd } }, room, socket.writer());
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
