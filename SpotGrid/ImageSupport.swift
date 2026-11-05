//
//  ImageSupport.swift
//  SpotGrid
//
//  Photo plumbing shared by the AR capture flow and the item editor:
//    - turning a raw ARKit camera frame into an upright image (any interface
//      orientation, so iPad landscape works too)
//    - re-encoding photos as size-capped JPEGs plus a small list thumbnail
//

import CoreImage
import CoreVideo
import Foundation
import UIKit

/// A full-size photo and its list thumbnail, both JPEG.
struct PhotoPair: Equatable {
    let photo: Data
    let thumbnail: Data
}

enum ImageSupport {

    private static let ciContext = CIContext()

    /// Long edge of list thumbnails, in pixels. 48 pt rows on 3x screens need
    /// ~144 px on the short edge; 240 px on the long edge covers 4:3 photos.
    static let thumbnailMaxDimension: CGFloat = 240

    // MARK: - ARKit frames

    /// ARKit delivers `capturedImage` in the camera sensor's native orientation
    /// (landscape, home button / USB-C on the right), whatever the UI does.
    /// This is the EXIF-style orientation that makes it upright on screen.
    static func imageOrientation(for interfaceOrientation: UIInterfaceOrientation) -> UIImage.Orientation {
        switch interfaceOrientation {
        case .portrait:           return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft:      return .down
        case .landscapeRight:     return .up
        default:                  return .right
        }
    }

    /// Downscaled, upright image of an ARKit camera frame.
    static func uprightImage(
        from pixelBuffer: CVPixelBuffer,
        interfaceOrientation: UIInterfaceOrientation,
        scale: CGFloat
    ) -> UIImage? {
        let scaled = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(
            cgImage: cgImage,
            scale: 1,
            orientation: imageOrientation(for: interfaceOrientation)
        )
    }

    // MARK: - JPEG encoding

    /// Redraws `image` upright, no larger than `maxDimension` on its long edge,
    /// and encodes it as JPEG.
    static func jpegData(
        from image: UIImage,
        maxDimension: CGFloat,
        compressionQuality: CGFloat = 0.7
    ) -> Data? {
        let size = image.size
        let longEdge = max(size.width, size.height)
        guard longEdge > 0 else { return nil }

        let factor = min(1, maxDimension / longEdge)
        let target = CGSize(
            width: (size.width * factor).rounded(),
            height: (size.height * factor).rounded()
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: compressionQuality)
    }

    /// Full photo (capped at `maxDimension`) plus list thumbnail.
    static func photoPair(from image: UIImage, maxDimension: CGFloat = 1600) -> PhotoPair? {
        guard let photo = jpegData(from: image, maxDimension: maxDimension),
              let thumbnail = jpegData(
                  from: image,
                  maxDimension: thumbnailMaxDimension,
                  compressionQuality: 0.6
              )
        else { return nil }
        return PhotoPair(photo: photo, thumbnail: thumbnail)
    }

    /// Same, from encoded data of any format UIImage reads (HEIC, PNG, …).
    static func photoPair(from data: Data) -> PhotoPair? {
        guard let image = UIImage(data: data) else { return nil }
        return photoPair(from: image)
    }
}
