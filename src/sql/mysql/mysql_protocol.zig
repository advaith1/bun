const std = @import("std");
const bun = @import("root").bun;

const Data = mysql.Data;
const protocol = @This();
const MySQLInt32 = mysql.MySQLInt32;
const MySQLInt16 = mysql.MySQLInt16;
const String = bun.String;
const debug = mysql.debug;
const JSValue = bun.JSC.JSValue;
const JSC = bun.JSC;
const types = mysql.types;
const BoringSSL = bun.BoringSSL;
const MySQLInt64 = mysql.MySQLInt64;

const mysql = @import("../mysql.zig");
const Value = mysql.types.Value;
// MySQL packet header size
pub const PACKET_HEADER_SIZE = 4;

pub const ArrayList = struct {
    array: *std.ArrayList(u8),

    pub fn offset(this: @This()) usize {
        return this.array.items.len;
    }

    pub fn write(this: @This(), bytes: []const u8) anyerror!void {
        try this.array.appendSlice(bytes);
    }

    pub fn pwrite(this: @This(), bytes: []const u8, i: usize) anyerror!void {
        @memcpy(this.array.items[i..][0..bytes.len], bytes);
    }

    pub const Writer = NewWriter(@This());
};

pub const StackReader = struct {
    buffer: []const u8 = "",
    offset: *usize,
    message_start: *usize,

    pub fn markMessageStart(this: @This()) void {
        this.message_start.* = this.offset.*;
    }

    pub fn ensureLength(this: @This(), length: usize) bool {
        return this.buffer.len >= (this.offset.* + length);
    }

    pub fn init(buffer: []const u8, offset: *usize, message_start: *usize) protocol.NewReader(StackReader) {
        return .{
            .wrapped = .{
                .buffer = buffer,
                .offset = offset,
                .message_start = message_start,
            },
        };
    }

    pub fn peek(this: StackReader) []const u8 {
        return this.buffer[this.offset.*..];
    }

    pub fn skip(this: StackReader, count: isize) void {
        if (count < 0) {
            const abs_count = @abs(count);
            if (abs_count > this.offset.*) {
                this.offset.* = 0;
                return;
            }
            this.offset.* -= @intCast(abs_count);
            return;
        }

        const ucount: usize = @intCast(count);
        if (this.offset.* + ucount > this.buffer.len) {
            this.offset.* = this.buffer.len;
            return;
        }

        this.offset.* += ucount;
    }

    pub fn ensureCapacity(this: StackReader, count: usize) bool {
        return this.buffer.len >= (this.offset.* + count);
    }

    pub fn read(this: StackReader, count: usize) anyerror!Data {
        const offset = this.offset.*;
        if (!this.ensureCapacity(count)) {
            return error.ShortRead;
        }

        this.skip(@intCast(count));
        return Data{
            .temporary = this.buffer[offset..this.offset.*],
        };
    }

    pub fn readZ(this: StackReader) anyerror!Data {
        const remaining = this.peek();
        if (bun.strings.indexOfChar(remaining, 0)) |zero| {
            this.skip(@intCast(zero + 1));
            return Data{
                .temporary = remaining[0..zero],
            };
        }

        return error.ShortRead;
    }
};

pub fn NewWriterWrap(
    comptime Context: type,
    comptime offsetFn_: (fn (ctx: Context) usize),
    comptime writeFunction_: (fn (ctx: Context, bytes: []const u8) anyerror!void),
    comptime pwriteFunction_: (fn (ctx: Context, bytes: []const u8, offset: usize) anyerror!void),
) type {
    return struct {
        wrapped: Context,

        const writeFn = writeFunction_;
        const pwriteFn = pwriteFunction_;
        const offsetFn = offsetFn_;
        pub const Ctx = Context;

        pub const WrappedWriter = @This();

        pub inline fn write(this: @This(), data: []const u8) anyerror!void {
            try writeFn(this.wrapped, data);
        }

        pub const LengthWriter = struct {
            index: usize,
            context: WrappedWriter,

            pub fn write(this: LengthWriter) anyerror!void {
                try this.context.pwrite(&Int32(this.context.offset() - this.index), this.index);
            }

            pub fn writeExcludingSelf(this: LengthWriter) anyerror!void {
                try this.context.pwrite(&Int32(this.context.offset() -| (this.index + 4)), this.index);
            }
        };

        pub inline fn length(this: @This()) anyerror!LengthWriter {
            const i = this.offset();
            try this.int4(0);
            return LengthWriter{
                .index = i,
                .context = this,
            };
        }

        pub inline fn offset(this: @This()) usize {
            return offsetFn(this.wrapped);
        }

        pub inline fn pwrite(this: @This(), data: []const u8, i: usize) anyerror!void {
            try pwriteFn(this.wrapped, data, i);
        }

        pub fn int4(this: @This(), value: MySQLInt32) !void {
            try this.write(std.mem.asBytes(&@byteSwap(value)));
        }

        pub fn int8(this: @This(), value: MySQLInt64) !void {
            try this.write(std.mem.asBytes(&@byteSwap(value)));
        }

        pub fn int1(this: @This(), value: u8) !void {
            try this.write(&[_]u8{value});
        }

        pub fn string(this: @This(), value: []const u8) !void {
            try this.write(value);
            if (value.len == 0 or value[value.len - 1] != 0)
                try this.write(&[_]u8{0});
        }

        pub fn String(this: @This(), value: bun.String) !void {
            if (value.isEmpty()) {
                try this.write(&[_]u8{0});
                return;
            }

            var sliced = value.toUTF8(bun.default_allocator);
            defer sliced.deinit();
            const slice = sliced.slice();

            try this.write(slice);
            if (slice.len == 0 or slice[slice.len - 1] != 0)
                try this.write(&[_]u8{0});
        }
    };
}

