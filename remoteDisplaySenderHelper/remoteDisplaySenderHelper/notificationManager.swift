//
//  notificationManager.swift
//  remoteDisplaySenderHelper
//
//  Created by Taha Khetib on 20/02/2026.
//

import Foundation
import UserNotifications 

class NotificationManager {
    static let shared = NotificationManager()
    var  notificationStatus: Bool = false
    private init() {}
    

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                self.notificationStatus = true
                print("Permissions for notifications granted")
            } else if let error = error {
                self.notificationStatus = false
                print("Error while trying to get notifications : \(error.localizedDescription)")
            } else {
                self.notificationStatus = false
                print("User refused to receive notifications")
            }
        }
    }
    
    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error while sending notification : \(error.localizedDescription)")
            }
        }
    }
}
