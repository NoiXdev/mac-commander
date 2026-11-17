import Foundation
import NetFS

/// Mounts shares with NetFS, never showing the system's authentication or error UI (`kNAUIOptionNoUI`). Mount
/// points are the system default under /Volumes.
public struct NetFSMounter: ShareMounter {
    public init() {}

    public func mount(_ url: ShareURL, credentials: ShareCredentials) async throws(MountError) -> URL {
        let request = MountRequest()
        let result: Result<URL, MountError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.start(url: url, credentials: credentials, continuation: continuation)
            }
        } onCancel: {
            request.cancel()
        }
        return try result.get()
    }

    public func unmount(_ mountPoint: URL, force: Bool) async throws(MountError) {
        let path = mountPoint.path
        let status: Int32 = await PathQueries.run {
            Darwin.unmount(path, force ? MNT_FORCE : 0) == 0 ? 0 : errno
        }
        switch status {
        case 0: return
        case EBUSY:
            let name = mountPoint.lastPathComponent
            throw .failed(String(localized: "“\(name)” is in use."))
        default:
            throw Self.mapMountError(status)
        }
    }

    /// Maps a NetFS / errno status to a `MountError`. Only real credential problems count as authentication
    /// failures (they stop auto-reconnect until the user signs in); NetAuth's internal and mount-failed codes
    /// (-6600, -6602) are transient. Other negative codes become "Error <n>" (with the NetFS.h name when known);
    /// positive ones use `strerror`.
    public static func mapMountError(_ status: Int32) -> MountError {
        switch status {
        case EAUTH, EACCES,
            -5045,  // ENETFSPWDNEEDSCHANGE
            -5046,  // ENETFSPWDPOLICY
            -5999,  // ENETFSACCOUNTRESTRICTED
            -6004:  // kNetAuthErrorGuestNotSupported: the user needs Sign In…
            return .authenticationFailed
        case ENETUNREACH, EHOSTUNREACH, ETIMEDOUT, ECONNREFUSED, EHOSTDOWN:
            return .unreachable
        case ECANCELED, -128:
            return .cancelled
        default:
            guard status < 0 else { return .failed(String(cString: strerror(status))) }
            if let name = negativeErrorNames[status] { return .failed("Error \(status) (\(name))") }
            return .failed("Error \(status)")
        }
    }

    private static let negativeErrorNames: [Int32: String] = [
        -6600: "kNetAuthErrorInternal",
        -6602: "kNetAuthErrorMountFailed",
    ]
}

/// One mount attempt: bridges `NetFSMountURLAsync`'s callback to a continuation that is resumed exactly once,
/// whether by the callback, a synchronous failure, or task cancellation (NetFS doesn't call the block for a
/// cancelled request, so cancellation resumes it here).
private final class MountRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<URL, MountError>, Never>?
    private var requestID: AsyncRequestID?
    private var cancelled = false
    private let queue = DispatchQueue(label: "dev.noix.MacCommander.NetFSMounter")

    func start(url: ShareURL, credentials: ShareCredentials,
               continuation: CheckedContinuation<Result<URL, MountError>, Never>) {
        let alreadyCancelled = lock.withLock {
            self.continuation = continuation
            return cancelled
        }
        if alreadyCancelled {
            finish(.failure(.cancelled))
            return
        }

        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
        if credentials.guest { openOptions[kNetFSUseGuestKey] = true }
        // A guest mount never sends a user or password, whatever the credentials carry.
        let user = credentials.guest ? nil : credentials.username
        let password = credentials.guest ? nil : credentials.password
        // kNetFSMountFlagsKey stays unset (0): the default mount point under /Volumes.
        let mountOptions = NSMutableDictionary()

        var id: AsyncRequestID?
        let status = NetFSMountURLAsync(
            url.url as CFURL, nil,
            user as CFString?, password as CFString?,
            openOptions, mountOptions, &id, queue
        ) { [self] status, _, mountpoints in
            if status != 0 {
                finish(.failure(NetFSMounter.mapMountError(status)))
            } else if let paths = mountpoints as? [String], let first = paths.first {
                finish(.success(URL(fileURLWithPath: first, isDirectory: true)))
            } else {
                finish(.failure(.failed("No mount point")))
            }
        }
        if status != 0 {
            finish(.failure(NetFSMounter.mapMountError(status)))
            return
        }
        let cancelNow: AsyncRequestID? = lock.withLock {
            requestID = id
            return cancelled ? id : nil
        }
        if let cancelNow { cancelRequest(cancelNow) }
    }

    func cancel() {
        let id: AsyncRequestID? = lock.withLock {
            cancelled = true
            return requestID
        }
        if let id { cancelRequest(id) }
    }

    private func cancelRequest(_ id: AsyncRequestID) {
        _ = NetFSMountURLCancel(id)
        finish(.failure(.cancelled))
    }

    private func finish(_ result: Result<URL, MountError>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: result)
    }
}
