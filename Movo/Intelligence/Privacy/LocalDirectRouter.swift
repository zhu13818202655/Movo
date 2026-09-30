//
//  LocalDirectRouter.swift
//  Intelligence/Privacy
//
//  6.2 C3 + 6.3 步 4：本地确定性匹配（不发云）。
//   a. 匹配受限计划当日/未来实例标题 → CompleteOccurrence / SkipOccurrence / LogActivity（可撤销）
//   b. 明确计划别名 + 清晰动作 → 本地创建/记录
//   c. 其余 → 收件箱，标注"健康/本地内容，请手动归类"
//

import Foundation

/// 本地直执的匹配类型。
public enum LocalDirectMatchKind: String, Hashable, Sendable, CaseIterable {
    /// 受限计划的当日/未来实例 → 完成这一次
    case completeOccurrence
    /// 受限计划的当日/未来实例 → 跳过这一次
    case skipOccurrence
    /// 记录一次行动（不完成）
    case logActivity
    /// 明确计划别名 + 清晰动作 → 本地创建任务
    case createTask
    /// 精确任务标题唯一匹配 → 完成
    case completeTask
    /// 无法确定 → 收件箱手动归类
    case unmatched

    public var displayName: String {
        switch self {
        case .completeOccurrence: "完成这一次"
        case .skipOccurrence: "跳过这一次"
        case .logActivity: "记录一次行动"
        case .createTask: "本地新增任务"
        case .completeTask: "完成任务"
        case .unmatched: "请手动归类"
        }
    }

    public var isDeterministic: Bool { self != .unmatched }
}

/// 一条本地直执结果。`command` 非空且 `kind.isDeterministic` 时可直接提交并撤销。
public struct LocalDirectMatch: Sendable {
    public var kind: LocalDirectMatchKind
    public var command: (any DomainCommand)?
    public var sourceText: String
    public var matchedTitle: String?
    public var matchedPlanID: UUID?
    public var matchedTaskID: UUID?
    public var matchedOccurrenceID: UUID?
    public var reason: String

    public init(kind: LocalDirectMatchKind, command: (any DomainCommand)? = nil,
                sourceText: String, matchedTitle: String? = nil, matchedPlanID: UUID? = nil,
                matchedTaskID: UUID? = nil, matchedOccurrenceID: UUID? = nil, reason: String) {
        self.kind = kind; self.command = command; self.sourceText = sourceText
        self.matchedTitle = matchedTitle; self.matchedPlanID = matchedPlanID
        self.matchedTaskID = matchedTaskID; self.matchedOccurrenceID = matchedOccurrenceID
        self.reason = reason
    }
}

public enum LocalDirectRouter {

    /// 完成类动词（判定"这一次已完成"）
    static let completeVerbs = ["完成", "做完", "搞定", "已完成", "打卡", "打完了"]
    /// 跳过类动词
    static let skipVerbs = ["跳过", "不做了", "算了", "取消", "改天"]
    /// 记录类动词（做了但不代表完成）
    static let logVerbs = ["做了", "去了", "跑了", "走了", "练了", "吃了", "喝了", "睡"]

    /// 6.3 步 4 主入口（纯函数）。仅处理 localOnlySpans（sensitive/mixed 的残留子句）。
    public static func route(privacy: PrivacySplitResult,
                             plans: [Plan],
                             tasks: [Task],
                             occurrences: [RecurrenceOccurrence],
                             today: DateOnly,
                             now: Date,
                             source: SourceKind = .ai,
                             captureID: UUID? = nil) -> [LocalDirectMatch] {
        let taskByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var matches: [LocalDirectMatch] = []

        for span in privacy.localOnlySpans {
            let text = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            matches.append(routeOne(text: text, plans: plans, taskByID: taskByID,
                                    occurrences: occurrences, today: today, now: now,
                                    source: source, captureID: captureID))
        }
        return matches
    }

    // MARK: - 单片段

