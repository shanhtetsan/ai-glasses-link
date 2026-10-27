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
    ) async throws -> PhoneCaptureUploadReceipt {
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
        return PhoneCaptureUploadReceipt.decode(data)
    }
}

/// What a 200 upload response says about the R2 archive copy.
struct PhoneCaptureUploadReceipt: Equatable, Sendable {
    /// Raw r2 status from the server, e.g. "done"; nil if the body had none.
    let r2Status: String?

    static func decode(_ data: Data) -> PhoneCaptureUploadReceipt {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return PhoneCaptureUploadReceipt(r2Status: nil)
        }
        let value = object["r2"]
        if let text = value as? String { return .init(r2Status: text) }
        if let flag = value as? Bool { return .init(r2Status: flag ? "done" : "pending") }
        if let nested = value as? [String: Any] {
            return .init(r2Status: (nested["status"] ?? nested["state"]) as? String)
        }
        return .init(r2Status: nil)
    }

    static func isArchived(_ r2Status: String?) -> Bool {
        r2Status?.lowercased() == "done"
    }
}

private struct UploadServerError: Decodable {
    let error: String
}
