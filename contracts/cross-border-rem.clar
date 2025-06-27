(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_BALANCE (err u101))
(define-constant ERR_INVALID_AMOUNT (err u102))
(define-constant ERR_POOL_NOT_FOUND (err u103))
(define-constant ERR_ALREADY_PROCESSED (err u104))
(define-constant ERR_BATCH_FULL (err u105))
(define-constant ERR_INVALID_RECIPIENT (err u106))
(define-constant ERR_POOL_CLOSED (err u107))
(define-constant ERR_MINIMUM_BATCH_SIZE (err u108))

(define-constant MAX_BATCH_SIZE u50)
(define-constant MIN_BATCH_SIZE u5)
(define-constant POOL_FEE_RATE u100)
(define-constant BASE_FEE u1000)

(define-data-var next-pool-id uint u1)
(define-data-var next-transfer-id uint u1)
(define-data-var total-pools-created uint u0)
(define-data-var total-volume-processed uint u0)

(define-map remittance-pools
  uint
  {
    creator: principal,
    destination-country: (string-ascii 3),
    exchange-rate: uint,
    total-amount: uint,
    fee-collected: uint,
    batch-count: uint,
    max-batch-size: uint,
    status: (string-ascii 10),
    created-at: uint,
    processed-at: (optional uint)
  }
)

(define-map pool-transfers
  {pool-id: uint, transfer-id: uint}
  {
    sender: principal,
    recipient: (string-ascii 50),
    amount: uint,
    fee: uint,
    status: (string-ascii 10),
    created-at: uint,
    processed-at: (optional uint)
  }
)

(define-map user-balances
  principal
  uint
)

(define-map pool-participants
  {pool-id: uint, participant: principal}
  {
    total-sent: uint,
    transfer-count: uint,
    joined-at: uint
  }
)

(define-map country-pools
  (string-ascii 3)
  (list 100 uint)
)

(define-private (calculate-fee (amount uint))
  (+ BASE_FEE (/ (* amount POOL_FEE_RATE) u10000))
)

(define-private (update-user-balance (user principal) (amount uint) (operation (string-ascii 10)))
  (let ((current-balance (default-to u0 (map-get? user-balances user))))
    (if (is-eq operation "add")
      (map-set user-balances user (+ current-balance amount))
      (if (>= current-balance amount)
        (map-set user-balances user (- current-balance amount))
        false
      )
    )
  )
)

(define-private (add-pool-to-country (country (string-ascii 3)) (pool-id uint))
  (let ((current-pools (default-to (list) (map-get? country-pools country))))
    (map-set country-pools country (unwrap-panic (as-max-len? (append current-pools pool-id) u100)))
  )
)

(define-public (deposit (amount uint))
  (begin
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (update-user-balance tx-sender amount "add")
    (ok amount)
  )
)

(define-public (withdraw (amount uint))
  (let ((user-balance (default-to u0 (map-get? user-balances tx-sender))))
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (>= user-balance amount) ERR_INSUFFICIENT_BALANCE)
    (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
    (update-user-balance tx-sender amount "subtract")
    (ok amount)
  )
)

(define-public (create-remittance-pool (destination-country (string-ascii 3)) (exchange-rate uint) (max-batch-size uint))
  (let ((pool-id (var-get next-pool-id)))
    (asserts! (> exchange-rate u0) ERR_INVALID_AMOUNT)
    (asserts! (and (>= max-batch-size MIN_BATCH_SIZE) (<= max-batch-size MAX_BATCH_SIZE)) ERR_INVALID_AMOUNT)
    (map-set remittance-pools pool-id {
      creator: tx-sender,
      destination-country: destination-country,
      exchange-rate: exchange-rate,
      total-amount: u0,
      fee-collected: u0,
      batch-count: u0,
      max-batch-size: max-batch-size,
      status: "active",
      created-at: stacks-block-height,
      processed-at: none
    })
    (add-pool-to-country destination-country pool-id)
    (var-set next-pool-id (+ pool-id u1))
    (var-set total-pools-created (+ (var-get total-pools-created) u1))
    (ok pool-id)
  )
)

