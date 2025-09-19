;; Weather Production Oracle
;; Integration with weather APIs and energy production meters
;; Provides standardized data feeds and maintains historical records

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-invalid-data (err u101))
(define-constant err-data-not-found (err u102))
(define-constant err-unauthorized (err u103))
(define-constant err-already-exists (err u104))

;; Maximum values for validation
(define-constant max-temperature u500) ;; 50.0 degrees Celsius
(define-constant max-humidity u1000) ;; 100.0% humidity
(define-constant max-solar-irradiance u2000) ;; 2000 W/m2
(define-constant max-production u1000000) ;; 1,000,000 kWh

;; Data Maps
(define-map weather-data
  { farm-id: (string-ascii 64), timestamp: uint }
  {
    temperature: uint, ;; Temperature in tenths of degrees Celsius
    humidity: uint, ;; Humidity percentage in tenths
    solar-irradiance: uint, ;; Solar irradiance in W/m2
    cloud-cover: uint, ;; Cloud cover percentage
    wind-speed: uint, ;; Wind speed in km/h
    precipitation: uint, ;; Precipitation in mm
    data-source: (string-ascii 32),
    is-validated: bool
  }
)

(define-map production-data
  { farm-id: (string-ascii 64), timestamp: uint }
  {
    energy-produced: uint, ;; Energy produced in kWh
    capacity-factor: uint, ;; Capacity factor percentage in tenths
    inverter-efficiency: uint, ;; Inverter efficiency percentage in tenths
    system-availability: uint, ;; System availability percentage in tenths
    meter-reading: uint, ;; Raw meter reading
    data-source: (string-ascii 32),
    is-validated: bool
  }
)

(define-map authorized-oracles
  { oracle-address: principal }
  { is-active: bool, oracle-type: (string-ascii 16) }
)

(define-map farm-registry
  { farm-id: (string-ascii 64) }
  {
    owner: principal,
    location: (string-ascii 128),
    capacity: uint, ;; Installed capacity in kW
    registration-date: uint,
    is-active: bool
  }
)

;; Data Variables
(define-data-var total-farms uint u0)
(define-data-var total-weather-records uint u0)
(define-data-var total-production-records uint u0)
(define-data-var data-retention-period uint u8760) ;; 1 year in hours

;; Private Functions

(define-private (validate-weather-data (temperature uint) (humidity uint) (irradiance uint))
  (and
    (<= temperature max-temperature)
    (<= humidity max-humidity)
    (<= irradiance max-solar-irradiance)
  )
)

(define-private (validate-production-data (energy-produced uint) (capacity-factor uint))
  (and
    (<= energy-produced max-production)
    (<= capacity-factor u1000) ;; 100.0% capacity factor
  )
)

(define-private (is-authorized-oracle (oracle principal) (oracle-type (string-ascii 16)))
  (match (map-get? authorized-oracles { oracle-address: oracle })
    oracle-info (and (get is-active oracle-info) 
                    (is-eq (get oracle-type oracle-info) oracle-type))
    false
  )
)

(define-private (calculate-weather-index 
  (temperature uint) (humidity uint) (irradiance uint) (cloud-cover uint))
  ;; Simple weather favorability index (0-1000)
  ;; Higher values indicate better conditions for solar production
  (let (
    (temp-factor (if (and (>= temperature u200) (<= temperature u350))
                    u250 ;; Optimal temperature range 20-35C
                    (- u250 (/ (* (abs (- temperature u275)) u2) u1))))
    (humidity-factor (if (<= humidity u700) u250 (- u250 (/ (- humidity u700) u4))))
    (irradiance-factor (/ (* irradiance u250) max-solar-irradiance))
    (cloud-factor (- u250 (/ (* cloud-cover u250) u100)))
  )
    (+ temp-factor humidity-factor irradiance-factor cloud-factor)
  )
)

(define-private (abs (value uint))
  value ;; Simplified for positive values in this context
)

;; Public Functions

;; Farm Registration
(define-public (register-farm 
  (farm-id (string-ascii 64)) 
  (location (string-ascii 128)) 
  (capacity uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (is-none (map-get? farm-registry { farm-id: farm-id })) err-already-exists)
    (asserts! (> capacity u0) err-invalid-data)
    
    (map-set farm-registry
      { farm-id: farm-id }
      {
        owner: tx-sender,
        location: location,
        capacity: capacity,
        registration-date: stacks-block-height,
        is-active: true
      }
    )
    
    (var-set total-farms (+ (var-get total-farms) u1))
    (ok true)
  )
)

