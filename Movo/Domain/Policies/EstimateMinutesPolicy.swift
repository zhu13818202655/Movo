//
//  EstimateMinutesPolicy.swift
//  Domain/Policies
//
//  预计投入的取值规则与措辞。
//
//  领域层的 `CreateTask` / `TaskPatch` 只把它当可选整数，不校验取值范围；这里收口
//  「什么算合法的预计投入」与「未设置怎么写」，供新建、就地编辑、任务详情三个入口共用，
//  也供专注计时推导倒计时长度时判断这个值能不能用。
//
//  空串是合法的「未设置」，非法输入必须单独一态：否则「打错了」会被当成「清空」静默写入。
//

import Foundation

public enum EstimateMinutes {
    /// 一次输入的解析结果。
    public enum Input: Equatable, Sendable {
        case unset
        case minutes(Int)
        case invalid(String)

        /// 可以直接写进 `CreateTask` / `TaskPatch` 的值；`unset` 与 `invalid` 都是 nil。
        public var value: Int? {
            if case .minutes(let value) = self { return value }
            return nil
        }

        public var isInvalid: Bool {
            if case .invalid = self { return true }
            return false
        }

        /// 非法输入时的提示文字；其余两态为 nil，方便直接绑给输入框的错误提示。
        public var invalidMessage: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    /// 解析用户输入。只接受正整数分钟，空串表示未设置。
    ///
    /// - Parameter subject: 出现在「要大于 0 分钟」这句里的名词。
    ///   行动记录的「投入时长」与任务的「预计投入」取值规则完全相同，只有措辞不同——
    ///   同一条规则不该有两个实现，否则两处迟早会漂移。
    public static func parse(_ text: String, subject: String = "预计投入") -> Input {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unset }
        guard let minutes = Int(trimmed) else { return .invalid("请填整数分钟，例如 30。") }
        guard minutes > 0 else { return .invalid("\(subject)要大于 0 分钟。") }
        return .minutes(minutes)
    }

    /// 编辑框里的初始文字。未设置时给空串，由占位符表达「未设置」。
    public static func text(for minutes: Int?) -> String {
        minutes.map(String.init) ?? ""
    }

    /// 只读展示的措辞，与「开始时间 / 结束时间」两行的「未设置」保持一致。
    public static func displayText(for minutes: Int?) -> String {
        guard let minutes else { return "未设置" }
        return "\(minutes) 分钟"
    }
}
