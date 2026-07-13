pub const ValidationSeverity = enum(i32) { info, warning, critical };

pub const ValidationFinding = struct {
    tool: []const u8,
    severity: ValidationSeverity,
    hook: []const u8,
    matched_line: []const u8,
    message: []const u8,
};
