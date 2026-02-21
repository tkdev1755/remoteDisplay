import Foundation
import Network

class NetworkUpdater {
    // Les paramètres de la cible
    private let host: NWEndpoint.Host = "10.0.0.1"
    private let port: NWEndpoint.Port = 5002
    
    // La file d'attente sur laquelle le réseau va travailler
    private let queue = DispatchQueue(label: "UDPQueue")
    
    func sendMessage(_ message: String) {
        // 1. Création de la connexion UDP
        let connection = NWConnection(host: host, port: port, using: .udp)
        
        // 2. Démarrage de la connexion
        connection.start(queue: queue)
        
        // 3. Encodage du message en données (Data)
        guard let data = message.data(using: .utf8) else { return }
        
        // 4. Envoi du paquet
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("❌ Erreur d'envoi UDP : \(error.localizedDescription)")
            } else {
                print("✅ Message UDP '\(message)' envoyé avec succès à 10.0.0.1:5002")
            }
            
            // 5. Fermeture de la connexion (très important en UDP pour ne pas fuir la mémoire)
            connection.cancel()
        })
    }
}
