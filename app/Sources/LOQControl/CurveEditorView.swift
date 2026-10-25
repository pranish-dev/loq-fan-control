import SwiftUI
import LOQCore

/// Interactive curve editor: drag points, double-click empty space to add a point.
/// X axis = temperature (°C), Y axis = fan RPM. Points can't cross their neighbours,
/// and speed can't drop as temperature rises.
struct CurveEditorView: View {
    @EnvironmentObject var model: ControlModel
    @State private var dragIndex: Int?
    @State private var gestureActive = false
    @State private var startedOnObject = false
    @State private var lastClick: (time: Date, point: CGPoint)?

    private let tMin = ControlModel.tempMin
    private let tMax = ControlModel.tempMax
    private let yMin = 1500.0
    private let yMax = 5500.0
    private let pad = EdgeInsets(top: 14, leading: 56, bottom: 34, trailing: 16)

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: pad.leading, y: pad.top,
                              width: max(geo.size.width - pad.leading - pad.trailing, 10),
                              height: max(geo.size.height - pad.top - pad.bottom, 10))
            Canvas { context, size in
                drawPlot(&context, plot: plot, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in handleDrag(v, plot: plot) }
                    .onEnded { v in handleEnd(v, plot: plot) }
            )
        }
    }

    // MARK: coordinate mapping

    private func px(_ t: Double, _ plot: CGRect) -> CGFloat {
        plot.minX + CGFloat((t - tMin) / (tMax - tMin)) * plot.width
    }

    private func py(_ rpm: Double, _ plot: CGRect) -> CGFloat {
        plot.maxY - CGFloat((rpm - yMin) / (yMax - yMin)) * plot.height
    }

    private func temperature(at x: CGFloat, plot: CGRect) -> Double {
        tMin + Double((x - plot.minX) / plot.width) * (tMax - tMin)
    }

    private func rpm(at y: CGFloat, plot: CGRect) -> Double {
        yMin + Double((plot.maxY - y) / plot.height) * (yMax - yMin)
    }

    // MARK: interaction

    // Click a point to drag it. Click ON the line to insert a point there and drag it.
    // Double-click empty space inside the graph to insert a point at that position.
    private func handleDrag(_ v: DragGesture.Value, plot: CGRect) {
        if !gestureActive {
            gestureActive = true
            startedOnObject = false
            dragIndex = pointIndex(near: v.startLocation, plot: plot)
            if dragIndex != nil {
                startedOnObject = true
            } else if plot.contains(v.startLocation),
                      distanceToCurve(v.startLocation, plot: plot) < 10 {
                startedOnObject = true
                dragIndex = model.addPoint(temp: temperature(at: v.startLocation.x, plot: plot))
            }
        }
        guard let i = dragIndex else { return }
        model.movePoint(i,
                        temp: temperature(at: v.location.x, plot: plot),
                        rpm: Int(rpm(at: v.location.y, plot: plot)))
    }

    private func handleEnd(_ v: DragGesture.Value, plot: CGRect) {
        let onObject = startedOnObject
        gestureActive = false
        startedOnObject = false
        dragIndex = nil

        guard !onObject else { lastClick = nil; return }
        let moved = hypot(v.translation.width, v.translation.height)
        guard moved < 4, plot.contains(v.location) else { lastClick = nil; return }

        let now = Date()
        if let last = lastClick,
           now.timeIntervalSince(last.time) < 0.5,
           hypot(v.location.x - last.point.x, v.location.y - last.point.y) < 12 {
            lastClick = nil
            if let idx = model.addPoint(temp: temperature(at: v.location.x, plot: plot)) {
                model.movePoint(idx,
                                temp: temperature(at: v.location.x, plot: plot),
                                rpm: Int(rpm(at: v.location.y, plot: plot)))
            }
        } else {
            lastClick = (now, v.location)
        }
    }

    private func pointIndex(near location: CGPoint, plot: CGRect) -> Int? {
        var best: (index: Int, dist: CGFloat)?
        for (i, p) in model.draft.points.enumerated() {
            let d = hypot(px(p.temp, plot) - location.x, py(Double(p.rpm), plot) - location.y)
            if d < 16, d < (best?.dist ?? .infinity) { best = (i, d) }
        }
        return best?.index
    }

    private func curvePolyline(_ plot: CGRect) -> [CGPoint] {
        let pts = model.draft.points
        guard let f = pts.first, let l = pts.last else { return [] }
        var out = [CGPoint(x: px(tMin, plot), y: py(Double(f.rpm), plot))]
        out += pts.map { CGPoint(x: px($0.temp, plot), y: py(Double($0.rpm), plot)) }
        out.append(CGPoint(x: px(tMax, plot), y: py(Double(l.rpm), plot)))
        return out
    }

    private func distanceToCurve(_ p: CGPoint, plot: CGRect) -> CGFloat {
        let line = curvePolyline(plot)
        guard line.count >= 2 else { return .infinity }
        var best = CGFloat.infinity
        for k in 0..<(line.count - 1) {
            best = min(best, distance(from: p, toSegment: line[k], line[k + 1]))
        }
        return best
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: drawing

    private func drawPlot(_ ctx: inout GraphicsContext, plot: CGRect, size: CGSize) {
        // Card background behind the whole canvas
        let bg = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
        ctx.fill(Path(roundedRect: bg, cornerRadius: 12),
                 with: .color(Color.primary.opacity(0.035)))
        ctx.stroke(Path(roundedRect: bg, cornerRadius: 12),
                   with: .color(Color.primary.opacity(0.08)), lineWidth: 1)

        // Grid + axis labels
        for t in stride(from: tMin, through: tMax, by: 10.0) {
            var p = Path()
            p.move(to: CGPoint(x: px(t, plot), y: plot.minY))
            p.addLine(to: CGPoint(x: px(t, plot), y: plot.maxY))
            ctx.stroke(p, with: .color(Color.primary.opacity(0.06)), lineWidth: 0.5)
            ctx.draw(Text("\(Int(t))°").font(.caption2).foregroundColor(.secondary),
                     at: CGPoint(x: px(t, plot), y: plot.maxY + 14))
        }
        for r in stride(from: 1500.0, through: 5500.0, by: 500.0) {
            var p = Path()
            p.move(to: CGPoint(x: plot.minX, y: py(r, plot)))
            p.addLine(to: CGPoint(x: plot.maxX, y: py(r, plot)))
            ctx.stroke(p, with: .color(Color.primary.opacity(0.06)), lineWidth: 0.5)
            ctx.draw(Text("\(Int(r))").font(.caption2).foregroundColor(.secondary),
                     at: CGPoint(x: plot.minX - 8, y: py(r, plot)), anchor: .trailing)
        }
        ctx.draw(Text("RPM").font(.caption2).foregroundColor(.secondary),
                 at: CGPoint(x: plot.minX - 8, y: plot.minY - 2), anchor: .trailing)
        ctx.draw(Text("Temperature (°C)").font(.caption2).foregroundColor(.secondary),
                 at: CGPoint(x: plot.maxX, y: plot.maxY + 26), anchor: .trailing)

        // Emergency temperature line
        let em = model.draft.emergencyTemp
        var emPath = Path()
        emPath.move(to: CGPoint(x: px(em, plot), y: plot.minY))
        emPath.addLine(to: CGPoint(x: px(em, plot), y: plot.maxY))
        ctx.stroke(emPath, with: .color(Color.red.opacity(0.65)),
                   style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        ctx.draw(Text("emergency \(Int(em))°").font(.caption2).foregroundColor(.red),
                 at: CGPoint(x: px(em, plot) - 4, y: plot.minY + 8), anchor: .trailing)

        // Curve line (flat before the first point and after the last one)
        let pts = model.draft.points
        guard let first = pts.first, let last = pts.last else { return }
        var line = Path()
        line.move(to: CGPoint(x: px(tMin, plot), y: py(Double(first.rpm), plot)))
        for p in pts { line.addLine(to: CGPoint(x: px(p.temp, plot), y: py(Double(p.rpm), plot))) }
        line.addLine(to: CGPoint(x: px(tMax, plot), y: py(Double(last.rpm), plot)))

        // Soft fill under the curve
        var area = line
        area.addLine(to: CGPoint(x: px(tMax, plot), y: plot.maxY))
        area.addLine(to: CGPoint(x: px(tMin, plot), y: plot.maxY))
        area.closeSubpath()
        ctx.fill(area, with: .linearGradient(
            Gradient(colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.02)]),
            startPoint: CGPoint(x: 0, y: plot.minY),
            endPoint: CGPoint(x: 0, y: plot.maxY)))

        // Current temperature marker
        if let t = model.currentTemp {
            var m = Path()
            m.move(to: CGPoint(x: px(t, plot), y: plot.minY))
            m.addLine(to: CGPoint(x: px(t, plot), y: plot.maxY))
            ctx.stroke(m, with: .color(Color.orange),
                       style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            ctx.draw(Text(String(format: "now %.0f°", t)).font(.caption2).foregroundColor(.orange),
                     at: CGPoint(x: px(t, plot) + 4, y: plot.maxY - 8), anchor: .leading)
        }

        // Where the fans are being driven right now (custom curve mode only)
        if model.activeMode == .customCurve, let ft = model.filteredTemp, model.commandedRPM > 0 {
            let c = CGPoint(x: px(ft, plot), y: py(Double(model.commandedRPM), plot))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20)),
                     with: .color(Color.orange.opacity(0.22)))
            let dot = CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
            ctx.fill(Path(ellipseIn: dot), with: .color(Color.orange))
            ctx.stroke(Path(ellipseIn: dot), with: .color(Color.white), lineWidth: 1.5)
        }

        // The curve itself, with a soft glow (drawLayer isolates the shadow filter)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: Color.accentColor.opacity(0.45), radius: 3, y: 1))
            layer.stroke(line, with: .color(.accentColor),
                         style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }

        // Draggable points
        for (i, p) in pts.enumerated() {
            let active = (i == dragIndex)
            let r: CGFloat = active ? 8 : 6
            let c = CGPoint(x: px(p.temp, plot), y: py(Double(p.rpm), plot))
            if active {
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r - 4, y: c.y - r - 4, width: (r + 4) * 2, height: (r + 4) * 2)),
                         with: .color(Color.accentColor.opacity(0.25)))
            }
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(Color.accentColor))
            ctx.stroke(Path(ellipseIn: rect), with: .color(Color.white), lineWidth: 1.5)
        }
    }
}
