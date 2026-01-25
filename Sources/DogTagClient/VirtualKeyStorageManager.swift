// Copyright 2025 FIDO3.ai
// Generated on 2025-7-19
import Foundation
import DogTagStorage

// MARK: - Virtual Key Storage Manager

public class VirtualKeyStorageManager: ObservableObject {
    public static let shared = VirtualKeyStorageManager()

    @Published public var currentStorageMode: StorageMode = .local
    @Published public var activeVirtualKey: VirtualHardwareKey?

    private var virtualKeyMountPoint: URL?

    private init() {}

    /// Safely executes an async operation and returns the result synchronously
    /// Uses a background queue to avoid main thread deadlocks
    private func runAsyncSync<T>(_ operation: @escaping () async -> T) -> T {
        // If we're already on a background thread, we can use a simpler approach
        if Thread.isMainThread {
            // When on main thread, dispatch to background to avoid deadlock
            var result: T!
            let semaphore = DispatchSemaphore(value: 0)

            DispatchQueue.global(qos: .userInitiated).async {
                Task {
                    result = await operation()
                    semaphore.signal()
                }
            }

            let waitResult = semaphore.wait(timeout: .now() + 30.0)
            if waitResult == .timedOut {
                print("⚠️ [VirtualKeyStorageManager] Operation timed out")
            }
            return result
        } else {
            // On background thread, we can block directly
            var result: T!
            let semaphore = DispatchSemaphore(value: 0)

            Task {
                result = await operation()
                semaphore.signal()
            }

            semaphore.wait()
            return result
        }
    }
    
    public enum StorageMode: Equatable {
        case local
        case virtual(VirtualHardwareKey)
        
        var description: String {
            switch self {
            case .local:
                return "Local Storage"
            case .virtual(let key):
                return "Virtual Key: \(key.name)"
            }
        }
        
        var isVirtual: Bool {
            switch self {
            case .local:
                return false
            case .virtual:
                return true
            }
        }
        
        public static func == (lhs: StorageMode, rhs: StorageMode) -> Bool {
            switch (lhs, rhs) {
            case (.local, .local):
                return true
            case (.virtual(let lhsKey), .virtual(let rhsKey)):
                return lhsKey.id == rhsKey.id
            default:
                return false
            }
        }
    }
    
    // MARK: - Storage Mode Switching
    
    /// Switch to using a virtual key as primary storage
    public func switchToVirtualStorage(_ virtualKey: VirtualHardwareKey, password: String? = nil) async throws {
        print("🔄 SWITCHING TO VIRTUAL STORAGE: \(virtualKey.name)")
        
        // First, unmount any existing virtual key
        try await switchToLocalStorage()
        
        // Mount the new virtual key
        let mountPoint = try await VirtualHardwareKeyManager.shared.mountDiskImage(virtualKey.diskImagePath, password: password)
        virtualKeyMountPoint = mountPoint
        
        // Initialize database containers for the virtual key
        try await initializeVirtualContainers(at: mountPoint)
        
        // Update state
        await MainActor.run {
            currentStorageMode = .virtual(virtualKey)
            activeVirtualKey = virtualKey
        }
        
        // Update access tracking in the virtual key manager
        Task {
            // Note: Credential count is calculated on-demand now (self-contained approach)
        }
        
        print("✅ Successfully switched to virtual storage: \(virtualKey.name)")
        print("📁 Mount point: \(mountPoint.path)")
    }
    
    /// Switch back to local storage
    public func switchToLocalStorage() async throws {
        print("🔄 SWITCHING TO LOCAL STORAGE")
        
        // Force switch to local storage mode FIRST (before unmounting)
        // This ensures we don't get stuck in virtual mode if unmount fails
        await MainActor.run {
            currentStorageMode = .local
            activeVirtualKey = nil
        }
        
        // Try to unmount virtual key if mounted (but don't fail if it's busy)
        if let mountPoint = virtualKeyMountPoint {
            do {
                try await VirtualHardwareKeyManager.shared.unmountDiskImage(mountPoint)
                virtualKeyMountPoint = nil
                print("✅ Successfully unmounted virtual key")
            } catch {
                print("⚠️ Could not unmount virtual key (disk busy): \(error)")
                print("💡 Virtual key will remain mounted but storage mode is now LOCAL")
                print("💡 Virtual key mount point kept for potential future cleanup")
                // Don't set virtualKeyMountPoint to nil so we can try to unmount later
                // But storage mode is already set to local above
            }
        }
        
        print("✅ Successfully switched to local storage")
    }
    
