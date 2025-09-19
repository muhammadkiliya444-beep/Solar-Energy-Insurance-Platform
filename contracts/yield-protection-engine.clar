;; Yield Protection Engine
;; Automated claims processing based on production shortfalls
;; Manages policy terms, coverage parameters, and claim distributions

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u200))
(define-constant err-invalid-policy (err u201))
(define-constant err-policy-not-found (err u202))
(define-constant err-claim-not-eligible (err u203))
(define-constant err-insufficient-funds (err u204))
(define-constant err-policy-expired (err u205))
(define-constant err-already-claimed (err u206))
(define-constant err-invalid-amount (err u207))
(define-constant err-unauthorized (err u208))

;; Policy constants
(define-constant min-premium u1000) ;; Minimum premium in microSTX
(define-constant max-coverage u10000000) ;; Maximum coverage in microSTX
(define-constant claim-processing-fee u50) ;; 0.5% processing fee
(define-constant min-policy-duration u2160) ;; Minimum 90 days in blocks
(define-constant max-policy-duration u17280) ;; Maximum 720 days in blocks

;; Policy status constants
(define-constant policy-status-active u1)
(define-constant policy-status-expired u2)
(define-constant policy-status-claimed u3)
(define-constant policy-status-cancelled u4)

;; Data Maps
(define-map insurance-policies
  { policy-id: uint }
  {
    farm-id: (string-ascii 64),
    policy-holder: principal,
    coverage-amount: uint,
    premium-paid: uint,
    start-block: uint,
    end-block: uint,
    threshold-percentage: uint, ;; Minimum production percentage (in tenths)
    status: uint,
    total-claims: uint,
    creation-timestamp: uint
  }
)

(define-map claims-registry
  { claim-id: uint }
  {
    policy-id: uint,
    farm-id: (string-ascii 64),
    period-start: uint,
    period-end: uint,
    expected-production: uint,
    actual-production: uint,
    shortfall-percentage: uint,
    claim-amount: uint,
    status: uint, ;; 1=pending, 2=approved, 3=rejected, 4=paid
    submission-block: uint,
    processing-block: uint
  }
)

(define-map premium-pool
  { pool-id: uint }
  { total-collected: uint, total-paid: uint, reserve-amount: uint }
)

(define-map policy-performance
  { policy-id: uint, period: uint }
  {
    expected-production: uint,
    actual-production: uint,
    performance-ratio: uint, ;; Actual/Expected * 1000
    weather-factor: uint,
    claim-triggered: bool
  }
)

;; Data Variables
(define-data-var next-policy-id uint u1)
(define-data-var next-claim-id uint u1)
(define-data-var total-policies uint u0)
(define-data-var total-active-policies uint u0)
(define-data-var total-claims uint u0)
(define-data-var contract-balance uint u0)
(define-data-var claim-threshold uint u800) ;; 80% production threshold
(define-data-var auto-processing-enabled bool true)

;; Private Functions

(define-private (validate-policy-parameters 
  (coverage-amount uint) 
  (premium uint) 
  (duration uint) 
  (threshold uint))
  (and
    (>= premium min-premium)
    (<= coverage-amount max-coverage)
    (>= duration min-policy-duration)
    (<= duration max-policy-duration)
    (>= threshold u500) ;; Minimum 50% threshold
    (<= threshold u950) ;; Maximum 95% threshold
    (>= (* premium u20) coverage-amount) ;; Premium should be at least 5% of coverage
  )
)

(define-private (calculate-claim-amount 
  (coverage uint) 
  (shortfall-percentage uint) 
  (threshold uint))
  (if (>= shortfall-percentage threshold)
    ;; Progressive payout based on shortfall severity
    (let (
      (excess-shortfall (- shortfall-percentage threshold))
      (base-payout (/ (* coverage threshold) u1000))
      (bonus-payout (/ (* coverage excess-shortfall) u2000))
    )
      (+ base-payout bonus-payout)
    )
    u0
  )
)

(define-private (is-policy-active (policy-id uint))
  (match (map-get? insurance-policies { policy-id: policy-id })
    policy-data
      (and
        (is-eq (get status policy-data) policy-status-active)
        (>= stacks-block-height (get start-block policy-data))
        (<= stacks-block-height (get end-block policy-data))
      )
    false
  )
)

