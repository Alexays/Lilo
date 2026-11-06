import XCTest
@testable import Lilo

/// Opt-in: `make changelog-media` runs it for a release. A plan that fails leaves its highlight without
/// media and records why; the others still run.
@MainActor
final class ReleaseMediaCaptureTests: XCTestCase {
    func testPlans() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let plans = environment["LILO_RELEASE_MEDIA_PLANS"], let shots = environment["LILO_RELEASE_MEDIA_SHOTS"] else {
            throw XCTSkip("Opt-in release media capture")
        }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: plans), includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" {
            let output = URL(fileURLWithPath: shots).appendingPathComponent(file.deletingPathExtension().lastPathComponent)
            do {
                let plan = try JSONDecoder().decode(ReleaseMediaPlan.self, from: Data(contentsOf: file))
                let capture = try await ReleaseMediaCapture(output: output)
                defer { capture.close() }
                for step in plan.steps { try await capture.run(step) }
                try capture.finish()
            } catch {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try error.localizedDescription.write(to: output.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
}
