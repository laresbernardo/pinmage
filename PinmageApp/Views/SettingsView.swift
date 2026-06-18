import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    
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
                                Text("Gemini 2.5 Flash (Recommended)").tag("gemini-2.5-flash")
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
                                
                                if !settings.outputFolderPath.isEmpty {
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
                    .padding(20)
                }
                .glassCardHoverEffect()
            }
            .padding(24)
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
}
