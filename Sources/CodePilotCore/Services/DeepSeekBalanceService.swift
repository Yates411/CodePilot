import Foundation

public struct DeepSeekBalanceSnapshot: Equatable, Sendable {
    public let isAvailable: Bool
    public let currency: String
    public let totalBalance: Double
    public let grantedBalance: Double
    public let toppedUpBalance: Double
    public let fetchedAt: Date

    public init(
        isAvailable: Bool,
        currency: String,
        totalBalance: Double,
        grantedBalance: Double,
        toppedUpBalance: Double,
        fetchedAt: Date = Date()
    ) {
        self.isAvailable = isAvailable
        self.currency = currency
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = toppedUpBalance
        self.fetchedAt = fetchedAt
    }

    public var formattedTotal: String {
        let symbol = (currency.uppercased() == "CNY") ? "¥" : (currency.uppercased() == "USD" ? "$" : "\(currency) ")
        return String(format: "%@%.2f", symbol, totalBalance)
    }
}

public enum DeepSeekBalanceError: Error, LocalizedError, Sendable {
    case invalidKey
    case httpStatus(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidKey: return "API Key 应以 sk- 开头"
        case .httpStatus(let code): return "查询失败（HTTP \(code)）"
        case .invalidResponse: return "返回数据格式异常"
        }
    }
}

public struct DeepSeekBalanceService: Sendable {
    public static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!

    public init() {}

    public func fetchBalance(apiKey: String) async throws -> DeepSeekBalanceSnapshot {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-"), trimmed.count >= 10 else {
            throw DeepSeekBalanceError.invalidKey
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekBalanceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DeepSeekBalanceError.httpStatus(http.statusCode)
        }

        return try Self.parseResponse(data: data)
    }

    public static func parseResponse(data: Data, now: Date = Date()) throws -> DeepSeekBalanceSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = root["balance_infos"] as? [[String: Any]],
              let first = infos.first(where: { ($0["currency"] as? String)?.uppercased() == "CNY" }) ?? infos.first else {
            throw DeepSeekBalanceError.invalidResponse
        }

        let isAvailable = (root["is_available"] as? Bool) ?? true
        let currency = (first["currency"] as? String) ?? "CNY"
        let total = Double((first["total_balance"] as? String) ?? "") ?? (first["total_balance"] as? Double) ?? 0
        let granted = Double((first["granted_balance"] as? String) ?? "") ?? (first["granted_balance"] as? Double) ?? 0
        let toppedUp = Double((first["topped_up_balance"] as? String) ?? "") ?? (first["topped_up_balance"] as? Double) ?? 0

        return DeepSeekBalanceSnapshot(
            isAvailable: isAvailable,
            currency: currency,
            totalBalance: total,
            grantedBalance: granted,
            toppedUpBalance: toppedUp,
            fetchedAt: now
        )
    }
}