(define-private (calculate-premium-requirement 
  (coverage-amount uint) 
  (duration uint) 
  (risk-factor uint))
  ;; Base premium calculation: Coverage * Duration * Risk Factor
  (/ (* (* coverage-amount duration) risk-factor) u100000000)
)

(define-private (update-contract-balance (amount uint) (operation (string-ascii 8)))
  (if (is-eq operation "add")
    (var-set contract-balance (+ (var-get contract-balance) amount))
    (var-set contract-balance (- (var-get contract-balance) amount))
  )
)

;; Public Functions

;; Policy Creation
(define-public (create-policy
  (farm-id (string-ascii 64))
  (coverage-amount uint)
  (duration uint)
  (threshold-percentage uint))
  (let (
    (policy-id (var-get next-policy-id))
    (premium-required (calculate-premium-requirement coverage-amount duration u100))
    (start-block stacks-block-height)
    (end-block (+ stacks-block-height duration))
  )
    (asserts! (validate-policy-parameters 
                coverage-amount premium-required duration threshold-percentage) 
              err-invalid-policy)
    (asserts! (>= (stx-get-balance tx-sender) premium-required) err-insufficient-funds)
    
    ;; Transfer premium to contract
    (try! (stx-transfer? premium-required tx-sender (as-contract tx-sender)))
    
    ;; Create policy record
    (map-set insurance-policies
      { policy-id: policy-id }
      {
        farm-id: farm-id,
        policy-holder: tx-sender,
        coverage-amount: coverage-amount,
        premium-paid: premium-required,
        start-block: start-block,
        end-block: end-block,
        threshold-percentage: threshold-percentage,
        status: policy-status-active,
        total-claims: u0,
        creation-timestamp: stacks-block-height
      }
    )
    
    ;; Update counters
    (var-set next-policy-id (+ policy-id u1))
    (var-set total-policies (+ (var-get total-policies) u1))
    (var-set total-active-policies (+ (var-get total-active-policies) u1))
    (update-contract-balance premium-required "add")
    
    (ok policy-id)
  )
)

;; Claim Submission
(define-public (submit-claim
  (policy-id uint)
  (period-start uint)
  (period-end uint)
  (expected-production uint)
  (actual-production uint))
  (let (
    (claim-id (var-get next-claim-id))
    (shortfall-percentage (if (> expected-production u0)
                           (- u1000 (/ (* actual-production u1000) expected-production))
                           u0))
  )
    (asserts! (is-policy-active policy-id) err-policy-expired)
    (asserts! (> expected-production u0) err-invalid-amount)
    (asserts! (< actual-production expected-production) err-claim-not-eligible)
    
    (match (map-get? insurance-policies { policy-id: policy-id })
      policy-data
        (begin
          (asserts! (is-eq tx-sender (get policy-holder policy-data)) err-unauthorized)
          
          ;; Create claim record
          (map-set claims-registry
            { claim-id: claim-id }
            {
              policy-id: policy-id,
              farm-id: (get farm-id policy-data),
              period-start: period-start,
              period-end: period-end,
              expected-production: expected-production,
              actual-production: actual-production,
              shortfall-percentage: shortfall-percentage,
              claim-amount: (calculate-claim-amount 
                             (get coverage-amount policy-data)
                             shortfall-percentage
                             (get threshold-percentage policy-data)),
              status: u1, ;; Pending
              submission-block: stacks-block-height,
              processing-block: u0
            }
          )
          
          ;; Update claim counter
          (var-set next-claim-id (+ claim-id u1))
          (var-set total-claims (+ (var-get total-claims) u1))
          
          ;; Auto-process if enabled and threshold met
          (if (and (var-get auto-processing-enabled)
                   (>= shortfall-percentage (get threshold-percentage policy-data)))
            (process-claim claim-id)
            (ok claim-id)
          )
        )
      err-policy-not-found
    )
  )
)

