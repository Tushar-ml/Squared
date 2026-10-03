import Observation
import SwiftUI

/// Live rates cache for the session (server caches upstream for an hour).
@MainActor
@Observable
final class FxStore {
    static let shared = FxStore()
    var currencies: [CurrencyInfo] = []
    private(set) var rates: [String: FxRates] = [:]   // keyed by base
    var unavailable = false

    func loadCurrencies() async {
        guard currencies.isEmpty else { return }
        if let r: CurrenciesResponse = try? await APIClient.shared.request("GET", "/fx/currencies") { currencies = r.currencies }
    }

    func rates(base: String) async -> FxRates? {
        if let r = rates[base] { return r }
        do {
            let r: FxRates = try await APIClient.shared.request("GET", "/fx/rates?base=\(base)")
            rates[base] = r
            unavailable = false
            return r
        } catch {
            unavailable = true
            return nil
        }
    }

    /// Rate to convert 1 unit of `from` into `to`, or nil while loading/unavailable.
    func rate(_ from: String, _ to: String) -> Double? {
        if from == to { return 1 }
        if let r = rates[from]?.rates[to] { return r }
        if let inv = rates[to]?.rates[from], inv > 0 { return 1 / inv }   // one fetch per reference currency
        return nil
    }
}

struct CurrencyPicker: View {
    @Environment(\.dismiss) private var dismiss
    let selected: String
    let reference: String          // show rates against this (the group currency)
    let onPick: (String) -> Void
    @State private var query = ""
    private var fx: FxStore { FxStore.shared }

    var body: some View {
        NavigationStack {
            List {
                if fx.unavailable {
                    Text("Live rates are unavailable right now. You can still pick a currency; we'll convert when you save.")
                        .font(Theme.body(13)).foregroundStyle(Theme.muted).listRowBackground(Theme.bg)
                }
                ForEach(filtered) { c in
                    Button { onPick(c.code); dismiss() } label: {
                        HStack(spacing: 12) {
                            Text(c.symbol ?? c.code.prefix(1).description)
                                .font(.system(size: 15, weight: .heavy)).frame(width: 34, height: 34).background(Theme.surfaceHigh)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.code).font(Theme.body(15, .bold))
                                Text(c.name).font(Theme.body(12)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            if c.code != reference, let r = fx.rate(c.code, reference) {
                                Text("1 = \(rateText(r)) \(reference)").font(Theme.body(12, .semibold)).foregroundStyle(Theme.muted)
                            }
                            if c.code == selected { Image(systemName: "checkmark").font(.system(size: 13, weight: .black)) }
                        }
                        .frame(minHeight: 44)
                    }
                    .foregroundStyle(Theme.text)
                    .listRowBackground(Theme.surface)
                }
                if let r = fx.rates[reference] {
                    Text("Live rates from \(r.source ?? "provider")\(r.stale ? " (last known)" : ""), updated \(Format.relative(r.asOf))")
                        .font(Theme.body(11)).foregroundStyle(Theme.muted).listRowBackground(Theme.bg)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .searchable(text: $query, prompt: "Search currencies")
            .navigationTitle("Currency")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .task {
            await fx.loadCurrencies()
            _ = await fx.rates(base: reference)   // other directions are inverted from this one
        }
    }

    private var filtered: [CurrencyInfo] {
        let q = query.lowercased()
        let list = q.isEmpty ? fx.currencies : fx.currencies.filter { $0.code.lowercased().contains(q) || $0.name.lowercased().contains(q) }
        // group currency and the common travel currencies first
        let pinned = [reference, "USD", "EUR", "GBP", "AED"]
        return list.sorted { (pinned.firstIndex(of: $0.code) ?? 99, $0.code) < (pinned.firstIndex(of: $1.code) ?? 99, $1.code) }
    }

    private func rateText(_ r: Double) -> String {
        r >= 100 ? String(format: "%.0f", r) : r >= 1 ? String(format: "%.2f", r) : String(format: "%.4f", r)
    }
}
