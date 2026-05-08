import Vapor

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        defer { app.shutdown() }

        try await configure(app)
        try await app.autoMigrate()
        try await app.execute()
    }
}
