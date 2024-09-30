const std = @import("std");
const httpz = @import("httpz");
const Context = @import("context.zig").Context;
const Handler = @import("context.zig").Handler;
const Injector = @import("injector.zig").Injector;

pub const Route = struct {
    method: ?httpz.Method = null,
    prefix: ?[]const u8 = null,
    path: ?[]const u8 = null,
    handler: ?*const fn (*Context) anyerror!void = null, // TODO(zig): should be ?*const Handler
    children: []const Route = &.{},

    pub fn match(self: *const Route, req: *const httpz.Request) ?Params {
        if (self.prefix) |prefix| {
            if (!std.mem.startsWith(u8, req.url.path, prefix)) return null;
        }

        if (self.method) |m| {
            if (m != req.method) return null;
        }

        if (self.path) |p| {
            return Params.match(p, req.url.path);
        }

        return Params{};
    }

    /// Groups the given routes under a common prefix. The prefix is removed
    /// from the request path before the children are called.
    pub fn group(prefix: []const u8, children: []const Route) Route {
        const H = struct {
            fn handleGroup(ctx: *Context) anyerror!void {
                const orig = ctx.req.url.path;
                ctx.req.url.path = ctx.req.url.path[ctx.current.prefix.?.len..];
                defer ctx.req.url.path = orig;

                try ctx.next();
            }
        };

        return .{
            .prefix = prefix,
            .handler = H.handleGroup,
            .children = children,
        };
    }

    /// Creates a GET route with the given path and handler.
    pub fn get(comptime path: []const u8, comptime handler: anytype) Route {
        return route(.GET, path, false, handler);
    }

    /// Creates a POST route with the given path and handler. The handler will
    /// receive the request body in the last argument.
    pub fn post(comptime path: []const u8, comptime handler: anytype) Route {
        return route(.POST, path, true, handler);
    }

    /// Creates a POST route with the given path and handler but without a body.
    pub fn post0(comptime path: []const u8, comptime handler: anytype) Route {
        return route(.POST, path, false, handler);
    }

    /// Creates a PUT route with the given path and handler. The handler will
    /// receive the request body in the last argument.
    pub fn put(comptime path: []const u8, comptime handler: anytype) Route {
        return route(.PUT, path, true, handler);
    }

    /// Creates a PUT route with the given path and handler but without a body.
    pub fn put0(comptime path: []const u8, comptime handler: anytype) Route {
        return route(.PUT, path, false, handler);
    }

    /// Creates a PATCH route with the given path and handler. The handler will
    /// receive the request body in the last argument.
    pub fn patch(comptime path: []const u8, comptime handler: anytype) Route {
        return route(.PATCH, path, true, handler);
    }

    /// Creates a PATCH route with the given path and handler but without a body.
    pub fn patch0(comptime path: []const u8, comptime handler: anytype) Route {
        return route(.PATCH, path, false, handler);
    }

    /// Creates a DELETE route with the given path and handler.
    pub fn delete(comptime path: []const u8, comptime handler: anytype) Route {
        return route(.DELETE, path, false, handler);
    }

    /// Creates a group of routes from a struct type. Each pub fn will be equivalent
    /// to calling the corresponding route function with the method and path.
    pub fn router(comptime T: type) Route {
        const children = comptime blk: {
            @setEvalBranchQuota(@typeInfo(T).@"struct".decls.len * 100);

            var res: []const Route = &.{};

            for (std.meta.declarations(T)) |d| {
                if (@typeInfo(@TypeOf(@field(T, d.name))) != .@"fn") continue;

                const j = std.mem.indexOfScalar(u8, d.name, ' ') orelse @compileError("route must contain a space");
                var buf: [j]u8 = undefined;
                const method = std.ascii.lowerString(&buf, d.name[0..j]);
                res = res ++ .{@field(@This(), method)(d.name[j + 1 ..], @field(T, d.name))};
            }

            break :blk res;
        };

        return .{
            .children = children,
        };
    }
};

