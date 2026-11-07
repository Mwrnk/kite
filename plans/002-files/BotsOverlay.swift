import AppKit
import QuartzCore

/// Little bots that live in front of the code. The star is the guide: it flies to the line being
/// edited and watches the caret. The others hop around on their own.
///
/// Motion is a small physics simulation (springs, gravity, squash and stretch) stepped by a display
/// link. The link runs only while something is moving, so an idle editor does no per-frame work.
/// Colors, idle bobbing, blinking and shape morphs stay plain Core Animation.
final class BotsOverlay: NSView {
    static let didToggle = Notification.Name("KiteBotsDidToggle")

    /// Whether bots are shown, remembered across launches. Toggled from View ▸ Show Bots.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "showBots") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "showBots")
            NotificationCenter.default.post(name: didToggle, object: nil)
        }
    }

    /// Why the focus changed; decides how the guide reacts.
    enum FocusReason { case scrolled, edited, caretMoved }

    /// Asked for fresh focus coordinates once the view has its real size.
    var requestFocus: (() -> Void)?

    private var bots: [Bot] = []
    private var timer: Timer?
    private var link: CADisplayLink?
    private var lastStep: CFTimeInterval = 0
    private var placed = false

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
        let eyes: [EyeStyle] = [.beads, .happy, .pixel, .sparkle, .beans]
        for (i, shape) in BotShape.allCases.enumerated() {
            let bot = Bot(shape: shape, eyes: eyes[i], colorPhase: Double(i) / Double(BotShape.allCases.count))
            layer?.addSublayer(bot.node)
            bots.append(bot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// Clicks and scrolling go straight through to the code.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Where wanderers may land.
    private var walkArea: CGRect { bounds.insetBy(dx: Bot.size / 2 + 14, dy: Bot.size / 2 + 10) }
    /// The guide may sit closer to the edges, so it can reach the first and last lines.
    private var perchArea: CGRect { bounds.insetBy(dx: Bot.size / 2 + 2, dy: Bot.size / 2 + 2) }

    override func layout() {
        super.layout()
        guard walkArea.width > 10, walkArea.height > 10 else { return }
        if !placed {
            placed = true
            scatter()
            requestFocus?()
        } else {
            // Keep everyone inside after a resize.
            for bot in bots { bot.keep(inside: bot === guide ? perchArea : walkArea) }
            renderAll()
        }
    }

    /// Spreads the bots across the view, without animation.
    func scatter() {
        let area = walkArea
        for (i, bot) in bots.enumerated() {
            let x = area.minX + area.width * (CGFloat(i) + 0.5) / CGFloat(bots.count)
            let y = area.minY + area.height * (i.isMultiple(of: 2) ? 0.3 : 0.65)
            bot.place(at: CGPoint(x: x, y: y))
        }
        renderAll()
    }

    private func renderAll() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bot in bots { bot.render() }
        CATransaction.commit()
    }

    /// A landing spot a short hop away, off the guide's line and clear of the other bots.
    private func hopTarget(for bot: Bot) -> CGPoint {
        let a = walkArea
        var p = bot.pos
        for _ in 0..<12 {
            let angle = CGFloat.random(in: 0..<(2 * .pi))
            let distance = CGFloat.random(in: 60...220)
            p = a.clamp(CGPoint(x: bot.pos.x + cos(angle) * distance, y: bot.pos.y + sin(angle) * distance))
            if let line = focusLine, abs(p.y - line.midY) < Bot.size { continue }
            if bots.contains(where: { $0 !== bot && hypot($0.destination.x - p.x, $0.destination.y - p.y) < Bot.size * 1.4 }) { continue }
            return p
        }
        return p
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        for bot in bots { bot.startIdleAnimations() }
        // A slow tick that only decides what to do next.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Steps the physics; paused whenever every bot is still.
        let link = displayLink(target: self, selector: #selector(stepFrame(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        self.link = link
    }

    private func wake() {
        guard let link, link.isPaused else { return }
        lastStep = CACurrentMediaTime()
        link.isPaused = false
    }

    @objc private func stepFrame(_ link: CADisplayLink) {
        guard !isHiddenOrHasHiddenAncestor else { link.isPaused = true; return }
        let now = CACurrentMediaTime()
        let dt = min(now - lastStep, 1.0 / 30)
        lastStep = now
        // Small fixed steps keep the springs stable at any frame rate.
        let steps = max(1, Int((dt * 240).rounded(.up)))
        for _ in 0..<steps {
            for bot in bots { bot.step(CGFloat(dt) / CGFloat(steps)) }
        }
        renderAll()
        if bots.allSatisfy(\.isSettled) { link.isPaused = true }
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
            if reduceMotion || bot === guide { continue }   // the guide only moves when the edited line does
            if bot.isResting && now >= bot.nextMove {
                let morph = Double.random(in: 0...1) < 0.25
                    ? BotShape.allCases.filter { $0 != bot.shape }.randomElement()
                    : nil
                bot.hop(to: hopTarget(for: bot), morphingTo: morph)
                bot.nextMove = now + .random(in: 3...7)
                wake()
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
        guide.watch = caret

        switch reason {
        case .scrolled:
            // Ride along with the text. A flight in progress keeps its speed, relative to the line.
            if let previous { guide.shift(dy: lineRect.midY - previous.midY) }
            guide.keep(inside: perchArea)
            renderAll()
        case .edited, .caretMoved:
            let sameLine = previous.map { abs($0.midY - lineRect.midY) < 1 } ?? false
            let current = guide.destination
            let textEnd = max(lineRect.maxX, caret.x)
            if sameLine && textEnd + 4 > current.x - Bot.size / 2 {
                // The text is about to run into it: hop well clear, right away.
                pendingFlight?.cancel()
                flyGuide(lead: 48)
            } else if sameLine && (0...72).contains(current.x - perch().x) {
                wake()                           // close enough; just turn to watch the caret
            } else {
                scheduleFlight(after: 0.25)      // wait for the caret to settle
            }
        }
    }

    /// Where the guide sits: just right of the line's text, plus `lead` extra room.
    private func perch(lead: CGFloat = 0) -> CGPoint {
        guard let line = focusLine else { return guide.pos }
        let x = max(line.maxX, caretPoint.x) + 10 + Bot.size / 2 + lead
        return perchArea.clamp(CGPoint(x: x, y: line.midY))
    }

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
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            guide.appear(at: target)
            renderAll()
        } else {
            guide.fly(to: target)
            wake()
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

// MARK: - Eyes

/// Small eye styles, drawn in design units: the bot is 100 units wide, eyes centered on (0, 0).
enum EyeStyle {
    case beads, beans, happy, sleepy, pixel, sparkle, peepers, cyclops

    /// Happy eyes are already closed arcs, so they don't blink.
    var blinks: Bool { self != .happy }

    func makeLayers() -> [CALayer] {
        let ink = CGColor(gray: 0.106, alpha: 1)   // #1B1D22
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
            CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil)
        }
        func fill(_ path: CGPath, _ color: CGColor) -> CAShapeLayer {
            let l = CAShapeLayer()
            l.path = path
            l.fillColor = color
            return l
        }
        func stroke(_ path: CGPath, width: CGFloat) -> CAShapeLayer {
            let l = CAShapeLayer()
            l.path = path
            l.fillColor = nil
            l.strokeColor = ink
            l.lineWidth = width
            l.lineCap = .round
            return l
        }
        switch self {
        case .beads:
            return [fill(circle(-12, 0, 4.6), ink), fill(circle(12, 0, 4.6), ink)]
        case .beans:
            return [
                fill(CGPath(ellipseIn: CGRect(x: -15.8, y: -6.4, width: 7.6, height: 12.8), transform: nil), ink),
                fill(CGPath(ellipseIn: CGRect(x: 8.2, y: -6.4, width: 7.6, height: 12.8), transform: nil), ink),
                fill(circle(-13.2, -2.6, 1.3), .white), fill(circle(10.8, -2.6, 1.3), .white),
            ]
        case .happy:
            return [-12, 12].map { (cx: CGFloat) in
                let p = CGMutablePath()
                p.move(to: CGPoint(x: cx - 5, y: 2))
                p.addQuadCurve(to: CGPoint(x: cx + 5, y: 2), control: CGPoint(x: cx, y: -5))
                return stroke(p, width: 2.8)
            }
        case .sleepy:
            return [-12, 12].flatMap { (cx: CGFloat) -> [CALayer] in
                // Lower half of a disc (y grows downward), with a lid line on top.
                let lower = CGMutablePath()
                lower.move(to: CGPoint(x: cx - 5.5, y: -0.5))
                lower.addRelativeArc(center: CGPoint(x: cx, y: -0.5), radius: 5.5, startAngle: .pi, delta: -.pi)
                lower.closeSubpath()
                let lid = CGMutablePath()
                lid.move(to: CGPoint(x: cx - 7, y: -1))
                lid.addLine(to: CGPoint(x: cx + 7, y: -1))
                return [fill(lower, ink), stroke(lid, width: 2)]
            }
        case .pixel:
            return [-16, 8].map { (x: CGFloat) in
                fill(CGPath(roundedRect: CGRect(x: x, y: -4, width: 8, height: 8), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil), ink)
            }
        case .sparkle:
            return [
                fill(circle(-12, 0, 5.6), ink), fill(circle(12, 0, 5.6), ink),
                fill(circle(-13.8, -1.9, 1.9), .white), fill(circle(10.2, -1.9, 1.9), .white),
                fill(circle(-10.4, 1.9, 0.9), .white), fill(circle(13.6, 1.9, 0.9), .white),
            ]
        case .peepers:
            return [
                fill(circle(-12, 0, 6.6), .white), fill(circle(12, 0, 6.6), .white),
                fill(circle(-10.6, 1.2, 3), ink), fill(circle(13.4, 1.2, 3), ink),
            ]
        case .cyclops:
            return [fill(circle(0, 0, 10), .white), fill(circle(1.5, 0.8, 4.6), ink)]
        }
    }
}

// MARK: - One bot

@MainActor
private final class Bot {
    static let size: CGFloat = 52
    /// Points per design unit (the designs draw a bot 100 units wide).
    static let unit: CGFloat = size / 100
    static let palette: [CGColor] = [0xFF6B6B, 0xFFA94D, 0xFFD43B, 0x69DB7C, 0x38D9A9, 0x4DABF7, 0x9775FA, 0xF783AC]
        .map { CGColor(srgbRed: CGFloat($0 >> 16) / 255, green: CGFloat($0 >> 8 & 0xFF) / 255,
                       blue: CGFloat($0 & 0xFF) / 255, alpha: 1) }

    // Physics constants.
    static let gravity: CGFloat = 1800            // pt/s², for hops
    static let flyStiffness: CGFloat = 158        // spring with perceptual duration 0.5 s, bounce 0.2: (2π / 0.5)²
    static let flyDamping: CGFloat = 20.1         // 2 × (1 − 0.2) × (2π / 0.5)
    static let jellyStiffness: CGFloat = 560      // squash and stretch wobble
    static let jellyDamping: CGFloat = 13

    let node = CALayer()        // placed and deformed by the simulation every frame
    let bobber = CALayer()      // gentle idle bob (Core Animation)
    let body = CAShapeLayer()
    let eyeHolder = CALayer()   // follows the look offset; scaled to design units
    let eyes = CALayer()        // blinks
    private(set) var shape: BotShape
    let eyeStyle: EyeStyle
    private let colorPhase: Double

    var nextMove = CACurrentMediaTime() + .random(in: 1...4)
    var nextBlink = CACurrentMediaTime() + .random(in: 1...4)

    // Simulation state. Positions are in the overlay's coordinates (y grows downward).
    private(set) var pos = CGPoint.zero
    private var vel = CGVector.zero
    private var flyTarget: CGPoint?
    private var hopTarget: CGPoint?
    private var hopTimeLeft: CGFloat = 0
    private var crouchLeft: CGFloat = 0
    private var pendingHop: (target: CGPoint, morph: BotShape?)?
    private var squash: CGFloat = 0, squashV: CGFloat = 0     // + wider and shorter, − longer, along `axis`
    private var axis = CGVector(dx: 0, dy: 1)
    private var tilt: CGFloat = 0, tiltV: CGFloat = 0
    private var look = CGVector.zero, lookV = CGVector.zero  // eye offset in design units
    private var eyeY: CGFloat
    /// A point to look at while resting (the guide watches the caret).
    var watch: CGPoint?

    /// Where the bot is headed, or where it is when still.
    var destination: CGPoint { flyTarget ?? hopTarget ?? pendingHop?.target ?? pos }
    var isResting: Bool { flyTarget == nil && hopTarget == nil && pendingHop == nil }
    var isSettled: Bool {
        isResting && abs(squash) < 0.002 && abs(squashV) < 0.02 && abs(tilt) < 0.002 && abs(tiltV) < 0.02
            && hypot(lookV.dx, lookV.dy) < 0.05 && hypot(look.dx - lookGoal.dx, look.dy - lookGoal.dy) < 0.05
            && abs(eyeY - eyeYGoal) < 0.05
    }

    private var center: CGPoint { CGPoint(x: Self.size / 2, y: Self.size / 2) }
    private var eyeYGoal: CGFloat { shape == .triangle ? 10 : 3 }

    init(shape: BotShape, eyes eyeStyle: EyeStyle, colorPhase: Double) {
        self.shape = shape
        self.eyeStyle = eyeStyle
        self.colorPhase = colorPhase
        eyeY = shape == .triangle ? 10 : 3
        let bounds = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        node.bounds = bounds
        bobber.frame = bounds
        node.addSublayer(bobber)

        // A stroke in the fill color rounds off the corners.
        body.frame = bounds
        body.path = shape.path(center: center, radius: 38 * Self.unit)
        let color = Self.palette[Int(colorPhase * Double(Self.palette.count)) % Self.palette.count]
        body.fillColor = color
        body.strokeColor = color
        body.lineWidth = 13 * Self.unit
        body.lineJoin = .round
        body.shadowColor = .black
        body.shadowOpacity = 0.28
        body.shadowRadius = 3
        body.shadowOffset = CGSize(width: 0, height: -2)
        bobber.addSublayer(body)

        eyeHolder.setAffineTransform(CGAffineTransform(scaleX: Self.unit, y: Self.unit))
        for layer in eyeStyle.makeLayers() { eyes.addSublayer(layer) }
        eyeHolder.addSublayer(eyes)
        bobber.addSublayer(eyeHolder)
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

    // MARK: Moves

    /// Puts the bot somewhere instantly, stopping any motion.
    func place(at p: CGPoint) {
        pos = p
        vel = .zero
        flyTarget = nil
        hopTarget = nil
        pendingHop = nil
    }

    /// A short hop: crouch, jump on an arc, land with a squash.
    func hop(to target: CGPoint, morphingTo morph: BotShape?) {
        pendingHop = (target, morph)
        crouchLeft = 0.14
    }

    /// A purposeful flight on a spring. Calling it again mid-flight just moves the target;
    /// the bot keeps its speed and curves toward the new spot.
    func fly(to target: CGPoint) {
        flyTarget = target
        hopTarget = nil
        pendingHop = nil
        crouchLeft = 0
    }

    /// Reduced motion: no travel, just fade in at the new spot.
    func appear(at target: CGPoint) {
        place(at: target)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        node.add(fade, forKey: "appear")
    }

    /// Moves with scrolled content, keeping any flight going.
    func shift(dy: CGFloat) {
        pos.y += dy
        flyTarget?.y += dy
    }

    func keep(inside area: CGRect) {
        pos = area.clamp(pos)
        flyTarget = flyTarget.map { area.clamp($0) }
        hopTarget = hopTarget.map { area.clamp($0) }
    }

    private func launch(to target: CGPoint) {
        // A ballistic arc that peaks 28–56 pt above the higher end and lands exactly on target.
        let g = Self.gravity
        let apexY = min(pos.y, target.y) - .random(in: 28...56)
        let vy0 = -sqrt(2 * g * (pos.y - apexY))
        let flightTime = -vy0 / g + sqrt(2 * (target.y - apexY) / g)
        vel = CGVector(dx: (target.x - pos.x) / flightTime, dy: vy0)
        hopTarget = target
        hopTimeLeft = flightTime
        squashV -= 6                                // stretch on takeoff
    }

    // MARK: Simulation

    func step(_ dt: CGFloat) {
        if let pending = pendingHop {
            crouchLeft -= dt
            if crouchLeft <= 0 {
                pendingHop = nil
                if let morph = pending.morph { self.morph(to: morph) }
                launch(to: pending.target)
            }
        }

        if let target = hopTarget {
            vel.dy += Self.gravity * dt
            pos.x += vel.dx * dt
            pos.y += vel.dy * dt
            hopTimeLeft -= dt
            if hopTimeLeft <= 0 {
                pos = target
                squashV += max(vel.dy, 0) * 0.004   // land with a squash
                vel = .zero
                hopTarget = nil
            }
        } else if let target = flyTarget {
            vel.dx += (Self.flyStiffness * (target.x - pos.x) - Self.flyDamping * vel.dx) * dt
            vel.dy += (Self.flyStiffness * (target.y - pos.y) - Self.flyDamping * vel.dy) * dt
            pos.x += vel.dx * dt
            pos.y += vel.dy * dt
            if hypot(target.x - pos.x, target.y - pos.y) < 0.5 && hypot(vel.dx, vel.dy) < 4 {
                pos = target
                vel = .zero
                flyTarget = nil
            }
        }

        // Squash and stretch: crouch before a hop, stretch along fast motion, then wobble back.
        let speed = hypot(vel.dx, vel.dy)
        var goal: CGFloat = 0
        var axisGoal = CGVector(dx: 0, dy: 1)
        if pendingHop != nil {
            goal = 0.2
        } else if speed > 40 {
            goal = -min(speed / 2600, 0.16)
            axisGoal = CGVector(dx: vel.dx / speed, dy: vel.dy / speed)
        }
        if axisGoal.dx * axis.dx + axisGoal.dy * axis.dy < 0 { axisGoal = CGVector(dx: -axisGoal.dx, dy: -axisGoal.dy) }
        let blend = min(1, 12 * dt)
        axis = CGVector(dx: axis.dx + (axisGoal.dx - axis.dx) * blend, dy: axis.dy + (axisGoal.dy - axis.dy) * blend)
        let length = max(hypot(axis.dx, axis.dy), 0.001)
        axis = CGVector(dx: axis.dx / length, dy: axis.dy / length)
        squashV += (-Self.jellyStiffness * (squash - goal) - Self.jellyDamping * squashV) * dt
        squash = min(max(squash + squashV * dt, -0.3), 0.35)

        // Lean into horizontal motion.
        let tiltGoal = speed > 40 ? min(max(vel.dx * 0.0005, -0.3), 0.3) : 0
        tiltV += (-140 * (tilt - tiltGoal) - 12 * tiltV) * dt
        tilt += tiltV * dt

        // Eyes trail the motion, or watch the caret when resting.
        let goalLook = lookGoal
        lookV.dx += (-220 * (look.dx - goalLook.dx) - 20 * lookV.dx) * dt
        lookV.dy += (-220 * (look.dy - goalLook.dy) - 20 * lookV.dy) * dt
        look.dx += lookV.dx * dt
        look.dy += lookV.dy * dt

        eyeY += (eyeYGoal - eyeY) * min(1, 10 * dt)
    }

    private var lookGoal: CGVector {
        let speed = hypot(vel.dx, vel.dy)
        if speed > 40 {
            return CGVector(dx: min(max(vel.dx / 500, -1), 1) * 4, dy: min(max(vel.dy / 800, -1), 1) * 3.5)
        }
        if let watch {
            let dx = watch.x - pos.x, dy = watch.y - pos.y
            let length = max(hypot(dx, dy), 1)
            return CGVector(dx: 4 * dx / length, dy: 3 * dy / length)
        }
        return .zero
    }

    /// Writes the simulation state to the layers. Call inside a transaction with actions disabled.
    func render() {
        // Squash along `axis`: rotate the axis onto x, scale, rotate back, then lean.
        let angle = atan2(axis.dy, axis.dx)
        let deform = CGAffineTransform(rotationAngle: -angle)
            .concatenating(CGAffineTransform(scaleX: 1 - squash, y: 1 + squash))
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(rotationAngle: tilt))
        node.setAffineTransform(deform)
        // Keep the feet planted when squashing vertically.
        let sink = max(squash, 0) * Self.size * 0.4 * abs(axis.dy)
        node.position = CGPoint(x: pos.x, y: pos.y + sink)
        eyeHolder.position = CGPoint(x: center.x + look.dx * Self.unit, y: center.y + (eyeY + look.dy) * Self.unit)
    }

    func morph(to newShape: BotShape) {
        let newPath = newShape.path(center: center, radius: 38 * Self.unit)
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
        squashV -= 3   // a little pop while it changes
    }

    func blink() {
        guard eyeStyle.blinks else { return }
        let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        blink.values = [1, 0.1, 1]
        blink.duration = 0.18
        eyes.add(blink, forKey: "blink")
    }
}