pub fn NewReaderWrap(
    comptime Context: type,
    comptime markMessageStartFn_: (fn (ctx: Context) void),
    comptime peekFn_: (fn (ctx: Context) []const u8),
    comptime skipFn_: (fn (ctx: Context, count: isize) void),
    comptime ensureCapacityFn_: (fn (ctx: Context, count: usize) bool),
    comptime readFunction_: (fn (ctx: Context, count: usize) anyerror!Data),
    comptime readZ_: (fn (ctx: Context) anyerror!Data),
) type {
    return struct {
        wrapped: Context,
        const readFn = readFunction_;
        const readZFn = readZ_;
        const ensureCapacityFn = ensureCapacityFn_;
        const skipFn = skipFn_;
        const peekFn = peekFn_;
        const markMessageStartFn = markMessageStartFn_;

        pub const Ctx = Context;

        pub inline fn markMessageStart(this: @This()) void {
            markMessageStartFn(this.wrapped);
        }

        pub inline fn read(this: @This(), count: usize) anyerror!Data {
            return try readFn(this.wrapped, count);
        }

        pub fn skip(this: @This(), count: isize) anyerror!void {
            skipFn(this.wrapped, count);
        }

        pub fn peek(this: @This()) []const u8 {
            return peekFn(this.wrapped);
        }

        pub inline fn readZ(this: @This()) anyerror!Data {
            return try readZFn(this.wrapped);
        }

        pub fn byte(this: @This()) !u8 {
            const data = try this.read(1);
            return data.slice()[0];
        }

        pub inline fn ensureCapacity(this: @This(), count: usize) anyerror!void {
            if (!ensureCapacityFn(this.wrapped, count)) {
                return error.ShortRead;
            }
        }

        pub fn int(this: @This(), comptime Int: type) !Int {
            var data = try this.read(@sizeOf(Int));
            defer data.deinit();
            if (comptime Int == u8) {
                return @as(Int, data.slice()[0]);
            }
            return @as(Int, @bitCast(data.slice()[0..@sizeOf(Int)].*));
        }
    };
}

pub fn NewReader(comptime Context: type) type {
    return NewReaderWrap(Context, Context.markMessageStart, Context.peek, Context.skip, Context.ensureLength, Context.read, Context.readZ);
}

pub fn NewWriter(comptime Context: type) type {
    return NewWriterWrap(Context, Context.offset, Context.write, Context.pwrite);
}

fn decoderWrap(comptime Container: type, comptime decodeFn: anytype) type {
    return struct {
        pub fn decode(this: *Container, context: anytype) anyerror!void {
            const Context = @TypeOf(context);
            try decodeFn(this, Context, NewReader(Context){ .wrapped = context });
        }
    };
}

fn writeWrap(comptime Container: type, comptime writeFn: anytype) type {
    return struct {
        pub fn write(this: *Container, context: anytype) anyerror!void {
            const Context = @TypeOf(context);
            try writeFn(this, Context, NewWriter(Context){ .wrapped = context });
        }
    };
}

fn Int32(value: anytype) [4]u8 {
    return @bitCast(@byteSwap(@as(MySQLInt32, @intCast(value))));
}

// MySQL packet types
pub const PacketType = enum(u8) {
    // Server packets
    OK = 0x00,
    EOF = 0xfe,
    ERROR = 0xff,
    LOCAL_INFILE = 0xfb,

    // Client/server packets
    HANDSHAKE = 0x0a,
    AUTH_SWITCH = 0xfe,
};

// Length-encoded integer encoding/decoding
pub fn encodeLengthInt(value: u64) []const u8 {
    if (value < 251) {
        return &[_]u8{@intCast(value)};
    } else if (value < 65536) {
        return &[_]u8{ 0xfc, @intCast(value & 0xff), @intCast((value >> 8) & 0xff) };
    } else if (value < 16777216) {
        return &[_]u8{
            0xfd,
            @intCast(value & 0xff),
            @intCast((value >> 8) & 0xff),
            @intCast((value >> 16) & 0xff),
        };
    } else {
        return &[_]u8{
            0xfe,
            @intCast(value & 0xff),
            @intCast((value >> 8) & 0xff),
            @intCast((value >> 16) & 0xff),
            @intCast((value >> 24) & 0xff),
            @intCast((value >> 32) & 0xff),
            @intCast((value >> 40) & 0xff),
            @intCast((value >> 48) & 0xff),
            @intCast((value >> 56) & 0xff),
        };
    }
}

pub fn decodeLengthInt(bytes: []const u8) ?struct { value: u64, bytes_read: usize } {
    if (bytes.len == 0) return null;

    switch (bytes[0]) {
        0xfc => {
            if (bytes.len < 3) return null;
            const value = bytes[1..3].*;
            return .{ .value = @as(u64, @as(u16, @bitCast(value))), .bytes_read = 3 };
        },
        0xfd => {
            if (bytes.len < 4) return null;
            const value = bytes[1..4].*;
            return .{ .value = @as(u64, @as(u24, @bitCast(value))), .bytes_read = 4 };
        },
        0xfe => {
            if (bytes.len < 9) return null;
            const value = bytes[0..8].*;
            return .{ .value = @bitCast(value), .bytes_read = 9 };
        },
        else => {
            return .{ .value = bytes[0], .bytes_read = 1 };
        },
    }
}

// MySQL packet header
pub const PacketHeader = struct {
    length: u24,
    sequence_id: u8,

    pub fn decode(bytes: []const u8) ?PacketHeader {
        if (bytes.len < 4) return null;

        return PacketHeader{
            .length = @as(u24, bytes[0]) |
                (@as(u24, bytes[1]) << 8) |
                (@as(u24, bytes[2]) << 16),
            .sequence_id = bytes[3],
        };
    }

    pub fn encode(self: PacketHeader) [4]u8 {
        return [4]u8{
            @intCast(self.length & 0xff),
            @intCast((self.length >> 8) & 0xff),
            @intCast((self.length >> 16) & 0xff),
            self.sequence_id,
        };
    }
};

// Initial handshake packet from server
pub const HandshakeV10 = struct {
    protocol_version: u8 = 10,
    server_version: Data = .{ .empty = {} },
    connection_id: u32 = 0,
    auth_plugin_data_part_1: [8]u8 = undefined,
    auth_plugin_data_part_2: []const u8 = &[_]u8{},
    capability_flags: mysql.Capabilities = .{},
    character_set: u8 = 0,
    status_flags: mysql.StatusFlags = .{},
    auth_plugin_name: Data = .{ .empty = {} },

    pub fn deinit(this: *HandshakeV10) void {
        this.server_version.deinit();
        this.auth_plugin_name.deinit();
    }

    pub fn decodeInternal(this: *HandshakeV10, comptime Context: type, reader: NewReader(Context)) !void {
        // Protocol version
        this.protocol_version = try reader.int(u8);
        if (this.protocol_version != 10) {
            return error.UnsupportedProtocolVersion;
        }

        // Server version (null-terminated string)
        this.server_version = try reader.readZ();

        // Connection ID (4 bytes)
        this.connection_id = try reader.int(u32);

        // Auth plugin data part 1 (8 bytes)
        var auth_data = try reader.read(8);
        defer auth_data.deinit();
        @memcpy(&this.auth_plugin_data_part_1, auth_data.slice());

        // Skip filler byte
        _ = try reader.int(u8);

        // Capability flags (lower 2 bytes)
        const capabilities_lower = try reader.int(u16);

        // Character set
        this.character_set = try reader.int(u8);

        // Status flags
        this.status_flags = mysql.StatusFlags.fromInt(try reader.int(u16));

        // Capability flags (upper 2 bytes)
        const capabilities_upper = try reader.int(u16);
        this.capability_flags = mysql.Capabilities.fromInt(@as(u32, capabilities_upper) << 16 | capabilities_lower);

        // Length of auth plugin data
        var auth_plugin_data_len = try reader.int(u8);
        if (auth_plugin_data_len < 21) {
            auth_plugin_data_len = 21;
        }

        // Skip reserved bytes
        try reader.skip(10);

        // Auth plugin data part 2
        const remaining_auth_len = @max(13, auth_plugin_data_len - 8);
        var auth_data_2 = try reader.read(remaining_auth_len);
        defer auth_data_2.deinit();
        this.auth_plugin_data_part_2 = try bun.default_allocator.dupe(u8, auth_data_2.slice());

        // Auth plugin name
        if (this.capability_flags.CLIENT_PLUGIN_AUTH) {
            this.auth_plugin_name = try reader.readZ();
        }
    }

    pub const decode = decoderWrap(HandshakeV10, decodeInternal).decode;
};

