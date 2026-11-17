# MacCommander Plan 5: Persistent Network Shares Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Network shares behave like Explorer's mapped drives.
- Connecting with ⌘K saves a share permanently in the sidebar's Network section. Each share always shows one of three states:
  - 🟢 Connected
  - ⚪ Available, with a key badge when sign-in is needed
  - 🔴 Unreachable
- Shares reconnect automatically when the network changes (office ↔ home).
- Active Directory logins work with Kerberos tickets or with `DOMAIN\user` plus a password. A NAS works with a saved username and password.
- A dropped share shows "Disconnected" with a Reconnect button instead of an error.
- An unreachable server never freezes the app.

**Architecture:**
- **Core** owns the share model and the whole state machine (`ShareManager`). It talks to the system only through four small protocols:
  - mounter
  - reachability prober
  - mounted-volume lister
  - credential store

  That keeps every rule unit-testable with fakes.
- **System adapters** implement those protocols:
  - NetFS: `NetFSMountURLAsync` with `kNAUIOptionNoUI` and guest options
  - Network.framework: `NWConnection` TCP probe and `NWPathMonitor`
  - `FileManager.mountedVolumeURLs` with `.volumeURLForRemountingKey`
  - Keychain internet passwords, in the same format Finder uses, so Finder's saved passwords are reused
- **The UI** adds:
  - the Network sidebar section
  - the Connect to Server sheet (⌘K), sign-in sheet and edit sheet
  - the "Remember this share?" prompt
  - a Disconnected placeholder in the list
- **First task:** before any of that, move the remaining main-thread file-system calls off the main thread, so a dead server can't block the UI (spec §4).

**Tech Stack:** Swift 6, SwiftUI, AppKit, NetFS, Network.framework, Security (Keychain), Swift Testing, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-11-17-maccommander-design.md`: §2.2.6 (persistent network shares), §2.1 (⌘K, Network sidebar), §7 ("Network shares", "Folder watching"), and §4 ("Unreachable network paths must never block the UI", "A saved network share disappears or needs re-adding after a network change").

### Roadmap position
Plan 5 of 6. Plans 1–4 are done. Next is Plan 6: tags, search, iCloud, Settings (including the share list in Settings), and the icon.

## Global Constraints
- **Toolchain:** macOS 15, Swift 6, CLT only.
  - Run tests with `scripts/test.sh` and use Swift Testing.
  - Don't use the `@State`/`@Entry` macros. Use `State<T>` properties and hand-written keys, as the existing code does.
  - AppKit subclass trap: never call an NSObject convenience initializer from a Swift subclass that lacks `init()`.
- **Main thread:** no file-system access touching a path that might be on a network volume. That covers `stat`, `resourceValues`, `fileExists`, `icon(forFile:)`, `ArchivePath.split` and directory listing. Run these `@concurrent` or in an actor. Local-only cheap calls are still forbidden when the path could be remote, so treat every path as possibly remote.
- **Supported URL schemes:** `smb`, `afp`, `nfs`, `https`, `http` (WebDAV). Probe ports: smb 445, afp 548, nfs 2049, https 443, http 80. An explicit port in the URL overrides the default.
- **Persistence:** the share list is JSON at `~/Library/Application Support/MacCommander/shares.json`.
  - Written atomically.
  - Decoded leniently per field; a corrupt file is moved aside to `shares.json.corrupt-<timestamp>` and the app starts empty. It is never silently overwritten.
  - Passwords are **never** stored in the JSON. They go in the Keychain, and only when the user ticks "Remember in Keychain".
- **Keychain item format:** `kSecClassInternetPassword` with:
  - `kSecAttrServer` = host
  - `kSecAttrProtocol` = smb/afp/nfs/https/http (`kSecAttrProtocolSMB`, …)
  - `kSecAttrAccount` = username, exactly as typed (`DOMAIN\user` or `user@domain` allowed)
  - `kSecAttrPath` = "/" + share name (for smb/afp)
  - label = `"<host>"`
- **Reachability:**
  - Rechecked on launch, on every `NWPathMonitor` path change, and every **60 s** while any share is unreachable.
  - A probe is a TCP connect with a **3 s** timeout.
  - The timer is suspended while nothing is unreachable.
- **Auto-reconnect** is a per-share setting, on by default. An Available share with auto-reconnect is mounted automatically, without UI.
  - Missing or rejected credentials skip the share quietly and set `needsSignIn`.
  - At most one mount attempt per share runs at a time.
  - After an auth failure, auto-reconnect is not retried for that share until the user signs in or edits it.
- **Mounting:** always uses `kNAUIOptionNoUI`. The system never shows its own dialog.
- **Copy strings** (exact):
  - `“<name>” can’t be reached from this network.` with buttons Retry and Cancel
  - `Remember this share?` with informative text `MacCommander can keep “<name>” in the sidebar and reconnect it automatically.` and buttons Remember and Not Now
  - `Disconnected`, `Reconnect`, `Sign In…`, `Connect as Guest`, `Remember in Keychain`, `Connect to Server…`
- UI strings are in English, through `String(localized:)`. Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Work on `main`; no worktrees.

## Review Focus
1. **A server that disappears while mounted** (office ↔ home switch, sleep) must not freeze any window. The current folder on that share shows `Disconnected` with Reconnect, and the sidebar shows 🔴 within one probe cycle. Pinned in Tasks 1, 3 and 6.
2. **A saved share must survive everything except "Remove":** network changes, failed mounts, unmounts from Finder, app relaunch, and a corrupt `shares.json`. Pinned in Tasks 2 and 3.
3. **Credentials:**
   - No password in JSON or in logs.
   - A rejected password never loops, and auto-reconnect stops after an auth failure.
   - A domain user (`CORP\daniel`) round-trips to the Keychain unchanged.

   Pinned in Tasks 3 and 4.
4. **Two shares on one server, a share mounted twice, or a mount point renamed (`share-1`)** still map to the right saved share: matching is by normalized URL, not by mount path. Pinned in Tasks 2 and 3.
5. **Rapid network flapping** (Wi-Fi on/off) never starts concurrent mounts of the same share, never shows stale states, and doesn't build up timers. Pinned in Task 3.

---

## File Structure

```
Sources/MacCommanderCore/
  FileSystem/PathQueries.swift              off-main exists/isDirectory/archive-split helpers (Task 1)
  Browser/BrowserModel.swift                no main-thread stats (Task 1); disconnected state (Task 6)
  Sidebar/FavoritesStore.swift, VolumeProvider.swift   off-main (Task 1)
  Shares/ShareURL.swift                     normalize, match, port, display name (Task 2)
  Shares/SavedShare.swift                   model + AuthMethod (Task 2)
  Shares/ShareStore.swift                   JSON persistence (Task 2)
  Shares/ShareSystem.swift                  protocols: ShareMounter, ReachabilityProber, MountedVolumeLister, CredentialStore (Task 3)
  Shares/ShareManager.swift                 @MainActor @Observable state machine (Task 3)
  Shares/NetFSMounter.swift                 NetFS adapter + error mapping (Task 4)
  Shares/TCPReachabilityProber.swift        NWConnection probe (Task 4)
  Shares/SystemVolumeLister.swift           mountedVolumeURLs + remount URLs (Task 4)
  Shares/KeychainCredentialStore.swift      internet passwords (Task 4)
  Shares/NetworkMonitor.swift               NWPathMonitor + NSWorkspace mount/unmount → manager (Task 4)
