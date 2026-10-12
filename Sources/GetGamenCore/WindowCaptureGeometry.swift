import CoreGraphics
import ScreenCaptureKit

public enum WindowCaptureGeometry {
    public static func pixelSize(contentRect: CGRect, pointPixelScale: Double) throws -> PixelSize {
        guard [contentRect.origin.x, contentRect.origin.y, contentRect.size.width, contentRect.size.height].allSatisfy(\.isFinite),
              contentRect.size.width > 0, contentRect.size.height > 0,
              pointPixelScale.isFinite, pointPixelScale > 0 else {
            throw WindowCaptureService.CaptureError.invalidGeometry
        }
        let widthValue = ceil(Double(contentRect.size.width) * pointPixelScale)
        let heightValue = ceil(Double(contentRect.size.height) * pointPixelScale)
        guard widthValue.isFinite, heightValue.isFinite,
              let width = Int(exactly: widthValue), let height = Int(exactly: heightValue),
              width > 0, height > 0 else { throw WindowCaptureService.CaptureError.invalidGeometry }
        let count = width.multipliedReportingOverflow(by: height)
        guard !count.overflow, !count.partialValue.multipliedReportingOverflow(by: 4).overflow else {
            throw WindowCaptureService.CaptureError.invalidGeometry
        }
        return PixelSize(width: width, height: height)
    }

    public static func configuration(contentRect: CGRect, pointPixelScale: Double,
                              showsCursor: Bool) throws -> SCStreamConfiguration {
        let size = try pixelSize(contentRect: contentRect, pointPixelScale: pointPixelScale)
        let configuration = PlatformSupport.captureConfiguration(showsCursor: showsCursor)
        configuration.width = size.width
        configuration.height = size.height
        return configuration
    }
}
