import Foundation

@MainActor
public final class RadarApplicationLifecycle {
    private weak var model: RadarViewModel?
    private var startTask: Task<Void, Never>?

    public init(model: RadarViewModel) {
        self.model = model
    }

    public func applicationDidFinishLaunching() {
        guard startTask == nil else { return }
        startTask = Task { [weak model] in
            await model?.start()
        }
    }
}