    /// Attempt to clean up any unmounted virtual key mount points
    /// Call this periodically or when you know the virtual key is no longer in use
    public func cleanupVirtualKeyMountPoints() async {
        guard currentStorageMode == .local else {
            print("💡 Cleanup skipped - currently using virtual storage")
            return
        }
        
        if let mountPoint = virtualKeyMountPoint {
            print("🧹 Attempting to cleanup virtual key mount point: \(mountPoint.path)")
            do {
                try await VirtualHardwareKeyManager.shared.unmountDiskImage(mountPoint)
                virtualKeyMountPoint = nil
                print("✅ Successfully cleaned up virtual key mount point")
            } catch {
                print("⚠️ Virtual key mount point still busy, will try again later")
            }
        }
    }
    
    // MARK: - Database Container Management
    
    private func initializeVirtualContainers(at mountPoint: URL) async throws {
        // FIXED: Use ONLY the unified database that export creates - NO separate databases!
        print("🔧 Initializing virtual database container at: \(mountPoint.path)")
        
        let unifiedDbPath = mountPoint.appendingPathComponent("WebAuthnClient.db")
        
        // Test that the UNIFIED database exists and is accessible
        do {
            let config = StorageConfiguration(
                databaseName: "WebAuthnClient", // SAME AS EXPORT
                customDatabasePath: unifiedDbPath.path
            )
            let storage = try await StorageFactory.createStorageManager(configuration: config)
            let info = try await storage.getStorageInfo()
            print("✅ UNIFIED virtual database accessible: \(info.credentialCount) client + \(info.serverCredentialCount) server credentials")
            
            print("✅ Virtual database container initialized successfully - SINGLE UNIFIED DATABASE")
        } catch {
            print("❌ Failed to initialize unified virtual database: \(error)")
            throw error
        }
    }
    
    // MARK: - Storage Access Methods
    
    /// Get the appropriate credential store based on current storage mode
    internal func getClientCredentialStore() -> WebAuthnClientCredentialStore {
        switch currentStorageMode {
        case .local:
            print("🔍 Using LOCAL storage for client credentials")
            return WebAuthnClientCredentialStore.shared
        case .virtual:
            // SIMPLIFIED: Use unified credential store for virtual keys
            if let mountPoint = virtualKeyMountPoint {
                let unifiedDbPath = mountPoint.appendingPathComponent("WebAuthnClient.db") // UNIFIED database name
                print("🔍 Using VIRTUAL unified storage for credentials: \(unifiedDbPath.path)")
                return WebAuthnClientCredentialStore(customDatabasePath: unifiedDbPath.path)
            } else {
                print("⚠️ Virtual key mount point not available, falling back to local")
                return WebAuthnClientCredentialStore.shared
            }
        }
    }
    
    /// Get the appropriate WebAuthn manager based on current storage mode
    /// NOTE: This is being phased out in favor of SimplifiedCredentialManager
    public func getWebAuthnManager() -> WebAuthnManager {
        switch currentStorageMode {
        case .local:
            print("🔍 Using LOCAL WebAuthn manager")
            return WebAuthnManager.shared
        case .virtual:
            // SIMPLIFIED: Use unified credential database for virtual keys
            if let mountPoint = virtualKeyMountPoint {
                let unifiedDbPath = mountPoint.appendingPathComponent("WebAuthnClient.db") // UNIFIED database name
                print("🔍 Using VIRTUAL unified WebAuthn manager with database: \(unifiedDbPath.path)")
                return WebAuthnManager(customDatabasePath: unifiedDbPath.path)
            } else {
                print("⚠️ Virtual key mount point not available, falling back to local")
                return WebAuthnManager.shared
            }
        }
    }
    
