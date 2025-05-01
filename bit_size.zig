const std = @import("std");

const MetaData = packed struct {
    raw: Raw,
    const Raw = usize;

    // Supports up to 64-byte alignment (2^6)
    const ALIGN_BITS = 6;
    const ALIGN_MASK: usize = (@as(usize, 1) << ALIGN_BITS) - 1;
    const SIZE_MASK: usize = ~(ALIGN_MASK);

    const max_alignment_supported = 64;
    // max size = 2^(usize_bits - ALIGN_BITS)
    const max_size = (1 << (@bitSizeOf(Raw) - ALIGN_BITS));

    /// Stores size and log2(alignment) together
    pub fn init(msize: usize, malignment: usize) MetaData {
        std.debug.assert(msize < max_size);
        std.debug.assert(std.math.isPowerOfTwo(malignment) and malignment <= max_alignment_supported);
        // equivalent to @ctz(alignment)
        const log_align: u6 = std.math.log2_int(usize, malignment);
        return .{
            .raw = (msize << ALIGN_BITS) | log_align,
        };
    }

    // Extract size (upper 58 bits)
    pub fn size(self: MetaData) usize {
        return self.raw >> ALIGN_BITS;
    }

    // Extract alignment (lower 6 bits as 2^N)
    pub fn alignment(self: MetaData) usize {
        const log_align: u6 = @truncate(self.raw & ALIGN_MASK);
        return @as(usize, 1) << log_align;
    }
};

test "pack and unpack metadata" {
    const size: usize = (1 << 58) - 1; // 288230376151711743
    const alignment: usize = 64;

    const meta = MetaData.init(size, alignment);

    try std.testing.expectEqual(size, meta.size());
    try std.testing.expectEqual(alignment, meta.alignment());
}
