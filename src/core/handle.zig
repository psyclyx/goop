/// Handle to a widget node. Carries an index into the tree's node array
/// and a generation counter for stale-handle detection.
pub const NodeHandle = struct {
    index: u32,
    generation: u32,

    /// Two handles are equal iff both index and generation match.
    pub fn eql(a: NodeHandle, b: NodeHandle) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};
