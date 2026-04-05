import Vapor
import Fluent
import FluentPostgresDriver
import JWT
import Redis

func configure(_ app: Application) throws {
    // MARK: - Database

    if let databaseURL = Environment.get("DATABASE_URL") {
        try app.databases.use(
            .postgres(url: databaseURL),
            as: .psql
        )
    } else {
        // Local development fallback
        app.databases.use(
            .postgres(configuration: .init(
                hostname: Environment.get("DB_HOST") ?? "localhost",
                port: Environment.get("DB_PORT").flatMap(Int.init) ?? 5432,
                username: Environment.get("DB_USER") ?? "tidepool",
                password: Environment.get("DB_PASS") ?? "tidepool",
                database: Environment.get("DB_NAME") ?? "tidepool",
                tls: .disable
            )),
            as: .psql
        )
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

    // MARK: - JWT

    let jwtSecret = Environment.get("JWT_SECRET") ?? "dev-secret-change-me"
    app.jwt.signers.use(.hs256(key: jwtSecret))

    // MARK: - Middleware

    app.middleware.use(ErrorMiddleware.default(environment: app.environment))

    // MARK: - Routes

    try routes(app)
}
