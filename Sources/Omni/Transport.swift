import Foundation

/// Sends one request. `completion` gets the HTTP status, or nil plus the error when no response came back.
/// May be called on any thread.
protocol Transport: AnyObject {
    func send(_ request: URLRequest, completion: @escaping (_ statusCode: Int?, _ error: Error?) -> Void)
}

final class URLSessionTransport: Transport {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    func send(_ request: URLRequest, completion: @escaping (Int?, Error?) -> Void) {
        let task = session.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse {
                completion(http.statusCode, nil)
            } else {
                completion(nil, error ?? URLError(.badServerResponse))
            }
        }
        task.resume()
    }
}

/// What to do with a batch after a send. Pure, so it's tested on its own.
enum RetryPolicy {
    enum Action: Equatable {
        /// Delivered: remove the events.
        case success
        /// The server won't ever take it (bad body / bad key): remove the events, don't retry.
        case drop
        /// Too large: send fewer events at a time.
        case split
        /// Keep the events and try again later with backoff.
        case retry
    }

    static let minBackoff: TimeInterval = 5
    static let maxBackoff: TimeInterval = 300

    /// `statusCode` nil means no response (network error, timeout).
    static func action(statusCode: Int?) -> Action {
        guard let code = statusCode else { return .retry }
        switch code {
        case 200..<300: return .success
        case 400, 401: return .drop
        case 413: return .split
        case 408, 429: return .retry
        case 500..<600: return .retry
        // Other 4xx (403, 404, 422…) won't succeed on retry either.
        case 402..<500: return .drop
        default: return .retry
        }
    }

    /// Delay before retry number `attempt` (1-based): 5 s, 10 s, 20 s … capped at 5 min.
    static func backoff(attempt: Int) -> TimeInterval {
        let exponent = Double(max(0, min(attempt - 1, 16)))
        return min(minBackoff * pow(2, exponent), maxBackoff)
    }
}
