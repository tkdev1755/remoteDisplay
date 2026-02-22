//
//  ContentView.swift
//  remoteDisplaySenderHelper
//
//  Created by Taha Khetib on 17/02/2026.
//

import SwiftUI
import SwiftData
internal import Combine
import Network
import SwiftUI
import Network
import Foundation


import Foundation



struct ContentView: View {
    // On instancie notre manager
    @ObservedObject var manager: ThunderboltManager
    init(manager: ThunderboltManager = ThunderboltManager()) {
        self.manager = manager
    }
    var body: some View {
        VStack(spacing: 20) {
            
            Text("Thunderbolt Interface")
                .font(.headline)
            
            // --- INDICATEUR DE STATUT ---
            HStack {
                Circle()
                    .fill(manager.isUp ? Color.green : Color.red)
                    .frame(width: 12, height: 12)
                
                Text(manager.isUp ? "Status : Cable connected" : "Status : Cable disconnected")
                    .font(.body)
                    .fontWeight(.medium)
            }
            .padding(.vertical, 5)
            
            // --- BOUTONS START / STOP ---
            HStack(spacing: 15) {
                Button(action: {
                    manager.start()
                }) {
                    Label("Start", systemImage: "play.fill")
                }
                // On grise le bouton si l'interface est déjà UP
                .disabled(manager.startedScreenCopy)
                
                Button(action: {
                    manager.stop()
                }) {
                    Label("Stop", systemImage: "stop.fill")
                }
                // On grise le bouton si l'interface est déjà DOWN
                .disabled(!manager.startedScreenCopy)
            }
            Divider()
                        
                        // --- CONTRÔLE DE LA LUMINOSITÉ ---
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Display brightness")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            HStack {
                                Image(systemName: "sun.min.fill") // Petite icône soleil
                                    .foregroundColor(.secondary)
                                
                                Slider(value: $manager.brightnessLevel, in: 0.0...100.0)
                                    .onChange(of: manager.brightnessLevel) { newValue in
                                        manager.sendBrightnessUpdate(newValue)
                                    }
                                
                                Image(systemName: "sun.max.fill") // Grande icône soleil
                                    .foregroundColor(.secondary)
                            }
                        }
                        // Grise le slider si la connexion n'est pas active (optionnel mais très propre)
                        .disabled(!manager.startedScreenCopy)
            Divider()
            
            // Bouton pour quitter l'app
            Button("Quitter") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain) // Style plus discret pour le bouton quitter
            .foregroundColor(.secondary)
        }
        .frame(alignment: Alignment.leading)
        .padding()
        .frame(width: 250, height: 280) // Taille fixe pour le popover
    }
        
}

#Preview {
    ContentView()
}
