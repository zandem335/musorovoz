import SwiftUI
import AppKit

private struct BlobScrollMonitor: NSViewRepresentable {
    let onScroll: (CGPoint, CGFloat) -> Bool

    final class SensorView: NSView {
        override var isFlipped: Bool { true }
    }

    final class Coordinator {
        weak var view: NSView?
        var onScroll: (CGPoint, CGFloat) -> Bool
        var monitor: Any?

        init(onScroll: @escaping (CGPoint, CGFloat) -> Bool) {
            self.onScroll = onScroll
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let view = self.view, view.window === event.window else { return event }
                let location = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(location) else { return event }
                let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                return self.onScroll(location, event.scrollingDeltaY * multiplier) ? nil : event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { uninstall() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    func makeNSView(context: Context) -> SensorView {
        let view = SensorView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: SensorView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: SensorView, coordinator: Coordinator) {
        coordinator.uninstall()
    }
}

private struct BlobRightClickMonitor: NSViewRepresentable {
    let onRightClick: (CGPoint) -> Bool

    final class SensorView: NSView {
        override var isFlipped: Bool { true }
    }

    final class Coordinator {
        weak var view: NSView?
        var onRightClick: (CGPoint) -> Bool
        var monitor: Any?

        init(onRightClick: @escaping (CGPoint) -> Bool) {
            self.onRightClick = onRightClick
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self, let view = self.view, view.window === event.window else { return event }
                let location = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(location) else { return event }
                return self.onRightClick(location) ? nil : event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { uninstall() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onRightClick: onRightClick) }

    func makeNSView(context: Context) -> SensorView {
        let view = SensorView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: SensorView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onRightClick = onRightClick
    }

    static func dismantleNSView(_ nsView: SensorView, coordinator: Coordinator) {
        coordinator.uninstall()
    }
}

private enum BlobScrollAction {
    case enter(BlobDescriptor)
    case back
    case consume
    case ignore
}

struct BlobDent: Sendable {
    let angle: CGFloat
    let strength: CGFloat
}

private enum BlobGeometry {
    static let heightRatio: CGFloat = 0.91
    static let compactThreshold: CGFloat = 112
    static let factors: [[CGFloat]] = [
        [0.86, 1.00, 0.90, 0.98, 0.80, 0.99, 0.87, 0.95],
        [0.82, 0.95, 1.00, 0.84, 0.98, 0.86, 0.99, 0.90],
        [0.98, 0.81, 0.94, 1.00, 0.86, 0.99, 0.83, 0.95],
        [0.85, 0.99, 0.82, 0.95, 1.00, 0.84, 0.97, 0.90]
    ]

    private struct Sample {
        let angle: CGFloat
        let cosine: CGFloat
        let sine: CGFloat
        let baseFactor: CGFloat
    }

    private static let samples: [[Sample]] = factors.map { radii in
        (0..<32).map { index in
            let progress = CGFloat(index) / 32 * CGFloat(radii.count)
            let lower = Int(floor(progress)) % radii.count
            let upper = (lower + 1) % radii.count
            let blend = progress - floor(progress)
            let factor = radii[lower] + (radii[upper] - radii[lower]) * blend
            let angle = CGFloat(index) / 32 * .pi * 2 - .pi / 2
            return Sample(angle: angle, cosine: cos(angle), sine: sin(angle), baseFactor: factor)
        }
    }

    static func contourPoints(diameter: CGFloat, variation: Int, dents: [BlobDent] = []) -> [CGPoint] {
        let radiusX = diameter / 2
        let radiusY = diameter * heightRatio / 2
        return samples[variation % samples.count].map { sample in
            var factor = sample.baseFactor
            for dent in dents {
                let delta = angularDistance(sample.angle, dent.angle)
                if delta < 0.72 {
                    let influence = pow(cos(delta / 0.72 * .pi / 2), 2)
                    factor -= dent.strength * influence
                    factor += dent.strength * 0.18 * pow(sin(delta / 0.72 * .pi), 2)
                }
            }
            return CGPoint(x: sample.cosine * radiusX * factor, y: sample.sine * radiusY * factor)
        }
    }

    private static func angularDistance(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        let raw = abs(first - second).truncatingRemainder(dividingBy: .pi * 2)
        return min(raw, .pi * 2 - raw)
    }

    static func support(diameter: CGFloat, variation: Int, dx: CGFloat, dy: CGFloat) -> CGFloat {
        let length = max(sqrt(dx * dx + dy * dy), 0.0001)
        let nx = dx / length
        let ny = dy / length
        let radius = diameter / 2
        return samples[variation % samples.count]
            .map { ($0.cosine * $0.baseFactor * nx + $0.sine * heightRatio * $0.baseFactor * ny) * radius }
            .max() ?? diameter / 2
    }

    static func expandedDiameter(for diameter: CGFloat) -> CGFloat {
        max(176, diameter * 1.55)
    }
}

private struct BlobParticle: Identifiable {
    let node: BlobDescriptor
    var center: CGPoint
    var velocity: CGVector
    let diameter: CGFloat
    let variation: Int
    var dents: [BlobDent]

    var id: String { node.id }
    var mass: CGFloat { diameter * diameter * BlobGeometry.heightRatio }
}

@MainActor
private final class BlobPhysicsModel: ObservableObject {
    @Published private(set) var particles: [BlobParticle] = []
    private var timer: Timer?
    private var bounds: CGSize = .zero
    private var signature = ""
    private var lastTick = Date()
    private var lastKick: [String: Date] = [:]
    private var accumulatedScroll: CGFloat = 0
    private var scrollDirection: CGFloat = 0
    private var lastScrollNavigation = Date.distantPast
    private var lastInteraction = Date()

    private func packedDenseParticles(
        nodes: [BlobDescriptor],
        in size: CGSize,
        minimumDiameter: CGFloat,
        maximumDiameter: CGFloat,
        minimumValue: Double,
        valueSpan: Double,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> [BlobParticle] {
        guard !nodes.isEmpty else { return [] }

        let usableHeight = max(size.height - topInset - bottomInset, 100)
        let targetAspect = max(size.width / usableHeight, 0.5)
        let gap: CGFloat = 4
        var packed: [BlobParticle] = []
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        func cardinalEdges(diameter: CGFloat, variation: Int, at point: CGPoint) -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
            (
                point.x - BlobGeometry.support(diameter: diameter, variation: variation, dx: -1, dy: 0),
                point.x + BlobGeometry.support(diameter: diameter, variation: variation, dx: 1, dy: 0),
                point.y - BlobGeometry.support(diameter: diameter, variation: variation, dx: 0, dy: -1),
                point.y + BlobGeometry.support(diameter: diameter, variation: variation, dx: 0, dy: 1)
            )
        }

        for (index, node) in nodes.enumerated() {
            let normalized = CGFloat((sqrt(Double(node.bytes)) - minimumValue) / valueSpan)
            let clamped = max(0, min(1, normalized))
            let diameter = minimumDiameter + clamped * (maximumDiameter - minimumDiameter)
            let variation = index % BlobGeometry.factors.count
            var chosenCenter = CGPoint.zero

            if !packed.isEmpty {
                var bestCenter: CGPoint?
                var bestScore = CGFloat.greatestFiniteMagnitude
                let angularSteps = 48

                for (anchorIndex, anchor) in packed.enumerated() {
                    let phase = CGFloat((index + anchorIndex) % 11) * 0.031
                    for step in 0..<angularSteps {
                        let angle = CGFloat(step) / CGFloat(angularSteps) * .pi * 2 + phase
                        let dx = cos(angle)
                        let dy = sin(angle)
                        let distance = BlobGeometry.support(
                            diameter: anchor.diameter,
                            variation: anchor.variation,
                            dx: dx,
                            dy: dy
                        ) + BlobGeometry.support(
                            diameter: diameter,
                            variation: variation,
                            dx: -dx,
                            dy: -dy
                        ) + gap
                        let candidate = CGPoint(
                            x: anchor.center.x + dx * distance,
                            y: anchor.center.y + dy * distance
                        )

                        var overlaps = false
                        for other in packed {
                            let otherDX = candidate.x - other.center.x
                            let otherDY = candidate.y - other.center.y
                            let separation = max(hypot(otherDX, otherDY), 0.001)
                            let nx = otherDX / separation
                            let ny = otherDY / separation
                            let required = BlobGeometry.support(
                                diameter: other.diameter,
                                variation: other.variation,
                                dx: nx,
                                dy: ny
                            ) + BlobGeometry.support(
                                diameter: diameter,
                                variation: variation,
                                dx: -nx,
                                dy: -ny
                            ) + gap - 0.5
                            if separation < required {
                                overlaps = true
                                break
                            }
                        }
                        guard !overlaps else { continue }

                        let edges = cardinalEdges(diameter: diameter, variation: variation, at: candidate)
                        let candidateMinX = min(minX, edges.left)
                        let candidateMaxX = max(maxX, edges.right)
                        let candidateMinY = min(minY, edges.top)
                        let candidateMaxY = max(maxY, edges.bottom)
                        let width = max(candidateMaxX - candidateMinX, 1)
                        let height = max(candidateMaxY - candidateMinY, 1)
                        let aspect = width / height
                        let aspectPenalty = CGFloat(abs(log(Double(max(aspect / targetAspect, 0.01)))))
                        let radialDistance = hypot(candidate.x, candidate.y)
                        let score = width * height * (1 + aspectPenalty * 0.58)
                            + radialDistance * maximumDiameter * 0.08

                        if score < bestScore {
                            bestScore = score
                            bestCenter = candidate
                        }
                    }
                }

                if let bestCenter {
                    chosenCenter = bestCenter
                } else {
                    let angle = CGFloat(index) * 2.399963
                    let radius = maximumDiameter * sqrt(CGFloat(index) + 1)
                    chosenCenter = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
                }
            }

            let particle = BlobParticle(
                node: node,
                center: chosenCenter,
                velocity: .zero,
                diameter: diameter,
                variation: variation,
                dents: []
            )
            packed.append(particle)
            let edges = cardinalEdges(diameter: diameter, variation: variation, at: chosenCenter)
            minX = min(minX, edges.left)
            maxX = max(maxX, edges.right)
            minY = min(minY, edges.top)
            maxY = max(maxY, edges.bottom)
        }

        let packedWidth = max(maxX - minX, 1)
        let packedHeight = max(maxY - minY, 1)
        let availableWidth = max(size.width - 36, 100)
        let availableHeight = max(usableHeight - 18, 100)
        // Fill the field instead of preserving the small construction scale.
        // The cap keeps very wide windows from turning every tiny file into a
        // huge blob, while the two fill ratios preserve safe UI margins.
        let fillScale = min(
            availableWidth * 0.86 / packedWidth,
            availableHeight * 0.80 / packedHeight
        )
        let scale = min(1.80, fillScale)
        let packedCenter = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let fieldCenter = CGPoint(x: size.width / 2, y: topInset + usableHeight / 2)

        return packed.map { particle in
            BlobParticle(
                node: particle.node,
                center: CGPoint(
                    x: fieldCenter.x + (particle.center.x - packedCenter.x) * scale,
                    y: fieldCenter.y + (particle.center.y - packedCenter.y) * scale
                ),
                velocity: .zero,
                diameter: particle.diameter * scale,
                variation: particle.variation,
                dents: []
            )
        }
    }

    func configure(nodes: [BlobDescriptor], in size: CGSize) {
        guard size.width > 100, size.height > 100 else { return }
        let newSignature = nodes.map { "\($0.id):\($0.bytes)" }.joined(separator: "|")
        if newSignature == signature, !particles.isEmpty {
            let needsDenseRepack = nodes.filter { $0.bytes > 0 }.count > 16
                && (abs(bounds.width - size.width) > 1 || abs(bounds.height - size.height) > 1)
            if !needsDenseRepack {
                resize(to: size)
                return
            }
        }

        signature = newSignature
        bounds = size
        let ordered = nodes.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        let maxBytes = max(ordered.map(\.bytes).max() ?? 1, 1)
        let minBytes = max(ordered.map(\.bytes).min() ?? 1, 1)
        let minValue = sqrt(Double(minBytes))
        let valueSpan = max(sqrt(Double(maxBytes)) - minValue, 1)
        let isDense = ordered.count > 16
        let countScale: CGFloat = ordered.count > 10 ? 0.92 : (ordered.count > 5 ? 0.96 : 1)
        let cap = min(255, size.height * 0.56) * countScale
        let minimum: CGFloat = ordered.count > 10 ? 96 : (ordered.count > 5 ? 108 : 120)
        let lowerCount = max(ordered.count - 2, 1)

        // Dense categories use a deterministic, size-aware bubble packing.
        // Large blobs anchor the cluster and smaller ones fill its open edges.
        let denseTopInset = max(70, size.height * 0.10)
        let denseBottomInset = max(20, size.height * 0.035)
        let denseUsableHeight = max(size.height - denseTopInset - denseBottomInset, 100)
        let fieldAspect = max(size.width / denseUsableHeight, 0.5)
        let denseColumns = max(1, Int(ceil(sqrt(Double(ordered.count) * Double(fieldAspect)))))
        let denseRows = max(1, Int(ceil(Double(ordered.count) / Double(denseColumns))))
        let denseCellWidth = size.width / CGFloat(denseColumns)
        let denseCellHeight = denseUsableHeight / CGFloat(denseRows)
        let denseMaximum = max(
            34,
            min(denseCellWidth * 0.82, denseCellHeight / BlobGeometry.heightRatio * 0.80)
        )
        let denseMinimum = max(30, denseMaximum * 0.43)

        if isDense {
            particles = packedDenseParticles(
                nodes: ordered,
                in: size,
                minimumDiameter: denseMinimum,
                maximumDiameter: denseMaximum,
                minimumValue: minValue,
                valueSpan: valueSpan,
                topInset: denseTopInset,
                bottomInset: denseBottomInset
            )
        } else {
            particles = ordered.enumerated().map { index, node in
                let normalizedSize = CGFloat((sqrt(Double(node.bytes)) - minValue) / valueSpan)
                let diameter = minimum + max(0, min(1, normalizedSize)) * (cap - minimum)
                let center: CGPoint
                if index < 2 {
                    center = CGPoint(
                        x: size.width * (index == 0 ? 0.36 : 0.64),
                        y: max(diameter / 2 + 8, size.height * 0.25)
                    )
                } else if ordered.count > 8 {
                    let gridIndex = index - 2
                    let remaining = ordered.count - 2
                    let columns = min(4, remaining)
                    let rows = Int(ceil(Double(remaining) / Double(columns)))
                    let column = gridIndex % columns
                    let row = gridIndex / columns
                    let columnProgress = columns == 1 ? 0.5 : CGFloat(column) / CGFloat(columns - 1)
                    let rowProgress = rows == 1 ? 0.5 : CGFloat(row) / CGFloat(rows - 1)
                    center = CGPoint(
                        x: size.width * (0.22 + columnProgress * 0.56),
                        y: size.height * (0.45 + rowProgress * 0.31)
                    )
                } else {
                    let lowerIndex = index - 2
                    let progress = CGFloat(lowerIndex + 1) / CGFloat(lowerCount + 1)
                    center = CGPoint(
                        x: size.width * (0.16 + progress * 0.68),
                        y: min(size.height - diameter / 2 - 8, size.height * 0.72)
                    )
                }
                return BlobParticle(
                    node: node,
                    center: center,
                    velocity: .zero,
                    diameter: diameter,
                    variation: index % BlobGeometry.factors.count,
                    dents: []
                )
            }
        }
        settleCollisions(iterations: isDense ? 18 : 100)
        lastTick = Date()
        lastInteraction = Date()
    }

    func resize(to newSize: CGSize) {
        guard newSize.width > 100, newSize.height > 100 else { return }
        guard bounds != .zero else { bounds = newSize; return }
        guard abs(bounds.width - newSize.width) > 1 || abs(bounds.height - newSize.height) > 1 else { return }
        let scaleX = newSize.width / bounds.width
        let scaleY = newSize.height / bounds.height
        for index in particles.indices {
            particles[index].center.x *= scaleX
            particles[index].center.y *= scaleY
        }
        bounds = newSize
        settleCollisions(iterations: particles.count > 20 ? 10 : 60)
        lastInteraction = Date()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func node(at point: CGPoint) -> BlobDescriptor? {
        for particle in particles.reversed() {
            let dx = point.x - particle.center.x
            let dy = point.y - particle.center.y
            let distance = sqrt(dx * dx + dy * dy)
            guard distance > 0.001 else { return particle.node }
            let edge = contourSupport(particle, dx: dx, dy: dy)
            if distance <= edge { return particle.node }
        }
        return nil
    }

    func scrollAction(at point: CGPoint, delta: CGFloat, canGoBack: Bool) -> BlobScrollAction {
        guard abs(delta) > 0.01 else { return .ignore }
        let direction: CGFloat = delta < 0 ? -1 : 1
        let candidate: BlobScrollAction
        if direction < 0 {
            guard let node = node(at: point), !node.children.isEmpty else {
                accumulatedScroll = 0
                return .ignore
            }
            candidate = .enter(node)
        } else {
            guard canGoBack else {
                accumulatedScroll = 0
                return .ignore
            }
            candidate = .back
        }

        if scrollDirection != direction {
            scrollDirection = direction
            accumulatedScroll = 0
        }
        accumulatedScroll += abs(delta)

        let now = Date()
        guard now.timeIntervalSince(lastScrollNavigation) > 0.72 else { return .consume }
        guard accumulatedScroll >= 18 else { return .consume }
        accumulatedScroll = 0
        lastScrollNavigation = now
        return candidate
    }

    private func step() {
        guard !particles.isEmpty, bounds != .zero else { return }
        let now = Date()
        let delta = min(max(now.timeIntervalSince(lastTick), 1.0 / 120.0), 1.0 / 20.0)
        lastTick = now
        let dt = CGFloat(delta)
        let damping = pow(0.982, dt * 60)
        for index in particles.indices {
            let dx = bounds.width / 2 - particles[index].center.x
            let dy = bounds.height / 2 - particles[index].center.y
            let distance = max(sqrt(dx * dx + dy * dy), 1)
            particles[index].velocity.dx += dx / distance * 5.5 * dt
            particles[index].velocity.dy += dy / distance * 5.5 * dt
            particles[index].center.x += particles[index].velocity.dx * dt
            particles[index].center.y += particles[index].velocity.dy * dt
            particles[index].velocity.dx *= damping
            particles[index].velocity.dy *= damping
            bounceFromWalls(index)
        }
        resolveCollisions(iterations: particles.count > 10 ? 4 : 3)
        updateDents()

        let peakSpeed = particles.map { hypot($0.velocity.dx, $0.velocity.dy) }.max() ?? 0
        let quietFor = now.timeIntervalSince(lastInteraction)
        if quietFor > 1.2 || (quietFor > 0.55 && peakSpeed < 3) {
            for index in particles.indices { particles[index].velocity = .zero }
            stop()
        }
    }

    private func contourSupport(_ particle: BlobParticle, dx: CGFloat, dy: CGFloat) -> CGFloat {
        BlobGeometry.support(diameter: particle.diameter, variation: particle.variation, dx: dx, dy: dy)
    }

    private func bounceFromWalls(_ index: Int) {
        let particle = particles[index]
        let horizontalInset = min(18, bounds.width * 0.025)
        let verticalInset = min(16, bounds.height * 0.025)
        let left = contourSupport(particle, dx: -1, dy: 0) + horizontalInset
        let right = contourSupport(particle, dx: 1, dy: 0) + horizontalInset
        let top = contourSupport(particle, dx: 0, dy: -1) + verticalInset
        let bottom = contourSupport(particle, dx: 0, dy: 1) + verticalInset
        if particles[index].center.x < left {
            particles[index].center.x = left
            particles[index].velocity.dx = abs(particles[index].velocity.dx) * 0.52
        } else if particles[index].center.x > bounds.width - right {
            particles[index].center.x = bounds.width - right
            particles[index].velocity.dx = -abs(particles[index].velocity.dx) * 0.52
        }
        if particles[index].center.y < top {
            particles[index].center.y = top
            particles[index].velocity.dy = abs(particles[index].velocity.dy) * 0.52
        } else if particles[index].center.y > bounds.height - bottom {
            particles[index].center.y = bounds.height - bottom
            particles[index].velocity.dy = -abs(particles[index].velocity.dy) * 0.52
        }
    }

    private func settleCollisions(iterations: Int) {
        guard particles.count > 1 else { return }
        for _ in 0..<iterations {
            resolveCollisions(iterations: 1)
            for index in particles.indices { bounceFromWalls(index) }
        }
    }

    private func resolveCollisions(iterations: Int) {
        guard particles.count > 1 else { return }
        for _ in 0..<iterations {
            for first in 0..<(particles.count - 1) {
                for second in (first + 1)..<particles.count {
                    var dx = particles[second].center.x - particles[first].center.x
                    var dy = particles[second].center.y - particles[first].center.y
                    var distance = sqrt(dx * dx + dy * dy)
                    if distance < 0.001 { dx = 1; dy = 0; distance = 1 }
                    let nx = dx / distance
                    let ny = dy / distance
                    let firstSupport = contourSupport(particles[first], dx: nx, dy: ny)
                    let secondSupport = contourSupport(particles[second], dx: -nx, dy: -ny)
                    let minimumDistance = firstSupport + secondSupport + 1
                    guard distance < minimumDistance else { continue }
                    let overlap = minimumDistance - distance
                    let totalMass = particles[first].mass + particles[second].mass
                    let firstShare = particles[second].mass / totalMass
                    let secondShare = particles[first].mass / totalMass
                    particles[first].center.x -= nx * overlap * firstShare
                    particles[first].center.y -= ny * overlap * firstShare
                    particles[second].center.x += nx * overlap * secondShare
                    particles[second].center.y += ny * overlap * secondShare

                    let relativeX = particles[second].velocity.dx - particles[first].velocity.dx
                    let relativeY = particles[second].velocity.dy - particles[first].velocity.dy
                    let separatingVelocity = relativeX * nx + relativeY * ny
                    guard separatingVelocity < 0 else { continue }
                    let firstInverseMass = 1 / particles[first].mass
                    let secondInverseMass = 1 / particles[second].mass
                    let impulse = -1.18 * separatingVelocity / (firstInverseMass + secondInverseMass)
                    particles[first].velocity.dx -= impulse * firstInverseMass * nx
                    particles[first].velocity.dy -= impulse * firstInverseMass * ny
                    particles[second].velocity.dx += impulse * secondInverseMass * nx
                    particles[second].velocity.dy += impulse * secondInverseMass * ny
                }
            }
        }
    }

    private func updateDents() {
        guard particles.count > 1 else { return }
        var targets = Array(repeating: [BlobDent](), count: particles.count)
        for first in 0..<(particles.count - 1) {
            for second in (first + 1)..<particles.count {
                let dx = particles[second].center.x - particles[first].center.x
                let dy = particles[second].center.y - particles[first].center.y
                let distance = max(sqrt(dx * dx + dy * dy), 1)
                let firstSupport = contourSupport(particles[first], dx: dx, dy: dy)
                let secondSupport = contourSupport(particles[second], dx: -dx, dy: -dy)
                let contact = firstSupport + secondSupport
                let proximity = max(0, min(1, (contact + 10 - distance) / 28))
                guard proximity > 0 else { continue }
                let angle = atan2(dy, dx)
                let strength = 0.065 * proximity
                targets[first].append(BlobDent(angle: angle, strength: strength))
                targets[second].append(BlobDent(angle: angle + .pi, strength: strength))
            }
        }

        for index in particles.indices {
            let previous = particles[index].dents
            var matchedPrevious = Set<Int>()
            var smoothed: [BlobDent] = []

            for target in targets[index] {
                let match = previous.enumerated()
                    .filter { !matchedPrevious.contains($0.offset) }
                    .min { angularDistance($0.element.angle, target.angle) < angularDistance($1.element.angle, target.angle) }

                if let match, angularDistance(match.element.angle, target.angle) < 0.9 {
                    matchedPrevious.insert(match.offset)
                    let angleDelta = atan2(sin(target.angle - match.element.angle), cos(target.angle - match.element.angle))
                    smoothed.append(BlobDent(
                        angle: match.element.angle + angleDelta * 0.18,
                        strength: match.element.strength + (target.strength - match.element.strength) * 0.16
                    ))
                } else {
                    smoothed.append(BlobDent(angle: target.angle, strength: target.strength * 0.16))
                }
            }

            for (oldIndex, old) in previous.enumerated() where !matchedPrevious.contains(oldIndex) {
                let fadedStrength = old.strength * 0.82
                if fadedStrength > 0.001 {
                    smoothed.append(BlobDent(angle: old.angle, strength: fadedStrength))
                }
            }
            particles[index].dents = smoothed
        }
    }

    private func angularDistance(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        abs(atan2(sin(first - second), cos(first - second)))
    }
}

struct OrganicBlob: Shape {
    let variation: Int
    var dents: [BlobDent] = []

    func path(in rect: CGRect) -> Path {
        let rawPoints = BlobGeometry.contourPoints(diameter: rect.width, variation: variation, dents: dents)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let points = rawPoints.map { CGPoint(x: center.x + $0.x, y: center.y + $0.y) }
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: (points.last!.x + first.x) / 2, y: (points.last!.y + first.y) / 2))
        for index in points.indices {
            let point = points[index]
            let next = points[(index + 1) % points.count]
            path.addQuadCurve(to: CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2), control: point)
        }
        path.closeSubpath()
        return path
    }
}

private struct BlobNode: View {
    let node: BlobDescriptor
    let diameter: CGFloat
    let variation: Int
    let dents: [BlobDent]
    let isDeleteConfirming: Bool
    let canRevealInFinder: Bool
    let onHoverChange: (Bool) -> Void
    let onRequestDelete: () -> Void
    let onRevealInFinder: () -> Void
    let onCancelDelete: () -> Void
    let onConfirmDelete: () -> Void
    @State private var isHovered = false