// Client authentication response
pub const HandshakeResponse41 = struct {
    capability_flags: mysql.Capabilities,
    max_packet_size: u32 = 16777216, // 16MB default
    character_set: u8,
    username: Data,
    auth_response: Data,
    database: Data,
    auth_plugin_name: Data,
    connect_attrs: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn deinit(this: *HandshakeResponse41) void {
        this.username.deinit();
        this.auth_response.deinit();
        this.database.deinit();
        this.auth_plugin_name.deinit();

        var it = this.connect_attrs.iterator();
        while (it.next()) |entry| {
            bun.default_allocator.free(entry.key_ptr.*);
            bun.default_allocator.free(entry.value_ptr.*);
        }
        this.connect_attrs.deinit(bun.default_allocator);
    }

    pub fn writeInternal(this: *const HandshakeResponse41, comptime Context: type, writer: NewWriter(Context)) !void {
        // Client capability flags
        try writer.int4(this.capability_flags.toInt());

        // Max packet size
        try writer.int4(this.max_packet_size);

        // Character set
        try writer.int1(this.character_set);

        // Reserved bytes
        try writer.write(&[_]u8{0} ** 23);

        // Username
        try writer.string(this.username.slice());

        // Auth response length + data
        const auth_data = this.auth_response.slice();
        if (this.capability_flags.CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA) {
            try writer.write(encodeLengthInt(auth_data.len));
            try writer.write(auth_data);
        } else {
            try writer.int1(@intCast(auth_data.len));
            try writer.write(auth_data);
        }

        // Database name if requested
        if (this.capability_flags.CLIENT_CONNECT_WITH_DB) {
            try writer.string(this.database.slice());
        }

        // Auth plugin name if supported
        if (this.capability_flags.CLIENT_PLUGIN_AUTH) {
            try writer.string(this.auth_plugin_name.slice());
        }

        // Connection attributes if supported
        if (this.capability_flags.CLIENT_CONNECT_ATTRS) {
            var attrs_buf = std.ArrayList(u8).init(bun.default_allocator);
            defer attrs_buf.deinit();

            var it = this.connect_attrs.iterator();
            while (it.next()) |entry| {
                try attrs_buf.appendSlice(encodeLengthInt(entry.key_ptr.len));
                try attrs_buf.appendSlice(entry.key_ptr.*);
                try attrs_buf.appendSlice(encodeLengthInt(entry.value_ptr.len));
                try attrs_buf.appendSlice(entry.value_ptr.*);
            }

            try writer.write(encodeLengthInt(attrs_buf.items.len));
            try writer.write(attrs_buf.items);
        }
    }

    pub const write = writeWrap(HandshakeResponse41, writeInternal).write;
};

// OK Packet
pub const OKPacket = struct {
    header: u8 = 0x00,
    affected_rows: u64 = 0,
    last_insert_id: u64 = 0,
    status_flags: mysql.StatusFlags = .{},
    warnings: u16 = 0,
    info: Data = .{ .empty = {} },
    session_state_changes: Data = .{ .empty = {} },

    pub fn deinit(this: *OKPacket) void {
        this.info.deinit();
        this.session_state_changes.deinit();
    }

    pub fn decodeInternal(this: *OKPacket, comptime Context: type, reader: NewReader(Context)) !void {
        this.header = try reader.int(u8);
        if (this.header != 0x00) {
            return error.InvalidOKPacket;
        }

        // Affected rows (length encoded integer)
        if (decodeLengthInt(reader.peek())) |result| {
            this.affected_rows = result.value;
            try reader.skip(result.bytes_read);
        } else {
            return error.InvalidOKPacket;
        }

        // Last insert ID (length encoded integer)
        if (decodeLengthInt(reader.peek())) |result| {
            this.last_insert_id = result.value;
            try reader.skip(result.bytes_read);
        } else {
            return error.InvalidOKPacket;
        }

        // Status flags
        this.status_flags = mysql.StatusFlags.fromInt(try reader.int(u16));

        // Warnings
        this.warnings = try reader.int(u16);

        // Info (EOF-terminated string)
        if (reader.peek().len > 0) {
            this.info = try reader.readZ();
        }

        // Session state changes if SESSION_TRACK_STATE_CHANGE is set
        if (this.status_flags.SERVER_SESSION_STATE_CHANGED) {
            if (decodeLengthInt(reader.peek())) |result| {
                const state_data = try reader.read(@intCast(result.value));
                this.session_state_changes = state_data;
                try reader.skip(result.bytes_read);
            }
        }
    }

    pub const decode = decoderWrap(OKPacket, decodeInternal).decode;
};

// Error Packet
pub const ErrorPacket = struct {
    header: u8 = 0xff,
    error_code: u16,
    sql_state_marker: ?u8 = null,
    sql_state: ?[5]u8 = null,
    error_message: Data = .{ .empty = {} },

    pub fn deinit(this: *ErrorPacket) void {
        this.error_message.deinit();
    }

    pub fn decodeInternal(this: *ErrorPacket, comptime Context: type, reader: NewReader(Context)) !void {
        this.header = try reader.int(u8);
        if (this.header != 0xff) {
            return error.InvalidErrorPacket;
        }

        this.error_code = try reader.int(u16);

        // Check if we have a SQL state marker
        const next_byte = try reader.int(u8);
        if (next_byte == '#') {
            this.sql_state_marker = '#';
            var sql_state_data = try reader.read(5);
            defer sql_state_data.deinit();
            this.sql_state = sql_state_data.slice()[0..5].*;
        } else {
            // No SQL state, rewind one byte
            try reader.skip(-1);
        }

        // Read the error message (rest of packet)
        this.error_message = try reader.readZ();
    }

    pub const decode = decoderWrap(ErrorPacket, decodeInternal).decode;

    pub fn toJS(this: ErrorPacket, globalObject: *JSC.JSGlobalObject) JSValue {
        var msg = this.error_message.slice();
        if (msg.len == 0) {
            msg = "MySQL error occurred";
        }

        const err = globalObject.createErrorInstance("{s} (Code: {d})", .{
            msg, this.error_code,
        });

        if (this.sql_state) |state| {
            err.put(globalObject, JSC.ZigString.static("sqlState"), JSC.ZigString.init(&state).toJS(globalObject));
        }

        err.put(globalObject, JSC.ZigString.static("code"), JSValue.jsNumber(this.error_code));

        return err;
    }
};

