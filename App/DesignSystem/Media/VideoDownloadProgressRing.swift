import QuartzCore

/// Both native viewers use the same honest determinate/indeterminate ring, without a
/// SwiftUI hosting controller around AVKit or per-page timers.
@MainActor
final class VideoDownloadProgressRing: CALayer {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()

    override init() {
        super.init()
        track.fillColor = nil
        track.lineWidth = 3
        track.lineCap = .round
        addSublayer(track)
        arc.fillColor = nil
        arc.lineWidth = 3
        arc.lineCap = .round
        addSublayer(arc)
        track.strokeColor = CGColor(gray: 1, alpha: 0.25)
        arc.strokeColor = CGColor(gray: 1, alpha: 1)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }

    func updatePath() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let path = CGMutablePath()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: max(0, min(rect.width, rect.height) / 2),
            startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: false)
        track.frame = bounds
        track.path = path
        arc.frame = bounds
        arc.path = path
        CATransaction.commit()
    }

    func update(_ progress: VideoDownloadProgress) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let fraction = progress.fraction {
            arc.removeAnimation(forKey: "download.rotation")
            arc.strokeEnd = fraction
        } else {
            arc.strokeEnd = 0.25
            if arc.animation(forKey: "download.rotation") == nil {
                let animation = CABasicAnimation(keyPath: "transform.rotation.z")
                animation.fromValue = 0
                animation.toValue = Double.pi * 2
                animation.duration = 1
                animation.repeatCount = .infinity
                arc.add(animation, forKey: "download.rotation")
            }
        }
        CATransaction.commit()
    }
}
