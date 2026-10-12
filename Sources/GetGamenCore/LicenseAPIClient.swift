import Foundation

/// Separates "explicitly invalid" from "could not check" so an outage never locks users out.
enum LicenseValidationOutcome: Equatable, Sendable {
    case valid
    case invalid
    case unreachable
}

enum LicenseDeactivationOutcome: Equatable, Sendable {
    case released
    case rejected
    case unreachable
}

enum LicenseActivationOutcome: Equatable, Sendable {
    case activated(instanceID: String)
    case invalidKey
    case activationLimitReached
    case unreachable
}

protocol LicenseAPIClient: Sendable {
    func activate(key: String, instanceName: String) async -> LicenseActivationOutcome
    func validate(key: String, instanceID: String) async -> LicenseValidationOutcome
    func deactivate(key: String, instanceID: String) async -> LicenseDeactivationOutcome
}

/// Lemon Squeezy License API (form-encoded POST, no auth header).
/// https://docs.lemonsqueezy.com/api/license-api
/// The key never appears in logs or error text.
struct LemonSqueezyLicenseClient: LicenseAPIClient {
    private static let base = URL(string: "https://api.lemonsqueezy.com/v1/licenses")!

    func activate(key: String, instanceName: String) async -> LicenseActivationOutcome {
        Self.activationOutcome(from: await post("activate", ["license_key": key, "instance_name": instanceName]))
    }

    func validate(key: String, instanceID: String) async -> LicenseValidationOutcome {
        Self.validationOutcome(from: await post("validate", ["license_key": key, "instance_id": instanceID]))
    }

    func deactivate(key: String, instanceID: String) async -> LicenseDeactivationOutcome {
        Self.deactivationOutcome(from: await post("deactivate", ["license_key": key, "instance_id": instanceID]))
    }

    /// statusCode nil means a transport failure (offline, timeout).
    struct HTTPResult {
        var statusCode: Int?
        var body: Data?
    }

    private func post(_ path: String, _ fields: [String: String]) async -> HTTPResult {
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = Self.formBody(fields)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return HTTPResult(statusCode: (response as? HTTPURLResponse)?.statusCode, body: data)
        } catch {
            return HTTPResult(statusCode: nil, body: nil)
        }
    }

    /// URLComponents leaves "+" as is, and a form decoder reads it as a space (a computer name can contain "+").
    static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }

    private struct ResponseBody: Decodable {
        struct Instance: Decodable { var id: String? }
        var activated: Bool?
        var valid: Bool?
        var deactivated: Bool?
        var error: String?
        var instance: Instance?
    }

    /// nil = unreachable (transport error, 5xx, 429, or a body that is not the API's JSON, such as a
    /// captive portal page): a problem between here and the server must not lock users out.
    private static func reachable(_ result: HTTPResult) -> (status: Int, body: ResponseBody)? {
        guard let status = result.statusCode, status < 500, status != 429,
              let body = result.body.flatMap({ try? JSONDecoder().decode(ResponseBody.self, from: $0) }) else { return nil }
        return (status, body)
    }

    static func validationOutcome(from result: HTTPResult) -> LicenseValidationOutcome {
        guard let (status, body) = reachable(result) else { return .unreachable }
        return status == 200 && body.valid == true ? .valid : .invalid
    }

    static func activationOutcome(from result: HTTPResult) -> LicenseActivationOutcome {
        guard let (status, body) = reachable(result) else { return .unreachable }
        if status == 200, body.activated == true, let id = body.instance?.id, !id.isEmpty {
            return .activated(instanceID: id)
        }
        // Wording from the License API, e.g. "This license key has reached the activation limit."
        return body.error?.lowercased().contains("activation limit") == true ? .activationLimitReached : .invalidKey
    }

    static func deactivationOutcome(from result: HTTPResult) -> LicenseDeactivationOutcome {
        guard let (status, body) = reachable(result) else { return .unreachable }
        return status == 200 && body.deactivated == true ? .released : .rejected
    }
}
