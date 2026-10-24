// Standalone experiment helper. Does not open or migrate Morrow's index.
import Foundation
import Vision
import ImageIO
import UniformTypeIdentifiers
import Darwin

func writeJSON(_ value: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

func centre(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
    guard let region, region.pointCount > 0 else { return nil }
    let points = region.normalizedPoints
    return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                   y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
}

func detect(_ inputs: [[String: Any]], output: URL) throws -> [String: Any] {
    let folder = output.deletingLastPathComponent().appendingPathComponent("normalized")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var results: [[String: Any]] = []
    for item in inputs {
        results.append(autoreleasepool { () -> [String: Any] in
            let id = item["id"] as! String
            var record: [String: Any] = ["id": id, "path": item["path"] as! String]
            do {
                let started = CFAbsoluteTimeGetCurrent()
                let url = URL(fileURLWithPath: item["path"] as! String)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1600,
                      ] as CFDictionary) else {
                    throw NSError(domain: "PeopleEval", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot decode image"])
                }
                let normalized = folder.appendingPathComponent(id + ".png")
                guard let destination = CGImageDestinationCreateWithURL(normalized as CFURL, UTType.png.identifier as CFString, 1, nil)
                else { throw NSError(domain: "PeopleEval", code: 2) }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "PeopleEval", code: 3) }
                record["normalization_seconds"] = CFAbsoluteTimeGetCurrent() - started
                let handler = VNImageRequestHandler(cgImage: image)
                let landmarks = VNDetectFaceLandmarksRequest()
                let detectionStarted = CFAbsoluteTimeGetCurrent()
                try handler.perform([landmarks])
                record["detection_seconds"] = CFAbsoluteTimeGetCurrent() - detectionStarted
                let observations = landmarks.results ?? []
                let quality = VNDetectFaceCaptureQualityRequest()
                quality.inputFaceObservations = observations
                let qualityStarted = CFAbsoluteTimeGetCurrent()
                try? handler.perform([quality])
                record["quality_seconds"] = CFAbsoluteTimeGetCurrent() - qualityStarted
                let width = CGFloat(image.width), height = CGFloat(image.height)
                record["normalized"] = normalized.path
                record["width"] = image.width
                record["height"] = image.height
                record["faces"] = observations.map { face -> [String: Any] in
                    let box = face.boundingBox
                    func pixel(_ point: CGPoint) -> [Double] {
                        [Double((box.minX + point.x * box.width) * width),
                         Double((1 - box.minY - point.y * box.height) * height)]
                    }
                    var value: [String: Any] = [
                        "box": [Double(box.minX * width), Double((1 - box.maxY) * height),
                                Double(box.width * width), Double(box.height * height)],
                        "confidence": Double(face.confidence),
                    ]
                    if let left = centre(face.landmarks?.leftEye), let right = centre(face.landmarks?.rightEye),
                       let mouth = centre(face.landmarks?.outerLips) {
                        let eyes = [pixel(left), pixel(right)].sorted { $0[0] < $1[0] }
                        value["anchors"] = eyes + [pixel(mouth)]
                    }
                    let capture = quality.results?.max { a, b in
                        let aa = a.boundingBox.intersection(box), bb = b.boundingBox.intersection(box)
                        return aa.width * aa.height < bb.width * bb.height
                    }?.faceCaptureQuality
                    if let capture { value["quality"] = Double(capture) }
                    return value
                }
            } catch {
                record["error"] = String(describing: error)
            }
            return record
        })
    }
    return ["images": results, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "normalization_max_pixels": 1600, "landmarks_revision": VNDetectFaceLandmarksRequest().revision]
}

func prints(_ inputs: [[String: Any]]) throws -> [String: Any] {
    guard VNGenerateImageFeaturePrintRequest.supportedRevisions.contains(2) else {
        throw NSError(domain: "PeopleEval", code: 4, userInfo: [NSLocalizedDescriptionKey: "Feature-print revision 2 unavailable"])
    }
    var observations: [VNFeaturePrintObservation?] = []
    var records: [[String: Any]] = []
    for item in inputs {
        let started = CFAbsoluteTimeGetCurrent()
        var record: [String: Any] = ["id": item["id"] as! String]
        var observation: VNFeaturePrintObservation?
        do {
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = 2
            request.imageCropAndScaleOption = .scaleFill
            try VNImageRequestHandler(url: URL(fileURLWithPath: item["path"] as! String)).perform([request])
            observation = request.results?.first
            if observation == nil { record["error"] = "No feature print returned" }
        } catch { record["error"] = String(describing: error) }
        record["seconds"] = CFAbsoluteTimeGetCurrent() - started
        observations.append(observation)
        records.append(record)
    }
    var distances = Array(repeating: Array<Any>(repeating: NSNull(), count: inputs.count), count: inputs.count)
    for i in observations.indices {
        guard let a = observations[i] else { continue }
        for j in i..<observations.count {
            guard let b = observations[j] else { continue }
            var distance: Float = 0
            try a.computeDistance(&distance, to: b)
            distances[i][j] = Double(distance)
            distances[j][i] = Double(distance)
        }
    }
    return ["items": records, "distances": distances, "revision": 2,
            "note": "Generic image feature prints on YuNet/SFace-aligned face crops; experimental identity baseline"]
}

do {
    guard CommandLine.arguments.count == 4 else {
        throw NSError(domain: "PeopleEval", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "Usage: people-eval-vision detect|prints input.json output.json"])
    }
    let input = URL(fileURLWithPath: CommandLine.arguments[2])
    let output = URL(fileURLWithPath: CommandLine.arguments[3])
    guard let items = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as? [[String: Any]]
    else { throw NSError(domain: "PeopleEval", code: 6) }
    var result: [String: Any]
    switch CommandLine.arguments[1] {
    case "detect": result = try detect(items, output: output)
    case "prints": result = try prints(items)
    default: throw NSError(domain: "PeopleEval", code: 7)
    }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    result["peak_process_rss_bytes"] = usage.ru_maxrss
    try writeJSON(result, to: output)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
