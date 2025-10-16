;; ------------------------------------------------------------
;; LockDropX - Lockdrop / Time-weighted Airdrop (Clarity v2)
;; ------------------------------------------------------------

(define-trait ft-trait
  (
    (transfer (uint principal principal) (response bool uint))
    (get-balance (principal) (response uint uint))
  ))
;; - Users lock STX (attach STX to tx) for a chosen duration in blocks.
;; - Each lock yields weight = amount * duration (both in STX base units).
;; - Owner deposits reward tokens (SIP-010) to the contract.
;; - Owner finalizes a snapshot (freezes weights); total_weight is recorded.
;; - After snapshot, users claim their share = floor(user_weight * total_rewards / total_weight).
;; - Users can withdraw their STX after their lock.end_block regardless snapshot.
;; ------------------------------------------------------------

;; ---------- Errors ----------
(define-constant ERR-UNAUTHORIZED   (err u100))
(define-constant ERR-BAD-ARGS       (err u101))
(define-constant ERR-NOT-FOUND     (err u102))
(define-constant ERR-ALREADY       (err u103))
(define-constant ERR-INSUFFICIENT  (err u104))
(define-constant ERR-NOTHING       (err u105))
(define-constant ERR-NOT-YET       (err u106))
(define-constant ERR-SNAPSHOTED    (err u107))

;; ---------- Config / State ----------
(define-data-var owner principal tx-sender)
(define-data-var snapshot-taken bool false)

;; reward token principal (SIP-010). Owner must set before deposit.
(define-data-var reward-token principal tx-sender)

;; total token rewards deposited (token units)
(define-data-var total-rewards uint u0)

;; total weight currently (sum of amount * duration for all active locks, only until snapshot)
(define-data-var total-weight uint u0)

;; frozen total weight after snapshot
(define-data-var total-weight-snapshot uint u0)

;; total rewards snapshot value (copied when snapshot taken)
(define-data-var total-rewards-snapshot uint u0)

;; incremental lock id
(define-data-var next-lock-id uint u1)

;; Per-lock record
(define-map locks
  { id: uint }
  {
    owner: principal,
    amount: uint,        ;; STX amount locked (micro-STX units)
    start: uint,         ;; block when lock created
    duration: uint,      ;; duration in blocks
    end: uint,           ;; start + duration
    weight: uint,        ;; amount * duration, recorded at creation
    withdrawn: bool
  })

;; Per-user running weight (only accumulates before snapshot)
(define-map user-weight
  { who: principal }
  { weight: uint })

;; Per-user claimed rewards (token units)
(define-map user-claimed
  { who: principal }
  { claimed: uint })

;; ---------- Helpers ----------
(define-trait sip-010-trait
  (
    ;; Transfer from the caller to a new principal
    (transfer (uint principal principal (response bool uint)) (response bool uint))
    ;; Get token symbol
    (get-symbol () (response (string-ascii 32) uint))
    ;; Get token name
    (get-name () (response (string-ascii 32) uint))
    ;; Get token decimals
    (get-decimals () (response uint uint))
    ;; Get token uri
    (get-token-uri () (response (optional (string-utf8 256)) uint))
    ;; Get the token balance of the specified principal
    (get-balance (principal) (response uint uint))
    ;; Get the total supply
    (get-total-supply () (response uint uint))
  )
)

(define-read-only (is-owner (p principal)) (is-eq p (var-get owner)))
(define-read-only (now) burn-block-height)

(define-read-only (mul-div (x uint) (num uint) (den uint))
  (if (is-eq den u0) u0 (/ (* x num) den)))

(define-read-only (get-user-claimed (who principal)) 
  (ok (default-to u0 (get claimed (map-get? user-claimed { who: who })))))

;; ---------- Admin ----------
(define-public (set-reward-token (token-pr <ft-trait>))
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (let ((token-principal (contract-of token-pr)))
      (try! (contract-call? token-pr get-balance tx-sender))  ;; verify token contract implements ft-trait
      (var-set reward-token token-principal)
      (ok token-principal))))

