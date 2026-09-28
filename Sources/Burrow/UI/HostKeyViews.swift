import SwiftUI

/// Makes sure a server's host key is trusted before anything connects to it. Already known → runs the action
/// right away; unknown → scans the key and asks the user to confirm its fingerprint first.
@MainActor
final class HostVerifier: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let host: String
        let port: Int
        let keys: [HostKeys.Key]
        let onTrust: () -> Void
    }

    @Published var request: Request?
    @Published var checking = false
    @Published var failure: String?

    func ensureTrusted(host: String, port: Int, then action: @escaping () -> Void) {
        let host = host.trimmingCharacters(in: .whitespaces)
        failure = nil
        checking = true
        Task.detached {
            let scan: HostKeys.Scan? = HostKeys.isKnown(host: host, port: port) ? nil : HostKeys.scan(host: host, port: port)
            await MainActor.run {
                self.checking = false
                switch scan {
                case nil: action()
                case .failed(let msg)?: self.failure = msg
                case .keys(let keys)?: self.request = Request(host: host, port: port, keys: keys, onTrust: action)
                }
            }
        }
    }

    func confirm() {
        guard let r = request else { return }
        request = nil
        Task.detached {
            HostKeys.trust(r.keys)
            await MainActor.run { r.onTrust() }
        }
    }
}

struct HostKeySheet: View {
    let request: HostVerifier.Request
    let onTrust: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                IconBadge(systemImage: "lock.shield.fill", tint: .blue, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Confirm the server's identity").font(.title3.bold())
                    Text(verbatim: HostKeys.entry(host: request.host, port: request.port))
                        .font(.callout.monospaced()).foregroundStyle(.secondary)
                }
            }
            Text("This is the first connection to this server. To be sure you are talking to the real server and not an impostor, compare the fingerprint below with the one your provider publishes. They must match exactly.")
                .fixedSize(horizontal: false, vertical: true)
            Label("Hosting providers list the fingerprints in their documentation or control panel. For your own server, run “ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub” on it.", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(request.keys.enumerated()), id: \.element.id) { i, k in
                    if i > 0 { Divider() }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: k.type).font(.callout.weight(.semibold)).frame(width: 70, alignment: .leading)
                        Text(verbatim: k.fingerprint).font(.callout.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                }
            }
            .card(padding: 12)
            Text("Only continue if the fingerprints match. The server is remembered in ~/.ssh/known_hosts, and every later connection is checked against it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Trust This Server", action: onTrust).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

private struct HostKeyVerification: ViewModifier {
    @ObservedObject var verifier: HostVerifier

    func body(content: Content) -> some View {
        content.sheet(item: $verifier.request) { r in
            HostKeySheet(request: r, onTrust: { verifier.confirm() }, onCancel: { verifier.request = nil })
        }
    }
}

extension View {
    func hostKeyVerification(_ verifier: HostVerifier) -> some View { modifier(HostKeyVerification(verifier: verifier)) }
}

/// Shown in the browser when a connection failed because of the host key.
struct HostKeyProblemBanner: View {
    let problem: HostKeys.Problem
    let host: String
    let verify: () -> Void

    var body: some View {
        switch problem {
        case .unknown:
            Banner(icon: "lock.shield", tint: .blue, title: "This server hasn't been verified yet",
                   text: "Before the first connection, confirm the server's fingerprint so nobody can impersonate it.",
                   actions: AnyView(Button("Verify Server…", action: verify)))
        case .changed:
            Banner(icon: "exclamationmark.shield.fill", tint: .red, title: "The server's identity has changed",
                   text: "The server presents a different key than the one you trusted. This can mean someone is intercepting the connection. If your provider announced new keys, remove the old entry for this server from ~/.ssh/known_hosts and connect again.")
        }
    }
}
