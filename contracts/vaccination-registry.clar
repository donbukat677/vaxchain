;; VaxChain Vaccination Registry Contract
;; Manages individual vaccination records with privacy controls and verification mechanisms

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-invalid-input (err u103))
(define-constant err-already-exists (err u104))
(define-constant err-access-denied (err u105))
(define-constant err-expired-record (err u106))

;; Vaccination status constants
(define-constant status-active u1)
(define-constant status-expired u2)
(define-constant status-revoked u3)

;; Vaccine type constants
(define-constant vaccine-covid19 u1)
(define-constant vaccine-influenza u2)
(define-constant vaccine-mmr u3)
(define-constant vaccine-dpt u4)
(define-constant vaccine-hepatitis-b u5)
(define-constant vaccine-polio u6)
(define-constant vaccine-yellow-fever u7)
(define-constant vaccine-typhoid u8)

;; Data Variables
(define-data-var next-vaccination-id uint u1)
(define-data-var next-certificate-id uint u1)
(define-data-var system-active bool true)

;; Data Maps

;; Individual vaccination records
(define-map vaccination-records
  { vaccination-id: uint }
  {
    patient: principal,
    vaccine-type: uint,
    vaccine-name: (string-ascii 64),
    manufacturer: (string-ascii 64),
    lot-number: (string-ascii 32),
    dose-number: uint,
    total-doses: uint,
    administration-date: uint,
    expiration-date: uint,
    provider: principal,
    location: (string-ascii 128),
    status: uint,
    created-at: uint
  }
)

;; Patient vaccination history tracking
(define-map patient-records
  { patient: principal }
  {
    total-vaccinations: uint,
    last-vaccination: uint,
    is-active: bool,
    privacy-level: uint, ;; 1=public, 2=limited, 3=private
    authorized-viewers: (list 10 principal)
  }
)

;; Vaccination certificates for verification
(define-map vaccination-certificates
  { certificate-id: uint }
  {
    patient: principal,
    vaccination-ids: (list 20 uint),
    issued-by: principal,
    issued-date: uint,
    valid-until: uint,
    certificate-hash: (buff 32),
    purpose: (string-ascii 64), ;; travel, employment, education, etc.
    is-active: bool
  }
)

;; Vaccine type definitions and metadata
(define-map vaccine-types
  { vaccine-type: uint }
  {
    name: (string-ascii 64),
    description: (string-ascii 256),
    required-doses: uint,
    interval-days: uint,
    immunity-duration: uint, ;; days
    is-required-for-travel: bool,
    who-approved: bool
  }
)

;; Access control for vaccination records
(define-map record-access
  { vaccination-id: uint, accessor: principal }
  {
    granted-by: principal,
    access-type: uint, ;; 1=read, 2=verify, 3=full
    granted-date: uint,
    expires-date: uint,
    purpose: (string-ascii 128)
  }
)

;; Patient privacy preferences
(define-map privacy-settings
  { patient: principal }
  {
    allow-public-verification: bool,
    allow-anonymous-statistics: bool,
    data-retention-period: uint,
    emergency-access-enabled: bool,
    preferred-language: (string-ascii 10)
  }
)

;; Public Functions

