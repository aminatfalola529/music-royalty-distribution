;; royalty-splitter
;; Automated royalty distribution to artists and stakeholders

;; Error constants
(define-constant ERR_NOT_AUTHORIZED (err u600))
(define-constant ERR_TRACK_NOT_FOUND (err u601))
(define-constant ERR_INVALID_PERCENTAGE (err u602))
(define-constant ERR_INSUFFICIENT_BALANCE (err u603))
(define-constant ERR_STAKEHOLDER_NOT_FOUND (err u604))
(define-constant ERR_ALREADY_CLAIMED (err u605))
(define-constant ERR_DISTRIBUTION_LOCKED (err u606))
(define-constant ERR_INVALID_SPLIT (err u607))
(define-constant ERR_ESCROW_DISPUTE (err u608))
(define-constant ERR_PAYMENT_FAILED (err u609))

;; Contract constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant MAX_STAKEHOLDERS u20)
(define-constant MIN_DISTRIBUTION_AMOUNT u1000) ;; Minimum micro-tokens
(define-constant PLATFORM_FEE_PERCENTAGE u5) ;; 5% platform fee
(define-constant ESCROW_PERIOD u1008) ;; ~7 days in blocks
(define-constant MAX_PERCENTAGE u10000) ;; 100.00% in basis points

;; Stakeholder types
(define-constant STAKEHOLDER_ARTIST u1)
(define-constant STAKEHOLDER_PRODUCER u2)
(define-constant STAKEHOLDER_SONGWRITER u3)
(define-constant STAKEHOLDER_LABEL u4)
(define-constant STAKEHOLDER_PUBLISHER u5)
(define-constant STAKEHOLDER_FEATURED_ARTIST u6)
(define-constant STAKEHOLDER_MIXING_ENGINEER u7)
(define-constant STAKEHOLDER_MASTERING_ENGINEER u8)

;; Distribution status constants
(define-constant STATUS_PENDING u1)
(define-constant STATUS_ACTIVE u2)
(define-constant STATUS_DISPUTED u3)
(define-constant STATUS_RESOLVED u4)
(define-constant STATUS_CANCELLED u5)

;; Data variables
(define-data-var total-tracks-with-splits uint u0)
(define-data-var total-distributions uint u0)
(define-data-var total-revenue-distributed uint u0)
(define-data-var next-distribution-id uint u1)
(define-data-var escrow-enabled bool true)

;; Data structures
(define-map royalty-splits
  { track-id: uint }
  {
    track-owner: principal,
    total-stakeholders: uint,
    splits-locked: bool,
    last-modified: uint,
    total-percentage: uint,
    minimum-payout: uint,
    auto-distribute: bool
  }
)

(define-map stakeholder-splits
  { track-id: uint, stakeholder: principal }
  {
    stakeholder-type: uint,
    percentage: uint, ;; in basis points (10000 = 100%)
    role-description: (string-ascii 128),
    added-by: principal,
    added-at: uint,
    total-earned: uint,
    total-claimed: uint
  }
)

(define-map revenue-pools
  { track-id: uint }
  {
    total-revenue: uint,
    unclaimed-revenue: uint,
    platform-fees: uint,
    last-distribution: uint,
    distribution-count: uint,
    is-locked: bool
  }
)

(define-map distribution-records
  { distribution-id: uint }
  {
    track-id: uint,
    total-amount: uint,
    distribution-date: uint,
    stakeholders-paid: uint,
    status: uint,
    initiated-by: principal,
    completion-block: (optional uint)
  }
)

(define-map stakeholder-payments
  { distribution-id: uint, stakeholder: principal }
  {
    amount-due: uint,
    amount-paid: uint,
    payment-date: (optional uint),
    payment-status: uint,
    transaction-hash: (optional (buff 32))
  }
)

(define-map escrow-holdings
  { track-id: uint, period: uint }
  {
    total-amount: uint,
    release-date: uint,
    disputed: bool,
    dispute-reason: (optional (string-ascii 256)),
    resolved: bool,
    resolver: (optional principal)
  }
)

