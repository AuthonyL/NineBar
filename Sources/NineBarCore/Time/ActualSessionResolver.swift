public enum ActualSessionResolver {
    public static func resolvesClosedDay(
        requiredSeriesCount: Int,
        successfulSeriesCount: Int,
        errors: [MarketDataError]
    ) -> Bool {
        requiredSeriesCount > 0
            && successfulSeriesCount == 0
            && errors.count == requiredSeriesCount
            && errors.allSatisfy(isRecoverableMissingTradingDay)
    }

    public static func isRecoverableMissingTradingDay(_ error: MarketDataError) -> Bool {
        switch error {
        case .emptyPayload, .wrongTradingDayPayload:
            true
        default:
            false
        }
    }
}
