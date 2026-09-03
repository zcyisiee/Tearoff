import Foundation

final class Debouncer {
    private var timer: Timer?
    private let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func call(action: @escaping () -> Void) {
        timer?.invalidate()
        let t = Timer(timeInterval: delay, repeats: false) { _ in
            action()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    var isPending: Bool {
        timer != nil
    }
}
