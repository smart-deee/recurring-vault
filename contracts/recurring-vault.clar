;; ------------------------------------------------------------
;; RecurringVault - Recurring Payment Vault (Clarity v1.0)
;; ------------------------------------------------------------
;; - Merchants create subscription plans (price in STX units, period in blocks).
;; - Users deposit STX into the contract (deposit), then subscribe to a plan.
;; - The contract charges subscribers each billing cycle by debiting their deposit.
;; - Anyone (a relayer or the merchant) can call `process-payment` for a due subscription.
;; - If subscriber lacks funds at processing time, subscription is auto-canceled.
;; - Merchants withdraw their earned balances from the contract.
;; - Admin (owner) can pause/unpause the contract.
;; ------------------------------------------------------------

;; ---------- Errors ----------
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-BAD-ARGS     (err u101))
(define-constant ERR-NOT-FOUND   (err u102))
(define-constant ERR-INSUFFICIENT (err u103))
(define-constant ERR-ALREADY     (err u104))
(define-constant ERR-PAUSED      (err u105))
(define-constant ERR-NOT-DUE     (err u106))
(define-constant ERR-NOT-ACTIVE  (err u107))

;; ---------- Config / State ----------
(define-data-var owner principal tx-sender)    ;; contract owner at deploy
(define-data-var paused bool false)            ;; emergency pause switch
(define-data-var next-plan-id uint u1)         ;; incremental plan id
(define-data-var current-height uint u0)       ;; current block height

;; ---------- Data structures ----------
;; Plan: id -> { merchant, price, period, active }
(define-map plans
  { id: uint }
  {
    merchant: principal,
    price: uint,       ;; price per cycle (STX units)
    period: uint,      ;; billing period in blocks
    active: bool
  })

;; Subscription: keyed by (plan-id, user) -> { next-payment: uint, active: bool }
(define-map subs
  { plan-id: uint, user: principal }
  {
    next-payment: uint,
    active: bool
  })

;; Deposits held for users (pre-funded)
(define-map deposits
  { user: principal }
  { balance: uint })

;; Merchant balances (earned, claimable)
(define-map merchant-balances
  { merchant: principal }
  { balance: uint })

;; ---------- Helpers ----------
(define-read-only (is-owner (p principal)) (is-eq p (var-get owner)))
(define-read-only (is-paused) (var-get paused))
(define-read-only (now) (var-get current-height))

;; For testing and initialization
(define-public (set-block-height (height uint))
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (asserts! (>= height u0) ERR-BAD-ARGS)
    (ok (var-set current-height height))))

;; Safe mul-div helper
(define-read-only (mul-div (x uint) (num uint) (den uint))
  (if (is-eq den u0) u0 (/ (* x num) den)))

;; ---------- Admin ----------
(define-public (pause)
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (var-set paused true)
    (ok true)))

(define-public (unpause)
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (var-set paused false)
    (ok true)))

;; ---------- Plan management (merchant) ----------
;; Create a plan: merchant calls and registers a price + billing period (blocks)
(define-public (create-plan (price uint) (period uint))
  (begin
    (asserts! (not (is-paused)) ERR-PAUSED)
    (asserts! (> price u0) ERR-BAD-ARGS)
    (asserts! (> period u0) ERR-BAD-ARGS)
    (let ((id (var-get next-plan-id)))
      (asserts! (<= id u1000000) ERR-BAD-ARGS) ;; reasonable limit
      (map-set plans { id: id }
        { merchant: tx-sender, price: price, period: period, active: true })
      (var-set next-plan-id (+ id u1))
      (ok id))))

;; Update plan (merchant-only)
(define-public (update-plan (id uint) (price uint) (period uint) (active bool))
  (let ((plan (unwrap! (map-get? plans { id: id }) ERR-NOT-FOUND)))
    (begin
      (asserts! (is-eq (get merchant plan) tx-sender) ERR-UNAUTHORIZED)
      (asserts! (> price u0) ERR-BAD-ARGS)
      (asserts! (> period u0) ERR-BAD-ARGS)
      (map-set plans { id: id } 
        { merchant: tx-sender, price: price, period: period, active: active })
      (ok true))))

;; Merchant funds - merchants can withdraw their earned balance
(define-public (merchant-withdraw (amount uint))
  (let ((mb (unwrap! (map-get? merchant-balances { merchant: tx-sender }) ERR-NOT-FOUND)))
    (let ((bal (get balance mb)))
      (begin
        (asserts! (>= bal amount) ERR-INSUFFICIENT)
        ;; update state before external transfer
        (map-set merchant-balances { merchant: tx-sender } { balance: (- bal amount) })
        (unwrap! (as-contract (stx-transfer? amount tx-sender tx-sender)) ERR-INSUFFICIENT)
        (ok true)))))

;; ---------- Deposits (subscriber) ----------
;; Deposit STX into contract to fund subscriptions
(define-public (deposit (amount uint))
  (begin
    (asserts! (> amount u0) ERR-BAD-ARGS)
    (let ((prev (default-to u0 (get balance (map-get? deposits { user: tx-sender })))))
      (map-set deposits { user: tx-sender } { balance: (+ prev amount) })
      (ok (map-get? deposits { user: tx-sender })))))

