import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum Screenshotter {
  enum ScreenshotError: Error {
    case captureFailed
    case encodingFailed
    case noScreenForRect
    case noDisplayFound
  }

  /// Captures a PNG for the given selection rect in **Cocoa global screen coordinates**.
  /// Uses ScreenCaptureKit (required on newer macOS SDKs).
  static func capturePNG(cocoaGlobalRect: CGRect) async throws -> Data {
    let rect = cocoaGlobalRect.standardized.integral

    guard let screen = bestScreen(for: rect) else {
      throw ScreenshotError.noScreenForRect
    }

    // Convert Cocoa-global (origin bottom-left) into this screen's local coordinates (still bottom-left).
    let local = rect.offsetBy(dx: -screen.frame.origin.x, dy: -screen.frame.origin.y)

    guard
      let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else {
      throw ScreenshotError.captureFailed
    }

    let displayID = CGDirectDisplayID(truncating: displayNumber)

    let fullImage = try await captureDisplayImage(displayID: displayID)
    let fullBounds = CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height)

    // Map points -> pixels using the *actual* captured image size to avoid scaling/offset issues.
    // This makes the crop match the user’s selection and the preview.
    let scaleX = CGFloat(fullImage.width) / max(screen.frame.width, 1)
    let scaleY = CGFloat(fullImage.height) / max(screen.frame.height, 1)

    let pixelRect = CGRect(
      x: local.minX * scaleX,
      y: (screen.frame.height - local.maxY) * scaleY,
      width: local.width * scaleX,
      height: local.height * scaleY
    ).integral

    let cropRect = pixelRect.intersection(fullBounds).integral
    guard let cgImage = fullImage.cropping(to: cropRect) else {
      throw ScreenshotError.captureFailed
    }

    // Encode CGImage to PNG.
    let data = NSMutableData()
    guard
      let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else {
      throw ScreenshotError.encodingFailed
    }

    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else {
      throw ScreenshotError.encodingFailed
    }

    return data as Data
  }

  @available(macOS 12.3, *)
  private static func captureDisplayImage(displayID: CGDirectDisplayID) async throws -> CGImage {
    // This call requires Screen Recording permission.
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
      throw ScreenshotError.noDisplayFound
    }

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.capturesAudio = false
    config.showsCursor = false
    config.queueDepth = 1
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.width = display.width
    config.height = display.height

    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
    let receiver = FrameReceiver()
    let queue = DispatchQueue(label: "AgentView.ScreenCaptureKit.frame")

    try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: queue)

    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      stream.startCapture { error in
        if let error { cont.resume(throwing: error) }
        else { cont.resume(returning: ()) }
      }
    }

    defer {
      stream.stopCapture { _ in }
    }

    return try await receiver.nextFrame()
  }

  private static func bestScreen(for cocoaGlobalRect: CGRect) -> NSScreen? {
    var best: (screen: NSScreen, area: CGFloat)?

    for screen in NSScreen.screens {
      let intersection = screen.frame.intersection(cocoaGlobalRect)
      guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { continue }

      let area = intersection.width * intersection.height
      if best == nil || area > best!.area {
        best = (screen, area)
      }
    }

    return best?.screen
  }
}

@available(macOS 12.3, *)
private final class FrameReceiver: NSObject, SCStreamOutput {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<CGImage, Error>?
  private let ciContext = CIContext(options: [.cacheIntermediates: false])

  func nextFrame() async throws -> CGImage {
    try await withCheckedThrowingContinuation { cont in
      lock.lock()
      continuation = cont
      lock.unlock()
    }
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen else { return }
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

    lock.lock()
    let cont = continuation
    continuation = nil
    lock.unlock()

    cont?.resume(returning: cgImage)
  }
}


