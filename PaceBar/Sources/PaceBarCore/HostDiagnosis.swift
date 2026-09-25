import Foundation

extension HostDoctor {
    static func serverPort(_ host: InferenceHost) -> Int {
        let url = URL(string: host.serverURL)
        return url?.port ?? (url?.scheme == "https" ? 443 : 80)
    }

    static func inferenceFailure(_ host: InferenceHost, facts: [String: String]?) -> String {
        guard let facts else {
            return host.sshHost == nil
                ? "The inference API is unavailable and no SSH host is configured to check the server."
                : "\(host.name) cannot be reached or inspected over SSH, and its inference API is unavailable."
        }
        if facts["inferenceListener"] == "no" {
            return "Nothing is listening on port \(Self.serverPort(host)) on \(host.name); start your inference server."
        }
        return "\(host.name) is reachable, but its inference API is not responding correctly from this Mac."
    }
}
