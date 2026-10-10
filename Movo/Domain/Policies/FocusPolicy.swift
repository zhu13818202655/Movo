//
//  FocusPolicy.swift
//  Domain/Policies
//
//  专注计时的纯逻辑：从任务的起止时间推导这次计时的形态、把会话字段换算成界面上的数字与
//  文案、以及在结束时决定写进记录多少分钟。
//
//  三条进入路径（任务详情、清单行、补记）共用这里的规则，界面不另建一套。
//  会话只保存「开始时刻 + 倒计时终点 + 暂停区间」，所有显示都由这些字段与当前时刻推导，
//  不做逐秒累加——冷启动恢复、暂停、时钟回拨都不会让数字漂移。
//
//  两处刻意分开的口径：
//  · 时长以结束时刻为锚点，不以时长为锚点。这样「起止都填」与「只填结束」自动统一。
//  · 暂停不计入投入：倒计时剩余按有效已用时长推算，暂停期间冻结，继续时不把暂停算回来。
//

import Foundation

public enum FocusPolicy {

    // MARK: - 形态

    /// 一次计时的形态。倒计时有终点，正计时没有。
    public enum Form: String, Hashable, Sendable, Codable {
        case countdown
        case stopwatch

        public var displayName: String {
            switch self {
            case .countdown: "倒计时"
            case .stopwatch: "正计时"
            }
        }
    }

    /// 这次计时的长度是怎么来的。同一形态下措辞不同，所以单独留一档。
    public enum Basis: String, Hashable, Sendable, Codable {
        /// 起止都是时刻：锚点取结束时刻，名义长度取两者之差。
        case startAndEnd
        /// 只有结束时刻：锚点取结束时刻，名义长度取「离截止还有多久」。
        case endOnly
        /// 只有开始时刻：没有终点，正计时。
        case startOnly
        /// 起止都没有，用预计投入当长度。
        case estimate
        /// 什么都没有：正计时。
        case none

        public var form: Form {
            switch self {
            case .startAndEnd, .endOnly, .estimate: .countdown
            case .startOnly, .none: .stopwatch
            }
        }
    }

    /// 界面上能看到的三个状态。没有会话就是「未开始」。
    public enum Status: String, Hashable, Sendable, Codable {
        case notStarted
        case running
        case paused

        public var displayName: String {
            switch self {
            case .notStarted: "未开始"
            case .running: "计时中"
            case .paused: "已暂停"
            }
        }
    }

    // MARK: - 开始之前的推导

    /// 「开始专注」按下去之前就能算出来的东西：形态、锚点、名义长度。
    public struct Plan: Hashable, Sendable {
        public var basis: Basis
        /// 倒计时终点（名义终点），带自己的时区，钟点文本按它换算。正计时为 nil。
        public var anchor: DateTimeTZ?
        /// 名义长度（秒）。定义是「倒计时归零那一刻的有效已用时长」：
        /// 起止都是时刻取差值，只有结束时刻取离截止还有多久，只有预计投入取预计投入的分钟数。
        /// 这个定义让「计划 30 分钟」与「到点后按 30 分钟截断」用同一个数。
        public var plannedSeconds: Int?

        public init(basis: Basis, anchor: DateTimeTZ? = nil, plannedSeconds: Int? = nil) {
            self.basis = basis
            self.anchor = anchor
            self.plannedSeconds = plannedSeconds
        }

        public var form: Form { basis.form }

        public var plannedMinutes: Int? {
            guard let plannedSeconds else { return nil }
            return plannedSeconds / 60
        }

        /// 这次计时的计划标签：`计划 30 分钟` / `离截止` / `未设置时长，正计时`。见 `Snapshot.planLabel`。
        public var planLabel: String {
            FocusPolicy.planLabel(for: basis, plannedSeconds: plannedSeconds)
        }

        /// 入口按钮的副文案，拼成「开始专注 · 30 分钟」。
        public var buttonSubtitle: String {
            switch basis {
            case .startAndEnd, .estimate:
                return plannedMinutes.map { "\($0) 分钟" } ?? "正计时"
            case .endOnly:
                guard let anchor else { return "正计时" }
                return "到 \(FocusPolicy.clockText(of: anchor))"
            case .startOnly, .none:
                return "正计时"
            }
        }

