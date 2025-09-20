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
(define-constant ERR_INVALID_TIER (err u109))
(define-constant ERR_AUTO_RECYCLE_FAILED (err u110))
(define-constant ERR_INVALID_SCHEDULE_TIME (err u111))
(define-constant ERR_SCHEDULE_NOT_FOUND (err u112))
(define-constant ERR_SCHEDULE_NOT_DUE (err u113))

(define-constant MAX_BATCH_SIZE u50)
(define-constant MIN_BATCH_SIZE u5)
(define-constant POOL_FEE_RATE u100)
(define-constant BASE_FEE u1000)
(define-constant BRONZE_TIER_THRESHOLD u10000)
(define-constant SILVER_TIER_THRESHOLD u50000)
(define-constant GOLD_TIER_THRESHOLD u100000)
(define-constant BRONZE_REBATE u500)
(define-constant SILVER_REBATE u1000)
(define-constant GOLD_REBATE u2000)

(define-data-var next-pool-id uint u1)
(define-data-var next-transfer-id uint u1)
(define-data-var total-pools-created uint u0)
(define-data-var total-volume-processed uint u0)
(define-data-var next-schedule-id uint u1)

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
    processed-at: (optional uint),
    auto-recycle: bool,
    parent-pool-id: (optional uint),
    child-pool-id: (optional uint)
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

(define-map user-loyalty-stats
  principal
  {
    total-volume: uint,
    transaction-count: uint,
    tier: (string-ascii 10),
    total-rebates-earned: uint,
    last-updated: uint
  }
)

(define-map pool-schedules
  uint
  {
    pool-id: uint,
    creator: principal,
    scheduled-block: uint,
    created-at: uint,
    status: (string-ascii 10)
  }
)

(define-private (calculate-fee (amount uint))
  (+ BASE_FEE (/ (* amount POOL_FEE_RATE) u10000))
)

(define-private (get-user-tier (user principal))
  (let ((stats (default-to {total-volume: u0, transaction-count: u0, tier: "standard", total-rebates-earned: u0, last-updated: u0} (map-get? user-loyalty-stats user))))
    (let ((volume (get total-volume stats)))
      (if (>= volume GOLD_TIER_THRESHOLD)
        "gold"
        (if (>= volume SILVER_TIER_THRESHOLD)
          "silver"
          (if (>= volume BRONZE_TIER_THRESHOLD)
            "bronze"
            "standard"
          )
        )
      )
    )
  )
)

(define-private (calculate-rebate (tier (string-ascii 10)))
  (if (is-eq tier "gold")
    GOLD_REBATE
    (if (is-eq tier "silver")
      SILVER_REBATE
      (if (is-eq tier "bronze")
        BRONZE_REBATE
        u0
      )
    )
  )
)

(define-private (calculate-discounted-fee (amount uint) (user principal))
  (let (
    (base-fee (calculate-fee amount))
    (user-tier (get-user-tier user))
    (rebate (calculate-rebate user-tier))
  )
    (if (> base-fee rebate)
      (- base-fee rebate)
      u0
    )
  )
)

