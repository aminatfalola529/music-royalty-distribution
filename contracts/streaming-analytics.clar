;; streaming-analytics
;; Analytics contract tracking music streaming and usage for royalty distribution

;; Error constants
(define-constant ERR_NOT_AUTHORIZED (err u500))
(define-constant ERR_TRACK_NOT_FOUND (err u501))
(define-constant ERR_INVALID_INPUT (err u502))
(define-constant ERR_PLATFORM_NOT_REGISTERED (err u503))
(define-constant ERR_DUPLICATE_ENTRY (err u504))
(define-constant ERR_INVALID_SIGNATURE (err u505))
(define-constant ERR_INSUFFICIENT_DATA (err u506))
(define-constant ERR_FRAUD_DETECTED (err u507))
(define-constant ERR_RATE_LIMIT_EXCEEDED (err u508))

;; Contract constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant MAX_PLATFORMS u50)
(define-constant MIN_STREAM_COUNT u1)
(define-constant FRAUD_THRESHOLD u10000) ;; Streams that trigger fraud detection
(define-constant REPORTING_WINDOW u144) ;; ~24 hours in blocks

;; Platform types
(define-constant PLATFORM_SPOTIFY u1)
(define-constant PLATFORM_APPLE_MUSIC u2)
(define-constant PLATFORM_YOUTUBE_MUSIC u3)
(define-constant PLATFORM_AMAZON_MUSIC u4)
(define-constant PLATFORM_SOUNDCLOUD u5)
(define-constant PLATFORM_TIDAL u6)
(define-constant PLATFORM_DEEZER u7)
(define-constant PLATFORM_BANDCAMP u8)

;; Revenue tier constants
(define-constant TIER_PREMIUM u1)
(define-constant TIER_FREE u2)
(define-constant TIER_FAMILY u3)
(define-constant TIER_STUDENT u4)

;; Data variables
(define-data-var total-tracks uint u0)
(define-data-var total-streams uint u0)
(define-data-var total-revenue uint u0)
(define-data-var next-track-id uint u1)
(define-data-var analytics-enabled bool true)

;; Data structures
(define-map tracks
  { track-id: uint }
  {
    track-title: (string-ascii 128),
    artist-name: (string-ascii 128),
    album-name: (optional (string-ascii 128)),
    duration-seconds: uint,
    release-date: uint,
    genre: (string-ascii 64),
    isrc-code: (optional (string-ascii 32)),
    owner: principal,
    total-streams: uint,
    total-revenue: uint,
    verified: bool
  }
)

(define-map streaming-platforms
  { platform-id: uint }
  {
    platform-name: (string-ascii 64),
    revenue-per-stream: uint, ;; in micro-tokens
    is-active: bool,
    registration-date: uint,
    total-tracks: uint,
    total-streams: uint,
    api-key-hash: (buff 32),
    contact-principal: principal
  }
)

(define-map streaming-data
  { track-id: uint, platform-id: uint, reporting-period: uint }
  {
    stream-count: uint,
    unique-listeners: uint,
    revenue-generated: uint,
    geographic-data: (optional (string-ascii 256)),
    demographic-data: (optional (string-ascii 256)),
    timestamp: uint,
    verified: bool,
    data-hash: (buff 32)
  }
)

(define-map listener-analytics
  { track-id: uint, country-code: (string-ascii 4) }
  {
    listener-count: uint,
    stream-count: uint,
    revenue-share: uint,
    engagement-score: uint,
    last-updated: uint
  }
)

(define-map platform-track-performance
  { platform-id: uint, track-id: uint }
  {
    total-streams: uint,
    total-revenue: uint,
    average-daily-streams: uint,
    peak-daily-streams: uint,
    first-stream-date: uint,
    last-stream-date: uint,
    trending-score: uint
  }
)

(define-map fraud-detection-flags
  { track-id: uint, flag-type: (string-ascii 32) }
  {
    flag-reason: (string-ascii 256),
    severity: uint,
    detected-at: uint,
    investigated: bool,
    resolved: bool,
    reporter: principal
  }
)

(define-map revenue-analytics
  { track-id: uint, period-start: uint }
  {
    period-end: uint,
    total-streams: uint,
    gross-revenue: uint,
    net-revenue: uint,
    platform-breakdown: (optional (string-ascii 512)),
    growth-rate: uint
  }
)

(define-map artist-portfolio
  { artist: principal }
  {
    total-tracks: uint,
    total-streams: uint,
    total-revenue: uint,
    avg-revenue-per-stream: uint,
    top-performing-track: (optional uint),
    last-updated: uint
  }
)

