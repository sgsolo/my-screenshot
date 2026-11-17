import AppKit
import Carbon

enum SelectionMode {
    case screenshot, recording

    var minimumSize: CGFloat { self == .recording ? 32 : 8 }
}

struct WindowSuggestions {
    let bounds: [CGRect]
    let focused: CGRect?

    func window(at point: CGPoint) -> CGRect? {
        bounds.first { $0.contains(point) }
    }
}

struct FrozenFrame {
    let image: CGImage
    let size: CGSize

    @MainActor
    func render(_ selection: CGRect, annotations: [CaptureAnnotation]) throws -> CGImage {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let scaleX = imageBounds.width / size.width
        let scaleY = imageBounds.height / size.height
        let pixels = selection.applying(.init(scaleX: scaleX, y: scaleY)).integral.intersection(imageBounds)
        guard !pixels.isEmpty, let cropped = image.cropping(to: pixels) else {
            throw CaptureError.invalidSelection
        }
        guard !annotations.isEmpty else { return cropped }
        let colorSpace = cropped.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: cropped.width, height: cropped.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.imageWriteFailed
        }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        context.translateBy(x: -pixels.minX, y: pixels.height + pixels.minY)
        context.scaleBy(x: scaleX, y: -scaleY)
        context.clip(to: selection)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for annotation in annotations { annotation.draw(in: context) }
        NSGraphicsContext.restoreGraphicsState()
        guard let result = context.makeImage() else { throw CaptureError.imageWriteFailed }
        return result
    }
}

private enum CaptureTool: Int, CaseIterable {
    case arrow, pen, line, rectangle, ellipse, text, eraser

    var title: String {
        switch self {
        case .pen: "Карандаш"
        case .arrow: "Стрелка"
        case .line: "Линия"
        case .rectangle: "Прямоугольник"
        case .ellipse: "Овал"
        case .text: "Текст"
        case .eraser: "Ластик"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .text: "textformat"
        case .eraser: "eraser"
        }
    }
}

private func rectangle(between start: CGPoint, and end: CGPoint) -> CGRect {
    CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
           width: abs(end.x - start.x), height: abs(end.y - start.y))
}

struct CaptureAnnotation {
    fileprivate let tool: CaptureTool
    fileprivate let color: NSColor
    fileprivate var points: [CGPoint]
    fileprivate var text = ""

    private var path: CGPath {
        let path = CGMutablePath()
        let start = points[0]
        let end = points[points.count - 1]
        switch tool {
        case .pen:
            path.addLines(between: points)
            if start == end && points.count == 1 {
                path.addLine(to: CGPoint(x: start.x + 0.1, y: start.y))
            }
        case .rectangle: path.addRect(rectangle(between: start, and: end))
        case .ellipse: path.addEllipse(in: rectangle(between: start, and: end))
        case .line, .arrow:
            path.move(to: start)
            path.addLine(to: end)
            let length = hypot(end.x - start.x, end.y - start.y)
            if tool == .arrow && length > 0 {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let head = min(16, length * 0.4)
                for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                    path.move(to: end)
                    path.addLine(to: CGPoint(x: end.x - head * cos(angle + offset),
                                             y: end.y - head * sin(angle + offset)))
                }
            }
        default: break
        }
        return path
    }

    private var label: NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 23, weight: .bold),
            .foregroundColor: color, .strokeColor: color == NSColor.white ? NSColor.black : NSColor.white,
            .strokeWidth: -2.5
        ])
    }

    @MainActor
    func draw(in context: CGContext) {
        if tool == .text {
            label.draw(at: points[0])
        } else {
            context.saveGState()
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(3)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path)
            context.strokePath()
            context.restoreGState()
        }
    }

    @MainActor
    func contains(_ point: CGPoint) -> Bool {
        if tool == .text {
            return CGRect(origin: points[0], size: label.size()).insetBy(dx: -5, dy: -5).contains(point)
        }
        return path.copy(strokingWithWidth: 15, lineCap: .round, lineJoin: .round, miterLimit: 3)
            .contains(point)
    }
}

