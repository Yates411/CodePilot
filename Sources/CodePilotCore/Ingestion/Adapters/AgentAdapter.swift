import Foundation

public enum AdapterHealth: Equatable, Sendable {
    case idle
    case active(watchedPath: String)
    case notInstalled
    case permissionDenied(path: String)
    case error(String)

    public var displayText: String {
        switch self {
        case .idle:
            return "未启动"
        case .active:
            return "正常监听中"
        case .notInstalled:
            return "未检测到安装目录"
        case .permissionDenied:
            return "无权访问日志目录"
        case .error(let msg):
            return "异常：\(msg)"
        }
    }
}

public protocol AgentAdapter: AnyObject, Sendable {
    var source: AgentSource { get }
    var healthStatus: AdapterHealth { get }
    func start(emit: @escaping @Sendable (TaskEvent) -> Void)
    func stop()
    func pollIfNeeded()
}

public extension AgentAdapter {
    func pollIfNeeded() {}
}
