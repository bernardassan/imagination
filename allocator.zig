const std = @import("std");
const builtin = @import("builtin");

/// maximum (most strict) alignment requirement for any C scalar type on this target
var max_align_t: u16 = builtin.target.cTypeAlignment(.longdouble);

comptime {
    std.debug.assert(max_align_t == 16);
}
// Use Zig's GeneralPurposeAllocator (or another allocator of your choice)
var gpa: std.heap.DebugAllocator(.{
    .thread_safe = true,
    .safety = true,
    .stack_trace_frames = 16,
}) = .init;
const allocator = ZigCAllocator.init(gpa.allocator());

// https://github.com/zig-gamedev/zstbi/blob/094c4bba5cdbec167d3f6aaa98cccccd5c99145f/src/zstbi.zig#L388
// https://gist.github.com/pfgithub/65c13d7dc889a4b2ba25131994be0d20
// std.heap.c_allocator
// https://gencmurat.com/en/posts/using-allocators-in-zig/
//

const ZigCAllocator = struct {
    const Pointer = usize;
    backing_allocator: std.mem.Allocator,
    metadata: std.AutoArrayHashMapUnmanaged(Pointer, MetaData) = .{},

    // Pack size + alignment into a single usize
    const MetaData = extern struct {
        packed_value: usize,

        // Constants for bit manipulation
        const ALIGNMENT_BITS = 8; // Use 8 bits for alignment (theorotically supports up to 255 alignment values)
        const SIZE_BITS = @bitSizeOf(usize) - ALIGNMENT_BITS; // 56 bits for size
        const SIZE_MASK = (1 << SIZE_BITS) - 1; // Mask to extract size

        // Initialize MetaData from size + alignment
        pub fn init(alloc_size: usize, alloc_alignment: u29) MetaData {
            std.debug.assert(std.math.isPowerOfTwo(alloc_alignment)); // Alignment must be power-of-two
            const alignment_log2 = std.math.log2_int(usize, alignment);
            return .{
                .packed_value = (alignment_log2 << SIZE_BITS) | (alloc_size & SIZE_MASK),
            };
        }

        // Extract size (lower 56 bits)
        pub fn size(self: MetaData) usize {
            return self.packed_value & SIZE_MASK;
        }

        // Extract alignment (upper 8 bits as 2^N)
        pub fn alignment(self: MetaData) usize {
            const alignment_log2 = self.packed_value >> SIZE_BITS;
            return @as(usize, 1) << @as(u8, @truncate(alignment_log2)); // Prevent overflow
        }
    };

    pub fn init(backing_allocator: std.mem.Allocator) ZigCAllocator {
        return .{ .backing_zig_allocator = backing_allocator };
    }

    inline fn addHeader(_: ZigCAllocator, ptr: [*]u8, size: usize, alignment: u29) void {
        const header: *MetaData = @ptrCast(@alignCast(ptr));
        header.* = MetaData.init(size, alignment);
    }

    // Helper to get header from user pointer
    inline fn getHeader(ptr: *anyopaque) *MetaData {
        const bytes_ptr: [*]u8 = @ptrCast(ptr);
        return @alignCast(@ptrCast(bytes_ptr - @sizeOf(MetaData)));
    }

    fn alloc(self: ZigCAllocator, comptime alignment: ?u29, size: usize) ?*anyopaque {
        const full_size = size + @sizeOf(MetaData);
        const aligned_ptr = self.backing_allocator.alignedAlloc(u8, alignment orelse max_align_t, full_size) catch return null;
        self.addHeader(aligned_ptr.ptr, size, alignment orelse max_align_t);
        return @ptrCast(aligned_ptr.ptr + @sizeOf(MetaData));
    }

    fn posixMemAlign(self: ZigCAllocator, memptr: *?*anyopaque, comptime alignment: u29, size: usize) u32 {
        if (size == 0) {
            memptr.* = null;
            return 0;
        }
        // alignments must be a power of two and multiples of sizeof(void *)
        if (!std.math.isPowerOfTwo(alignment) or alignment % @sizeOf(*anyopaque) == 0) {
            return @intCast(@intFromEnum(std.posix.system.E.INVAL)); // POSIX requires EINVAL for invalid alignment
        }
        memptr.* = self.alloc(alignment, size) orelse return @intCast(@intFromEnum(std.posix.system.E.NOMEM));
        return 0; // Success
    }

    fn alignedAlloc(self: ZigCAllocator, comptime alignment: u29, size: usize) ?*anyopaque {
        var memptr: ?*anyopaque = undefined;
        const status = self.posixMemAlign(&memptr, alignment, size);
        switch (status) {
            @intFromEnum(std.posix.system.E.INVAL) | @intFromEnum(std.posix.system.E.NOMEM) => return null,
            else => return memptr,
        }
    }

    fn free(self: ZigCAllocator, ptr: ?*anyopaque) void {
        if (ptr) |p| {
            const header = getHeader(p);
            const full_slice = @as([]align(header.alignment()) u8, @alignCast(@as([*]u8, @ptrCast(header))[0 .. header.size() + @sizeOf(MetaData)]));
            self.backing_allocator.free(full_slice);
        }
    }

    fn realloc(self: ZigCAllocator, ptr: ?*anyopaque, new_size: usize) ?*anyopaque {
        if (ptr == null) return self.alloc(null, new_size);
        const header = getHeader(ptr.?);
        const old_size = header.size();

        const full_old = @as([]align(header.alignment()) u8, @alignCast(@as([*]u8, @ptrCast(header))[0 .. old_size + @sizeOf(MetaData)]));
        const full_new = self.backing_allocator.realloc(full_old, new_size + @sizeOf(MetaData)) catch return null;

        self.addHeader(full_new.ptr, new_size);
        return @ptrCast(full_new.ptr + @sizeOf(MetaData));
    }
};

