#if DEBUG && os(tvOS)
import FeatureLiveTVCore
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV

@MainActor
final class LiveTVChannelBrowserTests: XCTestCase {
    func testLargeChannelBrowserUsesRecycledNativeRowsWithoutGuideOrNetwork() async throws {
        let channels = (0..<10_000).map { index in
            LiveTVPrototypeChannel(id: "channel-\(index)", number: index + 1,
                name: "Channel \(index)", category: "Test", symbol: "tv", accent: 0,
                source: .iptv, tagline: "")
        }
        let model = LiveTVPrototypeModel(channels: channels)
        let browser = LiveTVChannelBrowser(
            model: model, imports: LiveTVPrototypeImportModel(configuration: .init(playlists: [])),
            selectedRow: .constant(nil), restoreFocusRequest: 0, isPresented: false,
            libraryCatalog: nil, loadLibraryGuide: nil,
            select: { _ in }, watch: { _ in }, focusChanged: { _ in }, restored: { _ in }, openToolbar: {}
        )
        let host = UIHostingController(rootView: browser)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 780, height: 900))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while collections(in: host.view).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            host.view.layoutIfNeeded()
        }
        let collection = try XCTUnwrap(collections(in: host.view).first,
            "The split browser must use the recycled native list, not catalog-wide SwiftUI focus fillers")
        collection.layoutIfNeeded()
        XCTAssertEqual(collection.numberOfItems(inSection: 0), model.guideRowIDs.count)
        XCTAssertEqual(model.guideRowIDs.count, 10_000)
        XCTAssertFalse(collection.visibleCells.isEmpty)
        XCTAssertLessThan(collection.visibleCells.count, 100)
        XCTAssertLessThan(hostCount(in: host), 100)

        collection.scrollToItem(at: IndexPath(item: 9_990, section: 0), at: .centeredVertically, animated: false)
        collection.layoutIfNeeded()
        XCTAssertTrue(collection.indexPathsForVisibleItems.contains { $0.item == 9_990 })
        XCTAssertLessThan(hostCount(in: host), 100, "Distant scrolling must recycle row hosts")
    }

    private func collections(in view: UIView) -> [UICollectionView] {
        (view as? UICollectionView).map { [$0] } ?? view.subviews.flatMap { collections(in: $0) }
    }

    private func hostCount(in controller: UIViewController) -> Int {
        controller.children.reduce(0) { $0 + 1 + hostCount(in: $1) }
    }
}
#endif
