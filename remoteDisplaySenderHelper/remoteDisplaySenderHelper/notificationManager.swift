//
//  notificationManager.swift
//  remoteDisplaySenderHelper
//
//  Created by Taha Khetib on 20/02/2026.
//

import Foundation
import UserNotifications // Framework indispensable

class NotificationManager {
    // Singleton pour l'appeler facilement depuis n'importe où
    static let shared = NotificationManager()
    
    private init() {}
    
    // 1. Demander la permission (à appeler au lancement de l'app)
    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("Permission pour les notifications accordée.")
            } else if let error = error {
                print("Erreur lors de la demande de permission : \(error.localizedDescription)")
            } else {
                print("L'utilisateur a refusé les notifications.")
            }
        }
    }
    
    // 2. Envoyer une notification
    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default // Son de notification standard de macOS
        
        // Le déclencheur (ici, dans 1 seconde, sans répétition)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        
        // La requête (avec un identifiant unique pour éviter d'écraser d'autres alertes)
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: trigger
        )
        
        // Ajout de la requête au centre de notifications
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Erreur d'envoi de la notification : \(error.localizedDescription)")
            }
        }
    }
}
