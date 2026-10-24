import Foundation
import PDFKit

/// An isolated PDFKit copy that can cross to the automatic-save worker.
///
/// The copy is made on the main actor, then only the worker accesses it. The
/// displayed document and its PDFView remain on the main actor and can continue
/// responding to edits and navigation while the snapshot is serialized.
struct PDFDocumentSaveSnapshot: @unchecked Sendable {
    let document: PDFDocument
}

/// PDF serialization for an immutable save snapshot.
///
/// This type is deliberately not main-actor isolated. The automatic-save worker
/// owns its copied `PDFDocument` exclusively while it adds temporary Shua
/// identity keys and serializes the PDF.
enum PDFDocumentSaveSerializer {

    private struct ShuaThoughtIdentity: Equatable {
        let anchorID: UUID
        let thoughtID: UUID

        var persistenceValue: String {
            "\(anchorID.uuidString):\(thoughtID.uuidString)"
        }
    }

    private struct ShuaThoughtMetadata: Decodable {
        struct Anchor: Decodable {
            struct MarkerPosition: Decodable {
                let x: Double
                let y: Double
            }

            let id: UUID
            let excerpt: String?
            let isPageLevel: Bool?
            let markerPosition: MarkerPosition?
        }

        let version: Int
        let anchor: Anchor
        let thoughtID: UUID
        let thoughtOrder: Int

        var identity: ShuaThoughtIdentity {
            ShuaThoughtIdentity(anchorID: anchor.id, thoughtID: thoughtID)
        }
    }

    private static let shuaThoughtMetadataKey = PDFAnnotationKey(rawValue: "ShuaThoughtMetadata")
    private static let shuaIdentityPersistenceKey = PDFAnnotationKey(rawValue: "/YoPDFShuaThoughtIdentity")
    private static let shuaAnchorPersistenceKey = PDFAnnotationKey(rawValue: "/YoPDFShuaAnchorID")

    /// Preserves Shua identities through PDFKit's `/NM` loss on write.
    ///
    /// Name-only annotations use a temporary anchor cache. If `/NM` conflicts
    /// with valid embedded metadata, a second temporary key preserves the full
    /// name identity so the conflict remains detectable after serialization.
    /// The keys are set only on the worker's private document copy.
    static func dataRepresentationPreservingShuaGroups(
        in document: PDFDocument
    ) -> Data? {
        var previousValues: [(PDFAnnotation, PDFAnnotationKey, Any?)] = []
        defer {
            for (annotation, key, value) in previousValues {
                if let value {
                    _ = annotation.setValue(value, forAnnotationKey: key)
                } else {
                    annotation.removeValue(forAnnotationKey: key)
                }
            }
        }

        func temporarilySet(
            _ value: String?,
            for key: PDFAnnotationKey,
            on annotation: PDFAnnotation
        ) -> Bool {
            previousValues.append((annotation, key, annotation.value(forAnnotationKey: key)))
            if let value {
                return annotation.setValue(value, forAnnotationKey: key)
            }
            annotation.removeValue(forAnnotationKey: key)
            return true
        }

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                let nameIdentity = shuaThoughtIdentityFromName(of: annotation)
                let persistedIdentity = shuaThoughtIdentityFromPersistence(of: annotation)
                let metadata = shuaThoughtMetadata(of: annotation)

                if let metadata {
                    if let nameIdentity {
                        if nameIdentity != metadata.identity {
                            if persistedIdentity != nameIdentity {
                                guard temporarilySet(
                                    nameIdentity.persistenceValue,
                                    for: shuaIdentityPersistenceKey,
                                    on: annotation
                                ) else { return nil }
                            }
                        } else if annotation.value(forAnnotationKey: shuaIdentityPersistenceKey) != nil {
                            guard temporarilySet(nil, for: shuaIdentityPersistenceKey, on: annotation)
                            else { return nil }
                        }
                    } else if persistedIdentity == metadata.identity,
                              annotation.value(forAnnotationKey: shuaIdentityPersistenceKey) != nil {
                        guard temporarilySet(nil, for: shuaIdentityPersistenceKey, on: annotation)
                        else { return nil }
                    }
                }

                guard let nameIdentity,
                      (annotation.value(forAnnotationKey: shuaAnchorPersistenceKey) as? String)
                        .flatMap(UUID.init(uuidString:)) != nameIdentity.anchorID
                else { continue }

                guard temporarilySet(
                    nameIdentity.anchorID.uuidString,
                    for: shuaAnchorPersistenceKey,
                    on: annotation
                ) else { return nil }
            }
        }
        return document.dataRepresentation()
    }

    private static func shuaThoughtMetadata(
        of annotation: PDFAnnotation
    ) -> ShuaThoughtMetadata? {
        guard isTextAnnotation(annotation),
              let raw = annotation.value(forAnnotationKey: shuaThoughtMetadataKey) as? String,
              let data = raw.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(ShuaThoughtMetadata.self, from: data),
              metadata.version == 1,
              metadata.thoughtOrder >= 0
        else { return nil }
        return metadata
    }

    private static func shuaThoughtIdentityFromName(
        of annotation: PDFAnnotation
    ) -> ShuaThoughtIdentity? {
        guard isTextAnnotation(annotation),
              let name = annotation.value(forAnnotationKey: .name) as? String
        else { return nil }
        let parts = name.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "shua-thought",
              let anchorID = UUID(uuidString: String(parts[1])),
              let thoughtID = UUID(uuidString: String(parts[2]))
        else { return nil }
        return ShuaThoughtIdentity(anchorID: anchorID, thoughtID: thoughtID)
    }

    private static func shuaThoughtIdentityFromPersistence(
        of annotation: PDFAnnotation
    ) -> ShuaThoughtIdentity? {
        guard isTextAnnotation(annotation),
              let raw = annotation.value(forAnnotationKey: shuaIdentityPersistenceKey) as? String
        else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let anchorID = UUID(uuidString: String(parts[0])),
              let thoughtID = UUID(uuidString: String(parts[1]))
        else { return nil }
        return ShuaThoughtIdentity(anchorID: anchorID, thoughtID: thoughtID)
    }

    private static func isTextAnnotation(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "Text" || annotation.type == "/Text"
    }
}