    private var isFileBlob: Bool { node.systemImage == "doc.fill" }
    private var isCompact: Bool { diameter < BlobGeometry.compactThreshold }
    private var isExpanded: Bool { isCompact && (isHovered || isDeleteConfirming) }
    private var visualDiameter: CGFloat { isExpanded ? BlobGeometry.expandedDiameter(for: diameter) : diameter }

    private var displayTitle: String {
        guard isFileBlob else { return node.title }
        let limit = isExpanded ? 22 : (diameter < 135 ? 16 : (diameter < 190 ? 22 : 28))
        let characters = Array(node.title)
        guard characters.count > limit else { return node.title }
        let suffixCount = max(7, limit / 2)
        let prefixCount = max(4, limit - suffixCount - 1)
        return String(characters.prefix(prefixCount)) + "…" + String(characters.suffix(suffixCount))
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                let path = OrganicBlob(variation: variation, dents: dents).path(in: rect)
                context.fill(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [node.tint.opacity(0.42), node.tint.opacity(0.72)]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: size.height)
                    )
                )
                context.stroke(path, with: .color(.white.opacity(0.42)), lineWidth: 1)
            }
                .shadow(color: node.tint.opacity(0.22), radius: 20, y: 9)
            if isDeleteConfirming {
                VStack(spacing: 11) {
                    Text("Удалить?")
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text(StorageFormat.string(node.bytes))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: canRevealInFinder ? 9 : 12) {
                        if canRevealInFinder {
                            Button(action: onRevealInFinder) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 30, height: 30)
                                    .background(Color.blue.opacity(0.86), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Показать в Finder")
                            .accessibilityLabel("Показать файл в Finder")
                        }
                        Button(action: onCancelDelete) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .frame(width: 30, height: 30)
                                .background(.white.opacity(0.72), in: Circle())
                                .overlay(Circle().stroke(Color.primary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Отменить удаление")
                        Button(action: onConfirmDelete) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Color.red.opacity(0.86), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Подтвердить удаление")
                    }
                }
                .padding(visualDiameter * 0.12)
                .transition(.opacity.combined(with: .scale(scale: 0.88)))
            } else {
                VStack(spacing: visualDiameter > 180 ? 9 : 5) {
                    if isCompact && !isExpanded {
                    Text(StorageFormat.string(node.bytes))
                        .font(.system(size: max(9, min(17, diameter * 0.19)), weight: .bold))
                        .minimumScaleFactor(0.64)
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    } else {
                        Image(systemName: node.systemImage)
                            .font(.system(size: max(16, visualDiameter * 0.115), weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.72))
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        Text(displayTitle)
                            .font(visualDiameter > 180 ? .headline : .subheadline)
                            .fontWeight(.semibold)
                            .multilineTextAlignment(.center)
                            .lineLimit(isFileBlob ? 1 : 2)
                            .minimumScaleFactor(isExpanded ? 0.72 : 0.82)
                            .allowsTightening(true)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        Text(StorageFormat.string(node.bytes))
                            .font(visualDiameter > 170 ? .title2 : .headline)
                            .fontWeight(.bold)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .padding(visualDiameter * 0.12)
            }
        }
        .frame(width: visualDiameter, height: visualDiameter * BlobGeometry.heightRatio)
        .contentShape(OrganicBlob(variation: variation))
        .zIndex(isExpanded ? 100 : 0)
        .onHover { hovering in
            guard isCompact else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                isHovered = hovering
                onHoverChange(hovering)
            }
        }
        .onLongPressGesture(minimumDuration: 0.65, perform: onRequestDelete)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.title), \(StorageFormat.string(node.bytes))")
        .accessibilityHint(node.children.isEmpty ? "" : "Открыть состав категории")
    }
}