    /// Get client credentials from current storage
    public func getAllClientCredentials() -> [LocalCredential] {
        switch currentStorageMode {
        case .local:
            print("🔍 Getting client credentials from LOCAL storage")
            return WebAuthnClientCredentialStore.shared.getAllCredentials()
        case .virtual:
            print("🔍 Getting client credentials from VIRTUAL storage")
            return getVirtualClientCredentials()
        }
    }
    
    /// Get server credentials from current storage
    public func getAllServerCredentials() -> [WebAuthnCredential] {
        switch currentStorageMode {
        case .local:
            print("🔍 Getting server credentials from LOCAL storage")
            return WebAuthnManager.shared.getAllUsers()
        case .virtual:
            print("🔍 Getting server credentials from VIRTUAL storage")
            return getVirtualServerCredentials()
        }
    }
    
    // MARK: - Virtual Storage Access
    
    private func getVirtualClientCredentials() -> [LocalCredential] {
        guard let mountPoint = virtualKeyMountPoint else {
            print("❌ No virtual key mounted")
            return []
        }

        // FIXED: Use the SAME unified database that export/analysis use
        let unifiedDbPath = mountPoint.appendingPathComponent("WebAuthnClient.db")

        return runAsyncSync {
            do {
                let config = StorageConfiguration(
                    databaseName: "WebAuthnClient", // SAME AS EXPORT
                    customDatabasePath: unifiedDbPath.path
                )
                let virtualKeyStorage = try await StorageFactory.createStorageManager(configuration: config)

                // Fetch credentials from virtual key's UNIFIED database
                let credentials = try await virtualKeyStorage.fetchCredentials()

                return credentials.map { credData in
                    LocalCredential(
                        id: credData.id,
                        rpId: credData.rpId,
                        userName: credData.userDisplayName ?? "Unknown",
                        userDisplayName: credData.userDisplayName ?? "Unknown",
                        userId: String(data: credData.userHandle, encoding: .utf8) ?? credData.id,
                        publicKey: credData.publicKey, // PUBLIC KEY preserved
                        createdAt: credData.createdAt
                    )
                }
            } catch {
                print("❌ Failed to fetch virtual client credentials: \(error)")
                return [LocalCredential]()
            }
        }
    }
    
    private func getVirtualServerCredentials() -> [WebAuthnCredential] {
        guard let mountPoint = virtualKeyMountPoint else {
            print("❌ No virtual key mounted")
            return []
        }

        // FIXED: Use the SAME unified database that export/analysis use
        let unifiedDbPath = mountPoint.appendingPathComponent("WebAuthnClient.db")

        return runAsyncSync {
            do {
                let config = StorageConfiguration(
                    databaseName: "WebAuthnClient", // SAME AS EXPORT
                    customDatabasePath: unifiedDbPath.path
                )
                let virtualKeyStorage = try await StorageFactory.createStorageManager(configuration: config)

                // Fetch server credentials from virtual key's UNIFIED database
                let credentials = try await virtualKeyStorage.fetchServerCredentials()

                return credentials.map { serverData in
                    WebAuthnCredential(
                        id: serverData.id,
                        publicKey: serverData.publicKeyJWK,
                        signCount: UInt32(serverData.signCount),
                        username: String(data: serverData.userHandle, encoding: .utf8) ?? "Unknown",
                        algorithm: serverData.algorithm,
                        protocolVersion: serverData.protocolVersion,
                        attestationFormat: serverData.attestationFormat ?? "none",
                        aaguid: serverData.aaguid,
                        isDiscoverable: serverData.isDiscoverable,
                        backupEligible: serverData.backupEligible,
                        backupState: serverData.backupState,
                        emoji: serverData.emoji,
                        lastLoginIP: serverData.lastLoginIP,
                        lastLoginAt: serverData.lastVerified,
                        createdAt: serverData.createdAt,
                        isEnabled: serverData.isEnabled,
                        isAdmin: serverData.isAdmin,
                        userNumber: serverData.userNumber
                    )
                }
            } catch {
                print("❌ Failed to fetch virtual server credentials: \(error)")
                return [WebAuthnCredential]()
            }
        }
    }
    
