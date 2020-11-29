const std = @import("std");
const net = @import("net");

const Line = std.ArrayListUnmanaged(u8);
const Buffer = std.ArrayListUnmanaged(Line);

pub const io_mode = .evented;

pub const Position = struct {
    line: u32,
    col: u32,
};

const User = struct {
    name: []const u8,
    id: u64,
    cursor: Position,
    room: ?*Room,

    const Self = @This();

    fn join(self: *Self, room: *Room) !void {}
    fn create() void {}
};

const Room = struct {
    mtx: std.Mutex,
    name: []const u8,
    users: std.ArrayList(User),
    buffer: Buffer,
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = &gpa.allocator;

    var rooms = std.StringHashMap(Room).init(allocator);
    defer rooms.deinit();

    var server = try net.Socket.create(.ipv4, .tcp);
    defer server.close();

    try server.bind(.{
        .address = .{ .ipv4 = net.Address.IPv4.any },
        .port = 6666,
    });

    try server.listen();
    std.debug.print("listening at port {}\n", .{try server.getLocalEndPoint()});

    // TODO: signal handler
    while (true) {}
}