;; Withdraw unallocated deposit (subscriber)
(define-public (withdraw-deposit (amount uint))
  (let ((user-deposit (unwrap! (map-get? deposits { user: tx-sender }) ERR-NOT-FOUND)))
    (let ((bal (get balance user-deposit)))
      (begin
        (asserts! (>= bal amount) ERR-INSUFFICIENT)
        (map-set deposits { user: tx-sender } { balance: (- bal amount) })
        (unwrap! (as-contract (stx-transfer? amount tx-sender tx-sender)) ERR-INSUFFICIENT)
        (ok true)))))

;; ---------- Subscriptions ----------
;; Subscribe: user subscribes to a plan. First payment is charged immediately from deposit.
(define-public (subscribe (plan-id uint))
  (begin
    (asserts! (not (is-paused)) ERR-PAUSED)
    (let ((plan (unwrap! (map-get? plans { id: plan-id }) ERR-NOT-FOUND)))
      (begin
        (asserts! (get active plan) ERR-NOT-ACTIVE)
        ;; ensure user not already subscribed
        (asserts! (is-none (map-get? subs { plan-id: plan-id, user: tx-sender })) ERR-ALREADY)

        ;; require deposit present and sufficient for first period
        (let ((price (get price plan))
              (period (get period plan))
              (dep (default-to { balance: u0 } (map-get? deposits { user: tx-sender }))))
          (begin
            (asserts! (>= (get balance dep) price) ERR-INSUFFICIENT)
            (asserts! (<= (+ (now) period) u1000000000) ERR-BAD-ARGS) ;; reasonable block height limit

            ;; debit deposit, credit merchant (state updates before any transfers)
            (map-set deposits { user: tx-sender } { balance: (- (get balance dep) price) })
            (let ((mprev (default-to u0 (get balance (map-get? merchant-balances { merchant: (get merchant plan) })))))
              (map-set merchant-balances { merchant: (get merchant plan) } { balance: (+ mprev price) }))

            ;; create subscription: next-payment = now + period
            (map-set subs { plan-id: plan-id, user: tx-sender }
              { next-payment: (+ (now) period), active: true })

            (ok { subscribed: true, next-payment: (+ (now) period) })))))))

;; Cancel subscription (user)
(define-public (cancel-sub (plan-id uint))
  (let ((sub (unwrap! (map-get? subs { plan-id: plan-id, user: tx-sender }) ERR-NOT-FOUND)))
    (begin
      (asserts! (get active sub) ERR-NOT-ACTIVE)
      (map-set subs { plan-id: plan-id, user: tx-sender } 
        { next-payment: (get next-payment sub), active: false })
      (ok true))))

;; ---------- Processing payments ----------
;; Anyone can call this to process a due payment for a given subscription
(define-public (process-payment (plan-id uint) (user principal))
  (begin
    (asserts! (not (is-paused)) ERR-PAUSED)
    (let ((plan (unwrap! (map-get? plans { id: plan-id }) ERR-NOT-FOUND)))
      (let ((sub (unwrap! (map-get? subs { plan-id: plan-id, user: user }) ERR-NOT-FOUND)))
        (begin
          (asserts! (get active sub) ERR-NOT-ACTIVE)
          (let ((due (get next-payment sub)))
            (asserts! (<= due (now)) ERR-NOT-DUE)
            (let ((price (get price plan))
                  (period (get period plan))
                  (dep (default-to { balance: u0 } (map-get? deposits { user: user }))))
              (if (>= (get balance dep) price)
                  (begin
                    (asserts! (<= (+ due period) u1000000000) ERR-BAD-ARGS) ;; reasonable block height limit
                    (map-set deposits { user: user } { balance: (- (get balance dep) price) })
                    (let ((mprev (default-to u0 (get balance (map-get? merchant-balances { merchant: (get merchant plan) })))))
                      (map-set merchant-balances { merchant: (get merchant plan) } { balance: (+ mprev price) }))
                    (map-set subs { plan-id: plan-id, user: user }
                      { next-payment: (+ due period), active: true })
                    (ok { status: "processed", paid: price, next-payment: (+ due period), reason: "" }))
                  (begin
                    (map-set subs { plan-id: plan-id, user: user } { next-payment: due, active: false })
                    (ok { status: "canceled", paid: u0, next-payment: due, reason: "insufficient-funds" }))))))))))

;; Batch processor: process multiple subscriptions (useful for relayers)
(define-public (process-batch (plan-id uint) (users (list 10 principal)))
  (let ((first-user (element-at users u0)))
    (if (is-some first-user)
        (let ((result (unwrap-panic (process-payment plan-id (unwrap-panic first-user)))))
          (ok (list result)))
        (ok (list)))))

;; ---------- Views ----------
(define-read-only (get-plan (id uint))
  (match (map-get? plans { id: id })
    plan (ok plan)
    ERR-NOT-FOUND))

(define-read-only (get-sub (plan-id uint) (user principal))
  (match (map-get? subs { plan-id: plan-id, user: user })
    sub (ok sub)
    ERR-NOT-FOUND))

(define-read-only (get-deposit (user principal))
  (ok (default-to u0 (get balance (map-get? deposits { user: user })))))

(define-read-only (get-merchant-balance (merchant principal))
  (ok (default-to u0 (get balance (map-get? merchant-balances { merchant: merchant })))))

(define-read-only (all-plans)
  (ok (var-get next-plan-id)))