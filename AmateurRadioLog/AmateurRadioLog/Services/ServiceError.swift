import Foundation

enum ServiceError: Error, LocalizedError {
    case notAuthenticated
    case authenticationFailed(String)
    case networkError(String)
    case parseError(String)
    case serverError(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated. Please check your credentials."
        case .authenticationFailed(let msg): return "Authentication failed: \(msg)"
        case .networkError(let msg): return "Network error: \(msg)"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .serverError(let msg): return "Server error: \(msg)"
        case .notFound(let msg): return "Not found: \(msg)"
        }
    }
}
