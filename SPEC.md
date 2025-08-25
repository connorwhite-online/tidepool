## Tidepool — Anonymous Interest Heatmap (Product & Technical Spec)

### Vision
An anti-social social map that anonymously visualizes where people with similar interests are likely congregating, enhanced with personalized search recommendations based on aggregated interest data. No profiles, no messaging. Only aggregated presence, interest alignment, and intelligent place discovery.

### Non‑Goals
- No DMs, friending, or in‑app social graph UI
- No precise coordinates exposed to other users
- No public user identities or handles on the map

## User Experience

### Primary Flows
- Onboarding: grant Location/Photos permissions, set Home location, opt into integrations (prioritizing Apple Maps saved locations)
- Map tab: view heatmap overlays indicating nearby interest-aligned presence; search for places with personalized recommendations; tap locations for details and favoriting; view own approximate radius when away from Home
- Profile tab: manage integrations (Apple Maps, Photos, Spotify, Instagram), view favorited locations, data controls, privacy settings

### Navigation
- Tab 1: Home/Map
- Tab 2: Profile/Integrations

### Visual Language
- Heatmap: blended circular fields with opacity/gradient, intensity scaled by interest similarity
- User's own presence (only visible to self): 100 ft radius translucent ring when ≥ 500 ft from Home

### Interaction Design & Motion
- **Fluid Interface Philosophy**: Movement through the app should feel like floating through water rather than walking — smooth, natural, and effortless
- **Dimensional Coherence**: Create visible links between screens, components, and features that feel like logical steps in a physical space
- **Purposeful Animation**: Every animation serves an architectural purpose, helping users understand their navigation path from A → B
- **Origin-Based Transitions**: UI elements that create modals or popups should visually emerge from the interacted element during transition
- **Shared Element Continuity**: Components that persist across states should maintain spatial consistency without unnecessary duplication
- **Spring Physics**: Animations use spring-based physics to emulate natural motion from the physical world
- **Clarity Over Spectacle**: Motion enhances understanding rather than distracting; subtle but purposeful
- **Spatial Memory**: Users should always understand where they are and how they got there through consistent spatial relationships

#### Specific Interaction Patterns
- **Map Navigation**: Smooth spring-based pan and zoom with momentum decay; heat overlays fade in/out organically as data loads
- **Location Detail Sheet**: Emerges from tapped map location with scale and position animation; maintains spatial relationship to origin point
- **Search Interface**: Search bar expands fluidly from compact state; results animate in with staggered timing for readability
- **Tab Transitions**: Shared elements (map, persistent UI) remain stationary while content transitions around them
- **Modal Presentations**: Action sheets slide up with spring physics; card-style modals scale in from interaction point
- **Favorites Animation**: Heart/favorite button uses satisfying spring animation with scale and color transition
- **Loading States**: Skeleton screens and progressive disclosure rather than spinners; content appears as it becomes available
- **Pull-to-Refresh**: Uses natural spring physics with satisfying snap-back and content fade-in

## Functional Requirements

### Location & Presence
- Home location: saved during onboarding; can be reset; stored locally and never shared raw
- Presence visibility: user is hidden to others if within 500 ft (~152.4 m) of Home
- Visible presence away from Home: approximated to a 100 ft (~30.5 m) radius region, not a pinpoint
- Update cadence: foreground every 30–60 seconds; background limited and opportunistic (per iOS constraints)
- Never render a single user’s presence to others; show only aggregated tiles meeting k‑anonymity thresholds

### Interest Integrations
- Apple Maps (Priority 1): import saved/favorited locations and collections; extract place categories and preferences (restaurants, cafes, venues, etc.)
- Photos (Priority 2): infer venue/place types from geotagged photos (only if user opts in); process on-device and share only abstracted tags
- In-App Favorites: user can favorite/rate locations discovered through search or map exploration; builds personalized preference profile
- Spotify: fetch top artists, tracks, genres (time ranges: short/medium/long)
- Instagram: limited by Graph API scope; target interests via follows/categories if permitted; otherwise fallback to declared interests
- Each integration is optional; similarity falls back to available signals

