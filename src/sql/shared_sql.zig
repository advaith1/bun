const JSC = bun.JSC;
const bun = @import("root").bun;
const JSValue = JSC.JSValue;

pub const QueryBindingIterator = union(enum) {
    array: JSC.JSArrayIterator,
    objects: ObjectIterator,

    pub fn init(array: JSValue, columns: JSValue, globalObject: *JSC.JSGlobalObject) QueryBindingIterator {
        if (columns.isEmptyOrUndefinedOrNull()) {
            return .{ .array = JSC.JSArrayIterator.init(array, globalObject) };
        }

        return .{
            .objects = .{
                .array = array,
                .columns = columns,
                .globalObject = globalObject,
                .columns_count = columns.getLength(globalObject),
                .array_length = array.getLength(globalObject),
            },
        };
    }

    pub const ObjectIterator = struct {
        array: JSValue,
        columns: JSValue = .zero,
        globalObject: *JSC.JSGlobalObject,
        cell_i: usize = 0,
        row_i: usize = 0,
        current_row: JSC.JSValue = .zero,
        columns_count: usize = 0,
        array_length: usize = 0,
        any_failed: bool = false,

        pub fn next(this: *ObjectIterator) ?JSC.JSValue {
            if (this.row_i >= this.array_length) {
                return null;
            }

            const cell_i = this.cell_i;
            this.cell_i += 1;
            const row_i = this.row_i;

            const globalObject = this.globalObject;

            if (this.current_row == .zero) {
                this.current_row = JSC.JSObject.getIndex(this.array, globalObject, @intCast(row_i));
                if (this.current_row.isEmptyOrUndefinedOrNull()) {
                    if (!globalObject.hasException())
                        globalObject.throw("Expected a row to be returned at index {d}", .{row_i});
                    this.any_failed = true;
                    return null;
                }
            }

            defer {
                if (this.cell_i >= this.columns_count) {
                    this.cell_i = 0;
                    this.current_row = .zero;
                    this.row_i += 1;
                }
            }

            const property = JSC.JSObject.getIndex(this.columns, globalObject, @intCast(cell_i));
            if (property == .zero or property == .undefined) {
                if (!globalObject.hasException())
                    globalObject.throw("Expected a column at index {d} in row {d}", .{ cell_i, row_i });
                this.any_failed = true;
                return null;
            }

            const value = this.current_row.getOwnByValue(globalObject, property);
            if (value == .zero or value == .undefined) {
                if (!globalObject.hasException())
                    globalObject.throw("Expected a value at index {d} in row {d}", .{ cell_i, row_i });
                this.any_failed = true;
                return null;
            }
            return value;
        }
    };

    pub fn next(this: *QueryBindingIterator) ?JSC.JSValue {
        return switch (this.*) {
            .array => |*iter| iter.next(),
            .objects => |*iter| iter.next(),
        };
    }

    pub fn anyFailed(this: *const QueryBindingIterator) bool {
        return switch (this.*) {
            .array => false,
            .objects => |*iter| iter.any_failed,
        };
    }

    pub fn to(this: *QueryBindingIterator, index: u32) void {
        switch (this.*) {
            .array => |*iter| iter.i = index,
            .objects => |*iter| {
                iter.cell_i = index % iter.columns_count;
                iter.row_i = index / iter.columns_count;
                iter.current_row = .zero;
            },
        }
    }

    pub fn reset(this: *QueryBindingIterator) void {
        switch (this.*) {
            .array => |*iter| {
                iter.i = 0;
            },
            .objects => |*iter| {
                iter.cell_i = 0;
                iter.row_i = 0;
                iter.current_row = .zero;
            },
        }
    }
};

// Represents data that can be either owned or temporary
pub const Data = union(enum) {
    owned: bun.ByteList,
    temporary: []const u8,
    empty: void,

    pub fn toOwned(this: @This()) !bun.ByteList {
        return switch (this) {
            .owned => this.owned,
            .temporary => bun.ByteList.init(try bun.default_allocator.dupe(u8, this.temporary)),
            .empty => bun.ByteList.init(&.{}),
        };
    }

    pub fn deinit(this: *@This()) void {
        switch (this.*) {
            .owned => this.owned.deinitWithAllocator(bun.default_allocator),
            .temporary => {},
            .empty => {},
        }
    }

    /// Zero bytes before deinit
    /// Generally, for security reasons.
    pub fn zdeinit(this: *@This()) void {
        switch (this.*) {
            .owned => {

                // Zero bytes before deinit
                @memset(this.owned.slice(), 0);

                this.owned.deinitWithAllocator(bun.default_allocator);
            },
            .temporary => {},
            .empty => {},
        }
    }

    pub fn slice(this: @This()) []const u8 {
        return switch (this) {
            .owned => this.owned.slice(),
            .temporary => this.temporary,
            .empty => "",
        };
    }

    pub fn substring(this: @This(), start_index: usize, end_index: usize) Data {
        return switch (this) {
            .owned => .{ .temporary = this.owned.slice()[start_index..end_index] },
            .temporary => .{ .temporary = this.temporary[start_index..end_index] },
            .empty => .{ .empty = {} },
        };
    }

    pub fn sliceZ(this: @This()) [:0]const u8 {
        return switch (this) {
            .owned => this.owned.slice()[0..this.owned.len :0],
            .temporary => this.temporary[0..this.temporary.len :0],
            .empty => "",
        };
    }
};