import AppKit
import QuartzCore

/// Little bots that float in front of the code: simple shapes with eyes that wander,
/// shift colors and morph from one shape to another. Everything is Core Animation, so once an
/// animation starts the system compositor runs it and the editor does no per-frame work.
/// Later the AI tutor will steer them to the code it is talking about.
final class BotsOverlay: NSView {
    static let didToggle = Notification.Name("KiteBotsDidToggle")

    /// Whether bots are shown, remembered across launches. Off unless turned on in View ▸ Show Bots.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "showBots") as? Bool ?? false }   // off by default: just code
        set {
            UserDefaults.standard.set(newValue, forKey: "showBots")
            NotificationCenter.default.post(name: didToggle, object: nil)
        }
    }

    private var bots: [Bot] = []
    private var timer: Timer?
    private var placed = false

    /// Why the focus changed; decides how the guide reacts.
    enum FocusReason { case scrolled, edited, caretMoved }

    /// Asked for fresh focus coordinates once the view has its real size.
    var requestFocus: (() -> Void)?

    /// The edited line's text, in this view's coordinates. Nil until the editor reports one.
    private var focusLine: CGRect?
    private var caretPoint: CGPoint = .zero
    private var pendingFlight: DispatchWorkItem?
    /// The star perches beside the line being edited.
    private var guide: Bot { bots[bots.count - 1] }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        for (i, shape) in BotShape.allCases.enumerated() {
            let bot = Bot(shape: shape, colorPhase: Double(i) / Double(BotShape.allCases.count))
            layer?.addSublayer(bot.node)
            bots.append(bot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// Clicks and scrolling go straight through to the code.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var walkArea: CGRect { bounds.insetBy(dx: 36, dy: 32) }

    override func layout() {
        super.layout()
        guard walkArea.width > 10, walkArea.height > 10 else { return }
        if !placed {
            placed = true
            scatter()
            requestFocus?()
        } else {
            // Keep everyone inside after a resize.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for bot in bots { bot.node.position = clamp(bot.node.position) }
            CATransaction.commit()
        }
    }

    /// Spreads the bots across the view, without animation.
    func scatter() {
        let area = walkArea
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bot) in bots.enumerated() {
            let x = area.minX + area.width * (CGFloat(i) + 0.5) / CGFloat(bots.count)
            let y = area.minY + area.height * (i.isMultiple(of: 2) ? 0.3 : 0.65)
            bot.node.position = CGPoint(x: x, y: y)
        }
        CATransaction.commit()
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        let a = walkArea
        return CGPoint(x: min(max(p.x, a.minX), a.maxX), y: min(max(p.y, a.minY), a.maxY))
    }

    private func randomPoint() -> CGPoint {
        let a = walkArea
        var p = CGPoint(x: a.midX, y: a.midY)
        // A few tries to land away from the line the guide is pointing at.
        for _ in 0..<8 {
            p = CGPoint(x: .random(in: a.minX...a.maxX), y: .random(in: a.minY...a.maxY))
            if let line = focusLine, abs(p.y - line.midY) < 40 { continue }
            return p
        }
        return p
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        for bot in bots { bot.startIdleAnimations() }
        // A slow tick that only decides what to do next; the motion itself is Core Animation.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard !isHiddenOrHasHiddenAncestor, window?.occlusionState.contains(.visible) == true,
              walkArea.width > 10, walkArea.height > 10 else { return }
        let now = CACurrentMediaTime()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for bot in bots {
            if now >= bot.nextBlink {
                bot.blink()
                bot.nextBlink = now + .random(in: 2.5...6)
            }
            if reduceMotion { continue }
            if bot === guide { continue }   // the guide only moves when the edited line does
            if now >= bot.nextMove {
                bot.walk(to: randomPoint())
                bot.nextMove = now + .random(in: 2.5...5.5)
            }
            if now >= bot.nextMorph {
                bot.morph(to: BotShape.allCases.filter { $0 != bot.shape }.randomElement()!)
                bot.nextMorph = now + .random(in: 7...14)
            }
        }
    }

    // MARK: Guide

    /// Called when the caret moves, the text changes or the view scrolls. `lineRect` spans the
    /// line's text, from its left edge to where the text ends; `caret` is the caret's center.
    /// Both are in this view's coordinates.
    func focus(lineRect: CGRect, caret: CGPoint, reason: FocusReason) {
        let previous = focusLine
        focusLine = lineRect
        caretPoint = caret
        guard placed else { return }

        switch reason {
        case .scrolled:
            // Ride along with the text, keeping its spot on the line; a pending flight
            // still reads the fresh perch when it fires.
            guide.jump(to: perchArea.clamp(CGPoint(x: guide.node.position.x, y: lineRect.midY)))
        case .edited, .caretMoved:
            let sameLine = previous.map { abs($0.midY - lineRect.midY) < 1 } ?? false
            let current = guide.node.position   // where the last flight is headed
            let textEnd = max(lineRect.maxX, caret.x)
            if sameLine && textEnd + 4 > current.x - Bot.size / 2 {
                // The text is about to run into it: hop well clear, right away.
                pendingFlight?.cancel()
                flyGuide(lead: 48)
            } else if sameLine && (0...72).contains(current.x - perch().x) {
                return                           // close enough; don't fidget while typing
            } else {
                scheduleFlight(after: 0.25)      // wait for the caret to settle
            }
        }
    }

    /// Where the guide sits: just right of the line's text, plus `lead` extra room.
    private func perch(lead: CGFloat = 0) -> CGPoint {
        guard let line = focusLine else { return guide.node.position }
        let x = max(line.maxX, caretPoint.x) + 10 + Bot.size / 2 + lead
        return perchArea.clamp(CGPoint(x: x, y: line.midY))
    }

    /// The guide may sit closer to the edges than the wanderers, so it can reach the first and last lines.
    private var perchArea: CGRect { bounds.insetBy(dx: Bot.size / 2 + 2, dy: Bot.size / 2 + 2) }

    private func scheduleFlight(after delay: TimeInterval) {
        pendingFlight?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flyGuide() }
        }
        pendingFlight = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func flyGuide(lead: CGFloat = 0) {
        pendingFlight?.cancel()
        pendingFlight = nil
        guard focusLine != nil, !isHiddenOrHasHiddenAncestor else { return }
        let target = perch(lead: lead)
        let here = guide.node.position
        if abs(target.x - here.x) < 1 && abs(target.y - here.y) < 1 {
            guide.look(at: caretPoint)           // already there (e.g. pinned at the right edge)
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            guide.appear(at: target)
            guide.look(at: caretPoint)
        } else {
            guide.fly(to: target)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.guide.look(at: self.caretPoint)
                }
            }
        }
    }
}