### Heatmap & Similarity
- Users contribute heat to a spatial tile if away from Home and in foreground/background (subject to privacy throttle)
- Heat intensity per tile is weighted by similarity to the viewing user’s interest vector
- Neighboring tiles blend smoothly for a continuous heatmap effect

### Personalized Search & Recommendations
- Search interface integrated into map view for discovering places aligned with user interests
- Query processing combines traditional place search with interest-based ranking using aggregated user data
- Results prioritized by: (1) interest alignment score, (2) aggregated user activity/heat, (3) proximity, (4) general popularity
- ML model processes user's complete interest vector (from all integrations) to score and rank venue matches
- Search suggestions adapt to user's historical preferences and similar users' behaviors
- Fallback to standard map search when insufficient interest data or sparse coverage

### Location Details & In-App Favorites
- Tap-to-reveal location details: action sheet with essential venue information
- Location detail content: name, category, address, hours, image gallery (for context)
- In-app favoriting system: users can favorite/rate discovered locations
- Rating system: simple like/dislike or 1-5 scale (TBD) to differentiate preference strength
- Favorited locations contribute to user's interest vector and search personalization
- Local storage of user favorites with optional cloud sync for cross-device consistency

### Privacy & Safety
- Anonymity: no PII or handles rendered or retrievable from heat tiles
- K‑anonymity: a tile is rendered only if at least k_min distinct contributors (e.g., k_min=5) contributed in the last T minutes
- Differential privacy: calibrated Laplace/Gaussian noise on tile counts pre-rendering
- Home protection: device checks the 500 ft condition locally; server never receives raw Home
- Rate limits and jitter: randomized reporting intervals and per-tile throttling to prevent trajectory inference
- Sensitive POIs: optional suppression near schools, clinics, residences; use a suppression list

### Settings & Controls
- Toggle each integration on/off
- Reset Home
- Export/Delete data
- View privacy policy and data usage explainer

## Non‑Functional Requirements
- Battery: minimize GPS usage; prefer significant-change, visits, and reduced accuracy when possible
- Performance: smooth panning/zooming at 60 fps with overlays
- Scalability: tile aggregator supports ≥100k DAU with low latency tile reads
- Compliance: App privacy labels, Privacy Manifest reasons, user consent, data retention policies

## Architecture

### High-Level
- iOS client (SwiftUI + MapKit) handles permissions, on-device Home geofence, integration auth, and map rendering
- Backend services:
  - Auth: anonymous auth / device attestation
  - Profile: stores hashed integration tags and similarity-ready vectors
  - Tile Aggregator: ingests tile updates, enforces privacy, returns heatmap tiles per interest weighting
  - Policy: feature flags, thresholds (k_min, DP epsilon), POI suppression
- Storage:
  - Hot: in-memory or Redis for tile counters with short TTL (e.g., 15–30 min)
  - Durable: user profile embeddings/tags, audit logs, minimal operational metrics

### Client
- MapKit with `MKTileOverlay` or custom `MKOverlayRenderer` for heatmaps
- CoreLocation with reduced accuracy + visit/significant-change; precise on-demand when app in foreground
- On-device Home check; only send tile IDs, never raw coordinates
- Keychain for tokens; Secure Enclave where applicable

### Backend
- Location to tile using H3 (recommended) at resolution ≈100–150 m (adjustable)
- Ingest API applies rate limit/jitter, drops near-Home reports if any slip through
- Aggregator maintains counts per (tile_id, cohort_key) with DP noise; enforces k-anonymity
- Tile render API returns intensity fields computed per viewer’s interest vector

## Data Model (conceptual)

### Client (local)
- homeCenter: CLLocationCoordinate2D
- homeRadiusMeters: 152.4 (configurable)
- integrations:
  - spotifyAuthToken (Keychain)
  - instagramAuthToken (Keychain)
  - photosOptIn: Bool
  - appleMapsLocations: [SavedLocation]
- userFavorites: [{ place_id, rating, created_at, notes? }]
- interestVector: Float[N] (derived on device or server)

