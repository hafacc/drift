import MideaKit
import SwiftUI

/// A 270° arc, open at the bottom, over the selectable setpoint range. Dragging along the
/// ring picks a whole degree; the − and + buttons sit on the arc's two ends. Scales to the
/// width it's given, up to 300 points.
struct TemperatureDial: View {
  let target: Double
  let indoor: Double?
  let outdoor: Double?
  let range: ClosedRange<Double>
  let accent: Color
  let label: String
  let setTarget: (Double) -> Void
  let step: (Double) -> Void

  @Environment(\.isEnabled) private var isEnabled

  private let maxSide: CGFloat = 300
  private let startDegrees: Double = 135
  private let sweepDegrees: Double = 270
  // The frame stops just under the step buttons, which hang below the arc's ends.
  private let heightFraction: CGFloat = 0.87

  var body: some View {
    GeometryReader { geometry in
      let side = min(geometry.size.width, maxSide)
      ZStack(alignment: .top) {
        arc(side: side)
          .frame(width: side, height: side)
          .contentShape(RingShape(radius: radius(side), width: lineWidth(side) * 3))
          .gesture(dragGesture(side: side))

        readout(side: side)
          .frame(width: side)
          .padding(.top, side * 0.22)
          .allowsHitTesting(false)

        stepButton("minus", label: "Colder", delta: -1, fraction: 0, side: side)
        stepButton("plus", label: "Warmer", delta: 1, fraction: 1, side: side)
      }
      .frame(width: side, height: side * heightFraction, alignment: .top)
      .frame(maxWidth: .infinity)
    }
    // Ratio inside the width cap; the other order sizes the height from the full row width.
    .aspectRatio(1 / heightFraction, contentMode: .fit)
    .frame(maxWidth: maxSide)
    .animation(.snappy(duration: 0.2), value: target)
    .accessibilityRepresentation {
      Stepper {
        Text("Target temperature")
      } onIncrement: {
        step(1)
      } onDecrement: {
        step(-1)
      }
      .accessibilityValue("\(Int(target.rounded()))°")
    }
  }

  private func radius(_ side: CGFloat) -> CGFloat { side * 0.4 }
  private func lineWidth(_ side: CGFloat) -> CGFloat { side * 0.06 }

  private func readout(side: CGFloat) -> some View {
    VStack(spacing: 2) {
      Text(label)
        .font(.caption)
        .fontWeight(.semibold)
        .tracking(1)
        .foregroundStyle(accent)
      Text("\(Int(target.rounded()))°")
        .font(.system(size: side * 0.24, weight: .light))
        .monospacedDigit()
        .contentTransition(.numericText(value: target))
        .lineLimit(1)
      if let temperatures {
        Text(temperatures)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
    }
  }

  /// E.g. "Indoor 26° · Outdoor 31°", or `nil` with neither reading.
  private var temperatures: String? {
    let parts = [
      indoor.map { "Indoor \(Int($0.rounded()))°" },
      outdoor.map { "Outdoor \(Int($0.rounded()))°" },
    ].compactMap(\.self)
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func arc(side: CGFloat) -> some View {
    let radius = radius(side)
    let stroke = StrokeStyle(lineWidth: lineWidth(side), lineCap: .round)
    return ZStack {
      track(to: 1).stroke(.fill.secondary, style: stroke)
        .frame(width: radius * 2, height: radius * 2)
      track(to: fraction(of: target)).stroke(accent, style: stroke)
        .frame(width: radius * 2, height: radius * 2)
      if let indoor {
        Circle()
          .fill(.primary)
          .frame(width: side * 0.02, height: side * 0.02)
          .position(point(at: fraction(of: indoor), side: side))
      }
      Circle()
        .fill(.white)
        .strokeBorder(accent, lineWidth: side * 0.017)
        .frame(width: side * 0.087, height: side * 0.087)
        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
        .position(point(at: fraction(of: target), side: side))
    }
  }

  private func track(to fraction: Double) -> some Shape {
    Circle()
      .trim(from: 0, to: sweepDegrees / 360 * fraction)
      .rotation(.degrees(startDegrees))
  }

  private func dragGesture(side: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        let center = CGPoint(x: side / 2, y: side / 2)
        let degrees = atan2(value.location.y - center.y, value.location.x - center.x) * 180 / .pi
        var along = (degrees - startDegrees).truncatingRemainder(dividingBy: 360)
        if along < 0 { along += 360 }
        if along > sweepDegrees {
          // In the gap at the bottom: pin to whichever end is nearer.
          along = along < (sweepDegrees + 360) / 2 ? sweepDegrees : 0
        }
        let span = range.upperBound - range.lowerBound
        let requested = (range.lowerBound + along / sweepDegrees * span).rounded()
        if requested != target.rounded() { setTarget(requested) }
      }
  }

  private func fraction(of temperature: Double) -> Double {
    let span = range.upperBound - range.lowerBound
    return min(1, max(0, (temperature - range.lowerBound) / span))
  }

  private func point(at fraction: Double, side: CGFloat) -> CGPoint {
    let radians = (startDegrees + sweepDegrees * fraction) * .pi / 180
    let radius = radius(side)
    return CGPoint(x: side / 2 + radius * cos(radians), y: side / 2 + radius * sin(radians))
  }

  private func stepButton(
    _ symbol: String, label: String, delta: Double, fraction: Double, side: CGFloat
  ) -> some View {
    Button {
      step(delta)
    } label: {
      Image(systemName: symbol)
        .font(.title3.weight(.medium))
        .foregroundStyle(isEnabled ? accent : .secondary)
        .frame(width: 44, height: 44)
        .background(Color(.secondarySystemGroupedBackground), in: Circle())
        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
        .contentShape(Circle())
        .accessibilityLabel(label)
    }
    .buttonStyle(.plain)
    .position(point(at: fraction, side: side))
    .frame(width: side, height: side)
  }
}

/// The band around a circle's outline, so only touches on the ring start a drag.
private struct RingShape: Shape {
  let radius: CGFloat
  let width: CGFloat

