import Foundation

public enum NameGenerator {
    /// Returns `base[.ext]`, or `base 2[.ext]`, `base 3[.ext]`, … — the first name not present in `directory`.
    public static func uniqueName(
        base: String, pathExtension: String?, in directory: URL, fileManager: FileManager = .default
    ) -> String {
        func name(_ n: Int) -> String {
            let stem = n == 1 ? base : "\(base) \(n)"
            guard let pathExtension else { return stem }
            return "\(stem).\(pathExtension)"
        }
        var n = 1
        // attributesOfItem uses lstat, so dangling symlinks count as taken.
        while (try? fileManager.attributesOfItem(atPath: directory.appendingPathComponent(name(n)).path)) != nil {
            n += 1
        }
        return name(n)
    }
}