### Server (durable)
- user_profile: { user_id, integration_tags: [tag], interest_vector: Float[N], last_updated_at }
- user_favorites: { user_id, place_id, rating, created_at, notes? }
- cohort_vocab: { tag -> index }

### Server (ephemeral)
- tile_counts: { tile_id, cohort_bucket, count, last_seen_at }
- tile_noise_seeds: per-epoch DP randomization

## Interest Derivation & Similarity

### Signals
- Apple Maps (Priority 1): saved locations -> venue categories and preference patterns (e.g., coffee_shops, fine_dining, outdoor_recreation)
- Photos (Priority 2): location clusters -> place categories (e.g., cafe, venue, park) -> tags
- In-App Favorites: user-rated locations -> explicit preference signals with strength weighting
- Spotify: top artists -> genres -> tags; audio features -> style tags (e.g., danceability_high)
- Instagram: categories of followed accounts/liked media (if API allows) -> tags

### Vectorization
- Vocabulary: curated tag list across music genres, lifestyle, venue types
- User vector: normalized TF‑IDF or averaged embedding over tags
- Similarity: cosine similarity s in [0,1]
- Heat weight: w = clamp(a*s + b, 0, 1), with a, b tuned; minimum floor to avoid invisibility when low overlap

### Cold Start & Sparse Data Strategy
- Declared Interests: onboarding multi-select of curated tags to seed the vector when integrations are missing
- Popular Defaults: regionally trending tags (server-curated) with low weight to avoid bias
- Progressive Enhancement: re-weight toward real signals as integrations arrive
- Sparse Geography: render “Explore hotspots nearby” empty state and expand query radius; never lower k_min below threshold
- Time Decay: de-emphasize stale contributions to keep heat dynamic

## AI/ML Interest Matching

### Goals
- Convert heterogeneous interest signals (Spotify/Instagram/Photos/declared) into a compact user embedding
- Compute similarity between users and aggregate to tiles while preserving anonymity

### Inputs → Canonical Tags
- Normalize sources into canonical tags, e.g., `music:indie_rock`, `artist:phoebe_bridgers`, `venue:cafe`, `activity:trail_running`
- Include recency and frequency metadata per tag

### Embedding Strategies
- On-Device (preferred for privacy):
  - Model: Sentence-Transformer class converted to Core ML (e.g., all-MiniLM-L6-v2, 384 dims)
  - Pooling: mean pooling over tag embeddings, weighted by recency/frequency (and optional IDF)
  - Pros: privacy, offline; Cons: package size and device perf constraints
- Server-Side (fallback/alternative):
  - Model: E5-small/e5-base or hosted embeddings (e.g., 384–768–1536 dims)
  - Server computes/updates vectors from tags; client may still send only tags

### LLM-Assisted Semantics (Offline Only)
- Purpose: inject semantic understanding of interest relatedness without runtime LLM calls
- Uses:
  - Canonicalization: map raw strings to canonical tags, dedupe synonyms, build taxonomy
  - Relatedness graph: generate tag-to-tag similarity matrix and related-tag edges with strengths
  - Teacher labels: score tag pairs for contrastive training/distillation of a compact embedder
  - Cold-start enrichment: map free-text (if any) to tags in batch
- Outputs (versioned artifacts):
  - `docs/tag_vocab.csv` (canonical tags)
  - `docs/tag_graph.json` (edges with weights)
  - `models/embedding_matrix.npy` (tag embeddings)
  - `models/relatedness_lowrank.npz` (compressed relatedness factors)
- Runtime rule: no LLM inference on device or per request; only embeddings + cosine
- Privacy: LLM inputs are aggregated/de-identified; never include raw locations or PII

### Similarity & Weighting
- User vector v = normalize( Σ w_i · embed(tag_i) )
- Tile vector c = normalize( Σ over contributors v_user + DP_noise ), computed server-side per epoch
- Similarity s = cosine(v_viewer, c)
- Intensity weight w = sigmoid(α · s + β), then intensity = base_count_weight · w
- Calibrate α, β to map s∈[0,1] into visually meaningful alpha range

