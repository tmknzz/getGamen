import Foundation

public enum RegionGeometry {
    /// Authoritative global AppKit endpoints. Do not reconstruct right/top from derived sizes.
    private struct Edges {
        let left: Double
        let right: Double
        let bottom: Double
        let top: Double
        var width: Double { right - left }
        var height: Double { top - bottom }
        func intersection(_ other: Edges) -> Edges? {
            let result = Edges(left: max(left, other.left), right: min(right, other.right),
                               bottom: max(bottom, other.bottom), top: min(top, other.top))
            return result.left < result.right && result.bottom < result.top ? result : nil
        }
    }
    private struct Surface {
        let display: RegionDisplay
        let edges: Edges
    }
    private struct SnappedTile {
        let surface: Surface
        let source: RegionRect
        let pixels: PixelSize
        let global: Edges
    }

    public static func select(drag: RegionRect, displays: [RegionDisplay]) throws -> RegionSelection {
        let topology = try surfaces(displays)
        let raw = try canonicalRaw(try edges(drag, signed: true), surfaces: topology)
        let participants = topology.filter { $0.edges.intersection(raw) != nil }
        guard let anchor = participants.first else { throw RegionGeometryError.noDisplayIntersection }
        let local = RegionRect(x: try finite(raw.left - anchor.edges.left),
                               y: try finite(anchor.edges.top - raw.top), width: raw.width, height: raw.height)
        let references = try participants.map { surface in
            let d = surface.display
            return RegionDisplayReference(id: d.id,
                relativeX: try finite(surface.edges.left - anchor.edges.left),
                relativeY: try finite(surface.edges.bottom - anchor.edges.bottom),
                width: d.frame.width, height: d.frame.height, scale: d.scale,
                rotation: d.rotation, backingWidth: d.backingWidth, backingHeight: d.backingHeight,
                mirrorSourceID: d.mirrorSourceID)
        }
        let selection = RegionSelection(schemaVersion: 1, anchorID: anchor.display.id,
                                        dragInAnchor: local, displays: references)
        // A selected region must also admit a finite, representable capture plan.
        _ = try plan(selection: selection, displays: displays)
        return selection
    }

    public static func dragRect(for selection: RegionSelection, displays: [RegionDisplay]) throws -> RegionRect {
        _ = try plan(selection: selection, displays: displays)
        guard let anchor = displays.first(where: { $0.id == selection.anchorID }) else {
            throw RegionGeometryError.topologyChanged
        }
        let anchorEdges = try edges(anchor.frame)
        let local = selection.dragInAnchor
        let left = try finite(anchorEdges.left + local.x)
        let top = try finite(anchorEdges.top - local.y)
        return RegionRect(x: left, y: try finite(top - local.height), width: local.width, height: local.height)
    }

