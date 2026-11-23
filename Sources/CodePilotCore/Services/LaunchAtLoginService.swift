import Foundation
import ServiceManagement

@MainActor
public final class LaunchAtLoginService {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已开启"
        case .requiresApproval: return "需在系统设置中批准"
        case .notRegistered: return "未开启"
        case .notFound: return "未找到应用包"
        @unknown default: return "未知"
        }
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