;; Claim Processing
(define-public (process-claim (claim-id uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    (match (map-get? claims-registry { claim-id: claim-id })
      claim-data
        (begin
          (asserts! (is-eq (get status claim-data) u1) err-already-claimed)
          
          (let (
            (claim-amount (get claim-amount claim-data))
            (processing-fee (/ (* claim-amount claim-processing-fee) u10000))
            (payout-amount (- claim-amount processing-fee))
          )
            (asserts! (>= (var-get contract-balance) claim-amount) err-insufficient-funds)
            
            (match (map-get? insurance-policies { policy-id: (get policy-id claim-data) })
              policy-data
                (begin
                  ;; Transfer payout to policy holder
                  (try! (as-contract (stx-transfer? payout-amount tx-sender 
                                      (get policy-holder policy-data))))
                  
                  ;; Update claim status
                  (map-set claims-registry
                    { claim-id: claim-id }
                    (merge claim-data { status: u4, processing-block: stacks-block-height })
                  )
                  
                  ;; Update policy total claims
                  (map-set insurance-policies
                    { policy-id: (get policy-id claim-data) }
                    (merge policy-data { total-claims: (+ (get total-claims policy-data) u1) })
                  )
                  
                  ;; Update contract balance
                  (update-contract-balance claim-amount "subtract")
                  
                  (ok payout-amount)
                )
              err-policy-not-found
            )
          )
        )
      err-claim-not-eligible
    )
  )
)

;; Policy Management
(define-public (cancel-policy (policy-id uint))
  (match (map-get? insurance-policies { policy-id: policy-id })
    policy-data
      (begin
        (asserts! (is-eq tx-sender (get policy-holder policy-data)) err-unauthorized)
        (asserts! (is-eq (get status policy-data) policy-status-active) err-invalid-policy)
        (asserts! (is-eq (get total-claims policy-data) u0) err-already-claimed)
        
        ;; Calculate refund (partial premium refund based on remaining duration)
        (let (
          (remaining-blocks (- (get end-block policy-data) stacks-block-height))
          (total-duration (- (get end-block policy-data) (get start-block policy-data)))
          (refund-amount (/ (* (get premium-paid policy-data) remaining-blocks) total-duration))
        )
          ;; Transfer refund
          (try! (as-contract (stx-transfer? refund-amount tx-sender tx-sender)))
          
          ;; Update policy status
          (map-set insurance-policies
            { policy-id: policy-id }
            (merge policy-data { status: policy-status-cancelled })
          )
          
          ;; Update counters
          (var-set total-active-policies (- (var-get total-active-policies) u1))
          (update-contract-balance refund-amount "subtract")
          
          (ok refund-amount)
        )
      )
    err-policy-not-found
  )
)

;; Configuration Functions
(define-public (update-claim-threshold (new-threshold uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (and (>= new-threshold u500) (<= new-threshold u950)) err-invalid-amount)
    
    (var-set claim-threshold new-threshold)
    (ok true)
  )
)

(define-public (toggle-auto-processing)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    (var-set auto-processing-enabled (not (var-get auto-processing-enabled)))
    (ok (var-get auto-processing-enabled))
  )
)

;; Read-Only Functions
(define-read-only (get-policy-info (policy-id uint))
  (map-get? insurance-policies { policy-id: policy-id })
)

(define-read-only (get-claim-info (claim-id uint))
  (map-get? claims-registry { claim-id: claim-id })
)

(define-read-only (get-contract-statistics)
  {
    total-policies: (var-get total-policies),
    active-policies: (var-get total-active-policies),
    total-claims: (var-get total-claims),
    contract-balance: (var-get contract-balance),
    claim-threshold: (var-get claim-threshold),
    auto-processing: (var-get auto-processing-enabled)
  }
)

(define-read-only (calculate-policy-premium 
  (coverage-amount uint) 
  (duration uint) 
  (risk-multiplier uint))
  (calculate-premium-requirement coverage-amount duration risk-multiplier)
)

(define-read-only (get-policy-status (policy-id uint))
  (match (map-get? insurance-policies { policy-id: policy-id })
    policy-data
      (if (is-policy-active policy-id)
        "active"
        (if (> stacks-block-height (get end-block policy-data))
          "expired"
          "inactive"
        )
      )
    "not-found"
  )
)

(define-read-only (estimate-claim-payout 
  (policy-id uint) 
  (shortfall-percentage uint))
  (match (map-get? insurance-policies { policy-id: policy-id })
    policy-data
      (some (calculate-claim-amount 
             (get coverage-amount policy-data)
             shortfall-percentage
             (get threshold-percentage policy-data)))
    none
  )
)
