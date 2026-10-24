import Foundation
import Testing
@testable import FaceRuntime

@Suite struct FaceRuntimeTests {
    @Test func identityAlignmentPreservesLandmarksAndRGB() throws {
        let anchors = [CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.1396, y: 92.2848)]
        var pixels = [UInt8](repeating: 255, count: 112*112*4)
        for i in 0..<(112*112) { pixels[i*4] = UInt8(i % 112); pixels[i*4+1] = UInt8(i/112); pixels[i*4+2] = 31 }
        #expect(try FaceRecognizer.align(pixels, width: 112, height: 112, anchors: anchors) == pixels)
    }
}
