import Foundation
@testable import NineBarCore

func fixture(_ name: String) throws -> Data {
    let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
    guard let url = Bundle.module.url(
        forResource: parts[0],
        withExtension: parts.count == 2 ? parts[1] : nil,
        subdirectory: "Fixtures"
    ) else {
        throw FixtureError.missingResource(name)
    }
    return try Data(contentsOf: url)
}

func payload(_ json: String) -> Data {
    Data(json.utf8)
}

func fixtureURL() -> URL {
    URL(string: "https://example.invalid")!
}

func sourceEpoch(_ value: TimeInterval) -> Date {
    Date(timeIntervalSince1970: value)
}

struct FixtureHTTPClient: HTTPClient {
    let data: Data
    let statusCode: Int

    init(data: Data, statusCode: Int = 200) {
        self.data = data
        self.statusCode = statusCode
    }

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (data, response)
    }
}

actor MinuteHostFallbackHTTPClient: HTTPClient {
    private let data: Data
    private let primaryStatusCode: Int?
    private var hosts: [String] = []

    init(data: Data, primaryStatusCode: Int? = nil) {
        self.data = data
        self.primaryStatusCode = primaryStatusCode
    }

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        hosts.append(url.host ?? "")
        if url.host == "push2his.eastmoney.com" {
            if let primaryStatusCode {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: primaryStatusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: [:]
                )!
                return (Data(), response)
            } else {
                throw URLError(.networkConnectionLost)
            }
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (data, response)
    }

    func requestedHosts() -> [String] {
        hosts
    }
}

actor URLRecordingHTTPClient: HTTPClient {
    private let data: Data
    private var urls: [URL] = []

    init(data: Data) {
        self.data = data
    }

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        urls.append(url)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (data, response)
    }

    func firstQueryValue(named name: String) -> String? {
        guard let url = urls.first,
              let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        return queryItems.first(where: { $0.name == name })?.value
    }
}

actor QuoteHostFallbackHTTPClient: HTTPClient {
    private let data: Data
    private var hosts: [String] = []

    init(data: Data) {
        self.data = data
    }

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        hosts.append(url.host ?? "")
        if url.host == "push2.eastmoney.com" {
            throw URLError(.networkConnectionLost)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (data, response)
    }

    func requestedHosts() -> [String] {
        hosts
    }
}

actor FailingThenSucceedingHTTPClient: HTTPClient {
    private let failuresBeforeSuccess: Int
    private(set) var attempts = 0

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        attempts += 1
        if attempts <= failuresBeforeSuccess {
            throw URLError(.networkConnectionLost)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (Data(), response)
    }
}

actor RecordingSleeper: Sleeper {
    private(set) var durations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
    }
}

actor StatusSequenceHTTPClient: HTTPClient {
    private let statusCodes: [Int]
    private(set) var attempts = 0

    init(statusCodes: [Int]) {
        self.statusCodes = statusCodes
    }

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        attempts += 1
        let index = min(attempts - 1, statusCodes.count - 1)
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCodes[index],
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (Data(), response)
    }
}

actor CancellationHTTPClient: HTTPClient {
    private(set) var attempts = 0

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        attempts += 1
        throw CancellationError()
    }
}

enum URLCancellationErrorShape: Sendable, CaseIterable {
    case urlError
    case nsError
}

actor URLCancellationHTTPClient: HTTPClient {
    private let shape: URLCancellationErrorShape
    private(set) var attempts = 0

    init(shape: URLCancellationErrorShape) {
        self.shape = shape
    }

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        attempts += 1
        switch shape {
        case .urlError:
            throw URLError(.cancelled)
        case .nsError:
            throw NSError(domain: NSURLErrorDomain, code: URLError.cancelled.rawValue)
        }
    }
}

enum TestHTTPClientError: Error, Equatable {
    case unexpected
}

actor UnexpectedErrorHTTPClient: HTTPClient {
    private(set) var attempts = 0

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        attempts += 1
        throw TestHTTPClientError.unexpected
    }
}

private enum FixtureError: Error {
    case missingResource(String)
}