private extension CGRect {
    func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, minX), maxX), y: min(max(p.y, minY), maxY))
    }
}

// MARK: - Shapes

enum BotShape: CaseIterable {
    case circle, triangle, square, pentagon, star

    /// Every shape is drawn with the same number of points, at the same angles,
    /// so Core Animation can morph any shape into any other smoothly.
    static let samples = 120

    func path(center c: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let corners = self.corners
        for j in 0..<Self.samples {
            let angle = -CGFloat.pi / 2 + 2 * .pi * CGFloat(j) / CGFloat(Self.samples)
            let r = radius * visualScale * (corners.map { Self.distance(along: angle, to: $0) } ?? 1)
            let p = CGPoint(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
            if j == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    /// Corners on a unit circle, first one pointing up (y grows downward). Nil for the circle.
    private var corners: [CGPoint]? {
        func polygon(_ count: Int, rotation: CGFloat = 0, radii: [CGFloat] = [1]) -> [CGPoint] {
            (0..<count).map { i in
                let a = -CGFloat.pi / 2 + rotation + 2 * .pi * CGFloat(i) / CGFloat(count)
                let r = radii[i % radii.count]
                return CGPoint(x: r * cos(a), y: r * sin(a))
            }
        }
        switch self {
        case .circle: return nil
        case .triangle: return polygon(3)
        case .square: return polygon(4, rotation: .pi / 4)
        case .pentagon: return polygon(5)
        case .star: return polygon(10, radii: [1, 0.55])
        }
    }

    /// Evens out how big the shapes look next to each other.
    private var visualScale: CGFloat {
        switch self {
        case .circle: 0.9
        case .triangle: 1.18
        case .square: 0.98
        case .pentagon: 0.98
        case .star: 1.12
        }
    }

    /// How far a ray from the center at `angle` travels before it hits the outline.
    private static func distance(along angle: CGFloat, to corners: [CGPoint]) -> CGFloat {
        let d = CGPoint(x: cos(angle), y: sin(angle))
        func cross(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.y - a.y * b.x }
        var best = CGFloat.infinity
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            let e = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let denom = cross(d, e)
            guard abs(denom) > 1e-9 else { continue }
            let t = cross(a, e) / denom
            let s = cross(a, d) / denom
            if t > 0, s >= -1e-6, s <= 1 + 1e-6 { best = min(best, t) }
        }
        return best.isFinite ? best : 1
    }
}

// MARK: - One bot

@MainActor
private final class Bot {
    static let size: CGFloat = 36
    static let palette: [CGColor] = [0xFF6B6B, 0xFFA94D, 0xFFD43B, 0x69DB7C, 0x38D9A9, 0x4DABF7, 0x9775FA, 0xF783AC]
        .map { CGColor(srgbRed: CGFloat($0 >> 16) / 255, green: CGFloat($0 >> 8 & 0xFF) / 255,
                       blue: CGFloat($0 & 0xFF) / 255, alpha: 1) }

    let node = CALayer()        // walks around and leans
    let bobber = CALayer()      // bobs up and down, pops when morphing
    let body = CAShapeLayer()
    let eyes = CALayer()
    private var pupils: [CALayer] = []
    private(set) var shape: BotShape
    private let colorPhase: Double

    var nextMove = CACurrentMediaTime() + .random(in: 0.3...2)
    var nextMorph = CACurrentMediaTime() + .random(in: 5...12)
    var nextBlink = CACurrentMediaTime() + .random(in: 1...4)

    private var center: CGPoint { CGPoint(x: Self.size / 2, y: Self.size / 2) }
    private var radius: CGFloat { Self.size / 2 - 4 }

    init(shape: BotShape, colorPhase: Double) {
        self.shape = shape
        self.colorPhase = colorPhase
        let bounds = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        node.bounds = bounds
        bobber.frame = bounds
        node.addSublayer(bobber)

        // A stroke in the fill color rounds off the corners.
        body.frame = bounds
        body.path = shape.path(center: center, radius: radius)
        let color = Self.palette[Int(colorPhase * Double(Self.palette.count)) % Self.palette.count]
        body.fillColor = color
        body.strokeColor = color
        body.lineWidth = 5
        body.lineJoin = .round
        body.shadowColor = .black
        body.shadowOpacity = 0.28
        body.shadowRadius = 3
        body.shadowOffset = CGSize(width: 0, height: -2)
        bobber.addSublayer(body)

        // Two eyes, slightly below center so the triangle has room for them.
        eyes.frame = bounds
        for dx: CGFloat in [-5.5, 5.5] {
            let white = CALayer()
            white.bounds = CGRect(x: 0, y: 0, width: 8, height: 9)
            white.position = CGPoint(x: center.x + dx, y: center.y + 2)
            white.cornerRadius = 4
            white.backgroundColor = .white
            let pupil = CALayer()
            pupil.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
            pupil.position = CGPoint(x: 4, y: 4.5)
            pupil.cornerRadius = 2
            pupil.backgroundColor = CGColor(gray: 0.1, alpha: 1)
            white.addSublayer(pupil)
            pupils.append(pupil)
            eyes.addSublayer(white)
        }
        bobber.addSublayer(eyes)
    }

    /// Color cycling and bobbing, which loop forever.
    func startIdleAnimations() {
        let colors = Self.palette + [Self.palette[0]]
        for key in ["fillColor", "strokeColor"] {
            let cycle = CAKeyframeAnimation(keyPath: key)
            cycle.values = colors
            cycle.duration = 3.5 * Double(Self.palette.count)
            cycle.timeOffset = cycle.duration * colorPhase
            cycle.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: Self.palette.count)
            cycle.repeatCount = .infinity
            body.add(cycle, forKey: key)
        }

        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        bob.fromValue = -1.5
        bob.toValue = 1.5
        bob.duration = .random(in: 0.8...1.1)
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bobber.add(bob, forKey: "bob")
    }

    /// Slow, floaty wandering.
    func walk(to target: CGPoint) {
        let spring = CASpringAnimation(keyPath: "position")
        spring.mass = 1
        spring.stiffness = 40
        spring.damping = 11
        move(to: target, with: spring)
    }

    /// A purposeful move to the code being edited. Starts from where the bot is on screen right
    /// now, so a new target mid-flight redirects it instead of restarting.
    func fly(to target: CGPoint) {
        let spring = CASpringAnimation(perceptualDuration: 0.5, bounce: 0.2)
        spring.keyPath = "position"
        move(to: target, with: spring)
    }

    private func move(to target: CGPoint, with spring: CASpringAnimation) {
        let from = node.presentation()?.position ?? node.position
        spring.fromValue = NSValue(point: from)
        spring.toValue = NSValue(point: target)
        spring.duration = spring.settlingDuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        node.position = target
        CATransaction.commit()
        node.add(spring, forKey: "walk")

        // Lean into the move, then straighten up.
        let dx = target.x - from.x, dy = target.y - from.y
        let lean = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        lean.values = [0, (dx > 0 ? 1 : -1) * min(abs(dx) / 600, 0.2), 0]
        lean.keyTimes = [0, 0.3, 1]
        lean.duration = 1.2
        lean.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        node.add(lean, forKey: "lean")

        // Look where it's going.
        look(direction: CGPoint(x: dx, y: dy))
    }

    /// Moves instantly, cancelling any flight. Used while scrolling.
    func jump(to target: CGPoint) {
        node.removeAnimation(forKey: "walk")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        node.position = target
        CATransaction.commit()
    }

    /// Reduced motion: no travel, just fade in at the new spot.
    func appear(at target: CGPoint) {
        jump(to: target)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        node.add(fade, forKey: "appear")
    }

    /// Turns the pupils toward a point in the overlay's coordinates.
    func look(at point: CGPoint) {
        look(direction: CGPoint(x: point.x - node.position.x, y: point.y - node.position.y))
    }

    private func look(direction d: CGPoint) {
        let length = max(hypot(d.x, d.y), 1)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        for pupil in pupils {
            pupil.position = CGPoint(x: 4 + 1.6 * d.x / length, y: 4.5 + 1.8 * d.y / length)
        }
        CATransaction.commit()
    }

    func morph(to newShape: BotShape) {
        let newPath = newShape.path(center: center, radius: radius)
        let anim = CABasicAnimation(keyPath: "path")
        anim.fromValue = body.presentation()?.path ?? body.path
        anim.toValue = newPath
        anim.duration = 0.55
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.path = newPath
        CATransaction.commit()
        body.add(anim, forKey: "morph")
        shape = newShape

        // A little squash and pop while it changes.
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1, 0.82, 1.1, 1]
        pop.keyTimes = [0, 0.3, 0.7, 1]
        pop.duration = 0.55
        pop.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bobber.add(pop, forKey: "pop")
    }

    func blink() {
        let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        blink.values = [1, 0.1, 1]
        blink.duration = 0.18
        eyes.add(blink, forKey: "blink")
    }
}
