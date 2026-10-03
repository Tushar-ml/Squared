import UIKit
import Vision

/// On-device receipt reading (Apple Vision). Nothing leaves the phone until the user saves.
enum ReceiptScanner {
    struct Result { var amount: String?; var merchant: String? }

    static func read(_ image: UIImage) async -> Result {
        guard let cg = image.cgImage else { return Result() }
        let lines: [String] = await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { req, _ in
                let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
                // top-to-bottom reading order
                let sorted = obs.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                cont.resume(returning: sorted.compactMap { $0.topCandidates(1).first?.string })
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req]) } catch { cont.resume(returning: []) }
        }
        return parse(lines)
    }

    /// Prefer the number on a "total" line; otherwise the largest money-looking number.
    static func parse(_ lines: [String]) -> Result {
        let money = try! NSRegularExpression(pattern: #"(?:₹|rs\.?|inr|\$|€|£)?\s*([0-9]{1,3}(?:[,][0-9]{2,3})*(?:\.[0-9]{1,2})|[0-9]+(?:\.[0-9]{1,2})?)"#,
                                             options: [.caseInsensitive])
        func amounts(_ s: String) -> [Double] {
            money.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
                Range(m.range(at: 1), in: s).flatMap { Double(s[$0].replacingOccurrences(of: ",", with: "")) }
            }
        }
        let keywords = ["grand total", "total amount", "amount payable", "net amount", "total", "amount due", "to pay"]
        var best: Double?
        for (i, line) in lines.enumerated() {
            let l = line.lowercased()
            guard keywords.contains(where: l.contains), !l.contains("subtotal"), !l.contains("sub total") else { continue }
            let here = amounts(line) + (i + 1 < lines.count ? amounts(lines[i + 1]) : [])
            if let v = here.filter({ $0 > 0 }).max() { best = max(best ?? 0, v) }
        }
        if best == nil {
            best = lines.flatMap(amounts).filter { $0 > 0 && $0 < 10_000_000 }.max()
        }
        let merchant = lines.first { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.count >= 3 && t.rangeOfCharacter(from: .letters) != nil && amounts(t).isEmpty
        }
        let amountText = best.map { $0 == $0.rounded() ? String(Int($0)) : String(format: "%.2f", $0) }
        return Result(amount: amountText, merchant: merchant?.trimmingCharacters(in: .whitespaces))
    }
}
