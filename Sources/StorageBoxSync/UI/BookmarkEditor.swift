import SwiftUI
import AppKit

struct BookmarkEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var bookmark: Bookmark
    let isNew: Bool
    @State private var password = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var keyPassword = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $bookmark.name, prompt: Text("e.g. Storage Box, Client server"))
                    TextField("Server", text: $bookmark.host, prompt: Text(verbatim: "sftp.example.com"))
                    TextField("Port", value: $bookmark.port, format: .number.grouping(.never))
                    TextField("Username", text: $bookmark.user)
                    Text("Hetzner Storage Box: server uXXXXXX.your-storagebox.de, port 23, username uXXXXXX.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Authentication") {
                    Picker("Method", selection: $bookmark.auth) {
                        Text("SSH key").tag(Bookmark.Auth.key)
                        Text("Password").tag(Bookmark.Auth.password)
                    }
                    .pickerStyle(.segmented)
                    if bookmark.auth == .key {
                        HStack {
                            Text("Key file")
                            Spacer()
                            Text(verbatim: bookmark.keyFile).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { pickKey() }
                        }
                        DisclosureGroup("Install a key on this server") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Enter the account password once. A dedicated key is created if the file above doesn't exist yet, and appended to ~/.ssh/authorized_keys on the server. The password is not stored.")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    SecureField("Account password", text: $keyPassword)
                                    Button("Install key") {
                                        if !FileManager.default.fileExists(atPath: bookmark.keyFile) { bookmark.keyFile = Paths.defaultKey }
                                        model.installKey(host: bookmark.host, port: bookmark.port, user: bookmark.user,
                                                         password: keyPassword, keyFile: bookmark.keyFile)
                                        keyPassword = ""
                                    }
                                    .disabled(keyPassword.isEmpty || bookmark.host.isEmpty || bookmark.user.isEmpty || model.keySetupBusy)
                                }
                                if model.keySetupBusy { ProgressView().controlSize(.small) }
                                if let r = model.keySetupResult {
                                    Label(r.message, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                        .foregroundStyle(r.ok ? .green : .orange)
                                }
                            }
                            .padding(.top, 4)
                        }
                    } else {
                        if isNew { SecureField("Password", text: $password) }
                        else { SecureField("Password (leave empty to keep)", text: $password) }
                        Text("Stored in your macOS Keychain. Scheduled backups need SSH key authentication.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Folders") {
                    TextField("Start folder", text: $bookmark.path, prompt: Text("empty = login folder"))
                    TextField("Trash folder", text: $bookmark.trashFolder)
                    Text("“Delete” moves items into the trash folder (relative to the login folder), so they can be put back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Test Connection") { test() }.disabled(!bookmark.isComplete || testing)
                if testing { ProgressView().controlSize(.small) }
                if let r = testResult { Text(r).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!bookmark.isComplete || (isNew && bookmark.auth == .password && password.isEmpty))
            }
            .padding(12)
        }
        .frame(width: 520, height: 620)
        .onAppear { model.keySetupResult = nil }
    }

    private func save() {
        if bookmark.auth == .password && !password.isEmpty { Keychain.set(password, for: bookmark.id) }
        model.saveBookmark(bookmark)
        dismiss()
    }

    private func test() {
        testing = true
        testResult = nil
        var b = bookmark
        if b.auth == .password && !password.isEmpty {
            // test with the typed password without saving it yet
            b.id = UUID()
            Keychain.set(password, for: b.id)
        }
        let temp = b
        Task {
            let r = await model.testBookmark(temp)
            if temp.id != bookmark.id { Keychain.delete(temp.id) }
            testResult = r
            testing = false
        }
    }

    private func pickKey() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false
        p.directoryURL = URL(fileURLWithPath: Paths.home + "/.ssh")
        p.showsHiddenFiles = true
        if p.runModal() == .OK, let u = p.url { bookmark.keyFile = u.path }
    }
}