;; Private functions

(define-private (increment-track-id)
  (let ((current-id (var-get next-track-id)))
    (var-set next-track-id (+ current-id u1))
    current-id
  )
)

(define-private (is-valid-platform (platform-id uint))
  (match (map-get? streaming-platforms { platform-id: platform-id })
    platform-data (get is-active platform-data)
    false
  )
)

(define-private (calculate-revenue-per-stream (platform-id uint) (tier uint))
  (let (
    (base-rate (default-to u0 
                 (get revenue-per-stream 
                   (map-get? streaming-platforms { platform-id: platform-id }))))
  )
    (if (is-eq tier TIER_PREMIUM)
      (* base-rate u15 (/ u1 u10)) ;; 1.5x for premium
      (if (is-eq tier TIER_FAMILY)
        (* base-rate u12 (/ u1 u10)) ;; 1.2x for family
        (if (is-eq tier TIER_STUDENT)
          (* base-rate u8 (/ u1 u10)) ;; 0.8x for student
          base-rate))) ;; Standard rate for free tier
  )
)

(define-private (detect-potential-fraud (track-id uint) (stream-count uint) (platform-id uint))
  (let (
    (track-data (unwrap! (map-get? tracks { track-id: track-id }) false))
    (historical-avg (/ (get total-streams track-data) u30)) ;; 30-day average
  )
    (if (and (> stream-count FRAUD_THRESHOLD)
             (> stream-count (* historical-avg u10))) ;; 10x normal rate
      (begin
        (map-set fraud-detection-flags
          { track-id: track-id, flag-type: "unusual-spike" }
          {
            flag-reason: "Stream count significantly exceeds historical average",
            severity: u7,
            detected-at: block-height,
            investigated: false,
            resolved: false,
            reporter: CONTRACT_OWNER
          }
        )
        true
      )
      false
    )
  )
)

(define-private (update-artist-portfolio (artist principal) (track-id uint) (revenue-delta uint))
  (let (
    (current-portfolio (default-to {
      total-tracks: u0,
      total-streams: u0,
      total-revenue: u0,
      avg-revenue-per-stream: u0,
      top-performing-track: none,
      last-updated: u0
    } (map-get? artist-portfolio { artist: artist })))
    (track-data (unwrap! (map-get? tracks { track-id: track-id }) false))
  )
    (map-set artist-portfolio
      { artist: artist }
      {
        total-tracks: (get total-tracks current-portfolio),
        total-streams: (+ (get total-streams current-portfolio) (get total-streams track-data)),
        total-revenue: (+ (get total-revenue current-portfolio) revenue-delta),
        avg-revenue-per-stream: (if (> (get total-streams current-portfolio) u0)
                                 (/ (get total-revenue current-portfolio) (get total-streams current-portfolio))
                                 u0),
        top-performing-track: (get top-performing-track current-portfolio),
        last-updated: block-height
      }
    )
    true
  )
)

;; Read-only functions

(define-read-only (get-track-info (track-id uint))
  (map-get? tracks { track-id: track-id })
)

(define-read-only (get-streaming-data (track-id uint) (platform-id uint) (reporting-period uint))
  (map-get? streaming-data { track-id: track-id, platform-id: platform-id, reporting-period: reporting-period })
)

(define-read-only (get-platform-info (platform-id uint))
  (map-get? streaming-platforms { platform-id: platform-id })
)

(define-read-only (get-track-performance (platform-id uint) (track-id uint))
  (map-get? platform-track-performance { platform-id: platform-id, track-id: track-id })
)

(define-read-only (get-total-analytics)
  {
    total-tracks: (var-get total-tracks),
    total-streams: (var-get total-streams),
    total-revenue: (var-get total-revenue),
    analytics-enabled: (var-get analytics-enabled)
  }
)

(define-read-only (get-artist-portfolio-data (artist principal))
  (map-get? artist-portfolio { artist: artist })
)

(define-read-only (get-listener-analytics (track-id uint) (country-code (string-ascii 4)))
  (map-get? listener-analytics { track-id: track-id, country-code: country-code })
)

(define-read-only (get-revenue-analytics (track-id uint) (period-start uint))
  (map-get? revenue-analytics { track-id: track-id, period-start: period-start })
)

(define-read-only (calculate-estimated-revenue (stream-count uint) (platform-id uint) (tier uint))
  (let (
    (rate-per-stream (calculate-revenue-per-stream platform-id tier))
  )
    (* stream-count rate-per-stream)
  )
)

