//
//  RecurrenceScreens.swift
//  Features/Plans
//
//  M09-Frequency 编辑重复频率 / M09-FrequencyPreview 频率影响预览。
//  规则修改只作用于 effectiveFrom 及以后，已记录与跳过的历史保留不变（AC22）；
//  预览数字与实际影响一致，一次确认单 batch 提交。
//

import SwiftUI
import MovoKit

// MARK: - 频率编辑

public struct RecurrenceEditorScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    let taskID: UUID

    @State private var task: Task?
    @State private var rule: RecurrenceRule?
    @State private var pattern: RecurrencePattern = .weekdays
    @State private var weekdays: Set<Int> = [1, 3, 5]
    @State private var weeklyCount = 3
    @State private var effectiveFrom: DateOnly?
    @State private var existingOccurrences: [RecurrenceOccurrence] = []
    @State private var isSaving = false

    public init(taskID: UUID) { self.taskID = taskID }

    public var body: some View {
        Group {
            if task == nil {
                LoadingPlaceholder("正在读取重复安排…")
            } else {
                content
            }
        }
        .movoPageBackground()
        .task { await load() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScreenScroll {
                ScreenChrome("重复安排", subtitle: task?.title) {
                    if rule != nil {
                        MovoButton("影响预览", systemImage: "eye", kind: .secondary) {
                            env.pendingRecurrence = draft
                            router.push(.recurrencePreview(taskID: taskID))
                        }
                    }
                }

                if let error = env.lastError {
                    MovoBanner(error: error) { _ in env.lastError = nil }
                }

                if let rule {
                    MovoBanner(kind: .info,
                               title: "当前规则：\(rule.ruleDescription)",
                               message: "第 \(rule.version) 版，从 \(rule.effectiveFrom.displayString) 起生效。修改只影响这一天之后的安排。")
                } else {
                    MovoBanner(kind: .info,
                               title: "还没有重复安排",
                               message: "设置后这条任务会变成模板，每一次完成或跳过都只影响当次。")
                }

                MovoFormSection("频率") {
                    MovoFormRow("重复方式") {
                        MovoRequiredChipRow(options: RecurrencePattern.allCases,
                                            selection: $pattern,
                                            label: \.displayName)
                    }

                    if pattern == .weekdays {
                        MovoFormRow("选择星期", subtitle: "可多选") {
                            WeekdayPicker(selection: $weekdays)
                        }
                    }

                    if pattern == .weeklyCount {
                        MovoFormRow("每周几次") {
                            Stepper(value: $weeklyCount, in: 1...7) {
                                Text("每周 \(weeklyCount) 次")
                                    .font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.ink)
                            }
                        }
                    }
                }

                MovoFormSection("生效时间",
                                footnote: "生效日期早于今天时会自动修正为今天，并记入历史。") {
                    MovoDateField("从哪一天开始生效", placeholder: "今天",
                                  isOn: Binding(
                                    get: { effectiveFrom != nil },
                                    set: { effectiveFrom = $0 ? env.store.today : nil }),
                                  date: Binding(
                                    get: { (effectiveFrom ?? env.store.today).pickerDate },
                                    set: { effectiveFrom = DateOnly(from: $0, in: env.store.currentTimeZone) }),
                                  timeZone: env.store.currentTimeZone)
                }

                if let rule {
                    MovoFormSection("影响预览") {
                        ImpactPreviewList(preview: impactPreview(for: rule))
                    }
                }
            }

            MovoActionBar {
                MovoButton(rule == nil ? "设置重复" : "保存修改", kind: .primary,
                           isEnabled: !isSaving, isLoading: isSaving) {
                    _Concurrency.Task { await save() }
                }
                MovoButton("取消", kind: .quiet) { router.pop() }
                Spacer(minLength: 0)
            }
        }
    }

    private var draft: RecurrenceDraft {
        RecurrenceDraft(pattern: pattern,
                        weekdays: pattern == .weekdays ? weekdays.sorted() : [],
                        weeklyCount: pattern == .weeklyCount ? weeklyCount : nil,
                        effectiveFrom: effectiveFrom ?? env.store.today)
    }

    private func impactPreview(for rule: RecurrenceRule) -> ImpactPreview {
        RecurrencePolicy.impactPreview(
            rule: rule, existing: existingOccurrences,
            newPattern: pattern,
            newWeekdays: pattern == .weekdays ? weekdays.sorted() : nil,
            newWeeklyCount: pattern == .weeklyCount ? weeklyCount : nil,
            effectiveFrom: effectiveFrom ?? env.store.today,
            today: env.store.today)
    }

    private func save() async {
        guard !isSaving else { return }
        if pattern == .weekdays, weekdays.isEmpty {
            env.lastError = .invalidStructure(reason: "工作日模式至少需要选择一个星期。")
            return
        }
        isSaving = true
        defer { isSaving = false }
        let from = effectiveFrom ?? env.store.today
        do {
            if let rule {
                try await env.store.execute(ChangeRecurrence(
                    ruleID: rule.id, pattern: pattern,
                    weekdays: pattern == .weekdays ? weekdays.sorted() : [],
                    weeklyCount: pattern == .weeklyCount ? weeklyCount : nil,
                    effectiveFrom: from, baseRevision: rule.revision))
            } else {
                try await env.store.execute(CreateRecurrence(
                    taskID: taskID, pattern: pattern,
                    weekdays: pattern == .weekdays ? weekdays.sorted() : [],
                    weeklyCount: pattern == .weeklyCount ? weeklyCount : nil,
                    effectiveFrom: from))
            }
            env.pendingRecurrence = nil
            env.lastBatchNotice = env.store.lastNotification
            router.pop()
        } catch let error as MovoError {
            env.lastError = error
        } catch {
            env.lastError = .invalidStructure(reason: "频率没有保存成功。")
        }
    }

    private func load() async {
        task = await env.store.repository.task(taskID)
        rule = await env.store.repository.rule(forTask: taskID)
        if let rule {
            pattern = rule.pattern
            weekdays = Set(rule.weekdays ?? [])
            weeklyCount = rule.weeklyCount ?? 3
            effectiveFrom = rule.effectiveFrom
            existingOccurrences = await env.store.repository.occurrences(ruleID: rule.id)
        }
    }
}

