//
//  ThunderBoltManager.swift
//  remoteDisplaySenderHelper
//
//  Created by Taha Khetib on 21/02/2026.
//

import Foundation
import SwiftUI
import SwiftData
internal import Combine
import Network
import SwiftUI
import Network
import CoreGraphics

class ThunderboltManager: ObservableObject, PowerMonitorDelegate {
    @Published var isUp: Bool = false
    @Published var startedScreenCopy: Bool = false
    @Published var brightnessLevel: Double = 100.0
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
        self.startMonitoring()
    }
    func sendBrightnessUpdate(_ value: Double) {
            // On limite à 2 décimales pour ne pas envoyer "BRIGHTNESS:0.75000001"
            let formattedValue = String(format: "%.0f", value)
            let message = "BRIGHTNESS:\(formattedValue)"
            
            // On utilise ton UDPSender existant
            self.networkUpdater.sendMessage(message)
    }
    func systemDidWake() {
            print("⚡️ Delegate : Le Mac vient de se réveiller.")
            // Tu peux rajouter de la logique ici si nécessaire,
            // bien que ton onWake gère déjà l'appel à start()
            print("☀️ Vrai réveil confirmé ! L'écran est physiquement allumé.")
            self.onSleep = false
            self.start()
            
        }
        
        func systemWillSleep() {
            onSleep = true
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
    func start(modifyDisplayConf:Bool = false, fromSleep:Bool = false) -> Void{
        if (modifyDisplayConf){
            self.betterDisplayManager.connectVirtualDisplay()
        }
        self.programManager.runSender()
        if (!fromSleep){
            sendConnectionMessage()
        }
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