;; Owner deposits reward tokens into contract by calling token.transfer(amount, tx-sender, as-contract)
;; and then calling deposit-rewards to update accounting in this contract.
;; Alternatively, deposit-rewards pulls tokens from caller directly with contract-call?
(define-public (deposit-rewards (token-pr <ft-trait>) (amount uint))
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (asserts! (> amount u0) ERR-BAD-ARGS)
    ;; if reward-token not set yet, set it
    (if (is-eq (var-get reward-token) tx-sender)
        (var-set reward-token (contract-of token-pr))
        true)
    ;; ensure token matches configured reward-token (if configured)
    (asserts! (is-eq (contract-of token-pr) (var-get reward-token)) ERR-BAD-ARGS)
    ;; pull tokens from owner into contract
    (try! (contract-call? token-pr transfer amount tx-sender (as-contract tx-sender)))
    ;; update pool
    (var-set total-rewards (+ (var-get total-rewards) amount))
    (ok (var-get total-rewards))))

;; ---------- Locking ----------
;; Users lock STX by attaching STX to tx and specifying duration (in blocks).
;; Constraints: snapshot must NOT be taken yet.
(define-public (lock (duration uint))
  (let ((amt (stx-get-balance tx-sender)))
    (begin
      (asserts! (not (var-get snapshot-taken)) ERR-SNAPSHOTED)
      (asserts! (> amt u0) ERR-BAD-ARGS)
      (asserts! (> duration u0) ERR-BAD-ARGS)

      (let ((id (var-get next-lock-id))
            (start (now))
            (end (+ start duration))
            (weight (* amt duration)))
        ;; record lock
        (map-set locks { id: id }
          {
            owner: tx-sender,
            amount: amt,
            start: start,
            duration: duration,
            end: end,
            weight: weight,
            withdrawn: false
          })
        ;; update user and global weights (only while snapshot not taken)
        (let ((prev (default-to u0 (get weight (map-get? user-weight { who: tx-sender })))))
          (map-set user-weight { who: tx-sender } { weight: (+ prev weight) }))
        (var-set total-weight (+ (var-get total-weight) weight))
        (var-set next-lock-id (+ id u1))
        (ok { lock-id: id, amount: amt, duration: duration, weight: weight })))))

;; Extend a lock's duration before snapshot and before its end (owner-only)
(define-public (extend-lock (id uint) (extra-duration uint))
  (let ((lock-data (map-get? locks { id: id })))
    (if (is-some lock-data)
      (let ((rec (unwrap! lock-data ERR-NOT-FOUND)))
        (begin
          (asserts! (not (var-get snapshot-taken)) ERR-SNAPSHOTED)
          (asserts! (is-eq (get owner rec) tx-sender) ERR-UNAUTHORIZED)
          (asserts! (> extra-duration u0) ERR-BAD-ARGS)
          (let ((old-duration (get duration rec))
                (new-duration (+ old-duration extra-duration))
                (amt (get amount rec))
                (old-weight (get weight rec))
                (new-weight (* amt new-duration))
                (new-end (+ (get start rec) new-duration)))
            ;; update lock record
            (map-set locks { id: id } (merge rec { duration: new-duration, end: new-end, weight: new-weight }))
            ;; update user & total weight
            (let ((prev (default-to u0 (get weight (map-get? user-weight { who: tx-sender })))))
              (map-set user-weight { who: tx-sender } { weight: (+ (- prev old-weight) new-weight) }))
            (var-set total-weight (+ (- (var-get total-weight) old-weight) new-weight))
            (ok { id: id, new-duration: new-duration, new-weight: new-weight }))))
      ERR-NOT-FOUND)))

;; Withdraw locked STX after lock end. Allowed anytime after end.
(define-public (withdraw-lock (id uint))
  (let ((lock-data (map-get? locks { id: id })))
    (if (is-some lock-data)
      (let ((rec (unwrap-panic lock-data)))
        (begin
          (asserts! (is-eq (get owner rec) tx-sender) ERR-UNAUTHORIZED)
          (asserts! (not (get withdrawn rec)) ERR-ALREADY)
          (asserts! (>= (now) (get end rec)) ERR-NOT-YET)

          (let ((amt (get amount rec))
                (w (get weight rec)))

            ;; If snapshot not taken, reduce user & global weights because lock is leaving early
            (if (not (var-get snapshot-taken))
                (begin
                  (let ((prev (default-to u0 (get weight (map-get? user-weight { who: tx-sender })))))
                    (map-set user-weight { who: tx-sender } { weight: (- prev w) })
                    (var-set total-weight (- (var-get total-weight) w))
                    ;; mark withdrawn before transfer
                    (map-set locks { id: id } (merge rec { withdrawn: true }))
                    ;; transfer STX back to user
                    (try! (as-contract (stx-transfer? amt tx-sender tx-sender)))
                    (ok { withdrawn: amt })))
                (begin
                  ;; mark withdrawn before transfer
                  (map-set locks { id: id } (merge rec { withdrawn: true }))
                  ;; transfer STX back to user
                  (try! (as-contract (stx-transfer? amt tx-sender tx-sender)))
                  (ok { withdrawn: amt }))))))
      ERR-NOT-FOUND)))