// Command packet types
pub const CommandType = enum(u8) {
    COM_QUIT = 0x01,
    COM_INIT_DB = 0x02,
    COM_QUERY = 0x03,
    COM_FIELD_LIST = 0x04,
    COM_CREATE_DB = 0x05,
    COM_DROP_DB = 0x06,
    COM_REFRESH = 0x07,
    COM_SHUTDOWN = 0x08,
    COM_STATISTICS = 0x09,
    COM_PROCESS_INFO = 0x0a,
    COM_CONNECT = 0x0b,
    COM_PROCESS_KILL = 0x0c,
    COM_DEBUG = 0x0d,
    COM_PING = 0x0e,
    COM_TIME = 0x0f,
    COM_DELAYED_INSERT = 0x10,
    COM_CHANGE_USER = 0x11,
    COM_BINLOG_DUMP = 0x12,
    COM_TABLE_DUMP = 0x13,
    COM_CONNECT_OUT = 0x14,
    COM_REGISTER_SLAVE = 0x15,
    COM_STMT_PREPARE = 0x16,
    COM_STMT_EXECUTE = 0x17,
    COM_STMT_SEND_LONG_DATA = 0x18,
    COM_STMT_CLOSE = 0x19,
    COM_STMT_RESET = 0x1a,
    COM_SET_OPTION = 0x1b,
    COM_STMT_FETCH = 0x1c,
    COM_DAEMON = 0x1d,
    COM_BINLOG_DUMP_GTID = 0x1e,
    COM_RESET_CONNECTION = 0x1f,
};

// Query command packet
pub const QueryPacket = struct {
    command: CommandType = .COM_QUERY,
    query: Data,

    pub fn deinit(this: *QueryPacket) void {
        this.query.deinit();
    }

    pub fn writeInternal(this: *const QueryPacket, comptime Context: type, writer: NewWriter(Context)) !void {
        try writer.int1(@intFromEnum(this.command));
        try writer.write(this.query.slice());
    }

    pub const write = writeWrap(QueryPacket, writeInternal).write;
};

// Prepared statement prepare packet
pub const StmtPreparePacket = struct {
    command: CommandType = .COM_STMT_PREPARE,
    query: Data,

    pub fn deinit(this: *StmtPreparePacket) void {
        this.query.deinit();
    }

    pub fn writeInternal(this: *const StmtPreparePacket, comptime Context: type, writer: NewWriter(Context)) !void {
        try writer.int1(@intFromEnum(this.command));
        try writer.write(this.query.slice());
    }

    pub const write = writeWrap(StmtPreparePacket, writeInternal).write;
};

// Prepared statement prepare response
pub const StmtPrepareOKPacket = struct {
    status: u8 = 0,
    statement_id: u32,
    num_columns: u16,
    num_params: u16,
    warning_count: u16,

    pub fn decodeInternal(this: *StmtPrepareOKPacket, comptime Context: type, reader: NewReader(Context)) !void {
        this.status = try reader.int(u8);
        if (this.status != 0) {
            return error.InvalidPrepareOKPacket;
        }

        this.statement_id = try reader.int(u32);
        this.num_columns = try reader.int(u16);
        this.num_params = try reader.int(u16);
        _ = try reader.int(u8); // reserved_1
        this.warning_count = try reader.int(u16);
    }

    pub const decode = decoderWrap(StmtPrepareOKPacket, decodeInternal).decode;
};

// Prepared statement execute packet
pub const StmtExecutePacket = struct {
    command: CommandType = .COM_STMT_EXECUTE,
    statement_id: u32,
    flags: u8 = 0,
    iteration_count: u32 = 1,
    new_params_bind_flag: bool = true,
    params: []const Data = &[_]Data{},
    param_types: []const types.FieldType = &[_]types.FieldType{},

    pub fn deinit(this: *StmtExecutePacket) void {
        for (this.params) |*param| {
            param.deinit();
        }
    }

    pub fn writeInternal(this: *const StmtExecutePacket, comptime Context: type, writer: NewWriter(Context)) !void {
        try writer.int1(@intFromEnum(this.command));
        try writer.int4(this.statement_id);
        try writer.int1(this.flags);
        try writer.int4(this.iteration_count);

        if (this.params.len > 0) {
            // Calculate null bitmap
            const bitmap_bytes = (this.params.len + 7) / 8;
            var null_bitmap = try bun.default_allocator.alloc(u8, bitmap_bytes);
            defer bun.default_allocator.free(null_bitmap);
            @memset(null_bitmap, 0);

            for (this.params, 0..) |param, i| {
                if (param == .empty) {
                    null_bitmap[i >> 3] |= @as(u8, 1) << @as(u3, @truncate(i & 7));
                }
            }

            try writer.write(null_bitmap);

            // Write new params bind flag
            try writer.int1(@intFromBool(this.new_params_bind_flag));

            if (this.new_params_bind_flag) {
                // Write parameter types
                for (this.param_types) |param_type| {
                    try writer.int1(@intFromEnum(param_type));
                    try writer.int1(1); // unsigned flag, always true for now
                }
            }

            // Write parameter values
            for (this.params, this.param_types) |param, param_type| {
                if (param == .empty) continue;

                const value = param.slice();
                if (param_type.isBinaryFormatSupported()) {
                    try writer.write(value);
                } else {
                    try writer.write(encodeLengthInt(value.len));
                    try writer.write(value);
                }
            }
        }
    }

    pub const write = writeWrap(StmtExecutePacket, writeInternal).write;
};

