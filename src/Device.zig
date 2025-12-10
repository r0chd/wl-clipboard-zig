const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const ext = @import("wayland").client.ext;
const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;
const GlobalList = @import("wayland/GlobalList.zig");

pub const Backend = enum {
    ext,
    wlr,
    portal,
};

const Self = @This();

backend: Backend,
inner: Inner,

const Inner = union(Backend) {
    ext: ExtBackend,
    wlr: WlrBackend,
    portal: void, // TODO
};

const ExtBackend = struct {
    data_control_manager: *ext.DataControlManagerV1,
    device: *ext.DataControlDeviceV1,
};

const WlrBackend = struct {
    data_control_manager: *zwlr.DataControlManagerV1,
    device: *zwlr.DataControlDeviceV1,
};

pub fn init(globals: *const GlobalList, seat: *wl.Seat, options: struct { force_backend: ?Backend = null }) !Self {
    const backend = options.force_backend orelse detectBackend(globals) orelse return error.NoBackendFound;

    switch (backend) {
        .ext => {
            const data_control_manager = globals.bind(ext.DataControlManagerV1, ext.DataControlManagerV1.generated_version) orelse return error.UnsupportedBackend;
            const device = try data_control_manager.getDataDevice(seat);
            return Self{
                .backend = .ext,
                .inner = .{ .ext = .{
                    .data_control_manager = data_control_manager,
                    .device = device,
                } },
            };
        },
        .wlr => {
            const data_control_manager = globals.bind(zwlr.DataControlManagerV1, zwlr.DataControlManagerV1.generated_version) orelse return error.UnsupportedBackend;
            const device = try data_control_manager.getDataDevice(seat);
            return Self{
                .backend = .wlr,
                .inner = .{ .wlr = .{
                    .data_control_manager = data_control_manager,
                    .device = device,
                } },
            };
        },
        .portal => return error.UnsupportedBackend,
    }
}

pub fn deinit(self: *Self) void {
    switch (self.inner) {
        inline .ext, .wlr => |backend| {
            backend.device.destroy();
            backend.data_control_manager.destroy();
        },
        .portal => {},
    }
}

fn detectBackend(globals: *const GlobalList) ?Backend {
    if (globals.bind(ext.DataControlManagerV1, ext.DataControlManagerV1.generated_version) != null) {
        return .ext;
    }
    if (globals.bind(zwlr.DataControlManagerV1, zwlr.DataControlManagerV1.generated_version) != null) {
        return .wlr;
    }
    return null;
}

pub const DataSource = struct {
    backend: Backend,
    inner: DataSourceInner,

    const DataSourceInner = union(Backend) {
        ext: *ext.DataControlSourceV1,
        wlr: *zwlr.DataControlSourceV1,
        portal: void,
    };

    pub const Event = union(enum) {
        send: struct { mime_type: [:0]const u8, fd: posix.fd_t },
        cancelled: void,
    };

    pub fn offer(self: *DataSource, mime_type: [:0]const u8) void {
        switch (self.inner) {
            inline .ext, .wlr => |source| source.offer(mime_type),
            .portal => {},
        }
    }

    pub fn setListener(self: *DataSource, comptime T: type, listener: *const fn (*DataSource, Event, T) void, data: T) void {
        switch (self.inner) {
            .ext => |source| {
                const Context = struct {
                    data_source: *DataSource,
                    user_data: T,
                    user_listener: *const fn (*DataSource, Event, T) void,
                };

                const wrapper = struct {
                    fn callback(_: *ext.DataControlSourceV1, event: ext.DataControlSourceV1.Event, ctx: *const Context) void {
                        const abstract_event: Event = switch (event) {
                            .send => |send_data| .{ .send = .{
                                .mime_type = mem.span(send_data.mime_type),
                                .fd = send_data.fd,
                            } },
                            .cancelled => .cancelled,
                        };
                        ctx.user_listener(ctx.data_source, abstract_event, ctx.user_data);
                    }
                };

                const Static = struct {
                    // SAFETY: we set it one line below
                    var context: Context = undefined;
                };
                Static.context = .{
                    .data_source = self,
                    .user_data = data,
                    .user_listener = listener,
                };

                source.setListener(*const Context, wrapper.callback, &Static.context);
            },
            .wlr => |source| {
                const Context = struct {
                    data_source: *DataSource,
                    user_data: T,
                    user_listener: *const fn (*DataSource, Event, T) void,
                };

                const wrapper = struct {
                    fn callback(_: *zwlr.DataControlSourceV1, event: zwlr.DataControlSourceV1.Event, ctx: *const Context) void {
                        const abstract_event: Event = switch (event) {
                            .send => |send_data| .{ .send = .{
                                .mime_type = mem.span(send_data.mime_type),
                                .fd = send_data.fd,
                            } },
                            .cancelled => .cancelled,
                        };
                        ctx.user_listener(ctx.data_source, abstract_event, ctx.user_data);
                    }
                };

                const Static = struct {
                    // SAFETY: we set it one line below
                    var context: Context = undefined;
                };
                Static.context = .{
                    .data_source = self,
                    .user_data = data,
                    .user_listener = listener,
                };

                source.setListener(*const Context, wrapper.callback, &Static.context);
            },
            .portal => {},
        }
    }

    pub fn deinit(self: *DataSource) void {
        switch (self.inner) {
            inline .ext, .wlr => |source| source.destroy(),
            .portal => {},
        }
    }
};

