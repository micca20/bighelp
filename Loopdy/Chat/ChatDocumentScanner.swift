import SwiftUI
import UIKit
import VisionKit

/// The system scanner owns capture, page correction, reordering and cancellation.
/// Saving only prepares a local PDF. The normal composer owns eventual sending.
struct ChatDocumentScanner: UIViewControllerRepresentable {
    let onResult: (Result<ChatAttachment, Error>?) -> Void

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        private let onResult: (Result<ChatAttachment, Error>?) -> Void
        private var completed = false
        init(onResult: @escaping (Result<ChatAttachment, Error>?) -> Void) { self.onResult = onResult }

        func finish(_ result: Result<ChatAttachment, Error>?) {
            guard !completed else { return }
            completed = true
            onResult(result)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            finish(Result {
                try ChatScannedDocument.attachment(pageCount: scan.pageCount) { scan.imageOfPage(at: $0) }
            })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { finish(nil) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            finish(.failure(ChatScannedDocument.ScanError.captureFailed))
        }
    }
}

@MainActor
enum ChatScannedDocument {
    static let maximumPages = 20
    enum ScanError: LocalizedError {
        case invalidPages, invalidImage, captureFailed
        var errorDescription: String? {
            switch self {
            case .invalidPages: "Scan between 1 and 20 pages in one document."
            case .invalidImage: "A scanned page could not be read. Please scan it again."
            case .captureFailed: "The document scanner could not finish. Please try again."
            }
        }
    }

    static func attachment(pageCount: Int, image: (Int) -> UIImage) throws -> ChatAttachment {
        guard (1...maximumPages).contains(pageCount) else { throw ScanError.invalidPages }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        var invalidImage = false
        let data = renderer.pdfData { context in
            for index in 0..<pageCount {
                autoreleasepool {
                    let page = image(index)
                    guard page.size.width.isFinite, page.size.height.isFinite,
                          page.size.width >= 1, page.size.height >= 1,
                          page.size.width / page.size.height <= 20,
                          page.size.height / page.size.width <= 20 else {
                        invalidImage = true
                        return
                    }
                    // Bound raster work while keeping enough detail for printed text.
                    let ratio = min(1, 2_200 / max(page.size.width, page.size.height))
                    let size = CGSize(width: page.size.width * ratio, height: page.size.height * ratio)
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    format.opaque = true
                    let prepared = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                        UIColor.white.setFill()
                        UIRectFill(CGRect(origin: .zero, size: size))
                        page.draw(in: CGRect(origin: .zero, size: size))
                    }
                    let paper = CGRect(x: 0, y: 0, width: 612, height: 612 * size.height / size.width)
                    context.beginPage(withBounds: paper, pageInfo: [:])
                    prepared.draw(in: paper)
                }
            }
        }
        guard !invalidImage else { throw ScanError.invalidImage }
        return try ChatAttachment(id: "attachment_" + UUID().uuidString.lowercased(),
            fileName: "Scanned document.pdf", mimeType: "application/pdf", data: data)
    }
}
