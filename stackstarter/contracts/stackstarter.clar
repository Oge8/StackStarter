;; StackStarter: Milestone-based Crowdfunding Contract
;; Description: A decentralized crowdfunding platform with milestone validation

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_INVALID_CAMPAIGN (err u101))
(define-constant ERR_CAMPAIGN_EXISTS (err u102))
(define-constant ERR_INSUFFICIENT_FUNDS (err u103))
(define-constant ERR_MILESTONE_NOT_FOUND (err u104))
(define-constant ERR_INVALID_MILESTONE_STATE (err u105))
(define-constant ERR_CAMPAIGN_ENDED (err u106))
(define-constant ERR_ALREADY_WITHDRAWN (err u107))
(define-constant ERR_INVALID_INPUT (err u108))

;; Data Types
(define-map campaigns
    { campaign-id: uint }
    {
        creator: principal,
        title: (string-ascii 64),
        description: (string-ascii 256),
        funding-goal: uint,
        end-block: uint,
        total-funds: uint,
        is-active: bool,
        funds-withdrawn: uint
    }
)

(define-map milestones
    { campaign-id: uint, milestone-id: uint }
    {
        description: (string-ascii 256),
        funds-required: uint,
        deadline: uint,
        is-completed: bool,
        votes-needed: uint,
        votes-received: uint,
        funds-withdrawn: bool
    }
)

(define-map campaign-funders
    { campaign-id: uint, funder: principal }
    { amount: uint }
)

(define-map milestone-votes
    { campaign-id: uint, milestone-id: uint, voter: principal }
    { has-voted: bool }
)

;; Campaign Counter
(define-data-var campaign-id-nonce uint u0)

;; Helper Functions
(define-private (validate-string-input (input (string-ascii 256)))
    (> (len input) u0)
)

(define-private (validate-uint-input (input uint))
    (> input u0)
)

(define-private (validate-campaign-id (campaign-id uint))
    (is-some (map-get? campaigns { campaign-id: campaign-id }))
)

(define-private (validate-milestone-id (campaign-id uint) (milestone-id uint))
    (is-some (map-get? milestones { campaign-id: campaign-id, milestone-id: milestone-id }))
)

;; Administrative Functions
(define-public (create-campaign (title (string-ascii 64)) 
                              (description (string-ascii 256))
                              (funding-goal uint)
                              (duration uint))
    (let
        (
            (new-campaign-id (+ (var-get campaign-id-nonce) u1))
            (end-block (+ block-height duration))
        )
        ;; Input validation
        (asserts! (validate-string-input title) ERR_INVALID_INPUT)
        (asserts! (validate-string-input description) ERR_INVALID_INPUT)
        (asserts! (validate-uint-input funding-goal) ERR_INVALID_INPUT)
        (asserts! (validate-uint-input duration) ERR_INVALID_INPUT)
        
        (map-set campaigns
            { campaign-id: new-campaign-id }
            {
                creator: tx-sender,
                title: title,
                description: description,
                funding-goal: funding-goal,
                end-block: end-block,
                total-funds: u0,
                is-active: true,
                funds-withdrawn: u0
            }
        )
        
        (var-set campaign-id-nonce new-campaign-id)
        (ok new-campaign-id)
    )
)

