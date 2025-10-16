# LockDropX: Time-Weighted Token Distribution 🔒

A Clarity v2 smart contract implementation for time-weighted token distribution on the Stacks blockchain.

## Overview

LockDropX enables users to lock STX tokens for variable durations to earn proportional rewards based on their lock amount and duration. The system uses a time-weighted mechanism to calculate reward distributions.

## Features

- 🔒 **Flexible STX Locking**: Lock STX tokens for custom durations
- ⚖️ **Time-Weighted Rewards**: Earn rewards based on amount × duration
- 🔄 **Extensible Locks**: Extend lock periods before snapshot
- 🎯 **Snapshot Mechanism**: Freezes total weights for fair distribution
- 💎 **SIP-010 Compatible**: Works with any SIP-010 compliant token
- 🛡️ **Secure Withdrawals**: Guaranteed STX return after lock expiration

## Contract Functions

### User Functions
```clarity
(lock (duration uint)) -> Locks STX tokens
(extend-lock (id uint) (extra-duration uint)) -> Extends lock duration
(withdraw-lock (id uint)) -> Withdraws locked STX after expiration
(claim-rewards (token-pr <ft-trait>)) -> Claims earned rewards
```

### Admin Functions
```clarity
(set-reward-token (token-pr <ft-trait>)) -> Sets reward token
(deposit-rewards (token-pr <ft-trait>) (amount uint)) -> Deposits rewards
(finalize-snapshot) -> Finalizes reward distribution snapshot
(owner-withdraw-rewards (token-pr <ft-trait>) (amount uint) (to principal))
```

## Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/lockdropx.git

# Navigate to project directory
cd lockdropx

# Deploy contract (requires Clarinet)
clarinet contract deploy
```

## Testing

```bash
# Run all tests
clarinet test

# Run specific test file
clarinet test tests/lockdropx_test.ts
```

## Security Considerations

- Contract has built-in security checks
- Owner controls reward token setup
- Safe withdrawal mechanisms
- Comprehensive error handling
- Required audit before mainnet deployment
