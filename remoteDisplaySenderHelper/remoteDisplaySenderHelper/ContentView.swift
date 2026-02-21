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
class ThunderboltManager: ObservableObject, PowerMonitorDelegate {
    @Published var isUp: Bool = false
    @Published var startedScreenCopy: Bool = false
    var screenCopyStatus = false
    // 2. Création du moniteur réseau
    // On peut cibler .wiredEthernet car le Thunderbolt Bridge est considéré comme une connexion filaire
    private let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    private let monitorQueue = DispatchQueue(label: "NetworkMonitorQueue")
    let programManager = ExternalProgramManager()
    private var onSleep = false
    var powerMonitor: PowerMonitor!
    let betterDisplayManager = BetterDisplayManager()
    let networkUpdater = NetworkUpdater()
    init() {
        self.powerMonitor = PowerMonitor(delegate: self)
        NotificationManager.shared.requestAuthorization()
        startMonitoring()
    }
    
    func systemDidWake() {
            onSleep = false
            print("⚡️ Delegate : Le Mac vient de se réveiller.")
            // Tu peux rajouter de la logique ici si nécessaire,
            // bien que ton onWake gère déjà l'appel à start()
            self.start()
            sendConnectionMessage()
        }
        
        func systemWillSleep() {
            onSleep = true
            sendSleepMessage()
            print("💤 Delegate : Le Mac va s'endormir.")
            self.stop()

            // Idem ici
    }
    
    private func sendConnectionMessage(){
        networkUpdater.sendMessage("CONN_OK")

    }
    
    private func sendSleepMessage(){
        networkUpdater.sendMessage("SLP_DETECTED")
    }
    
    private func startMonitoring() {
        powerMonitor.startMonitoring()
        // 3. Définition de l'action à exécuter quand l'état du réseau change
        monitor.pathUpdateHandler = { [weak self] path in
            
            // On vérifie si la connexion filaire est active et fonctionnelle
            let isConnected = (path.status == .satisfied)
            
            /* 4. On vérifie spécifiquement si l'interface utilisée est le Thunderbolt.
               Par défaut sur macOS, le Thunderbolt Bridge s'appelle généralement "bridge0".
               On parcourt les interfaces disponibles pour voir si le bridge0 est actif. */
            let isThunderboltBridgeActive = path.availableInterfaces.contains { interface in
                // Tu peux ajuster "bridge0" si ton interface a un autre nom (ex: "en1", "en2")
                interface.name == "bridge0"
            }
            DispatchQueue.main.async {
                self?.isUp = isConnected && isThunderboltBridgeActive
            }
            // Mise à jour de l'interface graphique sur le thread principal
            if isConnected && isThunderboltBridgeActive && !(self!.onSleep){
                print("Starting display copy - Thunderbolt connection detected")
                self?.start(modifyDisplayConf: true)
                
            }
            else if !isThunderboltBridgeActive && !(self!.onSleep){
                print("Stopping display copy - Thunderbolt connection dropped")
                self?.stop(modifyDisplayConf: true)
                
            }
            
        }
        
        // Démarrage du moniteur sur notre file d'attente (queue) en arrière-plan
        monitor.start(queue: monitorQueue)
    }
    
    deinit {
        monitor.cancel()
    }
    
    // --- ACTIONS DES BOUTONS ---
    func start(modifyDisplayConf:Bool = false) -> Void{
        if (modifyDisplayConf){
            self.betterDisplayManager.connectVirtualDisplay()
        }
        self.programManager.runSender()
        sendConnectionMessage()
        DispatchQueue.main.async {
            self.startedScreenCopy = true
        }
    }
    
    func stop(modifyDisplayConf:Bool = false) -> Void{
        sendSleepMessage()
        if (modifyDisplayConf){
            self.betterDisplayManager.disconnectVirtualDisplay()
        }
        self.programManager.stopSender()
        DispatchQueue.main.async {
            self.startedScreenCopy = false
        }
    }
}

struct ContentView: View {
    // On instancie notre manager
    @StateObject private var manager = ThunderboltManager()
    
    var body: some View {
        VStack(spacing: 20) {
            
            Text("Interface Thunderbolt")
                .font(.headline)
            
            // --- INDICATEUR DE STATUT ---
            HStack {
                // Une petite pastille de couleur
                Circle()
                    .fill(manager.isUp ? Color.green : Color.red)
                    .frame(width: 12, height: 12)
                
                // Le texte du statut
                Text(manager.isUp ? "Statut : Cable connected" : "Statut : Cable disconnected")
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
            
            // Bouton pour quitter l'app
            Button("Quitter") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain) // Style plus discret pour le bouton quitter
            .foregroundColor(.secondary)
        }
        .frame(alignment: Alignment.leading)
        .padding()
        .frame(width: 250, height: 200) // Taille fixe pour le popover
    }
}

#Preview {
    ContentView()
}
