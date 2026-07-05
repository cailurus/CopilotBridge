import Foundation
import Testing
@testable import CopilotBridge

@Test func serverServesRequestThenStopReleasesPort() async throws {
    let port = Int.random(in: 20000...39000)
    let server = HTTPServer { req in
        .text(200, "ok:\(req.path)")
    }
    try server.start(host: "127.0.0.1", port: port)
    // Give the listener a moment to bind.
    try await Task.sleep(nanoseconds: 300_000_000)

    // A normal request still works after the lifecycle changes.
    let url = URL(string: "http://127.0.0.1:\(port)/health")!
    let (data, resp) = try await URLSession.shared.data(from: url)
    #expect((resp as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(data: data, encoding: .utf8) == "ok:/health")

    server.stop()
    try await Task.sleep(nanoseconds: 300_000_000)

    // After stop, a new server can bind the same port (proves the socket was released).
    let server2 = HTTPServer { _ in .text(200, "second") }
    try server2.start(host: "127.0.0.1", port: port)
    try await Task.sleep(nanoseconds: 200_000_000)
    server2.stop()
}
