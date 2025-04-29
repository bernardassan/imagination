const std = @import("std");

// Use Zig's GeneralPurposeAllocator (or another allocator of your choice)
var gpa: std.heap.DebugAllocator(.{ .thread_safe = true, .safety = true }) = .init;
const zig_allocator = gpa.allocator();

// https://github.com/zig-gamedev/zstbi/blob/094c4bba5cdbec167d3f6aaa98cccccd5c99145f/src/zstbi.zig#L388
// https://gist.github.com/pfgithub/65c13d7dc889a4b2ba25131994be0d20
// std.heap.c_allocator
// https://gencmurat.com/en/posts/using-allocators-in-zig/
//
// Export C-compatible allocator functions
export fn malloc(size: usize) ?*anyopaque {
    // std.debug.print("malloc {}", .{size});
    return @ptrCast(zig_allocator.alloc(u8, size) catch return null);
}

fn zigMem(mem: *anyopaque) [*]u8 {
    return @ptrCast(mem);
}

export fn free(ptr: ?*anyopaque) void {
    std.heap.c_allocator
    // std.debug.print("free {*}", .{ptr});
    if (ptr) |p| {
        zig_allocator.free(zigMem(p));
    }
}

export fn realloc(ptr: ?*anyopaque, new_size: usize) ?*anyopaque {
    // std.debug.print("realloc {*} with size {}", .{ ptr, new_size });
    if (ptr) |p| {
        return @ptrCast(zig_allocator.realloc(zigMem(p), new_size) catch return null);
    } else {
        return malloc(new_size);
    }
}

export fn calloc(nmemb: usize, size: usize) ?*anyopaque {
    // std.debug.print("calloc {} memb with size {}", .{ nmemb, size });
    const total_size = nmemb * size;
    const mem = malloc(total_size) orelse return null;
    @memset(zigMem(mem)[0..total_size], 0); // Zero-initialize
    return mem;
}

pub extern fn main() c_int;
