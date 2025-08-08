## Tidepool — Anonymous Interest Heatmap (Product & Technical Spec)

### Vision
An anti-social social map that anonymously visualizes where people with similar interests are likely congregating. No profiles, no messaging. Only aggregated presence and interest alignment.

### Non‑Goals
- No DMs, friending, or in‑app social graph UI
- No precise coordinates exposed to other users
- No public user identities or handles on the map

## User Experience

### Primary Flows
- Onboarding: grant Location/Photos permissions, set Home location, opt into integrations
- Map tab: view heatmap overlays indicating nearby interest-aligned presence; view own approximate radius when away from Home
- Profile tab: manage integrations (Instagram, Spotify, Photos), data controls, privacy settings

### Navigation
- Tab 1: Home/Map
- Tab 2: Profile/Integrations

### Visual Language
- Heatmap: blended circular fields with opacity/gradient, intensity scaled by interest similarity
- User’s own presence (only visible to self): 100 ft radius translucent ring when ≥ 500 ft from Home

## Functional Requirements

### Location & Presence
- Home location: saved during onboarding; can be reset; stored locally and never shared raw
- Presence visibility: user is hidden to others if within 500 ft (~152.4 m) of Home
- Visible presence away from Home: approximated to a 100 ft (~30.5 m) radius region, not a pinpoint
- Update cadence: foreground every 30–60 seconds; background limited and opportunistic (per iOS constraints)
- Never render a single user’s presence to others; show only aggregated tiles meeting k‑anonymity thresholds

### Interest Integrations
- Spotify: fetch top artists, tracks, genres (time ranges: short/medium/long)
- Instagram: limited by Graph API scope; target interests via follows/categories if permitted; otherwise fallback to declared interests
- Photos: infer venue/place types from geotagged photos (only if user opts in); process on-device and share only abstracted tags
- Each integration is optional; similarity falls back to available signals

### Heatmap & Similarity
- Users contribute heat to a spatial tile if away from Home and in foreground/background (subject to privacy throttle)
- Heat intensity per tile is weighted by similarity to the viewing user’s interest vector
- Neighboring tiles blend smoothly for a continuous heatmap effect

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
- interestVector: Float[N] (derived on device or server)

### Server (durable)
- user_profile: { user_id, integration_tags: [tag], interest_vector: Float[N], last_updated_at }
- cohort_vocab: { tag -> index }

### Server (ephemeral)
- tile_counts: { tile_id, cohort_bucket, count, last_seen_at }
- tile_noise_seeds: per-epoch DP randomization

## Interest Derivation & Similarity

### Signals
- Spotify: top artists -> genres -> tags; audio features -> style tags (e.g., danceability_high)
- Instagram: categories of followed accounts/liked media (if API allows) -> tags
- Photos: location clusters -> place categories (e.g., cafe, venue, park) -> tags

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

## Spatial Tiling & Rendering

### Tiling
- Use H3 resolution r ≈ 8–10 (≈ 100–150 m). Round device location to tile_id
- Client computes tile_id locally and sends only tile_id + noisy timestamp

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
-> { spotify: { token }, instagram: { token }, photos: { opted_in: bool } }
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

## iOS Implementation Plan

### Milestone 0 — Project Skeleton
- SwiftUI app, `TabView` with Map and Profile
- MapKit view scaffold; permission prompts
- Info.plist: NSLocationWhenInUseUsageDescription, NSLocationAlwaysAndWhenInUseUsageDescription, NSPhotoLibraryUsageDescription, NSPhotoLibraryAddUsageDescription, Privacy Manifest reasons

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

### Milestone 4 — Integrations & Interest Vector
- Spotify OAuth (PKCE), fetch top artists/genres; map to tags; produce normalized vector
- Instagram integration feasibility check; if limited, implement declared interests UI as fallback
- Photos: on-device clustering of PHAsset locations -> place categories -> tags (send tags only)
- Client sends tags/vector to server

### Milestone 5 — Similarity‑Weighted Heat
- Server computes/returns intensity weighted by viewer’s vector
- Client blends intensity by similarity
- Tune parameters (a, b) and maxAlpha

### Milestone 6 — Privacy Hardening & Safety
- Add DP noise, jitter windows, suppression around sensitive POIs
- Document privacy guarantees in-app; add data export/delete

### Milestone 7 — Beta Polish
- Performance tuning, accessibility, empty states, error handling
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
- Spotify: successful OAuth, revoke, and refresh flows
- Photos: user can opt-in/out; only tags (not photo metadata) leave device
- Instagram: implemented or gracefully degraded to declared interests

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

## Accessibility & UX
- High-contrast heatmap option
- VoiceOver labels for controls; avoid conveying critical info by color alone
- Clear explainer screens about anonymity model

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
- Spatial index: H3 (Uber) recommended for hex tiling and neighborhood ops
- iOS: MapKit `MKTileOverlay`, `MKOverlayRenderer`, `CLLocationManager`, `PHPhotoLibrary`
- Similarity: cosine; consider dimensionality N≈256 for future embeddings

## Initial Task Checklist (M0–M2)
- [ ] SwiftUI `TabView` with Map/Profile
- [ ] Location permissions + Home picker UI
- [ ] Local 500 ft geofence logic with hysteresis
- [ ] H3 tiling client lib integration or S2 alternative
- [ ] Custom heat overlay renderer with stubbed data
- [ ] Info.plist strings + Privacy Manifest reasons 