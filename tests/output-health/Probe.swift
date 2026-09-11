import Foundation
import Synchronization

func health(of provider: any OutputHealthProviding) -> OutputHealth {
    let reply = Mutex<OutputHealth?>(nil)
    let done = DispatchSemaphore(value: 0)
    provider.requestHealth { result in reply.withLock { $0 = result }; done.signal() }
    precondition(done.wait(timeout: .now() + 2) == .success, "output health stalled")
    return reply.withLock { $0! }
}