private struct BlobField: View {
    let nodes: [BlobDescriptor]
    let onSelect: (BlobDescriptor) -> Void
    let canGoBack: Bool
    let onScrollBack: () -> Void
    var onLeafSelect: ((BlobDescriptor) -> Void)? = nil
    let canDelete: (BlobDescriptor) -> Bool
    let canRevealInFinder: (BlobDescriptor) -> Bool
    let onDeleteConfirmed: (BlobDescriptor) -> Void
    let onRevealInFinder: (BlobDescriptor) -> Void
    @StateObject private var physics = BlobPhysicsModel()
    @State private var expandedBlobID: String?
    @State private var deleteConfirmationID: String?

    private var activeExpandedBlobID: String? { deleteConfirmationID ?? expandedBlobID }

    private func displayCenters(in size: CGSize) -> [String: CGPoint] {
        var centers = Dictionary(uniqueKeysWithValues: physics.particles.map { ($0.id, $0.center) })
        guard
            let expandedBlobID = activeExpandedBlobID,
            let expandedIndex = physics.particles.firstIndex(where: { $0.id == expandedBlobID })
        else { return centers }

        let expanded = physics.particles[expandedIndex]
        let expandedDiameter = BlobGeometry.expandedDiameter(for: expanded.diameter)
        let expansion = expandedDiameter - expanded.diameter
        let fieldDiagonal = max(hypot(size.width, size.height), 1)

        // Every blob participates in the hover layout. Nearby items move farther,
        // distant ones move only a few points so the whole cluster opens naturally.
        for particle in physics.particles where particle.id != expandedBlobID {
            var dx = particle.center.x - expanded.center.x
            var dy = particle.center.y - expanded.center.y
            var distance = hypot(dx, dy)
            if distance < 0.001 {
                dx = particle.id < expanded.id ? -1 : 1
                dy = 0
                distance = 1
            }
            let influence = max(0.14, 1 - distance / fieldDiagonal)
            let shift = expansion * 0.30 * influence
            centers[particle.id] = CGPoint(
                x: particle.center.x + dx / distance * shift,
                y: particle.center.y + dy / distance * shift
            )
        }

        // Resolve the complete group repeatedly so displacement cannot create a
        // second overlap farther away from the expanded blob.
        if physics.particles.count > 1 {
            let relaxationIterations = physics.particles.count > 20 ? 5 : 18
            for _ in 0..<relaxationIterations {
                for first in 0..<(physics.particles.count - 1) {
                    for second in (first + 1)..<physics.particles.count {
                        let firstParticle = physics.particles[first]
                        let secondParticle = physics.particles[second]
                        guard var firstCenter = centers[firstParticle.id], var secondCenter = centers[secondParticle.id] else { continue }
                        var dx = secondCenter.x - firstCenter.x
                        var dy = secondCenter.y - firstCenter.y
                        var distance = hypot(dx, dy)
                        if distance < 0.001 { dx = 1; dy = 0; distance = 1 }
                        let nx = dx / distance
                        let ny = dy / distance
                        let firstDiameter = firstParticle.id == expandedBlobID ? expandedDiameter : firstParticle.diameter
                        let secondDiameter = secondParticle.id == expandedBlobID ? expandedDiameter : secondParticle.diameter
                        let minimumDistance = BlobGeometry.support(
                            diameter: firstDiameter,
                            variation: firstParticle.variation,
                            dx: nx,
                            dy: ny
                        ) + BlobGeometry.support(
                            diameter: secondDiameter,
                            variation: secondParticle.variation,
                            dx: -nx,
                            dy: -ny
                        ) + 2
                        let overlap = minimumDistance - distance
                        guard overlap > 0 else { continue }

                        if firstParticle.id == expandedBlobID {
                            secondCenter.x += nx * overlap
                            secondCenter.y += ny * overlap
                        } else if secondParticle.id == expandedBlobID {
                            firstCenter.x -= nx * overlap
                            firstCenter.y -= ny * overlap
                        } else {
                            firstCenter.x -= nx * overlap * 0.5
                            firstCenter.y -= ny * overlap * 0.5
                            secondCenter.x += nx * overlap * 0.5
                            secondCenter.y += ny * overlap * 0.5
                        }
                        centers[firstParticle.id] = firstCenter
                        centers[secondParticle.id] = secondCenter
                    }
                }
            }
        }

        for particle in physics.particles where particle.id != expandedBlobID {
            guard let center = centers[particle.id] else { continue }
            let horizontalMargin = particle.diameter * 0.38 + 8
            let verticalMargin = particle.diameter * BlobGeometry.heightRatio * 0.38 + 8
            centers[particle.id] = CGPoint(
                x: min(max(center.x, horizontalMargin), max(horizontalMargin, size.width - horizontalMargin)),
                y: min(max(center.y, verticalMargin), max(verticalMargin, size.height - verticalMargin))
            )
        }
        return centers
    }