    // MARK: - Storage Information
    
    public func getStorageInfo() -> StorageInfo {
        let clientCount = getAllClientCredentials().count
        let serverCount = getAllServerCredentials().count
        
        return StorageInfo(
            mode: currentStorageMode,
            clientCredentialCount: clientCount,
            serverCredentialCount: serverCount,
            totalCredentialCount: clientCount + serverCount,
            mountPoint: virtualKeyMountPoint?.path,
            isVirtualKeyMounted: virtualKeyMountPoint != nil
        )
    }
    
    // MARK: - Counter Synchronization
    
    /// Synchronize signature counters between local and virtual storage for credentials that exist in both
    public func synchronizeCounters() async {
        guard currentStorageMode.isVirtual else {
            print("💫 Counter sync skipped - not in virtual mode")
            return
        }
        
        print("💫 Starting signature counter synchronization...")
        
        let localCredentials = WebAuthnClientCredentialStore.shared.getAllCredentials()
        let virtualCredentials = getVirtualClientCredentials()
        
        var syncCount = 0
        
        for localCred in localCredentials {
            if virtualCredentials.first(where: { $0.id == localCred.id }) != nil {
                // Found matching credentials - synchronize counters
                let localCount = WebAuthnClientCredentialStore.shared.getSignCount(for: localCred.id) ?? 0
                let virtualCount = getClientCredentialStore().getSignCount(for: localCred.id) ?? 0
                
                if localCount != virtualCount {
                    print("💫 Syncing counter for credential \(localCred.id): local=\(localCount), virtual=\(virtualCount)")
                    
                    // Use the higher count (more recent usage)
                    let maxCount = max(localCount, virtualCount)
                    
                    // Update both storage locations
                    _ = WebAuthnClientCredentialStore.shared.updateSignCount(for: localCred.id, newCount: maxCount)
                    _ = getClientCredentialStore().updateSignCount(for: localCred.id, newCount: maxCount)
                    
                    syncCount += 1
                    print("💫 Updated both counters to \(maxCount)")
                }
            }
        }
        
        print("💫 Counter synchronization complete: \(syncCount) credentials synchronized")
    }
    
    /// Update signature counter in both local and virtual storage if credential exists in both
    public func updateCounterInBothStorages(credentialId: String, newCount: UInt32) {
        let localExists = WebAuthnClientCredentialStore.shared.getAllCredentials().contains { $0.id == credentialId }
        let virtualExists = getVirtualClientCredentials().contains { $0.id == credentialId }
        
        if localExists && virtualExists {
            print("💫 Updating counter in both storages for credential \(credentialId): \(newCount)")
            
            // Update local storage
            _ = WebAuthnClientCredentialStore.shared.updateSignCount(for: credentialId, newCount: newCount)
            
            // Update virtual storage if we're in virtual mode
            if currentStorageMode.isVirtual {
                _ = getClientCredentialStore().updateSignCount(for: credentialId, newCount: newCount)
            }
        }
    }
    
    /// Get the highest signature counter value across all storage locations for a credential
    public func getMaxSignCount(for credentialId: String) -> UInt32 {
        let localCount = WebAuthnClientCredentialStore.shared.getSignCount(for: credentialId) ?? 0
        let virtualCount = getClientCredentialStore().getSignCount(for: credentialId) ?? 0
        return max(localCount, virtualCount)
    }
    
    // MARK: - Counter Mode Detection
    
    /// Detect if there are duplicate credentials across storage locations
    public func detectDuplicateCredentials() -> [String] {
        let localCredentials = WebAuthnClientCredentialStore.shared.getAllCredentials()
        let virtualCredentials = getVirtualClientCredentials()
        
        let localIds = Set(localCredentials.map { $0.id })
        let virtualIds = Set(virtualCredentials.map { $0.id })
        
        return Array(localIds.intersection(virtualIds))
    }
    
