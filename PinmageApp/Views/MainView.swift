import SwiftUI

enum ActiveTab: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case processQueue = "Process Queue"
    case settings = "Settings"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .dashboard: return "chart.bar.fill"
        case .processQueue: return "square.and.arrow.down.on.square.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct MainView: View {
    @StateObject var manager = PinmageManager()
    @StateObject var settings = AppSettings()
    @State private var activeTab: ActiveTab = .dashboard
    
    var body: some View {
        NavigationSplitView {
            // Sidebar Layout
            VStack(alignment: .leading, spacing: 20) {
                // Logo Section
                HStack(spacing: 12) {
                    Image("AppIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                        .shadow(color: Color.cyan.opacity(0.25), radius: 4)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PINMAGE")
                            .font(.system(.body, design: .rounded))
                            .fontWeight(.black)
                            .foregroundColor(.white)
                        Text("AI Geo & Date Injector")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                
                Divider().background(Color.white.opacity(0.08))
                    .padding(.horizontal, 12)
                
                // Sidebar Navigation Links
                VStack(spacing: 6) {
                    ForEach(ActiveTab.allCases) { tab in
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                activeTab = tab
                            }
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: tab.iconName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 20)
                                    .foregroundColor(activeTab == tab ? .white : .secondary)
                                
                                Text(tab.rawValue)
                                    .font(.body)
                                    .fontWeight(activeTab == tab ? .semibold : .regular)
                                    .foregroundColor(activeTab == tab ? .white : .secondary)
                                
                                Spacer()
                                
                                if activeTab == tab {
                                    Circle()
                                        .fill(Color.cyan)
                                        .frame(width: 5, height: 5)
                                        .shadow(color: .cyan, radius: 3)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(activeTab == tab ? Color.white.opacity(0.08) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                
                Spacer()
                
                // Sidebar Footer Brand info
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pinmage macOS v\(appVersion)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("Powered by Gemini AI")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .frame(minWidth: 220, maxWidth: 280)
            .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
        } detail: {
            // Main Content Area
            ZStack {
                VisualEffectView(material: .underWindowBackground, blendingMode: .withinWindow)
                
                switch activeTab {
                case .dashboard:
                    DashboardView(manager: manager)
                        .transition(.opacity)
                case .processQueue:
                    ProcessView(manager: manager, settings: settings)
                        .transition(.opacity)
                case .settings:
                    SettingsView(settings: settings)
                        .transition(.opacity)
                }
            }
            .frame(minWidth: 600, minHeight: 500)
        }
        .preferredColorScheme(.dark)
    }
    
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?.?.?"
    }
}
