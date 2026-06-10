//
//  BetterDisplayManager.swift
//  remoteDisplaySenderHelper
//
//  Created by Taha Khetib on 21/02/2026.
//

import Foundation

enum BetterDisplayStatuses{
    case up
    case error
    case not_installed
    case no_display_id
    case unknown
}
class BetterDisplayManager {
    private let cliURL = URL(fileURLWithPath: "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay")
    
    
    public let virtualDisplayID: Int
    public var displayIDStatus : Bool = false
    public var betterDisplayStatus : BetterDisplayStatuses = BetterDisplayStatuses.unknown
    public var onNoVirtualID: ()->Void
    init(virtualDisplayID: Int, onNoVirtualID:@escaping ()->Void) {
        self.onNoVirtualID = onNoVirtualID
        self.virtualDisplayID = virtualDisplayID
        self.displayIDStatus = virtualDisplayID > 0
        if (self.virtualDisplayID == -1){
            betterDisplayStatus = BetterDisplayStatuses.no_display_id
            print("No valid display is detected, calling for an ID")
            self.onNoVirtualID()
        }
    }
    
    func connectVirtualDisplay() {
        print(" Connecting the virtual display via BetterDisplay")
        runCLI(arguments: ["set", "-namematch=\(virtualDisplayID)", "-connected=on"])
    }
    
    func disconnectVirtualDisplay() {
        print("Disconnecting the virtual display")
        runCLI(arguments: ["set", "-tagID=\(virtualDisplayID)", "-connected=off"])
    }
    
    private func runCLI(arguments: [String]) {
        guard FileManager.default.fileExists(atPath: cliURL.path) else {
            betterDisplayStatus = BetterDisplayStatuses.not_installed
            print("Better display isn't installed in the /Applications folder.")
            return
        }
        let process = Process()
        process.executableURL = cliURL
        process.arguments = arguments
        
        do {
            try process.run()
            
            
            process.waitUntilExit() // On attend que la commande soit terminée
            if (betterDisplayStatus != BetterDisplayStatuses.no_display_id){
                if (process.terminationStatus == 0){
                    betterDisplayStatus = BetterDisplayStatuses.up
                }
                else{
                    betterDisplayStatus = BetterDisplayStatuses.error
                }
            }
            
      

        } catch {
            
            print("Error while calling BetterDisplay : \(error.localizedDescription)")
            betterDisplayStatus = BetterDisplayStatuses.error
        }
    }
}