(define-private (update-user-loyalty (user principal) (amount uint))
  (let (
    (current-stats (default-to {total-volume: u0, transaction-count: u0, tier: "standard", total-rebates-earned: u0, last-updated: u0} (map-get? user-loyalty-stats user)))
    (new-volume (+ (get total-volume current-stats) amount))
    (new-count (+ (get transaction-count current-stats) u1))
  )
    (let (
      (updated-stats {total-volume: new-volume, transaction-count: new-count, tier: "temp", total-rebates-earned: u0, last-updated: u0})
    )
      (map-set user-loyalty-stats user updated-stats)
      (let (
        (new-tier (get-user-tier user))
        (rebate-earned (calculate-rebate new-tier))
        (total-rebates (+ (get total-rebates-earned current-stats) rebate-earned))
      )
        (map-set user-loyalty-stats user {
          total-volume: new-volume,
          transaction-count: new-count,
          tier: new-tier,
          total-rebates-earned: total-rebates,
          last-updated: stacks-block-height
        })
        true
      )
    )
  )
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
      processed-at: none,
      auto-recycle: false,
      parent-pool-id: none,
      child-pool-id: none
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
    (fee (calculate-discounted-fee amount tx-sender))
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
    
    (update-user-loyalty tx-sender amount)
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

(define-read-only (get-user-loyalty-tier (user principal))
  (get-user-tier user)
)

(define-read-only (get-user-loyalty-stats (user principal))
  (default-to {total-volume: u0, transaction-count: u0, tier: "standard", total-rebates-earned: u0, last-updated: u0} (map-get? user-loyalty-stats user))
)

(define-read-only (calculate-user-fee (amount uint) (user principal))
  (calculate-discounted-fee amount user)
)

(define-read-only (get-tier-benefits (tier (string-ascii 10)))
  (ok {
    tier: tier,
    rebate-amount: (calculate-rebate tier),
    threshold-required: (if (is-eq tier "bronze")
      BRONZE_TIER_THRESHOLD
      (if (is-eq tier "silver")
        SILVER_TIER_THRESHOLD
        (if (is-eq tier "gold")
          GOLD_TIER_THRESHOLD
          u0
        )
      )
    )
  })
)

(define-public (claim-loyalty-rebate)
  (let (
    (user-stats (unwrap! (map-get? user-loyalty-stats tx-sender) (err u404)))
    (rebates-earned (get total-rebates-earned user-stats))
  )
    (asserts! (> rebates-earned u0) (err u405))
    (try! (as-contract (stx-transfer? rebates-earned tx-sender tx-sender)))
    (map-set user-loyalty-stats tx-sender (merge user-stats {
      total-rebates-earned: u0
    }))
    (ok rebates-earned)
  )
)

(define-private (create-recycled-pool (parent-pool-id uint))
  (let (
    (parent-pool (unwrap! (map-get? remittance-pools parent-pool-id) ERR_POOL_NOT_FOUND))
    (new-pool-id (var-get next-pool-id))
  )
    (map-set remittance-pools new-pool-id {
      creator: (get creator parent-pool),
      destination-country: (get destination-country parent-pool),
      exchange-rate: (get exchange-rate parent-pool),
      total-amount: u0,
      fee-collected: u0,
      batch-count: u0,
      max-batch-size: (get max-batch-size parent-pool),
      status: "active",
      created-at: stacks-block-height,
      processed-at: none,
      auto-recycle: true,
      parent-pool-id: (some parent-pool-id),
      child-pool-id: none
    })
    (map-set remittance-pools parent-pool-id (merge parent-pool {
      child-pool-id: (some new-pool-id)
    }))
    (add-pool-to-country (get destination-country parent-pool) new-pool-id)
    (var-set next-pool-id (+ new-pool-id u1))
    (var-set total-pools-created (+ (var-get total-pools-created) u1))
    (ok new-pool-id)
  )
)

(define-public (create-auto-recycle-pool (destination-country (string-ascii 3)) (exchange-rate uint) (max-batch-size uint))
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
      processed-at: none,
      auto-recycle: true,
      parent-pool-id: none,
      child-pool-id: none
    })
    (add-pool-to-country destination-country pool-id)
    (var-set next-pool-id (+ pool-id u1))
    (var-set total-pools-created (+ (var-get total-pools-created) u1))
    (ok pool-id)
  )
)

(define-public (add-transfer-with-auto-recycle (pool-id uint) (recipient (string-ascii 50)) (amount uint))
  (let (
    (pool (unwrap! (map-get? remittance-pools pool-id) ERR_POOL_NOT_FOUND))
    (transfer-id (var-get next-transfer-id))
    (fee (calculate-discounted-fee amount tx-sender))
    (total-cost (+ amount fee))
    (user-balance (default-to u0 (map-get? user-balances tx-sender)))
  )
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (> (len recipient) u0) ERR_INVALID_RECIPIENT)
    (asserts! (>= user-balance total-cost) ERR_INSUFFICIENT_BALANCE)
    
    (let ((target-pool-id 
      (if (and (is-eq (get status pool) "active") (< (get batch-count pool) (get max-batch-size pool)))
        pool-id
        (if (get auto-recycle pool)
          (match (get child-pool-id pool)
            existing-child existing-child
            (unwrap! (create-recycled-pool pool-id) ERR_AUTO_RECYCLE_FAILED)
          )
          (begin
            (asserts! (is-eq (get status pool) "active") ERR_POOL_CLOSED)
            (asserts! (< (get batch-count pool) (get max-batch-size pool)) ERR_BATCH_FULL)
            pool-id
          )
        )
      )))
      
      (let ((target-pool (unwrap! (map-get? remittance-pools target-pool-id) ERR_POOL_NOT_FOUND)))
        (update-user-balance tx-sender total-cost "subtract")
        
        (map-set pool-transfers {pool-id: target-pool-id, transfer-id: transfer-id} {
          sender: tx-sender,
          recipient: recipient,
          amount: amount,
          fee: fee,
          status: "pending",
          created-at: stacks-block-height,
          processed-at: none
        })
        
        (map-set remittance-pools target-pool-id (merge target-pool {
          total-amount: (+ (get total-amount target-pool) amount),
          fee-collected: (+ (get fee-collected target-pool) fee),
          batch-count: (+ (get batch-count target-pool) u1)
        }))
        
        (let ((participant-key {pool-id: target-pool-id, participant: tx-sender}))
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
        
        (update-user-loyalty tx-sender amount)
        (var-set next-transfer-id (+ transfer-id u1))
        (ok {transfer-id: transfer-id, pool-id: target-pool-id})
      )
    )
  )
)

