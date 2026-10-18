import AvoKit
import Foundation

/// The engine's GPU shader cache on disk (avo-vmm's
/// `engine/hvf/vmm/src/virtio/gpu/cache.rs`, docs/engine.md "GPU").
///
/// In GPU mode avo-vmm points Metal's shader cache at
/// `~/Library/Caches/Avo/gpu-cache/<emulator>_<driver>_<gpu>_macos-<build>/metal`
/// before gfxstream starts. A shader's first use otherwise costs about
/// 100 ms of Metal compiling (measured: 150 programs took 15 s cold and
/// 0.8 s from the cache), which no cache in Android can save. The engine
/// limits each Metal cache file to 512 MiB, keeps the whole folder under
/// 2 GiB and drops keys of other emulators or macOS builds; clearing is for
/// trouble (a driver bug baked into cached shaders) or disk space.
///
/// Android's own per-app caches (GLSL and MoltenVK's MSL, in each app's
/// `cache/com.android.opengl.shaders_cache.multifile`) stay: they are
/// Android app data, gone with the app's storage or Reset Android.
public enum GPUCache {
    public static func directory(home: URL) -> URL {
        home.appending(path: "Library/Caches/Avo/gpu-cache", directoryHint: .isDirectory)
    }

    /// Bytes of the files under `url` (0 when it is missing).
    static func size(of url: URL, fileManager: FileManager = .default) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let files = fileManager.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    public static func status(home: URL, fileManager: FileManager = .default) -> GPUCacheStatus {
        let url = directory(home: home)
        return GPUCacheStatus(path: url.path, bytes: size(of: url, fileManager: fileManager))
    }

    /// Empties the cache. A running engine keeps the shaders it has already
    /// loaded (and writes new ones into files that are gone); the next start
    /// compiles everything again.
    public static func clear(home: URL, fileManager: FileManager = .default) throws -> GPUCacheStatus {
        let url = directory(home: home)
        let before = size(of: url, fileManager: fileManager)
        if fileManager.fileExists(atPath: url.path) {
            for item in try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try fileManager.removeItem(at: item)
            }
        }
        let after = size(of: url, fileManager: fileManager)
        return GPUCacheStatus(path: url.path, bytes: after, clearedBytes: max(0, before - after))
    }
}