    /// Suggest optimal signature counter mode based on environment
    public func suggestCounterMode() -> WebAuthnManager.SignatureCounterMode {
        let duplicates = detectDuplicateCredentials()
        
        if !duplicates.isEmpty {
            print("💡 Detected \(duplicates.count) credentials in both local and virtual storage")
            print("💡 Recommending server-managed counter mode to prevent sync issues")
            return .serverManaged
        }
        
        // Check if we're primarily using platform authenticators
        let localCredentials = getAllClientCredentials()
        let hasOnlyPlatformCreds = localCredentials.allSatisfy { cred in
            // Platform authenticators typically have more standardized RP IDs
            return cred.rpId.contains(".") // Simple heuristic for web domains
        }
        
        if hasOnlyPlatformCreds {
            print("💡 Detected primarily platform authenticator usage")
            print("💡 Recommending server-managed counter mode (Apple/Microsoft/Google pattern)")
            return .serverManaged
        }
        
        print("💡 Mixed or hardware authenticator environment detected")
        print("💡 Recommending server-managed counter mode for compatibility")
        return .serverManaged
    }
    
    /// Apply optimal counter mode to WebAuthn managers
    public func optimizeCounterMode() {
        let optimalMode = suggestCounterMode()
        
        // Apply to local WebAuthn manager
        WebAuthnManager.shared.signatureCounterMode = optimalMode
        
        // Apply to virtual WebAuthn manager if available
        if currentStorageMode.isVirtual {
            getWebAuthnManager().signatureCounterMode = optimalMode
        }
        
        print("✅ Applied signature counter mode: \(optimalMode)")
    }
    
    /// Optimize counter mode specifically for regular local keys
    /// This ensures local keys get the same counter management benefits
    public func optimizeLocalKeyCounterMode() {
        // For regular local keys, always use server-managed mode
        // This prevents counter sync issues when keys are later exported/imported
        let optimalMode = WebAuthnManager.SignatureCounterMode.serverManaged
        
        // Apply to local WebAuthn manager
        WebAuthnManager.shared.signatureCounterMode = optimalMode
        
        print("✅ Applied server-managed counter mode for local keys")
        print("💡 This prevents counter sync issues if keys are later exported/imported")
    }
    
    /// Update signature counter for regular local keys with proper synchronization
    public func updateLocalKeyCounter(credentialId: String, newCount: UInt32) {
        // Update local storage
        let success = WebAuthnClientCredentialStore.shared.updateSignCount(for: credentialId, newCount: newCount)
        
        if success {
            print("💫 Updated local key counter for credential \(credentialId): \(newCount)")
            
            // If this credential also exists in virtual storage, sync it there too
            if currentStorageMode.isVirtual {
                let virtualExists = getVirtualClientCredentials().contains { $0.id == credentialId }
                if virtualExists {
                    _ = getClientCredentialStore().updateSignCount(for: credentialId, newCount: newCount)
                    print("💫 Also synchronized counter in virtual storage")
                }
            }
        } else {
            print("❌ Failed to update local key counter for credential \(credentialId)")
        }
    }
    
    // MARK: - Server Counter Update Configuration
    
    /// Configuration for server-side counter updates
    /// **DISABLED BY DEFAULT** for safety - only enable if server supports it
    public struct ServerCounterConfig {
        /// Whether to attempt server counter updates (DEFAULT: false for safety)
        public var enabled: Bool = false
        
        /// Whether to parse server responses for counter updates (DEFAULT: false)
        public var parseServerResponses: Bool = false
        
        /// Whether to log server counter operations (DEFAULT: true for debugging)
        public var logOperations: Bool = true
        
        /// Fallback behavior if server update fails (DEFAULT: continue normally)
        public var failureMode: FailureMode = .continueNormally
        
        public enum FailureMode {
            case continueNormally  // Don't break authentication if server update fails
            case logWarning        // Log warning but continue
        }
    }
    
    /// Server counter configuration - SAFE DEFAULTS (disabled)
    public var serverCounterConfig = ServerCounterConfig()
    
