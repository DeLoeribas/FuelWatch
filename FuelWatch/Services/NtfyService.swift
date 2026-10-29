import Foundation

/// Where ntfy messages go: a server and a topic the phone is subscribed to.
struct NtfyConfig: Equatable, Sendable {
    static let defaultServer = "https://ntfy.sh"

    var server: String
    var topic: String

    var isComplete: Bool {
        URL(string: server)?.host() != nil && !topic.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A random topic name; on the public ntfy.sh server anyone who knows the name can read it.
    static func randomTopic() -> String {
        "fuelwatch-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
    }
}

/// Sends push messages through ntfy (https://ntfy.sh), e.g. to the ntfy iPhone app.
struct NtfyService: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(title: String, message: String, click: URL? = nil, tags: [String] = ["fuelpump"], to config: NtfyConfig) async throws {
        let (_, response) = try await session.data(for: Self.request(title: title, message: message, click: click, tags: tags, config: config))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FuelWatchError.badResponse(http.statusCode)
        }
    }

    private struct Payload: Encodable {
        let topic: String
        let title: String
        let message: String
        let tags: [String]
        let click: String?
    }

    /// Builds a JSON publish request, which keeps accented text and € intact (headers would need encoding).
    static func request(title: String, message: String, click: URL?, tags: [String], config: NtfyConfig) throws -> URLRequest {
        guard config.isComplete, let url = URL(string: config.server) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(
            topic: config.topic.trimmingCharacters(in: .whitespaces),
            title: title,
            message: message,
            tags: tags,
            click: click?.absoluteString))
        return request
    }
}