(define-public (add-milestone (campaign-id uint)
                            (description (string-ascii 256))
                            (funds-required uint)
                            (deadline uint)
                            (votes-needed uint))
    (let
        (
            (campaign (unwrap! (map-get? campaigns { campaign-id: campaign-id }) ERR_INVALID_CAMPAIGN))
        )
        ;; Input validation
        (asserts! (validate-campaign-id campaign-id) ERR_INVALID_CAMPAIGN)
        (asserts! (validate-string-input description) ERR_INVALID_INPUT)
        (asserts! (validate-uint-input funds-required) ERR_INVALID_INPUT)
        (asserts! (validate-uint-input deadline) ERR_INVALID_INPUT)
        (asserts! (validate-uint-input votes-needed) ERR_INVALID_INPUT)
        (asserts! (is-eq (get creator campaign) tx-sender) ERR_NOT_AUTHORIZED)
        (asserts! (get is-active campaign) ERR_CAMPAIGN_ENDED)
        
        (map-set milestones
            { campaign-id: campaign-id, milestone-id: u0 }
            {
                description: description,
                funds-required: funds-required,
                deadline: deadline,
                is-completed: false,
                votes-needed: votes-needed,
                votes-received: u0,
                funds-withdrawn: false
            }
        )
        (ok true)
    )
)

;; Funding Functions
(define-public (fund-campaign (campaign-id uint) (amount uint))
    (let
        (
            (campaign (unwrap! (map-get? campaigns { campaign-id: campaign-id }) ERR_INVALID_CAMPAIGN))
            (current-funds (default-to u0 (get amount (map-get? campaign-funders { campaign-id: campaign-id, funder: tx-sender }))))
        )
        ;; Input validation
        (asserts! (validate-campaign-id campaign-id) ERR_INVALID_CAMPAIGN)
        (asserts! (validate-uint-input amount) ERR_INVALID_INPUT)
        (asserts! (get is-active campaign) ERR_CAMPAIGN_ENDED)
        (asserts! (<= block-height (get end-block campaign)) ERR_CAMPAIGN_ENDED)
        
        ;; Transfer STX from sender to contract
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        ;; Update campaign funds
        (map-set campaigns
            { campaign-id: campaign-id }
            (merge campaign { total-funds: (+ (get total-funds campaign) amount) })
        )
        
        ;; Update funder record
        (map-set campaign-funders
            { campaign-id: campaign-id, funder: tx-sender }
            { amount: (+ current-funds amount) }
        )
        
        (ok true)
    )
)

;; New Function: Withdraw Milestone Funds
(define-public (withdraw-milestone-funds (campaign-id uint) (milestone-id uint))
    (let
        (
            (campaign (unwrap! (map-get? campaigns { campaign-id: campaign-id }) ERR_INVALID_CAMPAIGN))
            (milestone (unwrap! (map-get? milestones { campaign-id: campaign-id, milestone-id: milestone-id }) ERR_MILESTONE_NOT_FOUND))
        )
        ;; Input validation
        (asserts! (validate-campaign-id campaign-id) ERR_INVALID_CAMPAIGN)
        (asserts! (validate-milestone-id campaign-id milestone-id) ERR_MILESTONE_NOT_FOUND)
        ;; Verify caller is campaign creator
        (asserts! (is-eq (get creator campaign) tx-sender) ERR_NOT_AUTHORIZED)
        ;; Verify milestone is completed
        (asserts! (get is-completed milestone) ERR_INVALID_MILESTONE_STATE)
        ;; Verify funds haven't been withdrawn yet
        (asserts! (not (get funds-withdrawn milestone)) ERR_ALREADY_WITHDRAWN)
        
        ;; Calculate amount to withdraw
        (let
            (
                (withdrawal-amount (get funds-required milestone))
                (new-total-withdrawn (+ (get funds-withdrawn campaign) withdrawal-amount))
            )
            ;; Verify sufficient funds remain
            (asserts! (<= new-total-withdrawn (get total-funds campaign)) ERR_INSUFFICIENT_FUNDS)
            
            ;; Transfer funds to creator
            (try! (as-contract (stx-transfer? withdrawal-amount tx-sender (get creator campaign))))
            
            ;; Update milestone withdrawal status
            (map-set milestones
                { campaign-id: campaign-id, milestone-id: milestone-id }
                (merge milestone { funds-withdrawn: true })
            )
            
            ;; Update campaign total withdrawn
            (map-set campaigns
                { campaign-id: campaign-id }
                (merge campaign { funds-withdrawn: new-total-withdrawn })
            )
            
            (ok withdrawal-amount)
        )
    )
)

