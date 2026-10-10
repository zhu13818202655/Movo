//
//  CorrectionHistoryPolicy.swift
//  Domain/Policies
//
//  更正链上「哪一条是当前值」。
//
//  更正不改写原来那条（PRD 3.4 要求保留旧版本）：改行动记录、改测量都会新写一条，
//  用 `correctedFromId` 指回被改的那条。于是库里同时存在新旧两条，而界面要回答的是
//  「我到底投入了多少 / 现在是哪个值」——旧值混在中间，这个问题就没有答案了。
//
//  所以凡是「读当前值」的地方都过一遍 `current(_:)`：被别的记录指向过的不再出现。
//  旧版本仍然在库里、在导出里、在更正记录的 back-reference 里，只是不在这里再重复一遍。
//
//  行动记录（任务详情的「行动记录」、计划详情的记录列表、导出）和测量（导出）用的是同一条
//  规则，所以这里做成对两类记录都成立的泛型，避免同一段过滤散成好几份。
//

import Foundation

/// 会进更正链的记录：有 id，并且可能指回被自己取代的那条。
public protocol CorrectionChained {
    var id: UUID { get }
    var correctedFromId: UUID? { get }
}

extension ActionRecord: CorrectionChained {}
extension Measurement: CorrectionChained {}

public enum CorrectionHistory {
    /// 当前有效的那几条，保持传入顺序。
    ///
    /// 连改两次也成立：A → B → C 时 B 也被 C 指向过，结果只剩 C。
    public static func current<Record: CorrectionChained>(_ records: [Record]) -> [Record] {
        let superseded = Set(records.compactMap(\.correctedFromId))
        return records.filter { !superseded.contains($0.id) }
    }
}
