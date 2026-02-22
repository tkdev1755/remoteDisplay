//
//  SenderProcessManager.swift
//  remoteDisplaySenderHelper
//
//  Created by Taha Khetib on 21/02/2026.
//

import Foundation
import AppKit

class ExternalProgramManager {
    private var senderProcess : Process?
    
    
    
    init() {
        setupTerminationHandlers()
    }
    
    private func setupTerminationHandlers() {
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                print("Fermeture de l'app détectée. Arrêt du sender...")
                self?.stopSender()
            }
            
            
            let signals = [SIGINT, SIGTERM, SIGQUIT]
            
            for sig in signals {
                signal(sig, SIG_IGN)
                
                let signalSource = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                signalSource.setEventHandler { [weak self] in
                    print("Signal Unix \(sig) reçu ! Nettoyage d'urgence...")
                    
                    self?.stopSender()
                    
                    exit(128 + sig)
                }
                signalSource.resume()
            }
    }
    func runSender() {
        stopSender()
        print("Stopped sender")
        guard let executableURL = Bundle.main.url(forResource: "sender", withExtension: nil) else {
            print("Erreur : Impossible de trouver le programme 'sender' dans le Bundle.")
            return
        }
        print("Got executable URL")
        // 2. Préparer le processus
        let process = Process()
        process.executableURL = executableURL
        
        
    
        
        senderProcess = process
        // 5. Lancer le programme
        print("Now launching the process")
        do {
            try process.run()
        } catch {
            print("Erreur lors de l'exécution du programme : \(error.localizedDescription)")
        }
        print("process launched")
    }
    
    func stopSender(){
        if let process = senderProcess, process.isRunning {
                    print("Arrêt du sender en cours...")
                    
                    // terminate() envoie un signal SIGTERM brutal au processus pour le tuer
                    process.terminate()
                    
                    // Optionnel mais recommandé : on attend qu'il soit vraiment mort avant de continuer
                    process.waitUntilExit()
                    print("🛑 Sender arrêté.")
        }
    }
    
}