    static func routeOne(text: String, plans: [Plan], taskByID: [UUID: Task],
                         occurrences: [RecurrenceOccurrence], today: DateOnly, now: Date,
                         source: SourceKind, captureID: UUID?) -> LocalDirectMatch {

        // a. 受限计划当日/未来实例标题匹配
        let restrictedPlanIDs = Set(plans.filter { !$0.cloudAIEnabled || $0.category == .health }.map(\.id))
        var occurrenceHits: [RecurrenceOccurrence] = []
        for occ in occurrences where occ.status == .pending {
            guard let planID = occ.planId, restrictedPlanIDs.contains(planID) else { continue }
            guard let scheduled = occ.scheduledOn, scheduled >= today else { continue }
            guard let task = taskByID[occ.taskId], overlaps(text, task.title) else { continue }
            occurrenceHits.append(occ)
        }

        if occurrenceHits.count == 1, let occ = occurrenceHits.first,
           let task = taskByID[occ.taskId], let planID = occ.planId {
            let verb = classifyVerb(text)
            switch verb {
            case .skip:
                let command = SkipOccurrence(occurrenceID: occ.id, at: .precise(now),
                                             baseRevision: occ.revision)
                return LocalDirectMatch(kind: .skipOccurrence, command: command, sourceText: text,
                                        matchedTitle: task.title, matchedPlanID: occ.planId,
                                        matchedTaskID: task.id, matchedOccurrenceID: occ.id,
                                        reason: "匹配到「\(task.title)」今天这一次，已跳过。")
            case .log:
                let command = LogActivity(planID: planID, taskID: task.id, occurrenceID: occ.id,
                                          happenedAt: .precise(now),
                                          durationMinutes: nil, text: text, source: source)
                return LocalDirectMatch(kind: .logActivity, command: command, sourceText: text,
                                        matchedTitle: task.title, matchedPlanID: occ.planId,
                                        matchedTaskID: task.id, matchedOccurrenceID: occ.id,
                                        reason: "匹配到「\(task.title)」，已记录一次行动。")
            case .complete, .neutral:
                let command = CompleteOccurrence(occurrenceID: occ.id, at: .precise(now),
                                                 baseRevision: occ.revision)
                return LocalDirectMatch(kind: .completeOccurrence, command: command, sourceText: text,
                                        matchedTitle: task.title, matchedPlanID: occ.planId,
                                        matchedTaskID: task.id, matchedOccurrenceID: occ.id,
                                        reason: "匹配到「\(task.title)」今天这一次，已完成。")
            }
        }

        // c-1. 精确任务标题唯一匹配完成（任意计划，非模板、未完成）
        let tasks = Array(taskByID.values)
        let titleHits = tasks.filter { !$0.isTemplate && $0.status != .done && $0.status != .cancelled
            && overlaps(text, $0.title) }
        if titleHits.count == 1, let task = titleHits.first, classifyVerb(text) != .log {
            let command = CompleteTask(taskID: task.id, at: .precise(now),
                                       baseRevision: task.revision, reason: "本地精确匹配")
            return LocalDirectMatch(kind: .completeTask, command: command, sourceText: text,
                                    matchedTitle: task.title, matchedPlanID: task.planId,
                                    matchedTaskID: task.id,
                                    reason: "精确匹配到「\(task.title)」，已标记完成。")
        }

        // b. 明确计划别名 + 清晰动作 → 本地创建（不发云）
        for plan in plans where !plan.cloudAIEnabled || plan.category == .health {
            let signals = ([plan.name] + plan.aliases).filter { $0.count >= 2 }
            guard signals.contains(where: { text.contains($0) }) else { continue }
            guard hasClearAction(text) else { continue }
            let title = deriveTitle(from: text)
            guard title.count >= 2 else { continue }
            let command = CreateTask(title: title, planID: plan.id, source: source,
                                     captureID: captureID, suggestedFields: ["planId"])
            return LocalDirectMatch(kind: .createTask, command: command, sourceText: text,
                                    matchedTitle: title, matchedPlanID: plan.id,
                                    reason: "这是「\(plan.name)」的本地内容，已在本机新增，未发送到云端。")
        }

        // c. 其余 → 收件箱
        return LocalDirectMatch(kind: .unmatched, command: nil, sourceText: text,
                                reason: "健康/本地内容，请手动归类")
    }

    // MARK: - 判定工具

    enum Verb { case complete, skip, log, neutral }

    static func classifyVerb(_ text: String) -> Verb {
        if skipVerbs.contains(where: text.contains) { return .skip }
        if completeVerbs.contains(where: text.contains) { return .complete }
        if logVerbs.contains(where: text.contains) { return .log }
        return .neutral
    }

    static func hasClearAction(_ text: String) -> Bool {
        let verbs = completeVerbs + skipVerbs + logVerbs
            + ["去", "开始", "准备", "安排", "记得", "要", "得去"]
        return verbs.contains(where: text.contains)
    }

    /// 去掉时间/语气前缀，得到可用的任务标题。
    static func deriveTitle(from text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["今天晚上", "今天早上", "明天早上", "明天晚上", "今晚", "明晚", "今天", "明天",
                        "早上", "晚上", "上午", "下午", "中午", "待会儿", "稍后", "记得", "要", "得",
                        "打算", "准备", "帮我", "我想", "我要"]
        var changed = true
        while changed {
            changed = false
            for p in prefixes where s.hasPrefix(p) {
                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return s
    }

    /// 标题匹配：直接包含，或 2-gram 命中率 ≥0.6。
    static func overlaps(_ text: String, _ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return false }
        if text.contains(t) { return true }
        let grams = bigrams(of: t)
        guard !grams.isEmpty else { return false }
        let hits = grams.filter { text.contains($0) }.count
        return Double(hits) / Double(grams.count) >= 0.6
    }

    static func bigrams(of s: String) -> [String] {
        let chars = Array(s)
        guard chars.count >= 2 else { return [] }
        var out: [String] = []
        for i in 0..<(chars.count - 1) {
            out.append(String(chars[i...i + 1]))
        }
        return out
    }
}
