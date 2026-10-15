import Foundation
import NineBarCore

enum WatchlistTextParser {
    enum ParseError: Error, Equatable {
        case missingCode(line: Int)
        case unsupportedCode(line: Int)
    }

    static func parse(
        _ text: String,
        knownInstruments: [Instrument]
    ) throws -> [Instrument] {
        let lines = text.components(separatedBy: .newlines)
        let knownBySymbol = Dictionary(
            knownInstruments.map { ($0.symbol, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var parsed: [Instrument] = []
        var seen = Set<String>()

        for (offset, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let symbolRange = sixDigitSymbolRange(in: line) else {
                throw ParseError.missingCode(line: offset + 1)
            }

            let symbol = String(line[symbolRange])
            let explicitName = firstNameToken(after: symbolRange, in: line)
            let known = knownBySymbol[symbol]
            let name = explicitName ?? known?.name ?? symbol
            guard let instrument = SupportedInstrumentClassifier.instrument(
                symbol: symbol,
                name: name
            ) else {
                throw ParseError.unsupportedCode(line: offset + 1)
            }
            guard seen.insert(instrument.id).inserted else { continue }
            parsed.append(instrument)
        }

        return parsed
    }

    private static func sixDigitSymbolRange(in line: String) -> Range<String.Index>? {
        var runStart: String.Index?

        for index in line.indices {
            if isASCIIDigit(line[index]) {
                if runStart == nil { runStart = index }
                continue
            }
            if let start = runStart, line.distance(from: start, to: index) == 6 {
                return start..<index
            }
            runStart = nil
        }

        guard let start = runStart, line.distance(from: start, to: line.endIndex) == 6 else {
            return nil
        }
        return start..<line.endIndex
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else {
            return false
        }
        return (48...57).contains(value)
    }

    private static func firstNameToken(
        after symbolRange: Range<String.Index>,
        in line: String
    ) -> String? {
        let suffix = line[symbolRange.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t,，|"))
        guard let token = suffix.split(whereSeparator: { $0.isWhitespace }).first else {
            return nil
        }
        let value = String(token).trimmingCharacters(in: CharacterSet(charactersIn: ",，|"))
        guard !value.isEmpty, !value.contains("%") else { return nil }
        return value
    }

}
