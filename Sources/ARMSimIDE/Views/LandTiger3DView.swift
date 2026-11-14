import ARMCore
import AppKit
import ModelIO
import SceneKit
import SceneKit.ModelIO
import SwiftUI

/// The LandTiger board in 3D (models imported from the LandTiger Emulator, `LandTiger3D`): the TFT shows the
/// simulated display, LD4-LD11 light up with P2.0-P2.7, and the buttons, joystick, potentiometer and touch
/// panel respond to the mouse. Dragging elsewhere turns the board, the scroll wheel zooms.
final class LandTigerScene {
    let scene: SCNScene
    let camera = SCNNode()
    let layout: LandTiger3D.Layout
    private(set) var lcdMaterial: SCNMaterial?
    private var ledNodes: [SCNNode] = []
    private var buttonMarks: [SCNNode] = []
    private var joystickMark = SCNNode()
    /// Potentiometer: a white notch on the knob, turned from -135° (0) to +135° (full scale).
    private let knobPivot = SCNNode()
    /// Speaker: rings spreading from the grille while the DAC output changes.
    private let speakerWaves = SCNNode()
    private var lastDAC: Int?
    private var lastSound = Date.distantPast
    private var soundPlaying = false
    private var lastFrame: [UInt16]?
    /// The display module's texture atlas (2048²) and, in it, the glass of the TFT (top-left origin).
    private var atlas: CGImage?
    static let atlasSize = 2048
    static let screenRect = CGRect(x: 83.0 / 2, y: 83.0 / 2, width: 638.0 / 2, height: 903.0 / 2)

