import SwiftUI

struct AIConnectionUsageSection: View {
    let presentation: AIUsagePresentation
    let refresh: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    var body: some View {
        if presentation != .hidden {
            VStack(alignment: .leading, spacing: 14) {
                switch presentation {
                case .hidden:
                    EmptyView()
                case .linkOnly(let url, let name):
                    heading
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            if let name { Text("在 \(name) 查看") }
                            else { Text("在服务控制台查看余额") }
                            Image(systemName: "arrow.up.right").accessibilityHidden(true)
                        }.frame(minHeight: 44).contentShape(.rect)
                    }
                    .foregroundStyle(Color(uiColor: theme.accent))
                case .configure(let url):
                    heading
                    note("配置凭据后可查询。")
                    consoleLink(url)
                case .query(let state, let url):
                    TimelineView(.explicit(updateDates(for: state))) { context in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                heading
                                Spacer(minLength: 8)
                                refreshControl(state, now: context.date)
                            }
                            queryContent(state, now: context.date)
                        }
                    }
                    consoleLink(url)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 22))
            .accessibilityIdentifier("aiConnectionUsage")
        }
    }

    private var heading: some View {
        Text("余额与额度").font(.headline).accessibilityAddTraits(.isHeader)
    }

    private func refreshControl(_ state: AIUsageQueryState, now: Date) -> some View {
        Group {
            if case .loading(let previous) = state {
                ProgressView()
                    .accessibilityLabel(previous == nil ? Text("正在查询…") : Text("正在刷新…"))
            } else {
                Button(action: refresh) {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color(uiColor: theme.accent))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .disabled(!state.canRefresh(at: now))
                .accessibilityIdentifier("refreshAIConnectionUsage")
            }
        }.frame(minWidth: 44, minHeight: 44)
    }

    private func updateDates(for state: AIUsageQueryState) -> [Date] {
        let now = Date.now
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        return [now] + [state.snapshot?.staleAt, state.retryAt, state.snapshot == nil ? nil : tomorrow]
            .compactMap { $0 }.filter { $0 > now }.sorted()
    }

    private func queryContent(_ state: AIUsageQueryState, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = state.snapshot {
                metrics(snapshot.usage)
                lastUpdated(snapshot.fetchedAt, now: now)
                if now >= snapshot.staleAt { note("数据可能已过期，请刷新。") }
            }

            switch state {
            case .idle, .ready, .loading:
                EmptyView()
            case .failed(let error, let previous):
                failure(error, hasPrevious: previous != nil, now: now)
            }
        }
    }

    @ViewBuilder private func metrics(_ usage: AIUsageSnapshot.Usage) -> some View {
        switch usage {
        case .wallet(let wallets, let available):
            ForEach(wallets, id: \.currency) { wallet in
                amount("可用余额", wallet.total, currency: wallet.currency, prominent: true)
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(wallets, id: \.currency) { wallet in
                        VStack(alignment: .leading, spacing: 8) {
                            balanceRow("充值余额", wallet.toppedUp, currency: wallet.currency)
                            balanceRow("赠送余额", wallet.granted, currency: wallet.currency)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("余额组成").font(.subheadline)
            }
            .tint(Color(uiColor: theme.accent))
            if !available { note("服务报告余额不足以调用 API，请到控制台确认。") }
        case .keyLimit(let limit, let cumulative, let reset, let includesBYOK):
            switch limit {
            case .unlimited:
                Text("当前 Key 未设置限额").font(.subheadline.weight(.semibold))
            case .limited(let limit, let remaining):
                if let remaining {
                    amount("当前 Key 限额剩余", remaining, currency: "USD", prominent: true)
                } else {
                    metric("当前 Key 限额剩余", value: Text("未提供"))
                }
                amount("Key 限额", limit, currency: "USD")
            }
            amount("累计使用额", cumulative, currency: "USD")
            switch reset {
            case .daily: metric("限额重置", value: Text("每日"))
            case .weekly: metric("限额重置", value: Text("每周"))
            case .monthly: metric("限额重置", value: Text("每月"))
            case .none: metric("限额重置", value: Text("不重置"))
            case .unknown: note("重置规则请查看控制台。")
            }
            if let includesBYOK {
                note(includesBYOK ? "Key 限额包含自带 API Key 的消耗。" : "Key 限额不含自带 API Key 的消耗。")
            }
            note("仅为当前 Key 的限额，不代表账户余额；账户及组织限制仍适用。")
        case .gateway(let balance, let cumulative):
            amount("可用余额", balance, currency: "USD", prominent: true)
            amount("累计使用额", cumulative, currency: "USD")
            note("此连接所属团队的 AI Gateway 额度。")
        }
    }

    private func amount(_ title: LocalizedStringKey, _ amount: Decimal, currency: String, prominent: Bool = false) -> some View {
        metric(title, value: currencyText(amount, code: currency), prominent: prominent)
    }

    private func balanceRow(_ title: LocalizedStringKey, _ amount: Decimal, currency: String) -> some View {
        LabeledContent {
            currencyText(amount, code: currency).monospacedDigit()
                .foregroundStyle(Color(uiColor: theme.ink))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            note(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func currencyText(_ amount: Decimal, code: String) -> Text {
        Text(amount, format: .currency(code: code).precision(.fractionLength(2)).locale(locale))
    }

    private func metric(_ title: LocalizedStringKey, value: Text, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            note(title)
            value.font(prominent ? .title2.weight(.semibold) : .body).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }

    private func lastUpdated(_ date: Date, now: Date) -> some View {
        let time = date.formatted(.dateTime.hour().minute().locale(locale))
        let full = date.formatted(.dateTime.year().month().day().hour().minute().locale(locale))
        return Group {
            if calendar.isDate(date, inSameDayAs: now) { note("更新于 今天 \(time)") }
            else { note("更新于 \(full)") }
        }.accessibilityLabel(Text("更新于 \(full)"))
    }

    @ViewBuilder private func failure(_ error: AIUsageFailure, hasPrevious: Bool, now: Date) -> some View {
        switch error {
        case .temporary:
            note(hasPrevious ? "更新失败，显示上次结果。请检查网络后重试。" : "暂时无法查询，请重试。")
        case .unauthorized:
            note(hasPrevious ? "余额查询未获授权，显示上次结果。请到控制台确认。" : "余额查询未获授权，请到控制台确认。")
        case .rateLimited(let retryAt):
            note(hasPrevious ? "查询过于频繁，显示上次结果。" : "查询过于频繁，请稍后重试。")
            if retryAt > now {
                let format: Date.FormatStyle = calendar.isDate(retryAt, inSameDayAs: now)
                    ? .dateTime.hour().minute().second() : .dateTime.year().month().day().hour().minute()
                note("可重试时间：\(retryAt.formatted(format.locale(locale)))")
            }
        case .unreadable:
            note(hasPrevious ? "暂时无法读取服务数据，显示上次结果。可到控制台查看。" : "暂时无法读取服务数据，可到控制台查看。")
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func consoleLink(_ url: URL) -> some View {
        Link(destination: url) {
            Label("打开服务控制台", systemImage: "arrow.up.right").frame(minHeight: 44)
                .contentShape(.rect)
        }.foregroundStyle(Color(uiColor: theme.accent))
    }
}
