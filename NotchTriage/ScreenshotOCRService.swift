import AppKit
import SwiftUI
import Vision

enum ScreenshotOCRService {
    /// Prefer the bitmap representation’s real pixels — never `NSImage.cgImage(forProposedRect:)`,
    /// which on Retina pasteboard images often samples a shifted / wrong region.
    static func cgImage(from image: NSImage) -> CGImage? {
        if let bitmap = image.representations.first(where: { $0 is NSBitmapImageRep }) as? NSBitmapImageRep,
           let cg = bitmap.cgImage {
            return cg
        }
        for rep in image.representations {
            var rect = CGRect(origin: .zero, size: rep.size)
            if let cg = rep.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                return cg
            }
        }
        var proposed = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }

    static func recognizeText(in image: NSImage) async throws -> String {
        guard let cgImage = cgImage(from: image) else {
            throw OCRError.invalidImage
        }
        return try await recognizeText(in: cgImage)
    }

    static func recognizeText(in cgImage: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .sorted { lhs, rhs in
                        // Vision normalizes Y bottom-up; sort top→bottom, then left→right.
                        if abs(lhs.boundingBox.minY - rhs.boundingBox.minY) > 0.02 {
                            return lhs.boundingBox.minY > rhs.boundingBox.minY
                        }
                        return lhs.boundingBox.minX < rhs.boundingBox.minX
                    }
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            // Correction can invent nearby words; keep raw recognition for screenshots.
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    enum OCRError: LocalizedError {
        case invalidImage
        case empty

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "无法读取图片"
            case .empty: return "未识别到文字"
            }
        }
    }
}
