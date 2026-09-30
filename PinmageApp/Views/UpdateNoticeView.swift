import SwiftUI

struct UpdateNoticeView: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        if let release = checker.available {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New version available").font(.callout.weight(.semibold))
                    Text("Pinmage \(release.version)").font(.caption).foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                Link("Download free update", destination: release.downloadURL)
                    .font(.callout)
                    .help("Quit Pinmage, then drag the downloaded app into Applications.")
                    .contextMenu {
                        Button("Copy download link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(release.downloadURL.absoluteString, forType: .string)
                        }
                    }
                Button("Later", action: checker.dismiss).buttonStyle(.plain).foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.white.opacity(0.06))
        } else if let status = checker.manualStatus {
            HStack {
                Text(status).font(.callout).foregroundColor(.secondary)
                Spacer()
                Button("Dismiss", action: checker.clearStatus).buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.white.opacity(0.06))
        }
    }
}
