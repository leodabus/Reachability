//
//  Network.swift
//  Reachability
//
//  Created by Leonardo Savio Dabus on 11/01/26.
//

import Foundation
import SystemConfiguration


public struct Network {
    
    @MainActor public static var reachability: Reachability?
    public static let flagsChanged = Notification.Name("FlagsChanged")
    
    public enum Status: String {
        case unreachable, wifi, wwan
    }
    
    public enum Error: Swift.Error {
        case failedToSetCallout
        case failedToSetDispatchQueue
        case failedToCreateWith(String)
        case failedToInitializeWith(sockaddr_in, sockaddr_in6)
    }
}
