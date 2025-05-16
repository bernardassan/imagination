const std = @import("std");
const debug = std.debug;
const builtin = @import("builtin");
const option: std.Options = .{ .log_level = debug };
const log = std.log.scoped(.czalloc);

/// maximum (most strict) alignment requirement for any C scalar type on this target
const max_align_t: u16 = builtin.target.cTypeAlignment(.longdouble);

comptime {
    debug.assert(max_align_t == 16);
    debug.assert(builtin.cpu.arch.endian() == .little);
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

    const Pointer = enum(usize) {
        _,

        fn init(alloc_ptr: [*]u8) Pointer {
            return @enumFromInt(@intFromPtr(alloc_ptr));
        }

        fn toUsize(self: Pointer) usize {
            return @intFromEnum(self);
        }

        fn toPtr(self: Pointer) [*]u8 {
            return @ptrFromInt(@intFromEnum(self));
        }
    };

    const Size = enum(u61) {
        _,
        // max size = 2^61 - 1
        const max_size = 1 << @bitSizeOf(Size);

        fn init(size: usize) Size {
            debug.assert(size < max_size);

            return @enumFromInt(size);
        }

        fn toUsize(self: Size) usize {
            return @intFromEnum(self);
        }
    };

    const Alignment = enum(u3) {
        _,
        // Since we are storing log2(alignment) in a u3, the maximum
        // theoretical alignment value we can represent is determined by the
        // maximum value a u3 can hold (.ie 8) therefore the
        // max_theoretical_alignment = (2^log2_alignment) - 1
        // .ie max_theoretical_alignment = (2^8) - 1
        /// Supports up to 64-byte alignment
        const max_alignment_supported = 64;

        fn init(alloc_alignment: std.mem.Alignment) Alignment {
            const alignment = alloc_alignment.toByteUnits();
            debug.assert(alignment <= max_alignment_supported);
            // equivalent to @ctz(alignment)
            const log_align = std.math.log2_int(usize, alignment);

            return @enumFromInt(log_align);
        }

        fn toAlignment(self: Alignment) std.mem.Alignment {
            // usize from the stored log2 of alignment
            const alignment = @as(usize, 1) << @intFromEnum(self);

            return .fromByteUnits(alignment);
        }
    };

    // Pack alignment + total size into a single usize
    const Metadata = packed struct(usize) {
        alignment: Alignment,
        total_size: Size,

        fn init(alloc_total_size: Size, alloc_alignment: std.mem.Alignment) Metadata {
            return .{
                .alignment = .init(alloc_alignment),
                .total_size = .init(alloc_total_size.toUsize()),
            };
        }

        fn allocPtr(self: *const Metadata) [*]u8 {
            return @ptrCast(@constCast(self));
        }

        fn allocAlign(self: *const Metadata) std.mem.Alignment {
            return self.alignment.toAlignment();
        }

        fn allocSize(self: *const Metadata) usize {
            return self.total_size.toUsize();
        }
    };

    pub fn init(backing_allocator: std.mem.Allocator) ZigCAllocator {
        return .{ .backing_allocator = backing_allocator };
    }

    inline fn addMetadataAndReturnPtr(aligned_addr: Pointer, size: Size, alignment: std.mem.Alignment) ?*anyopaque {
        const aligned_ptr = aligned_addr.toPtr();
        const header: *Metadata = @alignCast(@ptrCast(aligned_ptr));
        header.* = Metadata.init(size, alignment);
        return @ptrCast(aligned_ptr + @sizeOf(Metadata));
    }

    // Helper to get header from user pointer
    inline fn metadata(ptr: *anyopaque) *const Metadata {
        const bytes_ptr: [*]u8 = @ptrCast(ptr);
        return @alignCast(@ptrCast(bytes_ptr - @sizeOf(Metadata)));
    }

    fn alloc(self: ZigCAllocator, comptime alignment: ?std.mem.Alignment, size: usize) ?*anyopaque {
        const full_size = size + @sizeOf(Metadata);
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

        return addMetadataAndReturnPtr(
            .init(aligned_ptr.ptr),
            .init(full_size),
            alignment orelse .fromByteUnits(max_align_t),
        );
    }

    fn posixMemAlign(self: ZigCAllocator, memptr: *?*anyopaque, comptime alignment: std.mem.Alignment, size: usize) u32 {
        if (size == 0) {
            memptr.* = null;
            return 0;
        }
        const alignment_bytes = alignment.toByteUnits();
        // alignments must be a power of two and multiples of sizeof(void *)
        if (!std.math.isPowerOfTwo(alignment_bytes) or alignment_bytes % @sizeOf(*anyopaque) != 0) {
            return @intCast(@intFromEnum(std.posix.system.E.INVAL));
        }

        memptr.* = self.alloc(alignment, size) orelse return @intCast(@intFromEnum(std.posix.system.E.NOMEM));

        return 0; // Success
    }

    fn alignedAlloc(self: ZigCAllocator, comptime alignment: std.mem.Alignment, size: usize) ?*anyopaque {
        var memptr: ?*anyopaque = undefined;
        const status = self.posixMemAlign(&memptr, alignment, size);
        return switch (status) {
            @intFromEnum(std.posix.system.E.INVAL) | @intFromEnum(std.posix.system.E.NOMEM) => null,
            else => memptr,
        };
    }

    fn free(self: ZigCAllocator, ptr: ?*anyopaque) void {
        if (ptr) |p| {
            const metadata_ = metadata(p);
            const original_ptr = metadata_.allocPtr();
            const alignment = metadata_.allocAlign();

            // NOTE: breaking out of switch with `slice` changes alignment of
            // `slice` to 16, figure out why
            switch (alignment) {
                inline .@"16", .@"32", .@"64" => |align_bytes| {
                    const slice: []align(align_bytes.toByteUnits()) u8 = @alignCast(original_ptr[0..metadata_.allocSize()]);
                    return self.backing_allocator.free(slice);
                },
                else => {
                    const slice: []align(max_align_t) u8 = @alignCast(original_ptr[0..metadata_.allocSize()]);
                    return self.backing_allocator.free(slice);
                },
            }
        }
    }

    fn realloc(self: ZigCAllocator, ptr: ?*anyopaque, new_size: usize) ?*anyopaque {
        if (ptr == null) return self.alloc(null, new_size);
        const metadata_ = metadata(ptr.?);

        const full_old: []align(max_align_t) u8 = @alignCast(metadata_.allocPtr()[0..metadata_.allocSize()]);

        const new_full_size = new_size + @sizeOf(Metadata);
        const full_new = self.backing_allocator.realloc(full_old, new_full_size) catch return null;

        return addMetadataAndReturnPtr(
            .init(full_new.ptr),
            .init(new_full_size),
            .fromByteUnits(max_align_t),
        );
    }
};

