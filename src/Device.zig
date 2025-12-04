const std = @import("std");
const ext = @import("wayland").client.ext;

const Backend = enum {
    ext,
    wlr,
    portal,
};

//fn createDeviceBackend(data_control_manager: *) void {}