Sources/MacCommander/
  FileList/*, Browser/PathBar.swift, Browser/GoToFolderSheet.swift, Browser/BrowserWindow.swift  off-main + ⌘R (Task 1)
  Sidebar/SidebarView.swift, Sidebar/NetworkSection.swift   (Task 5)
  Shares/ConnectToServerSheet.swift, SignInSheet.swift, EditShareSheet.swift  (Tasks 5, 7)
  App/MacCommanderApp.swift, App/BrowserCommands.swift      ⌘K, manager wiring (Task 5)
Tests/MacCommanderCoreTests/
  PathQueriesTests, BrowserModelTests (+network), ShareURLTests, ShareStoreTests, ShareManagerTests,
  ShareAdaptersTests, BrowserModelShareTests
```

---

### Task 1: Never block on network paths

**Files:**
- Create: `Sources/MacCommanderCore/FileSystem/PathQueries.swift`, `Tests/MacCommanderCoreTests/PathQueriesTests.swift`.
- Modify Core: `Browser/BrowserModel.swift`, `Sidebar/FavoritesStore.swift`, `Sidebar/VolumeProvider.swift`.
- Modify UI (main-thread call sites): `FileList/FileCellViews.swift`, `FileList/FileListController+Outline.swift`, `Browser/PathBar.swift`, `Browser/GoToFolderSheet.swift`, `Browser/BrowserWindow.swift`, `Sidebar/SidebarView.swift`, `Info/InfoWindow.swift`, `Preview/PreviewController.swift`, `Operations/OpenWithMenu.swift`, `App/BrowserCommands.swift`.

**Interfaces:**
```swift
public struct PathInfo: Sendable, Equatable { public let exists: Bool; public let isDirectory: Bool; public let isPackage: Bool; public let isRegularFile: Bool; public let isLocalVolume: Bool }
public enum PathQueries {
    @concurrent public static func info(_ url: URL) async -> PathInfo          // one stat/resourceValues call, off main
    @concurrent public static func archiveLocation(_ url: URL) async -> ArchiveLocation?   // ArchivePath.split off main
    @concurrent public static func nearestExistingFolder(_ url: URL) async -> URL         // PathUtilities.nearestExistingAncestor off main
}
```
**Rules:**
- Every main-actor file-system call in `BrowserModel` becomes an `await` of these helpers. This covers `navigate`, `load`'s existence and split checks, `open`, `reveal`, `children`, the write guards, `isCurrentDirectory`'s `resolvingSymlinksInPath`, and `pruneSelection`'s `fileExists`.
  - Selection pruning: drop the `fileExists` check for descendants. Keep entries that are under the current folder. A later action on a vanished entry fails with a readable error.
  - `isCurrentDirectory`: compare standardized paths. When a symlink-resolved comparison is truly needed, compare against canonical paths computed once per load, off main, and stored with the listing.
- **UI:**
  - Icons load off main; a placeholder from the UTType is shown until the real icon arrives.
  - The path bar's names and icons, the Go to Folder validation, the window restore check, the sidebar favorite existence check (FavoritesStore resolves `exists` off main and publishes it), the Info window, the preview header and Open With all go through async helpers or detached tasks.
- **Refresh:** add **View ▸ Refresh** with ⌘R (calls `model.reload()`). A window becoming key also reloads, but only when the current folder is on a non-local volume (`PathInfo.isLocalVolume == false`; spec §7 "refresh on focus").
- **Timeouts:** `PathQueries` calls don't time out themselves. A hung `stat` sits on a background thread while the UI stays responsive and shows the existing loading spinner, because each load's generation supersedes the stuck one.

- [ ] **Step 1: Write the failing tests.**
  - `pathInfoBasics`:
    - a folder gives `isDirectory`;
    - a file gives `isRegularFile`;
    - a missing path gives `exists == false`;
    - a `.app` bundle gives `isPackage`;
    - `/` gives `isLocalVolume == true`.
  - `browserModelNeverStatsOnMainActor`:
    - inject a `DirectoryLoader` and a new `PathQueriesProvider` test hook (an internal protocol on BrowserModel, with `PathQueries` as the default), with a fake that blocks for 1 s.
    - Start `navigate(to:)`. While it's pending, a `@MainActor` task that increments a counter every 10 ms must reach at least 50 within the second.
  - `selectionPruningKeepsDescendantsWithoutStat`
  - Existing BrowserModel and archive tests stay green.
- [ ] **Step 2: Run** `scripts/test.sh --filter "PathQueries|BrowserModel"`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement** Core first, then the UI call sites. List every UI call site you changed in the report.
- [ ] **Step 4: Run** `scripts/test.sh`, then `scripts/build-app.sh`. Expected: PASS. Afterwards, `grep -rn "fileExists\|resourceValues\|icon(forFile\|attributesOfItem" Sources/MacCommander` must show only calls inside `@concurrent`/detached/actor contexts. Record that grep output in the report.
- [ ] **Step 5: Manual check.** Connect any SMB share in Finder, open it in MacCommander, then turn Wi-Fi off. The app stays responsive: menus open and other windows scroll.
- [ ] **Step 6: Commit** `fix: keep file-system calls off the main thread; ⌘R refresh`

---

### Task 2: Share URLs, model and store

**Files:**
- Create in `Sources/MacCommanderCore/Shares/`: `ShareURL.swift`, `SavedShare.swift`, `ShareStore.swift`.
- Tests: `ShareURLTests.swift`, `ShareStoreTests.swift`.

**Interfaces:**
```swift
public struct ShareURL: Hashable, Sendable, Codable {
    public let scheme: String          // lowercase: smb|afp|nfs|https|http
    public let host: String            // lowercase, IDNA as given, IPv6 without brackets
    public let port: Int?              // explicit only
    public let path: String            // "/Share/Sub" — leading "/", no trailing "/", percent-decoded
    /// nil for unsupported schemes, missing host, or (smb/afp) missing share name. Strips user/password/query/fragment.
    public init?(_ string: String)     // accepts "smb://host/share", "host/share" (→ smb), "\\host\share" (→ smb)
    public init?(remountURL: URL)
    public var url: URL                // canonical, without credentials
    public var probePort: Int          // explicit or scheme default (445/548/2049/443/80)
    public var shareName: String       // first path component (or host for nfs root)
    public var displayName: String     // "<share> on <host>"
    public func matches(_ other: ShareURL) -> Bool   // same scheme, host, effective port, and path equal ignoring case for smb/afp
}
public enum AuthMethod: String, Codable, Sendable { case automatic, password, guest }   // automatic = Kerberos ticket / existing Keychain
public struct SavedShare: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var url: ShareURL
    public var name: String            // user-editable display name, default url.displayName
    public var username: String?       // as typed; nil = none
    public var lastAuth: AuthMethod    // default .automatic
    public var autoReconnect: Bool     // default true
    public var lastMountPath: String?  // last seen mount point, for reconnecting into the same subfolder
}
@MainActor @Observable public final class ShareStore {
    public init(fileURL: URL = ShareStore.defaultURL)
    public static var defaultURL: URL  // ~/Library/Application Support/MacCommander/shares.json
    public private(set) var shares: [SavedShare]
    public private(set) var declinedRemountURLs: Set<ShareURL>   // "Not Now" answers, persisted in the same file
    public func add(_ url: ShareURL, username: String?) -> SavedShare   // existing match → returns it, no duplicate
    public func update(_ share: SavedShare)
    public func remove(_ id: UUID)
    public func share(matching url: ShareURL) -> SavedShare?
    public func decline(_ url: ShareURL)
}
```
- **File format:** `{"version":1,"shares":[…],"declined":[…]}`.
- **Writes:** off main (`@concurrent`), atomic, and serialized. The last write wins.
- **Loading:** the file is loaded on init, synchronously. It's a local file in Application Support, so a synchronous read there is allowed.

- [ ] **Step 1: Write the failing tests:**
  - `parsesForms`: `smb://NAS.local/Media` gives host `nas.local`, path `/Media`, share name `Media`. `smb://user:pw@nas/Media/sub/` strips the credentials and the trailing slash, giving `/Media/sub`. `\\fs01\Public` gives `smb://fs01/Public`. `nas/Media` gives `smb`. `https://dav.example.com/remote.php/dav` is valid.
  - `rejectsInvalid`: `ftp://x/y`, `smb://`, `smb://host` (no share), and an empty string all give nil.
  - `percentAndSpaces`: `smb://nas/My%20Files` gives the path `/My Files`, and `url` round-trips.
  - `matching`:
    - `smb://NAS/media` matches `smb://nas/Media`, case-insensitively for smb.
    - It doesn't match `afp://nas/Media`.
    - It doesn't match `smb://nas:4450/Media`, because the effective ports differ.
    - With `remountURL: URL(string: "smb://daniel@nas._smb._tcp.local/Media")`, the user is stripped and the host stays as given.
  - `probePorts`: smb 445, afp 548, nfs 2049, https 443, http 80, and an explicit `:8443` wins.
  - `storeRoundTrip`: add two shares, create a new store from the same file, and both are present with every field.
  - `addDeduplicates`
  - `corruptFileMovedAside`: writing `{nope` gives an empty store, `shares.json.corrupt-*` exists, and the next save writes a valid file.
  - `lenientFields`: a share entry without `autoReconnect` decodes as `true`, and an unknown `lastAuth` decodes as `.automatic`.
  - `noPasswordInFile`: after `add` with a username, the file's bytes contain the username but not the string `password`.
- [ ] **Step 2: Run** `scripts/test.sh --filter "ShareURL|ShareStore"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): saved network shares with normalized URLs and JSON store`

---

### Task 3: `ShareManager`, the state machine

**Files:**
- Create: `Sources/MacCommanderCore/Shares/ShareSystem.swift`, `Sources/MacCommanderCore/Shares/ShareManager.swift`.
- Test: `Tests/MacCommanderCoreTests/ShareManagerTests.swift`.

**Interfaces:**
```swift
public struct ShareCredentials: Sendable, Equatable { public var username: String?; public var password: String?; public var guest: Bool }
public enum MountError: Error, Equatable, Sendable { case authenticationFailed, unreachable, cancelled, failed(String) }
public protocol ShareMounter: Sendable {
    func mount(_ url: ShareURL, credentials: ShareCredentials) async throws(MountError) -> URL     // mount point
    func unmount(_ mountPoint: URL, force: Bool) async throws(MountError)
}
public protocol ReachabilityProber: Sendable { func isReachable(host: String, port: Int, timeout: Duration) async -> Bool }
public struct MountedShare: Sendable, Equatable { public let mountPoint: URL; public let url: ShareURL }
public protocol MountedVolumeLister: Sendable { func mountedShares() async -> [MountedShare] }
public protocol CredentialStore: Sendable {
    func password(for url: ShareURL, username: String) async -> String?
    func save(password: String, for url: ShareURL, username: String) async throws
    func delete(for url: ShareURL, username: String) async
}
public enum ShareStatus: Equatable, Sendable {
    case checking
    case connected(mountPoint: URL)
    case available(needsSignIn: Bool)
    case unreachable
}
public enum ConnectOutcome: Equatable, Sendable { case connected(URL), needsSignIn, unreachable, failed(String) }
@MainActor @Observable public final class ShareManager {
    public init(store: ShareStore, mounter: any ShareMounter, prober: any ReachabilityProber,
                volumes: any MountedVolumeLister, credentials: any CredentialStore, clock: any Clock<Duration> = ContinuousClock())
    public private(set) var status: [UUID: ShareStatus]
    public private(set) var rememberPrompts: [MountedShare]      // external mounts not saved and not declined
    public func start()                                           // initial refresh + 60 s timer management
    public func refreshAll() async                                // probe + match mounts for every share; auto-reconnect
    public func networkChanged() async                            // = refreshAll (coalesced: at most one refresh in flight + one queued)
    public func volumesChanged() async                            // mount/unmount notification: re-match mounts only, no probes
    public func connect(_ id: UUID) async -> ConnectOutcome       // user click / Connect
    public func signIn(_ id: UUID, username: String, password: String, remember: Bool) async -> ConnectOutcome
    public func connectAsGuest(_ id: UUID) async -> ConnectOutcome
    public func disconnect(_ id: UUID) async throws(MountError)   // unmount (force if unreachable)
    public func addAndConnect(_ url: ShareURL) async -> (SavedShare, ConnectOutcome)   // ⌘K
    public func remember(_ mounted: MountedShare)                 // "Remember" answer
    public func decline(_ mounted: MountedShare)                  // "Not Now" answer
    public func remove(_ id: UUID) async                          // removes from store; Keychain item kept (user may still use it in Finder)
    public func mountPoint(containing url: URL) -> (share: SavedShare, mountPoint: URL)?   // pure lookup over current statuses/lastMountPath
}
```

**State rules** (the tests pin each one):
- **Classification:**
  - A share found among `mountedShares()` by `ShareURL.matches` is `.connected`. Store `lastMountPath`.
  - Otherwise a reachable share is `.available(needsSignIn: <flag>)`.
  - Otherwise it's `.unreachable`.
  - A share that's mounted but whose server is unreachable is reported as `.unreachable`, and its mount point is kept for Disconnect (force).
- **Credential order in `connect` and auto-reconnect:**
  - Try `lastAuth` first, then `.automatic` if `lastAuth` wasn't automatic.
  - `.password` uses `credentials.password(for:username:)`. If nothing is stored, skip it.
  - `.guest` uses `guest: true`.
  - `.automatic` uses nil credentials.
  - After success, set `lastAuth` to the method that worked.
- **Auth failure:**
  - `authenticationFailed` on every method sets `needsSignIn = true`, and `connect` returns `.needsSignIn`.
  - Auto-reconnect skips shares with `needsSignIn` until `signIn`, `connectAsGuest` or an edit clears the flag.
- **Sign-in:**
  - `signIn` tries the given credentials once.
  - On success: if `remember`, call `credentials.save`; set `lastAuth = .password` if remembered, otherwise keep `.automatic`; and store `username`.
  - On `authenticationFailed`, return `.needsSignIn` and don't save anything.
- **One attempt at a time:** at most one mount per share is in flight. A second `connect` while one is running awaits the same attempt.
- **Timer:** the 60 s timer runs only while at least one share is `.unreachable`. Re-arming never stacks timers.
- **External mounts:** `volumesChanged` and `refreshAll` add mounted shares that aren't saved and aren't declined to `rememberPrompts` once. A share appears there at most once per app session.
- **`networkChanged`:** coalesced. If a refresh is in flight, at most one more is queued.

- [ ] **Step 1: Write the failing tests** with fakes: a scripted mounter that records its calls, a prober with a settable reachability per host, a volume lister with settable mounts, an in-memory credential store, and a test clock (`ContinuousClock` replaced with a manual clock, or tiny real durations if a manual clock is impractical).
  - `classifiesConnectedAvailableUnreachable`
  - `matchesMountedShareByURLNotPath`: the mount point is `/Volumes/Media-1`.
  - `autoReconnectMountsAvailableShares`: only shares with `autoReconnect` are mounted, and the order is `lastAuth` first.
  - `authFailureSetsNeedsSignInAndStopsRetrying`: after a failure, `refreshAll` twice makes no new mount calls.
  - `signInSavesOnlyWhenRemembered`: with `remember: false`, nothing is saved; with `true`, the item is saved with the username `CORP\daniel` unchanged; a wrong password saves nothing.
  - `guestPath`
  - `concurrentConnectsShareOneAttempt`: two `connect` calls make one mounter call.
  - `unreachableTimerOnlyWhileNeeded`: after the server becomes reachable, no further probes happen after 60 s.
  - `networkFlappingCoalesces`: ten `networkChanged()` calls in a row make at most 2 refresh passes.
  - `externalMountPromptsOnceAndRespectsDecline`
  - `removeKeepsKeychain`
  - `mountedButServerGoneIsUnreachableAndForceUnmounts`
- [ ] **Step 2: Run** `scripts/test.sh --filter ShareManager`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: PASS. Run the filter 3 times to check it isn't flaky.
- [ ] **Step 5: Commit** `feat(core): share manager with reachability, auto-reconnect and sign-in rules`

---

### Task 4: System adapters

**Files:**
- Create in `Sources/MacCommanderCore/Shares/`: `NetFSMounter.swift`, `TCPReachabilityProber.swift`, `SystemVolumeLister.swift`, `KeychainCredentialStore.swift`, `NetworkMonitor.swift`.
- Test: `Tests/MacCommanderCoreTests/ShareAdaptersTests.swift`.

**Behavior:**
- **`NetFSMounter`** (`import NetFS`):
  - Calls `NetFSMountURLAsync(url, nil, user, password, openOptions, mountOptions, queue, block)`.
  - Open options: `kNAUIOptionKey: kNAUIOptionNoUI`, and `kNetFSUseGuestKey: true` for guest.
  - Mount options: `kNetFSMountFlagsKey` stays 0, so the default mount point goes under /Volumes.
  - The callback is bridged to async with a continuation that is resumed exactly once.
  - Error mapping, in a pure `static func mapMountError(_ status: Int32) -> MountError`:
    - `EAUTH` (80), `EACCES` (13) and `-6600` (NetAuth auth error range: map −6600…−6699 as auth) give `.authenticationFailed`.
    - `ENETUNREACH` (51), `EHOSTUNREACH` (65), `ETIMEDOUT` (60), `ECONNREFUSED` (61) and `EHOSTDOWN` (64) give `.unreachable`.
    - `ECANCELED` (89) and `-128` (userCanceledErr) give `.cancelled`.
    - Anything else gives `.failed(String(cString: strerror(status)))`, or `"Error <n>"` for negative codes.
  - Unmount uses `unmount(path, force ? MNT_FORCE : 0)` off main. `EBUSY` gives `.failed("“<name>” is in use.")`.
- **`TCPReachabilityProber`:**
  - Uses `NWConnection(host:port:using: .tcp)` with the 3 s timeout.
  - `.ready` gives true; `.failed` or the timeout gives false.
  - The connection is always cancelled afterwards, and the continuation is resumed exactly once.
- **`SystemVolumeLister`:** `FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey, .volumeIsLocalKey], options: [])` runs off main. Every non-local volume with a remount URL that `ShareURL(remountURL:)` accepts becomes a `MountedShare`.
- **`KeychainCredentialStore`:**
  - Uses the Global Constraints item format, with `SecItemCopyMatching` / `SecItemAdd` / `SecItemUpdate` (update if the item exists) / `SecItemDelete`, all off main.
  - Protocol constants: smb → `kSecAttrProtocolSMB`, afp → `kSecAttrProtocolAFP`, nfs → `kSecAttrProtocolNFS`? NFS has no Keychain protocol constant, so store nothing for nfs and return nil.
  - https → `kSecAttrProtocolHTTPS`, http → `kSecAttrProtocolHTTP`.
- **`NetworkMonitor`** (`@MainActor`):
  - Owns an `NWPathMonitor` on a private queue. Path updates are debounced by 2 s, then call `manager.networkChanged()`.
  - Observes `NSWorkspace.didMountNotification` and `didUnmountNotification`, which call `manager.volumesChanged()`.
  - Also observes `NSWorkspace.didWakeNotification`, which calls `networkChanged()`.

- [ ] **Step 1: Write the failing tests:**
  - `mapsMountErrors`: the table above.
  - `proberReachesLocalListener`: start `NWListener` on a random local port, then `isReachable(127.0.0.1, port)` is true.
  - `proberRefusedPortIsFalseQuickly`: an unused port gives false in under 1 s.
  - `proberTimeoutIsBounded`: `10.255.255.1:445` gives false in under 4 s.
  - `volumeListerSeesNoLocalVolumes`: the result contains no entry for `/`.
  - `keychainRoundTrip`: runs only when the environment variable `MC_KEYCHAIN_TESTS=1` is set, because it writes to the login keychain. Otherwise it records a skip.
    - Save, read and delete a test item with server `mc-test.invalid` and username `CORP\tester`, and check the round trip.
    - Clean up in `defer`.
- [ ] **Step 2: Run** `scripts/test.sh --filter ShareAdapters`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: PASS. Then `MC_KEYCHAIN_TESTS=1 scripts/test.sh --filter keychainRoundTrip` (expected PASS), and record the output.
- [ ] **Step 5: Commit** `feat(core): NetFS, reachability, mounted-volume and Keychain adapters`

---

### Task 5: Network sidebar, ⌘K and sign-in

**Files:**
- Create: `Sources/MacCommander/Sidebar/NetworkSection.swift`, `Sources/MacCommander/Shares/ConnectToServerSheet.swift`, `Sources/MacCommander/Shares/SignInSheet.swift`.
- Modify: `Sidebar/SidebarView.swift`, `App/MacCommanderApp.swift` (one `ShareManager` and one `NetworkMonitor`, injected via `.environment`), and `App/BrowserCommands.swift` (Go ▸ Connect to Server… with ⌘K).

**Behavior:**
- **Network section.** It sits between Locations and the end. Each saved share is a row:
  - The row shows a status symbol:
    - Connected: `circle.fill` in green.
    - Available: `circle` in secondary. With `needsSignIn`, add a `key.fill` badge.
    - Unreachable: `network.slash` in red.
    - Checking: a small `ProgressView`.
  - Then the share's name.
- **Clicking a row:**
  - **Connected:** navigate the window to the mount point.
  - **Available:** call `connect`, then navigate. `.needsSignIn` opens the sign-in sheet.
  - **Unreachable:** an alert with the exact copy, plus Retry (which calls `connect`) and Cancel.
  - **`.failed(msg)`:** an alert `“<name>” couldn’t be connected: <msg>`.
- **Connect to Server sheet (⌘K):**
  - A URL field (placeholder `smb://server/share`), validated with `ShareURL(_:)` as you type. Connect stays disabled while the URL is invalid.
  - Up to 10 recent server URLs (from saved shares) as a list.
  - Connect calls `addAndConnect`. Then it navigates on success or shows the sign-in sheet.
- **Sign-in sheet:**
  - Fields:
    - Username, prefilled from the share. The hint below it reads `For a domain account use DOMAIN\name or name@domain.`
    - Password (secure).
    - A `Remember in Keychain` checkbox, off by default.
  - Buttons: Connect (default), `Connect as Guest`, Cancel.
  - A wrong password shows `The user name or password is incorrect.` inline and keeps the sheet open.
- **Remember this share? prompt:** shown for `rememberPrompts`, one at a time, as an app-modal alert using the exact copy. Remember calls `remember`; Not Now calls `decline`.
- **Context menu:** Connect, Disconnect, Edit…, Remove.
  - Connect and Disconnect are enabled per status.
  - Edit… and Remove are added in Task 7. In this task, add only Connect and Disconnect.
- **Startup:** `ShareManager.start()` runs at launch, and `NetworkMonitor` starts at the same time.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Verify.** `scripts/test.sh` passes and `scripts/build-app.sh` builds. Then, by hand, at home with the UGREEN NAS:
  1. ⌘K, `smb://<nas>/<share>`, Connect. The sign-in sheet appears. Enter the user and password with Remember on. The share mounts, the window opens it, and the sidebar shows 🟢.
  2. Quit and relaunch: the share is still there and reconnects by itself.
  3. Turn Wi-Fi off: within about 60 s the share shows 🔴 and clicking it shows the "can’t be reached" alert. Turn Wi-Fi on: it reconnects on its own.
  4. Mount a different share in Finder: MacCommander asks "Remember this share?" once.
  5. A wrong password shows the inline error. Cancel leaves the share ⚪ with the key badge.

   In the office:

  6. On a domain Mac with a Kerberos ticket (`klist` shows one), the office share mounts without any prompt.
  7. With no ticket (`kdestroy`), `CORP\user` plus a password works.
- [ ] **Step 3: Commit** `feat: Network sidebar, Connect to Server (⌘K) and sign-in`

---

### Task 6: Disconnected placeholder and reconnect in the list

**Files:**
- Modify: `Sources/MacCommanderCore/Browser/BrowserModel.swift`, `FileSystem/DirectoryLoader.swift` (`DirectoryLoadError` gains `shareDisconnected(name: String)`), and the UI's load-error view (in `FileList/FileListController.swift`) plus its wiring.
- Test: `Tests/MacCommanderCoreTests/BrowserModelShareTests.swift`.

**Interfaces:**
- `BrowserModel` gains:
  - `var shareResolver: (@MainActor (URL) -> (name: String, mountPoint: URL)?)?`, set by the UI from `ShareManager.mountPoint(containing:)`;
  - `func reconnected(oldMountPoint: URL, newMountPoint: URL) async`.
- **Behavior:**
  - **Placeholder instead of fallback:** when the current folder vanishes (unmount notification, a load failure, or `.notFound`) and `shareResolver` returns a share for it, `load()` does **not** fall back to an ancestor. It sets `loadError = .shareDisconnected(name:)` and keeps `currentURL` and the history unchanged.
  - **Message:** `.shareDisconnected` shows `Disconnected` with the detail `“<name>” is no longer connected.` and a **Reconnect** button.
  - **Reconnect:** the button calls `ShareManager.connect`. On success it calls `model.reconnected(old:new:)`, which replaces `currentURL`'s mount-point prefix with the new one (`/Volumes/Media` may come back as `/Volumes/Media-1`) and reloads. Sign-in and the unreachable alert work as in Task 5.
  - **Automatic recovery:** when a share auto-reconnects while a window shows its placeholder, the window reloads by itself. The model observes `volumesChanged` through a notification posted by `ShareManager`, `ShareManager.didConnectNotification` with `userInfo["mountPoint"]`.

- [ ] **Step 1: Write the failing tests.** Use the model with a fake resolver that maps `tmp/share` to a share named `Media`.
  - `vanishedShareFolderShowsDisconnected`: delete `tmp/share/sub` while it is shown, then reload. Expect `loadError == .shareDisconnected(name: "Media")`, `currentURL` unchanged, and `canGoBack` unchanged.
  - `nonShareFolderStillFallsBack`
  - `reconnectedRewritesMountPrefix`: `tmp/share/sub` with old `tmp/share` and new `tmp/share-1` gives `currentURL == tmp/share-1/sub`, and the items are listed.
  - `autoReconnectNotificationReloads`
- [ ] **Step 2: Run** `scripts/test.sh --filter BrowserModelShare`. Expected: FAIL.
- [ ] **Step 3: Implement** the Core change and the UI placeholder.
- [ ] **Step 4: Verify.** `scripts/test.sh` passes. By hand: open a folder on the NAS share and disconnect Wi-Fi. The list shows Disconnected and Back still works. Reconnect Wi-Fi and press Reconnect (or wait for auto-reconnect): the same folder comes back.
- [ ] **Step 5: Commit** `feat: Disconnected placeholder with Reconnect for dropped shares`

---

### Task 7: Edit, Remove and Connect as Guest

**Files:**
- Create: `Sources/MacCommander/Shares/EditShareSheet.swift`.
- Modify: `Sidebar/NetworkSection.swift`.

**Behavior:**
- **Edit…** opens a sheet with these fields:
  - URL, validated
  - Display name
  - User
  - `Reconnect automatically` (toggle)
  - `Connect as Guest`, which sets `lastAuth = .guest` and clears the user

  Saving calls `ShareStore.update`. If the URL changed, it re-classifies the share. Saving also clears `needsSignIn`.
- **Remove** asks to confirm: `Remove “<name>” from the sidebar?` with the informative text `The share stays connected until you disconnect it. Saved passwords are kept in the Keychain.` and the buttons Remove (destructive) and Cancel.
- **Disconnect** on a share whose folder is open turns open windows into the Disconnected placeholder (Task 6). It is never an error.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Verify.** `scripts/test.sh` passes and `scripts/build-app.sh` builds. Then, by hand:
  1. Edit renames the share in the sidebar and survives a relaunch.
  2. Turning off Reconnect automatically stops automatic mounting after a Wi-Fi toggle.
  3. Remove asks first. After that the share is gone from the sidebar and from `shares.json`.
- [ ] **Step 3: Commit** `feat: edit and remove saved shares`

---

## Self-review notes
- **Spec §2.2.6 coverage:**

  | Requirement | Task |
  |---|---|
  | ⌘K saves permanently | 3, 5 |
  | Password in Keychain only with Remember | 3, 4, 5 |
  | External mounts detected, ask once | 3, 5 |
  | Three states plus key badge | 3, 5 |
  | Recheck on launch, on network change and every 60 s while unreachable (TCP probe) | 3, 4 |
  | Auto-reconnect per share, on by default | 2, 3 |
  | Credential flow: Keychain, no-UI mount, key badge, sign-in sheet, guest | 3, 5, 7 |
  | AD with Kerberos, otherwise DOMAIN\user + password | 3, 4, 5 (manual check) |
  | Remembers how it last authenticated | 3 |
  | Drop while open: Disconnected + Reconnect, history kept | 6 |
  | Context menu: Connect, Disconnect, Edit…, Remove | 5, 7 |
  | Persists until Remove | 2, 3 |

- **Spec §4, unreachable paths never block the UI:** Task 1 plus Review Focus 1.
- **Spec §7:** NetFS, Network.framework path monitor plus TCP probe, Keychain, and JSON in Application Support. Folders that can't be watched refresh on focus and with ⌘R (Task 1).
- **Deferred to Plan 6:**
  - the network-share list in the Settings window (spec §2.3);
  - "Remembers how it last authenticated" reports Kerberos and an existing Keychain item together as `automatic`, because NetFS doesn't say which one it used.
- **Builder's calls:**
  - Remove keeps the Keychain item.
  - A mounted share whose server is unreachable shows 🔴 and Disconnect force-unmounts it.
  - Declined "Remember this share?" answers are stored per server URL.
  - The probe timeout is 3 s and network changes are debounced by 2 s.