// Export C-compatible allocator functions
export fn malloc(size: usize) ?*anyopaque {
    log.debug("malloc of size {}", .{size});
    return allocator.alloc(null, size);
}

export fn calloc(nmemb: usize, size: usize) ?*anyopaque {
    log.debug("calloc {} memb with size {}", .{ nmemb, size });
    const total_size = nmemb * size;
    const mem = allocator.alloc(null, total_size);
    // Zero-initialize
    @memset(@as([*]u8, @ptrCast(mem))[0..total_size], 0);
    return mem;
}

export fn realloc(memptr: ?*anyopaque, new_size: usize) ?*anyopaque {
    log.debug("realloc {*} with size {}", .{ memptr, new_size });
    return allocator.realloc(memptr, new_size);
}

export fn posix_memalign(memptr: *?*anyopaque, alignment: usize, size: usize) u32 {
    log.debug("posix_memalign with alignment {} and size {}", .{ alignment, size });
    return switch (alignment) {
        inline 16, 32, 64 => |alignment_bytes| allocator.posixMemAlign(memptr, .fromByteUnits(alignment_bytes), size),
        else => allocator.posixMemAlign(memptr, .fromByteUnits(max_align_t), size),
    };
}

export fn aligned_alloc(alignment: usize, size: usize) ?*anyopaque {
    log.debug("aligned_alloc with alignment {} and size {}", .{ alignment, size });
    return switch (alignment) {
        inline 16, 32, 64 => |alignment_bytes| allocator.alignedAlloc(.fromByteUnits(alignment_bytes), size),
        else => allocator.alignedAlloc(.fromByteUnits(max_align_t), size),
    };
}

export fn free(memptr: ?*anyopaque) void {
    if (memptr) |ptr| {
        log.debug("free {*}", .{ptr});
        allocator.free(ptr);
    }
}

// https://jcarin.com/posts/memory-leak/
// https://github.com/bminor/glibc/blob/06caf53adfae0c93062edd62f83eed16ab5cec0b/malloc/set-freeres.c#L123
// Glibc doesn't free some resources that are used through out the lifetime of
// the library as an optimization since these resources would eventually be
// freed by the kernel but this leads to leaks reported by valgrind and Zig's
// debug allocator so call this to cleanup if `checkLeaks` is called
/// Free all glibc allocated resources.
extern "c" fn __libc_freeres() void;

export fn checkLeaks() void {
    if (builtin.target.isGnuLibC()) {
        log.debug("freeing all glibc global resources with __libc_freeres", .{});
        __libc_freeres();
    }
    switch (gpa.deinit()) {
        .leak => {
            log.debug("Leaks detected", .{});
            std.process.exit(7);
        },
        .ok => log.debug("No leaks detected. Happy Programming", .{}),
    }
}

pub extern fn main() c_int;
