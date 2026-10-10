//
//  FocusSessionView.swift
//  Features/Plans
//
//  D14 Mac 专注计时 / M15 iPhone 专注计时，以及补记浮层（记录一次行动）。
//
//  用户可见的计时状态只有三个：未开始、计时中、已暂停。
//  倒计时归零属于「计时中」的显示变体，界面上不出现额外状态标签——
//  数字前缀与配色就是全部的区别。
//
//  计时页上的字很少，是有意的：标题、盘上的数字、控制按钮。
//  规则性的说明（暂停不计入投入、结束与放弃的区别）不写在这一页上，
//  它面对的是「正在做」的人，中间那几行字只会把视线从数字上拉走。
//
//  「结束」直接写入记录，不再弹一层确认：投入时长由 `FocusPolicy.recordedMinutes`
//  算好，让用户确认一遍只是让他复述系统刚算出来的那个数。
//  想改时长或补说明走「记录一次行动」——那是「补」，与「结束」共用同一条写入。
//
//  所有数字都来自 `FocusPolicy.Snapshot`；视图不自己算剩余时间，
//  计时条与计时页也不会出现两套口径。
//

import SwiftUI
import MovoKit

// MARK: - 计时条（Focus / Bar）

/// 跨页面可见的计时条。
///
/// 挂在外壳顶部而不是各页面里：从待办切到计划、回顾都要能看到秒数在走，
/// 逐个页面各插一份迟早会漏掉一个。整条可点，回到计时页；
/// 行内的暂停/结束按钮自己处理点击，不触发整条的跳转。
public struct FocusBar: View {
    @Environment(AppEnvironment.self) private var env

    private let session: FocusPolicy.Session
    private let onTap: () -> Void
    private let onTogglePause: () -> Void
    private let onFinish: () -> Void

    public init(session: FocusPolicy.Session,
                onTap: @escaping () -> Void,
                onTogglePause: @escaping () -> Void,
                onFinish: @escaping () -> Void) {
        self.session = session
        self.onTap = onTap
        self.onTogglePause = onTogglePause
        self.onFinish = onFinish
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            tick(at: context.date)
        }
    }

    @ViewBuilder
    private func tick(at date: Date) -> some View {
        let snapshot = env.focusSnapshot(session, at: date)
        HStack(spacing: MovoSpace.s) {
            Image(systemName: icon(snapshot))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(accent(snapshot))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.taskTitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MovoColor.ink)
                    .lineLimit(1)
                Text(snapshot.barDetailText)
                    .font(MovoFont.caption)
                    .foregroundStyle(MovoColor.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: MovoSpace.s)

            MovoIconButton(snapshot.status == .paused ? "play.fill" : "pause.fill",
                           label: snapshot.status == .paused ? "继续" : "暂停",
                           tint: MovoColor.primary, action: onTogglePause)
            MovoButton("结束", kind: .quiet, action: onFinish)
        }
        .padding(.horizontal, MovoSpace.m)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(barBackground(snapshot)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(snapshot.isOverrun ? MovoColor.warning : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .padding(.horizontal, MovoSpace.m)
        .padding(.vertical, MovoSpace.xs)
        // 剩余与已用每秒都在变，逐秒播报会把屏幕阅读器占满；
        // 只在状态变化时说一句，具体数字等用户自己聚焦这条再读。
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.taskTitle)，\(snapshot.status.displayName)")
        .accessibilityValue(snapshot.barDetailText)
    }

    private func barBackground(_ snapshot: FocusPolicy.Snapshot) -> Color {
        if snapshot.status == .paused { return MovoColor.soft }
        if snapshot.isOverrun { return MovoColor.surface }
        return MovoColor.tint
    }

    private func accent(_ snapshot: FocusPolicy.Snapshot) -> Color {
        if snapshot.isOverrun { return MovoColor.warning }
        if snapshot.status == .paused { return MovoColor.muted }
        return MovoColor.primary
    }

    private func icon(_ snapshot: FocusPolicy.Snapshot) -> String {
        if snapshot.isOverrun { return "exclamationmark.circle" }
        if snapshot.status == .paused { return "pause.circle" }
        return "timer"
    }
}

// MARK: - 行尾计时徽标

