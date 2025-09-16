// Simple memory pool for regex engine optimization
const std = @import("std");
const Allocator = std.mem.Allocator;

const bit_vector = @import("bit_vector.zig");
const BitVector = bit_vector.BitVector;
const ThreadSet = bit_vector.ThreadSet;

// Memory pool for frequently allocated objects
pub const RegexMemoryPool = struct {
    allocator: Allocator,
    thread_sets: std.ArrayListUnmanaged(*ThreadSet),
    bit_vectors: std.ArrayListUnmanaged(*BitVector),
    initialized: bool,

    pub fn init(allocator: Allocator) RegexMemoryPool {
        return RegexMemoryPool{
            .allocator = allocator,
            .thread_sets = .empty,
            .bit_vectors = .empty,
            .initialized = false,
        };
    }

    pub fn deinit(self: *RegexMemoryPool) void {
        // Free all thread sets
        for (self.thread_sets.items) |thread_set| {
            thread_set.deinit();
            self.allocator.destroy(thread_set);
        }
        self.thread_sets.deinit(self.allocator);

        // Free all bit vectors
        for (self.bit_vectors.items) |bv| {
            bv.deinit();
            self.allocator.destroy(bv);
        }
        self.bit_vectors.deinit(self.allocator);
    }

    // Get a thread set from pool or create new one
    pub fn getThreadSet(self: *RegexMemoryPool, size: usize) !*ThreadSet {
        // For now, always create a new thread set since ThreadSet doesn't have capacity field
        // In a more sophisticated implementation, we could track the capacity separately
        const thread_set = try self.allocator.create(ThreadSet);
        thread_set.* = try ThreadSet.init(self.allocator, size);
        try self.thread_sets.append(self.allocator, thread_set);
        return thread_set;
    }

    // Get a bit vector from pool or create new one
    pub fn getBitVector(self: *RegexMemoryPool, size: usize) !*BitVector {
        // Try to find a free bit vector
        for (self.bit_vectors.items) |bv| {
            if (bv.capacity >= size) {
                return bv;
            }
        }

        // Create new bit vector
        const bit_vector_ptr = try self.allocator.create(BitVector);
        bit_vector_ptr.* = try BitVector.init(self.allocator, size);
        try self.bit_vectors.append(self.allocator, bit_vector_ptr);
        return bit_vector_ptr;
    }

    // Reset all objects for reuse (without deallocating)
    pub fn reset(self: *RegexMemoryPool) void {
        // Reset all thread sets
        for (self.thread_sets.items) |thread_set| {
            thread_set.clear();
        }

        // Reset all bit vectors
        for (self.bit_vectors.items) |bv| {
            bv.clear();
        }
    }
};

// Global memory pool instance
var global_pool: RegexMemoryPool = undefined;
var pool_initialized = false;

// Initialize global memory pool
pub fn initGlobalPool(allocator: Allocator) !void {
    if (pool_initialized) return;

    global_pool = RegexMemoryPool.init(allocator);
    pool_initialized = true;
}

// Deinitialize global memory pool
pub fn deinitGlobalPool() void {
    if (!pool_initialized) return;

    global_pool.deinit();
    pool_initialized = false;
}

// Get thread set from global pool
pub fn getGlobalThreadSet(size: usize) !*ThreadSet {
    if (!pool_initialized) return error.PoolNotInitialized;
    return global_pool.getThreadSet(size);
}

// Get bit vector from global pool
pub fn getGlobalBitVector(size: usize) !*BitVector {
    if (!pool_initialized) return error.PoolNotInitialized;
    return global_pool.getBitVector(size);
}

// Reset global pool
pub fn resetGlobalPool() void {
    if (!pool_initialized) return;
    global_pool.reset();
}