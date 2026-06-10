import SwiftUI

struct ContentView: View {
    @ObservedObject var manager: ThunderboltManager
    
    // Sauvegarde automatique du Virtual ID dans les préférences macOS
    

    var body: some View {
        VStack(spacing: 16) {
            // --- HEADER ---
            HStack {
                Text("Remote Display Helper")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
                StatusBadge(isActive: manager.isUp)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("BetterDisplay ID", systemImage: "display")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                
                TextField("E.G: 42891...", text: manager.$virtualID)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
            }

            // --- CONTROLES PRINCIPAUX ---
            HStack(spacing: 12) {
                ActionButton(title: "Start", icon: "play.fill", color: .blue, active: !manager.startedScreenCopy) {
                    manager.start() // Vous pouvez passer virtualID ici si votre manager l'accepte
                }
                
                ActionButton(title: "Stop", icon: "stop.fill", color: .secondary, active: manager.startedScreenCopy) {
                    manager.stop()
                }
            }

            Divider().opacity(0.5)
            BetterDisplayStatusWidget(status: manager.betterDisplayManager.betterDisplayStatus)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 10))
                    Text("Brightness")
                        .font(.caption2.weight(.semibold))
                    Spacer()
                    Text("\(Int(manager.brightnessLevel))%")
                        .font(.caption2.monospacedDigit())
                }
                .foregroundColor(.secondary)

                Slider(value: $manager.brightnessLevel, in: 0...100)
                    .controlSize(.small)
                    .disabled(!manager.startedScreenCopy)
                    .onChange(of: manager.brightnessLevel) { newValue in
                        manager.sendBrightnessUpdate(newValue)
                    }
            }

            // --- FOOTER ---
            Button(action: { NSApplication.shared.terminate(nil) }) {
                Text("Quit")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 260)
    }
}



struct StatusBadge: View {
    let isActive: Bool
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isActive ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text(isActive ? "Connected" : "Disconnected")
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isActive ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
        .cornerRadius(20)
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(title)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(active ? color : Color.gray.opacity(0.1))
            .foregroundColor(active ? .white : .secondary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .disabled(!active)
    }
}

struct BetterDisplayStatusWidget: View {
    let status: BetterDisplayStatuses
    
    @State private var showDetails: Bool = false
    
    private var statusColor: Color {
        switch status {
        case .up: return .green
        case .error, .not_installed, .no_display_id : return .red
        case .unknown: return .yellow
        }
    }
    
    private var statusTitle: String {
        switch status {
        case .up: return "Better display is active"
        case .error: return "Error while using BetterDisplay"
        case .no_display_id : return "No Display ID is entered, please enter one"
        case .not_installed: return "BetterDisplay is not installed"
        case .unknown: return "BetterDisplay Status is Unknown"
        }
    }
    
    private var statusDetails: String {
        switch status {
        case .up: return "Everything is up "
        case .error: return "An error happened when trying to call BetterDisplay"
        case .no_display_id : return "Enter the virtual display ID that is found in the BetterDisplay GUI"
        case .not_installed: return "BetterDisplay doesn't seem to be installed"
        case .unknown: return "BetterDisplay status is unknown"
        }
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            

            Text(statusTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
            
            Spacer()
            
            Button(action: {
                showDetails.toggle()
            }) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDetails) {
                Text(statusDetails)
                    .font(.caption)
                    .padding()
                    .frame(width: 200)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}
