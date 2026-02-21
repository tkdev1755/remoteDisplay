import Cocoa

protocol PowerMonitorDelegate: AnyObject {
    func systemDidWake()
    func systemWillSleep()
}

class PowerMonitor {
    weak var delegate: PowerMonitorDelegate?
    
    
    init(delegate: PowerMonitorDelegate?) {
        self.delegate = delegate

    }
    

    func startMonitoring() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(willSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
    }
    
    @objc private func didWake(_ notification: Notification) {
        print("Mac woke up")
        delegate?.systemDidWake()
    }
    
    @objc private func willSleep(_ notification: Notification) {
        print("Mac sleeps")
        delegate?.systemWillSleep()
    }
    
    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