    private func node(at point: CGPoint, centers: [String: CGPoint]) -> BlobDescriptor? {
        for particle in physics.particles.reversed() {
            let center = centers[particle.id] ?? particle.center
            let dx = point.x - center.x
            let dy = point.y - center.y
            let distance = hypot(dx, dy)
            if distance < 0.001 { return particle.node }
            let diameter = particle.id == activeExpandedBlobID
                ? BlobGeometry.expandedDiameter(for: particle.diameter)
                : particle.diameter
            let edge = BlobGeometry.support(diameter: diameter, variation: particle.variation, dx: dx, dy: dy)
            if distance <= edge { return particle.node }
        }
        return nil
    }

    private func requestDelete(_ node: BlobDescriptor) {
        guard canDelete(node) else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            deleteConfirmationID = node.id
        }
    }

    private func cancelDelete() {
        withAnimation(.spring(response: 0.30, dampingFraction: 0.90)) {
            deleteConfirmationID = nil
        }
    }

    private func confirmDelete(_ node: BlobDescriptor) {
        guard deleteConfirmationID == node.id, canDelete(node) else { return }
        deleteConfirmationID = nil
        onDeleteConfirmed(node)
    }

    private func revealInFinder(_ node: BlobDescriptor) {
        guard canRevealInFinder(node) else { return }
        deleteConfirmationID = nil
        onRevealInFinder(node)
    }

    var body: some View {
        GeometryReader { proxy in
            let dataSignature = nodes.map { "\($0.id):\($0.bytes)" }.joined(separator: "|")
            let displayedCenters = displayCenters(in: proxy.size)
            ZStack {
                ForEach(physics.particles) { particle in
                    BlobNode(
                        node: particle.node,
                        diameter: particle.diameter,
                        variation: particle.variation,
                        dents: particle.dents,
                        isDeleteConfirming: deleteConfirmationID == particle.id,
                        canRevealInFinder: canRevealInFinder(particle.node),
                        onHoverChange: { hovering in
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                                if hovering {
                                    expandedBlobID = particle.id
                                } else if expandedBlobID == particle.id {
                                    expandedBlobID = nil
                                }
                            }
                        },
                        onRequestDelete: { requestDelete(particle.node) },
                        onRevealInFinder: { revealInFinder(particle.node) },
                        onCancelDelete: cancelDelete,
                        onConfirmDelete: { confirmDelete(particle.node) }
                    )
                    .contentShape(OrganicBlob(variation: particle.variation))
                    .position(displayedCenters[particle.id] ?? particle.center)
                    .zIndex(expandedBlobID == particle.id ? 100 : 0)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        if particle.node.children.isEmpty {
                            if let onLeafSelect { onLeafSelect(particle.node) }
                        } else {
                            physics.stop()
                            onSelect(particle.node)
                        }
                    }
                    .help("\(particle.node.title)\n\(StorageFormat.string(particle.node.bytes))\n\(particle.node.subtitle)\n\(particle.node.children.isEmpty ? "Нажмите, чтобы выбрать" : "Двойной клик — посмотреть внутри")")
                }
            }
            .contentShape(Rectangle())
            .background {
                BlobScrollMonitor { point, delta in
                    guard deleteConfirmationID == nil else { return true }
                    switch physics.scrollAction(at: point, delta: delta, canGoBack: canGoBack) {
                    case let .enter(node):
                        physics.stop()
                        onSelect(node)
                        return true
                    case .back:
                        physics.stop()
                        onScrollBack()
                        return true
                    case .consume:
                        return true
                    case .ignore:
                        return false
                    }
                }
            }
            .background {
                BlobRightClickMonitor { point in
                    guard let node = node(at: point, centers: displayedCenters), canDelete(node) else {
                        if deleteConfirmationID != nil { cancelDelete() }
                        return false
                    }
                    requestDelete(node)
                    return true
                }
            }
            .simultaneousGesture(
                SpatialTapGesture(count: 2)
                    .exclusively(before: SpatialTapGesture(count: 1))
                    .onEnded { click in
                        let location: CGPoint
                        let isDoubleClick: Bool
                        switch click {
                        case let .first(value):
                            location = value.location
                            isDoubleClick = true
                        case let .second(value):
                            location = value.location
                            isDoubleClick = false
                        }
                        if deleteConfirmationID != nil { return }
                        guard let node = node(at: location, centers: displayedCenters) else { return }
                        if node.children.isEmpty {
                            if let onLeafSelect { onLeafSelect(node) }
                        } else if isDoubleClick {
                            physics.stop()
                            onSelect(node)
                        }
                    }
            )
            .onAppear {
                physics.configure(nodes: nodes, in: proxy.size)
            }
            .onDisappear { physics.stop() }
            .onChange(of: dataSignature) {
                deleteConfirmationID = nil
                physics.configure(nodes: nodes, in: proxy.size)
            }
            .onChange(of: proxy.size) { physics.resize(to: proxy.size) }
        }
    }
}

