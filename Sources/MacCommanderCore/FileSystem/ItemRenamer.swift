import Foundation

public enum RenameError: Error, Equatable {
    case emptyName
    case invalidCharacter
    case nameTaken(String)
    case underlying(String)

    public var message: String {
        switch self {
        case .emptyName:
            return L10n.string("fileList.rename.emptyName", "The name cannot be empty.")
        case .invalidCharacter:
            return L10n.string("fileList.rename.invalidCharacter", "The name cannot contain “/” or “:”.")
        case .nameTaken(let name):
            return L10n.format("fileList.rename.nameTaken", "The name “%@” is already taken. Please choose a different name.", name)
        case .underlying(let text):
            return text
        }
    }
}

public enum ItemRenamer {
    public static func rename(
        _ url: URL, to newName: String, fileManager: FileManager = .default
    ) throws(RenameError) -> URL {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw .emptyName }
        if name.contains("/") || name.contains(":") { throw .invalidCharacter }
        let oldName = url.lastPathComponent
        if name == oldName { return url }

        let parent = url.deletingLastPathComponent()
        let target = parent.appendingPathComponent(name)
        let caseOnly = name.compare(oldName, options: [.caseInsensitive]) == .orderedSame

        do {
            if caseOnly {
                // On case-insensitive volumes the target "exists" (it is the source), so go via a temp name.
                let temp = parent.appendingPathComponent(".\(oldName).mc-rename-\(UUID().uuidString)")
                try fileManager.moveItem(at: url, to: temp)
                do {
                    try fileManager.moveItem(at: temp, to: target)
                } catch {
                    try? fileManager.moveItem(at: temp, to: url)
                    throw error
                }
            } else {
                if fileManager.fileExists(atPath: target.path) { throw RenameError.nameTaken(name) }
                try fileManager.moveItem(at: url, to: target)
            }
        } catch let error as RenameError {
            throw error
        } catch {
            throw .underlying(error.localizedDescription)
        }
        return target
    }
}
