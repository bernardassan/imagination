const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.imagination);

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;
const Socket = tardy.Socket;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;

fn baseHandler(ctx: *const Context, _: void) !Respond {
    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = "Hello, world!",
    });
}

comptime {
    if (builtin.target.ptrBitWidth() != 64) {
        @compileError("Imagination requires a 64-bit system");
    }
    if (builtin.os.tag != .linux) {
        @compileError("Imagination is currently tested only on Linux.\nPR for support to other Oses are welcome.");
    }
}

/// 1GiB static buffer allocation
var buffer: [1 << 30]u8 = undefined;
var fixed_allocator: std.heap.FixedBufferAllocator = .init(&buffer);
const fba = fixed_allocator.threadSafeAllocator();

var debug_allocator: std.heap.DebugAllocator(.{
    .safety = true,
    .thread_safe = true,
}) = .init;

const _gpa = gpa: {
    break :gpa switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseSmall => .{ fba, false },
        .ReleaseFast => .{ std.heap.smp_allocator, false },
    };
};
const gpa = _gpa.@"0";
const is_debug = _gpa.@"1";

// Export C-compatible allocator functions
export fn malloc(size: usize) ?*anyopaque {
    return gpa.alloc(size) catch return null;
}

export fn free(ptr: ?*anyopaque) void {
    if (ptr) |p| gpa.free(p);
}

export fn realloc(ptr: ?*anyopaque, new_size: usize) ?*anyopaque {
    if (ptr) |p| {
        return gpa.realloc(p, new_size) catch return null;
    } else {
        return malloc(new_size);
    }
}

export fn calloc(nmemb: usize, size: usize) ?*anyopaque {
    const total_size = nmemb * size;
    const mem = malloc(total_size) orelse return null;
    @memset(mem, 0); // Zero-initialize
    return mem;
}

pub fn main() !void {
    @memset(buffer[0..], 0);
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };
    defer fixed_allocator.reset();

    var arena: std.heap.ArenaAllocator = .init(_gpa.@"0");
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var t = try Tardy.init(fba, .{
        .threading = .auto,
    });
    defer t.deinit();

    var router = try Router.init(arena_alloc, &.{
        Route.init("/").get({}, baseHandler).layer(),
    }, .{});
    defer router.deinit(arena_alloc);

    // create socket for tardy
    var socket = try Socket.init(.{ .tcp = .{ .host = host, .port = port } });
    // TODO: how to use async close
    defer socket.close_blocking();

    const backlog = 4096;
    try socket.bind();
    try socket.listen(backlog);

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server = Server.init(.{
                    .stack_size = 1024 * 1024 * 4,
                    .socket_buffer_bytes = 1024 * 2,
                    .keepalive_count_max = null,
                    .connection_count_max = 1024,
                });
                try server.serve(rt, p.router, .{ .normal = p.socket });
            }
        }.entry,
    );
}
