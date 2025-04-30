const std = @import("std");

// Pack size + alignment into a single usize
const MetaData = struct {
    packed_value: usize,

    // Constants for bit manipulation
    const ALIGNMENT_BITS = 6; // Supports up to 64-byte alignment (2^6)
    const SIZE_BITS = @bitSizeOf(usize) - ALIGNMENT_BITS; // 56 bits for size (on 64-bit)
    const SIZE_MASK = (1 << SIZE_BITS) - 1; // Mask to extract size

    // Initialize MetaData from size + alignment
    pub fn init(alloc_size: usize, alloc_alignment: usize) MetaData {
        std.debug.assert(std.math.isPowerOfTwo(alloc_alignment)); // Alignment must be power-of-two
        const alignment_log2 = std.math.log2_int(u6, alloc_alignment);
        return .{
            .packed_value = (alignment_log2 << SIZE_BITS) | (alloc_size & SIZE_MASK),
        };
    }

    // Extract size (lower 56 bits)
    pub fn size(self: MetaData) usize {
        return self.packed_value & SIZE_MASK;
    }

    // Extract alignment (upper 8 bits as 2^N)
    pub fn alignment(self: MetaData) usize {
        const alignment_log2 = self.packed_value >> SIZE_BITS;
        return @as(usize, 1) << @as(u6, @truncate(alignment_log2)); // Prevent overflow
    }
};

test "Metadata packing" {
    const meta = MetaData.init((1 << 56) - 1, 64); // Size=1024, Alignment=64
    try std.testing.expectEqual(meta.size(), (1 << 56) - 1);
    try std.testing.expectEqual(meta.alignment(), 64);
    try std.testing.expectEqual(meta.packed_value, (6 << 56) | (1 << 56) - 1); // 6 = log2(64)
}
