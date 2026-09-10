import AppKit

/// Drives the same destination callbacks AppKit sends, without synthesizing OS input.
final class SlotDraggingInfo: NSObject, NSDraggingInfo {
    let draggingSource: Any?
    let draggingPasteboard: NSPasteboard
    var draggingLocation: NSPoint
    var draggingDestinationWindow: NSWindow? { (draggingSource as? NSView)?.window }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(source: NSView, pasteboard: NSPasteboard, location: NSPoint) {
        draggingSource = source
        draggingPasteboard = pasteboard
        draggingLocation = location
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
