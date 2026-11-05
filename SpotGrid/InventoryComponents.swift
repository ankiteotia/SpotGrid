//
//  InventoryComponents.swift
//  SpotGrid
//
//  Small views and helpers shared by the room, spot, item, and search screens.
//

import SwiftData
import SwiftUI
import UIKit

// MARK: - Photos

/// Square list thumbnail. Expects the small `thumbnailData` JPEGs, which are
/// cheap enough to decode inline while scrolling.
struct PhotoThumbnail: View {
    let data: Data?
    var size: CGFloat = 48
    var placeholderSystemImage = "photo"

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: placeholderSystemImage)
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemFill))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Full-width photo at the top of a detail screen. Renders nothing without data.
struct PhotoBanner: View {
    let data: Data?
    var height: CGFloat = 220

    var body: some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipped()
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Rows

struct ItemRow: View {
    let item: StoredAsset
    /// Search results show "Room › Spot"; a spot's own list shows notes instead.
    var showsLocation = true

    var body: some View {
        HStack(spacing: 12) {
            PhotoThumbnail(data: item.displayThumbnail, placeholderSystemImage: "shippingbox")
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body.weight(.medium))
                if showsLocation {
                    Text(item.locationText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !item.notes.isEmpty {
                    Text(item.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct SpotRow: View {
    let spot: SpotModel

    var body: some View {
        HStack(spacing: 12) {
            PhotoThumbnail(data: spot.thumbnailData, placeholderSystemImage: "mappin.and.ellipse")
            VStack(alignment: .leading, spacing: 3) {
                Text(spot.name)
                    .font(.body.weight(.medium))
                Text(itemSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    /// "Passport, PAN card, Spare keys" — what's in it at a glance.
    private var itemSummary: String {
        let names = spot.sortedItems.map(\.name)
        return names.isEmpty ? "Empty" : names.joined(separator: ", ")
    }
}

// MARK: - Deletion helpers

enum SpotDeletion {
    static func buttonTitle(for spot: SpotModel) -> String {
        switch spot.items.count {
        case 0:  return "Delete \(spot.name)"
        case 1:  return "Delete \(spot.name) and 1 Item"
        default: return "Delete \(spot.name) and \(spot.items.count) Items"
        }
    }

    static let message = "Move items to another spot first if you want to keep them."
}

enum DeferredDeletion {
    /// Pops the detail screen first and deletes once the pop has finished, so
    /// SwiftUI never re-renders a view that still points at a deleted model.
    static func run(after dismiss: DismissAction, _ delete: @escaping @MainActor () -> Void) {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            delete()
        }
    }
}