;; ---------- Snapshot & Distribution ----------

;; Owner finalizes snapshot: freezes weights and snapshots totals.
;; After this, no further locks or weight changes are allowed for distribution purposes.
(define-public (finalize-snapshot)
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (asserts! (not (var-get snapshot-taken)) ERR-ALREADY)
    (asserts! (> (var-get total-weight) u0) ERR-BAD-ARGS)
    (asserts! (> (var-get total-rewards) u0) ERR-BAD-ARGS)

    (var-set snapshot-taken true)
    (var-set total-weight-snapshot (var-get total-weight))
    (var-set total-rewards-snapshot (var-get total-rewards))
    (ok
      {
        total_weight: (var-get total-weight-snapshot),
        total_rewards: (var-get total-rewards-snapshot)
      })))

;; Claim rewards: users claim their pro-rata share based on their accumulated weight at snapshot.
(define-public (claim-rewards (token-pr <ft-trait>))
  (let ((snapshot (var-get snapshot-taken))
        (token-contract (contract-of token-pr)))
    (begin
      (asserts! snapshot ERR-NOTHING)
      (asserts! (is-eq token-contract (var-get reward-token)) ERR-BAD-ARGS)
      (let ((uw (default-to u0 (get weight (map-get? user-weight { who: tx-sender }))))
            (tot (var-get total-weight-snapshot))
            (trew (var-get total-rewards-snapshot)))
        (asserts! (> uw u0) ERR-NOTHING)

        ;; compute entitled = floor(uw * trew / tot)
        (let ((entitled (mul-div uw trew tot))
              (prev-claimed (unwrap-panic (get-user-claimed tx-sender))))
          (let ((pay (- entitled prev-claimed)))
            (asserts! (> pay u0) ERR-NOTHING)
            ;; update claimed BEFORE external transfer
            (map-set user-claimed { who: tx-sender } { claimed: (+ prev-claimed pay) })
            ;; perform token transfer
            (try! (contract-call? token-pr transfer pay tx-sender tx-sender))
            (ok { paid: pay, total_entitled: entitled })))))))

;; Owner can withdraw leftover rewards after all claims are done or at owner's discretion.
(define-public (owner-withdraw-rewards (token-pr <ft-trait>) (amount uint) (to principal))
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (asserts! (>= (var-get total-rewards) amount) ERR-INSUFFICIENT)
    (asserts! (is-eq (contract-of token-pr) (var-get reward-token)) ERR-BAD-ARGS)
    ;; reduce total-rewards (note: doesn't affect snapshoted total-rewards-snapshot already taken)
    (var-set total-rewards (- (var-get total-rewards) amount))
    (try! (contract-call? token-pr transfer amount tx-sender to))
    (ok true)))

;; ---------- Views ----------
(define-read-only (get-lock (id uint))
  (ok (map-get? locks { id: id })))

(define-read-only (get-user-weight (who principal))
  (ok (default-to u0 (get weight (map-get? user-weight { who: who })))))

(define-read-only (get-total-weight) (ok (var-get total-weight)))
(define-read-only (get-total-rewards) (ok (var-get total-rewards)))
(define-read-only (get-reward-token) (ok (var-get reward-token)))
(define-read-only (is-snapshot-taken) (ok (var-get snapshot-taken)))
(define-read-only (get-total-weight-snapshot) (ok (var-get total-weight-snapshot)))
(define-read-only (get-total-rewards-snapshot) (ok (var-get total-rewards-snapshot)))
(define-read-only (get-next-lock-id) (ok (var-get next-lock-id)))