// Column definition packet
pub const ColumnDefinition41 = struct {
    catalog: Data = .{ .empty = {} },
    schema: Data = .{ .empty = {} },
    table: Data = .{ .empty = {} },
    org_table: Data = .{ .empty = {} },
    name: Data = .{ .empty = {} },
    org_name: Data = .{ .empty = {} },
    character_set: u16 = 0,
    column_length: u32 = 0,
    column_type: types.FieldType = .MYSQL_TYPE_NULL,
    flags: ColumnFlags = .{},
    decimals: u8 = 0,

    pub const ColumnFlags = packed struct {
        NOT_NULL: bool = false,
        PRI_KEY: bool = false,
        UNIQUE_KEY: bool = false,
        MULTIPLE_KEY: bool = false,
        BLOB: bool = false,
        UNSIGNED: bool = false,
        ZEROFILL: bool = false,
        BINARY: bool = false,
        ENUM: bool = false,
        AUTO_INCREMENT: bool = false,
        TIMESTAMP: bool = false,
        SET: bool = false,
        NO_DEFAULT_VALUE: bool = false,
        ON_UPDATE_NOW: bool = false,
        _padding: u2 = 0,

        pub fn toInt(this: ColumnFlags) u16 {
            return @bitCast(this);
        }

        pub fn fromInt(flags: u16) ColumnFlags {
            return @bitCast(flags);
        }
    };

    pub fn deinit(this: *ColumnDefinition41) void {
        this.catalog.deinit();
        this.schema.deinit();
        this.table.deinit();
        this.org_table.deinit();
        this.name.deinit();
        this.org_name.deinit();
    }

    pub fn decodeInternal(this: *ColumnDefinition41, comptime Context: type, reader: NewReader(Context)) !void {
        // Length encoded strings
        if (decodeLengthInt(reader.peek())) |result| {
            try reader.skip(result.bytes_read);
            this.catalog = try reader.read(@intCast(result.value));
        } else return error.InvalidColumnDefinition;

        if (decodeLengthInt(reader.peek())) |result| {
            try reader.skip(result.bytes_read);
            this.schema = try reader.read(@intCast(result.value));
        } else return error.InvalidColumnDefinition;

        if (decodeLengthInt(reader.peek())) |result| {
            try reader.skip(result.bytes_read);
            this.table = try reader.read(@intCast(result.value));
        } else return error.InvalidColumnDefinition;

        if (decodeLengthInt(reader.peek())) |result| {
            try reader.skip(result.bytes_read);
            this.org_table = try reader.read(@intCast(result.value));
        } else return error.InvalidColumnDefinition;

        if (decodeLengthInt(reader.peek())) |result| {
            try reader.skip(result.bytes_read);
            this.name = try reader.read(@intCast(result.value));
        } else return error.InvalidColumnDefinition;

        if (decodeLengthInt(reader.peek())) |result| {
            try reader.skip(result.bytes_read);
            this.org_name = try reader.read(@intCast(result.value));
        } else return error.InvalidColumnDefinition;

        // Fixed length fields
        const next_length = try reader.int(u8);
        if (next_length != 0x0c) return error.InvalidColumnDefinition;

        this.character_set = try reader.int(u16);
        this.column_length = try reader.int(u32);
        this.column_type = @enumFromInt(try reader.int(u8));
        this.flags = ColumnFlags.fromInt(try reader.int(u16));
        this.decimals = try reader.int(u8);

        // Skip filler
        try reader.skip(2);
    }

    pub const decode = decoderWrap(ColumnDefinition41, decodeInternal).decode;
};

// Text result row
pub const TextResultRow = struct {
    values: []Data = &[_]Data{},
    columns: []const ColumnDefinition41,

    pub fn deinit(this: *TextResultRow) void {
        for (this.values) |*value| {
            value.deinit();
        }
        bun.default_allocator.free(this.values);
    }

    pub fn decodeInternal(this: *TextResultRow, comptime Context: type, reader: NewReader(Context)) !void {
        const values = try bun.default_allocator.alloc(Data, this.columns.len);
        errdefer {
            for (values) |*value| {
                value.deinit();
            }
            bun.default_allocator.free(values);
        }

        for (values) |*value| {
            if (decodeLengthInt(reader.peek())) |result| {
                try reader.skip(result.bytes_read);
                if (result.value == 0xfb) { // NULL value
                    value.* = .{ .empty = {} };
                } else {
                    value.* = try reader.read(@intCast(result.value));
                }
            } else {
                return error.InvalidResultRow;
            }
        }

        this.values = values;
    }

    pub const decode = decoderWrap(TextResultRow, decodeInternal).decode;
};

// Binary result row
pub const BinaryResultRow = struct {
    values: []Value = &[_]Value{},
    columns: []const ColumnDefinition41,
    pub fn deinit(this: *BinaryResultRow) void {
        for (this.values) |*value| {
            value.deinit();
        }
        bun.default_allocator.free(this.values);
    }

    pub fn decodeInternal(this: *BinaryResultRow, comptime Context: type, reader: NewReader(Context)) !void {
        // Header
        const header = try reader.int(u8);
        if (header != 0) return error.InvalidBinaryRow;

        // Null bitmap
        const bitmap_bytes = (this.columns.len + 7 + 2) / 8;
        var null_bitmap = try reader.read(bitmap_bytes);
        defer null_bitmap.deinit();

        const values = try bun.default_allocator.alloc(Value, this.columns.len);
        errdefer {
            for (values) |*value| {
                value.deinit();
            }
            bun.default_allocator.free(values);
        }

        // Skip first 2 bits of null bitmap (reserved)
        const bitmap_offset: usize = 2;

        for (values, 0..) |*value, i| {
            const byte_pos = (bitmap_offset + i) >> 3;
            const bit_pos = @as(u3, @truncate((bitmap_offset + i) & 7));
            const is_null = (null_bitmap.slice()[byte_pos] & (@as(u8, 1) << bit_pos)) != 0;

            if (is_null) {
                value.* = .{ .empty = {} };
                continue;
            }

            const column = this.columns[i];
            value.* = try decodeBinaryValue(column.column_type, Context, reader);
        }

        this.values = values;
    }

    pub const decode = decoderWrap(BinaryResultRow, decodeInternal).decode;
};