;; Milestone Voting and Validation
(define-public (vote-milestone (campaign-id uint) (milestone-id uint))
    (let
        (
            (milestone (unwrap! (map-get? milestones { campaign-id: campaign-id, milestone-id: milestone-id }) ERR_MILESTONE_NOT_FOUND))
            (campaign (unwrap! (map-get? campaigns { campaign-id: campaign-id }) ERR_INVALID_CAMPAIGN))
            (has-funded (> (default-to u0 (get amount (map-get? campaign-funders { campaign-id: campaign-id, funder: tx-sender }))) u0))
        )
        ;; Input validation
        (asserts! (validate-campaign-id campaign-id) ERR_INVALID_CAMPAIGN)
        (asserts! (validate-milestone-id campaign-id milestone-id) ERR_MILESTONE_NOT_FOUND)
        (asserts! has-funded ERR_NOT_AUTHORIZED)
        (asserts! (not (get is-completed milestone)) ERR_INVALID_MILESTONE_STATE)
        (asserts! (not (default-to false (get has-voted (map-get? milestone-votes { campaign-id: campaign-id, milestone-id: milestone-id, voter: tx-sender })))) ERR_NOT_AUTHORIZED)
        
        ;; Record vote
        (map-set milestone-votes
            { campaign-id: campaign-id, milestone-id: milestone-id, voter: tx-sender }
            { has-voted: true }
        )
        
        ;; Update milestone votes
        (map-set milestones
            { campaign-id: campaign-id, milestone-id: milestone-id }
            (merge milestone { votes-received: (+ (get votes-received milestone) u1) })
        )
        
        ;; Check if milestone is completed
        (if (>= (+ (get votes-received milestone) u1) (get votes-needed milestone))
            (begin
                ;; Mark milestone as completed
                (map-set milestones
                    { campaign-id: campaign-id, milestone-id: milestone-id }
                    (merge milestone { 
                        is-completed: true,
                        votes-received: (+ (get votes-received milestone) u1)
                    })
                )
                (ok true)
            )
            (ok true)
        )
    )
)

;; Refund Function
(define-public (claim-refund (campaign-id uint))
    (let
        (
            (campaign (unwrap! (map-get? campaigns { campaign-id: campaign-id }) ERR_INVALID_CAMPAIGN))
            (funder-amount (unwrap! (get amount (map-get? campaign-funders { campaign-id: campaign-id, funder: tx-sender })) ERR_INSUFFICIENT_FUNDS))
        )
        ;; Input validation
        (asserts! (validate-campaign-id campaign-id) ERR_INVALID_CAMPAIGN)
        (asserts! (> block-height (get end-block campaign)) ERR_INVALID_CAMPAIGN)
        (asserts! (< (get total-funds campaign) (get funding-goal campaign)) ERR_INVALID_CAMPAIGN)
        
        ;; Transfer refund
        (try! (as-contract (stx-transfer? funder-amount tx-sender tx-sender)))
        
        ;; Clear funder record
        (map-delete campaign-funders { campaign-id: campaign-id, funder: tx-sender })
        
        ;; Update campaign total funds
        (map-set campaigns
            { campaign-id: campaign-id }
            (merge campaign { total-funds: (- (get total-funds campaign) funder-amount) })
        )
        
        (ok true)
    )
)

;; Read-only Functions
(define-read-only (get-campaign-info (campaign-id uint))
    (map-get? campaigns { campaign-id: campaign-id })
)

(define-read-only (get-milestone-info (campaign-id uint) (milestone-id uint))
    (map-get? milestones { campaign-id: campaign-id, milestone-id: milestone-id })
)

(define-read-only (get-funder-amount (campaign-id uint) (funder principal))
    (map-get? campaign-funders { campaign-id: campaign-id, funder: funder })
)