pub fn createDataSource(self: *Self) !DataSource {
    switch (self.inner) {
        .ext => |backend| {
            const source = try backend.data_control_manager.createDataSource();
            return DataSource{
                .backend = .ext,
                .inner = .{ .ext = source },
            };
        },
        .wlr => |backend| {
            const source = try backend.data_control_manager.createDataSource();
            return DataSource{
                .backend = .wlr,
                .inner = .{ .wlr = source },
            };
        },
        .portal => return error.UnsupportedBackend,
    }
}

pub const DataOffer = struct {
    backend: Backend,
    inner: DataOfferInner,

    const DataOfferInner = union(Backend) {
        ext: *ext.DataControlOfferV1,
        wlr: *zwlr.DataControlOfferV1,
        portal: void,
    };

    pub const Event = union(enum) {
        offer: [:0]const u8,
    };

    pub fn receive(self: *DataOffer, mime_type: [:0]const u8, fd: posix.fd_t) void {
        switch (self.inner) {
            inline .ext, .wlr => |offer| offer.receive(mime_type, fd),
            .portal => {},
        }
    }

    pub fn setListener(self: *DataOffer, comptime T: type, listener: *const fn (*DataOffer, Event, T) void, data: T) void {
        switch (self.inner) {
            .ext => |offer| {
                const Context = struct {
                    data_offer: *DataOffer,
                    user_data: T,
                    user_listener: *const fn (*DataOffer, Event, T) void,
                };

                const wrapper = struct {
                    fn callback(_: *ext.DataControlOfferV1, event: ext.DataControlOfferV1.Event, ctx: *const Context) void {
                        const abstract_event: Event = switch (event) {
                            .offer => |offer_data| .{ .offer = mem.span(offer_data.mime_type) },
                        };
                        ctx.user_listener(ctx.data_offer, abstract_event, ctx.user_data);
                    }
                };

                const Static = struct {
                    // SAFETY: we set it one line below
                    var context: Context = undefined;
                };
                Static.context = .{
                    .data_offer = self,
                    .user_data = data,
                    .user_listener = listener,
                };

                offer.setListener(*const Context, wrapper.callback, &Static.context);
            },
            .wlr => |offer| {
                const Context = struct {
                    data_offer: *DataOffer,
                    user_data: T,
                    user_listener: *const fn (*DataOffer, Event, T) void,
                };

                const wrapper = struct {
                    fn callback(_: *zwlr.DataControlOfferV1, event: zwlr.DataControlOfferV1.Event, ctx: *const Context) void {
                        const abstract_event: Event = switch (event) {
                            .offer => |offer_data| .{ .offer = mem.span(offer_data.mime_type) },
                        };
                        ctx.user_listener(ctx.data_offer, abstract_event, ctx.user_data);
                    }
                };

                const Static = struct {
                    // SAFETY: we set it one line below
                    var context: Context = undefined;
                };
                Static.context = .{
                    .data_offer = self,
                    .user_data = data,
                    .user_listener = listener,
                };

                offer.setListener(*const Context, wrapper.callback, &Static.context);
            },
            .portal => {},
        }
    }

    pub fn deinit(self: *DataOffer) void {
        switch (self.inner) {
            inline .ext, .wlr => |offer| offer.destroy(),
            .portal => {},
        }
    }
};

pub const DeviceEvent = union(enum) {
    data_offer: *DataOffer,
    selection: ?*DataOffer,
    primary_selection: ?*DataOffer,
    finished: void,
};