(define-public (add-transfer-to-pool (pool-id uint) (recipient (string-ascii 50)) (amount uint))
  (let (
    (pool (unwrap! (map-get? remittance-pools pool-id) ERR_POOL_NOT_FOUND))
    (transfer-id (var-get next-transfer-id))
    (fee (calculate-fee amount))
    (total-cost (+ amount fee))
    (user-balance (default-to u0 (map-get? user-balances tx-sender)))
  )
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (> (len recipient) u0) ERR_INVALID_RECIPIENT)
    (asserts! (is-eq (get status pool) "active") ERR_POOL_CLOSED)
    (asserts! (< (get batch-count pool) (get max-batch-size pool)) ERR_BATCH_FULL)
    (asserts! (>= user-balance total-cost) ERR_INSUFFICIENT_BALANCE)
    
    (update-user-balance tx-sender total-cost "subtract")
    
    (map-set pool-transfers {pool-id: pool-id, transfer-id: transfer-id} {
      sender: tx-sender,
      recipient: recipient,
      amount: amount,
      fee: fee,
      status: "pending",
      created-at: stacks-block-height,
      processed-at: none
    })
    
    (map-set remittance-pools pool-id (merge pool {
      total-amount: (+ (get total-amount pool) amount),
      fee-collected: (+ (get fee-collected pool) fee),
      batch-count: (+ (get batch-count pool) u1)
    }))
    
    (let ((participant-key {pool-id: pool-id, participant: tx-sender}))
      (match (map-get? pool-participants participant-key)
        existing-participant (map-set pool-participants participant-key {
          total-sent: (+ (get total-sent existing-participant) amount),
          transfer-count: (+ (get transfer-count existing-participant) u1),
          joined-at: (get joined-at existing-participant)
        })
        (map-set pool-participants participant-key {
          total-sent: amount,
          transfer-count: u1,
          joined-at: stacks-block-height
        })
      )
    )
    
    (var-set next-transfer-id (+ transfer-id u1))
    (ok transfer-id)
  )
)

(define-public (process-pool-batch (pool-id uint))
  (let ((pool (unwrap! (map-get? remittance-pools pool-id) ERR_POOL_NOT_FOUND)))
    (asserts! (is-eq tx-sender (get creator pool)) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status pool) "active") ERR_ALREADY_PROCESSED)
    (asserts! (>= (get batch-count pool) MIN_BATCH_SIZE) ERR_MINIMUM_BATCH_SIZE)
    
    (map-set remittance-pools pool-id (merge pool {
      status: "processed",
      processed-at: (some stacks-block-height)
    }))
    
    (var-set total-volume-processed (+ (var-get total-volume-processed) (get total-amount pool)))
    (ok (get total-amount pool))
  )
)

(define-public (close-pool (pool-id uint))
  (let ((pool (unwrap! (map-get? remittance-pools pool-id) ERR_POOL_NOT_FOUND)))
    (asserts! (is-eq tx-sender (get creator pool)) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status pool) "active") ERR_ALREADY_PROCESSED)
    
    (map-set remittance-pools pool-id (merge pool {
      status: "closed",
      processed-at: (some stacks-block-height)
    }))
    (ok true)
  )
)

(define-read-only (get-pool-info (pool-id uint))
  (map-get? remittance-pools pool-id)
)

(define-read-only (get-transfer-info (pool-id uint) (transfer-id uint))
  (map-get? pool-transfers {pool-id: pool-id, transfer-id: transfer-id})
)

(define-read-only (get-user-balance (user principal))
  (default-to u0 (map-get? user-balances user))
)

(define-read-only (get-pool-participant-info (pool-id uint) (participant principal))
  (map-get? pool-participants {pool-id: pool-id, participant: participant})
)

(define-read-only (get-pools-by-country (country (string-ascii 3)))
  (default-to (list) (map-get? country-pools country))
)

(define-read-only (get-contract-stats)
  {
    total-pools: (var-get total-pools-created),
    total-volume: (var-get total-volume-processed),
    next-pool-id: (var-get next-pool-id),
    next-transfer-id: (var-get next-transfer-id)
  }
)

(define-read-only (calculate-transfer-fee (amount uint))
  (calculate-fee amount)
)

(define-read-only (get-pool-utilization (pool-id uint))
  (match (map-get? remittance-pools pool-id)
    pool (ok {
      current-batch: (get batch-count pool),
      max-batch: (get max-batch-size pool),
      utilization-percent: (/ (* (get batch-count pool) u100) (get max-batch-size pool))
    })
    ERR_POOL_NOT_FOUND
  )
)


