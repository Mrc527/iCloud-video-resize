import BackgroundTasks
import Foundation
import VideoResizeCore

/// Lets a job started with a button go on when the app leaves the screen (iOS 26 and later).
/// iOS shows its progress and may still end it early, for example when short of resources;
/// then the job pauses, as it always does on older systems.
@MainActor
final class BackgroundWork {
    /// The running BGContinuedProcessingTask. Typed loosely: the app also runs on iOS 17.
    private var task: AnyObject?
    private var identifier: String?
    private var title = ""
    private var subtitle = ""
    private var onStart: (() -> Void)?
    private var onExpire: (() -> Void)?

    /// True while iOS lets the job go on with the app in the background.
    var isActive: Bool { task != nil }

    func begin(title: String, subtitle: String,
               onStart: @escaping () -> Void, onExpire: @escaping () -> Void) {
        end(success: false)
        self.title = title
        self.subtitle = subtitle
        self.onStart = onStart
        self.onExpire = onExpire
        #if compiler(>=6.2)  // the iOS 26 SDK
        guard #available(iOS 26.0, *), let bundle = Bundle.main.bundleIdentifier else { return }
        // A new identifier for each job: registering one twice ends the app.
        let identifier = "\(bundle).work.\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier,
                                                         using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self else { return task.setTaskCompleted(success: false) }
                self.started(task)
            }
        }
        guard registered else { return }
        self.identifier = identifier
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title,
                                                       subtitle: subtitle)
        request.strategy = .fail  // a queued job could start after this one ended
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            self.identifier = nil  // the job runs while the app is on screen, as before
        }
        #endif
    }

    #if compiler(>=6.2)
    private func started(_ task: BGTask) {
        guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask,
              task.identifier == identifier
        else {
            task.setTaskCompleted(success: false)  // the job it was for has ended
            return
        }
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expired() }
        }
        task.progress.totalUnitCount = 1000
        task.updateTitle(title, subtitle: subtitle)
        self.task = task
        onStart?()
    }
    #endif

    private func expired() {
        guard let task = task as? BGTask else { return }
        task.setTaskCompleted(success: false)
        self.task = nil
        identifier = nil
        onExpire?()
    }

    /// `done` is the share of the whole job that is done, from 0 to 1.
    func report(_ done: Double, subtitle: String) {
        self.subtitle = subtitle
        #if compiler(>=6.2)
        guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask else { return }
        // Never backwards: a video added as it is is copied after it was checked.
        guard done.isFinite else { return }
        let value = Int64((min(max(done, 0), 1) * 1000).rounded())
        task.progress.completedUnitCount = max(task.progress.completedUnitCount, value)
        if task.subtitle != subtitle { task.updateTitle(title, subtitle: subtitle) }
        #endif
    }

    func end(success: Bool) {
        (task as? BGTask)?.setTaskCompleted(success: success)
        task = nil
        identifier = nil
        onStart = nil
        onExpire = nil
    }

    /// The share of a job of `count` videos done, while video `index` is in `phase`.
    nonisolated static func share(_ index: Int, of count: Int, _ phase: Phase,
                                  _ fraction: Double) -> Double {
        let span: (start: Double, end: Double)
        switch phase {
        case .downloading, .copying: span = (0, 0.2)
        case .encoding: span = (0.2, 0.9)
        case .verifying: span = (0.9, 0.95)
        case .importing: span = (0.95, 1)
        }
        let within = span.start + (span.end - span.start) * min(max(fraction, 0), 1)
        return (Double(index) + within) / Double(max(count, 1))
    }
}