pub fn setListener(self: *Self, comptime T: type, listener: *const fn (*Self, DeviceEvent, T) void, data: T) void {
    switch (self.inner) {
        .ext => |backend| {
            const Context = struct {
                device: *Self,
                user_data: T,
                user_listener: *const fn (*Self, DeviceEvent, T) void,
                offer_storage: ?DataOffer = null,
                selection_storage: ?DataOffer = null,
                primary_storage: ?DataOffer = null,
            };

            const wrapper = struct {
                fn callback(_: *ext.DataControlDeviceV1, event: ext.DataControlDeviceV1.Event, ctx: *Context) void {
                    const abstract_event: DeviceEvent = switch (event) {
                        .data_offer => |offer_data| blk: {
                            ctx.offer_storage = DataOffer{
                                .backend = .ext,
                                .inner = .{ .ext = offer_data.id },
                            };
                            break :blk .{ .data_offer = &ctx.offer_storage.? };
                        },
                        .selection => |selection_data| blk: {
                            if (selection_data.id) |id| {
                                ctx.selection_storage = DataOffer{
                                    .backend = .ext,
                                    .inner = .{ .ext = id },
                                };
                                break :blk .{ .selection = &ctx.selection_storage.? };
                            }
                            break :blk .{ .selection = null };
                        },
                        .primary_selection => |primary_data| blk: {
                            if (primary_data.id) |id| {
                                ctx.primary_storage = DataOffer{
                                    .backend = .ext,
                                    .inner = .{ .ext = id },
                                };
                                break :blk .{ .primary_selection = &ctx.primary_storage.? };
                            }
                            break :blk .{ .primary_selection = null };
                        },
                        .finished => .finished,
                    };
                    ctx.user_listener(ctx.device, abstract_event, ctx.user_data);
                }
            };

            const Static = struct {
                // SAFETY: we set it one line below
                var context: Context = undefined;
            };
            Static.context = .{
                .device = self,
                .user_data = data,
                .user_listener = listener,
            };

            backend.device.setListener(*Context, wrapper.callback, &Static.context);
        },
        .wlr => |backend| {
            const Context = struct {
                device: *Self,
                user_data: T,
                user_listener: *const fn (*Self, DeviceEvent, T) void,
                offer_storage: ?DataOffer = null,
                selection_storage: ?DataOffer = null,
                primary_storage: ?DataOffer = null,
            };

            const wrapper = struct {
                fn callback(_: *zwlr.DataControlDeviceV1, event: zwlr.DataControlDeviceV1.Event, ctx: *Context) void {
                    const abstract_event: DeviceEvent = switch (event) {
                        .data_offer => |offer_data| blk: {
                            ctx.offer_storage = DataOffer{
                                .backend = .wlr,
                                .inner = .{ .wlr = offer_data.id },
                            };
                            break :blk .{ .data_offer = &ctx.offer_storage.? };
                        },
                        .selection => |selection_data| blk: {
                            if (selection_data.id) |id| {
                                ctx.selection_storage = DataOffer{
                                    .backend = .wlr,
                                    .inner = .{ .wlr = id },
                                };
                                break :blk .{ .selection = &ctx.selection_storage.? };
                            }
                            break :blk .{ .selection = null };
                        },
                        .primary_selection => |primary_data| blk: {
                            if (primary_data.id) |id| {
                                ctx.primary_storage = DataOffer{
                                    .backend = .wlr,
                                    .inner = .{ .wlr = id },
                                };
                                break :blk .{ .primary_selection = &ctx.primary_storage.? };
                            }
                            break :blk .{ .primary_selection = null };
                        },
                        .finished => .finished,
                    };
                    ctx.user_listener(ctx.device, abstract_event, ctx.user_data);
                }
            };

            const Static = struct {
                // SAFETY: we set it one line below
                var context: Context = undefined;
            };
            Static.context = .{
                .device = self,
                .user_data = data,
                .user_listener = listener,
            };

            backend.device.setListener(*Context, wrapper.callback, &Static.context);
        },
        .portal => {},
    }
}

pub fn setSelection(self: *Self, source: *DataSource) void {
    switch (self.inner) {
        .ext => |backend| backend.device.setSelection(source.inner.ext),
        .wlr => |backend| backend.device.setSelection(source.inner.wlr),
        .portal => {},
    }
}

pub fn setPrimarySelection(self: *Self, source: *DataSource) void {
    switch (self.inner) {
        .ext => |backend| backend.device.setPrimarySelection(source.inner.ext),
        .wlr => |backend| backend.device.setPrimarySelection(source.inner.wlr),
        .portal => {},
    }
}

pub const Clipboard = enum {
    regular,
    primary,
    both,
};
