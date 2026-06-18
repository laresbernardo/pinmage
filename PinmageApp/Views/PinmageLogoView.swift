import SwiftUI

struct MapPinShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        
        // Circular top part (centered)
        let radius = width / 2
        path.addArc(
            center: CGPoint(x: width / 2, y: radius),
            radius: radius,
            startAngle: .degrees(-35),
            endAngle: .degrees(215),
            clockwise: true
        )
        // Bottom pointer tip to (width/2, height)
        path.addLine(to: CGPoint(x: width / 2, y: height))
        path.closeSubpath()
        return path
    }
}

struct AperturePattern: View {
    let navyColor: Color
    
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: size / 2, y: size / 2)
            let outerRadius = size / 2
            let innerRadius = outerRadius * 0.35
            
            ZStack {
                // Central aperture hole mask (Navy circle)
                Circle()
                    .fill(navyColor)
                    .frame(width: innerRadius * 2, height: innerRadius * 2)
                
                // 6 separator lines
                ForEach(0..<6) { i in
                    Path { path in
                        let angle = Double(i) * (2 * .pi / 6)
                        
                        // Start point on the outer circle
                        let startX = center.x + CGFloat(cos(angle)) * outerRadius
                        let startY = center.y + CGFloat(sin(angle)) * outerRadius
                        
                        // End point tangent to the inner circle
                        let tangentAngle = angle + .pi / 3.2
                        let endX = center.x + CGFloat(cos(tangentAngle)) * innerRadius
                        let endY = center.y + CGFloat(sin(tangentAngle)) * innerRadius
                        
                        path.move(to: CGPoint(x: startX, y: startY))
                        path.addLine(to: CGPoint(x: endX, y: endY))
                    }
                    .stroke(navyColor, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                }
                
                // Outer circle outline separating the aperture from the map pin structure
                Circle()
                    .stroke(navyColor, style: StrokeStyle(lineWidth: size * 0.07))
            }
        }
    }
}

struct PinmageLogoView: View {
    var isAnimating: Bool = false
    var size: CGFloat = 34
    
    // Brand Colors matching Option 1
    private let navyColor = Color(red: 15/255, green: 23/255, blue: 42/255) // #0F172A
    private let cyanColor = Color(red: 6/255, green: 182/255, blue: 212/255) // #06B6D4
    
    @State private var rotationAngle: Double = 0.0
    
    var body: some View {
        ZStack {
            // Squircle background
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(navyColor)
                .frame(width: size, height: size)
                
            // ZStack containing Pin and Aperture
            ZStack {
                // Cyan Pin Shape
                MapPinShape()
                    .fill(cyanColor)
                    .aspectRatio(1.0, contentMode: .fit)
                
                // Aperture pattern overlay (Navy negative-space drawing)
                // Positioned on the circular top part of the pin
                AperturePattern(navyColor: navyColor)
                    .frame(width: size * 0.52, height: size * 0.52)
                    .offset(y: -size * 0.06)
                    .rotationEffect(.degrees(rotationAngle))
            }
            .frame(width: size * 0.72, height: size * 0.72)
        }
        .frame(width: size, height: size)
        .onAppear {
            if isAnimating {
                startAnimation()
            }
        }
        .onChange(of: isAnimating) { _, newValue in
            if newValue {
                startAnimation()
            } else {
                stopAnimation()
            }
        }
    }
    
    private func startAnimation() {
        withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
            rotationAngle = 360.0
        }
    }
    
    private func stopAnimation() {
        withAnimation(.easeOut(duration: 0.5)) {
            rotationAngle = 0.0
        }
    }
}

struct PinmageLogoView_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 20) {
            PinmageLogoView(isAnimating: false, size: 64)
            PinmageLogoView(isAnimating: true, size: 64)
        }
        .padding()
        .background(Color.gray)
    }
}
