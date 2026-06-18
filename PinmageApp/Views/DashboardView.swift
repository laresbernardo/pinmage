import SwiftUI
import Charts
import MapKit

struct DashboardView: View {
    @ObservedObject var manager: PinmageManager
    
    // Map state
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.0902, longitude: -95.7129), // Center of US default
        span: MKCoordinateSpan(latitudeDelta: 60.0, longitudeDelta: 60.0)
    )
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Dashboard Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pinmage Dashboard")
                        .font(.system(.title, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text("Overview of library metadata extraction, geographical distributions, and timelines")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 8)
                
                if manager.imageItems.isEmpty {
                    EmptyDashboardView()
                } else {
                    // Quick Stats Grid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        StatCard(title: "Total Files", value: "\(manager.imageItems.count)", icon: "doc.on.doc", color: .blue)
                        StatCard(title: "Processed", value: "\(manager.totalProcessedCount)", icon: "arrow.triangle.2.circlepath", color: .orange)
                        StatCard(title: "Successful", value: "\(manager.successfulCount)", icon: "checkmark.circle", color: .emerald)
                        StatCard(title: "Geocoded", value: "\(geocodedCount)", icon: "mappin.and.ellipse", color: .purple)
                    }
                    
                    HStack(alignment: .top, spacing: 16) {
                        // Chronological Timeline Chart
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Timeline Distribution")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Text("Frequency of photos mapped across years")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Divider().background(Color.white.opacity(0.1))
                                
                                if timelineData.isEmpty {
                                    VStack {
                                        Spacer()
                                        Text("No date information available yet")
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .frame(height: 200)
                                    .frame(maxWidth: .infinity)
                                } else {
                                    Chart {
                                        ForEach(timelineData) { data in
                                            BarMark(
                                                x: .value("Year", data.year),
                                                y: .value("Count", data.count)
                                            )
                                            .foregroundStyle(LinearGradient(colors: [.indigo, .cyan], startPoint: .bottom, endPoint: .top))
                                            .cornerRadius(4)
                                        }
                                    }
                                    .frame(height: 200)
                                    .chartXAxis {
                                        AxisMarks(values: .automatic) { _ in
                                            AxisGridLine().stroke(Color.white.opacity(0.05))
                                            AxisTick().stroke(Color.white.opacity(0.1))
                                            AxisValueLabel().foregroundColor(.secondary)
                                        }
                                    }
                                    .chartYAxis {
                                        AxisMarks(values: .automatic) { _ in
                                            AxisGridLine().stroke(Color.white.opacity(0.05))
                                            AxisTick().stroke(Color.white.opacity(0.1))
                                            AxisValueLabel().foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                            .padding(20)
                        }
                        .glassCardHoverEffect()
                        
                        // Top Locations Table
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Top Locations")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Text("Most frequent places identified by Gemini")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Divider().background(Color.white.opacity(0.1))
                                
                                if locationData.isEmpty {
                                    VStack {
                                        Spacer()
                                        Text("No location information available yet")
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .frame(height: 200)
                                    .frame(maxWidth: .infinity)
                                } else {
                                    VStack(spacing: 8) {
                                        ForEach(locationData.prefix(5)) { loc in
                                            HStack {
                                                Image(systemName: "mappin.circle.fill")
                                                    .foregroundColor(.cyan)
                                                Text(loc.place)
                                                    .foregroundColor(.white)
                                                    .lineLimit(1)
                                                Spacer()
                                                Text("\(loc.count) photos")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 2)
                                                    .background(Color.white.opacity(0.05))
                                                    .cornerRadius(4)
                                            }
                                            Divider().background(Color.white.opacity(0.03))
                                        }
                                        Spacer()
                                    }
                                    .frame(height: 200)
                                }
                            }
                            .padding(20)
                        }
                        .glassCardHoverEffect()
                        .frame(width: 320)
                    }
                    
                    // Interactive Places Map
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Geographic Map")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    Text("Plotted coordinates of successfully geocoded images")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Recenter Map") {
                                    recenterMap()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            
                            Divider().background(Color.white.opacity(0.1))
                            
                            if mapAnnotations.isEmpty {
                                VStack {
                                    Spacer()
                                    Text("No geocoded coordinates available to plot")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .frame(height: 300)
                                .frame(maxWidth: .infinity)
                            } else {
                                Map(coordinateRegion: $region, annotationItems: mapAnnotations) { item in
                                    MapAnnotation(coordinate: item.coordinate) {
                                        VStack(spacing: 4) {
                                            Image(systemName: "mappin.circle.fill")
                                                .font(.title)
                                                .foregroundColor(.purple)
                                                .shadow(color: .black.opacity(0.4), radius: 3)
                                            
                                            Text(item.title)
                                                .font(.system(size: 9, weight: .bold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.black.opacity(0.75))
                                                .foregroundColor(.white)
                                                .cornerRadius(4)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 4)
                                                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                                                )
                                        }
                                    }
                                }
                                .frame(height: 300)
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                                .onAppear {
                                    recenterMap()
                                }
                            }
                        }
                        .padding(20)
                    }
                    .glassCardHoverEffect()
                }
            }
            .padding(24)
        }
    }
    
    // Helpers & Calculated Properties
    
    private var geocodedCount: Int {
        manager.imageItems.filter { $0.latitude != nil && $0.longitude != nil }.count
    }
    
    private var timelineData: [TimelineData] {
        var counts: [String: Int] = [:]
        let calendar = Calendar.current
        
        for item in manager.imageItems {
            if let date = item.detectedDate {
                let year = calendar.component(.year, from: date)
                let yearStr = "\(year)"
                counts[yearStr, default: 0] += 1
            }
        }
        
        return counts.map { TimelineData(year: $0.key, count: $0.value) }
            .sorted { $0.year < $1.year }
    }
    
    private var locationData: [LocationData] {
        var counts: [String: Int] = [:]
        for item in manager.imageItems {
            if let place = item.detectedPlace, !place.isEmpty {
                counts[place, default: 0] += 1
            }
        }
        
        return counts.map { LocationData(place: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }
    
    struct TimelineData: Identifiable {
        var id: String { year }
        let year: String
        let count: Int
    }
    
    struct LocationData: Identifiable {
        var id: String { place }
        let place: String
        let count: Int
    }
    
    struct MapPinItem: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
        let title: String
    }
    
    private var mapAnnotations: [MapPinItem] {
        manager.imageItems.compactMap { item in
            guard let lat = item.latitude, let lon = item.longitude else { return nil }
            return MapPinItem(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                title: item.fileName
            )
        }
    }
    
    private func recenterMap() {
        let annotations = mapAnnotations
        guard !annotations.isEmpty else { return }
        
        var minLat = 90.0
        var maxLat = -90.0
        var minLon = 180.0
        var maxLon = -180.0
        
        for ann in annotations {
            minLat = min(minLat, ann.coordinate.latitude)
            maxLat = max(maxLat, ann.coordinate.latitude)
            minLon = min(minLon, ann.coordinate.longitude)
            maxLon = max(maxLon, ann.coordinate.longitude)
        }
        
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2.0,
            longitude: (minLon + maxLon) / 2.0
        )
        
        let span = MKCoordinateSpan(
            latitudeDelta: max(abs(maxLat - minLat) * 1.5, 2.0),
            longitudeDelta: max(abs(maxLon - minLon) * 1.5, 2.0)
        )
        
        withAnimation(.easeInOut) {
            region = MKCoordinateRegion(center: center, span: span)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        GlassCard {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(color)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontWeight(.semibold)
                    Text(value)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                }
                Spacer()
            }
            .padding(16)
        }
        .glassCardHoverEffect()
    }
}

struct EmptyDashboardView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.4))
            
            Text("Dashboard is currently empty")
                .font(.title3)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            
            Text("Go to the Process Queue tab, import photo albums or scans, and run AI processing to generate analytics charts and location maps.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 80)
    }
}