(define-read-only (get-active-pool-for-country (country (string-ascii 3)))
  (let ((pools-list (default-to (list) (map-get? country-pools country))))
    (fold find-active-pool pools-list none)
  )
)

(define-private (find-active-pool (pool-id uint) (current-best (optional uint)))
  (match (map-get? remittance-pools pool-id)
    pool (if (and 
               (is-eq (get status pool) "active") 
               (< (get batch-count pool) (get max-batch-size pool))
             )
           (some pool-id)
           current-best)
    current-best
  )
)

(define-read-only (get-pool-chain (pool-id uint))
  (let ((pool (unwrap! (map-get? remittance-pools pool-id) ERR_POOL_NOT_FOUND)))
    (ok {
      current-pool: pool-id,
      parent-pool: (get parent-pool-id pool),
      child-pool: (get child-pool-id pool),
      auto-recycle-enabled: (get auto-recycle pool)
    })
  )
)

(define-public (schedule-pool-processing (pool-id uint) (target-block uint))
  (let (
    (pool (unwrap! (map-get? remittance-pools pool-id) ERR_POOL_NOT_FOUND))
    (schedule-id (var-get next-schedule-id))
  )
    (asserts! (is-eq tx-sender (get creator pool)) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status pool) "active") ERR_POOL_CLOSED)
    (asserts! (> target-block stacks-block-height) ERR_INVALID_SCHEDULE_TIME)
    
    (map-set pool-schedules schedule-id {
      pool-id: pool-id,
      creator: tx-sender,
      scheduled-block: target-block,
      created-at: stacks-block-height,
      status: "pending"
    })
    
    (var-set next-schedule-id (+ schedule-id u1))
    (ok schedule-id)
  )
)

(define-public (execute-scheduled-processing (schedule-id uint))
  (let (
    (schedule (unwrap! (map-get? pool-schedules schedule-id) ERR_SCHEDULE_NOT_FOUND))
    (pool (unwrap! (map-get? remittance-pools (get pool-id schedule)) ERR_POOL_NOT_FOUND))
  )
    (asserts! (is-eq (get status schedule) "pending") ERR_ALREADY_PROCESSED)
    (asserts! (>= stacks-block-height (get scheduled-block schedule)) ERR_SCHEDULE_NOT_DUE)
    (asserts! (is-eq (get status pool) "active") ERR_POOL_CLOSED)
    (asserts! (>= (get batch-count pool) MIN_BATCH_SIZE) ERR_MINIMUM_BATCH_SIZE)
    
    (map-set pool-schedules schedule-id (merge schedule {
      status: "executed"
    }))
    
    (map-set remittance-pools (get pool-id schedule) (merge pool {
      status: "processed",
      processed-at: (some stacks-block-height)
    }))
    
    (var-set total-volume-processed (+ (var-get total-volume-processed) (get total-amount pool)))
    (ok (get total-amount pool))
  )
)

(define-public (cancel-scheduled-processing (schedule-id uint))
  (let ((schedule (unwrap! (map-get? pool-schedules schedule-id) ERR_SCHEDULE_NOT_FOUND)))
    (asserts! (is-eq tx-sender (get creator schedule)) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status schedule) "pending") ERR_ALREADY_PROCESSED)
    
    (map-set pool-schedules schedule-id (merge schedule {
      status: "cancelled"
    }))
    (ok true)
  )
)

(define-read-only (get-schedule-info (schedule-id uint))
  (map-get? pool-schedules schedule-id)
)

(define-read-only (is-schedule-ready (schedule-id uint))
  (match (map-get? pool-schedules schedule-id)
    schedule (and 
               (is-eq (get status schedule) "pending")
               (>= stacks-block-height (get scheduled-block schedule))
             )
    false
  )
)

(define-read-only (get-pending-schedules-count)
  (var-get next-schedule-id)
)


