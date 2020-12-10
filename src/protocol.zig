const std = @import("std");
const pike = @import("pike");
const pam = @import("pam");

pub const Cmd = enum { host, join };

pub const Message = struct {
    event: Event,
    payload: ?Payload,

    const Deserializer = std.io.Deserializer(.Big, .Byte, pike.Socket.Reader);
    const Serializer = std.io.Serializer(.Big, .Byte, pike.Socket.Writer);

    const Payload = struct {
        internal: pike.Socket.Reader,
        len: u32,

        const Reader = std.io.Reader(*Payload, pike.Socket.Reader.Error, Payload.read);

        fn read(self: *Payload, buf: []u8) pike.Socket.Reader.Error!usize {
            if (self.len == 0) return error.EndOfStream;
            const n = try self.internal.read(buf[0..std.math.min(buf.len, self.len)]);
            self.len -= @intCast(u32, n);
            return n;
        }

        fn reader(self: *Payload) Reader {
            return .{ .context = self };
        }
    };

    pub fn deserialize(reader: pike.Socket.Reader) !Message {
        var deserializer = Deserializer.init(reader);
        const event = try deserializer.deserialize(Event);
        return Message{
            .event = event,
            .payload = inline for (std.meta.fields(Event)) |field| {
                if (@hasField(@TypeOf(@field(Event, field.name)), "len")) break Payload{ .internal = reader, .len = event.len };
            } else null,
        };
    }

    pub fn readPayload(self: *Message, allocator: *std.mem.Allocator) ![]const u8 {
        return if (self.payload) |*p|
            try p.reader().readAllAlloc(allocator, 0x2000)
        else
            error.NoPayload;
    }

    pub fn serialize(event: Event, payload: ?[]const u8, writer: pike.Socket.Writer) !void {
        var serializer = Serializer.init(writer);
        var e = event;

        inline for (std.meta.fields(Event)) |field| {
            if (@hasField(@TypeOf(@field(Event, field.name)), "len")) {
                if (payload) |p| {
                    e.len = p.len;
                }
            }
        }

        try serializer.serialize(e);
        if (payload) |p| {
            try writer.writeAll(p);
        }
    }
};

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

const StringPayload = struct {
    len: u32 = 0,
};

pub const MessageStyle = enum(u8) {
    prompt_echo_off = pam.Message.Style.prompt_echo_off,
    prompt_echo_on = pam.Message.Style.prompt_echo_on,
    error_msg = pam.Message.Style.error_msg,
    text_info = pam.Message.Style.text_info,
};

pub const Event = union(enum) {
    ok: void,
    err: StringPayload,

    // auth
    request: struct {
        style: pam.Message.Style,
        len: u32 = 0,
    },
    response: StringPayload,
    start: struct {
        cmd: Cmd,
        len: u32,
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