### Privacy Considerations
- Only tags or embeddings leave device; never raw identities or precise locations
- Tile vectors computed from ≥k_min contributors with differential privacy noise per component
- Round/truncate vectors to float32; no per-user vectors exposed in tile responses

### Performance Targets
- On-device embedding update ≤ 150 ms on median device (384 dims, ≤ 10k tags total vocab)
- Vector size ≤ 1.5 KB (float32·384) per user; updates ≤ 1/day typical, ≤ on change
- Tile aggregation latency ≤ 150 ms p95 per viewport request

### Model Operations
- Versioned model card (name, dims, quantization, checksum) tracked in repo
- A/B support for α, β calibration and dimension choices (e.g., 256 vs 384)
- Periodic re-embedding when integration data changes or every 7 days

### API Notes (updated)
- Client may send either `tags: string[]` or `vector: float[]` at `/v1/profile/interest-vector`
- Server computes/overwrites vector if tags provided; responds with `model_version`
- Tile API accepts viewer vector (optional). If omitted, server uses stored vector

### Evaluation & Acceptance
- Offline: curated pairwise interest similarity set with human labels; target Spearman ≥ 0.6
- Online proxy: CTR on explore hotspots and dwell time improvements without privacy regressions
- Visual QA: intensity monotonic with similarity while respecting k‑anonymity and DP

## Search Ranking & Recommendation Model

### Architecture
- Hybrid model combining collaborative filtering (user-user similarity) with content-based filtering (venue features)
- Input features: user interest vector, venue category embeddings, aggregated user activity per venue, geographic proximity
- Output: relevance score per venue for ranking search results

### Training Data
- Implicit feedback: user visit patterns, dwell time at venues, saved locations from integrations
- Venue features: category, price range, hours, amenities (sourced from Maps APIs)
- Aggregated interaction data: anonymized visit frequency, interest alignment scores per venue

### Model Components
- Interest-venue matching: cosine similarity between user vector and venue category embeddings
- Collaborative signal: venues popular among users with similar interest profiles
- Geographic relevance: distance-weighted scoring with configurable radius
- Popularity baseline: general venue popularity as fallback for cold-start scenarios

### Privacy & Training
- Training uses only aggregated, anonymized interaction patterns
- No individual user trajectories or identifiable visit sequences
- Differential privacy applied to training data aggregation
- Model updates use federated learning principles where possible

### Performance Targets
- Search result ranking latency ≤ 200ms p95
- Relevance improvement: ≥ 15% increase in user engagement vs. baseline map search
- Cold-start handling: graceful degradation to geographic + popularity ranking

## Spatial Tiling & Rendering

### Tiling
- Use native Swift grid tiling at 150m resolution (≈ 100–150 m target). Round device location to tile_id
- Client computes tile_id locally and sends only tile_id + noisy timestamp
- **Implementation Note**: Native `SimpleGridTiler` chosen over H3 for zero dependencies, simpler privacy auditing, and reduced complexity

### Rendering Strategy
- Option A (server tiles): pre-render PNG heat tiles per zoom; simple client
- Option B (vector): return tile_id + intensity; client draws radial gradients per tile with blending
- MVP: Option B for flexibility and faster iteration

### Blending
- For each visible tile: draw a radial gradient circle (~100 ft radius in meters per zoom) with alpha = intensity
- Combine with additive blending, capped at maxAlpha to avoid oversaturation

## Privacy Model (Guarantees)
- Never show tiles with < k_min contributors in last T minutes (rolling window)
- Add DP noise ε-configurable; publish only aggregates
- Suppress reporting within 500 ft of Home (device-side)
- Randomize report intervals (±15–45 s) and drop per-tile rapid repeats
- No storage of raw paths; delete ephemeral location reports after aggregation window
- No user lookups by tile; server decouples user_id from tile ingestion using ephemeral tokens

## API (MVP draft)

### Auth
```
POST /v1/auth/anonymous
-> { device_attestation, app_version }
<- { access_token, expires_in }
```

