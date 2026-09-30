//
//  PrivacySplitter.swift
//  Intelligence/Privacy
//
//  6.3 隐私拆分算法。硬约束：
//  sensitive 片段及其前后文、所属计划标题列表、回顾摘要都不得进入云请求。
//  任何一步异常 → 该片段按 sensitive 处理；"无法确定边界"整体留本机（保守策略）。
//

import Foundation

// MARK: - 结果模型

public struct PrivacySpan: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var start: Int
    public var end: Int
    public var text: String
    public var reason: String?

    public init(id: UUID = UUID(), start: Int, end: Int, text: String, reason: String? = nil) {
        self.id = id; self.start = start; self.end = end; self.text = text; self.reason = reason
    }

    public var span: SourceSpan { SourceSpan(start: start, end: end, text: text) }
}

public struct PrivacySegment: Hashable, Sendable, Identifiable {
    public enum Verdict: String, Hashable, Sendable, CaseIterable {
        /// 无受限信号 → 可发送
        case safe
        /// 有受限信号且无其他信号 → 整句不发送
        case sensitive
        /// 两者都有 → 仅不含受限信号的子句可发送
        case mixed

        public var displayName: String {
            switch self {
            case .safe: "可发送"
            case .sensitive: "仅本机处理"
            case .mixed: "部分本机处理"
            }
        }
    }

    public var id: UUID
    public var text: String
    public var start: Int
    public var end: Int
    public var verdict: Verdict
    public var matchedPlanIds: [UUID]
    public var matchedRestrictedPlanIds: [UUID]
    public var matchedHealthKeywords: [String]
    /// mixed 时：不含受限信号的子句 span（每子句独立 source_span）
    public var sendableSubSpans: [PrivacySpan]

    public init(id: UUID = UUID(), text: String, start: Int, end: Int, verdict: Verdict,
                matchedPlanIds: [UUID] = [], matchedRestrictedPlanIds: [UUID] = [],
                matchedHealthKeywords: [String] = [], sendableSubSpans: [PrivacySpan] = []) {
        self.id = id; self.text = text; self.start = start; self.end = end; self.verdict = verdict
        self.matchedPlanIds = matchedPlanIds
        self.matchedRestrictedPlanIds = matchedRestrictedPlanIds
        self.matchedHealthKeywords = matchedHealthKeywords
        self.sendableSubSpans = sendableSubSpans
    }

    public var isSendable: Bool { verdict == .safe || verdict == .mixed }
    public var reasonText: String {
        if !matchedHealthKeywords.isEmpty { return "涉及健康关键词（\(matchedHealthKeywords.prefix(2).joined(separator: "、"))）" }
        if !matchedRestrictedPlanIds.isEmpty { return "属于未允许云处理的计划" }
        return ""
    }
}

public struct PrivacySplitResult: Hashable, Sendable {
    public var segments: [PrivacySegment]
    /// 仅 safe 片段 + mixed 的可发送子句拼接；span 偏移对应该文本
    public var sendableText: String
    public var sendableSpans: [PrivacySpan]
    /// 留本机的片段（sensitive 整句 + mixed 的受限子句）
    public var localOnlySpans: [PrivacySpan]
    public var hasSensitiveContent: Bool
    /// 兜底：拆分异常时整体留本机
    public var fellBackToLocalOnly: Bool

    public init(segments: [PrivacySegment], sendableText: String, sendableSpans: [PrivacySpan],
                localOnlySpans: [PrivacySpan], hasSensitiveContent: Bool,
                fellBackToLocalOnly: Bool = false) {
        self.segments = segments; self.sendableText = sendableText
        self.sendableSpans = sendableSpans; self.localOnlySpans = localOnlySpans
        self.hasSensitiveContent = hasSensitiveContent
        self.fellBackToLocalOnly = fellBackToLocalOnly
    }

    public var hasSendableContent: Bool { !sendableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 无 safe 片段 → 跳过 C5，全部走本地/收件箱
    public var shouldSkipCloudCall: Bool { !hasSendableContent }
}

// MARK: - 拆分器

public enum PrivacySplitter {

    /// 句级边界（。！？!?；; 换行）
    static let sentenceStops: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "\n"]
    /// 子句边界（仅用于判定，不改变发送边界）
    static let clauseStops: Set<Character> = ["，", ",", "、"]

