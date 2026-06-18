import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var showResetConfirm = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Section Title
                VStack(alignment: .leading, spacing: 4) {
                    Text("Configuration Settings")
                        .font(.system(.title, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text("Customize your Gemini integration, output directory, and AI prompts")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 8)
                
                // Gemini API Settings
                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .font(.title3)
                                .foregroundColor(.emerald)
                            Text("Gemini API Setup")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        
                        Divider().background(Color.white.opacity(0.1))
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Gemini API Key")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fontWeight(.semibold)
                            
                            HStack {
                                SecureField("AIzaSy...", text: $settings.apiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                
                                Button(action: {
                                    if let url = URL(string: "https://aistudio.google.com/") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }) {
                                    Text("Get Key")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                }
                                .buttonStyle(.bordered)
                            }
                            Text("Your API key is saved locally in system UserDefaults.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Gemini Model Selection")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fontWeight(.semibold)
                            
                            Picker("", selection: $settings.modelName) {
                                Text("Gemini 3.5 Flash (Recommended)").tag("gemini-3.5-flash")
                                Text("Gemini 2.5 Flash").tag("gemini-2.5-flash")
                                Text("Gemini 1.5 Flash").tag("gemini-1.5-flash")
                                Text("Gemini 1.5 Pro").tag("gemini-1.5-pro")
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 320)
                        }
                    }
                    .padding(20)
                }
                .glassCardHoverEffect()
                
                // File Destination Settings
                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .font(.title3)
                                .foregroundColor(.emerald)
                            Text("Destination Settings")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        
                        Divider().background(Color.white.opacity(0.1))
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Output Folder")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fontWeight(.semibold)
                            
                            HStack {
                                TextField("Default (Save copy in original file folder)", text: $settings.outputFolderPath)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(true)
                                
                                Button("Choose Folder...") {
                                    selectFolder()
                                }
                                .disabled(settings.overwriteOriginals)
                                
                                if !settings.outputFolderPath.isEmpty && !settings.overwriteOriginals {
                                    Button(action: {
                                        settings.outputFolderPath = ""
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            
                            Text("Default leaves a copy with a suffix '_processed' in the source image location. If a different output folder is specified, files will be saved with their original names inside that folder.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .disabled(settings.overwriteOriginals)
                        .opacity(settings.overwriteOriginals ? 0.5 : 1.0)
                        
                        Divider().background(Color.white.opacity(0.1))
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Overwrite original files instead of creating copies", isOn: $settings.overwriteOriginals)
                                .toggleStyle(.checkbox)
                                .font(.body)
                                .foregroundColor(.white)
                            
                            if settings.overwriteOriginals {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.red)
                                        .font(.subheadline)
                                    Text("WARNING: Overwriting original files replaces the source images on your disk. This action cannot be undone. Please ensure you have backups of your photos.")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.red)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.top, 4)
                            }
                        }
                        
                        if !settings.overwriteOriginals {
                            Divider().background(Color.white.opacity(0.1))
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Filename Renaming Format")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fontWeight(.semibold)
                                
                                Picker("", selection: $settings.filenamePattern) {
                                    ForEach(FilenamePattern.allCases) { pattern in
                                        Text(pattern.rawValue).tag(pattern)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 320)
                                
                                Text("Automatically formats output copies to simplify sorting and chronological indexing (e.g. YYYY-MM-DD_ID_Location).")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(20)
                }
                .glassCardHoverEffect()
                
                // Advanced Prompt Settings
                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.title3)
                                .foregroundColor(.emerald)
                            Text("AI System Prompt")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        
                        Divider().background(Color.white.opacity(0.1))
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Instructions for Date & Place Extraction")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fontWeight(.semibold)
                            
                            TextEditor(text: $settings.customPrompt)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 120)
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                                .padding(.bottom, 4)
                            
                            HStack {
                                Spacer()
                                Button("Reset Default Prompt") {
                                    settings.customPrompt = "Analyze this image. If it is a scanned page containing multiple photos or a single photo, try to read any written text (captions, notes, dates) or visual cues to extract:\n1. The approximate or exact date when the photo(s) were taken.\n2. The location/place name (city, country, landmark) where the photo was taken.\n\nBe as accurate as possible. Return null for date or place if completely unknown."
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .glassCardHoverEffect()
                
                // Performance & Economy Settings
                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Image(systemName: "gauge.medium")
                                .font(.title3)
                                .foregroundColor(.emerald)
                            Text("Performance & Economy")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        
                        Divider().background(Color.white.opacity(0.1))
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Smart downscale of images (max 1600px width/height)", isOn: $settings.reduceImageSize)
                                .toggleStyle(.checkbox)
                                .font(.body)
                                .foregroundColor(.white)
                            
                            Text("Reduces upload bandwidth by up to 98% to maximize speed and prevent memory issues. Resized to high-quality JPEG.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        
                        Divider().background(Color.white.opacity(0.1))
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Max Concurrent AI Requests:")
                                    .foregroundColor(.white)
                                Text("\(settings.maxConcurrentRequests)")
                                    .fontWeight(.bold)
                                    .foregroundColor(.emerald)
                            }
                            
                            Slider(value: Binding(
                                get: { Double(settings.maxConcurrentRequests) },
                                set: { settings.maxConcurrentRequests = Int($0) }
                            ), in: 1...5, step: 1)
                            
                            Text("Controls the parallel request limits. Higher values analyze albums quicker but might trigger Gemini API rate limits (HTTP 429).")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        
                        Divider().background(Color.white.opacity(0.1))
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Local Metadata Cache Database")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fontWeight(.semibold)
                            
                            HStack {
                                Text("Avoids paying for repetitive API calls of unmodified images by caching results.")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Clear Cache Database") {
                                    CacheManager.shared.clearCache()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(20)
                }
                .glassCardHoverEffect()
                
                // AI Cost & Spend Tracker
                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Image(systemName: "banknote.fill")
                                .font(.title3)
                                .foregroundColor(.emerald)
                            Text("AI Cost & Spend Tracker")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        
                        Divider().background(Color.white.opacity(0.1))
                        
                        HStack(alignment: .center, spacing: 24) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Cumulative API Spend")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fontWeight(.semibold)
                                Text(formattedSpend(settings.cumulativeSpend))
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                    .foregroundColor(.emerald)
                            }
                            
                            Spacer()
                            
                            Button(action: {
                                showResetConfirm = true
                            }) {
                                HStack {
                                    Image(systemName: "trash")
                                    Text("Reset Spend...")
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                        
                        Text("Tracks real API cost calculated from Gemini's usageMetadata response. This is saved locally and can be reset at any time.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(20)
                }
                .glassCardHoverEffect()
            }
            .padding(24)
        }
        .confirmationDialog(
            "Reset Cumulative Spend?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset Spend", role: .destructive) {
                settings.resetCumulativeSpend()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to reset the cumulative API spend history to $0.00? This action cannot be undone.")
        }
    }
    
    private func selectFolder() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Output Folder"
        openPanel.showsResizeIndicator = true
        openPanel.showsHiddenFiles = false
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        
        if openPanel.runModal() == .OK {
            if let url = openPanel.url {
                settings.outputFolderPath = url.path
            }
        }
    }
    
    private func formattedSpend(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 5
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.5f", value)
    }
}
