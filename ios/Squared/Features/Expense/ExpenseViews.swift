import PhotosUI
import SwiftUI

struct ExpenseDetailView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let expenseId: Int
    @State private var expense: Expense?
    @State private var error: String?
    @State private var showEdit = false
    @State private var group: GroupDetail?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let e = expense {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(e.description).font(Theme.title(28))
                        Text(Format.money(e.amountPaise, e.currency)).font(Theme.number(36))
                        if let oc = e.originalCurrency, let om = e.originalAmountMinor, let r = e.fxRate {
                            Text("\(Format.money(om, oc)) at 1 \(oc) = \(String(format: r >= 1 ? "%.2f" : "%.4f", r)) \(e.currency)")
                                .font(Theme.body(13, .semibold)).foregroundStyle(Theme.coin)
                        }
                        Text("\(e.paidBy == state.user?.id ? "You" : (e.paidByName ?? "")) paid · \(Format.relative(e.createdAt))")
                            .font(Theme.body(13)).foregroundStyle(Theme.muted)
                        if let cat = ExpenseCategory(rawValue: e.category ?? "other"), cat != .other {
                            Label(cat.label, systemImage: cat.icon).font(Theme.body(12, .semibold)).foregroundStyle(Theme.muted)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Split \(splitLabel(e))")
                        ForEach(e.splits, id: \.userId) { s in
                            HStack {
                                Text(s.userId == state.user?.id ? "You" : (s.name ?? "")).font(Theme.body(15))
                                if let detail = splitDetail(e, s.userId) {
                                    Text(detail).font(Theme.body(12)).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Text(Format.money(s.sharePaise, e.currency)).font(Theme.body(15, .bold))
                            }
                            .padding(.vertical, 6)
                            Divider().overlay(Theme.line)
                        }
                    }
                    ReceiptsSection(expenseId: e.id)
                    CommentsSection(expenseId: e.id)
                    ShareLink(item: shareText(e)) {
                        Label("Share with the group", systemImage: "square.and.arrow.up").font(Theme.body(15, .semibold))
                            .frame(maxWidth: .infinity, minHeight: 44).overlay(Rectangle().stroke(Theme.line))
                    }
                    .foregroundStyle(Theme.text)
                    HStack(spacing: 12) {
                        NeoPopButton(title: "Edit", style: .stroke, icon: "pencil", height: 44) { showEdit = true }
                        NeoPopButton(title: "Delete", style: .flatStroke, icon: "trash", height: 44) { Task { await delete() } }
                    }
                } else if let error {
                    Text(error).foregroundStyle(Theme.muted)
                } else {
                    Skeleton(height: 120)
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: state.refreshTick) { Task { await load() } }
        .sheet(isPresented: $showEdit) {
            EditLoader(expense: expense, group: group) { Task { await load() } }
        }
    }

    /// A plain-text summary to paste into the group's WhatsApp, since nobody else has the app.
    private func shareText(_ e: Expense) -> String {
        let lines = e.splits.map { "• \($0.userId == state.user?.id ? "Me" : ($0.name ?? "")): \(Format.money($0.sharePaise, e.currency))" }
        let payer = e.paidBy == state.user?.id ? (state.user?.name ?? "I") : (e.paidByName ?? "")
        return (["\(e.description): \(Format.money(e.amountPaise, e.currency)), paid by \(payer)"] + lines).joined(separator: "\n")
    }

    private func load() async {
        do {
            let e: Expense = try await APIClient.shared.request("GET", "/expenses/\(expenseId)")
            expense = e
            if group == nil { group = try? await APIClient.shared.request("GET", "/groups/\(e.groupId)") }
        } catch { self.error = error.localizedDescription }
    }

    private func splitLabel(_ e: Expense) -> String {
        switch e.splitType ?? "EQUAL" {
        case "EXACT": "· by amount"; case "PERCENT": "· by percent"; case "SHARES": "· by shares"; default: "· equally"
        }
    }

    private func splitDetail(_ e: Expense, _ uid: Int) -> String? {
        let k = String(uid)
        switch e.splitType ?? "EQUAL" {
        case "PERCENT": return e.splitMeta?.percents?[k].map { "\($0.formatted(.number.precision(.fractionLength(0...2))))%" }
        case "SHARES": return e.splitMeta?.shares?[k].map { $0 == $0.rounded() ? "\(Int($0)) share\($0 == 1 ? "" : "s")" : "\($0) shares" }
        default: return nil
        }
    }

    private func delete() async {
        do {
            try await APIClient.shared.raw("DELETE", "/expenses/\(expenseId)")
            state.refreshTick += 1
            dismiss()
        } catch { state.showToast(error.localizedDescription) }
    }
}


/// Presents the expense form once both the expense and its group are available.
private struct EditLoader: View {
    let expense: Expense?
    @State var group: GroupDetail?
    let onSaved: () -> Void