fn decodeBinaryValue(field_type: types.FieldType, comptime Context: type, reader: NewReader(Context)) !mysql.types.Value {
    return switch (field_type) {
        .MYSQL_TYPE_TINY => blk: {
            const val = try reader.byte();
            break :blk Value{ .bool = val[0] != 0 };
        },
        .MYSQL_TYPE_SHORT => blk: {
            const val = try reader.int(i16);
            break :blk Value{ .short = val };
        },
        .MYSQL_TYPE_LONG => blk: {
            const val = try reader.int(i32);
            break :blk Value{ .int = val };
        },
        .MYSQL_TYPE_FLOAT => blk: {
            const val = try reader.read(4);
            break :blk Value{ .float = @bitCast(val) };
        },
        .MYSQL_TYPE_DOUBLE => blk: {
            const val = try reader.read(8);
            break :blk Value{ .double = @bitCast(val) };
        },
        .MYSQL_TYPE_LONGLONG => blk: {
            const val = try reader.read(8);
            break :blk Value{ .long = @bitCast(val) };
        },
        .MYSQL_TYPE_TIME => switch (try reader.byte()) {
            0 => Value{ .null = .{} },
            8, 12 => |l| Value{ .time = try Value.Time.fromBinary(reader.read(l)) },
            else => return error.InvalidBinaryValue,
        },
        .MYSQL_TYPE_DATE => switch (try reader.byte()) {
            0 => Value{ .null = .{} },
            4 => Value{ .date = try Value.DateTime.fromBinary(reader.read(4)) },
            else => error.InvalidBinaryValue,
        },
        .MYSQL_TYPE_DATETIME => switch (try reader.byte()) {
            0 => Value{ .null = .{} },
            11, 7, 4 => |l| Value{ .date = try Value.DateTime.fromBinary(reader.read(l)) },
            else => error.InvalidBinaryValue,
        },
        .MYSQL_TYPE_TIMESTAMP => switch (try reader.byte()) {
            0 => Value{ .null = .{} },
            4, 7 => |l| Value{ .timestamp = try Value.Timestamp.fromBinary(reader.read(l)) },
            else => error.InvalidBinaryValue,
        },
        .MYSQL_TYPE_TINY_BLOB,
        .MYSQL_TYPE_MEDIUM_BLOB,
        .MYSQL_TYPE_LONG_BLOB,
        .MYSQL_TYPE_BLOB,
        .MYSQL_TYPE_STRING,
        .MYSQL_TYPE_VARCHAR,
        .MYSQL_TYPE_VAR_STRING,
        .MYSQL_TYPE_JSON,
        => blk: {
            if (decodeLengthInt(reader.peek())) |result| {
                try reader.skip(result.bytes_read);
                const val = try reader.read(@intCast(result.value));
                break :blk val;
            } else return error.InvalidBinaryValue;
        },
        else => return error.UnsupportedColumnType,
    };
}

// Result set header packet
pub const ResultSetHeader = struct {
    field_count: u64,
    extra: ?u64 = null,

    pub fn decodeInternal(this: *ResultSetHeader, comptime Context: type, reader: NewReader(Context)) !void {
        // Field count (length encoded integer)
        if (decodeLengthInt(reader.peek())) |result| {
            this.field_count = result.value;
            try reader.skip(result.bytes_read);
        } else {
            return error.InvalidResultSetHeader;
        }

        // Extra (length encoded integer, optional)
        if (reader.peek().len > 0) {
            if (decodeLengthInt(reader.peek())) |result| {
                this.extra = result.value;
                try reader.skip(result.bytes_read);
            }
        }
    }

    pub const decode = decoderWrap(ResultSetHeader, decodeInternal).decode;
};

// EOF packet
pub const EOFPacket = struct {
    header: u8 = 0xfe,
    warnings: u16 = 0,
    status_flags: mysql.StatusFlags = .{},

    pub fn decodeInternal(this: *EOFPacket, comptime Context: type, reader: NewReader(Context)) !void {
        this.header = try reader.int(u8);
        if (this.header != 0xfe) {
            return error.InvalidEOFPacket;
        }

        this.warnings = try reader.int(u16);
        this.status_flags = mysql.StatusFlags.fromInt(try reader.int(u16));
    }

    pub const decode = decoderWrap(EOFPacket, decodeInternal).decode;
};

// Local infile request packet
pub const LocalInfileRequest = struct {
    filename: Data = .{ .empty = {} },

    pub fn deinit(this: *LocalInfileRequest) void {
        this.filename.deinit();
    }

    pub fn decodeInternal(this: *LocalInfileRequest, comptime Context: type, reader: NewReader(Context)) !void {
        this.filename = try reader.readZ();
    }

    pub const decode = decoderWrap(LocalInfileRequest, decodeInternal).decode;
};

// Local infile response packet
pub const LocalInfileResponse = struct {
    data: Data = .{ .empty = {} },

    pub fn deinit(this: *LocalInfileResponse) void {
        this.data.deinit();
    }

    pub fn writeInternal(this: *const LocalInfileResponse, comptime Context: type, writer: NewWriter(Context)) !void {
        try writer.write(this.data.slice());
    }

    pub const write = writeWrap(LocalInfileResponse, writeInternal).write;
};

// Auth switch request packet
pub const AuthSwitchRequest = struct {
    header: u8 = 0xfe,
    plugin_name: Data = .{ .empty = {} },
    plugin_data: Data = .{ .empty = {} },

    pub fn deinit(this: *AuthSwitchRequest) void {
        this.plugin_name.deinit();
        this.plugin_data.deinit();
    }

    pub fn decodeInternal(this: *AuthSwitchRequest, comptime Context: type, reader: NewReader(Context)) !void {
        this.header = try reader.int(u8);
        if (this.header != 0xfe) {
            return error.InvalidAuthSwitchRequest;
        }

        this.plugin_name = try reader.readZ();
        this.plugin_data = try reader.readZ();
    }

    pub const decode = decoderWrap(AuthSwitchRequest, decodeInternal).decode;
};

// Auth switch response packet
pub const AuthSwitchResponse = struct {
    auth_response: Data = .{ .empty = {} },

    pub fn deinit(this: *AuthSwitchResponse) void {
        this.auth_response.deinit();
    }

    pub fn writeInternal(this: *const AuthSwitchResponse, comptime Context: type, writer: NewWriter(Context)) !void {
        try writer.write(this.auth_response.slice());
    }

    pub const write = writeWrap(AuthSwitchResponse, writeInternal).write;
};

// Auth more data packet
pub const AuthMoreData = struct {
    status: u8 = 0x01,
    plugin_data: Data = .{ .empty = {} },

    pub fn deinit(this: *AuthMoreData) void {
        this.plugin_data.deinit();
    }

    pub fn decodeInternal(this: *AuthMoreData, comptime Context: type, reader: NewReader(Context)) !void {
        this.status = try reader.int(u8);
        if (this.status != 0x01) {
            return error.InvalidAuthMoreData;
        }

        // Read remaining data as plugin data
        const remaining = reader.peek();
        if (remaining.len > 0) {
            this.plugin_data = try reader.read(remaining.len);
        }
    }

    pub const decode = decoderWrap(AuthMoreData, decodeInternal).decode;
};

// Statement close packet
pub const StmtClosePacket = struct {
    command: CommandType = .COM_STMT_CLOSE,
    statement_id: u32,

    pub fn writeInternal(this: *const StmtClosePacket, comptime Context: type, writer: NewWriter(Context)) !void {
        try writer.int1(@intFromEnum(this.command));
        try writer.int4(this.statement_id);
    }

    pub const write = writeWrap(StmtClosePacket, writeInternal).write;
};

