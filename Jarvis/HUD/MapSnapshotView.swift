import SwiftUI
import MapKit
import JarvisCore

/// A place, drawn as a still image.
///
/// `MKMapSnapshotter` rather than a live `Map`: the HUD is a floating panel
/// that ignores mouse events, so nobody can pan or zoom it anyway, and a
/// snapshot is a bitmap that costs nothing to keep on screen. A live map view
/// inside a non-activating panel also renders its own gesture and attribution
/// furniture that has nowhere to go here.
///
/// Rendered in dark mode explicitly — the HUD is always dark regardless of the
/// system setting, and a daylight map in it looks like a hole punched in the
/// panel.
struct MapSnapshotView: View {
    let place: MapPlace

    @State private var image: NSImage?
    @State private var failed = false

    private static let height: CGFloat = 132

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .overlay(alignment: .center) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(HUDTheme.accent)
                            .shadow(color: .black.opacity(0.6), radius: 3)
                    }
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .overlay {
                        Image(systemName: failed ? "map" : "ellipsis")
                            .font(.system(size: 14))
                            .foregroundStyle(HUDTheme.inkTertiary)
                    }
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .clipped()
        .task(id: place) { await load() }
        .accessibilityLabel(place.label.map { "Map of \($0)" } ?? "Map")
    }

    private func load() async {
        guard let snapshot = await Self.snapshot(of: place, width: HUDTheme.width - 34) else {
            failed = true
            return
        }
        image = snapshot
    }

    /// `MKMapSnapshotter` is callback-based and its result is not `Sendable`,
    /// so the bridge happens here and only the finished bitmap escapes.
    private static func snapshot(of place: MapPlace, width: CGFloat) async -> NSImage? {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
            latitudinalMeters: place.spanMetres,
            longitudinalMeters: place.spanMetres
        )
        options.size = CGSize(width: width, height: height)
        options.appearance = NSAppearance(named: .darkAqua)
        options.pointOfInterestFilter = .includingAll

        return await withCheckedContinuation { continuation in
            MKMapSnapshotter(options: options).start(with: .global(qos: .userInitiated)) {
                snapshot, _ in
                continuation.resume(returning: snapshot?.image)
            }
        }
    }
}

/// A photo from the web, fetched once and kept.
///
/// The URL comes from the model, which is the only thing in this app that
/// reaches an arbitrary host — so it is bounded on every axis that matters:
/// https only (enforced at parse time), no cookies or credentials, a short
/// timeout, a size cap, and it must decode as an image before anything is
/// shown. A failure draws nothing rather than a broken-image glyph.
struct RemoteImageView: View {
    let url: URL

    @State private var image: NSImage?
    @State private var failed = false

    private static let height: CGFloat = 148
    private static let maximumBytes = 8 * 1024 * 1024

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: Self.height)
                    .frame(maxWidth: .infinity)
                    .clipped()
            } else if !failed {
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .frame(height: Self.height)
                    .overlay {
                        ProgressView().controlSize(.small)
                    }
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        // Nothing about this fetch should carry identity.
        request.httpShouldHandleCookies = false
        request.setValue(nil, forHTTPHeaderField: "Cookie")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= Self.maximumBytes,
              let decoded = NSImage(data: data) else {
            failed = true
            return
        }
        ImageCache.shared.store(decoded, for: url)
        image = decoded
    }
}

/// Small and in-memory. A HUD image is looked at for seconds and the same one
/// rarely comes back, so there is nothing here worth writing to disk.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, NSImage>()
    private init() { cache.countLimit = 24 }

    func image(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    func store(_ image: NSImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}