    public static func plan(selection: RegionSelection, displays: [RegionDisplay]) throws -> RegionCapturePlan {
        guard selection.schemaVersion == 1 else {
            throw RegionGeometryError.unsupportedVersion(selection.schemaVersion)
        }
        let topology = try surfaces(displays)
        try validateReferences(selection)
        guard let anchor = topology.first(where: { $0.display.id == selection.anchorID }) else {
            throw RegionGeometryError.topologyChanged
        }
        let lookup = Dictionary(uniqueKeysWithValues: topology.map { ($0.display.id, $0) })
        for reference in selection.displays {
            guard let surface = lookup[reference.id] else { throw RegionGeometryError.topologyChanged }
            let d = surface.display
            guard reference.relativeX == surface.edges.left - anchor.edges.left,
                  reference.relativeY == surface.edges.bottom - anchor.edges.bottom,
                  reference.width == d.frame.width, reference.height == d.frame.height,
                  reference.scale == d.scale, reference.rotation == d.rotation,
                  reference.backingWidth == d.backingWidth, reference.backingHeight == d.backingHeight,
                  reference.mirrorSourceID == d.mirrorSourceID else { throw RegionGeometryError.topologyChanged }
        }
        let local = selection.dragInAnchor
        _ = try edges(local)
        let left = try finite(anchor.edges.left + local.x)
        let top = try finite(anchor.edges.top - local.y)
        let restored = Edges(left: left, right: try finite(left + local.width),
                             bottom: try finite(top - local.height), top: top)
        let raw = try canonicalRaw(restored, surfaces: topology)
        let participants = topology.filter { $0.edges.intersection(raw) != nil }
        guard participants.map(\.display.id) == selection.displays.map(\.id) else {
            throw RegionGeometryError.topologyChanged
        }
        guard let scale = participants.map(\.display.scale).max() else {
            throw RegionGeometryError.noDisplayIntersection
        }
        let tiles = try participants.map { try snap($0, raw: raw) }
        let union = Edges(left: min(raw.left, tiles.map(\.global.left).min()!),
                          right: max(raw.right, tiles.map(\.global.right).max()!),
                          bottom: min(raw.bottom, tiles.map(\.global.bottom).min()!),
                          top: max(raw.top, tiles.map(\.global.top).max()!))
        try validExtent(union)
        let l = try integer(integerSnap(try scaled(union.left - anchor.edges.left, scale)).rounded(.down))
        let t = try integer(integerSnap(try scaled(anchor.edges.top - union.top, scale)).rounded(.down))
        let r = try integer(integerSnap(try scaled(union.right - anchor.edges.left, scale)).rounded(.up))
        let b = try integer(integerSnap(try scaled(anchor.edges.top - union.bottom, scale)).rounded(.up))
        let output = try size(width: subtract(r, l), height: subtract(b, t))
        var xEdges: [Double: Int] = [:]
        var yEdges: [Double: Int] = [:]
        func x(_ edge: Double) throws -> Int {
            if let value = xEdges[edge] { return value }
            let value = try subtract(integer(tieSnap(try scaled(edge - anchor.edges.left, scale))
                .rounded(.toNearestOrAwayFromZero)), l)
            xEdges[edge] = value
            return value
        }
        func y(_ edge: Double) throws -> Int {
            if let value = yEdges[edge] { return value }
            let value = try subtract(integer(tieSnap(try scaled(anchor.edges.top - edge, scale))
                .rounded(.toNearestOrAwayFromZero)), t)
            yEdges[edge] = value
            return value
        }
        var result: [RegionTile] = []
        for tile in tiles {
            let left = try x(tile.global.left), right = try x(tile.global.right)
            let top = try y(tile.global.top), bottom = try y(tile.global.bottom)
            let width = try subtract(right, left), height = try subtract(bottom, top)
            guard left >= 0, top >= 0, right <= output.width, bottom <= output.height,
                  width > 0, height > 0 else { throw RegionGeometryError.invalidGeometry }
            let destination = RegionPixelRect(x: left, y: top, width: width, height: height)
            for other in result {
                let d = other.destination
                if left < d.x + d.width && right > d.x && top < d.y + d.height && bottom > d.y {
                    throw RegionGeometryError.invalidGeometry
                }
            }
            result.append(RegionTile(displayID: tile.surface.display.id, runtimeID: tile.surface.display.runtimeID,
                                     sourceRect: tile.source, pixelSize: tile.pixels, destination: destination))
        }
        return RegionCapturePlan(selection: selection, outputSize: output, outputScale: scale, tiles: result)
    }

    /// Bounded serialization uncertainty, never a broad intersection tolerance.
    /// Both initial selection and restoration use the same authoritative display edges.
    private static func canonicalRaw(_ raw: Edges, surfaces: [Surface]) throws -> Edges {
        try validExtent(raw)
        var horizontal: [Double: Double] = [:]
        var vertical: [Double: Double] = [:]
        for surface in surfaces {
            let scale = surface.display.scale
            for edge in [surface.edges.left, surface.edges.right] {
                horizontal[edge] = max(horizontal[edge] ?? scale, scale)
            }
            for edge in [surface.edges.bottom, surface.edges.top] {
                vertical[edge] = max(vertical[edge] ?? scale, scale)
            }
        }
        func canonical(_ value: Double, candidates: [Double: Double]) -> Double {
            var chosen = value
            var distance = Double.infinity
            for (edge, scale) in candidates {
                let delta = abs(value - edge)
                let tolerance = min(4 * max(value.ulp, edge.ulp), 1e-9 / scale)
                guard delta <= tolerance else { continue }
                if delta < distance || (delta == distance && edge < chosen) {
                    chosen = edge
                    distance = delta
                }
            }
            return chosen
        }
        let result = Edges(left: canonical(raw.left, candidates: horizontal),
                           right: canonical(raw.right, candidates: horizontal),
                           bottom: canonical(raw.bottom, candidates: vertical),
                           top: canonical(raw.top, candidates: vertical))
        try validExtent(result)
        return result
    }

