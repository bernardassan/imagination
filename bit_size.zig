const std = @import("std");

const MetaData = packed struct {
    raw: Raw,
    const Raw = usize;

    const ALIGN_MASK: usize = (@as(usize, 1) << ALIGN_BITS) - 1;
    const ALIGN_BITS = 6;
    const SIZE_MASK: usize = ~(ALIGN_MASK);

    const max_alignment_supported = 64;
    // max size = 2^(usize_bits - ALIGN_BITS)
    const max_size = (1 << (@bitSizeOf(Raw) - ALIGN_BITS));

    /// Stores size and log2(alignment) together
    pub fn pack(size: usize, alignment: usize) MetaData {
        std.debug.assert(size < max_size);
        std.debug.assert(alignment <= max_alignment_supported and alignment > 0);
        const log_align: u6 = std.math.log2_int(usize, alignment); //@ctz(alignment)
        return .{
            .raw = (size << ALIGN_BITS) | log_align,
        };
    }

    pub fn unpack(self: MetaData) struct {
        size: usize,
        alignment: usize,
    } {
        const log_align: u6 = @truncate(self.raw & ALIGN_MASK);
        const size = self.raw >> ALIGN_BITS;
        return .{
            .size = size,
            .alignment = @as(usize, 1) << log_align,
        };
    }
};

test "pack and unpack metadata" {
    const size: usize = (1 << 58) - 1; // 288230376151711743
    const alignment: usize = 64;

    const meta = MetaData.pack(size, alignment);
    const unpacked = meta.unpack();

    try std.testing.expectEqual(size, unpacked.size);
    try std.testing.expectEqual(alignment, unpacked.alignment);
}
