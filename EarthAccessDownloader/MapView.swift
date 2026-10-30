//
//  MapView.swift
//  EarthAccessDownloader
//
//  An interactive map of the scene outlines (from catalog metadata, so nothing extra is
//  downloaded) and the search area. Clicking an outline highlights its row in the list.
//

import MapKit
import SwiftUI

/// A scene outline to draw.
struct Footprint: Equatable {
    let id: String
    let name: String
    let coordinates: [CLLocationCoordinate2D]
    let instrument: String
    let highlighted: Bool

    static func == (a: Footprint, b: Footprint) -> Bool {
        a.id == b.id && a.highlighted == b.highlighted
    }
}

/// Gives SwiftUI access to the map for converting between view points and coordinates.
final class MapHandle {
    weak var map: MKMapView?
    /// Set when the user draws a region, so the map doesn't re-frame under them.
    var skipNextFrame = false

    func coordinate(at point: CGPoint) -> CLLocationCoordinate2D? {
        guard let map else { return nil }
        let y = map.isFlipped ? point.y : map.bounds.height - point.y
        return map.convert(CGPoint(x: point.x, y: y), toCoordinateFrom: map)
    }
}

struct ResultsMap: View {
    @Bindable var model: SearchViewModel
    @State private var handle = MapHandle()
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?

