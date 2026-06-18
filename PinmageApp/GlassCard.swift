import SwiftUI
import AppKit

// MARK: - Visual Effect View Wrapper
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var state: NSVisualEffectView.State = .active
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Reusable Glass Card View
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 16
    var shadowRadius: CGFloat = 12
    var borderColor: Color = Color.white.opacity(0.07)
    var backgroundColor: Color = Color.black.opacity(0.15)
    var content: Content
    
    init(
        cornerRadius: CGFloat = 16,
        shadowRadius: CGFloat = 12,
        borderColor: Color = Color.white.opacity(0.07),
        backgroundColor: Color = Color.black.opacity(0.15),
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.borderColor = borderColor
        self.backgroundColor = backgroundColor
        self.content = content()
    }
    
    var body: some View {
        content
            .background(
                ZStack {
                    VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(backgroundColor)
                    
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Color.black.opacity(0.3), radius: shadowRadius, x: 0, y: 6)
    }
}

// MARK: - Premium Card Border Hover Modifier
struct CardHoverModifier: ViewModifier {
    @State private var isHovering = false
    var cornerRadius: CGFloat = 16
    
    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovering ? 0.25 : 0.07),
                                Color.white.opacity(isHovering ? 0.05 : 0.01),
                                Color.emerald.opacity(isHovering ? 0.25 : 0.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.25)) {
                    self.isHovering = hovering
                }
            }
    }
}

extension View {
    func glassCardHoverEffect(cornerRadius: CGFloat = 16) -> some View {
        self.modifier(CardHoverModifier(cornerRadius: cornerRadius))
    }
}
