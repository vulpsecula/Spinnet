import Combine
import Foundation
import SpinnetCore

/// The visible resource-control seam. The Host reads its own registry;
/// countdown ticks never invoke a Plugin or republish its page.
final class HostActivityListModel: ObservableObject {
    @Published private(set) var rows: [HostActivity] = []
    private let activities: HostActivities?
    private let owner: PluginID
    private let scheduleTick: (@escaping () -> Void) -> (() -> Void)
    private var observation: UUID?
    private var cancelTick: (() -> Void)?
    private var visible = false
    private var available = false

    init(activities: HostActivities?, owner: PluginID,
         scheduleTick: @escaping (@escaping () -> Void) -> (() -> Void) = HostActivityListModel.schedule) {
        self.activities = activities; self.owner = owner; self.scheduleTick = scheduleTick
    }

    static func schedule(_ work: @escaping () -> Void) -> (() -> Void) {
        let timer = Timer(timeInterval: HostActivities.visibleRefreshInterval, repeats: true) { _ in work() }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    func setAvailable(_ available: Bool) { self.available = available; reconcile() }
    func setVisible(_ visible: Bool) { self.visible = visible; reconcile() }

    private func reconcile() {
        guard visible, available else {
            cancelTick?(); cancelTick = nil
            if let observation { activities?.removeChangeObserver(observation); self.observation = nil }
            return
        }
        if observation == nil {
            observation = activities?.observeChanges { [weak self] in
                DispatchQueue.main.async { self?.refresh() }
            }
        }
        refresh()
    }

    private func refresh() {
        guard visible, available else { return }
        let current = activities?.list(for: owner) ?? []
        if current != rows { rows = current }
        if current.contains(where: { $0.remainingSeconds != nil }) {
            if cancelTick == nil { cancelTick = scheduleTick { [weak self] in self?.refresh() } }
        } else { cancelTick?(); cancelTick = nil }
    }

    func stop(_ id: String) {
        guard visible, available else { return }
        activities?.stop(id, for: owner)
        refresh()
    }

    deinit {
        cancelTick?()
        if let observation { activities?.removeChangeObserver(observation) }
    }
}
