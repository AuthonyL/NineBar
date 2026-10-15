import Foundation

public protocol HTTPClient: Sendable {
    func get(_ url: URL) async throws -> (Data, HTTPURLResponse)
}

public protocol Sleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct TaskSleeper: Sleeper {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MarketDataError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MarketDataError.httpStatus(http.statusCode)
        }
        return (data, http)
    }
}

public struct RetryingHTTPClient: HTTPClient {
    private let client: any HTTPClient
    private let sleeper: any Sleeper

    public init(client: any HTTPClient, sleeper: any Sleeper = TaskSleeper()) {
        self.client = client
        self.sleeper = sleeper
    }

    public func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let retryDelays: [Duration] = [.milliseconds(200), .milliseconds(800)]

        for attempt in 0...retryDelays.count {
            do {
                let result = try await client.get(url)
                guard (200..<300).contains(result.1.statusCode) else {
                    throw MarketDataError.httpStatus(result.1.statusCode)
                }
                return result
            } catch {
                if isCancellationError(error) {
                    throw CancellationError()
                }
                guard attempt < retryDelays.count, shouldRetry(error) else {
                    throw error
                }
                try await sleeper.sleep(for: retryDelays[attempt])
            }
        }

        throw MarketDataError.invalidResponse
    }

    private func shouldRetry(_ error: Error) -> Bool {
        guard !isCancellationError(error) else { return false }
        if let marketDataError = error as? MarketDataError {
            if case let .httpStatus(statusCode) = marketDataError {
                return statusCode == 429 || (500...599).contains(statusCode)
            }
            return false
        }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        return false
    }
}

func isCancellationError(_ error: Error) -> Bool {
    if error is CancellationError {
        return true
    }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain
        && nsError.code == URLError.cancelled.rawValue
}