(define-map payment-schedules
  { track-id: uint }
  {
    schedule-type: uint, ;; 1=immediate, 2=daily, 3=weekly, 4=monthly
    minimum-threshold: uint,
    last-payment: uint,
    next-payment-due: uint,
    auto-enabled: bool
  }
)

(define-map collaboration-agreements
  { agreement-id: uint }
  {
    track-id: uint,
    participants: (list 20 principal),
    agreement-hash: (buff 32),
    signed-by: (list 20 principal),
    effective-date: uint,
    expiration-date: (optional uint),
    status: uint
  }
)

;; Private functions

(define-private (increment-distribution-id)
  (let ((current-id (var-get next-distribution-id)))
    (var-set next-distribution-id (+ current-id u1))
    current-id
  )
)

(define-private (validate-percentage-total (track-id uint))
  (let (
    (split-info (unwrap! (map-get? royalty-splits { track-id: track-id }) false))
  )
    (is-eq (get total-percentage split-info) MAX_PERCENTAGE)
  )
)

(define-private (calculate-stakeholder-payment (track-id uint) (stakeholder principal) (total-revenue uint))
  (match (map-get? stakeholder-splits { track-id: track-id, stakeholder: stakeholder })
    split-data (let (
      (percentage (get percentage split-data))
      (payment-amount (/ (* total-revenue percentage) MAX_PERCENTAGE))
    )
      payment-amount
    )
    u0
  )
)

(define-private (deduct-platform-fee (amount uint))
  (let (
    (fee-amount (/ (* amount PLATFORM_FEE_PERCENTAGE) u100))
    (net-amount (- amount fee-amount))
  )
    { fee: fee-amount, net: net-amount }
  )
)

(define-private (is-track-owner (track-id uint) (user principal))
  (match (map-get? royalty-splits { track-id: track-id })
    split-data (is-eq (get track-owner split-data) user)
    false
  )
)

(define-private (process-individual-payment 
    (distribution-id uint)
    (track-id uint)
    (stakeholder principal)
    (amount uint)
  )
  (let (
    (payment-successful (>= (stx-get-balance (as-contract tx-sender)) amount))
  )
    (if payment-successful
      (begin
        ;; Transfer payment
        (try! (as-contract (stx-transfer? amount tx-sender stakeholder)))
        
        ;; Record payment
        (map-set stakeholder-payments
          { distribution-id: distribution-id, stakeholder: stakeholder }
          {
            amount-due: amount,
            amount-paid: amount,
            payment-date: (some block-height),
            payment-status: u1, ;; Paid
            transaction-hash: none ;; Would store actual tx hash
          }
        )
        
        ;; Update stakeholder totals
        (match (map-get? stakeholder-splits { track-id: track-id, stakeholder: stakeholder })
          split-data (map-set stakeholder-splits
                      { track-id: track-id, stakeholder: stakeholder }
                      (merge split-data {
                        total-earned: (+ (get total-earned split-data) amount),
                        total-claimed: (+ (get total-claimed split-data) amount)
                      }))
          false
        )
        
        (ok true)
      )
      ERR_PAYMENT_FAILED
    )
  )
)

;; Read-only functions

(define-read-only (get-royalty-splits (track-id uint))
  (map-get? royalty-splits { track-id: track-id })
)

(define-read-only (get-stakeholder-split (track-id uint) (stakeholder principal))
  (map-get? stakeholder-splits { track-id: track-id, stakeholder: stakeholder })
)

(define-read-only (get-revenue-pool (track-id uint))
  (map-get? revenue-pools { track-id: track-id })
)

(define-read-only (get-distribution-record (distribution-id uint))
  (map-get? distribution-records { distribution-id: distribution-id })
)

(define-read-only (get-stakeholder-payment (distribution-id uint) (stakeholder principal))
  (map-get? stakeholder-payments { distribution-id: distribution-id, stakeholder: stakeholder })
)

