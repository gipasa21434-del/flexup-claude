import SwiftUI
import UIKit

/// Full-screen vertical paging list (iOS 16 compatible) backed by UICollectionView:
/// cell reuse keeps memory flat, `isPagingEnabled` gives native snapping, and SwiftUI content is hosted
/// with `UIHostingConfiguration`. Pages are identified by `ID` so state changes never rebuild cells.
struct VerticalPager<ID: Hashable, Content: View>: UIViewControllerRepresentable {
    let ids: [ID]
    @Binding var index: Int
    var onRefresh: (() async -> Void)? = nil
    var onNearEnd: (() -> Void)? = nil
    @ViewBuilder let content: (ID) -> Content

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PagerController {
        let vc = PagerController()
        vc.coordinator = context.coordinator
        context.coordinator.controller = vc
        context.coordinator.configure(vc.collectionView)
        context.coordinator.apply(ids, animated: false)
        return vc
    }

    func updateUIViewController(_ vc: PagerController, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.currentIDs != ids { c.apply(ids, animated: false) }
        // External index change (e.g. "scroll to top" when the tab is re-selected).
        if c.reportedIndex != index, index < ids.count, !vc.collectionView.isDragging, !vc.collectionView.isDecelerating {
            c.reportedIndex = index
            vc.scroll(to: index, animated: true)
        }
        c.refreshControl?.isEnabled = onRefresh != nil
    }

    final class PagerController: UIViewController {
        weak var coordinator: Coordinator?
        let layout = UICollectionViewFlowLayout()
        lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        private var lastSize: CGSize = .zero

        override func viewDidLoad() {
            super.viewDidLoad()
            layout.scrollDirection = .vertical
            layout.minimumLineSpacing = 0
            layout.minimumInteritemSpacing = 0
            collectionView.isPagingEnabled = true
            collectionView.showsVerticalScrollIndicator = false
            collectionView.contentInsetAdjustmentBehavior = .never
            collectionView.backgroundColor = .black
            collectionView.decelerationRate = .fast
            collectionView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(collectionView)
            NSLayoutConstraint.activate([
                collectionView.topAnchor.constraint(equalTo: view.topAnchor),
                collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            let size = collectionView.bounds.size
            guard size != lastSize, size.height > 0 else { return }
            let page = coordinator?.reportedIndex ?? 0
            lastSize = size
            layout.itemSize = size
            layout.invalidateLayout()
            collectionView.layoutIfNeeded()
            scroll(to: page, animated: false)
        }

        func scroll(to index: Int, animated: Bool) {
            let h = collectionView.bounds.height
            guard h > 0 else { return }
            collectionView.setContentOffset(CGPoint(x: 0, y: CGFloat(index) * h), animated: animated)
        }
    }

    final class Coordinator: NSObject, UICollectionViewDelegate {
        var parent: VerticalPager
        weak var controller: PagerController?
        var dataSource: UICollectionViewDiffableDataSource<Int, ID>!
        var currentIDs: [ID] = []
        var reportedIndex = 0
        weak var refreshControl: UIRefreshControl?

        init(_ parent: VerticalPager) {
            self.parent = parent
            self.reportedIndex = parent.index
        }

        func configure(_ cv: UICollectionView) {
            let registration = UICollectionView.CellRegistration<UICollectionViewCell, ID> { [weak self] cell, _, id in
                guard let self else { return }
                cell.contentConfiguration = UIHostingConfiguration { self.parent.content(id) }
                    .margins(.all, 0)
                    .background(Color.black)
            }
            dataSource = UICollectionViewDiffableDataSource<Int, ID>(collectionView: cv) { cv, indexPath, id in
                cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }
            cv.delegate = self
            let rc = UIRefreshControl()
            rc.tintColor = .white
            rc.addTarget(self, action: #selector(refresh(_:)), for: .valueChanged)
            cv.refreshControl = rc
            refreshControl = rc
        }

        func apply(_ ids: [ID], animated: Bool) {
            currentIDs = ids
            var snap = NSDiffableDataSourceSnapshot<Int, ID>()
            snap.appendSections([0])
            snap.appendItems(ids)
            dataSource.apply(snap, animatingDifferences: animated)
            if reportedIndex >= ids.count { report(max(0, ids.count - 1)) }
        }

        @objc func refresh(_ rc: UIRefreshControl) {
            guard let onRefresh = parent.onRefresh else { rc.endRefreshing(); return }
            Task { @MainActor in
                await onRefresh()
                rc.endRefreshing()
            }
        }

        private func report(_ i: Int) {
            guard i != reportedIndex || parent.index != i else { return }
            reportedIndex = i
            DispatchQueue.main.async { self.parent.index = i }
            if i >= currentIDs.count - 3 { parent.onNearEnd?() }
        }

        private func settle(_ sv: UIScrollView) {
            let h = sv.bounds.height
            guard h > 0 else { return }
            let i = Int((sv.contentOffset.y / h).rounded())
            report(min(max(0, i), max(0, currentIDs.count - 1)))
        }

        func scrollViewDidEndDecelerating(_ sv: UIScrollView) { settle(sv) }
        func scrollViewDidEndScrollingAnimation(_ sv: UIScrollView) { settle(sv) }
        func scrollViewDidEndDragging(_ sv: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settle(sv) } }
    }
}
