import Vapor
import Fluent
import FluentPostgresDriver
import JWT
import NIOSSL
import Redis

func configure(_ app: Application) async throws {
    // MARK: - Database

    if let databaseURL = Environment.get("DATABASE_URL") {
        // BoringSSL (statically linked) does not auto-discover the system CA
        // bundle, so an explicit TLS config is required. We skip cert
        // verification because Railway's Postgres is reached via the private
        // network and we don't ship a CA bundle in the static binary.
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none
        let nioSSLContext = try NIOSSLContext(configuration: tlsConfig)

        var postgresConfig = try SQLPostgresConfiguration(url: databaseURL)
        postgresConfig.coreConfiguration.tls = .require(nioSSLContext)

        app.databases.use(.postgres(configuration: postgresConfig), as: .psql)
    } else {
        // Local development fallback
        let host: String = Environment.get("DB_HOST") ?? "localhost"
        let port: Int = Environment.get("DB_PORT").flatMap(Int.init) ?? 5432
        let user: String = Environment.get("DB_USER") ?? "tidepool"
        let pass: String = Environment.get("DB_PASS") ?? "tidepool"
        let name: String = Environment.get("DB_NAME") ?? "tidepool"
        let config = SQLPostgresConfiguration(
            hostname: host,
            port: port,
            username: user,
            password: pass,
            database: name,
            tls: .disable
        )
        app.databases.use(.postgres(configuration: config), as: .psql)
    }

    // MARK: - Redis

    if let redisURL = Environment.get("REDIS_URL") {
        app.redis.configuration = try RedisConfiguration(url: redisURL)
    } else {
        app.redis.configuration = try RedisConfiguration(
            hostname: Environment.get("REDIS_HOST") ?? "localhost",
            port: Environment.get("REDIS_PORT").flatMap(Int.init) ?? 6379
        )
    }

    // MARK: - Migrations

    app.migrations.add(EnablePgvector())
    app.migrations.add(CreateDevices())
    app.migrations.add(CreateDeviceProfiles())
    app.migrations.add(CreateFavorites())
    app.migrations.add(CreateVisits())
    app.migrations.add(AddMultiVectors())
    app.migrations.add(CreateTidepools())
    app.migrations.add(AddVisitTileID())
    app.migrations.add(AddVisitsRecentIndex())

    // MARK: - JWT

    // Outside the development environment, refuse to boot without an explicit
    // JWT_SECRET so we can't accidentally ship a deployment that signs tokens
    // with the placeholder dev key.
    let jwtSecret: String
    if let configured = Environment.get("JWT_SECRET") {
        jwtSecret = configured
    } else if app.environment == .development {
        app.logger.warning("JWT_SECRET not set — using insecure development default")
        jwtSecret = "dev-secret-change-me"
    } else {
        fatalError("JWT_SECRET must be set in \(app.environment.name)")
    }
    app.jwt.signers.use(.hs256(key: jwtSecret))

    // MARK: - Middleware

    app.middleware.use(ErrorMiddleware.default(environment: app.environment))

    // MARK: - Background Jobs
    // Temporarily disabled — scheduler crashes the server
    // app.lifecycle.use(BackgroundScheduler())

    // MARK: - Routes

    try routes(app)
}