(define-read-only (calculate-pending-payment (track-id uint) (stakeholder principal))
  (match (map-get? revenue-pools { track-id: track-id })
    pool-data (let (
      (unclaimed-revenue (get unclaimed-revenue pool-data))
      (stakeholder-amount (calculate-stakeholder-payment track-id stakeholder unclaimed-revenue))
    )
      stakeholder-amount
    )
    u0
  )
)

(define-read-only (get-total-statistics)
  {
    total-tracks-with-splits: (var-get total-tracks-with-splits),
    total-distributions: (var-get total-distributions),
    total-revenue-distributed: (var-get total-revenue-distributed),
    escrow-enabled: (var-get escrow-enabled)
  }
)

(define-read-only (get-escrow-status (track-id uint) (period uint))
  (map-get? escrow-holdings { track-id: track-id, period: period })
)

(define-read-only (get-payment-schedule (track-id uint))
  (map-get? payment-schedules { track-id: track-id })
)

(define-read-only (is-splits-valid (track-id uint))
  (validate-percentage-total track-id)
)

;; Public functions

(define-public (create-royalty-split 
    (track-id uint)
    (minimum-payout uint)
    (auto-distribute bool)
  )
  (let (
    (track-owner tx-sender)
  )
    (asserts! (is-none (map-get? royalty-splits { track-id: track-id })) ERR_INVALID_SPLIT)
    (asserts! (>= minimum-payout MIN_DISTRIBUTION_AMOUNT) ERR_INVALID_SPLIT)
    
    (map-set royalty-splits
      { track-id: track-id }
      {
        track-owner: track-owner,
        total-stakeholders: u0,
        splits-locked: false,
        last-modified: block-height,
        total-percentage: u0,
        minimum-payout: minimum-payout,
        auto-distribute: auto-distribute
      }
    )
    
    ;; Initialize revenue pool
    (map-set revenue-pools
      { track-id: track-id }
      {
        total-revenue: u0,
        unclaimed-revenue: u0,
        platform-fees: u0,
        last-distribution: u0,
        distribution-count: u0,
        is-locked: false
      }
    )
    
    (var-set total-tracks-with-splits (+ (var-get total-tracks-with-splits) u1))
    
    (ok track-id)
  )
)

(define-public (add-stakeholder 
    (track-id uint)
    (stakeholder principal)
    (stakeholder-type uint)
    (percentage uint)
    (role-description (string-ascii 128))
  )
  (let (
    (split-info (unwrap! (map-get? royalty-splits { track-id: track-id }) ERR_TRACK_NOT_FOUND))
  )
    (asserts! (is-track-owner track-id tx-sender) ERR_NOT_AUTHORIZED)
    (asserts! (not (get splits-locked split-info)) ERR_DISTRIBUTION_LOCKED)
    (asserts! (> percentage u0) ERR_INVALID_PERCENTAGE)
    (asserts! (<= percentage MAX_PERCENTAGE) ERR_INVALID_PERCENTAGE)
    (asserts! (< (get total-stakeholders split-info) MAX_STAKEHOLDERS) ERR_INVALID_SPLIT)
    
    ;; Check if adding this percentage would exceed 100%
    (let (
      (new-total-percentage (+ (get total-percentage split-info) percentage))
    )
      (asserts! (<= new-total-percentage MAX_PERCENTAGE) ERR_INVALID_PERCENTAGE)
      
      ;; Add stakeholder
      (map-set stakeholder-splits
        { track-id: track-id, stakeholder: stakeholder }
        {
          stakeholder-type: stakeholder-type,
          percentage: percentage,
          role-description: role-description,
          added-by: tx-sender,
          added-at: block-height,
          total-earned: u0,
          total-claimed: u0
        }
      )
      
      ;; Update split info
      (map-set royalty-splits
        { track-id: track-id }
        (merge split-info {
          total-stakeholders: (+ (get total-stakeholders split-info) u1),
          total-percentage: new-total-percentage,
          last-modified: block-height
        })
      )
      
      (ok stakeholder)
    )
  )
)

