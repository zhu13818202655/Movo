//
//  AppEnvironment+Focus.swift
//  App
//
//  专注计时的应用层接线：入口、状态迁移、结束写入、补记。
//
//  三条进入路径（任务详情、清单行、补记）最终落到同一组写入命令，界面不另建规则；
//  所以这里只做一件事——把 `FocusPolicy` 算出来的东西交给领域层，再把结果与
//  进行中的会话交回给界面。
//
//  「结束」与「放弃」在这里分流：结束写一条行动记录，放弃不写。
//  标记完成是另一条独立命令，与记录投入分开提交——记录投入不等于任务完成。
//
//  到点提醒不在这里另建一套排期：计时状态一变就整体重排一次通知，
//  暂停时它自然从排期里消失（撤销），继续时按新的有效终点回来。
//  这样「提醒」与「计时」永远只有一份真相——当前这个会话。
//

import Foundation
import MovoKit

/// 计时页与任务详情顶上那条一次性提示。
///
/// 标题跟着来由走，不写死在视图里：「开始被拦下」与「这次按计划时长记下了」是两个不同的来由，
/// 视图写死一个标题，另一条就会顶着一个不对题的标题出现。
public struct FocusNotice: Sendable, Equatable {
    public var title: String
    public var message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

extension AppEnvironment {

    // MARK: - 会话读写

    /// 把会话写进内存与本机。会话只在两个时刻变化：用户按了按钮，或计时结束。
    ///
    /// 同时重排一次通知：到点提醒的有无与时刻完全由这个会话决定，
    /// 所以「保存会话」与「重排提醒」是同一件事的两半，放在一起就不会漏。
    /// 重排是异步且幂等的，不阻塞按下按钮的那一帧。
    func setFocusSession(_ session: FocusPolicy.Session?) {
        focusSession = session
        focusSessionStore.save(session)
        rescheduleFocusReminder()
    }

    /// 按当前会话重排到点提醒。暂停时排期里没有这条提醒，因此等于撤销；
    /// 继续时按 `effectiveEnd` 重新算出来的终点回来。合并成一次整体替换。
    private func rescheduleFocusReminder() {
        _Concurrency.Task { _ = await refreshNotifications() }
    }

    /// 这项任务自己的会话；别的任务在计时时为 nil。
    public func activeFocus(for taskID: UUID) -> FocusPolicy.Session? {
        guard let session = focusSession, session.taskID == taskID else { return nil }
        return session
    }

    /// 有没有任何一次计时在进行。
    public var isFocusing: Bool { focusSession != nil }

    /// 久置提示处理完之后收起，不重复打扰。
    public func dismissFocusStaleness() { focusStaleness = nil }

    public func clearFocusNotice() { focusNotice = nil }

    // MARK: - 推导与显示

    /// 这项任务「开始专注」会开成什么形态。入口按钮的副文案也用它。
    public func focusPlan(for task: Task) -> FocusPolicy.Plan {
        FocusPolicy.plan(startAt: task.startAt, endAt: task.endAt,
                         estimateMinutes: task.estimateMinutes,
                         now: store.now, timeZone: store.currentTimeZone)
    }

    /// 当前时刻要显示的数字与文案。视图不再自己算剩余时间。
    public func focusSnapshot(_ session: FocusPolicy.Session, at now: Date) -> FocusPolicy.Snapshot {
        FocusPolicy.snapshot(session, at: now,
                             stalenessThresholdHours: defaults.focus.staleSessionHours)
    }

    /// 结束浮层里的默认投入时长。
    public func focusDefaultMinutes(_ session: FocusPolicy.Session, at now: Date) -> Int {
        FocusPolicy.recordedMinutes(session, at: now,
                                    truncateAtAnchor: defaults.focus.truncateDurationAtAnchor,
                                    graceMinutes: defaults.focus.truncateGraceMinutes)
    }

    /// 默认值是否被「到点后拖延」截断过。界面据此决定要不要解释一句。
    public func focusIsTruncated(_ session: FocusPolicy.Session, at now: Date) -> Bool {
        FocusPolicy.recordedSeconds(session, at: now,
                                    truncateAtAnchor: defaults.focus.truncateDurationAtAnchor,
                                    graceMinutes: defaults.focus.truncateGraceMinutes)
            < FocusPolicy.elapsedSeconds(session, at: now)
    }

    // MARK: - 开始 / 暂停 / 继续

    /// 开始一次专注。
    ///
    /// 已经有另一次在跑时**不静默顶掉**：把正在进行的那一项说出来，由用户决定先结束它。
    /// 静默替换会让用户丢掉一段真实的投入，而存储层也存不下两条。
    /// 返回是否已经开始。
    @discardableResult
    public func beginFocus(_ task: Task) -> Bool {
        if let running = focusSession, running.taskID != task.id {
            let title = running.taskTitle.isEmpty ? "另一项待办" : running.taskTitle
            focusNotice = FocusNotice(title: "这次没有开始",
                                      message: "「\(title)」正在计时，先结束那一次再开始新的。")
            return false
        }
        focusNotice = nil
        focusStaleness = nil
        let session = FocusPolicy.start(focusPlan(for: task), taskID: task.id,
                                        taskTitle: task.title, at: store.now)
        setFocusSession(session)
        return true
    }