  func path(in rect: CGRect) -> Path {
    Path(
      ellipseIn: CGRect(
        x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2)
    )
    .strokedPath(StrokeStyle(lineWidth: width))
  }
}

/// Discrete fan speeds on a slider, plus a separate Auto that leaves the slider neutral.
struct FanSpeedControl: View {
  let fanSpeed: FanSpeed
  let accent: Color
  let select: (FanSpeed) -> Void

  @State private var draggedValue: Double?

  private let speeds: [FanSpeed] = [.silent, .low, .medium, .high, .max]

  private var currentIndex: Int? { speeds.firstIndex(of: fanSpeed) }
  private var shownIndex: Int? { draggedValue.map { Int($0.rounded()) } ?? currentIndex }
  private var valueName: String {
    if let shownIndex {
      return speeds[shownIndex].display.capitalized
    } else {
      return FanSpeed.allCases.contains(fanSpeed) ? fanSpeed.display.capitalized : "—"
    }
  }

  var body: some View {
    VStack(spacing: 10) {
      HStack {
        Text("Fan speed").foregroundStyle(.secondary)
        Spacer()
        Text(valueName).fontWeight(.semibold)
      }
      .font(.footnote)

      HStack(spacing: 12) {
        Slider(
          value: Binding(
            get: { draggedValue ?? Double(currentIndex ?? 2) },
            set: { draggedValue = $0 }),
          in: 0...Double(speeds.count - 1),
          step: 1
        ) { editing in
          guard !editing, let draggedValue else { return }
          let chosen = speeds[Int(draggedValue.rounded())]
          self.draggedValue = nil
          if chosen != fanSpeed { select(chosen) }
        }
        .tint(fanSpeed == .auto && draggedValue == nil ? .gray : accent)
        .accessibilityLabel("Fan speed")
        .accessibilityValue(valueName)

        autoButton
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(
      Color(.secondarySystemGroupedBackground),
      in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  @ViewBuilder
  private var autoButton: some View {
    let button = Button("Auto") { select(.auto) }
      .buttonBorderShape(.capsule)
    if fanSpeed == .auto {
      button.buttonStyle(.borderedProminent).tint(accent)
    } else {
      button.buttonStyle(.bordered).tint(.secondary)
    }
  }
}