// MARK: - 星期选择

struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    private let names = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        HStack(spacing: MovoSpace.xs) {
            ForEach(1...7, id: \.self) { day in
                let isOn = selection.contains(day)
                Button {
                    if isOn { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(names[day - 1])
                        .font(MovoFont.captionEmphasis)
                        .foregroundStyle(isOn ? MovoColor.onPrimary : MovoColor.ink)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(isOn ? MovoColor.primary : MovoColor.soft))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("周\(names[day - 1])")
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 影响预览（列表部分，编辑器与预览页共用）

struct ImpactPreviewList: View {
    let preview: ImpactPreview

    var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.s) {
            HStack(spacing: MovoSpace.s) {
                StatusTag(text: preview.affectedCountText,
                          foreground: MovoColor.warning, background: MovoColor.soft,
                          systemImage: "arrow.triangle.2.circlepath")
                if preview.dependencyReleases > 0 {
                    MovoTag("会解除 \(preview.dependencyReleases) 项前置", systemImage: "arrow.triangle.branch")
                }
            }

            if preview.affected.isEmpty {
                Text("生效日期之后没有需要改变的安排。")
                    .font(MovoFont.body).foregroundStyle(MovoColor.muted)
            } else {
                ForEach(preview.affected.prefix(12)) { line in
                    HStack(alignment: .firstTextBaseline, spacing: MovoSpace.s) {
                        Image(systemName: "calendar").font(.system(size: 12))
                            .foregroundStyle(MovoColor.muted)
                        Text(line.title).font(MovoFont.body).foregroundStyle(MovoColor.ink)
                        Text(line.changeText).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                        Spacer(minLength: 0)
                    }
                }
                if preview.affected.count > 12 {
                    Text("另有 \(preview.affected.count - 12) 项同类变化未逐一列出。")
                        .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                }
            }

            if !preview.unaffected.isEmpty {
                Text("保持不变：" + preview.unaffected.prefix(6).joined(separator: "、"))
                    .font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(preview.undoNote).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
        }
    }
}

// MARK: - 频率影响预览页

public struct RecurrencePreviewScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router

    let taskID: UUID

    @State private var task: Task?
    @State private var rule: RecurrenceRule?
    @State private var preview: ImpactPreview?
    @State private var isSaving = false

    public init(taskID: UUID) { self.taskID = taskID }

    public var body: some View {
        Group {
            if let preview {
                content(preview)
            } else {
                LoadingPlaceholder("正在计算影响…")
            }
        }
        .movoPageBackground()
        .task { await load() }
    }

    @ViewBuilder
    private func content(_ preview: ImpactPreview) -> some View {
        VStack(spacing: 0) {
            ScreenScroll {
                ScreenChrome("频率影响预览", subtitle: task?.title)

                if env.pendingRecurrence == nil {
                    MovoBanner(kind: .info,
                               title: "还没有待确认的修改",
                               message: "回到频率编辑页调整后，这里会列出将会新增与不再安排的日期。")
                } else {
                    MovoBanner(kind: .warning,
                               title: preview.affectedCountText,
                               message: "确认后这些变化会作为一批提交，可以一次撤销。已记录与跳过的历史不会改变。")
                }

                MovoFormSection("将要变化") {
                    ImpactPreviewList(preview: preview)
                }

                if let newRule = env.pendingRecurrence {
                    MovoFormSection("新的规则") {
                        MovoInfoRow("重复方式", value: newRule.pattern.displayName, systemImage: "repeat")
                        if newRule.pattern == .weekdays {
                            MovoInfoRow("星期",
                                        value: newRule.weekdays.sorted()
                                            .map { WeekdayNaming.name($0) }.joined(separator: "、"),
                                        systemImage: "calendar")
                        }
                        if newRule.pattern == .weeklyCount {
                            MovoInfoRow("每周次数", value: "\(newRule.weeklyCount ?? 0) 次",
                                        systemImage: "number")
                        }
                        MovoInfoRow("生效日期", value: newRule.effectiveFrom.displayString,
                                    systemImage: "flag")
                    }
                }
            }

            MovoActionBar {
                MovoButton("确认并保存", kind: .primary,
                           isEnabled: env.pendingRecurrence != nil && !isSaving,
                           isLoading: isSaving) {
                    _Concurrency.Task { await confirm() }
                }
                MovoButton("返回修改", kind: .quiet) { router.pop() }
                Spacer(minLength: 0)
            }
        }
    }

    private func confirm() async {
        guard let draft = env.pendingRecurrence, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            if let rule {
                try await env.store.execute(ChangeRecurrence(
                    ruleID: rule.id, pattern: draft.pattern,
                    weekdays: draft.pattern == .weekdays ? draft.weekdays : [],
                    weeklyCount: draft.pattern == .weeklyCount ? draft.weeklyCount : nil,
                    effectiveFrom: draft.effectiveFrom, baseRevision: rule.revision))
            } else {
                try await env.store.execute(CreateRecurrence(
                    taskID: taskID, pattern: draft.pattern,
                    weekdays: draft.pattern == .weekdays ? draft.weekdays : [],
                    weeklyCount: draft.pattern == .weeklyCount ? draft.weeklyCount : nil,
                    effectiveFrom: draft.effectiveFrom))
            }
            env.pendingRecurrence = nil
            env.lastBatchNotice = env.store.lastNotification
            router.pop()
        } catch let error as MovoError {
            env.lastError = error
        } catch {
            env.lastError = .invalidStructure(reason: "频率没有保存成功。")
        }
    }

    private func load() async {
        task = await env.store.repository.task(taskID)
        let loadedRule = await env.store.repository.rule(forTask: taskID)
        rule = loadedRule
        guard let loadedRule else {
            preview = ImpactPreview(title: "新的重复安排")
            return
        }
        let draft = env.pendingRecurrence
        let occurrences = await env.store.repository.occurrences(ruleID: loadedRule.id)
        preview = RecurrencePolicy.impactPreview(
            rule: loadedRule, existing: occurrences,
            newPattern: draft?.pattern ?? loadedRule.pattern,
            newWeekdays: draft.map { $0.pattern == .weekdays ? $0.weekdays : [] }
                ?? loadedRule.weekdays,
            newWeeklyCount: draft.map { $0.pattern == .weeklyCount ? $0.weeklyCount : nil }
                ?? loadedRule.weeklyCount,
            effectiveFrom: draft?.effectiveFrom ?? env.store.today,
            today: env.store.today)
    }
}

enum WeekdayNaming {
    static func name(_ isoWeekday: Int) -> String {
        let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return names[max(0, min(6, isoWeekday - 1))]
    }
}

#Preview("频率编辑") {
    RecurrenceEditorScreen(taskID: DemoFixtures.IDs.walkTemplate)
        .environment(AppEnvironment.preview(today: DemoFixtures.referenceDate))
        .environment(\.movoRouter, Router())
}