    /// 6.3 主入口
    public static func split(text: String,
                             plans: [Plan],
                             healthKeywords: [String],
                             excludedTermsByPlan: [UUID: [String]] = [:]) -> PrivacySplitResult {
        let characters = Array(text)
        guard !characters.isEmpty else {
            return PrivacySplitResult(segments: [], sendableText: "", sendableSpans: [],
                                      localOnlySpans: [], hasSensitiveContent: false)
        }

        let restrictedPlans = plans.filter { !$0.cloudAIEnabled || $0.category == .health }
        let openPlans = plans.filter { $0.cloudAIEnabled && $0.category != .health }
        let normalizedHealth = healthKeywords.map { $0.lowercased() }

        var segments: [PrivacySegment] = []
        var sendableChunks: [String] = []
        var sendableSpans: [PrivacySpan] = []
        var localOnlySpans: [PrivacySpan] = []

        do {
            let sentences = try sentenceRanges(in: characters)

            for sentence in sentences {
                let sentenceText = String(characters[sentence.lower..<sentence.upper])
                let trimmed = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }

                let analysis = analyzeSentence(sentenceText,
                                               restrictedPlans: restrictedPlans,
                                               openPlans: openPlans,
                                               healthKeywords: normalizedHealth,
                                               excludedTermsByPlan: excludedTermsByPlan)

                switch analysis.verdict {
                case .safe:
                    segments.append(PrivacySegment(
                        text: sentenceText, start: sentence.lower, end: sentence.upper,
                        verdict: .safe, matchedPlanIds: analysis.matchedPlanIds))
                    // safe 整句发送（含标点，保持 offset 对应）
                    appendSendable(sentenceText, start: sentence.lower, end: sentence.upper,
                                   into: &sendableChunks, &sendableSpans)

                case .sensitive:
                    let reason = analysis.reasonText
                    segments.append(PrivacySegment(
                        text: sentenceText, start: sentence.lower, end: sentence.upper,
                        verdict: .sensitive, matchedPlanIds: analysis.matchedPlanIds,
                        matchedRestrictedPlanIds: analysis.restrictedPlanIds,
                        matchedHealthKeywords: analysis.healthKeywords))
                    localOnlySpans.append(PrivacySpan(start: sentence.lower, end: sentence.upper,
                                                      text: sentenceText, reason: reason))

                case .mixed:
                    // 仅将不含受限信号的子句作为 sendable 片段（每子句独立 source_span）
                    var subSpans: [PrivacySpan] = []
                    for clause in analysis.clauses {
                        let span = PrivacySpan(start: sentence.lower + clause.lower,
                                               end: sentence.lower + clause.upper,
                                               text: clause.text,
                                               reason: clause.isRestricted ? "含受限信号" : nil)
                        if clause.isRestricted {
                            localOnlySpans.append(span)
                        } else if !clause.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            subSpans.append(span)
                            appendSendable(clause.text, start: span.start, end: span.end,
                                           into: &sendableChunks, &sendableSpans)
                        }
                    }
                    segments.append(PrivacySegment(
                        text: sentenceText, start: sentence.lower, end: sentence.upper,
                        verdict: .mixed, matchedPlanIds: analysis.matchedPlanIds,
                        matchedRestrictedPlanIds: analysis.restrictedPlanIds,
                        matchedHealthKeywords: analysis.healthKeywords,
                        sendableSubSpans: subSpans))
                }
            }
        } catch {
            // 兜底：任何一步异常 → 整体留本机
            let whole = PrivacySpan(start: 0, end: characters.count, text: text,
                                    reason: "无法确定边界，整体留在本机")
            return PrivacySplitResult(
                segments: [PrivacySegment(text: text, start: 0, end: characters.count,
                                          verdict: .sensitive)],
                sendableText: "", sendableSpans: [], localOnlySpans: [whole],
                hasSensitiveContent: true, fellBackToLocalOnly: true)
        }

        let joined = sendableChunks.joined(separator: " ")
        return PrivacySplitResult(
            segments: segments,
            sendableText: joined,
            sendableSpans: sendableSpans,
            localOnlySpans: localOnlySpans,
            hasSensitiveContent: !localOnlySpans.isEmpty,
            fellBackToLocalOnly: false)
    }

    private enum SplitError: Error { case badOffsets }

    // MARK: - 句级拆分

    struct Range { var lower: Int; var upper: Int }

    static func sentenceRanges(in characters: [Character]) throws -> [Range] {
        var ranges: [Range] = []
        var start = 0
        var i = 0
        while i < characters.count {
            let ch = characters[i]
            if sentenceStops.contains(ch) {
                // 把连续标点并入上一句
                var end = i + 1
                while end < characters.count, sentenceStops.contains(characters[end]) { end += 1 }
                ranges.append(Range(lower: start, upper: end))
                start = end
                i = end
            } else {
                i += 1
            }
        }
        if start < characters.count { ranges.append(Range(lower: start, upper: characters.count)) }
        guard ranges.allSatisfy({ $0.lower <= $0.upper && $0.upper <= characters.count }) else {
            throw SplitError.badOffsets
        }
        return ranges
    }

    // MARK: - 判定

    struct ClauseAnalysis {
        var text: String
        var lower: Int
        var upper: Int
        var isRestricted: Bool
    }

    struct SentenceAnalysis {
        var verdict: PrivacySegment.Verdict
        var matchedPlanIds: [UUID]
        var restrictedPlanIds: [UUID]
        var healthKeywords: [String]
        var clauses: [ClauseAnalysis]

        var reasonText: String {
            if !healthKeywords.isEmpty { return "涉及健康关键词（\(healthKeywords.prefix(3).joined(separator: "、"))）" }
            return "属于未允许云处理的计划"
        }
    }

    static func analyzeSentence(_ sentence: String,
                                restrictedPlans: [Plan],
                                openPlans: [Plan],
                                healthKeywords: [String],
                                excludedTermsByPlan: [UUID: [String]]) -> SentenceAnalysis {
        let characters = Array(sentence)
        var clauses: [ClauseAnalysis] = []
        var start = 0
        var i = 0
        while i < characters.count {
            if clauseStops.contains(characters[i]) {
                let end = i + 1
                clauses.append(ClauseAnalysis(text: String(characters[start..<end]),
                                              lower: start, upper: end, isRestricted: false))
                start = end
            }
            i += 1
        }
        if start < characters.count {
            clauses.append(ClauseAnalysis(text: String(characters[start...]),
                                          lower: start, upper: characters.count, isRestricted: false))
        }

        var hitRestricted = false
        var hitOther = false
        var restrictedPlanIds: [UUID] = []
        var openPlanIds: [UUID] = []
        var healthHits: [String] = []

        for index in clauses.indices {
            let lowered = clauses[index].text.lowercased()
            var clauseRestricted = false

            // 明确排除项：命中即视为不匹配该计划的信号
            for plan in restrictedPlans {
                let excluded = (excludedTermsByPlan[plan.id] ?? plan.excludedTerms).map { $0.lowercased() }
                if excluded.contains(where: { !$0.isEmpty && lowered.contains($0) }) { continue }
                if matches(lowered, signals: plan.classificationSignals) {
                    clauseRestricted = true
                    if !restrictedPlanIds.contains(plan.id) { restrictedPlanIds.append(plan.id) }
                }
            }
            for keyword in healthKeywords where lowered.contains(keyword) {
                clauseRestricted = true
                if !healthHits.contains(keyword) { healthHits.append(keyword) }
            }

            // 非受限计划信号
            for plan in openPlans {
                let excluded = (excludedTermsByPlan[plan.id] ?? plan.excludedTerms).map { $0.lowercased() }
                if excluded.contains(where: { !$0.isEmpty && lowered.contains($0) }) { continue }
                if matches(lowered, signals: plan.classificationSignals) {
                    if !openPlanIds.contains(plan.id) { openPlanIds.append(plan.id) }
                }
            }
            // 非受限计划「明确任务」标题（6.3：名称/别名/明确任务）
            let explicitTaskHit = openPlans.contains { plan in
                plan.contextPhrases.contains { phrase in
                    !phrase.isEmpty && lowered.contains(phrase.lowercased())
                }
            }

            clauses[index].isRestricted = clauseRestricted
            if clauseRestricted { hitRestricted = true }
            if !clauseRestricted, (!openPlanIds.isEmpty || explicitTaskHit) { hitOther = true }
        }

        // 混合句：受限子句之外还有非受限信号
        if hitRestricted, !openPlanIds.isEmpty || hitOther {
            return SentenceAnalysis(verdict: .mixed, matchedPlanIds: restrictedPlanIds + openPlanIds,
                                    restrictedPlanIds: restrictedPlanIds,
                                    healthKeywords: healthHits, clauses: clauses)
        }
        if hitRestricted {
            return SentenceAnalysis(verdict: .sensitive, matchedPlanIds: restrictedPlanIds,
                                    restrictedPlanIds: restrictedPlanIds,
                                    healthKeywords: healthHits, clauses: clauses)
        }
        return SentenceAnalysis(verdict: .safe, matchedPlanIds: openPlanIds,
                                restrictedPlanIds: [], healthKeywords: [], clauses: clauses)
    }

    static func matches(_ loweredText: String, signals: [String]) -> Bool {
        for signal in signals {
            let s = signal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard s.count >= 2 else { continue }
            if loweredText.contains(s) { return true }
        }
        return false
    }

    private static func appendSendable(_ text: String, start: Int, end: Int,
                                       into chunks: inout [String], _ spans: inout [PrivacySpan]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chunks.append(trimmed)
        spans.append(PrivacySpan(start: start, end: end, text: trimmed))
    }
}