fn route(comptime method: httpz.Method, comptime path: []const u8, comptime has_body: bool, comptime handler: anytype) Route {
    const has_query = comptime path[path.len - 1] == '?';
    const n_params = comptime brk: {
        var n: usize = 0;
        for (path) |c| {
            if (c == ':') n += 1;
        }
        break :brk n;
    };

    const H = struct {
        fn handleRoute(ctx: *Context) anyerror!void {
            var args: std.meta.ArgsTuple(@TypeOf(handler)) = undefined;
            const mid = args.len - n_params - @intFromBool(has_query) - @intFromBool(has_body);

            inline for (0..mid) |i| {
                args[i] = try ctx.injector.get(@TypeOf(args[i]));
            }

            inline for (0..n_params, mid..) |j, i| {
                args[i] = try ctx.params.get(j, @TypeOf(args[i]));
            }

            if (comptime has_query) {
                args[mid + n_params] = try ctx.readQuery(@TypeOf(args[mid + n_params]));
            }

            if (comptime has_body) {
                args[args.len - 1] = try ctx.readJson(@TypeOf(args[args.len - 1]));
            }

            try ctx.send(@call(.auto, handler, args));
            return;
        }
    };

    return .{
        .method = method,
        .path = path[0 .. path.len - @intFromBool(has_query)],
        .handler = if (comptime @TypeOf(handler) == Route) handler.handler.? else H.handleRoute,
    };
}

pub const Params = struct {
    matches: [16][]const u8 = undefined,
    len: usize = 0,

    pub fn match(pattern: []const u8, path: []const u8) ?Params {
        var res = Params{};
        var pattern_parts = std.mem.tokenizeScalar(u8, pattern, '/');
        var path_parts = std.mem.tokenizeScalar(u8, path, '/');

        while (true) {
            const pat = pattern_parts.next() orelse return if (pattern[pattern.len - 1] == '*' or path_parts.next() == null) res else null;
            const pth = path_parts.next() orelse return if (pat.len == 1 and pat[0] == '*') res else null;
            const dynamic = pat[0] == ':' or pat[0] == '*';

            if (std.mem.indexOfScalar(u8, pat, '.')) |i| {
                const j = (if (dynamic) std.mem.lastIndexOfScalar(u8, pth, '.') else std.mem.indexOfScalar(u8, pth, '.')) orelse return null;

                if (match(pat[i + 1 ..], pth[j + 1 ..])) |ch| {
                    for (ch.matches, res.len..) |s, l| res.matches[l] = s;
                    res.len += ch.len;
                } else return null;
            }

            if (!dynamic and !std.mem.eql(u8, pat, pth)) return null;

            if (pat[0] == ':') {
                res.matches[res.len] = pth;
                res.len += 1;
            }
        }
    }

    pub fn get(self: *const Params, index: usize, comptime T: type) !T {
        if (index >= self.len) return error.NoMatch;

        return Context.parse(T, self.matches[index]);
    }
};

fn expectMatch(pattern: []const u8, path: []const u8, len: ?usize) !void {
    const res = Params.match(pattern, path);
    if (len) |l| {
        try std.testing.expectEqual(l, res.?.len);
    } else {
        try std.testing.expect(res == null);
    }
}

test "Params matching" {
    try expectMatch("/", "/", 0);
    try expectMatch("/", "/foo", null);
    try expectMatch("/", "/foo/bar", null);

    try expectMatch("/*", "/", 0);
    try expectMatch("/*", "/foo", 0);
    try expectMatch("/*", "/foo/bar", 0);

    try expectMatch("/*.js", "/foo.js", 0);
    try expectMatch("/*.js", "/foo-bar.js", 0);
    try expectMatch("/*.js", "/foo/bar.js", null);
    try expectMatch("/*.js", "/", null);

    try expectMatch("/foo", "/foo", 0);
    try expectMatch("/foo", "/foo/bar", null);
    try expectMatch("/foo", "/bar", null);

    try expectMatch("/:foo", "/foo", 1);
    try expectMatch("/:foo", "/bar", 1);
    try expectMatch("/:foo", "/foo/bar", null);

    try expectMatch("/:foo/bar", "/foo/bar", 1);
    try expectMatch("/:foo/bar", "/baz/bar", 1);
    try expectMatch("/:foo/bar", "/foo/bar/baz", null);

    try expectMatch("/api/*", "/api", 0);
    try expectMatch("/api/*", "/api/foo", 0);
    try expectMatch("/api/*", "/api/foo/bar", 0);
    try expectMatch("/api/*", "/foo", null);
    try expectMatch("/api/*", "/", null);
}
