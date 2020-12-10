usingnamespace @import("protocol.zig");
const std = @import("std");
const pike = @import("pike");
const zap = @import("zap");
//const pam = @import("pam");

pub const pike_task = zap.runtime.executor.Task;
pub const pike_batch = zap.runtime.executor.Batch;
pub const pike_dispatch = dispatch;

const Allocator = std.mem.Allocator;
const Line = std.ArrayListUnmanaged(u8);
const Buffer = std.ArrayListUnmanaged(Line);

inline fn dispatch(batchable: anytype, args: anytype) void {
    zap.runtime.schedule(batchable, args);
}

const User = struct {
    client: Client,
    cursor: Position = Position{ .line = 1, .col = 1 },
    room: *Room,
    fifo: std.fifo.LinearFifo(u8, .Dynamic),

    const Self = @This();

    fn run(self: *Self) void {
        _run(self) catch |err| {
            std.log.err("User - run(): {}", .{@errorName(err)});
        };
    }

    fn _run(self: *Self) !void {
        zap.runtime.yield();

        while (true) {
            // TODO: handle closed connection
            const message = try Message.deserialize(self.client.socket.reader());

            std.log.debug("{}: {}", .{ self.client.socket, message });

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

    fn createUser(self: *Self, client: Client) !void {
        const held = self.mtx.acquire();
        defer held.release();

        const user = try self.allocator.create(User);
        user.* = .{
            .client = client,
            .room = self,
            .fifo = std.fifo.LinearFifo(u8, .Dynamic).init(self.allocator),
        };

        try self.users.append(self.allocator, user);

        // TODO: append entire buffer to user's message queue

        zap.runtime.spawn(.{}, User.run, .{user}) catch |err| {
            std.log.err("Server - runtime.spawn(): {}", .{@errorName(err)});
        };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    try try zap.runtime.run(.{}, asyncMain, .{&gpa.allocator});
}

pub fn asyncMain(allocator: *Allocator) !void {
    defer std.log.debug("Successfully shut down", .{});

    try pike.init();
    pike.deinit();

    const notifier = try pike.Notifier.init();
    defer notifier.deinit();

    var stopped = false;

    var frame = async run(allocator, &notifier, &stopped);

    while (!stopped) {
        try notifier.poll(1_000_000);
    }

    try nosuspend await frame;
}

pub fn run(allocator: *Allocator, notifier: *const pike.Notifier, stopped: *bool) !void {
    var signal = try pike.Signal.init(.{ .interrupt = true });
    defer signal.deinit();

    var event = try pike.Event.init();
    defer event.deinit();

    try event.registerTo(notifier);

    defer {
        stopped.* = true;
        event.post() catch unreachable;
    }

    var server = try Server.init(allocator);
    defer server.deinit();

    try server.start(notifier, try std.net.Address.parseIp("127.0.0.1", 9000));
    try signal.wait();
}

pub const ClientQueue = std.atomic.Queue(*Client);

pub const Client = struct {
    socket: pike.Socket,
    address: std.net.Address,

    fn run(
        server: *Server,
        notifier: *const pike.Notifier,
        _socket: pike.Socket,
        _address: std.net.Address,
    ) void {
        _run(server, notifier, _socket, _address) catch |err| {
            std.log.err("Client - run(): {}", .{@errorName(err)});
        };
    }

    inline fn _run(
        server: *Server,
        notifier: *const pike.Notifier,
        _socket: pike.Socket,
        _address: std.net.Address,
    ) !void {
        zap.runtime.yield();

        var self = Client{ .socket = _socket, .address = _address };
        var node = ClientQueue.Node{ .data = &self };
        const writer = self.socket.writer();
        const reader = self.socket.reader();

        server.clients.put(&node);
        defer _ = server.clients.remove(&node);
        errdefer self.socket.deinit();
        try self.socket.registerTo(notifier);

        try Message.serialize(.{ .request = .{ .style = .prompt_echo_on } }, "Username: ", writer);
        var username_msg = try Message.deserialize(reader);
        if (username_msg.event != .response) return error.BadResponse;
        const username = try username_msg.readPayload(server.allocator);

        //const pam_client = try pam.Client.start("collusion", username, &conv);
        //defer pam_client.end() catch {};
        //try pam_client.authenticate(0);

        try Message.serialize(.{ .ok = {} }, null, writer);
        var msg = try Message.deserialize(reader);
        if (msg.event != .start) return error.BadResponse;
        const room_name = try msg.readPayload(server.allocator);

        const room_exists = server.rooms.contains(room_name);
        const entry = switch (msg.event.start.cmd) {
            .host => blk: {
                if (room_exists) {
                    try Message.serialize(.{ .err = .{} }, "Room already exists", writer);
                    return error.RoomExists;
                }

                break :blk try server.rooms.getOrPutValue(room_name, Room.init(server.allocator));
            },
            .join => blk: {
                if (!room_exists) {
                    try Message.serialize(.{ .err = .{} }, "Room doesn't exist", writer);
                    return error.RoomDoesntExist;
                }

                break :blk server.rooms.getEntry(room_name) orelse unreachable;
            },
        };

        try entry.*.value.createUser(self);
        try Message.serialize(.{ .ok = {} }, null, self.socket.writer());
    }
};

pub const Server = struct {
    allocator: *Allocator,
    socket: pike.Socket,
    rooms: std.StringHashMap(Room),
    clients: ClientQueue,

    frame: @Frame(Server.run),

    pub fn init(allocator: *Allocator) !Server {
        var socket = try pike.Socket.init(std.os.AF_INET, std.os.SOCK_STREAM, std.os.IPPROTO_TCP, 0);
        errdefer socket.deinit();

        try socket.set(.reuse_address, true);
        return Server{
            .allocator = allocator,
            .socket = socket,
            .rooms = std.StringHashMap(Room).init(allocator),
            .clients = ClientQueue.init(),
            .frame = undefined,
        };
    }

    pub fn deinit(self: *Server) void {
        self.socket.deinit();

        await self.frame;

        while (self.clients.get()) |node| {
            node.data.socket.deinit();
        }
    }

    pub fn start(self: *Server, notifier: *const pike.Notifier, address: std.net.Address) !void {
        try self.socket.bind(address);
        try self.socket.listen(128);
        try self.socket.registerTo(notifier);

        self.frame = async self.run(notifier);

        std.log.info("Web server started on: {}", .{address});
    }

    pub fn run(self: *Server, notifier: *const pike.Notifier) void {
        defer std.log.debug("Web server has shut down", .{});

        while (true) {
            var conn = self.socket.accept() catch |err| switch (err) {
                error.SocketNotListening, error.OperationCancelled => return,
                else => {
                    std.log.err("Server - socket.accept(): {}", .{@errorName(err)});
                    continue;
                },
            };

            zap.runtime.spawn(.{}, Client.run, .{ self, notifier, conn.socket, conn.address }) catch |err| {
                std.log.err("Server - runtime.spawn(): {}", .{@errorName(err)});
                continue;
            };
        }
    }
};

//fn authConv(
//    allocator: *Alloctor,
//    messages: []*const pam.Message,
//    responses: []pam.Response,
//    data: usize,
//) !void {
//    const socket = @intToPtr(*const pike.Socket, data);
//    for (messages) |message, i| {
//        const payload = std.mem.spanZ(message.msg);
//        try Message.serialize(.{
//            .request = .{
//                .style = message.style,
//                .len = payload.len,
//            },
//        });
//        try socket.writer().writeAll(payload);
//
//        const resp = try Message.deserialize(socket.reader());
//        if (resp.event != .response) return error.BadResponse;
//
//        const resp_payload = try resp.readPayloadAlloc(allocator);
//        responses[i].resp = resp_payload.ptr;
//    }
//}
//
//fn authInThread(ctx: struct {
//    username: []const u8,
//    socket: *const pike.Socket,
//    success: *bool,
//}) void {
//    const conv = pam.conversation(authConv, @ptrToInt(socket));
//    var pam_client = pam.Client.start("collusion", ctx.username, &conv) catch return;
//    defer pam_client.end() catch {};
//
//    pam_client.authenticate(0) catch |err| {
//        std.log.err("{} failed to log in: {}", .{ ctx.username, @errorName(err) });
//        return;
//    };
//
//    std.log.info("{} logged in successfully", .{ctx.username});
//    success.* = true;
//}