@MainActor
final class SelectionView: NSView {
    private enum Drag {
        case select(CGPoint, window: CGRect?)
        case move(CGPoint, CGRect)
        case resize(CGVector, CGPoint, CGRect)
        case draw
        case erase([CaptureAnnotation])
    }

    private let mode: SelectionMode
    private let windows: WindowSuggestions
    private let completion: (CGRect?, [CaptureAnnotation], Bool) -> Void
    private let preview: NSImage
    private let toolbar = NSVisualEffectView()
    private let tools = NSSegmentedControl()
    private let colorMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let textField = NSTextField()
    private let colors: [(String, NSColor)] = [
        ("Красный", .systemRed), ("Жёлтый", .systemYellow), ("Зелёный", .systemGreen),
        ("Синий", .systemBlue), ("Белый", .white), ("Чёрный", .black)
    ]
    private var undoButton: NSButton!
    private var sizeLabel: NSTextField!
    private var toolbarTop: NSLayoutConstraint!
    private var toolbarCenter: NSLayoutConstraint!
    private var selection = CGRect.zero
    private var suggestedWindow: CGRect?
    private var initialPointer: CGPoint?
    private var pointerTracking: NSTrackingArea?
    private var drag: Drag?
    private var tool: CaptureTool?
    private var selectedColor = 0
    private var annotations: [CaptureAnnotation] = []
    private var pending: CaptureAnnotation?
    private var undoHistory: [[CaptureAnnotation]] = []

    init(frame: FrozenFrame, mode: SelectionMode, windows: WindowSuggestions,
         completion: @escaping (CGRect?, [CaptureAnnotation], Bool) -> Void) {
        self.mode = mode
        self.windows = windows
        self.completion = completion
        preview = NSImage(cgImage: frame.image, size: frame.size)
        super.init(frame: CGRect(origin: .zero, size: frame.size))
        installToolbar()
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTracking = area
    }

    func suggestInitialWindow(at point: CGPoint) {
        initialPointer = point
        suggest(windows.window(at: point) ?? windows.focused)
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil, selection.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let initialPointer, hypot(point.x - initialPointer.x, point.y - initialPointer.y) < 1 { return }
        initialPointer = nil
        suggest(windows.window(at: point))
    }

    override func mouseExited(with event: NSEvent) {
        if drag == nil, selection.isEmpty { suggest(nil) }
    }

    private func suggest(_ rect: CGRect?) {
        guard suggestedWindow != rect else { return }
        suggestedWindow = rect
        needsDisplay = true
    }

