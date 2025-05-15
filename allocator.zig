const std = @import("std");
const builtin = @import("builtin");

/// maximum (most strict) alignment requirement for any C scalar type on this target
const max_align_t: u16 = builtin.target.cTypeAlignment(.longdouble);

comptime {
    std.debug.assert(max_align_t == 16);
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

// Use Zig's GeneralPurposeAllocator (or another allocator of your choice)
var gpa: std.heap.DebugAllocator(.{
    .thread_safe = true,
    .safety = true,
    .stack_trace_frames = 16,
    // SIGSEGV debugging
    .never_unmap = true,
    .retain_metadata = true,
}) = .init;
const allocator = ZigCAllocator.init(gpa.allocator());

// https://github.com/zig-gamedev/zstbi/blob/094c4bba5cdbec167d3f6aaa98cccccd5c99145f/src/zstbi.zig#L388
// https://gist.github.com/pfgithub/65c13d7dc889a4b2ba25131994be0d20
// std.heap.c_allocator
// https://gencmurat.com/en/posts/using-allocators-in-zig/
// https://embeddedartistry.com/blog/2017/02/22/generating-aligned-memory/
// https://developer.ibm.com/articles/pa-dalign/

const ZigCAllocator = struct {
    backing_allocator: std.mem.Allocator,
    const Pointer = usize;

    // Pack offset to original ptr + total size into a single usize
    const MetaData = packed struct(Pointer) {
        offset_to_original: u6, // 6 bits: max 63 byte offset (supports 64-byte alignment)
        total_size: u58, // 58 bits: 256PB max allocation

        fn init(alloc_offset_to_original: Pointer, alloc_total_size: usize) MetaData {
            return .{
                .offset_to_original = @intCast(alloc_offset_to_original),
                .total_size = @intCast(alloc_total_size),
            };
        }

        fn allocptr(self: *const MetaData) [*]u8 {
            return @as([*]u8, @ptrCast(@constCast(self))) - self.offset_to_original;
        }

        fn allocsize(self: *const MetaData) usize {
            return @intCast(self.total_size);
        }
    };

    pub fn init(backing_allocator: std.mem.Allocator) ZigCAllocator {
        return .{ .backing_allocator = backing_allocator };
    }

    inline fn addHeader(original_addr: Pointer, meta_ptr: [*]u8, size: usize) void {
        const header: *MetaData = @alignCast(@ptrCast(meta_ptr));
        header.* = MetaData.init(@intFromPtr(meta_ptr) - original_addr, size);
    }

    // Helper to get header from user pointer
    inline fn getHeader(ptr: *anyopaque) *MetaData {
        const bytes_ptr: [*]u8 = @ptrCast(ptr);
        return @alignCast(@ptrCast(bytes_ptr - @sizeOf(MetaData)));
    }

    fn alloc(self: ZigCAllocator, comptime alignment: ?std.mem.Alignment, size: usize) ?*anyopaque {
        const full_size = size + @sizeOf(MetaData);
        const aligned_ptr = ptr: {
            if (alignment) |alignment_| {
                break :ptr switch (alignment_) {
                    .@"16", .@"32", .@"64" => |alignment_value| self.backing_allocator.alignedAlloc(
                        u8,
                        alignment_value,
                        full_size,
                    ) catch return null,
                    else => unreachable,
                };
            } else {
                break :ptr self.backing_allocator.alignedAlloc(u8, .fromByteUnits(max_align_t), full_size) catch return null;
            }
        };
        addHeader(@intFromPtr(aligned_ptr.ptr), aligned_ptr.ptr, full_size);
        return @ptrCast(aligned_ptr.ptr + @sizeOf(MetaData));
    }

    fn posixMemAlign(self: ZigCAllocator, memptr: *?*anyopaque, comptime alignment: std.mem.Alignment, size: usize) u32 {
        if (size == 0) {
            memptr.* = null;
            return 0;
        }
        std.debug.print("Size {}\n", .{size});
        const alignment_bytes = alignment.toByteUnits();
        // alignments must be a power of two and multiples of sizeof(void *)
        if (!std.math.isPowerOfTwo(alignment_bytes) or alignment_bytes % @sizeOf(*anyopaque) != 0) {
            return @intCast(@intFromEnum(std.posix.system.E.INVAL));
        }
        memptr.* = self.alloc(alignment, size) orelse return @intCast(@intFromEnum(std.posix.system.E.NOMEM));

        // // + alignment - 1 padding for the worse case where returned alloc
        // // address is just 1 byte before the desired alignment boundary so we
        // // can shift the pointer forward to meet the alignment requirement
        // const max_padding = alignment_bytes - 1;
        // const total_size = @sizeOf(usize) + size + max_padding;
        // // Overallocate to account for alignment padding and store the original
        // // alloced()'ed pointer before the aligned address.
        // const unaligned_ptr = self.backing_allocator.alloc(u8, total_size) catch return @intCast(@intFromEnum(std.posix.system.E.NOMEM));
        // const unaligned_addr = @intFromPtr(unaligned_ptr.ptr);
        // // Calculate aligned address after metadata
        // const aligned_addr = std.mem.alignForward(usize, unaligned_addr + @sizeOf(usize), alignment_bytes);

        // std.debug.assert(aligned_addr >= unaligned_addr);

        // // distance from unaligned address to aligned address
        // const distance_to_aligned = (aligned_addr - unaligned_addr);
        // const aligned_ptr = unaligned_ptr.ptr + distance_to_aligned;

        // const metadata_addr = aligned_addr - @sizeOf(MetaData);
        // std.debug.assert(metadata_addr >= unaligned_addr);

        // // distance from meta data address to algined address
        // const distance_to_meta = metadata_addr - unaligned_addr;
        // const meta_ptr = unaligned_ptr.ptr + distance_to_meta;
        // addHeader(unaligned_addr, meta_ptr, total_size);

        // memptr.* = @ptrCast(aligned_ptr);

        return 0; // Success
    }

    fn alignedAlloc(self: ZigCAllocator, comptime alignment: std.mem.Alignment, size: usize) ?*anyopaque {
        var memptr: ?*anyopaque = undefined;
        const status = self.posixMemAlign(&memptr, alignment, size);
        switch (status) {
            @intFromEnum(std.posix.system.E.INVAL) | @intFromEnum(std.posix.system.E.NOMEM) => return null,
            else => return memptr,
        }
    }

    fn free(self: ZigCAllocator, ptr: ?*anyopaque) void {
        if (ptr) |p| {
            const metadata = getHeader(p);

            const original_ptr = metadata.allocptr();
            const full_slice: []align(max_align_t) u8 = @alignCast(original_ptr[0..metadata.allocsize()]);

            self.backing_allocator.free(full_slice);
        }
    }

    fn freeAligned(self: ZigCAllocator, ptr: ?*anyopaque, comptime alignment: std.mem.Alignment) void {
        if (ptr) |p| {
            const metadata = getHeader(p);
            const original_ptr = metadata.allocptr();
            const full_slice = slice: switch (alignment) {
                .@"16", .@"32", .@"64" => |align_bytes| {
                    const slice: []align(align_bytes.toByteUnits()) u8 = @alignCast(original_ptr[0..metadata.allocsize()]);
                    break :slice slice;
                },
                else => {
                    const slice: []align(max_align_t) u8 = @alignCast(original_ptr[0..metadata.allocsize()]);
                    break :slice slice;
                },
            };

            self.backing_allocator.free(full_slice);
        }
    }

    fn realloc(self: ZigCAllocator, ptr: ?*anyopaque, new_size: usize) ?*anyopaque {
        if (ptr == null) return self.alloc(null, new_size);
        const metadata = getHeader(ptr.?);

        const full_old: []align(max_align_t) u8 = @alignCast(metadata.allocptr()[0..metadata.allocsize()]);

        const new_full_size = new_size + @sizeOf(MetaData);
        const full_new = self.backing_allocator.realloc(full_old, new_full_size) catch return null;

        addHeader(@intFromPtr(full_new.ptr), full_new.ptr, new_full_size);
        return @ptrCast(full_new.ptr + @sizeOf(MetaData));
    }
};

// Export C-compatible allocator functions
export fn malloc(size: usize) ?*anyopaque {
    std.debug.print("malloc of size {}\n", .{size});
    return allocator.alloc(null, size);
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

export fn posix_memalign(memptr: *?*anyopaque, alignment: usize, size: usize) u32 {
    std.debug.print("posix_memalign with alignment {} and size {}\n", .{ alignment, size });
    return switch (alignment) {
        inline 16, 32, 64 => |bytes| allocator.posixMemAlign(memptr, .fromByteUnits(bytes), size),
        else => allocator.posixMemAlign(memptr, .fromByteUnits(max_align_t), size),
    };
}

export fn aligned_alloc(alignment: usize, size: usize) ?*anyopaque {
    std.debug.print("aligned_alloc with alignment {} and size {}\n", .{ alignment, size });
    return switch (alignment) {
        inline 16, 32, 64 => |bytes| allocator.alignedAlloc(.fromByteUnits(bytes), size),
        else => allocator.alignedAlloc(.fromByteUnits(max_align_t), size),
    };
}

export fn aligned_free(
    ptr: ?*anyopaque,
    alignment: usize,
) void {
    std.debug.print("free aligned {*}\n", .{ptr});
    if (ptr) |p| {
        switch (alignment) {
            inline 16, 32, 64 => |bytes| allocator.freeAligned(p, .fromByteUnits(bytes)),
            else => allocator.freeAligned(p, .fromByteUnits(max_align_t)),
        }
    }
}

export fn free(ptr: ?*anyopaque) void {
    std.debug.print("free {*}\n", .{ptr});
    if (ptr) |p| {
        allocator.free(p);
    }
}

// https://jcarin.com/posts/memory-leak/
// https://github.com/bminor/glibc/blob/06caf53adfae0c93062edd62f83eed16ab5cec0b/malloc/set-freeres.c#L123
// Glibc doesn't free some resources that are used through out the lifetime of
// the library as an optimization since these resources would eventually be
// freed by the kernel but this leads to leaks reported by valgrind and Zig's
// debug allocator so call this to cleanup if `checkLeaks` is called
/// Free all glibc allocated resources.
extern fn __libc_freeres() callconv(.C) void;

export fn checkLeaks() void {
    if (builtin.target.isGnuLibC()) {
        __libc_freeres();
    }
    switch (gpa.deinit()) {
        .leak => {
            std.debug.print("Leaks detected\n", .{});
            std.process.exit(7);
        },
        .ok => std.debug.print("No leaks detected. Happy Programming\n", .{}),
    }
}

pub extern fn main() c_int;