    private static func surfaces(_ displays: [RegionDisplay]) throws -> [Surface] {
        var ids = Set<String>(), runtimeIDs = Set<UInt32>()
        var all: [String: Surface] = [:]
        for display in displays {
            guard !display.id.isEmpty, ids.insert(display.id).inserted,
                  display.runtimeID != 0, runtimeIDs.insert(display.runtimeID).inserted else {
                throw RegionGeometryError.invalidDisplayIdentity
            }
            try signature(width: display.frame.width, height: display.frame.height, scale: display.scale,
                          rotation: display.rotation, backingWidth: display.backingWidth, backingHeight: display.backingHeight)
            all[display.id] = Surface(display: display, edges: try edges(display.frame))
        }
        for surface in all.values {
            if let sourceID = surface.display.mirrorSourceID {
                guard let source = all[sourceID], source.display.mirrorSourceID == sourceID,
                      source.display.frame == surface.display.frame else { throw RegionGeometryError.invalidDisplayIdentity }
            }
        }
        let canonical = all.values.filter {
            $0.display.mirrorSourceID == nil || $0.display.mirrorSourceID == $0.display.id
        }.sorted { $0.display.id < $1.display.id }
        for index in canonical.indices {
            for other in canonical.prefix(index) where canonical[index].edges.intersection(other.edges) != nil {
                throw RegionGeometryError.ambiguousOverlap
            }
        }
        return canonical
    }

    private static func validateReferences(_ selection: RegionSelection) throws {
        guard !selection.anchorID.isEmpty, !selection.displays.isEmpty,
              selection.displays.map(\.id) == selection.displays.map(\.id).sorted(),
              selection.displays.first?.id == selection.anchorID else { throw RegionGeometryError.invalidDisplayIdentity }
        var ids = Set<String>()
        for ref in selection.displays {
            guard !ref.id.isEmpty, ids.insert(ref.id).inserted,
                  ref.mirrorSourceID == nil || ref.mirrorSourceID == ref.id else {
                throw RegionGeometryError.invalidDisplayIdentity
            }
            try signature(width: ref.width, height: ref.height, scale: ref.scale, rotation: ref.rotation,
                          backingWidth: ref.backingWidth, backingHeight: ref.backingHeight)
            _ = try edges(RegionRect(x: ref.relativeX, y: ref.relativeY, width: ref.width, height: ref.height))
            if ref.id == selection.anchorID && (ref.relativeX != 0 || ref.relativeY != 0) {
                throw RegionGeometryError.invalidGeometry
            }
        }
    }

    private static func signature(width: Double, height: Double, scale: Double, rotation: Double,
                                  backingWidth: Int, backingHeight: Int) throws {
        guard width.isFinite, height.isFinite, scale.isFinite, rotation.isFinite,
              width > 0, height > 0, scale > 0, rotation >= 0, rotation < 360 else {
            throw RegionGeometryError.invalidGeometry
        }
        _ = try size(width: backingWidth, height: backingHeight)
    }