// Statement reset packet
pub const StmtResetPacket = struct {
    command: CommandType = .COM_STMT_RESET,
    statement_id: u32,

    pub fn writeInternal(this: *const StmtResetPacket, comptime Context: type, writer: NewWriter(Context)) !void {
        try writer.int1(@intFromEnum(this.command));
        try writer.int4(this.statement_id);
    }

    pub const write = writeWrap(StmtResetPacket, writeInternal).write;
};

// Authentication methods
pub const Auth = struct {
    pub const mysql_native_password = struct {
        pub fn scramble(password: []const u8, nonce: []const u8) ![20]u8 {
            // SHA1( password ) XOR SHA1( nonce + SHA1( SHA1( password ) ) ) )
            var stage1 = [_]u8{0} ** 20;
            var stage2 = [_]u8{0} ** 20;
            var stage3 = [_]u8{0} ** 20;
            var result: [20]u8 = [_]u8{0} ** 20;

            // Stage 1: SHA1(password)
            bun.sha.SHA1.hash(password, &stage1, JSC.VirtualMachine.get().rareData().boringEngine());

            // Stage 2: SHA1(SHA1(password))
            bun.sha.SHA1.hash(&stage1, &stage2, JSC.VirtualMachine.get().rareData().boringEngine());

            // Stage 3: SHA1(nonce + SHA1(SHA1(password)))
            var combined = try bun.default_allocator.alloc(u8, nonce.len + stage2.len);
            defer bun.default_allocator.free(combined);
            @memcpy(combined[0..nonce.len], nonce);
            @memcpy(combined[nonce.len..], &stage2);
            bun.sha.SHA1.hash(combined, &stage3, JSC.VirtualMachine.get().rareData().boringEngine());

            // Final: stage1 XOR stage3
            for (0..20) |i| {
                result[i] = stage1[i] ^ stage3[i];
            }

            return result;
        }
    };

    pub const caching_sha2_password = struct {
        pub fn scramble(password: []const u8, nonce: []const u8) ![32]u8 {
            // XOR(SHA256(password), SHA256(SHA256(SHA256(password)), nonce))
            var digest1 = [_]u8{0} ** 32;
            var digest2 = [_]u8{0} ** 32;
            var digest3 = [_]u8{0} ** 32;
            var result: [32]u8 = [_]u8{0} ** 32;

            // SHA256(password)
            bun.sha.SHA256.hash(password, &digest1, JSC.VirtualMachine.get().rareData().boringEngine());

            // SHA256(SHA256(password))
            bun.sha.SHA256.hash(&digest1, &digest2, JSC.VirtualMachine.get().rareData().boringEngine());

            // SHA256(SHA256(SHA256(password)) + nonce)
            var combined = try bun.default_allocator.alloc(u8, nonce.len + digest2.len);
            defer bun.default_allocator.free(combined);
            @memcpy(combined[0..nonce.len], nonce);
            @memcpy(combined[nonce.len..], &digest2);
            bun.sha.SHA256.hash(combined, &digest3, JSC.VirtualMachine.get().rareData().boringEngine());

            // XOR(SHA256(password), digest3)
            for (0..32) |i| {
                result[i] = digest1[i] ^ digest3[i];
            }

            return result;
        }

        pub const FastAuthStatus = enum(u8) {
            success = 0x03,
            fail = 0x04,
            full_auth = 0x02,
        };

        pub const Response = struct {
            status: FastAuthStatus,
            data: Data = .{ .empty = {} },

            pub fn deinit(this: *Response) void {
                this.data.deinit();
            }

            pub fn decodeInternal(this: *Response, comptime Context: type, reader: NewReader(Context)) !void {
                this.status = @enumFromInt(try reader.int(u8));

                // Read remaining data if any
                const remaining = reader.peek();
                if (remaining.len > 0) {
                    this.data = try reader.read(remaining.len);
                }
            }

            pub const decode = decoderWrap(Response, decodeInternal).decode;
        };

        pub const PublicKeyRequest = struct {
            pub fn writeInternal(this: *const PublicKeyRequest, comptime Context: type, writer: NewWriter(Context)) !void {
                _ = this;
                try writer.int1(0x02); // Request public key
            }

            pub const write = writeWrap(PublicKeyRequest, writeInternal).write;
        };

        pub const EncryptedPassword = struct {
            password: []const u8,
            public_key: []const u8,
            nonce: []const u8,

            pub fn writeInternal(this: *const EncryptedPassword, comptime Context: type, writer: NewWriter(Context)) !void {
                var stack = std.heap.stackFallback(4096, bun.default_allocator);
                const allocator = stack.get();
                const encrypted = try encryptPassword(allocator, this.password, this.public_key, this.nonce);
                defer allocator.free(encrypted);
                try writer.write(encrypted);
            }

            pub const write = writeWrap(EncryptedPassword, writeInternal).write;

            fn encryptPassword(allocator: std.mem.Allocator, password: []const u8, public_key: []const u8, nonce: []const u8) ![]u8 {
                _ = allocator; // autofix
                _ = password; // autofix
                _ = public_key; // autofix
                _ = nonce; // autofix
                bun.todoPanic(@src(), "Not implemented", .{});
                // XOR the password with the nonce
                // var xored = try allocator.alloc(u8, password.len);
                // defer allocator.free(xored);

                // for (password, 0..) |c, i| {
                //     xored[i] = c ^ nonce[i % nonce.len];
                // }

                // // // Load the public key
                // // const key = try BoringSSL.PKey.fromPEM(public_key);
                // // defer key.deinit();

                // // // Encrypt with RSA
                // // const out = try allocator.alloc(u8, key.size());
                // // errdefer allocator.free(out);

                // // const written = try key.encrypt(out, xored, .PKCS1_OAEP);

                // const written
                // // if (written != out.len) {
                //     return error.EncryptionFailed;
                // }

                // return out;
            }
        };
    };
};

