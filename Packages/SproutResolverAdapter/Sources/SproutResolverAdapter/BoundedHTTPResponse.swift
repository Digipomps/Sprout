import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum BoundedHTTPResponseError: Error, Equatable {
    case responseTooLarge
    case missingResponse
}

extension URLSession {
    /// Collect with a hard limit while receiving, not after an unbounded data task completes.
    func boundedData(for request: URLRequest, maximumBytes: Int = 1_048_576) async throws -> (Data, URLResponse) {
        precondition(maximumBytes > 0)
        let cancellation = HTTPTaskCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
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

    init(maximumBytes: Int, continuation: CheckedContinuation<(Data, URLResponse), any Error>) {
        self.maximumBytes = maximumBytes
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard response.expectedContentLength <= maximumBytes else {
            failure = .responseTooLarge
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
        defer { session.finishTasksAndInvalidate() }
        if let failure { continuation.resume(throwing: failure) }
        else if let error { continuation.resume(throwing: error) }
        else if let response { continuation.resume(returning: (data, response)) }
        else { continuation.resume(throwing: BoundedHTTPResponseError.missingResponse) }
    }
}
