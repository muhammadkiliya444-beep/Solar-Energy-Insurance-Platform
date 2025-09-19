;; Performance Analytics
;; Smart contract for calculating expected vs actual energy production
;; Provides risk assessment metrics and supports underwriting decisions

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u300))
(define-constant err-invalid-data (err u301))
(define-constant err-data-not-found (err u302))
(define-constant err-unauthorized (err u303))
(define-constant err-calculation-error (err u304))
(define-constant err-insufficient-history (err u305))

;; Analytics constants
(define-constant min-data-points u30) ;; Minimum data points for reliable analysis
(define-constant max-historical-periods u365) ;; Maximum historical periods to store
(define-constant performance-excellent u950) ;; 95%+ performance
(define-constant performance-good u850) ;; 85-95% performance
(define-constant performance-average u700) ;; 70-85% performance
(define-constant seasonal-adjustment-factor u100) ;; Base seasonal factor

;; Data Maps
(define-map performance-history
  { farm-id: (string-ascii 64), period: uint }
  {
    expected-production: uint,
    actual-production: uint,
    performance-ratio: uint, ;; Actual/Expected * 1000
    weather-score: uint, ;; Weather favorability score
    efficiency-score: uint, ;; System efficiency score
    availability-score: uint, ;; System availability score
    timestamp: uint,
    data-quality: uint ;; Data quality indicator (0-1000)
  }
)

(define-map farm-analytics
  { farm-id: (string-ascii 64) }
  {
    total-periods: uint,
    average-performance: uint,
    performance-variance: uint,
    best-performance: uint,
    worst-performance: uint,
    seasonal-pattern: (list 12 uint), ;; Monthly performance averages
    risk-score: uint, ;; Overall risk score (0-1000)
    reliability-rating: uint, ;; Reliability rating (0-1000)
    last-updated: uint
  }
)

(define-map weather-correlations
  { farm-id: (string-ascii 64), weather-type: (string-ascii 16) }
  {
    correlation-coefficient: int, ;; -1000 to 1000 (representing -1.0 to 1.0)
    data-points: uint,
    significance-level: uint,
    last-calculated: uint
  }
)

(define-map risk-assessments
  { farm-id: (string-ascii 64), assessment-date: uint }
  {
    production-risk: uint, ;; Risk of underproduction (0-1000)
    weather-risk: uint, ;; Weather-related risk (0-1000)
    technical-risk: uint, ;; Technical/equipment risk (0-1000)
    overall-risk: uint, ;; Combined risk score (0-1000)
    recommended-premium: uint, ;; Suggested premium multiplier
    confidence-level: uint, ;; Confidence in assessment (0-1000)
    assessment-notes: (string-ascii 256)
  }
)

(define-map benchmark-data
  { region: (string-ascii 32), month: uint }
  {
    average-irradiance: uint,
    average-temperature: uint,
    average-production: uint,
    performance-benchmark: uint,
    data-points: uint,
    last-updated: uint
  }
)

;; Data Variables
(define-data-var total-farms-analyzed uint u0)
(define-data-var total-performance-records uint u0)
(define-data-var total-risk-assessments uint u0)
(define-data-var analysis-fee uint u1000) ;; Fee for detailed analysis
(define-data-var benchmark-update-threshold uint u100) ;; Min data points for benchmark update

;; Private Functions

(define-private (validate-performance-data 
  (expected uint) 
  (actual uint) 
  (weather-score uint))
  (and
    (> expected u0)
    (>= actual u0)
    (<= weather-score u1000)
    (<= actual (* expected u2)) ;; Actual shouldn't exceed 2x expected
  )
)

(define-private (calculate-performance-ratio (expected uint) (actual uint))
  (if (> expected u0)
    (/ (* actual u1000) expected)
    u0
  )
)

(define-private (calculate-variance (values (list 10 uint)))
  ;; Simplified variance calculation for up to 10 values
  (let (
    (sum (fold + values u0))
    (count (len values))
    (mean (if (> count u0) (/ sum count) u0))
  )
    (if (> count u1)
      (/ (fold calculate-squared-diff values u0) count)
      u0
    )
  )
)

(define-private (calculate-squared-diff (value uint) (acc uint))
  ;; Helper function for variance calculation
  (let ((diff (if (>= value u500) (- value u500) (- u500 value))))
    (+ acc (* diff diff))
  )
)

(define-private (abs (value int))
  (if (>= value 0) (to-uint value) (to-uint (- value)))
)