    private static func snap(_ surface: Surface, raw: Edges) throws -> SnappedTile {
        let d = surface.display, e = surface.edges
        guard let i = e.intersection(raw) else { throw RegionGeometryError.noDisplayIntersection }
        let lx = try finite(i.left - e.left), rx = try finite(i.right - e.left)
        let ty = try finite(e.top - i.top), by = try finite(e.top - i.bottom)
        func outward(_ value: Double, up: Bool, limit: Double) throws -> (point: Double, native: Double) {
            let grid = integerSnap(try scaled(value, d.scale)).rounded(up ? .up : .down)
            let point = try finite(grid / d.scale)
            if up && point > limit {
                // A genuine clamp may end between pixels; retain its native-coordinate extent.
                return (limit, integerSnap(try scaled(limit, d.scale)))
            }
            if !up && point < 0 { return (0, 0) }
            return (point, grid)
        }
        let left = try outward(lx, up: false, limit: d.frame.width)
        let right = try outward(rx, up: true, limit: d.frame.width)
        let top = try outward(ty, up: false, limit: d.frame.height)
        let bottom = try outward(by, up: true, limit: d.frame.height)
        let l = left.point, r = right.point, t = top.point, b = bottom.point
        let width = try finite(r - l), height = try finite(b - t)
        guard width > 0, height > 0 else { throw RegionGeometryError.invalidGeometry }
        func nativeLength(_ start: Double, _ end: Double) throws -> Int {
            if start.rounded() == start && end.rounded() == end {
                // Subtract retained grid integers, not divided point values multiplied back.
                return try subtract(integer(end), integer(start))
            }
            return try integer(integerSnap(try finite(end - start)).rounded(.up))
        }
        let pixels = try size(width: nativeLength(left.native, right.native),
                              height: nativeLength(top.native, bottom.native))
        // Clamped and unchanged intersection edges keep their original endpoint bits.
        let gl = l == 0 ? e.left : (l == lx ? i.left : try finite(e.left + l))
        let gr = r == d.frame.width ? e.right : (r == rx ? i.right : try finite(e.left + r))
        let gt = t == 0 ? e.top : (t == ty ? i.top : try finite(e.top - t))
        let gb = b == d.frame.height ? e.bottom : (b == by ? i.bottom : try finite(e.top - b))
        let global = Edges(left: gl, right: gr, bottom: gb, top: gt)
        try validExtent(global)
        return SnappedTile(surface: surface, source: RegionRect(x: l, y: t, width: width, height: height),
                           pixels: pixels, global: global)
    }

    private static func edges(_ rect: RegionRect, signed: Bool = false) throws -> Edges {
        guard [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite),
              signed ? (rect.width != 0 && rect.height != 0) : (rect.width > 0 && rect.height > 0) else {
            throw RegionGeometryError.invalidGeometry
        }
        let endX = try finite(rect.x + rect.width), endY = try finite(rect.y + rect.height)
        let result = Edges(left: min(rect.x, endX), right: max(rect.x, endX),
                           bottom: min(rect.y, endY), top: max(rect.y, endY))
        try validExtent(result)
        return result
    }
    private static func validExtent(_ edges: Edges) throws {
        _ = try finite(edges.width); _ = try finite(edges.height)
        guard edges.width > 0, edges.height > 0 else { throw RegionGeometryError.invalidGeometry }
    }
    private static func finite(_ value: Double) throws -> Double {
        guard value.isFinite else { throw RegionGeometryError.arithmeticOverflow }
        return value
    }
    private static func scaled(_ value: Double, _ scale: Double) throws -> Double {
        _ = try finite(value)
        return try finite(value * scale)
    }
    private static func integer(_ value: Double) throws -> Int {
        guard let result = Int(exactly: value) else { throw RegionGeometryError.arithmeticOverflow }
        return result
    }
    private static func subtract(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.subtractingReportingOverflow(rhs)
        guard !result.overflow else { throw RegionGeometryError.arithmeticOverflow }
        return result.partialValue
    }
    private static func size(width: Int, height: Int) throws -> PixelSize {
        guard width > 0, height > 0 else { throw RegionGeometryError.invalidGeometry }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow, !pixels.partialValue.multipliedReportingOverflow(by: 4).overflow else {
            throw RegionGeometryError.arithmeticOverflow
        }
        return PixelSize(width: width, height: height)
    }

    static func integerSnap(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        let nearest = value.rounded(.toNearestOrAwayFromZero)
        let tolerance = min(4 * max(value.ulp, nearest.ulp), 1e-9)
        return abs(value - nearest) <= tolerance ? nearest : value
    }
    static func tieSnap(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        let floorValue = value.rounded(.down), half = floorValue + 0.5
        if half.isFinite, half - floorValue == 0.5,
           abs(value - half) <= min(4 * max(value.ulp, half.ulp), 1e-9) { return half }
        return integerSnap(value)
    }
}
