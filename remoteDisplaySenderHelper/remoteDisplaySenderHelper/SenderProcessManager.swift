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
                print("App is closing right now, killing sender process")
                self?.stopSender()
            }
            
            
            let signals = [SIGINT, SIGTERM, SIGQUIT]
            
            for sig in signals {
                signal(sig, SIG_IGN)
                
                let signalSource = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                signalSource.setEventHandler { [weak self] in
                    
                    
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
            print("Error : Impossible to find the sender program in the app bundle")
            return
        }
        let process = Process()
        process.executableURL = executableURL
        
        
    
        
        senderProcess = process

        print("Now launching the process")
        do {
            try process.run()
        } catch {
            print("Error while launching the sender process : \(error.localizedDescription)")
        }
        print("process launched")
    }
    
    func stopSender(){
        if let process = senderProcess, process.isRunning {
                    print("Stopping the sender process")
                    
                    process.terminate()
                    
                    process.waitUntilExit()
                    print("Sender process stopped")
        }
    }
    
}
