const std = @import("std");
const pike = @import("pike");
const pam = @import("pam");

// As soon as a client connects to the collusion server it will be prompted for
// a username. This will be sent over as a pam style prompt so that vim can
// easily get the user to fill it out, it is always guaranteed.
//
// Next the server will send N pam style requests, expecting a response for
// each before sending the next request. These responses are fed right into
// PAM. Once the client has processed all the pam requests then it will send an
// "OK" message, which the client will respond with whether it is hosting or
// joining, which will also get an "OK" if it is cleared to join a room or host
// a new room.
//
// If a host is "Ok"ed then the session begins. It is assumed that the file
// buffer is empty so it's up to the client to send an insert event with the
// file contents if the file is in fact, not empty.
//
// If a join is "Ok"ed then the session begins. It is assumed that the file
// buffer is empty so it's up to the client to clear it's own buffer, and the
// server's to send an insert event with the contents of the room's buffer.
//
// When the session is initialized, processing of events is asyncronous and
// requires no more state tracking like authentication and initialization does.
//
// At any point an error might occur, and that is what the "ERR" event is for.
// In this case it sends a string to be displayed in vim, and then closes the
// connection to the client.

pub const Cmd = enum { host, join };
const StringPayload = struct {
    len: u32 = 0,
};

pub const MessageStyle = pam.Message.Style;

pub const Event = union(enum) {
    ok: struct {
        something: u32 = 0,
    },
    err: StringPayload,

    // auth
    request: struct {
        style: MessageStyle,
        len: u32 = 0,
    },
    response: StringPayload,
    start: struct {
        cmd: Cmd,
        len: u32 = 0,
    },

    // regular events
    disconnected: StringPayload,
    move: struct {
        pos: Position,
    },
    insert: struct {
        start: u32,
        added: u32,
        len: u32 = 0,
    },
    delete: struct {
        start: u32,
        end: u32,
    },
    change: struct {
        start: u32,
        len: u32 = 0,
    },
};

pub const UserCursor = struct {
    id: u32,
    position: Position,
};

pub const Position = struct {
    line: u32,
    col: u32,
};

pub fn Message(comptime Reader: type, comptime Writer: type) type {
    return struct {
        event: Event,
        payload: ?Payload,

        const Self = @This();

        const Deserializer = std.io.Deserializer(.Big, .Byte, Reader);
        const Serializer = std.io.Serializer(.Big, .Byte, Writer);

        const Payload = struct {
            internal: Reader,
            len: u32,

            const PayloadReader = std.io.Reader(*Payload, Reader.Error, Payload.read);

            fn read(self: *Payload, buf: []u8) Reader.Error!usize {
                if (self.len == 0) return 0;
                const n = try self.internal.read(buf[0..std.math.min(buf.len, self.len)]);
                self.len -= @intCast(u32, n);
                return n;
            }

            fn reader(payload: *Payload) PayloadReader {
                return .{ .context = payload };
            }
        };

        pub fn deserialize(reader: Reader) !Self {
            var deserializer = Deserializer.init(reader);
            const event = try deserializer.deserialize(Event);
            const msg = Self{
                .event = event,
                .payload = inline for (std.meta.fields(Event)) |field| {
                    const TagType = @field(@TagType(Event), field.name);
                    const TagPayload = std.meta.TagPayloadType(Event, TagType);
                    if (event == TagType) {
                        if (TagPayload != void and @hasField(TagPayload, "len")) {
                            break Payload{ .internal = reader, .len = @field(event, field.name).len };
                        }
                    }
                } else null,
            };

            return msg;
        }

        pub fn readPayload(self: *Self, allocator: *std.mem.Allocator) ![]const u8 {
            return if (self.payload) |*p|
                try p.reader().readAllAlloc(allocator, 0x2000)
            else
                error.NoPayload;
        }

        pub fn serialize(event: Event, payload: ?[]const u8, writer: Writer) !void {
            var serializer = Serializer.init(writer);
            var e = event;

            inline for (std.meta.fields(Event)) |field| {
                const TagType = @field(@TagType(Event), field.name);
                const TagPayload = std.meta.TagPayloadType(Event, TagType);
                if (event == TagType) {
                    if (TagPayload != void and @hasField(TagPayload, "len")) {
                        if (payload) |p| {
                            @field(e, field.name).len = @intCast(u32, p.len);
                        }
                    }
                }
            }

            try serializer.serialize(e);
            if (payload) |p| {
                try writer.writeAll(p);
            }
        }
    };
}

test "serialize ok" {
    const Fifo = std.fifo.LinearFifo(u8, .{ .Static = 80 });
    var fifo = Fifo.init();
    defer fifo.deinit();

    const TestMessage = Message(@TypeOf(fifo.reader()), @TypeOf(fifo.writer()));

    try TestMessage.serialize(.{ .ok = .{} }, null, fifo.writer());
    const msg = try TestMessage.deserialize(fifo.reader());

    std.testing.expectEqual(msg.event, .{ .ok = .{} });
    std.testing.expectEqual(msg.payload, null);
}

test "serialize request" {
    const Fifo = std.fifo.LinearFifo(u8, .{ .Static = 80 });
    var fifo = Fifo.init();
    defer fifo.deinit();

    const TestMessage = Message(@TypeOf(fifo.reader()), @TypeOf(fifo.writer()));

    const payload_expected = "hello this is a payload";
    const expected = Event{ .request = .{ .style = MessageStyle.prompt_echo_on } };
    try TestMessage.serialize(expected, payload_expected, fifo.writer());
    var msg = try TestMessage.deserialize(fifo.reader());

    std.testing.expectEqual(expected.request.style, msg.event.request.style);
    std.testing.expect(msg.payload != null);

    const payload = try msg.payload.?.reader().readAllAlloc(std.heap.page_allocator, 0x2000);
    defer std.heap.page_allocator.free(payload);

    std.testing.expectEqualSlices(u8, payload_expected, payload);
}
