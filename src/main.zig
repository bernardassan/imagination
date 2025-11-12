const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.imagination);

const zzz = @import("zzz");
const czalloc = @import("czalloc");
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
    if (builtin.os.tag != .linux) {
        @compileError("Imagination is currently tested only on Linux.\nPR for support to other Oses are welcome.");
    }
}

pub fn main() !void {
    const gpa = czalloc.gpa;
    defer gpa.deinit();

    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var arena: std.heap.ArenaAllocator = .init(czalloc.backing_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var t: Tardy = try .init(czalloc.fba, .{
        .threading = .auto,
    });
    defer t.deinit();

    var router: Router = try .init(arena_alloc, &.{
        Route.init("/").get({}, baseHandler).layer(),
    }, .{});
    defer router.deinit(arena_alloc);

    // create socket for tardy
    var socket: Socket = try .init(.{ .tcp = .{ .host = host, .port = port } });
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
                var server: Server = .init(.{
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
