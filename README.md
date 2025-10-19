# RecurringVault Smart Contract

A Clarity smart contract for managing recurring payments and subscriptions on the Stacks blockchain.

## Overview

RecurringVault enables merchants to create subscription plans and users to make automated recurring payments using STX tokens. The contract handles deposit management, subscription lifecycle, and automated payment processing.

## Features

- 🏪 **Merchant Features**
  - Create and manage subscription plans
  - Set custom prices and billing periods
  - Withdraw earned balances
  - Update plan parameters

- 👤 **User Features**
  - Deposit/withdraw STX tokens
  - Subscribe to available plans
  - Automatic payment processing
  - Cancel subscriptions anytime

- 🔄 **Payment Processing**
  - Automated recurring payments
  - Batch processing support
  - Insufficient funds protection
  - Safe STX transfers

- 🛡️ **Security**
  - Emergency pause mechanism
  - Owner-only administrative functions
  - Protected merchant withdrawals
  - Safe numeric operations

## Contract Functions

### Administrative
- `pause()`: Emergency pause contract
- `unpause()`: Resume contract operations
- `set-block-height()`: Set block height (testing only)

### Merchant Operations
- `create-plan(price, period)`
- `update-plan(id, price, period, active)`
- `merchant-withdraw(amount)`

### User Operations
- `deposit(amount)`
- `withdraw-deposit(amount)`
- `subscribe(plan-id)`
- `cancel-sub(plan-id)`

### Payment Processing
- `process-payment(plan-id, user)`
- `process-batch(plan-id, users)`

### View Functions
- `get-plan(id)`
- `get-sub(plan-id, user)`
- `get-deposit(user)`
- `get-merchant-balance(merchant)`
- `all-plans()`

## Error Codes

| Code | Description |
|------|-------------|
| u100 | Unauthorized |
| u101 | Bad Arguments |
| u102 | Not Found |
| u103 | Insufficient Funds |
| u104 | Already Exists |
| u105 | Contract Paused |
| u106 | Payment Not Due |
| u107 | Plan Not Active |

## Development

Built with Clarity version 3 for the Stacks blockchain.

```bash
# Install dependencies
clarinet install

# Run tests
clarinet test

# Check contract
clarinet check
```
