import UIKit
import UserNotifications

/// On-device notifications (recurring bills added, budget alerts). Nothing is sent from a server.
enum LocalNotify {
    static func post(title: String, body: String) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

/// Monthly statement as a PDF, drawn on the device.
enum ReportPDF {
    static func render(title: String, subtitle: String, header: [String], rows: [[String]], payments: [String], owed: [String]) -> Data {
        let page = CGRect(x: 0, y: 0, width: 842, height: 595)          // A4 landscape, points
        let margin: CGFloat = 36
        let titleFont = UIFont.boldSystemFont(ofSize: 18), bold = UIFont.boldSystemFont(ofSize: 9), body = UIFont.systemFont(ofSize: 9)
        let colCount = max(header.count, 1)
        let descWidth: CGFloat = 200
        let other = (page.width - 2 * margin - descWidth) / CGFloat(max(colCount - 1, 1))
        func x(_ i: Int) -> CGFloat { i <= 1 ? margin + (i == 0 ? 0 : other) : margin + other + descWidth + CGFloat(i - 2) * other }
        func w(_ i: Int) -> CGFloat { i == 1 ? descWidth : other }

        return UIGraphicsPDFRenderer(bounds: page).pdfData { ctx in
            var y: CGFloat = 0
            func newPage() { ctx.beginPage(); y = margin }
            func text(_ s: String, _ f: UIFont, at p: CGPoint, width: CGFloat, color: UIColor = .black) {
                (s as NSString).draw(in: CGRect(x: p.x, y: p.y, width: width - 4, height: 14),
                                     withAttributes: [.font: f, .foregroundColor: color])
            }
            func need(_ h: CGFloat) { if y + h > page.height - margin { newPage() } }
            func line(_ s: String, _ f: UIFont = body, gap: CGFloat = 14) { need(gap); text(s, f, at: CGPoint(x: margin, y: y), width: page.width - 2 * margin); y += gap }
            func headerRow() {
                need(16)
                UIColor(white: 0.07, alpha: 1).setFill()
                UIRectFill(CGRect(x: margin, y: y - 2, width: page.width - 2 * margin, height: 15))
                for (i, h) in header.enumerated() { text(h, bold, at: CGPoint(x: x(i), y: y), width: w(i), color: .white) }
                y += 16
            }
            newPage()
            line(title, titleFont, gap: 26)
            line(subtitle, gap: 22)
            line("Expenses", bold, gap: 16)
            headerRow()
            for r in rows {
                if y + 14 > page.height - margin { newPage(); headerRow() }
                for (i, c) in r.enumerated() { text(c, body, at: CGPoint(x: x(i), y: y), width: w(i)) }
                y += 14
            }
            y += 10
            if !payments.isEmpty { line("Payments", bold, gap: 16); payments.forEach { line($0) }; y += 10 }
            line("Still owed today", bold, gap: 16)
            owed.forEach { line($0) }
        }
    }
}
