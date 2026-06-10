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
    @AppStorage("betterDisplayID") var virtualID: String = ""
    
    var screenCopyStatus = false
    
    private let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    private let monitorQueue = DispatchQueue(label: "NetworkMonitorQueue")
    let programManager = ExternalProgramManager()
    private var onSleep = false
    var powerMonitor: PowerMonitor!
    let betterDisplayManager : BetterDisplayManager
    let networkUpdater = NetworkUpdater()
    
    init() {
        @AppStorage("betterDisplayID") var virtualID: String = ""
        NotificationManager.shared.requestAuthorization()
        self.betterDisplayManager = BetterDisplayManager(virtualDisplayID: Int(virtualID) ?? -1, onNoVirtualID: ThunderboltManager.callForVirtualIDData)
        self.powerMonitor = PowerMonitor(delegate: self)
        
        self.startMonitoring()
    }
    
    static func callForVirtualIDData(){
        NotificationManager.shared.sendNotification(title: "Please enter the BetterDisplay ID for the display to target", body: "You can find this by opening Better Display")
    }
    
    func sendBrightnessUpdate(_ value: Double) {
            let formattedValue = String(format: "%.0f", value)
            let message = "BRIGHTNESS:\(formattedValue)"
            
            
            self.networkUpdater.sendMessage(message)
    }
    
    
    func systemDidWake() {
            print("Received action from delegate : Mac woke up")
            self.onSleep = false
            self.start()
            
        }
        
        func systemWillSleep() {
            onSleep = true
            print("Action from delegate : Mac goes to sleep")
            self.stop()

            
    }
    
    private func sendConnectionMessage(){
        networkUpdater.sendMessage("CONN_OK")

    }
    
    private func sendSleepMessage(){
        networkUpdater.sendMessage("SLP_DETECTED")
    }
    
    
    private func startMonitoring() {
        powerMonitor.startMonitoring()
        
        monitor.pathUpdateHandler = { [weak self] path in
            
            
            let isConnected = (path.status == .satisfied)
            
            
            let isThunderboltBridgeActive = path.availableInterfaces.contains { interface in
                
                interface.name == "bridge0"
            }
            DispatchQueue.main.async {
                self?.isUp = isConnected && isThunderboltBridgeActive
            }
            
            if isConnected && isThunderboltBridgeActive && !(self!.onSleep){
                print("Starting display copy - Thunderbolt connection detected")
                self?.start(modifyDisplayConf: true)
                
            }
            else if !isThunderboltBridgeActive && !(self!.onSleep){
                print("Stopping display copy - Thunderbolt connection dropped")
                self?.stop(modifyDisplayConf: true)
                
            }
            
        }
        
        
        monitor.start(queue: monitorQueue)
    }
    
    deinit {
        monitor.cancel()
    }
    
    
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