/// 清单行尾的计时徽标（`⏱ 18:23`）。
///
/// 自己带一秒一跳：徽标就是拿来「扫一眼还剩多久」的，静止的数字没有意义。
/// 它在有会话的那几行才出现，所以不会给整张列表挂上时钟。
public struct FocusRowBadge: View {
    @Environment(AppEnvironment.self) private var env

    private let session: FocusPolicy.Session
    private let onTap: () -> Void

    public init(session: FocusPolicy.Session, onTap: @escaping () -> Void) {
        self.session = session
        self.onTap = onTap
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let snapshot = env.focusSnapshot(session, at: context.date)
            Button(action: onTap) {
                MovoTag(text(snapshot), systemImage: snapshot.status == .paused ? "pause.fill" : "timer")
                    .frame(minHeight: MovoSpace.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("回到计时页")
            .accessibilityValue("\(snapshot.status.displayName)，\(text(snapshot))")
        }
    }

    private func text(_ snapshot: FocusPolicy.Snapshot) -> String {
        if snapshot.isOverrun { return "+" + FocusPolicy.clockText(snapshot.overrunSeconds) }
        if let remaining = snapshot.remainingSeconds { return FocusPolicy.clockText(remaining) }
        return FocusPolicy.clockText(snapshot.elapsedSeconds)
    }
}

// MARK: - 计时盘（Focus / Dial）

/// 计时盘：倒计时画进度环（环长表示剩余比例），正计时改画 60 段刻度点。
public struct FocusDial: View {
    private let snapshot: FocusPolicy.Snapshot
    private let diameter: CGFloat

    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 56

    public init(snapshot: FocusPolicy.Snapshot, diameter: CGFloat = 220) {
        self.snapshot = snapshot
        self.diameter = diameter
    }