### Profile
```
POST /v1/profile/integrations
-> { spotify: { token }, instagram: { token }, photos: { opted_in: bool }, apple_maps: { saved_locations: [location] } }
<- { status }

POST /v1/profile/interest-vector
-> { vector: float[] | tags: string[] }
<- { status }
```

### Presence Ingest
```
POST /v1/presence/ingest
-> { tile_id: string, epoch_ms: number, client_jitter_ms: number }
<- { accepted: bool }
```

### Heat Tiles
```
POST /v1/tiles/heat
-> { viewport: { ne, sw, zoom }, interest_vector: float[], client_version }
<- { tiles: [ { tile_id, intensity } ], meta: { k_min, epsilon, ttl_s } }
```

### Search & Recommendations
```
POST /v1/search/places
-> { query: string, location: { lat, lng }, radius_km: number, interest_vector: float[] }
<- { results: [ { place_id, name, category, location, relevance_score, interest_alignment } ], meta: { total_results, search_time_ms } }

GET /v1/search/suggestions
-> { location: { lat, lng }, interest_vector: float[], limit: number }
<- { suggestions: [ { place_id, name, category, location, reason: string } ] }
```

### Location Details & Favorites
```
GET /v1/places/{place_id}/details
-> { }
<- { place_id, name, category, address, hours, images: [url], phone, website, user_favorite_status }

POST /v1/favorites
-> { place_id: string, rating: number, notes?: string }
<- { status, favorite_id }

DELETE /v1/favorites/{favorite_id}
-> { }
<- { status }

GET /v1/favorites
-> { }
<- { favorites: [ { favorite_id, place_id, name, category, rating, created_at } ] }
```

## iOS Implementation Plan

### Milestone 0 — Project Skeleton
- [x] SwiftUI `TabView` with Map/Profile
- [x] Location permissions + Home picker UI
- [x] Local 500 ft geofence logic with hysteresis
- [x] Native tiling system (implemented `SimpleGridTiler` - 150m grid, zero dependencies)
- [x] Custom heat overlay renderer with stubbed data
- [x] Info.plist strings + Privacy Manifest reasons 

### Milestone 1 — Location & Home Geofence
- Onboarding flow to set Home (drop pin or current location)
- Local check: hide presence when distance(Home, current) < 500 ft (with hysteresis, e.g., 450/550 ft)
- Show own 100 ft radius overlay when visible

### Milestone 2 — Tiling & Local Heat Rendering (stubbed data)
- H3 tiling on device
- Local synthetic heatmap to validate rendering and performance
- Custom overlay renderer with radial gradients and blending

### Milestone 3 — Backend MVP
- Anonymous auth
- Presence ingest: accept tile_id, apply rate limits
- Heat tiles API: return intensities for viewport (no DP first, then add)
- K‑anonymity gating and DP noise

### Milestone 4 — Priority Integrations & Interest Vector
- Apple Maps (Priority 1): import saved locations using MapKit APIs; extract venue categories and preferences
- Photos (Priority 2): on-device clustering of PHAsset locations -> place categories -> tags (send tags only)
- In-app location details: implement tap-to-reveal action sheet with venue information and fluid animations
- In-app favorites system: implement rating/favoriting functionality with satisfying spring animations
- Core animation system: establish spring physics parameters and shared element transitions
- Client sends tags/vector to server

### Milestone 5 — Additional Integrations
- Spotify OAuth (PKCE), fetch top artists/genres; map to tags; produce normalized vector
- Instagram integration feasibility check; if limited, implement declared interests UI as fallback
- Integrate in-app favorites into interest vector computation

### Milestone 6 — Similarity‑Weighted Heat
- Server computes/returns intensity weighted by viewer’s vector
- Client blends intensity by similarity
- Tune parameters (a, b) and maxAlpha

### Milestone 7 — Search & Recommendations
- Implement search interface in map view with fluid expansion and query input animations
- Integrate search API with personalized ranking based on interest vector
- Add search suggestions and autocomplete with staggered result animations
- Implement fallback to standard map search for sparse data scenarios

### Milestone 8 — Privacy Hardening & Safety
- Add DP noise, jitter windows, suppression around sensitive POIs
- Document privacy guarantees in-app; add data export/delete