// Export C-compatible allocator functions
export fn malloc(size: usize) ?*anyopaque {
    std.debug.print("malloc of size {}\n", .{size});
    return allocator.alloc(null, size);
}

export fn posix_mem_align(memptr: *?*anyopaque, alignment: usize, size: usize) u32 {
    std.debug.print("posix_mem_align with alignment {} and size {}\n", .{ alignment, size });
    return switch (alignment) {
        16 => allocator.posixMemAlign(memptr, 16, size),
        32 => allocator.posixMemAlign(memptr, 32, size),
        64 => allocator.posixMemAlign(memptr, 64, size),
        else => allocator.posixMemAlign(memptr, max_align_t, size),
    };
}

export fn aligned_alloc(alignment: usize, size: usize) ?*anyopaque {
    std.debug.print("aligned_alloc with alignment {} and size {}\n", .{ alignment, size });
    return switch (alignment) {
        16 => allocator.alignedAlloc(16, size),
        32 => allocator.alignedAlloc(32, size),
        64 => allocator.alignedAlloc(64, size),
        else => allocator.alignedAlloc(max_align_t, size),
    };
    // switch (alignment) {
    //     16 | 32 | 64 => |value| max_align_t = value,
    //     else => unreachable,
    // }
    // allocator.alignedAlloc(max_align_t, size);
}

export fn calloc(nmemb: usize, size: usize) ?*anyopaque {
    std.debug.print("calloc {} memb with size {}\n", .{ nmemb, size });
    const total_size = nmemb * size;
    const mem = allocator.alloc(null, total_size);
    @memset(@as([*]u8, @ptrCast(mem))[0..total_size], 0); // Zero-initialize
    return mem;
}

export fn realloc(ptr: ?*anyopaque, new_size: usize) ?*anyopaque {
    std.debug.print("realloc {*} with size {}\n", .{ ptr, new_size });
    return allocator.realloc(ptr, new_size);
}

export fn free(ptr: ?*anyopaque) void {
    std.debug.print("free {*}\n", .{ptr});
    if (ptr) |p| {
        allocator.free(p);
    }
}

export fn checkLeaks() void {
    switch (gpa.deinit()) {
        .leak => std.debug.print("Leaks detected\n", .{}),
        .ok => std.debug.print("No leaks detected. Happy Programming\n", .{}),
    }
}

pub extern fn main() c_int;
