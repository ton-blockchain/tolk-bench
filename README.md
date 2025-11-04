# "Tolk vs FunC" gas benchmarks

This repository demonstrates how real smart contracts look in **Tolk** — and how efficient they can be.

I took several standard contracts from the TON ecosystem (Jetton, NFT, Wallet, etc.) and migrated them **from FunC to Tolk**:
- preserving the original logic and behavior,
- **passing the same test suites** as the FunC versions,
- but written in **idiomatic, expressive Tolk style**,
- with **significantly reduced gas costs**.

**The goal is to show that Tolk can replace FunC** not just in theory — but in production, today.


## 📊 Benchmarks!

In gas units, plus code side (bits / cells).

### 01 — basic jetton

| Operation                       | FunC       | Tolk       | **Gas savings** |
|---------------------------------|------------|------------|-----------------|
| MINT jettons by admin           | 19278      | 11914      | **-38.20%**     |
| TRANSFER with forward_amount    | 19420      | 12904      | **-33.55%**     |
| TRANSFER no forward_amount      | 16964      | 10401      | **-38.69%**     |
| BURN jettons                    | 12514      | 7952       | **-36.46%**     |
| DISCOVER with include_address   | 7116       | 4456       | **-37.38%**     |
| DISCOVER no include_address     | 6554       | 3894       | **-40.59%**     |
| code size: minter               | 5046 / 14  | 4130 / 12  |                 |
| code size: wallet               | 6081 / 18  | 4485 / 11  |                 |

### 02 — basic nft

| Operation                       | FunC       | Tolk       | **Gas savings** |
|---------------------------------|------------|------------|-----------------|
| DEPLOY nft                      | 10469      | 5510       | **-47.37%**     |
| BATCH deploy nft                | 1049281    | 458212     | **-56.33%**     |
| TRANSFER nft                    | 7109       | 4478       | **-37.01%**     |
| GET static data                 | 4535       | 2543       | **-43.93%**     |
| code size: nft-item             | 3441 / 14  | 2581 / 7   |                 |
| code size: nft-collection       | 3564 / 19  | 3939 / 14  |                 |

### 03 — notcoin

| Operation                       | FunC       | Tolk       | **Gas savings** |
|---------------------------------|------------|------------|-----------------|
| MINT jettons by admin           | 17053      | 10664      | **-37.47%**     |
| TRANSFER with forward_amount    | 19638      | 14024      | **-28.59%**     |
| TRANSFER no forward_amount      | 16984      | 11655      | **-31.38%**     |
| BURN jettons                    | 12732      | 8532       | **-32.99%**     |
| DISCOVER with include_address   | 7107       | 4195       | **-40.97%**     |
| DISCOVER no include_address     | 6545       | 3633       | **-44.49%**     |
| code size: minter               | 8782 / 21  | 7119 / 16  |                 |
| code size: wallet               | 6794 / 15  | 5314 / 12  |                 |

### 04 — sharded jetton (tgBTC)

| Operation                       | FunC       | Tolk       | **Gas savings** |
|---------------------------------|------------|------------|-----------------|
| MINT jettons by admin           | 15019      | 10830      | **-27.89%**     |
| TRANSFER with forward_amount    | 20021      | 14388      | **-28.14%**     |
| TRANSFER no forward_amount      | 17489      | 12019      | **-31.28%**     |
| BURN jettons                    | 13089      | 8634       | **-34.04%**     |
| DISCOVER with include_address   | 7290       | 4429       | **-39.25%**     |
| DISCOVER no include_address     | 6728       | 3867       | **-42.52%**     |
| code size: minter               | 9454 / 21  | 7639 / 16  |                 |
| code size: wallet               | 6941 / 13  | 5333 / 10  |                 |

### 05 — wallet V5

| Operation                       | FunC       | Tolk       | **Gas savings** |
|---------------------------------|------------|------------|-----------------|
| EXTERNAL transfer               | 4939       | 3869       | **-21.66%**     |
| INTERNAL transfer               | 5645       | 4351       | **-22.92%**     |
| ADD extension                   | 6110       | 4951       | **-18.97%**     |
| EXTENSION transfer              | 3854       | 2951       | **-23.43%**     |
| code size: wallet_v5            | 4583 / 20  | 5775 / 20  |                 |

### 06 — vesting wallet

| Operation                       | FunC       | Tolk       | **Gas savings** |
|---------------------------------|------------|------------|-----------------|
| ADD whitelist                   | 8000       | 4384       | **-45.20%**     |
| UNLOCK internal partial         | 8365       | 5896       | **-29.52%**     |
| INTERNAL to vesting sender      | 6543       | 5160       | **-21.14%**     |
| INTERNAL to elector             | 11062      | 7623       | **-31.09%**     |
| INTERNAL to single nominator    | 10338      | 6748       | **-34.73%**     |
| INTERNAL with comment           | 10628      | 6836       | **-35.68%**     |
| EXTERNAL transfer after unlock  | 6740       | 4509       | **-33.10%**     |
| code size: vesting wallet       | 7413 / 28  | 7037 / 26  |                 |

### 07 — telemint (telegram gifts)

