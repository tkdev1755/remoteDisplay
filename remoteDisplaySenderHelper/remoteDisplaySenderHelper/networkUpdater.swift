import Foundation
import Network

class NetworkUpdater {
    
    private let host: NWEndpoint.Host = "10.0.0.1"
    private let port: NWEndpoint.Port = 5002
    
    
    private let queue = DispatchQueue(label: "UDPQueue")
    
    func sendMessage(_ message: String) {
        
        let connection = NWConnection(host: host, port: port, using: .udp)
        
        
        connection.start(queue: queue)
        
        
        guard let data = message.data(using: .utf8) else { return }
        
        
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
            } else {
            }
            
            
            connection.cancel()
        })
    }
}
