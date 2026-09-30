import Foundation
import CryptoKit

/// 同一份已保存提案在重试、重开应用后仍使用相同操作标识。
public struct CaptureCommand: DomainCommand {
    public let operationID: UUID
    private let command: any DomainCommand
    public var kind: OperationKind { command.kind }
    public var entityID: UUID { command.entityID }
    public var entityType: EntityType { command.entityType }
    public var baseRevision: Int { command.baseRevision }

    public init(_ command: any DomainCommand, captureID: UUID, key: String) {
        self.command = command
        self.operationID = Self.stableID(captureID: captureID, key: key)
    }

    public static func stableID(captureID: UUID, key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data((captureID.uuidString + "|" + key).utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           (bytes[6] & 0x0f) | 0x50, bytes[7], (bytes[8] & 0x3f) | 0x80,
                           bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public static func batchID(for captureID: UUID) -> UUID {
        stableID(captureID: captureID, key: "batch")
    }

    @MainActor
    public func execute(in context: CommandContext) async throws -> CommandResult {
        var result = try await command.execute(in: context)
        result.operationID = operationID
        return result
    }
}

/// 回放本机已保存的模型提案；仍须经过当前隐私与领域校验，不产生网络请求。
public struct SavedProposalProvider: AIProvider {
    public var proposal: AIProposal
    public init(proposal: AIProposal) { self.proposal = proposal }
    public var id: AIVendor { proposal.provider.flatMap(AIVendor.init(rawValue:)) ?? .deepseek }
    public var displayName: String { "已保存的整理结果" }
    public var currentModel: String { proposal.model ?? "saved" }
    public func availableModels() -> [ModelInfo] { [] }
    public func testConnection() async throws { }
    public func proposeOperations(_ input: AIInput) async throws -> AIProposal { proposal }
}