| Operation                       | FunC       | Tolk       | **Gas savings** |
|---------------------------------|------------|------------|-----------------|
| EXTERNAL to collection          | 2569       | 1161       | **-54.81%**     |
| DEPLOY item by admin            | 23706      | 14205      | **-40.08%**     |
| REJECT incorrect sender         | 24142      | 14903      | **-38.27%**     |
| OVERRIDE restrictions           | 24069      | 14835      | **-38.36%**     |
| INCREASE next bid               | 12640      | 7334       | **-41.98%**     |
| AUCTION end on expire           | 11317      | 7932       | **-29.91%**     |
| AUCTION end reached max bid     | 20497      | 12805      | **-37.53%**     |
| AUCTION start by owner          | 7762       | 4118       | **-46.95%**     |
| AUCTION cancel if no bids       | 6341       | 3189       | **-49.71%**     |
| AUCTION first bid               | 10394      | 5477       | **-47.31%**     |
| AUCTION next bid                | 12640      | 7334       | **-41.98%**     |
| TRANSFER item                   | 9508       | 6619       | **-30.38%**     |
| GET royalty params              | 4245       | 2906       | **-31.54%**     |
| code size: NftCollection        | 4649 / 17  | 3695 / 15  |                 |
| code size: NftItem              | 14785 / 37 | 13048 / 34 |                 |

<br>

## How does Tolk achieve these numbers?

#### 1. Language design and type system

Tolk code is closer to business logic — and still maps cleanly to the TVM's stack model.

This is not "compiler magic" — it's a result of language design. Just writing straightforward code is often more efficient than manual stack juggling in FunC.

For instance, universal `createMessage`, based on unions, is more lightweight than hand-crafted message cell composition. It also handles `StateInit` and deployment without creating extra cells.

#### 2. The `lazy` keyword

The compiler decides when and where to load data from slices. It enables:
- prefix-based lazy matching without creating unions on a stack,
- loading only the fields you actually use,
- skipping over unused fields or references,
- computing immutable sub-slices for serializing back.

#### 3. Optimizing compiler

Inlining, constant condition folding, grouping of sequential `storeInt`, peephole optimizations, stack reordering — all applied automatically.

#### 4. TVM-11 and TVM-12 instructions

TVM 11 allows accessing incoming message data without parsing `msg_cell`.
TVM 12 has `BTOS` ("builder-to-slice" without intermediate cell creation).
Combined, they contribute ~30% of the savings.
Most of the gain comes from the language itself.

#### 5. Fixing inefficiencies in original FunC code

In some cases, the FunC versions had suboptimal logic. The Tolk versions improve it — while preserving behavior.


## Not just about gas — readability comes first

Tolk is built for **readability**. These contracts aren't "just cleaner" than their FunC equivalents — they're **elegant**.  
No magic. No stack tricks. Just clean, consistent logic — whether it's a Jetton or a Wallet.

Take Jettons as an example. Compare these three files:

- a standard jetton config: [01/jetton_utils.tolk](contracts_Tolk/01_jetton/jetton-utils.tolk)
- Notcoin — supports masterchain: [03/jetton_utils.tolk](contracts_Tolk/03_notcoin/jetton-utils.tolk)
- tgBTC — supports sharding: [04/jetton_utils.tolk](contracts_Tolk/04_sharded_tgbtc/jetton-utils.tolk)

They are **remarkably similar**.  
Start with a simple Jetton. Want masterchain support? Add a line — and you have Notcoin.  
Want sharding? Set the desired `SHARD_DEPTH` — and you get a sharded Jetton.  
Message sending and address composition are encapsulated cleanly and declaratively.

And gas savings? They're a **consequence**.  
I didn't micro-optimize. Each contract was rewritten in about a day — just focusing on clarity.  
If the code is readable, it's probably already efficient.  
If the logic is hard to follow — that's where the inefficiency hides.

The compiler and stdlib will keep improving.  
But the core principle remains: **if you write code the way the language encourages — gas will take care of itself.**


## Correctness and test coverage

All Tolk contracts here **pass the same test suites** as their FunC originals.

In a few cases, tests were **slightly modified** — but only those that assert specific `exit codes`.

The reason: Tolk fails more gracefully on corrupted input. For example:
- FunC might crash with `exit code 9` ("cell underflow"),
- while Tolk returns `0xFFFF` ("invalid opcode").

So, I updated a few `expect(exit_code)` values — to match the actual (and now more meaningful) behavior.


## How to run and verify

```bash
npm run test:all
```

All tests are executed on Tolk contracts, using the same inputs as the original FunC versions.

The `bench-snapshots/` folder contains gas snapshots for each contract at different stages of rewriting.

You can also follow the Git history to see how each contract evolved — from raw auto-conversion to clean, idiomatic Tolk.


## Want to migrate your own contract from FunC to Tolk?

Start with the [FunC-to-Tolk converter](https://github.com/ton-blockchain/convert-func-to-tolk).  
It's a syntax-level tool that preserves 1:1 semantics — giving you a working Tolk version in "FunC-style," ready to be gradually modernized.

Then check out the guide [Tolk vs FunC](https://docs.ton.org/v3/documentation/smart-contracts/tolk/tolk-vs-func/in-short).  
It focuses on syntax differences — but keep in mind: **Tolk is more than just new syntax**.
The language encourages a different mindset — one that puts data structures and types at the center, rather than imperative flow.
This philosophy isn't always spelled out in docs — but you'll feel it as you work with the code.

Use the contracts in this repository as a reference — especially the ones you're already familiar with.

Finally, Tolk is supported in blueprint. Run `npm create ton@latest`, and start experimenting!
