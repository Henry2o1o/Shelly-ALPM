const std = @import("std");
const zz = @import("zigzag");

pub const Model = struct {
    group: zz.TabGroup,
    package_grid: zz.DataTable,
    aur_grid: zz.DataTable,
};
