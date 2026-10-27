import Foundation

final class PhoneCaptureUploadClient: @unchecked Sendable {
    static let phoneCapturePath = "/internal/trial/{session_id}/phone_capture"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func path(sessionID: String) -> String {
        phoneCapturePath.replacingOccurrences(of: "{session_id}", with: sessionID)
    }

    func upload(
        archiveURL: URL,
        sessionID: String,
        baseURL: URL,
        token: String
    ) async throws {
        guard let url = BackendEndpoint.httpURL(
            base: baseURL,
            path: Self.path(sessionID: sessionID)
        ) else {
            throw TrialAPIError.invalidBackendURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "attachment; filename=\"\(sessionID)-phone-capture.zip\"",
            forHTTPHeaderField: "Content-Disposition"
        )
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Trial-Token")
        }
        let (data, response) = try await session.upload(for: request, fromFile: archiveURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrialAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(UploadServerError.self, from: data))?.error
            throw TrialAPIError.http(status: httpResponse.statusCode, message: message)
        }
    }
}

private struct UploadServerError: Decodable {
    let error: String
}
