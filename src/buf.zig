/// ReadBuffer are the various options for reading.
pub const ReadBuffer = union(enum) {
    /// Read into this buffer.
    buffer: []u8,

    // TODO: future will have vectors
};

/// WriteBuffer are the various options for writing.
pub const WriteBuffer = union(enum) {
    /// Write from this buffer.
    buffer: []const u8,

    // TODO: future will have vectors
};
