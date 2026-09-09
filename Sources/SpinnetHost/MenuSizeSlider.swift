import AppKit
import SwiftUI

/// A narrow AppKit bridge for the Menu Size control. SwiftUI's Slider does not
/// expose the native track rectangle, so the preset labels are drawn by the
/// same view that owns the NSSlider and can use its exact track geometry.
struct MenuSizeSliderRepresentable: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onEditingChanged: (Bool) -> Void

    final class Coordinator: NSObject {
        var value: Binding<Double>
        var onEditingChanged: (Bool) -> Void

        init(value: Binding<Double>, onEditingChanged: @escaping (Bool) -> Void) {
            self.value = value
            self.onEditingChanged = onEditingChanged
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, onEditingChanged: onEditingChanged)
    }

    func makeNSView(context: Context) -> MenuSizeSliderView {
        let view = MenuSizeSliderView(value: value, range: range)
        view.onValueChanged = { value in
            context.coordinator.value.wrappedValue = value
        }
        view.onEditingChanged = { isEditing in
            context.coordinator.onEditingChanged(isEditing)
        }
        return view
    }

    func updateNSView(_ nsView: MenuSizeSliderView, context: Context) {
        context.coordinator.value = $value
        context.coordinator.onEditingChanged = onEditingChanged
        nsView.setValue(value)
    }
}

final class MenuSizeSliderView: NSView {
    private final class TrackingSlider: NSSlider {
        var onEditingChanged: ((Bool) -> Void)?

        override func mouseDown(with event: NSEvent) {
            onEditingChanged?(true)
            super.mouseDown(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            onEditingChanged?(false)
        }
    }

    static let labelHeight: CGFloat = 18
    static let sliderHeight: CGFloat = 20

    private let slider: TrackingSlider
    private let sizes = MenuAppearanceConfiguration.Size.allCases
    private let range: ClosedRange<Double>

    var onValueChanged: ((Double) -> Void)?
    var onEditingChanged: ((Bool) -> Void)? {
        didSet {
            slider.onEditingChanged = onEditingChanged
        }
    }

    init(value: Double, range: ClosedRange<Double>) {
        self.range = range
        self.slider = TrackingSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: nil,
            action: nil
        )
        super.init(frame: .zero)

        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderValueChanged(_:))
        slider.setAccessibilityLabel("Menu Size")
        slider.setAccessibilityValue("\(Int(value.rounded())) percent")
        addSubview(slider)
    }

    required init?(coder: NSCoder) {
        fatalError("MenuSizeSliderView is not decoded from a nib")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.labelHeight + Self.sliderHeight)
    }

    override func layout() {
        super.layout()
        slider.frame = NSRect(
            x: 0,
            y: Self.labelHeight,
            width: bounds.width,
            height: max(Self.sliderHeight, bounds.height - Self.labelHeight)
        )
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = nativeTrackRect
        guard track.width > 0 else { return }

        let activeSize = activeSnapPoint
        for size in sizes {
            let x = track.minX + track.width * normalizedValue(for: size.percentage)
            let tickColor = activeSize == size
                ? NSColor.controlAccentColor
                : NSColor.separatorColor.withAlphaComponent(0.72)
            tickColor.setFill()
            NSBezierPath(
                rect: NSRect(
                    x: x - 0.5,
                    y: Self.labelHeight - 5,
                    width: 1,
                    height: 5
                )
            ).fill()

            let font = NSFont.systemFont(
                ofSize: NSFont.smallSystemFontSize,
                weight: activeSize == size ? .semibold : .regular
            )
            let title = "\(size.rawValue) \(Int(size.percentage.rounded()))%"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: activeSize == size
                    ? NSColor.controlAccentColor
                    : NSColor.secondaryLabelColor
            ]
            let titleSize = (title as NSString).size(withAttributes: attributes)
            let titleX = size == sizes.last
                ? x - titleSize.width
                : x - titleSize.width / 2
            (title as NSString).draw(
                in: NSRect(
                    x: titleX,
                    y: 0,
                    width: titleSize.width,
                    height: Self.labelHeight
                ),
                withAttributes: attributes
            )
        }
    }

    /// The native track in the same NSSlider used for interaction. This is
    /// also the coordinate contract used by the preset labels and ticks.
    var nativeTrackRect: NSRect {
        let cellTrack = (slider.cell as? NSSliderCell)?.trackRect ?? slider.bounds
        return NSRect(
            x: slider.frame.minX + cellTrack.minX,
            y: slider.frame.minY + cellTrack.minY,
            width: cellTrack.width,
            height: cellTrack.height
        )
    }

    var snapPointXPositions: [CGFloat] {
        sizes.map { size in
            nativeTrackRect.minX
                + nativeTrackRect.width * normalizedValue(for: size.percentage)
        }
    }

    var activeSnapPoint: MenuAppearanceConfiguration.Size? {
        sizes.first {
            abs($0.percentage - slider.doubleValue) < 0.5
        }
    }

    func setValue(_ value: Double) {
        let clampedValue = min(max(value, range.lowerBound), range.upperBound)
        guard abs(slider.doubleValue - clampedValue) > 0.0001 else {
            needsDisplay = true
            return
        }
        slider.doubleValue = clampedValue
        slider.setAccessibilityValue("\(Int(clampedValue.rounded())) percent")
        needsDisplay = true
    }

    @objc private func sliderValueChanged(_ sender: NSSlider) {
        sender.setAccessibilityValue("\(Int(sender.doubleValue.rounded())) percent")
        onValueChanged?(sender.doubleValue)
        needsDisplay = true
    }

    private func normalizedValue(for percentage: Double) -> CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        return CGFloat(
            min(
                max(
                    (percentage - range.lowerBound) / (range.upperBound - range.lowerBound),
                    0
                ),
                1
            )
        )
    }
}