        /// 按钮上的整句。
        public var buttonTitle: String { "开始专注 · \(buttonSubtitle)" }
    }

    /// 从任务的起止时间与预计投入推导这次计时。
    ///
    /// 只有「某一时刻」才算有钟点：某一天（如「截止 今天」）没有钟点，不构成终点，
    /// 也不会被拿来算长度——否则会把整整一天算成这次专注的长度。
    public static func plan(startAt: TimePoint?, endAt: TimePoint?,
                            estimateMinutes: Int?, now: Date,
                            timeZone: TimeZone = .current) -> Plan {
        let start = startAt?.instantValue
        let end = endAt?.instantValue

        // 起止都是时刻，且结束晚于开始：长度取差值。
        if let start, let end, end.epoch > start.epoch {
            return Plan(basis: .startAndEnd, anchor: end,
                        plannedSeconds: Int(end.epoch.timeIntervalSince(start.epoch).rounded()))
        }
        // 只有结束时刻（或起止颠倒）：锚点照用，长度取「离截止还有多久」。
        if let end, end.epoch > now {
            return Plan(basis: .endOnly, anchor: end,
                        plannedSeconds: Int(end.epoch.timeIntervalSince(now).rounded()))
        }
        // 只有开始时刻：没有终点，正计时。
        if start != nil {
            return Plan(basis: .startOnly)
        }
        // 没有钟点，退回预计投入。
        if let estimateMinutes, estimateMinutes > 0 {
            let seconds = estimateMinutes * 60
            return Plan(basis: .estimate,
                        anchor: DateTimeTZ(now.addingTimeInterval(TimeInterval(seconds)), in: timeZone),
                        plannedSeconds: seconds)
        }
        return Plan(basis: .none)
    }

    // MARK: - 会话

    /// 一次进行中的专注。可编码，用于落本机（不进 CloudKit）。
    public struct Session: Hashable, Sendable, Codable, Identifiable {
        /// 一段暂停。`endedAt` 为 nil 表示这次暂停还没结束。
        public struct Pause: Hashable, Sendable, Codable {
            public var startedAt: Date
            public var endedAt: Date?

            public init(startedAt: Date, endedAt: Date? = nil) {
                self.startedAt = startedAt
                self.endedAt = endedAt
            }

            public var isOpen: Bool { endedAt == nil }

            /// 这段暂停到 `now` 为止占用的秒数。时钟回拨不产生负数。
            public func seconds(until now: Date) -> Int {
                let end = endedAt ?? now
                return max(0, Int(end.timeIntervalSince(startedAt).rounded()))
            }
        }

        public var id: UUID
        public var taskID: UUID
        /// 任务标题的显示快照：计时条在冷启动恢复后要立刻能渲染，不能等仓库读回任务。
        /// 只是显示用，不参与任何领域判断，下次开始时刷新。
        public var taskTitle: String
        public var basis: Basis
        /// 倒计时终点（名义终点）。正计时为 nil。
        public var anchor: DateTimeTZ?
        public var plannedSeconds: Int?
        public var startedAt: Date
        public var pauses: [Pause]

        public init(id: UUID = UUID(), taskID: UUID, taskTitle: String,
                    basis: Basis, anchor: DateTimeTZ? = nil, plannedSeconds: Int? = nil,
                    startedAt: Date, pauses: [Pause] = []) {
            self.id = id
            self.taskID = taskID
            self.taskTitle = taskTitle
            self.basis = basis
            self.anchor = anchor
            self.plannedSeconds = plannedSeconds
            self.startedAt = startedAt
            self.pauses = pauses
        }

        public var form: Form { basis.form }

        public var plannedMinutes: Int? {
            guard let plannedSeconds else { return nil }
            return plannedSeconds / 60
        }

        /// 结尾那段暂停是不是还没结束。
        public var isPaused: Bool { pauses.last?.isOpen ?? false }
    }

