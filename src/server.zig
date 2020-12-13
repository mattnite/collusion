const std = @import("std");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const Line = std.ArrayListUnmanaged(u8);
const Buffer = std.ArrayListUnmanaged(Line);
const Message = protocol.Message(std.fs.File.Reader, std.fs.File.Writer);
const Position = protocol.Position;
const UserCursor = protocol.UserCursor;

pub const io_mode = .evented;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

var incoming = std.TailQueue(@Frame(processIncoming)){};
var rooms = std.StringHashMap(Room).init(&gpa.allocator);

const Room = struct {
    allocator: *Allocator,
    mtx: std.Mutex,
    users: std.ArrayListUnmanaged(*User),
    buffer: Buffer,

    const Self = @This();

    fn init(allocator: *Allocator) Self {
        return Self{
            .allocator = allocator,
            .mtx = std.Mutex{},
            .users = std.ArrayListUnmanaged(*User){},
            .buffer = Buffer{},
        };
    }

    fn deinit(self: *Self) void {
        self.users.deinit(self.allocator);
        for (self.buffer.items) |*line| {
            line.deinit(self.allocator);
        }

        self.buffer.deinit(self.allocator);
    }

    fn createUser(self: *Self, conn: std.net.StreamServer.Connection) !void {
        const held = self.mtx.acquire();
        defer held.release();

        const user = try self.allocator.create(User);
        user.* = .{
            .conn = conn,
            .room = self,
            .fifo = std.fifo.LinearFifo(u8, .Dynamic).init(self.allocator),
        };

        try self.users.append(self.allocator, user);

        // TODO: append entire buffer to user's message queue
    }
};

const User = struct {
    conn: std.net.StreamServer.Connection,
    cursor: Position = Position{ .line = 1, .col = 1 },
    room: *Room,
    fifo: std.fifo.LinearFifo(u8, .Dynamic),
    //read_task: @Frame(User.readTask),
    //write_task: ?@Frame(User.writeTask),

    const Self = @This();

    fn _run(self: *Self) !void {
        zap.runtime.yield();

        while (true) {
            // TODO: handle closed connection
            const message = try Message.deserialize(self.client.socket.reader());
            const held = self.room.mtx.acquire();
            defer held.release();

            switch (message.event) {
                .move => |move| {
                    self.cursor = move.pos;
                    for (self.room.users.items) |user, i| {
                        if (user == self) continue;

                        var serializer = std.io.serializer(.Big, .Byte, user.fifo.writer());
                        try serializer.serialize(UserCursor{
                            // TODO: user id's /username?
                            .id = @intCast(u32, i),
                            .position = move.pos,
                        });
                    }
                },
                else => {},
            }
        }
    }
};

pub fn main() !void {
    defer _ = gpa.deinit();

    var server = std.net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();

    const loop = std.event.Loop.instance.?;
    try server.listen(try std.net.Address.parseIp("127.0.0.1", 9000));

    std.log.info("listening on port {}, pid: {}", .{ server.listen_address.getPort(), std.os.linux.getpid() });
    while (true) {
        try loop.runDetached(&gpa.allocator, processIncoming, .{try server.accept()});
    }
}

fn processIncoming(conn: std.net.StreamServer.Connection) void {
    processIncomingImpl(conn) catch |err| {
        std.log.err("got error: {}", .{err});
    };
}

fn processIncomingImpl(conn: std.net.StreamServer.Connection) !void {
    std.log.info("connection with fd {}", .{conn.file.handle});

    const writer = conn.file.writer();
    const reader = conn.file.reader();

    errdefer conn.file.close();

    std.log.info("sending username", .{});
    try Message.serialize(.{ .request = .{ .style = .prompt_echo_on } }, "Username: ", writer);
    var username_msg = try Message.deserialize(reader);
    if (username_msg.event != .response) return error.BadResponse;
    const username = try username_msg.readPayload(&gpa.allocator);

    //const pam_client = try pam.Client.start("collusion", username, &conv);
    //defer pam_client.end() catch {};
    //try pam_client.authenticate(0);

    std.log.info("passed auth", .{});
    try Message.serialize(.{ .ok = .{} }, null, writer);
    var msg = try Message.deserialize(reader);
    if (msg.event != .start) return error.BadResponse;
    const room_name = try msg.readPayload(&gpa.allocator);
    const room_exists = rooms.contains(room_name);
    std.log.info("they want to {} room {}", .{ msg.event.start.cmd, room_name });
    const entry = switch (msg.event.start.cmd) {
        .host => blk: {
            if (room_exists) {
                try Message.serialize(.{ .err = .{} }, "Room already exists", writer);
                return error.RoomExists;
            }

            break :blk try rooms.getOrPutValue(room_name, Room.init(&gpa.allocator));
        },
        .join => blk: {
            if (!room_exists) {
                try Message.serialize(.{ .err = .{} }, "Room doesn't exist", writer);
                return error.RoomDoesntExist;
            }

            break :blk rooms.getEntry(room_name) orelse unreachable;
        },
    };
    errdefer if (msg.event.start.cmd == .host) rooms.removeAssertDiscard(room_name);

    try entry.*.value.createUser(conn);
    try Message.serialize(.{ .ok = .{} }, null, writer);
}
