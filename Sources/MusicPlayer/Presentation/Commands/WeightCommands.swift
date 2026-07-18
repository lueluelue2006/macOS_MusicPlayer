import Foundation

/// 封装与随机权重相关的用户命令，统一处理设置失败时的提示。
enum WeightCommands {
    static func handleSetWeightResult(_ result: PlaybackWeights.MutationResult) {
        switch result {
        case .applied, .unchanged:
            break
        case .rejectedReadOnly(let reason):
            NotificationCenter.default.post(
                name: .showAppToast,
                object: nil,
                userInfo: [
                    "title": "无法修改随机权重",
                    "subtitle": reason.diagnosticMessage,
                    "kind": "error",
                    "duration": 4.0
                ]
            )
        }
    }
}