### Milestone 9 — Beta Polish
- Animation refinement: fine-tune spring parameters and timing for optimal feel
- Performance tuning, accessibility (including reduced motion), empty states, error handling
- Comprehensive gesture and interaction polish across all surfaces
- Observability & feature flags

## Acceptance Criteria (per area)

### Location & Home
- Within 500 ft of Home: user’s presence is never sent to server nor rendered to others
- Outside 500 ft: device displays own 100 ft radius; server receives only tile_id, not lat/lng
- Hysteresis prevents rapid toggling when hovering near boundary

### Heatmap
- Panning/zooming is smooth at 60 fps on mid‑range devices
- No tile renders if contributors < k_min; with DP noise enabled
- Intensities increase with higher similarity to viewer

### Integrations
- Apple Maps (Priority 1): successful import of saved locations; venue categories extracted and processed locally
- Photos (Priority 2): user can opt-in/out; only tags (not photo metadata) leave device
- In-App Favorites: users can favorite/rate locations; ratings contribute to personalized recommendations
- Spotify: successful OAuth, revoke, and refresh flows
- Instagram: implemented or gracefully degraded to declared interests

### Search & Recommendations
- Search results return within 200ms for typical queries
- Results ranked by interest alignment show measurable improvement over baseline map search
- Search suggestions adapt to user's integration data and preferences
- Graceful fallback to standard search when insufficient personalization data available

### Location Details & Favorites
- Location detail action sheet displays within 100ms of tap with fluid emergence animation
- Essential venue information (name, category, address, hours, images) loads reliably
- Favoriting system allows users to save and rate locations with satisfying spring-based feedback
- Favorited locations are stored locally and optionally synced across devices
- In-app favorites contribute measurably to search personalization and recommendations

### Animation & Interaction Quality
- All animations maintain 60fps performance on target devices (iPhone 12 and newer)
- Spring physics feel natural and responsive across all micro-interactions
- Shared elements maintain spatial consistency during state transitions
- Modal presentations emerge logically from their triggering interaction point
- Reduced motion alternatives preserve functionality while respecting accessibility preferences
- Animation timing creates clear architectural understanding of navigation flow

### Privacy
- Data export shows only integration tags and anonymized vectors; no raw location history stored
- Ephemeral tile counts expire within TTL (≤30 minutes)
- Suppression list enforced for sensitive POIs

## Edge Cases & Safeguards
- GPS drift near Home boundary → hysteresis and dwell-time checks
- Sparse areas → enforce k_min; show “No data yet” state
- Highly dense events → cap maxAlpha to avoid saturation
- Abuse/spoofing → device attestation, rate limits, sudden jump detection
- Minors → optional age gate; avoid Schools POIs in heat tiles

## Telemetry & Observability
- Client: anonymized performance metrics (render time, API latencies), feature flags
- Server: per-endpoint latency, error rates, tile request volumes; no raw lat/lng logs

## Battery & Performance Notes
- Prefer reduced accuracy and significant-change updates; precise updates only when foreground and interacting
- Coalesce presence reports; backoff when stationary
- Cache heat tiles and reuse across small pans/zooms

## Animation & Motion Specifications

### Spring Physics Parameters
- **Standard Spring**: Damping 0.75, Stiffness 300, Mass 1.0 (for most UI transitions)
- **Snappy Spring**: Damping 0.8, Stiffness 400, Mass 0.8 (for button interactions, favorites)
- **Gentle Spring**: Damping 0.85, Stiffness 200, Mass 1.2 (for large content transitions, modals)
- **Map Spring**: Damping 0.9, Stiffness 250, Mass 1.0 (for map pan/zoom with momentum)

### Timing & Easing
- **Micro-interactions**: 150-300ms (favorites, button states, small UI changes)
- **Content Transitions**: 400-600ms (sheet presentations, tab changes, search expansion)
- **Large State Changes**: 600-800ms (modal presentations, onboarding flow)
- **Map Animations**: Variable duration based on distance/zoom (min 200ms, max 1200ms)

