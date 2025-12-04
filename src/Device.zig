const std = @import("std");
const ext = @import("wayland").client.ext;
const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;
const GlobalList = @import("GlobalList.zig");

const Backend = enum {
    ext,
    wlr,
    portal,
};

const Self = @This();

backend: Backend,
data: union(Backend) {
    ext: struct {
        data_control_manager: *ext.DataControlManagerV1,
        data_source: *ext.DataControlSourceV1,
        device: *ext.DataControlDeviceV1,
    },
    wlr: struct {
        data_control_manager: *zwlr.DataControlManagerV1,
        data_source: *zwlr.DataControlSourceV1,
        device: *zwlr.DataControlDeviceV1,
    },
    portal: struct {},
},

pub fn init(globals: *const GlobalList, seat: *wl.Seat, options: struct { force_backend: ?Backend = null }) !Self {
    if (options.force_backend) |backend| {
        switch (backend) {
            .ext => {
                const data_control_manager = globals.bind(ext.DataControlManagerV1, ext.DataControlManagerV1.generated_version) orelse return error.UnsupportedBackend;
                const data_source = try data_control_manager.createDataSource();
                const device = try data_control_manager.getDataDevice(seat);
                return Self{
                    .backend = .ext,
                    .data = .{ .ext = .{
                        .data_control_manager = data_control_manager,
                        .data_source = data_source,
                        .device = device,
                    } },
                };
            },
            .wlr => {
                const data_control_manger = globals.init(zwlr.DataControlManagerV1, zwlr.DataControlManagerV1.generated_version) orelse return error.UnsupportedBackend;
                const data_source = try data_control_manger.createDataSource();
                const device = try data_control_manger.getDataDevice(seat);
                return Self{
                    .backend = .wlr,
                    .data = .{ .wlr = .{
                        .data_control_manager = data_control_manger,
                        .data_source = data_source,
                        .device = device,
                    } },
                };
            },
            .portal => unreachable,
        }
    } else {
        if (globals.bind(ext.DataControlManagerV1, ext.DataControlManagerV1.generated_version)) |data_control_manager| {
            const data_source = try data_control_manager.createDataSource();
            const device = try data_control_manager.getDataDevice(seat);
            return Self{
                .backend = .ext,
                .data = .{ .ext = .{
                    .data_control_manager = data_control_manager,
                    .data_source = data_source,
                    .device = device,
                } },
            };
        } else if (globals.init(zwlr.DataControlManagerV1, zwlr.DataControlManagerV1.generated_version) orelse return error.UnsupportedBackend) |data_control_manager| {
            const data_source = try data_control_manager.createDataSource();
            const device = try data_control_manager.getDataDevice(seat);
            return Self{
                .backend = .wlr,
                .data = .{ .wlr = .{
                    .data_control_manager = data_control_manager,
                    .data_source = data_source,
                    .device = device,
                } },
            };
        } else if (true) {
            // TODO: PORTAL
            unreachable;
        } else {
            return error.NoBackendFound;
        }
    }
}