(define-read-only (get-fraud-flags (track-id uint))
  (map-get? fraud-detection-flags { track-id: track-id, flag-type: "unusual-spike" })
)

;; Public functions

(define-public (register-streaming-platform 
    (platform-name (string-ascii 64))
    (revenue-per-stream uint)
    (api-key-hash (buff 32))
    (contact-principal principal)
  )
  (let (
    (platform-id (+ (var-get total-tracks) u1)) ;; Simple ID generation
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (asserts! (> revenue-per-stream u0) ERR_INVALID_INPUT)
    
    (map-set streaming-platforms
      { platform-id: platform-id }
      {
        platform-name: platform-name,
        revenue-per-stream: revenue-per-stream,
        is-active: true,
        registration-date: block-height,
        total-tracks: u0,
        total-streams: u0,
        api-key-hash: api-key-hash,
        contact-principal: contact-principal
      }
    )
    
    (ok platform-id)
  )
)

(define-public (register-track 
    (track-title (string-ascii 128))
    (artist-name (string-ascii 128))
    (album-name (optional (string-ascii 128)))
    (duration-seconds uint)
    (genre (string-ascii 64))
    (isrc-code (optional (string-ascii 32)))
  )
  (let (
    (track-id (increment-track-id))
    (artist tx-sender)
  )
    (asserts! (var-get analytics-enabled) ERR_NOT_AUTHORIZED)
    (asserts! (> duration-seconds u0) ERR_INVALID_INPUT)
    
    (map-set tracks
      { track-id: track-id }
      {
        track-title: track-title,
        artist-name: artist-name,
        album-name: album-name,
        duration-seconds: duration-seconds,
        release-date: block-height,
        genre: genre,
        isrc-code: isrc-code,
        owner: artist,
        total-streams: u0,
        total-revenue: u0,
        verified: false
      }
    )
    
    ;; Initialize artist portfolio if it doesn't exist
    (if (is-none (map-get? artist-portfolio { artist: artist }))
      (map-set artist-portfolio
        { artist: artist }
        {
          total-tracks: u1,
          total-streams: u0,
          total-revenue: u0,
          avg-revenue-per-stream: u0,
          top-performing-track: (some track-id),
          last-updated: block-height
        }
      )
      (let (
        (current-portfolio (unwrap-panic (map-get? artist-portfolio { artist: artist })))
      )
        (map-set artist-portfolio
          { artist: artist }
          (merge current-portfolio {
            total-tracks: (+ (get total-tracks current-portfolio) u1),
            last-updated: block-height
          })
        )
      )
    )
    
    (var-set total-tracks (+ (var-get total-tracks) u1))
    
    (ok track-id)
  )
)

(define-public (submit-streaming-data 
    (track-id uint)
    (platform-id uint)
    (stream-count uint)
    (unique-listeners uint)
    (tier uint)
    (geographic-data (optional (string-ascii 256)))
    (demographic-data (optional (string-ascii 256)))
    (data-signature (buff 64))
  )
  (let (
    (reporting-period (/ block-height REPORTING_WINDOW))
    (revenue-generated (calculate-revenue-per-stream platform-id tier))
    (revenue-total (* stream-count revenue-generated))
    (submitter tx-sender)
  )
    (asserts! (is-valid-platform platform-id) ERR_PLATFORM_NOT_REGISTERED)
    (asserts! (is-some (map-get? tracks { track-id: track-id })) ERR_TRACK_NOT_FOUND)
    (asserts! (>= stream-count MIN_STREAM_COUNT) ERR_INVALID_INPUT)
    (asserts! (<= unique-listeners stream-count) ERR_INVALID_INPUT)
    
    ;; Check for duplicate submissions
    (asserts! (is-none (map-get? streaming-data { track-id: track-id, platform-id: platform-id, reporting-period: reporting-period })) ERR_DUPLICATE_ENTRY)
    
    ;; Fraud detection
    (let ((fraud-detected (detect-potential-fraud track-id stream-count platform-id)))
      (if fraud-detected
        ERR_FRAUD_DETECTED
        (begin
          ;; Record streaming data
          (map-set streaming-data
            { track-id: track-id, platform-id: platform-id, reporting-period: reporting-period }
            {
              stream-count: stream-count,
              unique-listeners: unique-listeners,
              revenue-generated: revenue-total,
              geographic-data: geographic-data,
              demographic-data: demographic-data,
              timestamp: block-height,
              verified: true,
              data-hash: (sha256 data-signature)
            }
          )
          
          ;; Update track totals
          (let (
            (track-data (unwrap-panic (map-get? tracks { track-id: track-id })))
          )
            (map-set tracks
              { track-id: track-id }
              (merge track-data {
                total-streams: (+ (get total-streams track-data) stream-count),
                total-revenue: (+ (get total-revenue track-data) revenue-total)
              })
            )
          )
          
          ;; Update platform performance
          (let (
            (current-performance (default-to {
              total-streams: u0,
              total-revenue: u0,
              average-daily-streams: u0,
              peak-daily-streams: u0,
              first-stream-date: block-height,
              last-stream-date: block-height,
              trending-score: u0
            } (map-get? platform-track-performance { platform-id: platform-id, track-id: track-id })))
          )
            (map-set platform-track-performance
              { platform-id: platform-id, track-id: track-id }
              (merge current-performance {
                total-streams: (+ (get total-streams current-performance) stream-count),
                total-revenue: (+ (get total-revenue current-performance) revenue-total),
                peak-daily-streams: (if (> stream-count (get peak-daily-streams current-performance))
                                     stream-count
                                     (get peak-daily-streams current-performance)),
                last-stream-date: block-height
              })
            )
          )
          
          ;; Update global analytics
          (var-set total-streams (+ (var-get total-streams) stream-count))
          (var-set total-revenue (+ (var-get total-revenue) revenue-total))
          
          ;; Update artist portfolio
          (let (
            (track-owner (get owner (unwrap-panic (map-get? tracks { track-id: track-id }))))
          )
            (update-artist-portfolio track-owner track-id revenue-total)
          )
          
          (ok true)
        )
      )
    )
  )
)

(define-public (verify-track (track-id uint))
  (let (
    (track-data (unwrap! (map-get? tracks { track-id: track-id }) ERR_TRACK_NOT_FOUND))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    
    (map-set tracks
      { track-id: track-id }
      (merge track-data { verified: true })
    )
    
    (ok true)
  )
)

(define-public (update-listener-analytics 
    (track-id uint)
    (country-code (string-ascii 4))
    (listener-count uint)
    (stream-count uint)
    (engagement-score uint)
  )
  (let (
    (track-data (unwrap! (map-get? tracks { track-id: track-id }) ERR_TRACK_NOT_FOUND))
  )
    (asserts! (is-eq tx-sender (get owner track-data)) ERR_NOT_AUTHORIZED)
    
    (map-set listener-analytics
      { track-id: track-id, country-code: country-code }
      {
        listener-count: listener-count,
        stream-count: stream-count,
        revenue-share: (/ (* stream-count (get total-revenue track-data)) (get total-streams track-data)),
        engagement-score: engagement-score,
        last-updated: block-height
      }
    )
    
    (ok true)
  )
)

(define-public (generate-revenue-report 
    (track-id uint)
    (period-start uint)
    (period-end uint)
  )
  (let (
    (track-data (unwrap! (map-get? tracks { track-id: track-id }) ERR_TRACK_NOT_FOUND))
    (reporter tx-sender)
  )
    (asserts! (is-eq reporter (get owner track-data)) ERR_NOT_AUTHORIZED)
    (asserts! (> period-end period-start) ERR_INVALID_INPUT)
    
    ;; Calculate revenue for the period (simplified)
    (let (
      (period-streams (/ (get total-streams track-data) u30)) ;; Approximation
      (period-revenue (/ (get total-revenue track-data) u30))
    )
      (map-set revenue-analytics
        { track-id: track-id, period-start: period-start }
        {
          period-end: period-end,
          total-streams: period-streams,
          gross-revenue: period-revenue,
          net-revenue: (* period-revenue u85 (/ u1 u100)), ;; 85% after platform fees
          platform-breakdown: none,
          growth-rate: u0 ;; Would calculate based on historical data
        }
      )
    )
    
    (ok true)
  )
)

(define-public (flag-suspicious-activity 
    (track-id uint)
    (flag-type (string-ascii 32))
    (reason (string-ascii 256))
    (severity uint)
  )
  (begin
    (asserts! (is-some (map-get? tracks { track-id: track-id })) ERR_TRACK_NOT_FOUND)
    (asserts! (<= severity u10) ERR_INVALID_INPUT)
    
    (map-set fraud-detection-flags
      { track-id: track-id, flag-type: flag-type }
      {
        flag-reason: reason,
        severity: severity,
        detected-at: block-height,
        investigated: false,
        resolved: false,
        reporter: tx-sender
      }
    )
    
    (ok true)
  )
)

(define-public (toggle-analytics (enabled bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (var-set analytics-enabled enabled)
    (ok true)
  )
)