(define-public (lock-splits (track-id uint))
  (let (
    (split-info (unwrap! (map-get? royalty-splits { track-id: track-id }) ERR_TRACK_NOT_FOUND))
  )
    (asserts! (is-track-owner track-id tx-sender) ERR_NOT_AUTHORIZED)
    (asserts! (validate-percentage-total track-id) ERR_INVALID_PERCENTAGE)
    
    (map-set royalty-splits
      { track-id: track-id }
      (merge split-info {
        splits-locked: true,
        last-modified: block-height
      })
    )
    
    (ok true)
  )
)

(define-public (add-revenue 
    (track-id uint)
    (amount uint)
  )
  (let (
    (pool-data (unwrap! (map-get? revenue-pools { track-id: track-id }) ERR_TRACK_NOT_FOUND))
    (fee-calculation (deduct-platform-fee amount))
    (net-amount (get net fee-calculation))
    (platform-fee (get fee fee-calculation))
  )
    ;; Revenue can be added by anyone (typically streaming platforms)
    (asserts! (> amount u0) ERR_INSUFFICIENT_BALANCE)
    
    ;; Transfer the funds to the contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Update revenue pool
    (map-set revenue-pools
      { track-id: track-id }
      {
        total-revenue: (+ (get total-revenue pool-data) net-amount),
        unclaimed-revenue: (+ (get unclaimed-revenue pool-data) net-amount),
        platform-fees: (+ (get platform-fees pool-data) platform-fee),
        last-distribution: (get last-distribution pool-data),
        distribution-count: (get distribution-count pool-data),
        is-locked: (get is-locked pool-data)
      }
    )
    
    ;; Auto-distribute if enabled and meets minimum threshold
    (if (is-some (map-get? royalty-splits { track-id: track-id }))
      (let (
        (split-info (unwrap-panic (map-get? royalty-splits { track-id: track-id })))
      )
        (if (and 
              (get auto-distribute split-info)
              (>= (+ (get unclaimed-revenue pool-data) net-amount) (get minimum-payout split-info)))
          (let ((distribution-result (distribute-royalties track-id)))
            (ok true)) ;; Return consistent type regardless of distribution result
          (ok true))
      )
      (ok true)
    )
  )
)

(define-public (distribute-royalties (track-id uint))
  (let (
    (split-info (unwrap! (map-get? royalty-splits { track-id: track-id }) ERR_TRACK_NOT_FOUND))
    (pool-data (unwrap! (map-get? revenue-pools { track-id: track-id }) ERR_TRACK_NOT_FOUND))
    (distribution-id (increment-distribution-id))
    (unclaimed-amount (get unclaimed-revenue pool-data))
  )
    (asserts! (get splits-locked split-info) ERR_DISTRIBUTION_LOCKED)
    (asserts! (>= unclaimed-amount (get minimum-payout split-info)) ERR_INSUFFICIENT_BALANCE)
    (asserts! (not (get is-locked pool-data)) ERR_DISTRIBUTION_LOCKED)
    
    ;; Create distribution record
    (map-set distribution-records
      { distribution-id: distribution-id }
      {
        track-id: track-id,
        total-amount: unclaimed-amount,
        distribution-date: block-height,
        stakeholders-paid: u0,
        status: STATUS_ACTIVE,
        initiated-by: tx-sender,
        completion-block: none
      }
    )
    
    ;; Update revenue pool
    (map-set revenue-pools
      { track-id: track-id }
      (merge pool-data {
        unclaimed-revenue: u0,
        last-distribution: block-height,
        distribution-count: (+ (get distribution-count pool-data) u1)
      })
    )
    
    ;; Update global statistics
    (var-set total-distributions (+ (var-get total-distributions) u1))
    (var-set total-revenue-distributed (+ (var-get total-revenue-distributed) unclaimed-amount))
    
    (ok distribution-id)
  )
)