(define-private (calculate-seasonal-adjustment (month uint) (base-performance uint))
  ;; Adjust performance based on seasonal patterns
  (let (
    (seasonal-multiplier (if (or (is-eq month u12) (is-eq month u1) (is-eq month u2))
                          u900 ;; Winter months - 90% multiplier
                          (if (or (is-eq month u6) (is-eq month u7) (is-eq month u8))
                            u1100 ;; Summer months - 110% multiplier
                            u1000))) ;; Other months - 100% multiplier
  )
    (/ (* base-performance seasonal-multiplier) u1000)
  )
)

(define-private (calculate-risk-score 
  (avg-performance uint) 
  (variance uint) 
  (data-points uint))
  ;; Calculate overall risk score based on performance metrics
  (let (
    (performance-risk (if (>= avg-performance u800) u200 
                       (if (>= avg-performance u600) u500 u800)))
    (volatility-risk (if (<= variance u5000) u200
                      (if (<= variance u10000) u500 u800)))
    (data-quality-risk (if (>= data-points min-data-points) u100 u400))
  )
    (/ (+ performance-risk volatility-risk data-quality-risk) u3)
  )
)

;; Public Functions

;; Performance Data Recording
(define-public (record-performance
  (farm-id (string-ascii 64))
  (period uint)
  (expected-production uint)
  (actual-production uint)
  (weather-score uint)
  (efficiency-score uint)
  (availability-score uint))
  (begin
    (asserts! (validate-performance-data expected-production actual-production weather-score) 
              err-invalid-data)
    (asserts! (<= efficiency-score u1000) err-invalid-data)
    (asserts! (<= availability-score u1000) err-invalid-data)
    
    (let (
      (performance-ratio (calculate-performance-ratio expected-production actual-production))
      (data-quality (/ (+ weather-score efficiency-score availability-score) u3))
    )
      ;; Record performance data
      (map-set performance-history
        { farm-id: farm-id, period: period }
        {
          expected-production: expected-production,
          actual-production: actual-production,
          performance-ratio: performance-ratio,
          weather-score: weather-score,
          efficiency-score: efficiency-score,
          availability-score: availability-score,
          timestamp: stacks-block-height,
          data-quality: data-quality
        }
      )
      
      ;; Update analytics
      (unwrap! (update-farm-analytics farm-id) err-calculation-error)
      
      ;; Update counters
      (var-set total-performance-records (+ (var-get total-performance-records) u1))
      
      (ok true)
    )
  )
)

;; Analytics Update
(define-public (update-farm-analytics (farm-id (string-ascii 64)))
  (begin
    ;; This would typically iterate through historical data
    ;; Simplified implementation for demonstration
    (let (
      (current-analytics (default-to {
        total-periods: u0,
        average-performance: u0,
        performance-variance: u0,
        best-performance: u0,
        worst-performance: u0,
        seasonal-pattern: (list u0 u0 u0 u0 u0 u0 u0 u0 u0 u0 u0 u0),
        risk-score: u500,
        reliability-rating: u500,
        last-updated: u0
      } (map-get? farm-analytics { farm-id: farm-id })))
    )
      ;; Update analytics record
      (map-set farm-analytics
        { farm-id: farm-id }
        (merge current-analytics {
          total-periods: (+ (get total-periods current-analytics) u1),
          last-updated: stacks-block-height
        })
      )
      
      (ok true)
    )
  )
)

;; Risk Assessment
(define-public (generate-risk-assessment
  (farm-id (string-ascii 64))
  (assessment-notes (string-ascii 256)))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    (match (map-get? farm-analytics { farm-id: farm-id })
      analytics
        (let (
          (production-risk (calculate-risk-score 
                           (get average-performance analytics)
                           (get performance-variance analytics)
                           (get total-periods analytics)))
          (weather-risk u500) ;; Simplified calculation
          (technical-risk u400) ;; Simplified calculation
          (overall-risk (/ (+ production-risk weather-risk technical-risk) u3))
          (recommended-premium (if (<= overall-risk u300) u150
                               (if (<= overall-risk u600) u200 u300)))
        )
          ;; Create risk assessment
          (map-set risk-assessments
            { farm-id: farm-id, assessment-date: stacks-block-height }
            {
              production-risk: production-risk,
              weather-risk: weather-risk,
              technical-risk: technical-risk,
              overall-risk: overall-risk,
              recommended-premium: recommended-premium,
              confidence-level: (if (>= (get total-periods analytics) min-data-points) u900 u600),
              assessment-notes: assessment-notes
            }
          )
          
          (var-set total-risk-assessments (+ (var-get total-risk-assessments) u1))
          (ok overall-risk)
        )
      err-data-not-found
    )
  )
)