    public func pauseFocus() {
        guard let session = focusSession, !session.isPaused else { return }
        setFocusSession(FocusPolicy.pause(session, at: store.now))
    }

    public func resumeFocus() {
        guard let session = focusSession, session.isPaused else { return }
        setFocusSession(FocusPolicy.resume(session, at: store.now))
    }

    // MARK: - 结束 / 放弃

    /// 结束这次专注并写入记录——**不问用户要不要确认**。
    ///
    /// 投入时长由 `FocusPolicy.recordedMinutes` 算好：倒计时取计划时长、正计时取有效已用时长，
    /// 到点后拖延超过宽限的按锚点截断。按下「结束」时用户想的是「我不做了」，
    /// 再弹一层问他要记多久，只是让他把系统刚刚算出来的那个数复述一遍。
    ///
    /// 想补一句说明或另记一段时间，走「记录一次行动」那条补记路径；那条路径是「补」，
    /// 与「结束」共用一个记录结构，口径一致。
    public func finishFocus() async {
        guard let session = focusSession else { return }
        let minutes = focusDefaultMinutes(session, at: store.now)
        let wasTruncated = focusIsTruncated(session, at: store.now)
        await finishFocus(minutes: minutes, note: nil, markComplete: false)
        // 上面那条结尾会清掉上一轮的提示，所以这条要写在它之后。
        // 到点后拖延超过宽限的按锚点截断，记下的数并不等于实际坐了多久；
        // 撤掉确认框之后，这件事只剩这里还能说一句。不说，用户就只看到
        // 一条「30 分钟」的记录，并以为自己被记错了。
        if wasTruncated {
            focusNotice = FocusNotice(
                title: "已按计划时长记下",
                message: "到点之后一直没有回来，这次按计划时长 \(minutes) 分钟记下了。")
        }
    }

    /// 结束这次专注并写入记录。
    ///
    /// `minutes` 传 nil 表示只留一条不带投入时长的记录。`markComplete` 是另一条命令，
    /// 与记录投入分开提交；任务已经被标记完成时不再重复写。
    public func finishFocus(minutes: Int?, note: String?, markComplete: Bool) async {
        guard let session = focusSession else { return }
        let noteText = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        // 任务可能在这期间被删除或移入最近删除。删掉之后这次投入仍然发生过，
        // 所以找不到任务时只写记录、不写完成——这条记录既不带计划也不带任务。
        let task = await store.repository.task(session.taskID)

        var log = LogActivity(happenedAt: .precise(session.startedAt),
                              durationMinutes: minutes,
                              text: (noteText?.isEmpty ?? true) ? nil : noteText,
                              source: .manual)
        log.taskID = task?.id
        do {
            try await store.execute(log)
            lastBatchNotice = store.lastNotification
        } catch let error as MovoError {
            lastError = error
        } catch {
            lastError = .invalidStructure(reason: "这次投入没有记下来。")
        }

        // 分开提交：上一条失败也不影响这一条，反之亦然。
        if markComplete, let task, task.status.isOpen {
            do {
                try await store.execute(CompleteTask(taskID: task.id, at: .precise(store.now),
                                                     baseRevision: task.revision))
            } catch let error as MovoError {
                lastError = error
            } catch {
                lastError = .invalidStructure(reason: "没有标记成完成。")
            }
        }

        setFocusSession(nil)
        focusStaleness = nil
        focusNotice = nil
    }

    /// 放弃这次计时：不写记录，也不产生可撤销项。用于误触。
    public func discardFocus() {
        setFocusSession(nil)
        focusStaleness = nil
        focusNotice = nil
    }

    // MARK: - 补记一次行动

    /// 不启动计时，直接补记一次已经发生的投入。
    /// 写入的结构与计时结束完全相同，因此撤销、导出与统计口径一致。
    public func logActivity(taskID: UUID, minutes: Int?, note: String?,
                            happenedAt: TimeValue) async {
        let noteText = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await store.execute(LogActivity(taskID: taskID,
                                                happenedAt: happenedAt,
                                                durationMinutes: minutes,
                                                text: (noteText?.isEmpty ?? true) ? nil : noteText,
                                                source: .manual))
            lastBatchNotice = store.lastNotification
        } catch let error as MovoError {
            lastError = error
        } catch {
            lastError = .invalidStructure(reason: "这条记录没有保存成功。")
        }
    }

    /// 更正一条已经写下的行动记录。
    ///
    /// 注意它不是「覆盖」：`CorrectActivity` 新写一条带 `isCorrection` 的记录指回原来那条，
    /// 旧版本留在库里与导出里（PRD 3.4）。所以列行动记录的地方要按「当前值」过滤一次
    /// （`CorrectionHistory.current`），否则改完会看到两条。
    public func correctActivity(_ command: CorrectActivity) async {
        do {
            try await store.execute(command)
            lastBatchNotice = store.lastNotification
        } catch let error as MovoError {
            lastError = error
        } catch {
            lastError = .invalidStructure(reason: "这条更正没有保存成功。")
        }
    }
}