private struct RectangularEdgeFadeMask: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.70), location: 0.025),
                .init(color: .white, location: 0.065),
                .init(color: .white, location: 0.935),
                .init(color: .white.opacity(0.70), location: 0.975),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.72), location: 0.02),
                    .init(color: .white, location: 0.055),
                    .init(color: .white, location: 0.945),
                    .init(color: .white.opacity(0.72), location: 0.98),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}

struct BlobExplorer: View {
    let categories: [CleanupCategory]
    let largeFiles: [LargeFileEntry]
    let installerFiles: [LargeFileEntry]
    let onLargeFileSelect: (LargeFileEntry) -> Void
    let onDeleteAllLargeFiles: () -> Void
    let onDeleteAllInstallers: () -> Void
    let onLargeFileDeleteConfirmed: (LargeFileEntry) -> Void
    let onLargeFileReveal: (LargeFileEntry) -> Void
    let onCleanupNodeDeleteConfirmed: (BlobDescriptor) -> Void
    @State private var pathIDs: [String] = []
    @State private var navigationDirection: NavigationDirection = .deeper

    private enum NavigationDirection {
        case deeper
        case back
    }

    private var roots: [BlobDescriptor] {
        var result = categories.map(BlobDescriptor.init(category:))
        if !installerFiles.isEmpty { result.append(BlobDescriptor(installerFiles: installerFiles)) }
        if !largeFiles.isEmpty { result.append(BlobDescriptor(largeFiles: largeFiles)) }
        return result
    }
    private var currentNode: BlobDescriptor? {
        var level = roots
        var selected: BlobDescriptor?
        for id in pathIDs {
            guard let next = level.first(where: { $0.id == id }) else { return nil }
            selected = next
            level = next.children
        }
        return selected
    }
    private var currentNodes: [BlobDescriptor] { currentNode?.children ?? roots }
    private var currentTitle: String { currentNode?.title ?? "" }
    private var depthID: String { pathIDs.isEmpty ? "root" : pathIDs.joined(separator: "/") }
    private var isInsideFileCollection: Bool {
        pathIDs.first == "largeFiles" || pathIDs.first == "installers"
    }
    private var filesByID: [String: LargeFileEntry] {
        var result = Dictionary(uniqueKeysWithValues: largeFiles.map { ($0.id, $0) })
        for file in installerFiles { result[file.id] = file }
        return result
    }

