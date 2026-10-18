import Foundation

/// The engine's GPU shader cache (docs/engine.md, "GPU", shader cache):
/// what Metal compiled for Android's apps in GPU mode, kept between starts
/// in `~/Library/Caches/Avo/gpu-cache` so a shader's first use is slow only
/// once. Graphics › "Clear GPU cache" (`clearGPUCache`, `avoctl gpu-cache
/// clear`) empties it.
public struct GPUCacheStatus: Codable, Sendable, Equatable {
    /// The cache folder.
    public var path: String
    /// Bytes in it now.
    public var bytes: Int64
    /// What a clear removed (only in `clearGPUCache`'s reply).
    public var clearedBytes: Int64?

    public init(path: String, bytes: Int64, clearedBytes: Int64? = nil) {
        self.path = path
        self.bytes = bytes
        self.clearedBytes = clearedBytes
    }
}