    private var footprints: [Footprint] {
        let highlighted = model.highlightedGranuleIDs
        return model.mapGranules.compactMap { g in
            guard let ring = g.footprint, ring.count >= 3 else { return nil }
            return Footprint(id: g.id, name: g.name,
                             coordinates: ring.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) },
                             instrument: g.displayInstrument, highlighted: highlighted.contains(g.id))
        }
    }

    var body: some View {
        // Reading the location fields here redraws the search area as the form is edited.
        let search = model.hasLocation ? try? model.location() : nil
        MapRepresentable(footprints: footprints, search: search, basemap: model.mapBasemap, handle: handle) { id, extend in
            model.selectOnMap(granuleID: id, extend: extend)
        }
        .overlay { if model.isSelectingRegion { regionPicker } }
    }

    /// Captures a drag over the map, draws it as a rubber band, and turns it into the search rectangle.
    private var regionPicker: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { drag in
                        dragStart = drag.startLocation
                        dragEnd = drag.location
                    }
                    .onEnded { drag in
                        commitRegion(from: drag.startLocation, to: drag.location)
                        dragStart = nil
                        dragEnd = nil
                    })
            if let a = dragStart, let b = dragEnd {
                Rectangle()
                    .fill(Color.red.opacity(0.1))
                    .overlay(Rectangle().stroke(Color.red, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                    .frame(width: abs(a.x - b.x), height: abs(a.y - b.y))
                    .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    .allowsHitTesting(false)
            }
            Text("Drag to draw the search rectangle")
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    private func commitRegion(from a: CGPoint, to b: CGPoint) {
        // The two dragged corners are opposite corners of the rectangle, in either order.
        guard let c1 = handle.coordinate(at: a), let c2 = handle.coordinate(at: b) else { return }
        func lon(_ v: Double) -> Double {  // wrap into -180...180 (the map can be panned past the date line)
            let wrapped = (v + 180).truncatingRemainder(dividingBy: 360)
            return (wrapped < 0 ? wrapped + 360 : wrapped) - 180
        }
        func lat(_ v: Double) -> Double { min(max(v, -90), 90) }
        let west = lon(min(c1.longitude, c2.longitude)), east = lon(max(c1.longitude, c2.longitude))
        let south = lat(min(c1.latitude, c2.latitude)), north = lat(max(c1.latitude, c2.latitude))
        handle.skipNextFrame = true
        model.setRegion(west: west, south: south, east: east, north: north)
        model.isSelectingRegion = false
    }
}

private final class FootprintPolygon: MKPolygon {
    var footprint: Footprint?
}

private final class SearchAreaPolygon: MKPolygon {}

private struct MapRepresentable: NSViewRepresentable {
    let footprints: [Footprint]
    let search: SearchLocation?
    let basemap: MapBasemap
    let handle: MapHandle
    let onSelect: (String, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        handle.map = map
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        map.addGestureRecognizer(click)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.onSelect = onSelect
        c.footprints = footprints
        // Satellite imagery with place labels, so the scene outlines can still be located.
        map.mapType = basemap == .satellite ? .hybrid : .standard

        // Redraw only when something visible changed.
        let key = footprints.map { "\($0.id)\($0.highlighted ? "*" : "")" }.joined(separator: ",")
            + "|" + String(describing: search?.json)
        guard key != c.drawnKey else { return }
        let granulesChanged = footprints.map(\.id) != c.drawnIDs
        c.drawnKey = key
        c.drawnIDs = footprints.map(\.id)

        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        for f in footprints {
            let polygon = FootprintPolygon(coordinates: f.coordinates, count: f.coordinates.count)
            polygon.footprint = f
            map.addOverlay(polygon)
        }
        var searchRect: MKMapRect?
        switch search {
        case let .point(lon, lat)?:
            let pin = MKPointAnnotation()
            pin.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            pin.title = "Search point"
            map.addAnnotation(pin)
            searchRect = MKMapRect(origin: MKMapPoint(pin.coordinate), size: MKMapSize(width: 0, height: 0))
        case let .bbox(w, s, e, n)?:
            let corners = [(s, w), (s, e), (n, e), (n, w)]
                .map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }
            let polygon = SearchAreaPolygon(coordinates: corners, count: 4)
            map.addOverlay(polygon)
            searchRect = polygon.boundingMapRect
        case nil:
            break
        }

        // Re-frame when the set of scenes changes, or while there are no scenes yet.
        let skipFrame = handle.skipNextFrame
        handle.skipNextFrame = false
        if !skipFrame && (granulesChanged || footprints.isEmpty || !c.hasFramed) {
            let rects = map.overlays.map(\.boundingMapRect) + (searchRect.map { [$0] } ?? [])
            if let first = rects.first {
                var union = rects.dropFirst().reduce(first) { $0.union($1) }
                if union.size.width == 0 && union.size.height == 0 {  // a lone point: show some context
                    union = union.insetBy(dx: -20_000, dy: -20_000)
                }
                map.setVisibleMapRect(union, edgePadding: NSEdgeInsets(top: 30, left: 30, bottom: 30, right: 30),
                                      animated: c.hasFramed)
                c.hasFramed = true
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onSelect: (String, Bool) -> Void = { _, _ in }
        var footprints: [Footprint] = []
        var drawnKey = ""
        var drawnIDs: [String] = []
        var hasFramed = false

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polygon = overlay as? MKPolygon else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolygonRenderer(polygon: polygon)
            if let f = (polygon as? FootprintPolygon)?.footprint {
                let color = NSColor(f.instrument.instrumentColor)
                renderer.strokeColor = color
                renderer.fillColor = color.withAlphaComponent(f.highlighted ? 0.45 : 0.15)
                renderer.lineWidth = f.highlighted ? 3 : 1
            } else {
                renderer.strokeColor = .systemRed
                renderer.fillColor = NSColor.systemRed.withAlphaComponent(0.05)
                renderer.lineWidth = 2
                renderer.lineDashPattern = [6, 4]
            }
            return renderer
        }

        @objc func clicked(_ gesture: NSClickGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let coordinate = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            // Of the outlines under the click, prefer the smallest so scenes stacked on a larger one stay reachable.
            let hit = footprints
                .filter { Self.contains($0.coordinates, coordinate) }
                .min { Self.area($0.coordinates) < Self.area($1.coordinates) }
            if let hit { onSelect(hit.id, NSEvent.modifierFlags.contains(.command)) }
        }

        private static func contains(_ ring: [CLLocationCoordinate2D], _ p: CLLocationCoordinate2D) -> Bool {
            var inside = false
            var j = ring.count - 1
            for i in ring.indices {
                let a = ring[i], b = ring[j]
                if (a.latitude > p.latitude) != (b.latitude > p.latitude),
                   p.longitude < (b.longitude - a.longitude) * (p.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }

        private static func area(_ ring: [CLLocationCoordinate2D]) -> Double {
            var sum = 0.0
            var j = ring.count - 1
            for i in ring.indices {
                sum += (ring[j].longitude + ring[i].longitude) * (ring[j].latitude - ring[i].latitude)
                j = i
            }
            return abs(sum / 2)
        }
    }
}
