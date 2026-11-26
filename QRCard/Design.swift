import SwiftUI
import UIKit

enum Palette {
    static let screen = Color(red: 247 / 255, green: 247 / 255, blue: 251 / 255)
    static let white = Color.white
    static let ink = Color(red: 28 / 255, green: 27 / 255, blue: 49 / 255)
    static let muted = Color(red: 86 / 255, green: 86 / 255, blue: 109 / 255)
    static let line = Color(red: 222 / 255, green: 222 / 255, blue: 234 / 255)
    static let brand = Color(red: 74 / 255, green: 59 / 255, blue: 179 / 255)
    static let tint = Color(red: 238 / 255, green: 235 / 255, blue: 1)
    static let rail = Color(red: 234 / 255, green: 233 / 255, blue: 241 / 255)
    static let error = Color(red: 156 / 255, green: 45 / 255, blue: 71 / 255)
}

struct CardActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: primary ? 50 : 44)
            .padding(.horizontal, 8)
            .foregroundStyle(primary ? Palette.white : Palette.brand)
            .background(primary ? Palette.brand : Palette.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                if !primary { RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line) }
            }
            .opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct IconAction: View {
    let icon: String
    let title: String
    let id: String
    var background = Palette.white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(Palette.brand)
                .frame(width: 44, height: 44)
                .background(background, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line) }
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
}

extension View {
    func surface(radius: CGFloat = 20, color: Color = Palette.white) -> some View {
        background(color, in: RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(Palette.line) }
    }

    func fieldSurface() -> some View {
        font(.subheadline)
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .surface(radius: 11, color: Palette.screen)
    }
}

struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .frame(maxWidth: 500)
                .padding(.horizontal, 23)
                .padding(.vertical, 5)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.screen.ignoresSafeArea())
    }
}

struct SheetPage<Content: View>: View {
    let title: String
    var close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                IconAction(icon: "xmark", title: L.t("action.close"), id: "sheet-close", action: close)
            }
            .padding(.horizontal, 23)
            .padding(.vertical, 12)
            Page { content }
        }
        .background(Palette.screen.ignoresSafeArea())
    }
}

struct AccessibleQR: View {
    let bytes: Data
    let size: CGFloat
    let title: String

    var body: some View {
        if let image = UIImage(data: bytes) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: size)
                .accessibilityLabel(title)
        }
    }
}