    var body: some View {
        Group {
            if let e = expense, let g = group {
                ExpenseForm(group: g, editing: e, onSaved: onSaved)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
            }
        }
        .task {
            if group == nil, let e = expense {
                group = try? await APIClient.shared.request("GET", "/groups/\(e.groupId)", as: GroupDetail.self)
            }
        }
    }
}


/// Bill photos attached to an expense.
struct ReceiptsSection: View {
    @Environment(AppState.self) private var state
    let expenseId: Int
    @State private var items: [Attachment] = []
    @State private var images: [String: UIImage] = [:]
    @State private var picker: PhotosPickerItem?
    @State private var viewing: String?
    @State private var uploading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Receipts")
                Spacer()
                PhotosPicker(selection: $picker, matching: .images) {
                    Label(uploading ? "Uploading…" : "Add photo", systemImage: "camera").font(Theme.body(13, .bold))
                }
                .foregroundStyle(Theme.text)
            }
            if items.isEmpty {
                Text("No bill attached.").font(Theme.body(13)).foregroundStyle(Theme.muted)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(items) { a in
                            Button { viewing = a.id } label: {
                                Group {
                                    if let img = images[a.id] { Image(uiImage: img).resizable().scaledToFill() }
                                    else if a.contentType == "application/pdf" { Image(systemName: "doc.richtext").font(.system(size: 26)) }
                                    else { ProgressView() }
                                }
                                .frame(width: 84, height: 84).clipped().background(Theme.surfaceHigh)
                                .overlay(Rectangle().stroke(Theme.line))
                            }
                            .accessibilityLabel("Receipt photo")
                        }
                    }
                }
            }
        }
        .task { await load() }
        .onChange(of: picker) { _, item in Task { await upload(item) } }
        .fullScreenCover(item: Binding(get: { viewing.map { IdBox(id: $0) } }, set: { viewing = $0?.id })) { box in
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                if let img = images[box.id] { Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
                VStack(spacing: 12) {
                    Button { viewing = nil } label: { Image(systemName: "xmark").font(.system(size: 18, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44) }
                    Button { Task { await delete(box.id) } } label: { Image(systemName: "trash").foregroundStyle(.white).frame(width: 44, height: 44) }
                        .accessibilityLabel("Delete photo")
                }
                .padding()
            }
        }
    }

    private func load() async {
        guard let r: AttachmentsResponse = try? await APIClient.shared.request("GET", "/expenses/\(expenseId)/attachments") else { return }
        items = r.attachments
        for a in items where images[a.id] == nil && a.contentType.hasPrefix("image") {
            if let d = try? await APIClient.shared.raw("GET", "/attachments/\(a.id)"), let img = UIImage(data: d) { images[a.id] = img }
        }
    }

    private func upload(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data),
              let jpeg = img.jpegData(compressionQuality: 0.7) else { return }
        uploading = true
        defer { uploading = false }
        do { try await APIClient.shared.upload("/expenses/\(expenseId)/attachments", data: jpeg, contentType: "image/jpeg"); await load() }
        catch { state.showToast(error.localizedDescription) }
    }

    private func delete(_ id: String) async {
        do { try await APIClient.shared.raw("DELETE", "/attachments/\(id)"); viewing = nil; images[id] = nil; await load() }
        catch { state.showToast("Only the person who added a photo can remove it") }
    }
}

struct IdBox: Identifiable { let id: String }

/// Conversation about one expense ("was this for both weeks?").
struct CommentsSection: View {
    @Environment(AppState.self) private var state
    let expenseId: Int
    @State private var comments: [Comment] = []
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Comments")
            ForEach(comments) { c in
                HStack(alignment: .top, spacing: 10) {
                    Avatar(name: c.isYou ? "You" : (c.name ?? "?"), size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(c.isYou ? "You" : (c.name ?? "")).font(Theme.body(13, .bold))
                            Text(Format.relative(c.createdAt)).font(Theme.body(11)).foregroundStyle(Theme.muted)
                        }
                        Text(c.body).font(Theme.body(14))
                    }
                    Spacer()
                    if c.isYou {
                        Button { Task { await delete(c) } } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 32, height: 32) }
                            .foregroundStyle(Theme.muted).accessibilityLabel("Delete comment")
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Add a comment", text: $draft, axis: .vertical).lineLimit(1...3)
                    .padding(10).background(Theme.surface).overlay(Rectangle().stroke(Theme.line))
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .black)).foregroundStyle(Theme.bg)
                        .frame(width: 40, height: 40).background(Theme.text)
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Post comment")
            }
        }
        .task { await load() }
    }

    private func load() async {
        if let r: CommentsResponse = try? await APIClient.shared.request("GET", "/expenses/\(expenseId)/comments") { comments = r.comments }
    }

    private func send() async {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let r: CommentsResponse = try? await APIClient.shared.request("POST", "/expenses/\(expenseId)/comments", body: ["body": t]) {
            comments = r.comments
            draft = ""
        }
    }

    private func delete(_ c: Comment) async {
        try? await APIClient.shared.raw("DELETE", "/comments/\(c.id)")
        await load()
    }
}