    /// 按推导结果开一次计时。
    public static func start(_ plan: Plan, taskID: UUID, taskTitle: String,
                             at now: Date, id: UUID = UUID()) -> Session {
        Session(id: id, taskID: taskID, taskTitle: taskTitle, basis: plan.basis,
                anchor: plan.anchor, plannedSeconds: plan.plannedSeconds, startedAt: now)
    }

    public static func status(of session: Session?) -> Status {
        guard let session else { return .notStarted }
        return session.isPaused ? .paused : .running
    }

    /// 暂停。已经在暂停中时原样返回，不叠第二段。
    public static func pause(_ session: Session, at now: Date) -> Session {
        guard !session.isPaused else { return session }
        var next = session
        next.pauses.append(Session.Pause(startedAt: now))
        return next
    }

    /// 继续。不在暂停中时原样返回。
    ///
    /// `endedAt` 早于 `startedAt` 的异常区间（时钟被回拨）按零长度收尾，
    /// 不让一段倒着走的区间把有效时长算多。
    public static func resume(_ session: Session, at now: Date) -> Session {
        guard let last = session.pauses.last, last.isOpen else { return session }
        var next = session
        next.pauses[next.pauses.count - 1].endedAt = max(now, last.startedAt)
        return next
    }

    // MARK: - 派生数字

    /// 到 `now` 为止的暂停总秒数，含正在进行的那一段。
    public static func pausedSeconds(_ session: Session, at now: Date) -> Int {
        session.pauses.reduce(0) { $0 + $1.seconds(until: now) }
    }

