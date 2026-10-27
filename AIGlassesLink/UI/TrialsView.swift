import SwiftUI
import WebKit

struct TrialsView: View {
    @ObservedObject var model: TrialsModel

    var body: some View {
        NavigationStack {
            List {
                if let error = model.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                ForEach(model.rows) { row in
                    if let url = model.detailURL(for: row) {
                        NavigationLink {
                            TrialWebView(
                                url: url,
                                token: model.backendSettings.trialToken
                            )
                            .navigationTitle(row.sessionID)
                            .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            trialLabel(row)
                        }
                    } else {
                        trialLabel(row)
                    }
                }
            }
            .overlay {
                if model.rows.isEmpty && !model.isLoading {
                    ContentUnavailableView(
                        "No trials",
                        systemImage: "tray",
                        description: Text("Recorded trials and pending phone uploads appear here.")
                    )
                }
            }
            .refreshable { await model.refresh() }
            .navigationTitle("Trials")
            .toolbar {
                if model.isLoading { ProgressView() }
            }
            .task {
                guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
                    return
                }
                await model.refresh()
            }
        }
    }

    private func trialLabel(_ row: TrialListRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.sessionID).font(.headline)
                Spacer()
                if let status = row.serverStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text([
                row.site,
                row.condition,
                row.sensorSource,
            ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if let turns = row.turnCount {
                    Label("\(turns) turns", systemImage: "text.bubble")
                }
                if let status = row.phoneCaptureStatus {
                    Label(uploadLabel(status), systemImage: uploadIcon(status))
                        .foregroundStyle(uploadColor(status))
                    if status == .uploaded {
                        let archived = PhoneCaptureUploadReceipt.isArchived(row.phoneCaptureR2Status)
                        Label(
                            archived ? "archived" : "on server, not archived",
                            systemImage: archived ? "archivebox.fill" : "archivebox"
                        )
                        .foregroundStyle(archived ? .green : .secondary)
                    }
                }
            }
            .font(.caption)
            if let error = row.phoneCaptureError, row.phoneCaptureStatus != .uploaded {
                Text(row.phoneCaptureStatus == .failed ? "\(error) Local copy kept." : error)
                    .font(.caption)
                    .foregroundStyle(row.phoneCaptureStatus == .failed ? .red : .orange)
            }
            if row.phoneCaptureStatus == .failed {
                Button {
                    model.retryUpload(for: row)
                } label: {
                    Label("Retry upload", systemImage: "arrow.clockwise.icloud")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

private func uploadLabel(_ status: PhoneCaptureUploadState) -> String {
    switch status {
    case .uploaded: "uploaded"
    case .failed: "upload failed"
    case .pending, .uploading: "pending"
    }
}

private func uploadIcon(_ status: PhoneCaptureUploadState) -> String {
    switch status {
    case .uploaded: "checkmark.icloud.fill"
    case .failed: "exclamationmark.icloud.fill"
    case .pending, .uploading: "icloud.and.arrow.up"
    }
}

private func uploadColor(_ status: PhoneCaptureUploadState) -> Color {
    switch status {
    case .uploaded: .green
    case .failed: .red
    case .pending, .uploading: .orange
    }
}

private struct TrialWebView: UIViewRepresentable {
    let url: URL
    let token: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        var request = URLRequest(url: url)
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Trial-Token")
        }
        guard !token.isEmpty, let host = url.host else {
            webView.load(request)
            return webView
        }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: host,
            .path: "/",
            .name: "trial_token",
            .value: token,
            .expires: Date().addingTimeInterval(12 * 60 * 60),
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ]
        if url.scheme == "https" { properties[.secure] = "TRUE" }
        if let cookie = HTTPCookie(properties: properties) {
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                webView.load(request)
            }
        } else {
            webView.load(request)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
