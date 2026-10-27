import Foundation

final class TrialAPIClient: @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func startTrial(
        _ trial: TrialFormData,
        baseURL: URL,
        token: String
    ) async throws -> String {
        guard let url = BackendEndpoint.httpURL(base: baseURL, path: "/internal/trial") else {
            throw TrialAPIError.invalidBackendURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyToken(token, to: &request)
        request.httpBody = try JSONEncoder().encode(trial)
        let data = try await responseData(for: request)
        let response = try JSONDecoder().decode(TrialStartResponse.self, from: data)
        guard !response.sessionID.isEmpty else { throw TrialAPIError.missingSessionID }
        return response.sessionID
    }

    func endTrial(baseURL: URL, token: String) async throws {
        guard let url = BackendEndpoint.httpURL(base: baseURL, path: "/internal/trial/end") else {
            throw TrialAPIError.invalidBackendURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyToken(token, to: &request)
        request.httpBody = Data("{}".utf8)
        _ = try await responseData(for: request)
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrialAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let serverMessage = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
            throw TrialAPIError.http(status: httpResponse.statusCode, message: serverMessage)
        }
        return data
    }

    private func applyToken(_ token: String, to request: inout URLRequest) {
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Trial-Token")
        }
    }
}

private struct TrialStartResponse: Decodable {
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }
}

private struct ServerError: Decodable {
    let error: String
}

enum TrialAPIError: LocalizedError {
    case invalidBackendURL
    case invalidResponse
    case missingSessionID
    case http(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidBackendURL: "Enter a valid HTTP or HTTPS backend URL in Settings."
        case .invalidResponse: "The backend returned an invalid response."
        case .missingSessionID: "The backend did not return a session_id."
        case let .http(status, message): message ?? "Backend request failed (HTTP \(status))."
        }
    }
}