    private func installToolbar() {
        toolbar.material = .hudWindow
        toolbar.state = .active
        toolbar.blendingMode = .withinWindow
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 12
        toolbar.layer?.masksToBounds = true
        toolbar.isHidden = true
        addSubview(toolbar)

        let done: NSButton
        if mode == .screenshot {
            let title = Bundle.main.localizedString(forKey: "capture.save", value: "Save", table: nil)
            done = NSButton(title: title, target: self, action: #selector(confirmSelection))
            done.bezelStyle = .rounded
            done.toolTip = "⌘C — сохранить и скопировать снимок"
        } else {
            done = iconButton("record.circle", title: "Начать запись", action: #selector(confirmSelection))
            done.contentTintColor = .systemRed
        }
        done.bezelColor = .controlAccentColor
        let cancel = iconButton("xmark", title: "Отмена", action: #selector(cancelSelection))
        sizeLabel = NSTextField(labelWithString: "")
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .centerX
        rows.spacing = 5
        if mode == .screenshot {
            tools.segmentCount = CaptureTool.allCases.count
            tools.trackingMode = .selectOne
            for tool in CaptureTool.allCases {
                let image = tool == .pen ? pencilIcon(title: tool.title) : icon(tool.symbol, title: tool.title)
                tools.setImage(image, forSegment: tool.rawValue)
                tools.setToolTip(tool.title, forSegment: tool.rawValue)
                tools.setWidth(34, forSegment: tool.rawValue)
            }
            tools.selectedSegment = -1
            tools.target = self
            tools.action = #selector(changeTool)
            rows.addArrangedSubview(tools)

            installColorMenu()
            textField.placeholderString = "Текст пометки"
            textField.toolTip = "Введите текст и щёлкните по снимку"
            textField.setAccessibilityLabel("Текст пометки")
            textField.widthAnchor.constraint(equalToConstant: 146).isActive = true
            textField.target = self
            textField.action = #selector(focusCanvas)
            textField.isHidden = true
            undoButton = iconButton("arrow.uturn.backward", title: "Отменить пометку",
                                    action: #selector(undoAnnotation))
            undoButton.isEnabled = false
            rows.addArrangedSubview(NSStackView(views: [sizeLabel, colorMenu, textField, undoButton, cancel, done]))
        } else {
            rows.addArrangedSubview(NSStackView(views: [sizeLabel, cancel, done]))
        }
        rows.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            rows.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            rows.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 9),
            rows.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -9)
        ])
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbarTop = toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 42)
        toolbarCenter = toolbar.centerXAnchor.constraint(equalTo: centerXAnchor)
        NSLayoutConstraint.activate([toolbarCenter, toolbarTop])
    }

    private func icon(_ name: String, title: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
            ?? NSImage(size: CGSize(width: 15, height: 15))
    }

    private func pencilIcon(title: String) -> NSImage {
        let image = NSImage(size: CGSize(width: 19, height: 19), flipped: false) { _ in
            let segments: [[CGPoint]] = [
                [.init(x: 1.5, y: 1.5), .init(x: 3.2, y: 6.3), .init(x: 6.3, y: 3.2)],
                [.init(x: 4.2, y: 7.3), .init(x: 12.7, y: 15.8),
                 .init(x: 15.8, y: 12.7), .init(x: 7.3, y: 4.2)],
                [.init(x: 13.7, y: 16.8), .init(x: 15.3, y: 18.4), .init(x: 16.3, y: 18.4),
                 .init(x: 18.4, y: 16.3), .init(x: 18.4, y: 15.3), .init(x: 16.8, y: 13.7)]
            ]
            NSColor.black.setFill()
            for segment in segments {
                let path = NSBezierPath()
                path.move(to: segment[0])
                for point in segment.dropFirst() { path.line(to: point) }
                path.close()
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = title
        return image
    }

    private func iconButton(_ name: String, title: String, action: Selector) -> NSButton {
        let button = NSButton(image: icon(name, title: title), target: self, action: action)
        button.bezelStyle = .rounded
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }

    private func installColorMenu() {
        colorMenu.addItem(withTitle: "")
        for (index, option) in colors.enumerated() {
            let item = NSMenuItem(title: option.0, action: #selector(chooseColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = colorIcon(option.1)
            colorMenu.menu?.addItem(item)
        }
        updateColorMenu()
    }

    private func colorIcon(_ color: NSColor) -> NSImage {
        NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            color.setFill()
            circle.fill()
            NSColor.labelColor.withAlphaComponent(0.45).setStroke()
            circle.stroke()
            return true
        }
    }

    @objc private func chooseColor(_ item: NSMenuItem) {
        selectedColor = item.tag
        updateColorMenu()
        focusCanvasUnlessEditingText()
    }

    private func updateColorMenu() {
        let (name, color) = colors[selectedColor]
        let description = "Цвет пометок: \(name)"
        colorMenu.item(at: 0)?.image = colorIcon(color)
        colorMenu.toolTip = description
        colorMenu.setAccessibilityLabel(description)
    }

    @objc private func changeTool() {
        guard let selected = CaptureTool(rawValue: tools.selectedSegment) else { return }
        tool = selected
        textField.isHidden = tool != .text
        focusCanvasUnlessEditingText()
        positionToolbar()
    }

    private func focusCanvasUnlessEditingText() {
        if tool == .text {
            window?.makeFirstResponder(textField)
        } else {
            focusCanvas()
        }
    }

    @objc private func focusCanvas() { window?.makeFirstResponder(self) }

    @objc private func confirmSelection() {
        if !toolbar.isHidden && drag == nil { completion(selection, annotations, false) }
    }

    func copyAndSave() -> Bool {
        guard mode == .screenshot, !toolbar.isHidden, drag == nil else { return false }
        completion(selection, annotations, true)
        return true
    }

    @objc private func cancelSelection() { completion(nil, [], false) }

    @objc private func undoAnnotation() {
        guard drag == nil, let previous = undoHistory.popLast() else { return }
        annotations = previous
        undoButton.isEnabled = !undoHistory.isEmpty
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        focusCanvas()
        let point = convert(event.locationInWindow, from: nil)
        if let edge = resizeDirection(at: point) {
            drag = .resize(edge, point, selection)
            return
        }
        guard selection.contains(point) else {
            drag = .select(point, window: windows.window(at: point))
            return
        }
        guard let tool, !event.modifierFlags.contains(.option) else {
            drag = .move(point, selection)
            return
        }
        let color = colors[selectedColor].1
        switch tool {
        case .text:
            let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                window?.makeFirstResponder(textField)
                return
            }
            addAnnotation(CaptureAnnotation(tool: .text, color: color, points: [point], text: text))
        case .eraser:
            drag = .erase(annotations)
            erase(at: point)
        default:
            drag = .draw
            pending = CaptureAnnotation(tool: tool, color: color, points: [point])
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .select(let start, let window):
            if window != nil, hypot(point.x - start.x, point.y - start.y) < 4 { return }
            self.drag = .select(start, window: nil)
            if selection.isEmpty || toolbar.isHidden || start != point {
                selection = rectangle(between: start, and: point).intersection(bounds)
            }
        case .move(let start, let original):
            selection.origin = CGPoint(
                x: min(max(original.minX + point.x - start.x, bounds.minX), bounds.maxX - original.width),
                y: min(max(original.minY + point.y - start.y, bounds.minY), bounds.maxY - original.height)
            )
        case .resize(let direction, let start, let original):
            let minimum = mode.minimumSize
            let dx = point.x - start.x
            let dy = point.y - start.y
            let x1 = direction.dx < 0 ? max(bounds.minX, min(original.minX + dx, original.maxX - minimum)) : original.minX
            let x2 = direction.dx > 0 ? min(bounds.maxX, max(original.maxX + dx, original.minX + minimum)) : original.maxX
            let y1 = direction.dy < 0 ? max(bounds.minY, min(original.minY + dy, original.maxY - minimum)) : original.minY
            let y2 = direction.dy > 0 ? min(bounds.maxY, max(original.maxY + dy, original.minY + minimum)) : original.maxY
            selection = CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
        case .draw:
            let end = CGPoint(x: min(max(point.x, selection.minX), selection.maxX),
                              y: min(max(point.y, selection.minY), selection.maxY))
            if pending?.tool == .pen || pending?.points.count == 1 {
                if pending?.points.last != end { pending?.points.append(end) }
            } else {
                pending?.points[1] = end
            }
        case .erase:
            if selection.contains(point) { erase(at: point) }
        }
        updateSelection()
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        mouseDragged(with: event)
        guard let drag else { return }
        switch drag {
        case .select(_, let window):
            if let window { selection = window }
        case .draw:
            if let pending, pending.tool == .pen || pending.points.count == 2 { addAnnotation(pending) }
            pending = nil
        case .erase(let previous):
            if previous.count != annotations.count { undoHistory.append(previous) }
        default: break
        }
        self.drag = nil
        if selection.width < mode.minimumSize || selection.height < mode.minimumSize { selection = .zero }
        if selection.isEmpty { suggest(windows.window(at: convert(event.locationInWindow, from: nil))) }
        updateSelection()
        positionToolbar()
    }

    private func positionToolbar() {
        guard !toolbar.isHidden else { return }
        layoutSubtreeIfNeeded()
        let upperLimit = bounds.minY + 42
        let lowerLimit = max(upperLimit, bounds.maxY - toolbar.frame.height - 16)
        toolbarTop.constant = min(max(upperLimit, selection.maxY + 12), lowerLimit)

        let horizontalInset = min(toolbar.frame.width / 2 + 12, bounds.width / 2)
        let center = min(max(selection.midX, bounds.minX + horizontalInset), bounds.maxX - horizontalInset)
        toolbarCenter.constant = center - bounds.midX
    }

    private func addAnnotation(_ annotation: CaptureAnnotation) {
        undoHistory.append(annotations)
        annotations.append(annotation)
        undoButton.isEnabled = true
        needsDisplay = true
    }

    private func erase(at point: CGPoint) {
        if let hit = annotations.lastIndex(where: { $0.contains(point) }) { annotations.remove(at: hit) }
        needsDisplay = true
    }

    private func updateSelection() {
        toolbar.isHidden = selection.width < mode.minimumSize || selection.height < mode.minimumSize
        if !toolbar.isHidden {
            sizeLabel.stringValue = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
        }
        undoButton?.isEnabled = !undoHistory.isEmpty
        needsDisplay = true
    }

    private func resizeDirection(at point: CGPoint) -> CGVector? {
        let hitWidth: CGFloat = 8
        guard !toolbar.isHidden, selection.insetBy(dx: -hitWidth, dy: -hitWidth).contains(point) else { return nil }

        func edge(at value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
            // Reserve room in the middle for drawing even on a small selection.
            let inset = min(hitWidth, (high - low) / 4)
            if value <= low + inset { return -1 }
            if value >= high - inset { return 1 }
            return 0
        }
        let x = edge(at: point.x, low: selection.minX, high: selection.maxX)
        let y = edge(at: point.y, low: selection.minY, high: selection.maxY)
        return x == 0 && y == 0 ? nil : CGVector(dx: x, dy: y)
    }

    private var handles: [CGPoint] {
        [-1, 0, 1].flatMap { x in
            [-1, 0, 1].compactMap { y in
                guard x != 0 || y != 0 else { return nil }
                return CGPoint(x: selection.midX + CGFloat(x) * selection.width / 2,
                               y: selection.midY + CGFloat(y) * selection.height / 2)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case UInt16(kVK_Escape): cancelSelection()
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            if selection.isEmpty, drag == nil, let window = suggestedWindow ?? windows.focused {
                selection = window
                updateSelection()
                positionToolbar()
            } else {
                confirmSelection()
            }
        default: super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) { cancelSelection() }

    override func draw(_ dirtyRect: NSRect) {
        preview.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        drawCaptureShade(in: bounds, excluding: selection.isEmpty ? suggestedWindow : selection)

        if !selection.isEmpty {
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.clip(to: selection)
                for annotation in annotations { annotation.draw(in: context) }
                pending?.draw(in: context)
                context.restoreGState()
            }
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
            if !toolbar.isHidden {
                for handle in handles {
                    let dot = NSBezierPath(ovalIn: CGRect(x: handle.x - 4, y: handle.y - 4, width: 8, height: 8))
                    NSColor.white.setFill()
                    dot.fill()
                    NSColor.black.withAlphaComponent(0.7).setStroke()
                    dot.stroke()
                }
            }
        } else {
            if let suggestedWindow {
                let outline = NSBezierPath(rect: suggestedWindow.insetBy(dx: 1, dy: 1))
                outline.lineWidth = 2
                outline.setLineDash([5, 4], count: 2, phase: 0)
                NSColor.systemBlue.setStroke()
                outline.stroke()
            }
            let instruction = windows.bounds.isEmpty
                ? "Выделите область  ·  Esc — отмена"
                : "Щелчок — окно  ·  Перетаскивание — область  ·  Esc — отмена"
            let hint = NSAttributedString(string: instruction, attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white
            ])
            let size = hint.size()
            let box = CGRect(x: (bounds.width - size.width) / 2 - 14, y: 47,
                             width: size.width + 28, height: size.height + 14)
            NSColor.black.withAlphaComponent(0.76).setFill()
            NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9).fill()
            hint.draw(at: CGPoint(x: box.minX + 14, y: box.minY + 7))
        }
    }
}
@MainActor
func drawCaptureShade(in bounds: CGRect, excluding region: CGRect?) {
    let shade = NSBezierPath(rect: bounds)
    if let region { shade.appendRect(region) }
    shade.windingRule = .evenOdd
    NSColor.black.withAlphaComponent(0.34).setFill()
    shade.fill()
}
