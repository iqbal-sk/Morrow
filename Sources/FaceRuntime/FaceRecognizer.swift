import Foundation
import Vision
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import OnnxRuntimeBindings
import DigUpKit

/// A serial, CPU-only native inference session. Owned by the short-lived helper, never the UI process.
public final class FaceRecognizer {
    private let environment: ORTEnv
    private let session: ORTSession
    private let input: String
    private let output: String
    public init(model: URL) throws {
        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        session = try ORTSession(env: environment, modelPath: model.path, sessionOptions: options)
        guard let input = try session.inputNames().first, let output = try session.outputNames().first else {
            throw FaceError("The face model has no inputs or outputs")
        }
        self.input = input; self.output = output
    }
    public func embedAligned(_ url: URL) throws -> [Float] {
        let image = try Self.decode(url, maxPixels: 112)
        guard image.width == 112, image.height == 112 else { throw FaceError("Aligned face must be 112 × 112") }
        return try embed(Self.pixels(image))
    }
    public func detect(_ url: URL) throws -> FacePhoto {
        let started = Date()
        let image = try Self.decode(url, maxPixels: 1600)
        let request = VNDetectFaceLandmarksRequest()
        request.revision = 3
        try VNImageRequestHandler(cgImage: image).perform([request])
        let pixels = try Self.pixels(image)
        let width = Double(image.width), height = Double(image.height)
        var results: [FaceSample] = []
        for face in (request.results ?? []).sorted(by: { $0.boundingBox.midX < $1.boundingBox.midX }) {
            guard let left = Self.centre(face.landmarks?.leftEye), let right = Self.centre(face.landmarks?.rightEye),
                  let mouth = Self.centre(face.landmarks?.outerLips) else { continue }
            let box = face.boundingBox
            func pixel(_ p: CGPoint) -> CGPoint {
                CGPoint(x: (box.minX + p.x * box.width) * width, y: (1 - box.minY - p.y * box.height) * height)
            }
            let eyes = [pixel(left), pixel(right)].sorted { $0.x < $1.x }
            let aligned = try Self.align(pixels, width: image.width, height: image.height, anchors: eyes + [pixel(mouth)])
            let vector = try embed(aligned)
            results.append(FaceSample(box: [box.minX, 1 - box.maxY, box.width, box.height], vector: vector,
                                      jpeg: try Self.jpeg(aligned, width: 112, height: 112)))
        }
        return FacePhoto(faces: results, width: image.width, height: image.height, seconds: Date().timeIntervalSince(started))
    }
    private func embed(_ rgba: [UInt8]) throws -> [Float] {
        let size = 112 * 112
        guard rgba.count == size * 4 else { throw FaceError("Invalid aligned face pixels") }
        var planar = [Float](repeating: 0, count: size * 3)
        for i in 0..<size { for channel in 0..<3 { planar[channel * size + i] = Float(rgba[i * 4 + channel]) } }
        let data = planar.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress!, length: $0.count * 4) }
        let tensor = try ORTValue(tensorData: data, elementType: .float, shape: [1, 3, 112, 112])
        let outputs = try session.run(withInputs: [input: tensor], outputNames: [output], runOptions: nil)
        guard let value = outputs[output] else { throw FaceError("Face model returned no vector") }
        let bytes = try value.tensorData() as Data
        guard bytes.count == 128 * 4 else { throw FaceError("Unexpected face vector dimensions") }
        return try FaceIdentity.normalized(bytes.withUnsafeBytes { raw in
            (0..<128).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        })
    }
    private static func centre(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
        guard let region, region.pointCount > 0 else { return nil }
        return CGPoint(x: region.normalizedPoints.map(\.x).reduce(0,+) / CGFloat(region.pointCount),
                       y: region.normalizedPoints.map(\.y).reduce(0,+) / CGFloat(region.pointCount))
    }
    private static func decode(_ url: URL, maxPixels: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary)
        else { throw FaceError("This photo could not be read") }
        return image
    }
    private static func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { data in
            guard let context = CGContext(data: data.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw FaceError("Cannot prepare photo pixels") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    // Same three-point least-squares similarity transform as the evaluation. Bilinear sampling uses OpenCV's 1/32 grid.
    static func align(_ rgba: [UInt8], width: Int, height: Int, anchors: [CGPoint]) throws -> [UInt8] {
        let target = [CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.1396, y: 92.2848)]
        guard anchors.count == 3 else { throw FaceError("Three face landmarks required") }
        let sx = anchors.map(\.x).reduce(0,+)/3, sy = anchors.map(\.y).reduce(0,+)/3
        let tx = target.map(\.x).reduce(0,+)/3, ty = target.map(\.y).reduce(0,+)/3
        var a = 0.0, b = 0.0, denominator = 0.0
        for (s,t) in zip(anchors,target) {
            let x = s.x-sx, y = s.y-sy, u = t.x-tx, v = t.y-ty
            a += x*u + y*v; b += x*v-y*u; denominator += x*x+y*y
        }
        guard denominator > 0 else { throw FaceError("Face landmarks are too small") }
        a /= denominator; b /= denominator
        let dx = tx-a*sx+b*sy, dy = ty-b*sx-a*sy, determinant = a*a+b*b
        guard determinant > 1e-12 else { throw FaceError("Cannot align this face") }
        var output = [UInt8](repeating: 0, count: 112*112*4)
        for y in 0..<112 { for x in 0..<112 {
            let px = (a*(Double(x)-dx)+b*(Double(y)-dy))/determinant
            let py = (-b*(Double(x)-dx)+a*(Double(y)-dy))/determinant
            let qx = (px*32).rounded()/32, qy = (py*32).rounded()/32
            let ix = Int(floor(qx)), iy = Int(floor(qy)), fx = qx-Double(ix), fy = qy-Double(iy)
            for c in 0..<3 {
                var value = 0.0
                for oy in 0...1 { for ox in 0...1 {
                    let xx = ix+ox, yy = iy+oy
                    if xx >= 0 && xx < width && yy >= 0 && yy < height {
                        value += Double(rgba[(yy*width+xx)*4+c]) * (ox == 0 ? 1-fx : fx) * (oy == 0 ? 1-fy : fy)
                    }
                }}
                output[(y*112+x)*4+c] = UInt8(max(0,min(255,value.rounded())))
            }
            output[(y*112+x)*4+3] = 255
        }}
        return output
    }
    private static func jpeg(_ rgba: [UInt8], width: Int, height: Int) throws -> Data {
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw FaceError("Cannot create face thumbnail") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw FaceError("Cannot encode face thumbnail") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FaceError("Cannot save face thumbnail") }
        return output as Data
    }
}
public struct FaceError: LocalizedError {
    let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
