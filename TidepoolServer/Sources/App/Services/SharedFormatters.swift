import Foundation

/// Single shared ISO 8601 date formatter for the whole server. The default
/// config is thread-safe and immutable, so a per-request allocation was just
/// wasted work — FavoritesController in particular was making one per
/// favorite in a list response.
let iso8601Formatter = ISO8601DateFormatter()