;; Benchmark Management
(define-public (update-benchmark
  (region (string-ascii 32))
  (month uint)
  (avg-irradiance uint)
  (avg-temperature uint)
  (avg-production uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (and (>= month u1) (<= month u12)) err-invalid-data)
    
    (let (
      (performance-benchmark (calculate-seasonal-adjustment month avg-production))
      (current-data (default-to {
        average-irradiance: u0,
        average-temperature: u0,
        average-production: u0,
        performance-benchmark: u0,
        data-points: u0,
        last-updated: u0
      } (map-get? benchmark-data { region: region, month: month })))
    )
      ;; Update benchmark data
      (map-set benchmark-data
        { region: region, month: month }
        {
          average-irradiance: avg-irradiance,
          average-temperature: avg-temperature,
          average-production: avg-production,
          performance-benchmark: performance-benchmark,
          data-points: (+ (get data-points current-data) u1),
          last-updated: stacks-block-height
        }
      )
      
      (ok true)
    )
  )
)

;; Analysis Functions
(define-public (calculate-expected-production
  (farm-id (string-ascii 64))
  (weather-conditions (list 5 uint)))
  (begin
    ;; Simplified expected production calculation
    ;; In practice, this would use machine learning models
    (match (map-get? farm-analytics { farm-id: farm-id })
      analytics
        (let (
          (base-performance (get average-performance analytics))
          (weather-adjustment (/ (fold + weather-conditions u0) (len weather-conditions)))
          (adjusted-performance (/ (* base-performance weather-adjustment) u1000))
        )
          (ok adjusted-performance)
        )
      err-data-not-found
    )
  )
)

;; Read-Only Functions
(define-read-only (get-performance-history (farm-id (string-ascii 64)) (period uint))
  (map-get? performance-history { farm-id: farm-id, period: period })
)

(define-read-only (get-farm-analytics (farm-id (string-ascii 64)))
  (map-get? farm-analytics { farm-id: farm-id })
)

(define-read-only (get-risk-assessment (farm-id (string-ascii 64)) (assessment-date uint))
  (map-get? risk-assessments { farm-id: farm-id, assessment-date: assessment-date })
)

(define-read-only (get-benchmark-data (region (string-ascii 32)) (month uint))
  (map-get? benchmark-data { region: region, month: month })
)

(define-read-only (calculate-performance-score (farm-id (string-ascii 64)))
  (match (map-get? farm-analytics { farm-id: farm-id })
    analytics
      (let (
        (avg-perf (get average-performance analytics))
        (reliability (get reliability-rating analytics))
      )
        (some (/ (+ avg-perf reliability) u2))
      )
    none
  )
)

(define-read-only (get-risk-category (risk-score uint))
  (if (<= risk-score u300)
    "low"
    (if (<= risk-score u600)
      "medium"
      "high"
    )
  )
)

(define-read-only (get-performance-trend (farm-id (string-ascii 64)))
  ;; Simplified trend analysis
  (match (map-get? farm-analytics { farm-id: farm-id })
    analytics
      (let (
        (current-perf (get average-performance analytics))
        (variance (get performance-variance analytics))
      )
        (if (< variance u2000)
          "stable"
          (if (>= current-perf u800)
            "improving"
            "declining"
          )
        )
      )
    "insufficient-data"
  )
)

(define-read-only (get-analytics-statistics)
  {
    total-farms-analyzed: (var-get total-farms-analyzed),
    total-performance-records: (var-get total-performance-records),
    total-risk-assessments: (var-get total-risk-assessments),
    analysis-fee: (var-get analysis-fee)
  }
)

(define-read-only (estimate-production-confidence (farm-id (string-ascii 64)))
  (match (map-get? farm-analytics { farm-id: farm-id })
    analytics
      (let (
        (data-points (get total-periods analytics))
        (variance (get performance-variance analytics))
      )
        (if (>= data-points min-data-points)
          (- u1000 (/ variance u10)) ;; Higher variance = lower confidence
          (/ (* data-points u1000) min-data-points) ;; Confidence increases with data points
        )
      )
    u0
  )
)
