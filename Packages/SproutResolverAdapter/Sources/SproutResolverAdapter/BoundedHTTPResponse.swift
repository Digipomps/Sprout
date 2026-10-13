import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum BoundedHTTPResponseError: Error, Equatable {
    case responseTooLarge
    case missingResponse
}

/// Fixed, cookie-free transports. Keep these sessions alive for the process:
/// Swift 6.2 FoundationNetworking can resurrect _MultiHandle during teardown.
/// Individual tasks still complete/cancel and release their collector normally.
public enum BoundedHTTPSessions {
    public static let onboarding = makeSession(requestTimeout: 20, resourceTimeout: 45)
    public static let identityLink = makeSession(requestTimeout: 20, resourceTimeout: 30)
    static let standard = makeSession(requestTimeout: 60, resourceTimeout: 604_800)

    private static func makeSession(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: BoundedHTTPDispatcher(), delegateQueue: nil)
    }
}

extension URLSession {
    /// Collect with a hard limit while receiving, not after an unbounded data task completes.
    func boundedData(for request: URLRequest, maximumBytes: Int = 1_048_576) async throws -> (Data, URLResponse) {
        precondition(maximumBytes > 0)
        let cancellation = HTTPTaskCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                // Default and named production sessions use a finite reusable pool.
                // Explicitly injected configurations retain their isolated behavior;
                // custom URLProtocol tests must never enter the production session.
                let reusable = self === URLSession.shared ? BoundedHTTPSessions.standard : self
                if let dispatcher = reusable.delegate as? BoundedHTTPDispatcher {
                    let collector = BoundedHTTPCollector(maximumBytes: maximumBytes, continuation: continuation,
                                                         invalidateSessionOnCompletion: false)
                    let task = reusable.dataTask(with: request)
                    dispatcher.install(collector, for: task)
                    cancellation.install(task)
                    task.resume()
                    return
                }
                let collector = BoundedHTTPCollector(maximumBytes: maximumBytes, continuation: continuation)
                let configuration = self.configuration
                configuration.httpShouldSetCookies = false
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
                let task = session.dataTask(with: request)
                cancellation.install(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// FoundationNetworking selects the session delegate for streaming data (not
/// URLSessionTask.delegate). Installation can race delegate callbacks, so protect
/// the routing map separately from each collector's serial delegate-queue state.
private final class BoundedHTTPDispatcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var collectors: [Int: BoundedHTTPCollector] = [:]

    func install(_ collector: BoundedHTTPCollector, for task: URLSessionTask) {
        lock.lock()
        collectors[task.taskIdentifier] = collector
        lock.unlock()
    }

    private func collector(for task: URLSessionTask, remove: Bool = false) -> BoundedHTTPCollector? {
        lock.lock()
        defer { lock.unlock() }
        return remove ? collectors.removeValue(forKey: task.taskIdentifier) : collectors[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let collector = collector(for: dataTask) else {
            dataTask.cancel()
            completionHandler(.cancel)
            return
        }
        collector.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        collector(for: dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        collector(for: task, remove: true)?.urlSession(session, task: task, didCompleteWithError: error)
    }
}

private final class HTTPTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func install(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

/// All mutable collector state is confined to URLSession's serial delegate queue.
final class BoundedHTTPCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let continuation: CheckedContinuation<(Data, URLResponse), any Error>
    private var data = Data()
    private var response: URLResponse?
    private var failure: BoundedHTTPResponseError?
    private let invalidateSessionOnCompletion: Bool

    init(maximumBytes: Int, continuation: CheckedContinuation<(Data, URLResponse), any Error>,
         invalidateSessionOnCompletion: Bool = true) {
        self.maximumBytes = maximumBytes
        self.continuation = continuation
        self.invalidateSessionOnCompletion = invalidateSessionOnCompletion
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard response.expectedContentLength <= maximumBytes else {
            failure = .responseTooLarge
            // swift-corelibs-foundation 6.2 ignores ResponseDisposition.cancel.
            // Cancel the task too so a declared oversized body is not downloaded.
            dataTask.cancel()
            completionHandler(.cancel)
            return
        }
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard data.count <= maximumBytes - self.data.count else {
            failure = .responseTooLarge
            dataTask.cancel()
            return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        defer { if invalidateSessionOnCompletion { session.finishTasksAndInvalidate() } }
        if let failure { continuation.resume(throwing: failure) }
        else if let error { continuation.resume(throwing: error) }
        else if let response { continuation.resume(returning: (data, response)) }
        else { continuation.resume(throwing: BoundedHTTPResponseError.missingResponse) }
    }
}