    init?() {
        let dir = LandTiger3D.directory
        let url = dir.appendingPathComponent("LANDTIGER/Board (LCD).obj")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        scene = SCNScene(mdlAsset: asset)
        layout = LandTiger3D.layout()
        var lcd: SCNMaterial?
        scene.rootNode.enumerateChildNodes { node, _ in
            for material in node.geometry?.materials ?? [] where material.name == "Top" { lcd = material }
        }
        lcdMaterial = lcd
        if let source = CGImageSourceCreateWithURL(dir.appendingPathComponent("LANDTIGER/lcd_texture.tga") as CFURL, nil) {
            atlas = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: Self.atlasSize] as CFDictionary)
        }
        // Lights: soft ambient plus a key light from above the front edge.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 650
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 550
        key.eulerAngles = SCNVector3(-1.0, 0.25, 0)
        scene.rootNode.addChildNode(key)
        camera.camera = SCNCamera()
        camera.camera!.zNear = 0.005
        camera.camera!.zFar = 50
        camera.camera!.fieldOfView = 38
        camera.position = SCNVector3(0, 0.78, 0.5)
        camera.look(at: SCNVector3(0, -0.02, 0.03))
        scene.rootNode.addChildNode(camera)

        func glow(_ color: NSColor) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = color
            m.emission.contents = color
            return m
        }
        for p in layout.leds {
            // The lit diode: a bright red body above the LED, with an additive halo.
            let box = SCNBox(width: 0.0068, height: 0.006, length: 0.0115, chamferRadius: 0.001)
            box.materials = [glow(NSColor(calibratedRed: 1, green: 0.3, blue: 0.22, alpha: 1))]
            let node = SCNNode(geometry: box)
            node.position = SCNVector3(p.x, p.y + 0.003, p.z)
            node.isHidden = true
            let halo = SCNNode(geometry: SCNPlane(width: 0.011, height: 0.019))
            let haloMaterial = glow(NSColor(calibratedRed: 1, green: 0.12, blue: 0.05, alpha: 0.6))
            haloMaterial.blendMode = .add
            haloMaterial.writesToDepthBuffer = false
            halo.geometry!.materials = [haloMaterial]
            halo.eulerAngles.x = -.pi / 2
            halo.position = SCNVector3(0, 0.0032, 0)
            node.addChildNode(halo)
            scene.rootNode.addChildNode(node)
            ledNodes.append(node)
        }
        func mark(_ radius: CGFloat) -> SCNNode {
            let disc = SCNNode(geometry: SCNCylinder(radius: radius, height: 0.0008))
            disc.geometry!.materials = [glow(NSColor(calibratedRed: 1, green: 0.85, blue: 0.1, alpha: 0.55))]
            disc.isHidden = true
            scene.rootNode.addChildNode(disc)
            return disc
        }
        for p in layout.buttons {
            let m = mark(0.0085)
            m.position = SCNVector3(p.x, p.y + 0.002, p.z)
            buttonMarks.append(m)
        }
        joystickMark = mark(0.006)

        if layout.knobRadius > 0 {
            let length = CGFloat(layout.knobRadius) * 0.85
            let notch = SCNNode(geometry: SCNBox(width: 0.0018, height: 0.0008, length: length, chamferRadius: 0.0003))
            notch.geometry!.materials = [glow(NSColor(calibratedWhite: 0.95, alpha: 1))]
            notch.position = SCNVector3(0, 0, -length / 2)   // from the centre towards the back of the board
            knobPivot.addChildNode(notch)
            knobPivot.position = SCNVector3(layout.knob.x, layout.knob.y + 0.0006, layout.knob.z)
            scene.rootNode.addChildNode(knobPivot)
        }
        if let speaker = layout.speaker {
            speakerWaves.position = SCNVector3(speaker.x, speaker.y + 0.002, speaker.z)
            speakerWaves.isHidden = true
            for i in 0..<3 {
                let ring = SCNNode(geometry: SCNTorus(ringRadius: CGFloat(layout.speakerRadius) * 0.9, pipeRadius: 0.0009))
                let m = glow(NSColor(calibratedRed: 0.35, green: 0.75, blue: 1, alpha: 1))
                m.blendMode = .add
                ring.geometry!.materials = [m]
                ring.opacity = 0
                ring.name = "wave\(i)"
                speakerWaves.addChildNode(ring)
            }
            scene.rootNode.addChildNode(speakerWaves)
        }
    }

    /// Knob position for the potentiometer value (0...1).
    private func setPotentiometer(_ value: Double) {
        knobPivot.eulerAngles.y = CGFloat(-(value - 0.5) * 1.5 * .pi)
    }

    /// Starts or stops the speaker rings: on while the DAC output keeps changing.
    private func setSound(dac: Int?) {
        guard layout.speaker != nil else { return }
        if let dac, let last = lastDAC, dac != last { lastSound = Date() }
        lastDAC = dac
        let playing = Date().timeIntervalSince(lastSound) < 0.3
        guard playing != soundPlaying else { return }
        soundPlaying = playing
        speakerWaves.isHidden = !playing
        for (i, ring) in speakerWaves.childNodes.enumerated() {
            ring.removeAllActions()
            ring.opacity = 0
            guard playing else { continue }
            let wave = SCNAction.sequence([
                .run { node in node.scale = SCNVector3(0.55, 1, 0.55); node.opacity = 0.9 },
                .group([.scale(to: 1.6, duration: 0.9), .fadeOut(duration: 0.9)]),
            ])
            ring.runAction(.sequence([.wait(duration: 0.3 * Double(i)), .repeatForever(wave)]))
        }
        if playing {
            // Stop by itself once the output stops changing (no further update may come).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.setSound(dac: self?.lastDAC) }
        }
    }

    /// Board state: P2 pins / directions (LEDs), the TFT frame, held buttons (0 INT0, 1 KEY1, 2 KEY2) and joystick.
    func update(pins: UInt32, direction: UInt32, frame: [UInt16]?, buttons: Set<Int>, joystick: Set<Int>,
                potentiometer: Double = 0.5, dac: Int? = nil) {
        setPotentiometer(potentiometer)
        setSound(dac: dac)
        for (bit, node) in ledNodes.enumerated() {
            node.isHidden = !(direction & (1 << UInt32(bit)) != 0 && pins & (1 << UInt32(bit)) != 0)
        }
        if frame != lastFrame {
            lastFrame = frame
            if let image = composeDisplay(frame) { lcdMaterial?.diffuse.contents = image }
        }
        // Button marks, left to right: KEY1, KEY2, INT0 (RESET has no EINT).
        for (i, eint) in [1, 2, 0].enumerated() where i < buttonMarks.count { buttonMarks[i].isHidden = !buttons.contains(eint) }
        if let direction = joystick.first, let held = LPC17xx.Joystick(rawValue: direction) {
            let c = layout.joystick
            let d: Float = 0.013
            let offset: (Float, Float)
            switch held {
            case .up: offset = (0, -d)
            case .down: offset = (0, d)
            case .left: offset = (-d, 0)
            case .right: offset = (d, 0)
            case .select: offset = (0, 0)
            }
            joystickMark.position = SCNVector3(c.x + offset.0, c.y + 0.002, c.z + offset.1)
            joystickMark.isHidden = false
        } else {
            joystickMark.isHidden = true
        }
    }

    /// The display module's atlas with the TFT frame drawn on its glass (black glass when the TFT is off).
    private func composeDisplay(_ frame: [UInt16]?) -> CGImage? {
        guard let atlas else { return nil }
        let size = Self.atlasSize
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(atlas, in: CGRect(x: 0, y: 0, width: size, height: size))
        let r = Self.screenRect
        let target = CGRect(x: r.minX, y: CGFloat(size) - r.maxY, width: r.width, height: r.height)   // CG origin: bottom left
        ctx.interpolationQuality = .none
        if let frame, let image = LCDImage.make(frame) {
            // The glass is mapped upside down in the atlas: turn the frame by 180°.
            ctx.saveGState()
            ctx.translateBy(x: target.midX, y: target.midY)
            ctx.rotate(by: .pi)
            ctx.draw(image, in: CGRect(x: -target.width / 2, y: -target.height / 2, width: target.width, height: target.height))
            ctx.restoreGState()
        } else {
            ctx.setFillColor(CGColor(gray: 0.06, alpha: 1))
            ctx.fill(target)
        }
        return ctx.makeImage()
    }

    // MARK: Picking

    enum Control: Equatable {
        case button(eint: Int)
        case reset
        case joystick(LPC17xx.Joystick)
        case potentiometer
        case touch(x: Int, y: Int)
    }

    /// The control under a hit on the board.
    func control(at hit: SCNHitTestResult) -> Control? {
        if let material = hit.node.geometry?.materials[safe: hit.geometryIndex], material === lcdMaterial {
            // Texture coordinates -> atlas pixel -> TFT pixel; only the glass is touch sensitive.
            let uv = hit.textureCoordinates(withMappingChannel: 0)
            let p = CGPoint(x: uv.x * CGFloat(Self.atlasSize), y: uv.y * CGFloat(Self.atlasSize))
            let r = Self.screenRect
            guard r.contains(p) else { return nil }
            // 180°, as the frame is drawn.
            let x = min(Int((p.x - r.minX) / r.width * CGFloat(LandTigerLCD.width)), LandTigerLCD.width - 1)
            let y = min(Int((p.y - r.minY) / r.height * CGFloat(LandTigerLCD.height)), LandTigerLCD.height - 1)
            return .touch(x: LandTigerLCD.width - 1 - x, y: LandTigerLCD.height - 1 - y)
        }
        let w = hit.worldCoordinates
        let p = SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z))
        func flat(_ a: SIMD3<Float>) -> Float { simd_length(SIMD2(a.x - p.x, a.z - p.z)) }
        if let (i, b) = layout.buttons.enumerated().min(by: { flat($0.element) < flat($1.element) }).map({ ($0.offset, $0.element) }),
           flat(b) < 0.016 {
            return i < 3 ? .button(eint: [1, 2, 0][i]) : .reset
        }
        if flat(layout.joystick) < 0.026 {
            let dx = p.x - layout.joystick.x, dz = p.z - layout.joystick.z
            if max(abs(dx), abs(dz)) < 0.006 { return .joystick(.select) }
            if abs(dx) > abs(dz) { return .joystick(dx > 0 ? .right : .left) }
            return .joystick(dz > 0 ? .down : .up)
        }
        if flat(layout.potentiometer) < 0.035 { return .potentiometer }
        return nil
    }
}

