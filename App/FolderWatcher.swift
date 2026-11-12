import Foundation

/// Tells us when anything inside the library folder changes (books added, renamed or removed
/// on another device or in the Files app). We still rescan on launch and on returning to the
/// foreground, since change reporting for user-picked folders is not guaranteed.
final class FolderWatcher: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private let onChange: @Sendable (URL?) -> Void

    init(url: URL, onChange: @escaping @Sendable (URL?) -> Void) {
        presentedItemURL = url
        self.onChange = onChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() { NSFileCoordinator.removeFilePresenter(self) }

    deinit { NSFileCoordinator.removeFilePresenter(self) }

    func presentedItemDidChange() { onChange(nil) }
    func presentedSubitemDidChange(at url: URL) { onChange(url) }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { onChange(nil) }
    func presentedSubitemDidAppear(at url: URL) { onChange(nil) }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        onChange(nil)
        completionHandler(nil)
    }
}
