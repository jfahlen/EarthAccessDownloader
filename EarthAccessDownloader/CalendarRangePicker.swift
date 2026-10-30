//
//  CalendarRangePicker.swift
//  EarthAccessDownloader
//
//  A popover with one continuously scrolling calendar (all years at once) for choosing the
//  start and end of the time window. Clicking a day sets whichever end is active; times of day
//  are left as set in the date/time pickers.
//

import SwiftUI

struct CalendarRangePopover: View {
    @Bindable var model: SearchViewModel
    @State private var active = End.from

    private enum End { case from, to }

    private static let calendar = SearchViewModel.utcCalendar
    private static let firstYear = 1986  // AVIRIS-Classic's earliest data
    static let monthsPerRow = 4  // four across, three rows: one year in view
    static let monthWidth: CGFloat = 150  // nominal; months share the available width
    static let scrollBarAllowance: CGFloat = 22
    static let monthHeight: CGFloat = 160
    static let spacing: CGFloat = 14
    /// Rows of months (a month is year * 12 + (month - 1)), from January of `firstYear` to the end of next year.
    private static let rows: ClosedRange<Int> = {
        let year = calendar.component(.year, from: .now)
        return (firstYear * 12 / monthsPerRow)...(((year + 1) * 12 + 11) / monthsPerRow)
    }()

    private static func monthIndex(of date: Date) -> Int {
        let c = calendar.dateComponents([.year, .month], from: date)
        return c.year! * 12 + c.month! - 1
    }

    static func monthStart(_ index: Int) -> Date {
        calendar.date(from: DateComponents(year: index / 12, month: index % 12 + 1, day: 1))!
    }

    private var activeDate: Date { active == .from ? model.startDate : model.endDate }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                endButton(.from, "From", model.startDate)
                endButton(.to, "To", model.endDate)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Self.spacing) {
                        ForEach(Self.rows, id: \.self) { row in
                            HStack(alignment: .top, spacing: Self.spacing) {
                                ForEach(0..<Self.monthsPerRow, id: \.self) { column in
                                    MonthGrid(model: model, index: row * Self.monthsPerRow + column, onPick: pick)
                                }
                            }
                            .id(row)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onAppear { jump(proxy, animated: false) }
                .onChange(of: active) { jump(proxy, animated: true) }
            }
            .frame(height: 3 * Self.monthHeight + 2 * Self.spacing + 4)
            Text("Scroll to any year. Times stay as set in the pickers.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: CGFloat(Self.monthsPerRow) * (Self.monthWidth + Self.spacing) - Self.spacing + 24 + Self.scrollBarAllowance)
    }

    private func endButton(_ end: End, _ title: String, _ date: Date) -> some View {
        Button { active = end } label: {
            VStack(spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: Self.calendar.timeZone)))
                    .font(.callout.weight(active == end ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(active == end ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(active == end ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private func jump(_ proxy: ScrollViewProxy, animated: Bool) {
        // The row holding January of the active date's year, so that whole year is in view.
        let target = Self.calendar.component(.year, from: activeDate) * 12 / Self.monthsPerRow
        DispatchQueue.main.async {
            if animated { withAnimation { proxy.scrollTo(target, anchor: .top) } }
            else { proxy.scrollTo(target, anchor: .top) }
        }
    }

    /// Sets the active end to `day`, keeping its time of day. After choosing a start, moves on to the end.
    private func pick(_ day: Date) {
        func withTimeOf(_ old: Date) -> Date {
            day.addingTimeInterval(old.timeIntervalSince(SearchViewModel.midnightUTC(of: old)))
        }
        switch active {
        case .from:
            model.startDate = withTimeOf(model.startDate)
            active = .to
        case .to:
            model.endDate = withTimeOf(model.endDate)
        }
    }
}

private struct MonthGrid: View {
    let model: SearchViewModel
    let index: Int
    let onPick: (Date) -> Void

    private static let calendar = SearchViewModel.utcCalendar
    private static let today = SearchViewModel.midnightUTC(of: .now)

    var body: some View {
        let first = CalendarRangePopover.monthStart(index)
        let dayCount = Self.calendar.range(of: .day, in: .month, for: first)!.count
        let leading = (Self.calendar.component(.weekday, from: first) - Self.calendar.firstWeekday + 7) % 7
        let startDay = SearchViewModel.midnightUTC(of: model.startDate)
        let endDay = SearchViewModel.midnightUTC(of: model.endDate)

        VStack(alignment: .leading, spacing: 4) {
            Text(first.formatted(Date.FormatStyle(timeZone: Self.calendar.timeZone).month(.wide).year()))
                .font(.caption.weight(.semibold))
                .frame(height: 18)
            HStack(spacing: 0) {
                ForEach(Array(Self.calendar.veryShortWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .frame(height: 14)
            // Always six weeks, so every month is the same height and a year lines up in rows.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(0..<42, id: \.self) { cell in
                    let n = cell - leading + 1
                    if n >= 1 && n <= dayCount {
                        let day = Self.calendar.date(byAdding: .day, value: n - 1, to: first)!
                        let isEnd = day == startDay || day == endDay
                        let inRange = endDay >= startDay && day >= startDay && day <= endDay
                        Text("\(n)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(isEnd ? Color.white : .primary)
                            .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
                            .background {
                                if inRange { Rectangle().fill(Color.accentColor.opacity(0.18)) }
                            }
                            .background {
                                if isEnd { Circle().fill(Color.accentColor) }
                                else if day == Self.today { Circle().stroke(Color.secondary, lineWidth: 1) }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(day) }
                    } else {
                        Color.clear.frame(height: 20)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: CalendarRangePopover.monthHeight, maxHeight: CalendarRangePopover.monthHeight, alignment: .top)
    }
}
