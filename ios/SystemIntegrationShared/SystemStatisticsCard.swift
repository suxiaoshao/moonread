import SwiftUI

struct SystemStatisticsCard: View {
    let statistics: SystemReadingSnapshot.Statistics?
    let colors: SystemWidgetColors
    var date = Date()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SystemWidgetBrand(title: "阅读统计", colors: colors)
                Spacer()
                if statistics?.recordingEnabled == false { Text("记录已暂停").font(.caption2).foregroundStyle(colors.secondary) }
            }
            if let value = statistics, value.hasValues(at: date),
               let today = value.todayDurationMs, let week = value.weekDurationMs, let streak = value.currentStreakDays {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    metric("今天", value: duration(today))
                    metric("本周", value: duration(week))
                    metric("连续", value: String(localized: "\(streak) 天"))
                }
                Spacer(minLength: 0)
                chart(value.days ?? [])
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "chart.bar.xaxis").font(.title2).foregroundStyle(colors.accent)
                    Text(status).font(.subheadline.weight(.medium)).foregroundStyle(colors.ink)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }
    private var status: LocalizedStringKey {
        guard let statistics, statistics.isCurrent(at: date) else { return "打开月读更新统计" }
        switch statistics.status {
        case "incomplete": return "需更新月读"
        case "unavailable": return "统计暂不可用"
        case "notEnabled": return "打开月读开启阅读统计"
        default: return "打开月读更新统计"
        }
    }
    private func metric(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(colors.secondary)
            Text(verbatim: value).font(.system(.headline, design: .rounded)).foregroundStyle(colors.ink).lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func duration(_ ms: UInt64) -> String {
        if ms > 0 && ms < 60_000 { return String(localized: "不足 1 分钟") }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]; formatter.unitsStyle = .abbreviated; formatter.maximumUnitCount = 2
        return formatter.string(from: Double(ms) / 1000) ?? String(localized: "0 分钟")
    }
    private func dayLabel(_ day: Int64) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("EEEEE")
        return formatter.string(from: Date(timeIntervalSince1970: Double(day) * 86_400))
    }
    private func chart(_ days: [SystemReadingSnapshot.Statistics.Day]) -> some View {
        let maximum = max(1, days.map(\.durationMs).max() ?? 0)
        return HStack(alignment: .bottom, spacing: 12) {
            ForEach(days, id: \.localDay) { day in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(day.localDay == statistics?.localDay ? colors.accent : colors.accent.opacity(0.3))
                        .frame(height: day.durationMs == 0 ? 0 : max(2, 34 * Double(day.durationMs) / Double(maximum)))
                        .frame(height: 34, alignment: .bottom)
                    Text(dayLabel(day.localDay)).font(.system(size: 9)).foregroundStyle(colors.secondary)
                }.frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(dayLabel(day.localDay))，\(duration(day.durationMs))"))
            }
        }
    }
}
