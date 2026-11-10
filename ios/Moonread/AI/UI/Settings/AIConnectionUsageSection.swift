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
                Text("余额与额度").font(.headline).accessibilityAddTraits(.isHeader)
                switch presentation {
                case .hidden:
                    EmptyView()
                case .linkOnly(let destination):
                    Text("该服务不提供余额查询").font(.subheadline)
                    switch destination {
                    case .console(let url):
                        note("请在服务控制台查看。")
                        consoleLink(url)
                    case .kimiAccount:
                        note("请使用上方的 Kimi Code 控制台入口查看。")
                    case .chatGPT, nil:
                        EmptyView()
                    }
                case .configure(let url):
                    note("配置凭据后可查询。")
                    consoleLink(url)
                case .query(let state, let url):
                    TimelineView(.explicit(updateDates(for: state))) { context in
                        queryContent(state, now: context.date)
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
            case .idle, .ready:
                EmptyView()
            case .loading(let previous):
                ProgressView {
                    note(previous == nil ? "正在查询…" : "正在刷新…")
                }
            case .failed(let error, let previous):
                failure(error, hasPrevious: previous != nil, now: now)
            }

            Button(action: refresh) {
                Label("刷新", systemImage: "arrow.clockwise").frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .disabled(!state.canRefresh(at: now))
            .accessibilityIdentifier("refreshAIConnectionUsage")
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
                            amount("充值余额", wallet.toppedUp, currency: wallet.currency)
                            amount("赠送余额", wallet.granted, currency: wallet.currency)
                        }
                    }
                }.padding(.top, 10)
            } label: {
                Text("余额组成").frame(minHeight: 44).contentShape(.rect)
            }
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
        let number = amount.formatted(.number.precision(.fractionLength(0...38)).locale(locale))
        return metric(title, value: Text(verbatim: "\(number) \(currency)"), prominent: prominent)
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