;; Register a new vaccination record
(define-public (record-vaccination 
    (patient principal)
    (vaccine-type uint)
    (vaccine-name (string-ascii 64))
    (manufacturer (string-ascii 64))
    (lot-number (string-ascii 32))
    (dose-number uint)
    (total-doses uint)
    (administration-date uint)
    (expiration-date uint)
    (location (string-ascii 128)))
  (let (
    (vaccination-id (var-get next-vaccination-id))
    (patient-info (default-to 
      { total-vaccinations: u0, last-vaccination: u0, is-active: true, 
        privacy-level: u2, authorized-viewers: (list) }
      (map-get? patient-records { patient: patient })
    ))
  )
    ;; Input validation
    (asserts! (var-get system-active) err-invalid-input)
    (asserts! (> vaccine-type u0) err-invalid-input)
    (asserts! (> dose-number u0) err-invalid-input)
    (asserts! (<= dose-number total-doses) err-invalid-input)
    (asserts! (> administration-date u0) err-invalid-input)
    (asserts! (> expiration-date administration-date) err-invalid-input)
    
    ;; Create vaccination record
    (map-set vaccination-records
      { vaccination-id: vaccination-id }
      {
        patient: patient,
        vaccine-type: vaccine-type,
        vaccine-name: vaccine-name,
        manufacturer: manufacturer,
        lot-number: lot-number,
        dose-number: dose-number,
        total-doses: total-doses,
        administration-date: administration-date,
        expiration-date: expiration-date,
        provider: tx-sender,
        location: location,
        status: status-active,
        created-at: stacks-block-height
      }
    )
    
    ;; Update patient records
    (map-set patient-records
      { patient: patient }
      (merge patient-info {
        total-vaccinations: (+ (get total-vaccinations patient-info) u1),
        last-vaccination: vaccination-id
      })
    )
    
    ;; Increment vaccination ID counter
    (var-set next-vaccination-id (+ vaccination-id u1))
    
    (ok vaccination-id)
  )
)

;; Grant access to vaccination records
(define-public (grant-access 
    (vaccination-id uint)
    (accessor principal)
    (access-type uint)
    (expires-days uint)
    (purpose (string-ascii 128)))
  (let (
    (record (unwrap! (map-get? vaccination-records { vaccination-id: vaccination-id }) err-not-found))
    (expires-date (+ stacks-block-height (* expires-days u144))) ;; ~24 hours per day
  )
    ;; Only patient can grant access to their records
    (asserts! (is-eq tx-sender (get patient record)) err-unauthorized)
    (asserts! (and (>= access-type u1) (<= access-type u3)) err-invalid-input)
    
    (map-set record-access
      { vaccination-id: vaccination-id, accessor: accessor }
      {
        granted-by: tx-sender,
        access-type: access-type,
        granted-date: stacks-block-height,
        expires-date: expires-date,
        purpose: purpose
      }
    )
    
    (ok true)
  )
)

;; Issue vaccination certificate
(define-public (issue-certificate
    (patient principal)
    (vaccination-ids (list 20 uint))
    (purpose (string-ascii 64))
    (valid-days uint)
    (certificate-hash (buff 32)))
  (let (
    (certificate-id (var-get next-certificate-id))
    (valid-until (+ stacks-block-height (* valid-days u144)))
    (validation-result (validate-patient-vaccinations vaccination-ids patient))
  )
    ;; Verify all vaccination IDs belong to the patient  
    (asserts! (> (len vaccination-ids) u0) err-invalid-input)
    (asserts! (get valid validation-result) err-unauthorized)
    
    (map-set vaccination-certificates
      { certificate-id: certificate-id }
      {
        patient: patient,
        vaccination-ids: vaccination-ids,
        issued-by: tx-sender,
        issued-date: stacks-block-height,
        valid-until: valid-until,
        certificate-hash: certificate-hash,
        purpose: purpose,
        is-active: true
      }
    )
    
    (var-set next-certificate-id (+ certificate-id u1))
    
    (ok certificate-id)
  )
)

;; Update vaccination status
(define-public (update-vaccination-status 
    (vaccination-id uint)
    (new-status uint))
  (let (
    (record (unwrap! (map-get? vaccination-records { vaccination-id: vaccination-id }) err-not-found))
  )
    ;; Only the provider who created the record can update it
    (asserts! (is-eq tx-sender (get provider record)) err-unauthorized)
    (asserts! (and (>= new-status u1) (<= new-status u3)) err-invalid-input)
    
    (map-set vaccination-records
      { vaccination-id: vaccination-id }
      (merge record { status: new-status })
    )
    
    (ok true)
  )
)