    /// 有效已用秒数 = 当前时刻 − 开始时刻 − 已暂停总时长。
    ///
    /// 暂停中这个值自动冻结（当前时刻与当前暂停同步增长，两者抵消），不需要额外分支。
    /// 时钟回拨导致当前时刻早于开始时刻时按 0 处理，不出现负数。
    public static func elapsedSeconds(_ session: Session, at now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(session.startedAt).rounded()) - pausedSeconds(session, at: now))
    }

    /// 倒计时剩余秒数；正计时返回 nil，已归零返回 0（不出现负数）。
    public static func remainingSeconds(_ session: Session, at now: Date) -> Int? {
        rawRemainingSeconds(session, at: now).map { max(0, $0) }
    }

    /// 超出计划时间的秒数；未超出返回 0。正计时恒为 0。
    ///
    /// 必须从**未截断**的剩余算起：`remainingSeconds` 会把负值钳到 0，
    /// 用它反推就永远得不到超出量。
    public static func overrunSeconds(_ session: Session, at now: Date) -> Int {
        guard let raw = rawRemainingSeconds(session, at: now) else { return 0 }
        return raw > 0 ? 0 : -raw
    }

    /// 带符号的剩余：正数表示还有多久，负数表示已经超出多少。正计时为 nil。
    private static func rawRemainingSeconds(_ session: Session, at now: Date) -> Int? {
        guard session.form == .countdown, let anchor = session.anchor else { return nil }
        return Int(anchor.epoch.timeIntervalSince(now).rounded()) + pausedSeconds(session, at: now)
    }

    /// 当前这段暂停已经持续多久；不在暂停中返回 nil。
    public static func currentPauseSeconds(_ session: Session, at now: Date) -> Int? {
        guard let last = session.pauses.last, last.isOpen else { return nil }
        return last.seconds(until: now)
    }

    /// 排期到点提醒应该用的有效终点。
    ///
    /// 到点按有效剩余时间判断，不按名义锚点：暂停 20 分钟后重新排期的终点要往后挪 20 分钟，
    /// 否则提醒会提前 20 分钟响。暂停中与已归零后不排期，返回 nil。
    public static func effectiveEnd(_ session: Session, at now: Date) -> Date? {
        guard session.form == .countdown, !session.isPaused else { return nil }
        guard let remaining = remainingSeconds(session, at: now), remaining > 0 else { return nil }
        return now.addingTimeInterval(TimeInterval(remaining))
    }

    /// 这次计时是不是已经在到点或暂停后很久没人管了。
    public static func staleness(_ session: Session, at now: Date,
                                 thresholdHours: Int) -> Staleness? {
        guard thresholdHours > 0, thresholdHours <= Int.max / 3600 else { return nil }
        let threshold = thresholdHours * 3600
        if let paused = currentPauseSeconds(session, at: now), paused >= threshold {
            return .paused(hours: paused / 3600)
        }
        let overrun = overrunSeconds(session, at: now)
        if overrun >= threshold {
            return .overrun(hours: overrun / 3600)
        }
        return nil
    }

    /// 持续没人操作的原因。两种都要在下次打开应用时问一次，不静默作废也不静默续上。
    public enum Staleness: Hashable, Sendable {
        case paused(hours: Int)
        case overrun(hours: Int)

        public var hours: Int {
            switch self {
            case .paused(let hours), .overrun(let hours): hours
            }
        }

        public var message: String {
            switch self {
            case .paused(let hours):
                return "这次计时已经暂停 \(hours) 小时，是结束记录还是放弃？"
            case .overrun(let hours):
                return "这次计时已经超出计划时间 \(hours) 小时，是结束记录还是放弃？"
            }
        }
    }

    // MARK: - 结束与写入

    /// 结束时该记多少秒。
    ///
    /// 到点后拖延很久才回来结束，默认截断到锚点（计划 30 分钟就记 30 分钟）；
    /// 超出锚点在宽限分钟数以内的按实际记，这点超出只是分钟级的收尾，截掉反而失真。
    public static func recordedSeconds(_ session: Session, at now: Date,
                                      truncateAtAnchor: Bool, graceMinutes: Int) -> Int {
        let elapsed = elapsedSeconds(session, at: now)
        guard truncateAtAnchor, session.form == .countdown,
              let planned = session.plannedSeconds, planned > 0 else { return elapsed }
        let grace = max(0, graceMinutes) * 60
        return elapsed > planned + grace ? planned : elapsed
    }

    /// 结束时该记多少分钟。不足一分钟按一分钟记，避免写出 0 分钟的记录。
    public static func recordedMinutes(_ session: Session, at now: Date,
                                       truncateAtAnchor: Bool, graceMinutes: Int) -> Int {
        let seconds = recordedSeconds(session, at: now,
                                      truncateAtAnchor: truncateAtAnchor,
                                      graceMinutes: graceMinutes)
        return max(1, Int((Double(seconds) / 60).rounded()))
    }

    /// 计划与实际的差异标签：`与计划一致` / `比计划多 10 分钟` / `比计划少 5 分钟`。
    /// 没有计划时长（正计时）时没有可比的一方，返回 nil。
    public static func diffTag(recordedMinutes: Int, plannedMinutes: Int?) -> String? {
        guard let plannedMinutes else { return nil }
        let delta = recordedMinutes - plannedMinutes
        if delta == 0 { return "与计划一致" }
        return delta > 0 ? "比计划多 \(delta) 分钟" : "比计划少 \(-delta) 分钟"
    }

    // MARK: - 界面一屏

    /// 界面要显示的数字与文案，全部由会话与当前时刻推导。
    /// 视图不再自己算剩余时间，两端的计时条与计时页共用这一份。
    public struct Snapshot: Hashable, Sendable {
        public var status: Status
        public var form: Form
        public var basis: Basis
        public var elapsedSeconds: Int
        public var remainingSeconds: Int?
        public var overrunSeconds: Int
        /// 倒计时剩余比例 0…1，用于画进度环；正计时为 nil（改为刻度点）。
        public var remainingFraction: Double?
        public var isOverrun: Bool
        public var currentPauseSeconds: Int?
        public var staleness: Staleness?
        /// 这次计时按什么基准算：`计划 30 分钟` / `离截止` / `未设置时长，正计时`。
        ///
        /// 目前没有界面落点：计时页只留标题。这句话在「未开始」已经写在主按钮上
        /// （「开始专注 · 30 分钟」），在计时中又和盘上的数字重复。
        /// 保留是因为它是「这次按什么算」的单一来源，计时条或别的入口随时要用。
        public var planLabel: String
        /// 盘内主数字：`18:23` / `12:40` / `+03:12`。
        public var primaryText: String
        /// 主数字下的副行：`到 15:00 结束` / `已专注` / `已超过计划时间`。
        public var secondaryText: String
        /// 计时条上的下行：`剩余 18:23 · 到 15:00` / `已暂停 · 剩余 18:23` / `已超出 03:12` / `已专注 12:40`。
        public var barDetailText: String
        /// 暂停时长的独立措辞 `已暂停 02:14`；不在暂停中为 nil。
        public var pausedDurationText: String?
    }

    public static func snapshot(_ session: Session, at now: Date,
                                stalenessThresholdHours: Int) -> Snapshot {
        let elapsed = elapsedSeconds(session, at: now)
        let remaining = remainingSeconds(session, at: now)
        let overrun = overrunSeconds(session, at: now)
        // 刚好归零的那一瞬仍读成「剩余 00:00」：还没超出，不该闪一下「+00:00」。
        let isOverrun = overrun > 0
        let currentPause = currentPauseSeconds(session, at: now)

        let primary: String
        let secondary: String
        let runningDetail: String
        let fraction: Double?

        switch session.form {
        case .countdown:
            let anchorText = session.anchor.map(clockText(of:))
            fraction = isOverrun ? 0 : fractionOf(remaining: remaining, planned: session.plannedSeconds)
            if isOverrun {
                primary = "+" + clockText(overrun)
                secondary = "已超过计划时间"
                runningDetail = "已超出 \(clockText(overrun))"
            } else {
                let text = clockText(remaining ?? 0)
                primary = text
                secondary = anchorText.map { "到 \($0) 结束" } ?? "剩余"
                runningDetail = "剩余 \(text)" + (anchorText.map { " · 到 \($0)" } ?? "")
            }
        case .stopwatch:
            fraction = nil
            primary = clockText(elapsed)
            secondary = "已专注"
            runningDetail = "已专注 \(clockText(elapsed))"
        }

        let bar: String
        let pausedDuration: String?
        if let currentPause {
            pausedDuration = "已暂停 \(clockText(currentPause))"
            let frozen = session.form == .countdown ? "剩余 \(clockText(remaining ?? 0))"
                                                    : "已专注 \(clockText(elapsed))"
            bar = "已暂停 · \(frozen)"
        } else {
            pausedDuration = nil
            bar = runningDetail
        }

        return Snapshot(status: status(of: session),
                        form: session.form,
                        basis: session.basis,
                        elapsedSeconds: elapsed,
                        remainingSeconds: remaining,
                        overrunSeconds: overrun,
                        remainingFraction: fraction,
                        isOverrun: isOverrun,
                        currentPauseSeconds: currentPause,
                        staleness: staleness(session, at: now, thresholdHours: stalenessThresholdHours),
                        planLabel: planLabel(for: session.basis, plannedSeconds: session.plannedSeconds),
                        primaryText: primary,
                        secondaryText: secondary,
                        barDetailText: bar,
                        pausedDurationText: pausedDuration)
    }

    /// 计划标签的措辞。会话与推导结果共用，避免两处写不一样的话。
    private static func planLabel(for basis: Basis, plannedSeconds: Int?) -> String {
        switch basis {
        case .startAndEnd, .estimate:
            guard let plannedSeconds else { return "计划" }
            return "计划 \(plannedSeconds / 60) 分钟"
        case .endOnly:
            return "离截止"
        case .startOnly, .none:
            return "未设置时长，正计时"
        }
    }

    private static func fractionOf(remaining: Int?, planned: Int?) -> Double? {
        guard let remaining, let planned, planned > 0 else { return nil }
        return min(1, max(0, Double(remaining) / Double(planned)))
    }

    // MARK: - 文案

    /// `18:23` / `1:02:03`。超过一小时才补上小时段，短时长保持两段更易读。
    public static func clockText(_ seconds: Int) -> String {
        let value = max(0, seconds)
        if value >= 3600 {
            return String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    /// 锚点的钟点文本，按其自带时区换算（沿用 `TimePoint.clockText` 的口径）。
    public static func clockText(of anchor: DateTimeTZ) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = anchor.timeZone
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: anchor.epoch)
    }
}