### Performance Guidelines
- Target 60fps for all animations; degrade gracefully on older devices
- Use `CASpringAnimation` and SwiftUI spring modifiers for iOS-native feel
- Prefer transform-based animations (scale, translate, rotate) over frame changes
- Batch animations that occur simultaneously to reduce CPU overhead
- Use `UIViewPropertyAnimator` for interruptible animations (search, scrolling)

### Accessibility Considerations
- Respect `UIAccessibility.isReduceMotionEnabled` with simplified transitions
- Provide alternative feedback (haptic, audio) for motion-dependent interactions
- Ensure animations don't interfere with VoiceOver navigation timing

## Accessibility & UX
- High-contrast heatmap option
- VoiceOver labels for controls; avoid conveying critical info by color alone
- Clear explainer screens about anonymity model
- Reduced motion alternatives for users with motion sensitivity

## Compliance & Policy
- App Store privacy nutrition labels
- Privacy Manifest (location, photos access reasons)
- Data retention: ephemeral counts ≤30 min; user profile vectors deletable
- Third-party API terms (Spotify, Instagram) and scopes kept minimal

## Open Questions
- Target k_min and TTL defaults? (e.g., k_min=5, TTL=20 min)
- Minimum zoom level for tiles to appear?
- Should Home region be encrypted backup across devices or device‑local only?
- Which sensitive POI categories to suppress by default?
- Instagram scope feasibility (may require review); fallback plan priority
- Apple Maps integration: MapKit API limitations for accessing saved locations; privacy implications of importing user's saved places
- Search ranking model: optimal balance between interest alignment, popularity, and geographic proximity
- Cold-start problem: minimum data requirements before personalized search becomes effective

## Additional Integrations (Future Ideas)
- Apple Music: similar to Spotify; map library/play history to genres/tags (requires MusicKit + user consent)
- Last.fm: lightweight scrobble-based genres/artists; good for broader music coverage
- YouTube Music: genres/artists; API feasibility to be validated
- Strava: activity types and preferred environments (trail/road/indoor) -> lifestyle tags; avoid sharing routes
- Eventbrite/Meetup: attended/interest categories -> community/activity tags; only category-level data
- Foursquare Places API: enrich Photos-derived locations to venue categories (on-device categorization preferred)
- Goodreads/Letterboxd/Trakt: media genres to culture tags (books/films/shows)
- Steam/PlayStation/Xbox: high-level game genres (opt-in, no gamer tags surfaced)
- Discord/Reddit: community topic tags (very sensitive; only aggregate topic categories with strict consent)

Constraints: All integrations must produce abstracted tags or embeddings, never identities or friend graphs. Data use must adhere to provider terms and in-app disclosures.

## Technical Notes & References
- Spatial index: Native grid tiling system (150m square tiles) for simplicity and zero dependencies
- iOS: MapKit `MKTileOverlay`, `MKOverlayRenderer`, `CLLocationManager`, `PHPhotoLibrary`
- Similarity: cosine; consider dimensionality N≈256 for future embeddings

## Initial Task Checklist (M0–M4)
- [x] SwiftUI `TabView` with Map/Profile
- [x] Location permissions + Home picker UI
- [x] Local 500 ft geofence logic with hysteresis
- [x] Native tiling system (implemented `SimpleGridTiler` - 150m grid, zero dependencies)
- [x] Custom heat overlay renderer with stubbed data
- [x] Info.plist strings + Privacy Manifest reasons 
- [x] High-contrast heatmap option
- [x] Data export/delete (local settings and Home)
- [ ] Apple Maps saved locations integration (MapKit APIs) - Priority 1
- [ ] Photos location clustering and categorization - Priority 2
- [ ] Core animation system with spring physics parameters
- [ ] Location detail action sheet with fluid emergence animations
- [ ] In-app favorites/rating system with satisfying micro-interactions
- [ ] Shared element transitions for persistent UI components
- [ ] Search interface with fluid expansion and staggered results
- [ ] Search API integration with personalized ranking
- [ ] Search ranking model architecture and training pipeline 