import Foundation

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Each concealed semantic run owns independently drifting, finite-lived particles.
/// Only particles are painted: there is no filled panel behind concealed text.
/// TextKit line rectangles clip the field so wrapped gaps and adjacent text stay clear.
final class MessageSpoilerParticleField {
    private struct Particle {
        var origin: CGPoint
        var velocity: CGVector
        var birth: TimeInterval
        var lifetime: TimeInterval
        var diameter: CGFloat
    }

    private var rectangles: [CGRect] = []
    private var particles: [Particle] = []
    private var area: CGFloat = 0

    func draw(in rectangles: [CGRect], color: BubbleNativeColor) {
        let now = ProcessInfo.processInfo.systemUptime
        let geometryChanged = self.rectangles != rectangles
        if geometryChanged {
            self.rectangles = rectangles
            area = rectangles.reduce(0) { $0 + max(0, $1.width * $1.height) }
        }
        guard area > 0 else {
            particles.removeAll(keepingCapacity: true)
            return
        }
        let count = min(2500, max(1, Int(area / 9)))
        if particles.count > count { particles.removeLast(particles.count - count) }
        if geometryChanged {
            for index in particles.indices {
                particles[index] = makeParticle(now: now, initiallyAged: true)
            }
        }
        while particles.count < count {
            particles.append(makeParticle(now: now, initiallyAged: true))
        }

        #if os(macOS)
            guard let context = NSGraphicsContext.current?.cgContext else { return }
        #else
            guard let context = UIGraphicsGetCurrentContext() else { return }
        #endif
        context.saveGState()
        defer { context.restoreGState() }
        context.addRects(rectangles)
        context.clip()
        color.withAlphaComponent(0.65).setFill()
        for index in particles.indices {
            if now - particles[index].birth >= particles[index].lifetime {
                // Reuse expired slots rather than allocating particles each frame.
                particles[index] = makeParticle(now: now, initiallyAged: false)
            }
            let particle = particles[index]
            let age = max(0, now - particle.birth)
            let fade = min(1, age / 0.3, (particle.lifetime - age) / 0.5)
            let rect = CGRect(
                x: particle.origin.x + particle.velocity.dx * CGFloat(age),
                y: particle.origin.y + particle.velocity.dy * CGFloat(age),
                width: particle.diameter, height: particle.diameter)
            context.setAlpha(CGFloat(max(0, fade)))
            context.fillEllipse(in: rect)
        }
    }

    private func makeParticle(now: TimeInterval, initiallyAged: Bool) -> Particle {
        var target = CGFloat.random(in: 0...area)
        var rect = rectangles.last ?? .zero
        for candidate in rectangles {
            target -= max(0, candidate.width * candidate.height)
            if target <= 0 {
                rect = candidate
                break
            }
        }
        let angle = CGFloat.random(in: 0..<(2 * .pi))
        let speed = CGFloat.random(in: 2...7)
        let lifetime = TimeInterval.random(in: 1.5...3.5)
        return Particle(
            origin: CGPoint(
                x: rect.minX + CGFloat.random(in: 0...max(0, rect.width)),
                y: rect.minY + CGFloat.random(in: 0...max(0, rect.height))),
            velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
            birth: now - (initiallyAged ? TimeInterval.random(in: 0..<lifetime) : 0),
            lifetime: lifetime, diameter: CGFloat.random(in: 0.8...1.5))
    }
}