    private func canDelete(_ node: BlobDescriptor) -> Bool {
        if isInsideFileCollection { return filesByID[node.id] != nil }
        if node.id == "largeFiles" || node.id == "installers" || node.id.hasPrefix("claudeVM.") { return false }
        return categories.contains { category in
            category.id == node.id || (category.items ?? []).contains { $0.id == node.id }
        }
    }

    private func canRevealInFinder(_ node: BlobDescriptor) -> Bool {
        isInsideFileCollection && filesByID[node.id] != nil
    }

    private func revealInFinder(_ node: BlobDescriptor) {
        guard let file = filesByID[node.id], isInsideFileCollection else { return }
        onLargeFileReveal(file)
    }

    private func confirmDelete(_ node: BlobDescriptor) {
        if isInsideFileCollection, let file = filesByID[node.id] {
            onLargeFileDeleteConfirmed(file)
        } else if canDelete(node) {
            onCleanupNodeDeleteConfirmed(node)
        }
    }
    private var fieldTransition: AnyTransition {
        switch navigationDirection {
        case .deeper:
            return .asymmetric(
                insertion: .scale(scale: 0.22).combined(with: .opacity),
                removal: .scale(scale: 2.15).combined(with: .opacity)
            )
        case .back:
            return .asymmetric(
                insertion: .scale(scale: 2.15).combined(with: .opacity),
                removal: .scale(scale: 0.22).combined(with: .opacity)
            )
        }
    }