    /// **SAFE** method to update counter from server response
    /// This will NEVER break existing functionality - it only adds optional enhancements
    public func updateCounterFromServerResponse(
        credentialId: String,
        serverResponse: [String: Any]
    ) {
        // SAFETY CHECK: Only proceed if explicitly enabled
        guard serverCounterConfig.enabled else {
            if serverCounterConfig.logOperations {
                print("💫 Server counter updates disabled (safe default)")
            }
            return
        }
        
        // SAFETY CHECK: Validate inputs
        guard !credentialId.isEmpty else {
            if serverCounterConfig.logOperations {
                print("⚠️ Invalid credential ID for server counter update")
            }
            return
        }
        
        // Try to extract counter from server response (various possible formats)
        var serverCounter: UInt32?
        
        // Check common server response formats
        if let counter = serverResponse["signCount"] as? UInt32 {
            serverCounter = counter
        } else if let counter = serverResponse["counter"] as? UInt32 {
            serverCounter = counter
        } else if let counter = serverResponse["signatureCounter"] as? UInt32 {
            serverCounter = counter
        } else if let counterInt = serverResponse["signCount"] as? Int {
            serverCounter = UInt32(max(0, counterInt))
        } else if let counterString = serverResponse["signCount"] as? String,
                  let counterValue = UInt32(counterString) {
            serverCounter = counterValue
        }
        
        guard let newCounter = serverCounter else {
            if serverCounterConfig.logOperations {
                print("💫 No server counter found in response (this is normal for many servers)")
            }
            return
        }
        
        // SAFETY: Only update if the server counter is reasonable
        let currentCounter = getMaxSignCount(for: credentialId)
        if newCounter >= currentCounter {
            updateCounterInBothStorages(credentialId: credentialId, newCount: newCounter)
            if serverCounterConfig.logOperations {
                print("💫 ✅ Updated counter from server: \(currentCounter) → \(newCounter)")
            }
        } else {
            if serverCounterConfig.logOperations {
                print("💫 ⚠️ Server counter (\(newCounter)) is less than current (\(currentCounter)) - skipping update")
            }
        }
    }
    
    /// **SAFE** method to enable server counter updates
    /// Call this ONLY if you're sure your server supports counter updates
    /// Can be safely disabled at any time without breaking functionality
    public func enableServerCounterUpdates(
        parseResponses: Bool = true,
        logOperations: Bool = true,
        failureMode: ServerCounterConfig.FailureMode = .continueNormally
    ) {
        print("💫 🔧 ENABLING server counter updates (experimental feature)")
        print("💫 ⚠️  This is SAFE but experimental - can be disabled anytime")
        print("💫 📝 To disable: VirtualKeyStorageManager.shared.disableServerCounterUpdates()")
        
        serverCounterConfig.enabled = true
        serverCounterConfig.parseServerResponses = parseResponses
        serverCounterConfig.logOperations = logOperations
        serverCounterConfig.failureMode = failureMode
        
        print("💫 ✅ Server counter updates enabled with safe defaults")
    }
    
    /// **SAFE** method to disable server counter updates
    /// This will NEVER break anything - it just returns to the working state
    public func disableServerCounterUpdates() {
        print("💫 🔧 DISABLING server counter updates (returning to safe defaults)")
        
        serverCounterConfig.enabled = false
        serverCounterConfig.parseServerResponses = false
        
        print("💫 ✅ Server counter updates disabled - back to safe working state")
    }
    
    /// Check if server counter updates are enabled
    public var isServerCounterUpdatesEnabled: Bool {
        return serverCounterConfig.enabled
    }
    
    // MARK: - Cleanup
    
    deinit {
        Task { [weak self] in
            try? await self?.switchToLocalStorage()
        }
    }
}

// MARK: - Storage Info

public struct StorageInfo {
    public let mode: VirtualKeyStorageManager.StorageMode
    public let clientCredentialCount: Int
    public let serverCredentialCount: Int
    public let totalCredentialCount: Int
    public let mountPoint: String?
    public let isVirtualKeyMounted: Bool
    
    public var description: String {
        var info = [
            "Storage Mode: \(mode.description)",
            "Client Credentials: \(clientCredentialCount)",
            "Server Credentials: \(serverCredentialCount)",
            "Total Credentials: \(totalCredentialCount)"
        ]
        
        if let mountPoint = mountPoint {
            info.append("Mount Point: \(mountPoint)")
        }
        
        return info.joined(separator: "\n")
    }
} 
