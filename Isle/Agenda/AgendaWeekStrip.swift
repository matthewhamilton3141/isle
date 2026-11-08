//
//  AgendaWeekStrip.swift
//
//  The week as a row of days, starting on the user's own first weekday:
//  each day's initial and date, and under it up to three dots in the colours
//  of what's on it — a calendar or list each, so a day of three meetings in
//  one calendar is one dot, and a busy mixed day three. A click picks the
//  day the face lists. Today's date is in the accent; the picked day sits
//  in a soft well.
//
//  Paged a week at a time by the chevrons at its ends — from last week to
//  four on, which is what `AgendaMonitor` reads — never by a sideways swipe,
//  which moves between faces.
//

import SwiftUI

struct AgendaWeekStrip: View {
    let days: [Date]
    let selected: Date
    let now: Date
    let palette: ArtworkPalette
    let items: (Date) -> [AgendaItem]
    let canPage: (back: Bool, forward: Bool)
    let page: (Int) -> Void
    let select: (Date) -> Void

    static let height: CGFloat = 40

    var body: some View {
        HStack(spacing: 0) {
            chevron("chevron.left", enabled: canPage.back) { page(-1) }
            ForEach(days, id: \.self) { day in
                cell(day)
            }
            chevron("chevron.right", enabled: canPage.forward) { page(1) }
        }
        .frame(height: Self.height)
    }

    private func chevron(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.5 : 0.15))
                .frame(width: 14, height: Self.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(symbol == "chevron.left" ? "Previous week" : "Next week")
    }

    private func cell(_ day: Date) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        let isPast = day < calendar.startOfDay(for: now)
        let dots = AgendaLayout.dotColors(items(day))
        return Button { select(day) } label: {
            VStack(spacing: 2) {
                Text(day.formatted(.dateTime.weekday(.narrow)))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.islandSecondary(0.45))
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 13, weight: isToday ? .bold : .semibold).monospacedDigit())
                    .foregroundStyle(isToday ? palette.accent : .white.opacity(isPast ? 0.5 : 0.95))
                HStack(spacing: 2) {
                    ForEach(dots) { item in
                        Circle().fill(item.color).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
                .opacity(isPast ? 0.5 : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.14 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }
}
