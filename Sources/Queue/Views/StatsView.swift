import SwiftUI

// Stats tab, four sections:
//  1. This week — reviews given, PRs opened/merged, 7-day activity, streak
//     (GitHub contribution data).
//  2. Waiting on you — review requests bucketed by age, oldest one linked.
//  3. Your PRs waiting on others — open, non-draft PRs that aren't ready
//     and aren't waiting on you (failing CI, changes requested, conflicts).
//  4. Review & CI — median time to first review, CI pass rate.
// Sections 2–3 derive live from the inbox / PR lists so they track
// approvals; 1 and 4 come from StatsData. Until a section's data has
// loaded it says so rather than showing an empty (all-clear) state.

struct StatsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    private enum Metric {
        static let tileRadius: CGFloat = 10
        static let gap: CGFloat = 8
        static let barTrackHeight: CGFloat = 40
        static let barRadius: CGFloat = 3
        static let zeroBarStub: CGFloat = 3
        static let agingBarHeight: CGFloat = 8
        static let maxWaitingRows = 4
    }

    var body: some View {
        let ds = DS(scheme)
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    thisWeek(ds)
                    waitingOnYou(ds)
                    yourPRsWaiting(ds)
                    reviewAndCI(ds)
                }
                .padding(DSMetric.gutter)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeOut(duration: 0.15), value: state.stats)
            // Stale or missing numbers say why, as on the list tabs.
            if let error = state.inlineError {
                InlineErrorLine(text: error)
            }
        }
    }

    /// "Loading…" until `section` has loaded once (nil once it has).
    private func notLoaded(_ section: SnapshotSection) -> String? {
        state.loadedSections.contains(section) ? nil : TabEmptyState.notLoadedText(state)
    }

    // MARK: 1 · This week

    @ViewBuilder
    private func thisWeek(_ ds: DS) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("THIS WEEK", trailing: streakCaption, trailingColor: ds.attention, ds: ds)
            if let stats = state.stats {
                HStack(spacing: Metric.gap) {
                    tile("\(stats.reviewsThisWeek)", "Reviews given", ds: ds)
                    tile("\(stats.prsOpenedThisWeek)", "PRs opened", ds: ds)
                    tile("\(stats.prsMergedThisWeek)", "PRs merged", ds: ds)
                }
                .fixedSize(horizontal: false, vertical: true)
                activityBars(stats.activity, ds: ds)
                    .padding(.top, 4)
            } else {
                placeholder(TabEmptyState.notLoadedText(state), ds: ds)
            }
        }
    }

    private var streakCaption: String? {
        guard let streak = state.stats?.streakDays, streak > 0 else { return nil }
        return "\(streak)-day streak"
    }

    private func activityBars(_ days: [DayActivity], ds: DS) -> some View {
        let maxValue = days.map(\.value).max() ?? 0
        return HStack(alignment: .top, spacing: 6) {
            ForEach(days) { day in
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: Metric.barRadius, style: .continuous)
                        .fill(barColor(day, ds: ds))
                        .frame(height: barHeight(day.value, maxValue: maxValue))
                        .frame(maxWidth: .infinity, maxHeight: Metric.barTrackHeight, alignment: .bottom)
                    Text(day.label)
                        .font(.system(size: 9.5))
                        .foregroundStyle(ds.textFaint)
                }
                .frame(maxWidth: .infinity)
                .help("\(day.value) contribution\(day.value == 1 ? "" : "s")")
            }
        }
    }

    private func barHeight(_ value: Int, maxValue: Int) -> CGFloat {
        guard maxValue > 0, value > 0 else { return Metric.zeroBarStub }
        return max(Metric.zeroBarStub, Metric.barTrackHeight * CGFloat(value) / CGFloat(maxValue))
    }

    private func barColor(_ day: DayActivity, ds: DS) -> Color {
        if day.isToday { return ds.attention }
        if day.isWeekend { return ds.dark ? Color.white.opacity(0.18) : Color.black.opacity(0.18) }
        return ds.textFaint
    }

    // MARK: 2 · Waiting on you

    private var reviewRequests: [ReviewRequest] {
        state.inbox.compactMap {
            if case .review(let request) = $0 { return request }
            return nil
        }
    }

    @ViewBuilder
    private func waitingOnYou(_ ds: DS) -> some View {
        let requests = reviewRequests
        let day: TimeInterval = 86400
        let ages = requests.map { -$0.age.date.timeIntervalSinceNow }
        let fresh = ages.filter { $0 < day }.count
        let aging = ages.filter { $0 >= day && $0 < 3 * day }.count
        let stale = ages.filter { $0 >= 3 * day }.count

        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                "WAITING ON YOU",
                trailing: requests.isEmpty ? nil : "\(requests.count) review request\(requests.count == 1 ? "" : "s")",
                ds: ds
            )
            if let notLoaded = notLoaded(.reviews), requests.isEmpty {
                placeholder(notLoaded, ds: ds)
            } else if requests.isEmpty {
                placeholder("Nothing waiting on you ✓", ds: ds)
            } else {
                agingBar(segments: [(fresh, ds.success), (aging, ds.attention), (stale, ds.danger)])
                HStack(spacing: 10) {
                    legendItem(fresh, "under a day", color: ds.success, ds: ds)
                    legendItem(aging, "1–3 days", color: ds.attention, ds: ds)
                    legendItem(stale, "3+ days", color: ds.danger, ds: ds)
                    Spacer(minLength: 0)
                }
                if let oldest = requests.min(by: { $0.age.date < $1.age.date }) {
                    linkRow(
                        title: oldest.title,
                        meta: "Oldest · \(oldest.repo.fullName) #\(oldest.number)",
                        age: oldest.age,
                        url: oldest.url,
                        ds: ds
                    )
                }
            }
        }
    }

    /// Proportional segments with 2px gaps; empty buckets drop out.
    private func agingBar(segments: [(Int, Color)]) -> some View {
        let visible = segments.filter { $0.0 > 0 }
        let total = visible.reduce(0) { $0 + $1.0 }
        return GeometryReader { geo in
            let gaps = CGFloat(max(0, visible.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, segment in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(segment.1)
                        .frame(width: max(0, geo.size.width - gaps) * CGFloat(segment.0) / CGFloat(max(total, 1)))
                }
            }
        }
        .frame(height: Metric.agingBarHeight)
    }

    private func legendItem(_ count: Int, _ label: String, color: Color, ds: DS) -> some View {
        HStack(spacing: 3) {
            Text("\(count)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(count > 0 ? color : ds.textFaint)
            Text(label)
                .font(DSFont.legend())
                .foregroundStyle(ds.textSecondary)
        }
    }

    // MARK: 3 · Your PRs waiting on others

    @ViewBuilder
    private func yourPRsWaiting(_ ds: DS) -> some View {
        // Blocked PRs (changes requested, conflicts) and failing ones wait on
        // you, not on reviewers; ready ones wait on your Merge.
        let waiting = state.prs
            .filter { !$0.isDraft && !$0.isReady && !$0.needsYou }
            .sorted { $0.age.date < $1.age.date }   // longest-waiting first

        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(
                "YOUR PRS WAITING ON OTHERS",
                trailing: waiting.isEmpty ? nil : "\(waiting.count)",
                ds: ds
            )
            if let notLoaded = notLoaded(.prs), waiting.isEmpty {
                placeholder(notLoaded, ds: ds)
            } else if waiting.isEmpty {
                placeholder("No open PRs waiting on review", ds: ds)
            } else {
                ForEach(waiting.prefix(Metric.maxWaitingRows)) { pr in
                    linkRow(title: pr.title, meta: waitingMeta(pr), age: pr.age, url: pr.url, ds: ds)
                }
                if waiting.count > Metric.maxWaitingRows {
                    Text("+\(waiting.count - Metric.maxWaitingRows) more in My PRs")
                        .font(DSFont.meta())
                        .foregroundStyle(ds.textFaint)
                }
            }
        }
    }

    /// "1 approval · waiting on tkole", "No approvals · no reviewers requested".
    private func waitingMeta(_ pr: MyPR) -> String {
        let approvals = pr.approvals == 0
            ? "No approvals"
            : "\(pr.approvals) approval\(pr.approvals == 1 ? "" : "s")"
        guard !pr.requestedReviewers.isEmpty else { return "\(approvals) · no reviewers requested" }
        return "\(approvals) · waiting on \(pr.requestedReviewers.joined(separator: ", "))"
    }

    // MARK: 4 · Review & CI

    @ViewBuilder
    private func reviewAndCI(_ ds: DS) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("REVIEW & CI", trailing: nil, ds: ds)
            if let stats = state.stats {
                HStack(alignment: .top, spacing: Metric.gap) {
                    tile(
                        stats.medianFirstReview.map(formatDuration) ?? "—",
                        stats.medianFirstReview == nil
                            ? "Time to first review · not enough reviewed PRs yet"
                            : "Median time to first review · your last \(stats.firstReviewSample) merged PRs",
                        ds: ds
                    )
                    tile(
                        stats.checksPassRate.map { "\($0)%" } ?? "—",
                        ciCaption(stats),
                        color: passRateColor(stats.checksPassRate, ds: ds),
                        ds: ds
                    )
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                placeholder(TabEmptyState.notLoadedText(state), ds: ds)
            }
        }
    }

    private func ciCaption(_ stats: StatsData) -> String {
        guard stats.checksPassRate != nil else { return "CI pass rate · no checks on your open PRs" }
        guard let check = stats.mostFailingCheck else { return "CI pass rate · your open PRs" }
        let prs = "\(stats.mostFailingCount) PR\(stats.mostFailingCount == 1 ? "" : "s")"
        return "CI pass rate · your open PRs\nMost failing: \(check) (\(prs))"
    }

    private func passRateColor(_ rate: Int?, ds: DS) -> Color {
        guard let rate else { return ds.textPrimary }
        if rate >= 90 { return ds.success }
        return rate >= 70 ? ds.attention : ds.danger
    }

    // MARK: Building blocks

    private func sectionHeader(_ title: String, trailing: String?, trailingColor: Color? = nil, ds: DS) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(DSFont.sectionLabel())
                .tracking(0.4)
                .foregroundStyle(ds.textGroupHeader)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(DSFont.pill())
                    .foregroundStyle(trailingColor ?? ds.textFaint)
            }
        }
    }

    private func tile(_ number: String, _ caption: String, color: Color? = nil, ds: DS) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(number)
                .font(DSFont.statNumber())
                .tracking(-0.3)
                .foregroundStyle(color ?? ds.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(DSFont.statCaption())
                .foregroundStyle(ds.dark ? Color.white.opacity(0.45) : Color.black.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ds.card, in: RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous))
    }

    /// Compact clickable row: title + meta, trailing age; opens on GitHub.
    private func linkRow(title: String, meta: String, age: Age, url: URL, ds: DS) -> some View {
        Button {
            state.open(url)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ds.textPrimary)
                        .lineLimit(1)
                        .help(title)
                    Text(meta)
                        .font(DSFont.meta())
                        .foregroundStyle(ds.textMeta)
                        .lineLimit(1)
                        .help(meta)
                }
                Spacer(minLength: 8)
                AgeText(age: age)
            }
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
            .background(ds.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open on GitHub")
    }

    private func placeholder(_ text: String, ds: DS) -> some View {
        Text(text)
            .font(DSFont.meta())
            .foregroundStyle(ds.textFaint)
    }
}