    private func enter(_ node: BlobDescriptor) {
        guard !node.children.isEmpty else { return }
        guard currentNodes.contains(where: { $0.id == node.id }) else { return }
        navigationDirection = .deeper
        withAnimation(.spring(response: 0.72, dampingFraction: 0.90)) {
            pathIDs.append(node.id)
        }
    }

    private func goBack() {
        guard !pathIDs.isEmpty else { return }
        navigationDirection = .back
        withAnimation(.spring(response: 0.82, dampingFraction: 0.92)) {
            _ = pathIDs.popLast()
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { proxy in
                ZStack {
                    BlobField(
                        nodes: currentNodes,
                        onSelect: enter,
                        canGoBack: !pathIDs.isEmpty,
                        onScrollBack: goBack,
                        onLeafSelect: isInsideFileCollection ? { node in
                            if let file = filesByID[node.id] { onLargeFileSelect(file) }
                        } : nil,
                        canDelete: canDelete,
                        canRevealInFinder: canRevealInFinder,
                        onDeleteConfirmed: confirmDelete,
                        onRevealInFinder: revealInFinder
                    )
                    .id(depthID)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .transition(fieldTransition)
                }
                .frame(width: proxy.size.width + 48, height: proxy.size.height + 44)
                .mask(RectangularEdgeFadeMask())
                .position(
                    x: proxy.size.width / 2,
                    y: proxy.size.height / 2
                )
            }

            if !pathIDs.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        goBack()
                    } label: {
                        Label("Назад", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(currentTitle).font(.headline)
                        Text("Из чего состоит • \(StorageFormat.string(currentNodes.reduce(0) { $0 + $1.bytes }))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isInsideFileCollection {
                        Button("В Корзину всё", role: .destructive) {
                            if pathIDs.first == "installers" {
                                onDeleteAllInstallers()
                            } else {
                                onDeleteAllLargeFiles()
                            }
                        }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .onChange(of: (categories.map { "\($0.id):\($0.bytes)" } + largeFiles.map { "\($0.id):\($0.bytes)" } + installerFiles.map { "\($0.id):\($0.bytes)" }).joined(separator: "|")) {
            pathIDs.removeAll()
        }
    }
}
