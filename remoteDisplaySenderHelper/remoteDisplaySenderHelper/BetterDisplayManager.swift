//
//  BetterDisplayManager.swift
//  remoteDisplaySenderHelper
//
//  Created by Taha Khetib on 21/02/2026.
//

import Foundation


class BetterDisplayManager {
    
    // Le chemin standard vers l'exécutable CLI à l'intérieur de l'app BetterDisplay
    private let cliURL = URL(fileURLWithPath: "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay")
    
    // Remplace par le nom exact de l'écran virtuel que tu as créé dans BetterDisplay
    private let virtualDisplayID = "5"
    
    func connectVirtualDisplay() {
        print("🖥️ Connexion de l'écran virtuel via BetterDisplay...")
        runCLI(arguments: ["set", "-namematch=\(virtualDisplayID)", "-connected=on"])
    }
    
    func disconnectVirtualDisplay() {
        print("🖥️ Déconnexion de l'écran virtuel...")
        runCLI(arguments: ["set", "-tagID=\(virtualDisplayID)", "-connected=off"])
    }
    
    private func runCLI(arguments: [String]) {
        // Vérification que BetterDisplay est bien installé sur le Mac
        guard FileManager.default.fileExists(atPath: cliURL.path) else {
            print("⚠️ BetterDisplay n'est pas installé dans /Applications.")
            return
        }
        
        let process = Process()
        process.executableURL = cliURL
        process.arguments = arguments
        
        do {
            try process.run()
            
            
            process.waitUntilExit() // On attend que la commande soit terminée
      

        } catch {
            print("❌ Erreur lors de l'appel à BetterDisplay : \(error.localizedDescription)")
        }
    }
}
