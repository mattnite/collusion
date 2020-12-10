const std = @import("std");
const mecha = @import("mecha");
const pike = @import("pike");
const zap = @import("zap");
const protocol = @import("protocol.zig");

const net = std.net;
const mem = std.mem;
const os = std.os;

pub const pike_task = zap.runtime.executor.Task;
pub const pike_batch = zap.runtime.executor.Batch;
pub const pike_dispatch = dispatch;

inline fn dispatch(batchable: anytype, args: anytype) void {
    zap.runtime.schedule(batchable, args);
}

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

    const cmd = try args.next(allocator) orelse error.MissingCmd;
    defer allocator.free(cmd);

    const room = try args.next(allocator) orelse error.MissingRoom;
    defer allocator.free(room);

    const server = try args.next(allocator) orelse error.MissingServer;
    defer allocator.free(server);

    const port = try args.next(allocator) orelse error.MissingPort;
    defer allocator.free(port);

    try pike.init();
    defer pike.deinit();

    const notifier = try pike.Notifier.init();
    defer notifier.deinit();

    var stopped = false;
    var frame = async run(allocator, &notifier, &stopped, cmd, room, server, port);
    while (!stopped) {
        try notifier.poll(1_000_000);
    }

    try nosuspend await frame;
}

fn run(
    allocator: *mem.Allocator,
    notifier: *const pike.Notifier,
    stopped: *bool,
    cmd: []const u8,
    room: []const u8,
    server: []const u8,
    port: []const u8,
) !void {
    defer stopped.* = true;
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    var socket = try pike.Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0);
    defer socket.deinit();

    try socket.registerTo(notifier);
    const list = try net.getAddressList(allocator, server, try std.fmt.parseUnsigned(u16, port, 10));
    defer list.deinit();

    for (list.addrs) |addr| {
        socket.connect(addr) catch continue;
        std.log.info("Connected to {}", .{addr});
        break;
    } else return error.CantConnect;

    //try protocol.authenticate(&socket, stdin, stdout);
    //try protocol.init(&socket, cmd, room, stdin, stdout);
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
