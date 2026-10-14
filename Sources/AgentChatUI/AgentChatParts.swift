import AgentKit
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

// What a message carries besides its text: the app's own views, links to its
// screens, files both ways, and confirmations. The app draws views and opens
// screens with its own code (registered on the ActionRegistry); the assistant
// only picked them.

/// A reply's views, links and files, in the order the assistant added them.
struct PartsView: View {
    let parts: [TurnPart]
    let model: AgentChatModel

    var body: some View {
        // By the part itself, not its position: a file card's loaded state
        // must not move to another part when the list changes.
        ForEach(parts, id: \.self) { part in
            switch part {
            case .view(let name, let params):
                AppViewPart(name: name, params: params, registry: model.registry)
            case .navigation(let destination, let params, let label, _):
                LinkPart(label: label) { model.open(destination, params: params) }
            case .attachment(let file):
                AttachmentPart(file: file, model: model)
            case .text, .unknown:
                EmptyView()
            }
        }
    }
}

/// One of the app's registered views, shown in the chat.
struct AppViewPart: View {
    let name: String
    let params: JSONValue
    let registry: ActionRegistry?

    var body: some View {
        Group {
            if let view = registry?.view(name, params: params) {
                view
            } else {
                Label("This view isn't available in this version of the app.", systemImage: "rectangle.dashed")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator, lineWidth: 0.5))
        .accessibilityIdentifier("agentChat.view.\(name)")
    }
}

/// A link to one of the app's screens.
struct LinkPart: View {
    let label: String
    let open: () -> Void
    @Environment(\.agentChatTheme) private var theme

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent)
        .accessibilityIdentifier("agentChat.link")
        .accessibilityHint("Opens this in the app")
    }
}

/// A photo or a file in the chat: images show inline, other files offer Share.
struct AttachmentPart: View {
    let file: TurnPart.Attachment
    let model: AgentChatModel
    @State private var data: Data?
    @State private var shareURL: URL?
    @State private var failed = false
    /// Bumped by "Try again" to load once more.
    @State private var attempt = 0

    private var isImage: Bool { file.mimeType.hasPrefix("image/") }

    var body: some View {
        Group {
            if isImage, let data, let image = Image(agentData: data) {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .clipShape(.rect(cornerRadius: 14))
                    .accessibilityLabel(file.name)
            } else if isImage, !failed {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.fill.tertiary)
                    .frame(width: 160, height: 120)
                    .overlay { ProgressView() }
            } else {
                fileRow
            }
        }
        // Keep the share button's own identifier: without .contain the
        // container's identifier replaces every child's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentChat.file")
        .task(id: LoadKey(attachmentId: file.attachmentId, attempt: attempt)) { await load() }
    }

    private var fileRow: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(failed ? "Couldn't load this file." : ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if failed {
                Button("Try Again") { attempt += 1 }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityIdentifier("agentChat.file.retry")
            } else if let shareURL {
                ShareLink(item: shareURL) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share \(file.name)")
                    .accessibilityIdentifier("agentChat.file.share")
            } else if !failed {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 0.5))
    }

    private var icon: String {
        switch file.mimeType {
        case "text/csv": "tablecells"
        case "application/pdf": "doc.richtext"
        default: "doc"
        }
    }

    private struct LoadKey: Hashable {
        var attachmentId: String
        var attempt: Int
    }

    private func load() async {
        failed = false
        do {
            let bytes = try await model.data(for: file)
            if isImage {
                data = bytes
            } else {
                // ShareLink needs a file on disk with the file's own name.
                let dir = FileManager.default.temporaryDirectory.appending(path: file.attachmentId, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appending(path: file.name)
                try bytes.write(to: url, options: .atomic)
                shareURL = url
            }
        } catch is CancellationError {
            // The row went away or is loading again: not a failure.
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

/// Asks the user to approve an action, with its exact details.
struct ConfirmationCard: View {
    let confirmation: AgentChatModel.Confirmation
    let answer: (Bool) -> Void
    @Environment(\.agentChatTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Confirm", systemImage: "hand.raised.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(confirmation.summary)
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("agentChat.confirmation.summary")
            switch confirmation.state {
            case .asking:
                HStack(spacing: 8) {
                    Button("Cancel", role: .cancel) { answer(false) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("agentChat.confirmation.cancel")
                    Button("Confirm") { answer(true) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("agentChat.confirmation.confirm")
                }
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            case .confirmed:
                Label("Confirmed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(theme.accent)
            case .declined:
                Label("Cancelled", systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator, lineWidth: 0.5))
        .animation(ChatMotion.state, value: confirmation.state)
        .accessibilityElement(children: .contain)
    }
}

/// Files picked for the next message, above the composer.
struct PendingFilesRow: View {
    let model: AgentChatModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.pendingFiles, id: \.attachmentId) { file in
                    HStack(spacing: 6) {
                        Image(systemName: file.mimeType.hasPrefix("image/") ? "photo" : "doc")
                        Text(file.name).lineLimit(1).frame(maxWidth: 140)
                        Button {
                            model.removePendingFile(file.attachmentId)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(file.name)")
                    }
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.fill.tertiary, in: .capsule)
                }
                if model.isUploading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("agentChat.pendingFiles")
    }
}

extension Image {
    /// An image from file bytes, on iOS and macOS.
    init?(agentData data: Data) {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        self.init(nsImage: image)
        #else
        return nil
        #endif
    }
}

extension AgentFile {
    /// A photo ready to send: re-encoded as JPEG and scaled to at most
    /// `maxSide` pixels, so it stays under the upload limit and the model
    /// sees a reasonable size. Nil when the data isn't an image.
    public static func photo(_ data: Data, name: String = "photo.jpg", maxSide: CGFloat = 2048) -> AgentFile? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        // Points are pixels here: the renderer's default scale is the screen's
        // (3x on a phone), which made a 2048-point photo 6144 px and over the limit.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        var quality: CGFloat = 0.8
        guard var jpeg = resized.jpegData(compressionQuality: quality) else { return nil }
        while jpeg.count > maxBytes, quality > 0.3, let smaller = resized.jpegData(compressionQuality: quality - 0.2) {
            quality -= 0.2
            jpeg = smaller
        }
        let base = (name as NSString).deletingPathExtension
        return AgentFile(name: (base.isEmpty ? "photo" : base) + ".jpg", mimeType: "image/jpeg", data: jpeg)
        #else
        return nil
        #endif
    }

    /// A file the user picked, with its type from its extension. Nil when the
    /// type can't be sent.
    public static func document(at url: URL) throws -> AgentFile? {
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""
        let mime = type == "text/comma-separated-values" ? "text/csv" : type
        guard allowedTypes.contains(mime) else { return nil }
        return AgentFile(name: url.lastPathComponent, mimeType: mime, data: try Data(contentsOf: url))
    }
}
