#if os(iOS)
    import UIKit

    /// Cells mount UIKit rows directly: no hosting controller or observation graph.
    final class TimelineCollectionViewCell: UICollectionViewCell {
        let rowView = TimelineRowView(frame: .zero)

        override init(frame: CGRect) {
            super.init(frame: frame)
            contentView.addSubview(rowView)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            rowView.frame = contentView.bounds
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            rowView.clear()
        }
    }

#endif
