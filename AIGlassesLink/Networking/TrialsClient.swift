import Foundation

struct ServerTrial: Decodable, Sendable {
    let id: String
    let trial: String?
    let participant: String?
    let site: String?
    let condition: String?
    let sensorSource: String?
    let status: String?
    let date: String?
    let turnCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, trial, participant, site, condition, status, date
        case sensorSource = "sensor_source"
        case turnCount = "turn_count"
    }
}

final class TrialsClient: @unchecked Sendable {
    static let trialsPath = "/api/trials"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchTrials(baseURL: URL, token: String) async throws -> [ServerTrial] {
        guard let url = BackendEndpoint.httpURL(base: baseURL, path: Self.trialsPath) else {
            throw TrialAPIError.invalidBackendURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Trial-Token")
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrialAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(TrialsServerError.self, from: data))?.error
            throw TrialAPIError.http(status: httpResponse.statusCode, message: message)
        }
        return try JSONDecoder().decode(TrialsResponse.self, from: data).trials
    }
}

private struct TrialsResponse: Decodable {
    let trials: [ServerTrial]
}

private struct TrialsServerError: Decodable {
    let error: String
}