/// SCNView that sends clicks on the board's controls to the simulator and lets other drags turn the camera.
final class LandTigerSCNView: SCNView {
    var board: LandTigerScene?
    var debugger: DebugController?
    private var active: LandTigerScene.Control?
    private var potentiometerStart: (x: CGFloat, value: Double)?

    private func hit(_ event: NSEvent) -> SCNHitTestResult? {
        let point = convert(event.locationInWindow, from: nil)
        return hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue]).first
    }

    override func mouseDown(with event: NSEvent) {
        guard let board, let debugger, let hit = hit(event), let control = board.control(at: hit) else {
            active = nil
            return super.mouseDown(with: event)
        }
        active = control
        press(control, debugger)
        if control == .potentiometer { potentiometerStart = (event.locationInWindow.x, debugger.potentiometer) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let active, let debugger else { return super.mouseDragged(with: event) }
        switch active {
        case .touch:
            if let hit = hit(event), case .touch(let x, let y)? = board?.control(at: hit) { debugger.setTouch((x: x, y: y)) }
        case .potentiometer:
            if let start = potentiometerStart {
                debugger.setPotentiometer(min(max(start.value + Double(event.locationInWindow.x - start.x) / 250, 0), 1))
            }
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let active, let debugger else { return super.mouseUp(with: event) }
        switch active {
        case .button(let eint): debugger.setButton(eint, pressed: false)
        case .joystick(let d): debugger.setJoystick(d, pressed: false)
        case .touch: debugger.setTouch(nil)
        default: break
        }
        self.active = nil
        potentiometerStart = nil
    }

    private func press(_ control: LandTigerScene.Control, _ debugger: DebugController) {
        switch control {
        case .button(let eint): debugger.setButton(eint, pressed: true)
        case .reset: debugger.reset()
        case .joystick(let d): debugger.setJoystick(d, pressed: true)
        case .touch(let x, let y): debugger.setTouch((x: x, y: y))
        case .potentiometer: break
        }
    }
}

struct LandTiger3DView: NSViewRepresentable {
    @ObservedObject var debugger: DebugController

    func makeNSView(context: Context) -> LandTigerSCNView {
        let view = LandTigerSCNView()
        view.board = LandTigerScene()
        view.debugger = debugger
        view.scene = view.board?.scene
        view.pointOfView = view.board?.camera
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = NSColor(calibratedWhite: 0.93, alpha: 1)
        return view
    }

    func updateNSView(_ view: LandTigerSCNView, context: Context) {
        let s = debugger.snapshot
        view.board?.update(pins: s.gpioPins.count == 5 ? s.gpioPins[2] : 0, direction: s.gpioDirection.count == 5 ? s.gpioDirection[2] : 0,
                           frame: debugger.lcdFrame, buttons: debugger.buttonsHeld, joystick: debugger.joystickHeld,
                           potentiometer: debugger.potentiometer, dac: debugger.lpc.map { Int($0.dac.value) })
    }
}

/// LandTiger window, 3D tab: the board, or how to import its models.
struct LandTiger3DPanel: View {
    @ObservedObject var debugger = Workspace.shared.debugger
    @LocalState private var installed = LandTiger3D.isInstalled
    @LocalState private var error: String?
    @LocalState private var importing = false

    var body: some View {
        if installed {
            VStack(spacing: 4) {
                LandTiger3DView(debugger: debugger)
                Text("Click the buttons, joystick and TFT; drag the potentiometer sideways. Drag the board to turn it, scroll to zoom.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            .frame(minWidth: 800, minHeight: 560)
        } else {
            VStack(spacing: 12) {
                Text("3D board").font(.system(size: 14, weight: .semibold))
                Text("""
                The 3D LandTiger comes from the LandTiger Emulator of the Politecnico di Torino course \
                (Gabriele and Federico Filipponi), which ARM Sim does not include. Import it from your copy \
                of the emulator: its emulatore_v1.2.3.rar (or .zip), or the folder extracted from it. \
                Only the board models are copied, into ~/Library/Application Support/ARM Sim/LandTiger3D.
                """)
                .font(.system(size: 11)).foregroundColor(.secondary).multilineTextAlignment(.center).frame(width: 460)
                Button(importing ? "Importing…" : "Import from LandTiger Emulator…") { chooseSource() }.disabled(importing)
                if let error { Text(error).font(.system(size: 11)).foregroundColor(.red).frame(width: 460) }
            }
            .frame(minWidth: 800, minHeight: 360)
        }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose the LandTiger Emulator archive (.rar / .zip) or its folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try LandTiger3D.importModels(from: url) }
            DispatchQueue.main.async {
                importing = false
                switch result {
                case .success: installed = LandTiger3D.isInstalled
                case .failure(let e): error = "\(e)"
                }
            }
        }
    }
}
