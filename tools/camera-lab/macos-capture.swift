// macos-capture: a lossless reference from the built-in camera on macOS, for
// comparing with the Linux camera lab. It streams the camera at 1920x1080 in
// '420v' (the NV12 the Linux driver delivers), lets exposure settle, then
// writes FRAMES frames as raw NV12 (raw.nv12, the camera-lab clip format) and
// the last frame as a PNG, plus notes.txt with the format and frame rate.
//
//   swiftc -O -o macos-capture macos-capture.swift \
//     -framework AVFoundation -framework CoreImage -framework AppKit
//   ./macos-capture [OUT_DIR] [FRAMES] [SKIP]
//
// Then on Linux: camera-lab clip --from OUT_DIR (the Aurora tools are not
// there, so only the specks and edge metrics fill; ffmpeg does the rest).
import AVFoundation
import AppKit
import CoreImage
import Foundation

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : NSHomeDirectory() + "/Pictures/omarchy-cam-macos"
let want = args.count > 2 ? Int(args[2]) ?? 100 : 100
let skip = args.count > 3 ? Int(args[3]) ?? 60 : 60
let fourcc = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

func fourccString(_ v: FourCharCode) -> String {
    let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    return String(bytes: b, encoding: .ascii) ?? "\(v)"
}

func fail(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Camera permission. Over SSH the prompt, if any, appears on the Mac's screen.
var granted = false
switch AVCaptureDevice.authorizationStatus(for: .video) {
case .authorized:
    granted = true
case .notDetermined:
    let sem = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { g in granted = g; sem.signal() }
    _ = sem.wait(timeout: .now() + 90)
default:
    granted = false
}
if !granted {
    fail("camera access not authorized (status \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)); run this in Terminal on the Mac once and allow it", 2)
}

guard let device = AVCaptureDevice.default(for: .video) else { fail("no camera", 1) }
var notes = "Device: \(device.localizedName) (\(device.modelID))\n"
var chosen: AVCaptureDevice.Format?
for f in device.formats {
    let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
    let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
    let fps = f.videoSupportedFrameRateRanges.map { String(format: "%.0f", $0.maxFrameRate) }.joined(separator: "/")
    notes += "Format offered: \(d.width)x\(d.height) \(fourccString(sub)) fps \(fps)\n"
    if d.width == 1920 && d.height == 1080 && sub == fourcc && chosen == nil { chosen = f }
}

final class Grabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let raw: FileHandle
    let done = DispatchSemaphore(value: 0)
    var seen = 0, written = 0, width = 0, height = 0
    var first: CMTime = .invalid, last: CMTime = .invalid
    var lastImage: CGImage?
    var fourccSeen: OSType = 0
    init(raw: FileHandle) { self.raw = raw }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        seen += 1
        if seen <= skip { return }
        if written >= want { return }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if written == 0 { first = ts }
        last = ts
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        width = CVPixelBufferGetWidth(pb)
        height = CVPixelBufferGetHeight(pb)
        fourccSeen = CVPixelBufferGetPixelFormatType(pb)
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
            let rows = CVPixelBufferGetHeightOfPlane(pb, plane)
            let rowBytes = plane == 0 ? width : width  // NV12: Y is W bytes a row, CbCr interleaved is W bytes a row
            for r in 0..<rows {
                raw.write(Data(bytes: base + r * stride, count: rowBytes))
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        written += 1
        if written == want {
            let ci = CIImage(cvPixelBuffer: pb)
            lastImage = CIContext().createCGImage(ci, from: ci.extent)
            done.signal()
        }
    }
}

FileManager.default.createFile(atPath: outDir + "/raw.nv12", contents: nil)
guard let rawHandle = FileHandle(forWritingAtPath: outDir + "/raw.nv12") else { fail("can't write \(outDir)/raw.nv12", 1) }
let grabber = Grabber(raw: rawHandle)

let session = AVCaptureSession()
session.beginConfiguration()
session.sessionPreset = .hd1920x1080
guard let input = try? AVCaptureDeviceInput(device: device) else { fail("can't open the camera", 1) }
session.addInput(input)
// Setting the active format moves the session to input priority by itself
// (the explicit preset for that isn't available on macOS).
if let f = chosen {
    try? device.lockForConfiguration()
    device.activeFormat = f
    device.unlockForConfiguration()
}
let output = AVCaptureVideoDataOutput()
output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: fourcc]
output.alwaysDiscardsLateVideoFrames = false
output.setSampleBufferDelegate(grabber, queue: DispatchQueue(label: "capture"))
session.addOutput(output)
session.commitConfiguration()
session.startRunning()

let started = Date()
let finished = grabber.done.wait(timeout: .now() + 30) == .success
session.stopRunning()
rawHandle.closeFile()

let af = device.activeFormat
let ad = CMVideoFormatDescriptionGetDimensions(af.formatDescription)
notes += "Active format: \(ad.width)x\(ad.height) \(fourccString(CMFormatDescriptionGetMediaSubType(af.formatDescription)))\n"
notes += "Frames delivered: \(grabber.seen) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s; skipped \(skip), written \(grabber.written)\n"
if grabber.written > 1 {
    let dt = CMTimeGetSeconds(CMTimeSubtract(grabber.last, grabber.first)) / Double(grabber.written - 1)
    notes += String(format: "Frame interval: %.1f ms (%.1f fps)\n", dt * 1000, 1 / dt)
}
notes += "Clip: \(grabber.width)x\(grabber.height) NV12, \(grabber.written) frames, the last 60 measured\n"
notes += "Pixel format of the frames: \(fourccString(grabber.fourccSeen))\n"
notes += "Recorded: \(ISO8601DateFormatter().string(from: Date()))\n"
notes += "Readings during the capture: n/a (macOS; gain and exposure aren't exposed)\n"
if let img = grabber.lastImage {
    let rep = NSBitmapImageRep(cgImage: img)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: outDir + "/last-frame.png"))
        notes += "PNG: last-frame.png (\(img.width)x\(img.height), from the last written frame)\n"
    }
}
try? notes.write(toFile: outDir + "/notes.txt", atomically: true, encoding: .utf8)
print(notes, terminator: "")
if !finished { fail("timed out: \(grabber.written) of \(want) frames written", 3) }
