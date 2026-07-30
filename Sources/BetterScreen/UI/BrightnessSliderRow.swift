import AppKit

/// A menu row with a display name, a live brightness slider and a percentage.
///
/// Dragging the slider is treated as an explicit statement of preference, so it
/// feeds the calibration learner -- but only on mouse-up, otherwise every
/// intermediate value during a drag would be recorded.
final class BrightnessSliderRow: NSView {
    private let label = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()

    private let displayKey: String
    private var onChange: ((Double, Bool) -> Void)?

    init(displayKey: String, title: String, subtitle: String, value: Double, onChange: @escaping (Double, Bool) -> Void) {
        self.displayKey = displayKey
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 48))

        label.stringValue = title
        label.font = .menuFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .menuFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = value
        slider.target = self
        slider.action = #selector(sliderChanged)
        // Continuous updates so the display tracks the drag, with the final value
        // distinguished via NSEvent below.
        slider.isContinuous = true
        slider.controlSize = .small

        for view in [label, subtitleLabel, valueLabel, slider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            subtitleLabel.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            subtitleLabel.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),

            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueLabel.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 40),

            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
        ])

        updateValueLabel(value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    var value: Double {
        get { slider.doubleValue }
        set {
            slider.doubleValue = newValue
            updateValueLabel(newValue)
        }
    }

    @objc private func sliderChanged() {
        let value = slider.doubleValue
        updateValueLabel(value)
        // .leftMouseUp marks the end of the drag: only then is the value the user's
        // actual choice rather than a waypoint.
        let isFinal = NSEvent.pressedMouseButtons == 0
        onChange?(value, isFinal)
    }

    private func updateValueLabel(_ value: Double) {
        valueLabel.stringValue = "\(Int((value * 100).rounded()))%"
    }
}