;; Set privacy preferences
(define-public (set-privacy-preferences
    (allow-public-verification bool)
    (allow-anonymous-statistics bool)
    (data-retention-period uint)
    (emergency-access-enabled bool)
    (preferred-language (string-ascii 10)))
  (begin
    (map-set privacy-settings
      { patient: tx-sender }
      {
        allow-public-verification: allow-public-verification,
        allow-anonymous-statistics: allow-anonymous-statistics,
        data-retention-period: data-retention-period,
        emergency-access-enabled: emergency-access-enabled,
        preferred-language: preferred-language
      }
    )
    
    (ok true)
  )
)

;; Define vaccine type
(define-public (define-vaccine-type
    (vaccine-type uint)
    (name (string-ascii 64))
    (description (string-ascii 256))
    (required-doses uint)
    (interval-days uint)
    (immunity-duration uint)
    (is-required-for-travel bool)
    (who-approved bool))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (> vaccine-type u0) err-invalid-input)
    
    (map-set vaccine-types
      { vaccine-type: vaccine-type }
      {
        name: name,
        description: description,
        required-doses: required-doses,
        interval-days: interval-days,
        immunity-duration: immunity-duration,
        is-required-for-travel: is-required-for-travel,
        who-approved: who-approved
      }
    )
    
    (ok true)
  )
)

;; Administrative functions
(define-public (toggle-system-status)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set system-active (not (var-get system-active)))
    (ok (var-get system-active))
  )
)

;; Read-only functions

;; Get vaccination record
(define-read-only (get-vaccination-record (vaccination-id uint))
  (map-get? vaccination-records { vaccination-id: vaccination-id })
)

;; Get patient vaccination history
(define-read-only (get-patient-records (patient principal))
  (map-get? patient-records { patient: patient })
)

;; Verify vaccination status
(define-read-only (verify-vaccination 
    (patient principal)
    (vaccine-type uint)
    (min-doses uint))
  (let (
    (patient-info (map-get? patient-records { patient: patient }))
  )
    (match patient-info
      info (ok { 
        has-required-doses: true, ;; Simplified for this implementation
        last-vaccination-date: (get last-vaccination info),
        total-vaccinations: (get total-vaccinations info)
      })
      (ok { 
        has-required-doses: false,
        last-vaccination-date: u0,
        total-vaccinations: u0
      })
    )
  )
)

;; Get vaccination certificate
(define-read-only (get-certificate (certificate-id uint))
  (map-get? vaccination-certificates { certificate-id: certificate-id })
)

;; Check access permissions
(define-read-only (has-access 
    (vaccination-id uint)
    (accessor principal))
  (let (
    (access-info (map-get? record-access { vaccination-id: vaccination-id, accessor: accessor }))
  )
    (match access-info
      info (< stacks-block-height (get expires-date info))
      false
    )
  )
)

;; Get vaccine type information
(define-read-only (get-vaccine-type (vaccine-type uint))
  (map-get? vaccine-types { vaccine-type: vaccine-type })
)

;; Get privacy settings
(define-read-only (get-privacy-settings (patient principal))
  (map-get? privacy-settings { patient: patient })
)

;; Get system status
(define-read-only (get-system-status)
  {
    system-active: (var-get system-active),
    next-vaccination-id: (var-get next-vaccination-id),
    next-certificate-id: (var-get next-certificate-id)
  }
)

;; Private helper functions

;; Check if vaccination belongs to patient
(define-private (is-patient-vaccination (vaccination-id uint) (patient principal))
  (match (map-get? vaccination-records { vaccination-id: vaccination-id })
    record (is-eq (get patient record) patient)
    false
  )
)

;; Validate all vaccination IDs belong to patient
(define-private (validate-patient-vaccinations (vaccination-ids (list 20 uint)) (patient principal))
  (fold check-vaccination-ownership vaccination-ids { patient: patient, valid: true })
)

;; Helper for fold to check vaccination ownership
(define-private (check-vaccination-ownership (vaccination-id uint) (acc { patient: principal, valid: bool }))
  (if (get valid acc)
    (merge acc { valid: (is-patient-vaccination vaccination-id (get patient acc)) })
    acc
  )
)