;; Oracle Management
(define-public (add-authorized-oracle 
  (oracle-address principal) 
  (oracle-type (string-ascii 16)))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    (map-set authorized-oracles
      { oracle-address: oracle-address }
      { is-active: true, oracle-type: oracle-type }
    )
    (ok true)
  )
)

(define-public (deactivate-oracle (oracle-address principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    (match (map-get? authorized-oracles { oracle-address: oracle-address })
      oracle-info (begin
        (map-set authorized-oracles
          { oracle-address: oracle-address }
          { is-active: false, oracle-type: (get oracle-type oracle-info) }
        )
        (ok true)
      )
      err-data-not-found
    )
  )
)

;; Weather Data Submission
(define-public (submit-weather-data
  (farm-id (string-ascii 64))
  (timestamp uint)
  (temperature uint)
  (humidity uint)
  (solar-irradiance uint)
  (cloud-cover uint)
  (wind-speed uint)
  (precipitation uint)
  (data-source (string-ascii 32)))
  (begin
    (asserts! (is-authorized-oracle tx-sender "weather") err-unauthorized)
    (asserts! (is-some (map-get? farm-registry { farm-id: farm-id })) err-data-not-found)
    (asserts! (validate-weather-data temperature humidity solar-irradiance) err-invalid-data)
    (asserts! (<= cloud-cover u100) err-invalid-data)
    
    (map-set weather-data
      { farm-id: farm-id, timestamp: timestamp }
      {
        temperature: temperature,
        humidity: humidity,
        solar-irradiance: solar-irradiance,
        cloud-cover: cloud-cover,
        wind-speed: wind-speed,
        precipitation: precipitation,
        data-source: data-source,
        is-validated: true
      }
    )
    
    (var-set total-weather-records (+ (var-get total-weather-records) u1))
    (ok true)
  )
)

;; Production Data Submission
(define-public (submit-production-data
  (farm-id (string-ascii 64))
  (timestamp uint)
  (energy-produced uint)
  (capacity-factor uint)
  (inverter-efficiency uint)
  (system-availability uint)
  (meter-reading uint)
  (data-source (string-ascii 32)))
  (begin
    (asserts! (is-authorized-oracle tx-sender "production") err-unauthorized)
    (asserts! (is-some (map-get? farm-registry { farm-id: farm-id })) err-data-not-found)
    (asserts! (validate-production-data energy-produced capacity-factor) err-invalid-data)
    (asserts! (<= inverter-efficiency u1000) err-invalid-data)
    (asserts! (<= system-availability u1000) err-invalid-data)
    
    (map-set production-data
      { farm-id: farm-id, timestamp: timestamp }
      {
        energy-produced: energy-produced,
        capacity-factor: capacity-factor,
        inverter-efficiency: inverter-efficiency,
        system-availability: system-availability,
        meter-reading: meter-reading,
        data-source: data-source,
        is-validated: true
      }
    )
    
    (var-set total-production-records (+ (var-get total-production-records) u1))
    (ok true)
  )
)

;; Data Retrieval Functions
(define-read-only (get-weather-data (farm-id (string-ascii 64)) (timestamp uint))
  (map-get? weather-data { farm-id: farm-id, timestamp: timestamp })
)

(define-read-only (get-production-data (farm-id (string-ascii 64)) (timestamp uint))
  (map-get? production-data { farm-id: farm-id, timestamp: timestamp })
)

(define-read-only (get-farm-info (farm-id (string-ascii 64)))
  (map-get? farm-registry { farm-id: farm-id })
)

(define-read-only (calculate-expected-production
  (farm-id (string-ascii 64))
  (timestamp uint))
  (match (get-farm-info farm-id)
    farm-info
      (match (get-weather-data farm-id timestamp)
        weather-info
          (let (
            (capacity (get capacity farm-info))
            (irradiance (get solar-irradiance weather-info))
            (weather-idx (calculate-weather-index 
              (get temperature weather-info)
              (get humidity weather-info)
              (get solar-irradiance weather-info)
              (get cloud-cover weather-info)))
          )
            ;; Simple expected production calculation
            ;; Expected = Capacity * (Irradiance/1000) * (Weather_Index/1000) * Hours
            (some (/ (* (* capacity irradiance) weather-idx) u1000000))
          )
        none
      )
    none
  )
)

;; Analytics Functions
(define-read-only (get-statistics)
  {
    total-farms: (var-get total-farms),
    total-weather-records: (var-get total-weather-records),
    total-production-records: (var-get total-production-records),
    contract-owner: contract-owner
  }
)

(define-read-only (is-oracle-authorized (oracle-address principal))
  (match (map-get? authorized-oracles { oracle-address: oracle-address })
    oracle-info (get is-active oracle-info)
    false
  )
)
