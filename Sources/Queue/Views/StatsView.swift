import SwiftUI

// Stats tab (spec 1a "Stats tab", screenshot 04): waiting-on split bar,
// 2×2 stat cards, weekly activity bars. Whole tab padded 14px, top-aligned.

struct StatsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    // Local spec constants Theme.swift doesn't cover.
    private enum Metric {
        static let splitBarHeight: CGFloat = 8
        static let splitBarRadius: CGFloat = 4
        static let splitBarGap: CGFloat = 2
        static let cardRadius: CGFloat = 10
        static let cardGap: CGFloat = 8
        static let barTrackHeight: CGFloat = 54
        static let barRadius: CGFloat = 3
        static let barGap: CGFloat = 6
        static let zeroBarStub: CGFloat = 3
    }

    var body: some View {
        let ds = DS(scheme)
        Group {
            if let stats = state.stats {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionLabel("WAITING ON", ds: ds)

                        splitBar(stats: stats, ds: ds)
                            .padding(.top, 8)

                        legend(stats: stats, ds: ds)
                            .padding(.top, 7)

                        cardsGrid(stats: stats, ds: ds)
                            .padding(.top, 14)

                        sectionLabel("ACTIVITY · REVIEWS + MERGES", ds: ds)
                            .padding(.top, 18)

                        activityBars(stats.activity, ds: ds)
                            .padding(.top, 8)
                    }
                    .padding(DSMetric.gutter)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .animation(.easeOut(duration: 0.15), value: stats)
            } else {
                EmptyStateLine(text: "No stats yet")
            }
        }
    }

    // MARK: Section label — 11/600 uppercase, tracking 0.4, mono 0.5.

    private func sectionLabel(_ text: String, ds: DS) -> some View {
        Text(text)
            .font(DSFont.sectionLabel())
            .tracking(0.4)
            .foregroundStyle(ds.textGroupHeader)
    }

    // MARK: Waiting-on split bar

    /// "others" segment / weekend bar fill: white 0.18 dark, black 0.18 light.
    private func dimFill(_ ds: DS) -> Color {
        ds.dark ? Color.white.opacity(0.18) : Color.black.opacity(0.18)
    }

    private func splitBar(stats: StatsData, ds: DS) -> some View {
        let you = max(0, stats.waitingOnYou)
        let others = max(0, stats.waitingOnOthers)
        let total = you + others
        return GeometryReader { geo in
            HStack(spacing: Metric.splitBarGap) {
                if total == 0 {
                    segment(dimFill(ds))
                } else {
                    let gaps = (you > 0 && others > 0) ? Metric.splitBarGap : 0
                    let available = max(0, geo.size.width - gaps)
                    if you > 0 {
                        segment(ds.attention)
                            .frame(width: available * CGFloat(you) / CGFloat(total))
                    }
                    if others > 0 {
                        segment(dimFill(ds))
                    }
                }
            }
        }
        .frame(height: Metric.splitBarHeight)
    }

    private func segment(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: Metric.splitBarRadius, style: .continuous)
            .fill(color)
            .frame(maxWidth: .infinity)
    }

    // MARK: Legend — 11.5px; numbers semibold, words muted.

    private func legend(stats: StatsData, ds: DS) -> some View {
        HStack(spacing: 0) {
            Text("\(stats.waitingOnYou)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(ds.attention)
            Text(" you")
                .font(DSFont.legend())
                .foregroundStyle(ds.textSecondary)
            Spacer(minLength: 8)
            Text("\(stats.waitingOnOthers)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(ds.textPrimary)
            Text(" others")
                .font(DSFont.legend())
                .foregroundStyle(ds.textSecondary)
        }
    }

    // MARK: 2×2 stat cards

    private func cardsGrid(stats: StatsData, ds: DS) -> some View {
        VStack(spacing: Metric.cardGap) {
            cardRow(
                left: statCard(number: stats.reviewTurnaround, numberColor: ds.textPrimary,
                               caption: "Your review turnaround · 7d median", ds: ds),
                right: statCard(number: "\(stats.checksPassRate)%", numberColor: ds.success,
                                caption: "Checks pass rate · 7d", ds: ds)
            )
            cardRow(
                left: statCard(number: stats.oldestWaiting, numberColor: ds.perfWarn,
                               caption: "Oldest waiting on you · \(stats.oldestWaitingContext)", ds: ds),
                right: statCard(number: "\(stats.reviewsThisWeek)", numberColor: ds.textPrimary,
                                caption: "Reviews given this week", ds: ds)
            )
        }
    }

    /// Two cards side by side, equal widths and equal heights.
    private func cardRow(left: some View, right: some View) -> some View {
        HStack(alignment: .top, spacing: Metric.cardGap) {
            left
            right
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func statCard(number: String, numberColor: Color, caption: String, ds: DS) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(number)
                .font(DSFont.statNumber())
                .tracking(-0.3)
                .foregroundStyle(numberColor)
            Text(caption)
                .font(DSFont.statCaption())
                .foregroundStyle(ds.dark ? Color.white.opacity(0.45) : Color.black.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ds.card, in: RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous))
    }

    // MARK: Activity bars — 7 columns, 54px track, bottom-aligned.

    private func activityBars(_ days: [DayActivity], ds: DS) -> some View {
        let maxValue = days.map(\.value).max() ?? 0
        return HStack(alignment: .top, spacing: Metric.barGap) {
            ForEach(days) { day in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: Metric.barRadius, style: .continuous)
                        .fill(barColor(day, ds: ds))
                        .frame(height: barHeight(day.value, maxValue: maxValue))
                        .frame(maxWidth: .infinity, maxHeight: Metric.barTrackHeight, alignment: .bottom)
                    // Spec/handoff: day labels are uniform muted gray — only
                    // the BAR is amber for today.
                    Text(day.label)
                        .font(.system(size: 9.5))
                        .foregroundStyle(ds.textFaint)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func barHeight(_ value: Int, maxValue: Int) -> CGFloat {
        guard maxValue > 0, value > 0 else { return Metric.zeroBarStub }
        return max(Metric.zeroBarStub, CGFloat(value) / CGFloat(maxValue) * Metric.barTrackHeight)
    }

    private func barColor(_ day: DayActivity, ds: DS) -> Color {
        if day.isToday { return ds.attention }
        if day.isWeekend { return dimFill(ds) }
        return ds.textFaint // white 0.35 dark / black 0.35 light
    }
}
