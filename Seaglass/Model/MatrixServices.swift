//
// Seaglass, a native macOS Matrix client
// Copyright © 2018, Neil Alexander
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import Cocoa
import SwiftMatrixSDK

protocol ViewControllerWithDelegates {
    var roomsController: MainViewRoomsController? { get }
    var channelController: MainViewRoomController? { get }
    
    var servicesDelegate: MatrixServicesDelegate? { get }
    var roomsDelegate: MatrixRoomsDelegate? { get }
    var channelDelegate: MatrixRoomDelegate? { get }
}

class MatrixServices: NSObject {
    static let inst = MatrixServices()
    static let credKey = "Matrix"
    
    enum State {
        case needsCredentials, notStarted, starting, started
    }
    private(set) var state: State
    
    // From the Matrix SDK
    var client: MXRestClient!
    var session: MXSession!
    var fileStore: MXStore!
    
    // Own structures
    var eventCache: Dictionary<String, [MXEvent]> = [:]
    
    var mainController: ViewControllerWithDelegates?
    
    var credentials: MXCredentials? {
        didSet {
            guard
                let homeServerURL = credentials?.homeServer,
                let userId = credentials?.userId,
                let accessToken = credentials?.accessToken
                else { UserDefaults.standard.removeObject(forKey: MatrixServices.credKey); return }
            
            let storedCredentials: [String: String] = [
                "homeServer": homeServerURL,
                "userId": userId,
                "token": accessToken
            ]
            
            UserDefaults.standard.set(storedCredentials, forKey: MatrixServices.credKey)
            UserDefaults.standard.synchronize()
            
            if state == .needsCredentials {
                state = .notStarted
            }
        }
    }
    
    override init() {
        if  let savedCredentials = UserDefaults.standard.dictionary(forKey: MatrixServices.credKey),
            let homeServer = savedCredentials["homeServer"] as? String,
            let userId = savedCredentials["userId"] as? String,
            let token = savedCredentials["token"] as? String {
            
            credentials = MXCredentials(homeServer: homeServer, userId: userId, accessToken: token)
            state = .notStarted
        } else {
            state = .needsCredentials
            credentials = nil
        }
    }
    
    func start(_ credentials: MXCredentials, disableCache: Bool) {
        let options = MXSDKOptions.sharedInstance()
        options.enableCryptoWhenStartingMXSession = true
        
        print("Creating REST client")
        client = MXRestClient(credentials: credentials, unrecognizedCertificateHandler: nil)
        
        print("Creating session")
        session = MXSession(matrixRestClient: client)
        
        state = .starting
        
        if disableCache {
            print("Disabling cache")
            fileStore = MXNoStore()
        } else {
            print("Enabling cache")
            fileStore = MXFileStore()
        }

        session.setStore(fileStore) { response in
            if case .failure(let error) = response {
                print("An error occurred setting the store: \(error)")
                return
            }
            
            self.state = .starting
            //self.session.crypto.warnOnUnknowDevices = false
            self.session.start { response in
                guard response.isSuccess else {
                    print("Assertion failed: setStore response was not true")
                    return
                }
                
                DispatchQueue.main.async {
                    print("Handing off to services delegate")
                    self.state = .started
                    self.mainController?.servicesDelegate?.matrixDidLogin(self.session);
                }
            }
        }
    }
    
    func close() {
        client?.close()
    }
    
    func logout() {
        self.mainController?.servicesDelegate?.matrixWillLogout()
        
        UserDefaults.standard.removeObject(forKey: MatrixServices.credKey)
        UserDefaults.standard.synchronize()
        self.credentials = nil
        self.state = .needsCredentials
        
        session.logout { _ in
            MXFileStore().deleteAllData()
            self.mainController?.servicesDelegate?.matrixDidLogout()
        }
    }
    
    func selectRoom(roomId: String) {
    }
    
    func subscribeToRoom(roomId: String) {
        let room = self.session.room(withRoomId: roomId)
        
        _ = room?.liveTimeline.listenToEvents() { (event, direction, roomState) in
            if event.roomId == nil {
                return
            }
            if event.roomId == "" {
                return
            }
            if !self.eventCache.keys.contains(event.roomId) {
                self.eventCache[event.roomId] = []
            }
            let cacheTypes = [ "m.room.create", "m.room.message", "m.room.name", "m.room.member", "m.room.topic", "m.room.canonical_alias" ]
            if !cacheTypes.contains(event.type) {
                return
            }
            if !self.eventCache[event.roomId]!.contains(where: { $0.eventId == event.eventId }) {
                if direction == .forwards {
                    self.eventCache[event.roomId]!.append(event)
                } else {
                    self.eventCache[event.roomId]!.insert(event, at: 0)
                }
                self.mainController?.channelDelegate?.matrixDidRoomMessage(event: event, direction: direction, roomState: roomState);
                self.mainController?.roomsDelegate?.matrixDidUpdateRoom(room!)
            }
        }
        
        room?.liveTimeline.resetPagination()
        room?.liveTimeline.paginate(30, direction: .backwards, onlyFromStore: false) { _ in
            // complete?
        }
    }
    
}