    public var body: some View {
        ZStack {
            if snapshot.form == .countdown {
                ring
            } else {
                ticks
            }
            VStack(spacing: 10) {
                Text(snapshot.primaryText)
                    .font(.system(size: numberSize, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(numberColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(snapshot.secondaryText)
                    .font(.system(size: 14))
                    .foregroundStyle(MovoColor.muted)
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(.linear(duration: 0.2), value: snapshot.primaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.status.displayName)
        .accessibilityValue("\(snapshot.primaryText)，\(snapshot.secondaryText)")
    }

    private let lineWidth: CGFloat = 10

    @ViewBuilder
    private var ring: some View {
        Circle()
            .stroke(MovoColor.soft, lineWidth: lineWidth)
        Circle()
            .trim(from: 0, to: remainingFraction)
            .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }

    /// 60 段刻度点，已过的段染色。没有终点就没有比例可画，用「一小时走一圈」位次代替。
    @ViewBuilder
    private var ticks: some View {
        let passed = Double(snapshot.elapsedSeconds % 3600) / 3600
        ZStack {
            ForEach(0..<60, id: \.self) { index in
                Capsule()
                    .fill(tickColor(index: index, passed: passed))
                    .frame(width: 2, height: index % 5 == 0 ? 10 : 6)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .rotationEffect(.degrees(Double(index) * 6))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func tickColor(index: Int, passed: Double) -> Color {
        if snapshot.status == .paused { return MovoColor.muted }
        if Double(index) / 60 <= passed { return MovoColor.primary }
        return MovoColor.line
    }

    private var remainingFraction: Double {
        snapshot.status == .paused
            ? max(0, snapshot.remainingFraction ?? 0)
            : (snapshot.remainingFraction ?? 0)
    }

    private var ringColor: Color {
        if snapshot.isOverrun { return MovoColor.warning }
        if snapshot.status == .paused { return MovoColor.muted }
        return MovoColor.primary
    }

    private var numberColor: Color {
        snapshot.isOverrun ? MovoColor.warning : MovoColor.ink
    }
}

// MARK: - 计时页（D14 / M15）

/// 计时页。
///
/// iPhone 从顶部下拉收起，收起后回到进入前的上下文；Mac 走原生的返回。
/// 「未开始」也在这一页：入口按钮的副文案由 `FocusPolicy.Plan` 推导，
/// 不在这里另算一次时长。
public struct FocusSessionScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.movoRouter) private var router
    @Environment(\.dismiss) private var dismiss

    let taskID: UUID

    @State private var task: Task?
    @State private var loaded = false
    @State private var logPrompt = false

    public init(taskID: UUID) { self.taskID = taskID }

    public var body: some View {
        Group {
            if !loaded {
                LoadingPlaceholder("正在读取这项待办…")
            } else if let task {
                content(task)
            } else {
                missingTask
            }
        }
        .movoPageBackground()
        .task(id: "\(taskID)-\(env.store.dataVersion)") { await reload() }
        .sheet(isPresented: $logPrompt) {
            LogActivitySheet(taskTitle: task?.title ?? "", taskID: taskID)
        }
    }

    @ViewBuilder
    private func content(_ task: Task) -> some View {
        Group {
            if let session = env.activeFocus(for: taskID) {
                runningContent(task, session: session)
            } else {
                startContent(task)
            }
        }
    }

    // MARK: 未开始

    @ViewBuilder
    private func startContent(_ task: Task) -> some View {
        let plan = env.focusPlan(for: task)
        FocusStage {
            if let notice = env.focusNotice {
                MovoBanner(kind: .info, title: notice.title, message: notice.message,
                           actions: [("知道了", { env.clearFocusNotice() })])
            }
            // 上一次的计时还开着（属于别的待办）：说清楚是哪一项，并给一个直接过去的入口。
            if let stale = env.focusStaleness, let running = env.focusSession {
                MovoBanner(kind: .warning, title: "「\(running.taskTitle)」的计时还开着",
                           message: stale.message,
                           actions: [("去处理", { router.push(.focus(running.taskID)) }),
                                     ("知道了", { env.dismissFocusStaleness() })])
            }

            hero(task.title)

            // 只留这句任务相关的：这次会倒计时还是正计时、到点会不会自己停。
            // 通用规则（暂停不计入投入、结束与放弃的区别）不写在这块界面上——
            // 它们每次都是一样的，写在这里只是让人多读一遍。
            Text(planHint(plan))
                .font(MovoFont.caption)
                .foregroundStyle(MovoColor.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            VStack(spacing: MovoSpace.s) {
                FocusPrimaryButton(plan.buttonTitle, systemImage: "play.fill") {
                    env.beginFocus(task)
                }
                MovoButton("记录一次行动", kind: .secondary) { logPrompt = true }
            }
        }
    }

    /// 计时页的标题块。未开始与计时中共用同一个，按下「开始」时页面上半部分不会跳。
    ///
    /// 只留标题，不带计划标签（`FocusPolicy.planLabel`）：在「未开始」它已经写在主按钮上
    /// （「开始专注 · 30 分钟」），在计时中它又和盘上的数字说同一件事。
    /// 计时页在「做」的状态里，标题下面紧跟着的应该是那个数字。
    private func hero(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(MovoColor.ink)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    private func planHint(_ plan: FocusPolicy.Plan) -> String {
        switch plan.basis {
        case .startAndEnd, .estimate: "倒计时到点后只提醒一次，计时继续走，不会自动结束。"
        case .endOnly: "按结束时刻倒计时；没有开始时间会被当成从现在开始。"
        case .startOnly, .none: "没有起止时间也没有预计投入，这次从 0 开始正计时。"
        }
    }

    // MARK: 计时中 / 已暂停

    @ViewBuilder
    private func runningContent(_ task: Task, session: FocusPolicy.Session) -> some View {
        // 收起胶囊留在顶部，不跟着内容居中——它是一个固定在屏幕顶边的把手，
        // 掉到画面中间就不再像「往下拖可以收起」这件事了。
        VStack(spacing: 0) {
            #if os(iOS)
            collapseCapsule
            #endif

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let snapshot = env.focusSnapshot(session, at: context.date)
                FocusStage {
                    hero(task.title)

                    FocusDial(snapshot: snapshot)
                        .frame(maxWidth: .infinity)

                    // 状态本身需要解释时才给一句话。正常计时这里什么都不显示：
                    // 「暂停期间不计入投入」只是在重复盘上已经写着的那个数。
                    let notes = stateNotes(snapshot)
                    if !notes.isEmpty {
                        VStack(spacing: MovoSpace.xs) {
                            ForEach(notes, id: \.self) { Text($0) }
                        }
                        .font(MovoFont.caption)
                        .foregroundStyle(MovoColor.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                    }

                    if let stale = env.focusStaleness {
                        MovoBanner(kind: .warning, title: "这次计时开着很久了", message: stale.message,
                                   actions: [("结束记录", { finish() }),
                                             ("放弃", { env.discardFocus(); dismiss() })])
                    }

                    VStack(spacing: MovoSpace.s) {
                        FocusPrimaryButton(primaryTitle(snapshot), systemImage: primaryIcon(snapshot)) {
                            primaryAction(snapshot)
                        }
                        HStack(spacing: MovoSpace.m) {
                            if primaryTitle(snapshot) != "结束" {
                                textAction("结束", action: finish)
                                Text("·").foregroundStyle(MovoColor.muted)
                            }
                            textAction("放弃") {
                                env.discardFocus()
                                dismiss()
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.top, MovoSpace.s)
                }
            }
        }
    }

    private func primaryTitle(_ snapshot: FocusPolicy.Snapshot) -> String {
        if snapshot.status == .paused { return "继续" }
        return snapshot.isOverrun ? "结束" : "暂停"
    }

    private func primaryIcon(_ snapshot: FocusPolicy.Snapshot) -> String {
        if snapshot.status == .paused { return "play.fill" }
        return snapshot.isOverrun ? "stop.fill" : "pause.fill"
    }

    private func primaryAction(_ snapshot: FocusPolicy.Snapshot) {
        if snapshot.status == .paused { env.resumeFocus(); return }
        if snapshot.isOverrun { finish(); return }
        env.pauseFocus()
    }

    /// 结束这次投入并直接写入记录。
    ///
    /// 投入时长取 `FocusPolicy.recordedMinutes`，不再弹「这次投入」让人确认一遍：
    /// 那个数本来就是系统按计划时长或有效已用时长算出来的，确认框只是让用户复述一次。
    /// 这一页上有三处会结束（主按钮、文字按钮、久置横幅），都是同一件事，收在这里。
    private func finish() {
        _Concurrency.Task { await env.finishFocus() }
    }

    /// 计时中盘下面那一两句话。
    ///
    /// 只有两种状态需要解释，而且两句说的都是「看数字看不出来」的事：
    /// 暂停要说清继续之后从哪接着走，到点后还在超出要说清它不会自己结束
    /// （不说，用户会坐在那儿等它自己停）。
    /// 正常计时返回空——原来那句「暂停期间不计入投入」写的是规则，不是此刻的信息。
    private func stateNotes(_ snapshot: FocusPolicy.Snapshot) -> [String] {
        if snapshot.status == .paused {
            let remaining = snapshot.remainingSeconds.map { FocusPolicy.clockText($0) }
            var notes = [remaining.map { "继续后从 \($0) 接着走" } ?? "继续后接着累计"]
            if let pausedText = snapshot.pausedDurationText { notes.append(pausedText) }
            return notes
        }
        if snapshot.isOverrun { return ["到点后仍在计时，不会自动结束。"] }
        return []
    }

    private func textAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(MovoFont.bodyEmphasis).foregroundStyle(MovoColor.muted)
                .frame(minHeight: MovoSpace.minTouch)
                .padding(.horizontal, MovoSpace.s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    #if os(iOS)
    /// 36×5 的收起胶囊：下拉收起，回到进入前的上下文。
    private var collapseCapsule: some View {
        Capsule()
            .fill(MovoColor.line)
            .frame(width: 36, height: 5)
            .padding(.vertical, MovoSpace.s)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture().onEnded { value in
                if value.translation.height > 60 { dismiss() }
            })
            .accessibilityLabel("收起计时页")
    }
    #endif

    // MARK: 任务不在了

    @ViewBuilder
    private var missingTask: some View {
        ScreenScroll {
            ScreenChrome("专注")
            let session = env.activeFocus(for: taskID)
            MovoBanner(kind: .warning, title: "这项待办已经不在了",
                       message: session == nil
                           ? "它可能已经被删除。"
                           : "它可能已经被删除。这次投入仍然发生过，结束会把它记下来。")
            if session != nil {
                VStack(alignment: .leading, spacing: MovoSpace.s) {
                    FocusPrimaryButton("结束并记录", systemImage: "stop.fill") {
                        // 这一页在会话结束之后什么也不剩（任务已经不在，没有「未开始」可回），
                        // 所以写完就收起，不留一个再也点不动的页面。
                        _Concurrency.Task {
                            await env.finishFocus()
                            dismiss()
                        }
                    }
                    MovoButton("放弃", kind: .secondary) {
                        env.discardFocus()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: 内部

    private func reload() async {
        task = await env.store.repository.task(taskID)
        loaded = true
    }
}

// MARK: - 补记一次行动

/// 不启动计时而直接补记。写入的结构与计时结束完全相同，
/// 所以撤销、导出与统计的口径一致；差别只在「发生时间」可以改成过去。
public struct LogActivitySheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let taskTitle: String
    let taskID: UUID

    @State private var minutesText = ""
    @State private var minutesError: String?
    @State private var note = ""
    @State private var happened = TimePointDraft()
    @State private var preparing = false

    public init(taskTitle: String, taskID: UUID) {
        self.taskTitle = taskTitle
        self.taskID = taskID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MovoSpace.m) {
            Text("记录一次行动").font(MovoFont.title2).foregroundStyle(MovoColor.ink)
            Text(taskTitle).font(MovoFont.caption).foregroundStyle(MovoColor.muted)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)

            EstimateMinutesField("投入时长", text: $minutesText,
                                 placeholder: "不填就只留一条记录",
                                 errorMessage: minutesError,
                                 showsSteppers: true,
                                 chips: [15, 25, 30, 45, 60])
                .onChange(of: minutesText) { _, new in
                    minutesError = EstimateMinutes.parse(new, subject: "投入时长").invalidMessage
                }

            MovoTextField("说明", text: $note, placeholder: "补一句说明（可选）", axis: .vertical)

            MovoTimePointField("发生时间", placeholder: "未设置（默认记到现在）",
                               draft: $happened, timeZone: env.store.currentTimeZone)

            Text("记录投入不等于任务完成；要标记完成请单独操作。")
                .font(MovoFont.caption).foregroundStyle(MovoColor.muted)

            FocusPrimaryButton("保存记录", systemImage: "checkmark", isLoading: preparing) {
                submit()
            }
            MovoButton("取消", kind: .quiet, isEnabled: !preparing) { dismiss() }
        }
        .padding(MovoSpace.l)
        .onAppear {
            happened = TimePointDraft(.instant(DateTimeTZ(env.store.now, in: env.store.currentTimeZone)),
                                      fallback: env.store.now)
        }
        #if os(macOS)
        .frame(minWidth: 420)
        #endif
    }

    private func submit() {
        let input = EstimateMinutes.parse(minutesText, subject: "投入时长")
        guard !input.isInvalid else {
            minutesError = input.invalidMessage
            return
        }
        minutesError = nil
        preparing = true
        let time = timeValue(happened.point(in: env.store.currentTimeZone))
        _Concurrency.Task {
            await env.logActivity(taskID: taskID, minutes: input.value, note: note, happenedAt: time)
            preparing = false
            dismiss()
        }
    }

    /// 可以改成过去：点选的是「某一天」就按天记，选了钟点就按时刻记，
    /// 没开开关就记到现在。
    private func timeValue(_ point: TimePoint?) -> TimeValue {
        switch point {
        case .instant(let instant): return .precise(instant.epoch)
        case .day(let day): return .day(day)
        case nil: return .precise(env.store.now)
        }
    }
}

// MARK: - 共用小件

/// 主按钮：端到端撑满、高 52、左右留 24。
struct FocusPrimaryButton: View {
    private let title: String
    private let systemImage: String?
    private let isLoading: Bool
    private let action: () -> Void

    init(_ title: String, systemImage: String? = nil, isLoading: Bool = false,
         action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage
        self.isLoading = isLoading; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: MovoSpace.s) {
                if isLoading {
                    ProgressView().controlSize(.small).tint(MovoColor.onPrimary)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title).font(MovoFont.bodyEmphasis)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: MovoRadius.button, style: .continuous)
                .fill(MovoColor.primary))
            .foregroundStyle(MovoColor.onPrimary)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel(title)
    }
}
