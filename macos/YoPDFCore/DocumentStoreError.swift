import Foundation

/// Failures a caller has to tell apart, because each one leads to a different
/// decision in the UI: reopen, grant access, save somewhere else, or stop and
/// let the user resolve a conflict.
///
/// Deliberately not collapsed into a single `saveFailed`: "the file is gone",
/// "someone else changed it" and "the disk refused the write" are not the same
/// situation and must not be presented as one.
public enum DocumentStoreError: Error, Equatable, Sendable {
    case notAFileURL
    case fileMissing(URL)
    case permissionDenied(URL)
    /// The file exists but is not writable (mode, ACL, or read-only volume).
    case readOnly(URL)
    case notReadable(URL, String)
    case sessionClosed
    /// The bytes on disk no longer match the version the session opened.
    case externalModificationDetected(ExternalChange)
    /// `saveAs` without overwrite, and the destination already exists.
    case targetExists(URL)
    case unsupportedFileSituation(UnsupportedFileSituation, URL)
    /// Writing the staging file failed (no space, quota, I/O error).
    case stagingFailed(String)
    /// The staging file was written but could not be committed.
    case replacementFailed(String)
    case coordinationFailed(String)

    /// Maps a POSIX error number to the most specific case available.
    /// `fallback` covers the codes that are specific to the operation that
    /// failed (a read error is not a staging error).
    static func fromPOSIX(
        _ code: Int32,
        url: URL,
        fallback: DocumentStoreError
    ) -> DocumentStoreError {
        switch code {
        case ENOENT, ENOTDIR:
            return .fileMissing(url)
        case EACCES, EPERM:
            return .permissionDenied(url)
        case EROFS:
            return .readOnly(url)
        default:
            return fallback
        }
    }

    static func message(forPOSIX code: Int32) -> String {
        String(cString: strerror(code))
    }
}

extension DocumentStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAFileURL:
            return "That location is not a local file."
        case let .fileMissing(url):
            return "“\(url.lastPathComponent)” could not be found. It may have been moved or deleted."
        case let .permissionDenied(url):
            return "YoPDF does not have permission to use “\(url.lastPathComponent)”."
        case let .readOnly(url):
            return "“\(url.lastPathComponent)” is read-only. Save a copy instead."
        case let .notReadable(url, reason):
            return "“\(url.lastPathComponent)” could not be read: \(reason)"
        case .sessionClosed:
            return "This document is no longer open."
        case .externalModificationDetected(.missing):
            return "The file was removed while it was open. Your changes were not written."
        case .externalModificationDetected(.replaced):
            return "The file was replaced by another app while it was open. Your changes were not written."
        case .externalModificationDetected(.modified):
            return "The file was changed by another app while it was open. Your changes were not written."
        case .externalModificationDetected(.unchanged):
            return "The file could not be verified before saving."
        case let .targetExists(url):
            return "“\(url.lastPathComponent)” already exists."
        case let .unsupportedFileSituation(situation, url):
            let name = url.lastPathComponent
            switch situation {
            case .symbolicLink:
                return "“\(name)” is a symbolic link. YoPDF will not replace the link; save a copy instead."
            case let .hardLink(count):
                return "“\(name)” is linked to \(count) other names. Saving would detach it from them; save a copy instead."
            case .notARegularFile:
                return "“\(name)” is not a regular file."
            case .cloudPlaceholderNotDownloaded:
                return "“\(name)” has not been downloaded from the cloud yet."
            case .sameFileAsCurrent:
                return "Choose a different location from the file that is already open."
            }
        case let .stagingFailed(reason):
            return "The new contents could not be written: \(reason)"
        case let .replacementFailed(reason):
            return "The file could not be replaced safely: \(reason)"
        case let .coordinationFailed(reason):
            return "Another app is using the file: \(reason)"
        }
    }
}
