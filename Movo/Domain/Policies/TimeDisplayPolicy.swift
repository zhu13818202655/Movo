//
//  TimeDisplayPolicy.swift
//  Domain/Policies
//
//  时间点的展示上下文。同一条时间在不同页面上需要表达的信息量不同：
//  「今日」筛选里日期已知是今天，再显示一遍日期是冗余；计划树里则必须显示完整日期。
//
//  这里只决定「省略哪些日期」，不改变 `TimePoint` 自身的取值、比较与存储语义。
//  原则：只省略参考日当天的日期，任何仍然有信息量的日期照常显示。
//

import Foundation

/// 展示时间点时的上下文。
public enum TimeDisplayContext: Hashable, Sendable {
    /// 今日筛选：整页的参考日就是今天，与参考日相同的日期不再重复出现。
    case today(DateOnly)
    /// 同一周内的列表：参考日当天与前后一天用「今天 / 明天 / 昨天」，其余显示日期。
    case nearby(DateOnly)
    /// 完整日期。计划树、任务详情、导出等需要绝对时间的场景使用，也是缺省。
    case absolute

    /// 参考日；绝对上下文没有参考日。
    public var referenceDay: DateOnly? {
        switch self {
        case .today(let day), .nearby(let day): day
        case .absolute: nil
        }
    }

    /// 某一天在这个上下文里的文字。今日上下文不使用「昨天」，因为逾期项应当直接显示日期。
    func dayText(for day: DateOnly) -> String {
        guard let reference = referenceDay else { return day.displayString }
        if day.isSameDay(as: reference) { return "今天" }
        if day.isSameDay(as: reference.adding(days: 1)) { return "明天" }
        if case .nearby = self, day.isSameDay(as: reference.adding(days: -1)) { return "昨天" }
        return day.displayString
    }

    /// 是否省略这一天的日期。只有今日上下文会省略参考日当天；`nearby` 保留「今天 / 明天」的措辞。
    func omitsDate(for day: DateOnly) -> Bool {
        guard case .today(let reference) = self else { return false }
        return day.isSameDay(as: reference)
    }

    /// 行内时间标签的日期前缀（含尾随空格）；不需要前缀时返回空串。
    func timePrefix(for day: DateOnly) -> String {
        if omitsDate(for: day) { return "" }
        return dayText(for: day) + " "
    }
}

extension TimePoint {
    /// 独立取值的展示文字，按上下文省略冗余日期。
    public func displayString(in context: TimeDisplayContext) -> String {
        switch self {
        case .day(let day):
            return context.dayText(for: day)
        case .instant(let value):
            let day = value.dateOnly
            let clock = clockText ?? ""
            if context.omitsDate(for: day) { return clock }
            return "\(context.dayText(for: day)) \(clock)"
        }
    }
}