// Result set packet types
pub const ResultSet = struct {
    pub const Header = struct {
        field_count: u64,
        extra: ?u64 = null,

        pub fn decodeInternal(this: *Header, comptime Context: type, reader: NewReader(Context)) !void {
            // Field count (length encoded integer)
            if (decodeLengthInt(reader.peek())) |result| {
                this.field_count = result.value;
                try reader.skip(result.bytes_read);
            } else {
                return error.InvalidResultSetHeader;
            }

            // Extra (length encoded integer, optional)
            if (reader.peek().len > 0) {
                if (decodeLengthInt(reader.peek())) |result| {
                    this.extra = result.value;
                    try reader.skip(result.bytes_read);
                }
            }
        }

        pub const decode = decoderWrap(Header, decodeInternal).decode;
    };

    pub const Row = struct {
        values: []Value = &[_]Value{},
        columns: []const ColumnDefinition41,
        binary: bool = false,

        pub fn deinit(this: *Row) void {
            for (this.values) |*value| {
                value.deinit();
            }
            bun.default_allocator.free(this.values);
        }

        pub fn decodeInternal(this: *Row, comptime Context: type, reader: NewReader(Context)) !void {
            if (this.binary) {
                try this.decodeBinary(Context, reader);
            } else {
                try this.decodeText(Context, reader);
            }
        }

        fn decodeText(this: *Row, comptime Context: type, reader: NewReader(Context)) !void {
            const values = try bun.default_allocator.alloc(Value, this.columns.len);
            errdefer {
                for (values) |*value| {
                    value.deinit();
                }
                bun.default_allocator.free(values);
            }

            for (values) |*value| {
                if (decodeLengthInt(reader.peek())) |result| {
                    try reader.skip(result.bytes_read);
                    if (result.value == 0xfb) { // NULL value
                        value.* = .{ .empty = {} };
                    } else {
                        value.* = try reader.read(@intCast(result.value));
                    }
                } else {
                    return error.InvalidResultRow;
                }
            }

            this.values = values;
        }

        fn decodeBinary(this: *Row, comptime Context: type, reader: NewReader(Context)) !void {
            // Header
            const header = try reader.int(u8);
            if (header != 0) return error.InvalidBinaryRow;

            // Null bitmap
            const bitmap_bytes = (this.columns.len + 7 + 2) / 8;
            var null_bitmap = try reader.read(bitmap_bytes);
            defer null_bitmap.deinit();

            const values = try bun.default_allocator.alloc(Value, this.columns.len);
            errdefer {
                for (values) |*value| {
                    value.deinit();
                }
                bun.default_allocator.free(values);
            }

            // Skip first 2 bits of null bitmap (reserved)
            const bitmap_offset: usize = 2;

            for (values, 0..) |*value, i| {
                const byte_pos = (bitmap_offset + i) >> 3;
                const bit_pos = @as(u3, @truncate((bitmap_offset + i) & 7));
                const is_null = (null_bitmap.slice()[byte_pos] & (@as(u8, 1) << bit_pos)) != 0;

                if (is_null) {
                    value.* = .{ .empty = {} };
                    continue;
                }

                const column = this.columns[i];
                value.* = try decodeBinaryValue(column.column_type, Context, reader);
            }

            this.values = values;
        }

        pub const decode = decoderWrap(Row, decodeInternal).decode;
    };
};

// Prepared statement packets
pub const PreparedStatement = struct {
    pub const Prepare = struct {
        command: CommandType = .COM_STMT_PREPARE,
        query: Data,

        pub fn deinit(this: *Prepare) void {
            this.query.deinit();
        }

        pub fn writeInternal(this: *const Prepare, comptime Context: type, writer: NewWriter(Context)) !void {
            try writer.int1(@intFromEnum(this.command));
            try writer.write(this.query.slice());
        }

        pub const write = writeWrap(Prepare, writeInternal).write;
    };

    pub const PrepareOK = struct {
        status: u8 = 0,
        statement_id: u32,
        num_columns: u16,
        num_params: u16,
        warning_count: u16,

        pub fn decodeInternal(this: *PrepareOK, comptime Context: type, reader: NewReader(Context)) !void {
            this.status = try reader.int(u8);
            if (this.status != 0) {
                return error.InvalidPrepareOKPacket;
            }

            this.statement_id = try reader.int(u32);
            this.num_columns = try reader.int(u16);
            this.num_params = try reader.int(u16);
            _ = try reader.int(u8); // reserved_1
            this.warning_count = try reader.int(u16);
        }

        pub const decode = decoderWrap(PrepareOK, decodeInternal).decode;
    };

    pub const Execute = struct {
        command: CommandType = .COM_STMT_EXECUTE,
        statement_id: u32,
        flags: u8 = 0,
        iteration_count: u32 = 1,
        new_params_bind_flag: bool = true,
        params: []const Data = &[_]Data{},
        param_types: []const types.FieldType = &[_]types.FieldType{},

        pub fn deinit(this: *Execute) void {
            for (this.params) |*param| {
                param.deinit();
            }
        }

        pub fn writeInternal(this: *const Execute, comptime Context: type, writer: NewWriter(Context)) !void {
            try writer.int1(@intFromEnum(this.command));
            try writer.int4(this.statement_id);
            try writer.int1(this.flags);
            try writer.int4(this.iteration_count);

            if (this.params.len > 0) {
                var null_bitmap_buf: [32]u8 = undefined;
                const bitmap_bytes = (this.params.len + 7) / 8;
                const null_bitmap = null_bitmap_buf[0..bitmap_bytes];
                @memset(null_bitmap, 0);

                for (this.params, 0..) |param, i| {
                    if (param == .empty) {
                        null_bitmap[i >> 3] |= @as(u8, 1) << @as(u3, @truncate(i & 7));
                    }
                }

                try writer.write(null_bitmap);

                // Write new params bind flag
                try writer.int1(@intFromBool(this.new_params_bind_flag));

                if (this.new_params_bind_flag) {
                    // Write parameter types
                    for (this.param_types) |param_type| {
                        try writer.int1(@intFromEnum(param_type));
                        try writer.int1(1); // unsigned flag, always true for now
                    }
                }

                // Write parameter values
                for (this.params, this.param_types) |param, param_type| {
                    if (param == .empty) continue;

                    const value = param.slice();
                    if (param_type.isBinaryFormatSupported()) {
                        try writer.write(value);
                    } else {
                        try writer.write(encodeLengthInt(value.len));
                        try writer.write(value);
                    }
                }
            }
        }

        pub const write = writeWrap(Execute, writeInternal).write;
    };

    pub const Close = struct {
        command: CommandType = .COM_STMT_CLOSE,
        statement_id: u32,

        pub fn writeInternal(this: *const Close, comptime Context: type, writer: NewWriter(Context)) !void {
            try writer.int1(@intFromEnum(this.command));
            try writer.int4(this.statement_id);
        }

        pub const write = writeWrap(Close, writeInternal).write;
    };

    pub const Reset = struct {
        command: CommandType = .COM_STMT_RESET,
        statement_id: u32,

        pub fn writeInternal(this: *const Reset, comptime Context: type, writer: NewWriter(Context)) !void {
            try writer.int1(@intFromEnum(this.command));
            try writer.int4(this.statement_id);
        }

        pub const write = writeWrap(Reset, writeInternal).write;
    };
};