import AppKit

/// A table cell view that displays an image preview for binary image files.
/// Supports showing a single image (add/delete) or side-by-side old/new comparison.
@MainActor
public final class ImagePreviewCellView: NSTableCellView {

    public enum ChangeType {
        case added, deleted, modified

        var color: NSColor {
            switch self {
            case .added: return NSColor.systemGreen
            case .deleted: return NSColor.systemRed
            case .modified: return NSColor.systemOrange
            }
        }

        var backgroundColor: NSColor {
            switch self {
            case .added: return NSColor.systemGreen.withAlphaComponent(0.06)
            case .deleted: return NSColor.systemRed.withAlphaComponent(0.06)
            case .modified: return NSColor.systemOrange.withAlphaComponent(0.06)
            }
        }
    }

    public static let reuseIdentifier = NSUserInterfaceItemIdentifier("ImagePreviewCell")

    /// The image to display (new version for additions, old for deletions).
    public var image: NSImage? {
        didSet { imageLayer.image = image; needsLayout = true }
    }

    /// For modified images: the old version shown on the left.
    public var oldImage: NSImage? {
        didSet { oldImageLayer.image = oldImage; needsLayout = true }
    }

    /// Label text (e.g. "新增", "删除", "修改").
    public var statusText: String = "" {
        didSet { statusLabel.stringValue = statusText }
    }

    /// The file path for display.
    public var filePath: String = ""

    private let imageLayer: NSImageView = {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 4
        iv.layer?.masksToBounds = true
        iv.layer?.borderWidth = 1
        iv.layer?.borderColor = NSColor.separatorColor.cgColor
        return iv
    }()

    private let oldImageLayer: NSImageView = {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 4
        iv.layer?.masksToBounds = true
        iv.layer?.borderWidth = 1
        iv.layer?.borderColor = NSColor.separatorColor.cgColor
        iv.isHidden = true
        return iv
    }()

    private let statusLabel: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.font = .systemFont(ofSize: 11, weight: .medium)
        f.textColor = .secondaryLabelColor
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()

    private let sizeLabel: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        f.textColor = .tertiaryLabelColor
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()

    private var imageHeightConstraint: NSLayoutConstraint?
    private var oldImageHeightConstraint: NSLayoutConstraint?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        addSubview(statusLabel)
        addSubview(sizeLabel)
        addSubview(oldImageLayer)
        addSubview(imageLayer)

        let imgH = imageLayer.heightAnchor.constraint(equalToConstant: 100)
        imgH.priority = .defaultHigh
        imageHeightConstraint = imgH

        let oldImgH = oldImageLayer.heightAnchor.constraint(equalToConstant: 100)
        oldImgH.priority = .defaultHigh
        oldImageHeightConstraint = oldImgH

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            sizeLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            sizeLabel.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 8),

            // Old image (left side, for modifications).
            oldImageLayer.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            oldImageLayer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            oldImgH,

            // New image.
            imageLayer.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            imageLayer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            imgH,
        ])
    }

    /// Configure for a single image (addition or deletion).
    public func configureSingle(image: NSImage?, status: String, changeType: ChangeType = .modified) {
        self.image = image
        self.oldImage = nil
        oldImageLayer.isHidden = true
        imageLayer.isHidden = false

        // Status badge with color.
        let badge = NSMutableAttributedString()
        let dot = NSAttributedString(
            string: "● ",
            attributes: [.foregroundColor: changeType.color, .font: NSFont.systemFont(ofSize: 12)]
        )
        badge.append(dot)
        badge.append(NSAttributedString(
            string: status,
            attributes: [.foregroundColor: changeType.color, .font: NSFont.systemFont(ofSize: 11, weight: .semibold)]
        ))
        statusLabel.attributedStringValue = badge

        // Background tint.
        wantsLayer = true
        layer?.backgroundColor = changeType.backgroundColor.cgColor

        // Center the image.
        imageLayer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16).isActive = true

        if let img = image {
            let maxW = max(bounds.width - 32, 200)
            let maxH: CGFloat = 360
            let ratio = img.size.height / max(img.size.width, 1)
            let displayW = min(img.size.width, maxW)
            let displayH = min(displayW * ratio, maxH)
            imageHeightConstraint?.constant = displayH
            imageLayer.widthAnchor.constraint(lessThanOrEqualToConstant: displayW).isActive = true
            sizeLabel.stringValue = "\(Int(img.size.width))×\(Int(img.size.height))"
        } else {
            imageHeightConstraint?.constant = 40
            sizeLabel.stringValue = ""
        }
    }

    /// Configure for side-by-side comparison (modification).
    public func configureDual(oldImage: NSImage?, newImage: NSImage?, status: String) {
        self.image = newImage
        self.oldImage = oldImage
        self.statusText = status
        oldImageLayer.isHidden = false
        imageLayer.isHidden = false

        let maxH: CGFloat = 300
        let halfW = max((bounds.width - 48) / 2, 100)

        if let old = oldImage {
            let ratio = old.size.height / max(old.size.width, 1)
            oldImageHeightConstraint?.constant = min(halfW * ratio, maxH)
            oldImageLayer.widthAnchor.constraint(lessThanOrEqualToConstant: halfW).isActive = true
        }
        if let img = newImage {
            let ratio = img.size.height / max(img.size.width, 1)
            imageHeightConstraint?.constant = min(halfW * ratio, maxH)
            imageLayer.widthAnchor.constraint(lessThanOrEqualToConstant: halfW).isActive = true
        }
        // Position side by side.
        imageLayer.leadingAnchor.constraint(equalTo: oldImageLayer.trailingAnchor, constant: 16).isActive = true
        sizeLabel.stringValue = ""
    }

    /// Computes the ideal row height for this image preview.
    public static func preferredHeight(for image: NSImage?, maxWidth: CGFloat) -> CGFloat {
        guard let img = image else { return 60 }
        let maxH: CGFloat = 380
        let availableW = maxWidth - 32
        let ratio = img.size.height / max(img.size.width, 1)
        let displayW = min(img.size.width, availableW)
        let displayH = min(displayW * ratio, maxH)
        return displayH + 36 // 8 top + 20 status + 8 gap + image + padding
    }
}
