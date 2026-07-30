import Foundation

/// Maps ambient light to a target brightness, with a learned per-light-level
/// correction on top of a base response.
///
/// ## Why the model is anchored rather than absolute
///
/// The sensor reports light *relative* to a reference point, in stops (log2), not
/// in absolute units -- see `AmbientLightSensor` for why absolute luminance cannot
/// be obtained on macOS. So the model is:
///
///     brightness(stops) = anchorBrightness + baseResponse(stops) + learned(stops)
///
/// `anchorBrightness` is the user's preferred brightness at the reference light
/// level, and `baseResponse(0) == 0` by construction. Working in stops is also
/// simply the right domain: perceived brightness is roughly logarithmic in
/// luminance, so a linear response in stops behaves far better than one in linear
/// light.
struct BrightnessCurve: Codable, Equatable {
    /// A point on the response curve.
    struct Anchor: Codable, Equatable {
        /// Stops of ambient light relative to the reference (0 = reference).
        var stops: Double
        /// Brightness change from `anchorBrightness` at that light level.
        var delta: Double
    }

    /// A remembered user correction: "at this light level, they wanted this much
    /// more or less brightness than the model predicted".
    struct Calibration: Codable, Equatable {
        var stops: Double
        /// Signed correction to the model output, not an absolute brightness.
        /// Storing a delta means changing the base response does not invalidate
        /// what has been learned.
        var delta: Double
        var recordedAt: Date
    }

    /// Preferred brightness at the reference light level, 0...1.
    ///
    /// Updated directly whenever the user adjusts brightness while ambient light is
    /// near the reference, which is what makes the whole model self-correcting.
    var anchorBrightness: Double = 0.55

    /// Base response, ascending in `stops`.
    ///
    /// Roughly 0.09 of brightness per stop near the reference, flattening at the
    /// extremes. Chosen so a typical dim-room-to-daylight swing (~5 stops) moves
    /// brightness about 40 points, and deliberately conservative: under-reacting is
    /// far less irritating than over-reacting, and the learner corrects it.
    var response: [Anchor] = [
        Anchor(stops: -8, delta: -0.50),
        Anchor(stops: -5, delta: -0.38),
        Anchor(stops: -3, delta: -0.26),
        Anchor(stops: -1, delta: -0.09),
        Anchor(stops: 0, delta: 0.00),
        Anchor(stops: 1, delta: 0.09),
        Anchor(stops: 3, delta: 0.26),
        Anchor(stops: 5, delta: 0.38),
        Anchor(stops: 8, delta: 0.50),
    ]

    var calibrations: [Calibration] = []

    /// Hard clamps, so auto-brightness can never render a display unusable.
    var minBrightness: Double = 0.05
    var maxBrightness: Double = 1.0

    // MARK: - Tuning

    /// Width of the learning kernel, in stops.
    ///
    /// Too narrow and a correction only applies in the exact light it was made in;
    /// too wide and a correction made in a dark room bleeds into daylight.
    private static let kernelWidth = 1.5

    /// Corrections closer together than this are treated as the same lighting
    /// condition and merged, so repeatedly nudging brightness in one room converges
    /// instead of accumulating duplicates.
    private static let mergeDistance = 0.6

    /// Within this many stops of the reference, an adjustment is taken to mean
    /// "change my baseline preference" rather than "change the response curve".
    private static let anchorZone = 0.75

    private static let maxCalibrations = 48

    // MARK: - Evaluation

    /// Target brightness for a light level expressed in stops from the reference.
    func brightness(atStops stops: Double) -> Double {
        let value = anchorBrightness + baseResponse(atStops: stops) + learnedOffset(atStops: stops)
        return min(max(value, minBrightness), maxBrightness)
    }

    /// The model without any learned correction, for showing calibration's effect.
    func baseBrightness(atStops stops: Double) -> Double {
        min(max(anchorBrightness + baseResponse(atStops: stops), minBrightness), maxBrightness)
    }

    /// Piecewise-linear interpolation, flat outside the anchor range.
    private func baseResponse(atStops stops: Double) -> Double {
        guard let first = response.first, let last = response.last else { return 0 }
        if stops <= first.stops { return first.delta }
        if stops >= last.stops { return last.delta }

        for index in 1 ..< response.count {
            let lower = response[index - 1]
            let upper = response[index]
            guard stops <= upper.stops else { continue }
            let span = upper.stops - lower.stops
            guard span > 0 else { return upper.delta }
            let t = (stops - lower.stops) / span
            return lower.delta + t * (upper.delta - lower.delta)
        }
        return last.delta
    }

    /// Gaussian-weighted average of nearby corrections.
    ///
    /// Deliberately not a plain average over all samples: weighting by distance in
    /// stops is exactly what makes this a per-light-level correction rather than one
    /// global offset.
    private func learnedOffset(atStops stops: Double) -> Double {
        guard !calibrations.isEmpty else { return 0 }

        var weightedSum = 0.0
        var weightTotal = 0.0
        let denominator = 2 * Self.kernelWidth * Self.kernelWidth

        for sample in calibrations {
            let distance = stops - sample.stops
            let weight = exp(-(distance * distance) / denominator)
            // Drop negligible contributions, so a distant correction cannot drag the
            // result toward zero.
            guard weight > 0.01 else { continue }
            weightedSum += weight * sample.delta
            weightTotal += weight
        }

        guard weightTotal > 0 else { return 0 }
        return weightedSum / weightTotal
    }

    // MARK: - Learning

    /// Records that the user chose `chosenBrightness` at `stops` of ambient light.
    ///
    /// Only call for deliberate manual adjustments: feeding the app's own output
    /// back in would make the curve drift toward whatever it already did.
    mutating func learn(stops: Double, chosenBrightness: Double) {
        // Near the reference, treat the adjustment as a new baseline preference.
        // Otherwise every session would start from a stale anchor and need the same
        // correction again.
        if abs(stops) <= Self.anchorZone {
            let previous = anchorBrightness
            anchorBrightness = min(max(chosenBrightness - baseResponse(atStops: stops), 0), 1)
            Log.control.info(String(
                format: "Re-anchored: %.3f -> %.3f (adjustment at %+.2f stops)",
                previous, anchorBrightness, stops
            ))
            return
        }

        let delta = chosenBrightness - baseBrightness(atStops: stops)

        if let index = calibrations.firstIndex(where: { abs($0.stops - stops) < Self.mergeDistance }) {
            // Same lighting condition: move toward the new preference rather than
            // appending, so the latest intent dominates without discarding history.
            let blend = 0.6
            calibrations[index].delta = calibrations[index].delta * (1 - blend) + delta * blend
            calibrations[index].stops = calibrations[index].stops * (1 - blend) + stops * blend
            calibrations[index].recordedAt = Date()
        } else {
            calibrations.append(Calibration(stops: stops, delta: delta, recordedAt: Date()))
        }

        if calibrations.count > Self.maxCalibrations {
            calibrations.sort { $0.recordedAt > $1.recordedAt }
            calibrations = Array(calibrations.prefix(Self.maxCalibrations))
        }

        Log.control.info(String(
            format: "Learned: %+.2f stops -> %.3f (delta %+.3f, %d sample(s))",
            stops, chosenBrightness, delta, calibrations.count
        ))
    }

    mutating func resetCalibration() {
        calibrations.removeAll()
    }
}
