const std = @import("std");

pub fn matches(query: []const u8, candidate: []const u8) bool {
    return score(query, candidate) != null;
}

pub fn score(query: []const u8, candidate: []const u8) ?i32 {
    if (query.len == 0) return 0;

    var query_index: usize = 0;
    var candidate_index: usize = 0;
    var total: i32 = 0;
    var previous_match: ?usize = null;

    while (query_index < query.len and candidate_index < candidate.len) : (candidate_index += 1) {
        const query_char = std.ascii.toLower(query[query_index]);
        const candidate_char = std.ascii.toLower(candidate[candidate_index]);
        if (query_char != candidate_char) continue;

        total += 10;
        if (candidate_index == query_index) total += 4;
        if (previous_match) |previous| {
            if (candidate_index == previous + 1) total += 6;
        }
        if (candidate_index == 0 or isWordBreak(candidate[candidate_index - 1])) total += 3;

        previous_match = candidate_index;
        query_index += 1;
    }

    if (query_index != query.len) return null;
    return total - @as(i32, @intCast(candidate.len - query.len));
}

fn isWordBreak(char: u8) bool {
    return char == '-' or char == '_' or char == ' ' or char == '/' or char == '.';
}

test "fuzzy matches case insensitive subsequences" {
    try std.testing.expect(matches("zb", "zig-build"));
    try std.testing.expect(matches("ZT", "zig test"));
    try std.testing.expect(!matches("zz", "zig-build"));
}

test "fuzzy rewards contiguous prefix matches" {
    const prefix = score("zig", "zig build").?;
    const spread = score("zig", "z anything i anything g").?;
    try std.testing.expect(prefix > spread);
}
