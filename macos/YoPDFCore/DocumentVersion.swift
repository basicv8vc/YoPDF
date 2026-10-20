import Foundation

/// Identifies one physical file, independent of the path used to reach it.
///
/// Two paths that resolve to the same device/inode pair are the same file;
/// a path that now points at a different inode has been replaced, even if the
/// bytes happen to be identical.
public struct FileIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// The state of a file at one moment.
///
/// `contentHash` is a streaming SHA-256 of the whole file. Size and
/// modification date are kept because they are cheap to read and useful for
/// diagnostics, but they are **not** what decides whether a save is safe:
/// a file can be rewritten with the same size and a restored mtime.
public struct DocumentVersion: Equatable, Sendable {
    public let identity: FileIdentity
    public let size: Int64
    public let modificationDate: Date
    /// Lowercase hexadecimal SHA-256 of the file bytes.
    public let contentHash: String

    public init(
        identity: FileIdentity,
        size: Int64,
        modificationDate: Date,
        contentHash: String
    ) {
        self.identity = identity
        self.size = size
        self.modificationDate = modificationDate
        self.contentHash = contentHash
    }
}

/// How the file on disk differs from the version a session was opened with.
public enum ExternalChange: Equatable, Sendable {
    case unchanged
    /// Same file, different bytes.
    case modified(DocumentVersion)
    /// A different file now occupies the path (new inode).
    case replaced(DocumentVersion)
    /// Nothing is reachable at the path any more.
    case missing
}

/// What the filesystem reports about a path, without reading its contents.
public struct FileStatus: Equatable, Sendable {
    /// A regular file is reachable at the path (through a symlink, if any).
    public let exists: Bool
    public let isRegularFile: Bool
    /// The path itself is a symbolic link.
    public let isSymbolicLink: Bool
    /// `st_nlink` of the resolved file. Greater than one means hard-linked.
    public let linkCount: Int
    public let isWritable: Bool
    /// An iCloud item that has not been downloaded to this device.
    public let isCloudPlaceholder: Bool

    public init(
        exists: Bool,
        isRegularFile: Bool,
        isSymbolicLink: Bool,
        linkCount: Int,
        isWritable: Bool,
        isCloudPlaceholder: Bool
    ) {
        self.exists = exists
        self.isRegularFile = isRegularFile
        self.isSymbolicLink = isSymbolicLink
        self.linkCount = linkCount
        self.isWritable = isWritable
        self.isCloudPlaceholder = isCloudPlaceholder
    }

    /// The state of a path where nothing exists.
    public static let missing = FileStatus(
        exists: false,
        isRegularFile: false,
        isSymbolicLink: false,
        linkCount: 0,
        isWritable: false,
        isCloudPlaceholder: false
    )
}

/// A file layout where writing in place cannot be done without changing
/// something the user did not ask to change. These are refused rather than
/// handled optimistically: a wrong guess here destroys data or breaks links.
public enum UnsupportedFileSituation: Equatable, Sendable {
    /// The path is a symlink. Replacing it would replace the link, not the target.
    case symbolicLink
    /// `st_nlink > 1`. Replacing one name would silently detach it from the others.
    case hardLink(linkCount: Int)
    case notARegularFile
    /// A cloud placeholder whose bytes are not on this device yet.
    case cloudPlaceholderNotDownloaded
    /// `saveAs` was pointed at the file the session already has open.
    case sameFileAsCurrent
}