(define-public (claim-royalty-payment 
    (distribution-id uint)
    (stakeholder principal)
  )
  (let (
    (distribution-record (unwrap! (map-get? distribution-records { distribution-id: distribution-id }) ERR_TRACK_NOT_FOUND))
    (track-id (get track-id distribution-record))
  )
    (asserts! (is-eq stakeholder tx-sender) ERR_NOT_AUTHORIZED)
    (asserts! (is-some (map-get? stakeholder-splits { track-id: track-id, stakeholder: stakeholder })) ERR_STAKEHOLDER_NOT_FOUND)
    
    ;; Check if already paid
    (asserts! (is-none (get payment-date (default-to {
      amount-due: u0,
      amount-paid: u0,
      payment-date: none,
      payment-status: u0,
      transaction-hash: none
    } (map-get? stakeholder-payments { distribution-id: distribution-id, stakeholder: stakeholder })))) ERR_ALREADY_CLAIMED)
    
    (let (
      (payment-amount (calculate-stakeholder-payment track-id stakeholder (get total-amount distribution-record)))
    )
      (asserts! (> payment-amount u0) ERR_INSUFFICIENT_BALANCE)
      
      (process-individual-payment distribution-id track-id stakeholder payment-amount)
    )
  )
)

(define-public (update-payment-schedule 
    (track-id uint)
    (schedule-type uint)
    (minimum-threshold uint)
    (auto-enabled bool)
  )
  (let (
    (split-info (unwrap! (map-get? royalty-splits { track-id: track-id }) ERR_TRACK_NOT_FOUND))
  )
    (asserts! (is-track-owner track-id tx-sender) ERR_NOT_AUTHORIZED)
    (asserts! (<= schedule-type u4) ERR_INVALID_SPLIT)
    
    (map-set payment-schedules
      { track-id: track-id }
      {
        schedule-type: schedule-type,
        minimum-threshold: minimum-threshold,
        last-payment: u0,
        next-payment-due: (+ block-height 
                           (if (is-eq schedule-type u2) u144      ;; Daily
                            (if (is-eq schedule-type u3) u1008     ;; Weekly  
                            (if (is-eq schedule-type u4) u4320     ;; Monthly
                            u0)))),                                 ;; Immediate
        auto-enabled: auto-enabled
      }
    )
    
    (ok true)
  )
)

(define-public (dispute-distribution 
    (track-id uint)
    (period uint)
    (reason (string-ascii 256))
  )
  (let (
    (escrow-data (unwrap! (map-get? escrow-holdings { track-id: track-id, period: period }) ERR_TRACK_NOT_FOUND))
  )
    (asserts! (is-some (map-get? stakeholder-splits { track-id: track-id, stakeholder: tx-sender })) ERR_STAKEHOLDER_NOT_FOUND)
    (asserts! (not (get disputed escrow-data)) ERR_ESCROW_DISPUTE)
    
    (map-set escrow-holdings
      { track-id: track-id, period: period }
      (merge escrow-data {
        disputed: true,
        dispute-reason: (some reason)
      })
    )
    
    (ok true)
  )
)

(define-public (resolve-dispute 
    (track-id uint)
    (period uint)
    (resolution-approved bool)
  )
  (let (
    (escrow-data (unwrap! (map-get? escrow-holdings { track-id: track-id, period: period }) ERR_TRACK_NOT_FOUND))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (asserts! (get disputed escrow-data) ERR_ESCROW_DISPUTE)
    (asserts! (not (get resolved escrow-data)) ERR_ESCROW_DISPUTE)
    
    (map-set escrow-holdings
      { track-id: track-id, period: period }
      (merge escrow-data {
        resolved: true,
        resolver: (some tx-sender)
      })
    )
    
    (ok resolution-approved)
  )
)

(define-public (toggle-escrow (enabled bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (var-set escrow-enabled enabled)
    (ok true)
  )
)
