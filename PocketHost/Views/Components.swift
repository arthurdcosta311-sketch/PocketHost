//
//  Components.swift
//  PocketHost
//
//  Small pieces of chrome shared by the screens.
//

import CoreImage
import SwiftUI
import UIKit

// MARK: - Live indicator

struct LiveDot: View {
    var active: Bool

    @State private var pulsing = false

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .fill(Color.accentColor.opacity(0.28))
                    .frame(width: 22, height: 22)
                    .scaleEffect(pulsing ? 1.15 : 0.5)
                    .opacity(pulsing ? 0 : 1)
                    .animation(
                        .easeOut(duration: 1.6).repeatForever(autoreverses: false),
                        value: pulsing
                    )
            }

            Circle()
                .fill(active ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
        }
        .frame(width: 22, height: 22)
        .onAppear {
            pulsing = active
        }
        .onChange(of: active) { _, newValue in
            pulsing = newValue
            if newValue {
                pulsing = false
                DispatchQueue.main.async { pulsing = true }
            }
        }
    }
}

// MARK: - Statistic tile

struct StatTile: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

// MARK: - Copy button

struct CopyButton: View {
    let text: String
    var title: String? = nil
    var bordered: Bool = false

    @State private var copied = false

    var body: some View {
        Group {
            if bordered {
                button
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            } else {
                button
                    .buttonStyle(.borderless)
            }
        }
    }

    private var button: some View {
        Button {
            UIPasteboard.general.string = text
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.snappy) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            label
        }
        .accessibilityLabel(title ?? "Copy link")
    }

    @ViewBuilder
    private var label: some View {
        if let title {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        } else {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Color.accentColor : Color.secondary)
        }
    }
}

// MARK: - QR codes

enum QRCodeGenerator {
    private static let context = CIContext()

    static func image(from string: String, scale: CGFloat = 12) -> UIImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = QRCodeGenerator.image(from: text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            ContentUnavailableView(
                "No QR code",
                systemImage: "qrcode",
                description: Text("The link could not be turned into a code.")
            )
        }
    }
}

struct ShareSiteSheet: View {
    let url: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                QRCodeImage(text: url)
                    .frame(width: 210, height: 210)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(.white)
                    )

                VStack(spacing: 6) {
                    Text("Scan to open")
                        .font(.headline)

                    Text(url)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }

                HStack(spacing: 12) {
                    CopyButton(text: url, title: "Copy link", bordered: true)

                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 22)
            .frame(maxHeight: .infinity, alignment: .center)
            .navigationTitle("Share your site")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Activity row

struct ActivityRow: View {
    let entry: HTTPLogEntry

    private var statusColor: Color {
        switch entry.status {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(entry.status)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 30, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.path)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(entry.method) · \(entry.date.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Text(FileStore.sizeText(entry.bytes))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}
