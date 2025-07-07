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
| MINT jettons by admin           | 19278      | 11611      | **-39.77%**     |
| TRANSFER with forward_amount    | 19420      | 13531      | **-30.32%**     |
| TRANSFER no forward_amount      | 16964      | 11144      | **-34.31%**     |
| BURN jettons                    | 12514      | 8302       | **-33.66%**     |
| DISCOVER with include_address   | 7116       | 5355       | **-24.75%**     |
| DISCOVER no include_address     | 6554       | 4801       | **-26.75%**     |
| code size: minter               | 5046 / 14  | 4730 / 11  |                 |
| code size: wallet               | 6081 / 18  | 4798 / 10  |                 |

### 02 — basic nft

| Operation                       | FunC       | Tolk       | **Gas savings** |
|---------------------------------|------------|------------|-----------------|
| DEPLOY nft                      | 10469      | 5885       | **-43.79%**     |
| BATCH deploy nft                | 1049281    | 686820     | **-34.54%**     |
| TRANSFER nft                    | 7109       | 4445       | **-37.47%**     |
| GET static data                 | 4535       | 2527       | **-44.28%**     |
| code size: nft-item             | 3441 / 14  | 2597 / 7   |                 |
| code size: nft-collection       | 3564 / 19  | 4339 / 14  |                 |

### 03 — notcoin

| Operation                       | FunC       | Tolk       | **Gas savings** |
|---------------------------------|------------|------------|-----------------|
| MINT jettons by admin           | 17053      | 10962      | **-35.72%**     |
| TRANSFER with forward_amount    | 19638      | 14585      | **-25.73%**     |
| TRANSFER no forward_amount      | 16984      | 12232      | **-27.98%**     |
| BURN jettons                    | 12732      | 8800       | **-30.88%**     |
| DISCOVER with include_address   | 7107       | 5002       | **-29.62%**     |
| DISCOVER no include_address     | 6545       | 4448       | **-32.04%**     |
| code size: minter               | 8782 / 21  | 7719 / 16  |                 |
| code size: wallet               | 6794 / 15  | 5602 / 12  |                 |

### 04 — sharded jetton (tgBTC)

| Operation                       | FunC       | Tolk       | **Gas savings** |
|---------------------------------|------------|------------|-----------------|
| MINT jettons by admin           | 15019      | 11424      | **-23.94%**     |
| TRANSFER with forward_amount    | 20021      | 15122      | **-24.47%**     |
| TRANSFER no forward_amount      | 17489      | 12769      | **-26.99%**     |
| BURN jettons                    | 13089      | 9069       | **-30.71%**     |
| DISCOVER with include_address   | 7290       | 5419       | **-25.67%**     |
| DISCOVER no include_address     | 6728       | 4865       | **-27.69%**     |
| code size: minter               | 9454 / 21  | 8351 / 18  |                 |
| code size: wallet               | 6941 / 13  | 5631 / 11  |                 |

### 05 — wallet V5

| Operation                       | FunC       | Tolk       | **Gas savings** |
|---------------------------------|------------|------------|-----------------|
| EXTERNAL transfer               | 4939       | 3869       | **-21.66%**     |
| INTERNAL transfer               | 5645       | 4351       | **-22.92%**     |
| ADD extension                   | 6110       | 4949       | **-19.00%**     |
| EXTENSION transfer              | 3854       | 2951       | **-23.43%**     |
| code size: wallet_v5            | 4583 / 20  | 5775 / 20  |                 |

### 06 — vesting wallet

| Operation                       | FunC       | Tolk       | **Gas savings** |
|---------------------------------|------------|------------|-----------------|
| ADD whitelist                   | 8000       | 4376       | **-45.30%**     |
| UNLOCK internal partial         | 8365       | 5888       | **-29.61%**     |
| INTERNAL to vesting sender      | 6543       | 5152       | **-21.26%**     |
| INTERNAL to elector             | 11062      | 7615       | **-31.16%**     |
| INTERNAL to single nominator    | 10338      | 6740       | **-34.80%**     |
| INTERNAL with comment           | 10628      | 6828       | **-35.75%**     |
| EXTERNAL transfer after unlock  | 6740       | 4509       | **-33.10%**     |
| code size: vesting wallet       | 7413 / 28  | 6973 / 26  |                 |

### 07 — telemint (telegram gifts)

| Operation                       | FunC       | Tolk       | **Gas savings** |
|---------------------------------|------------|------------|-----------------|
| EXTERNAL to collection          | 2569       | 1161       | **-54.81%**     |
| DEPLOY item by admin            | 23706      | 14368      | **-39.39%**     |
| REJECT incorrect sender         | 24142      | 15066      | **-37.59%**     |
| OVERRIDE restrictions           | 24069      | 14998      | **-37.69%**     |
| INCREASE next bid               | 12640      | 7302       | **-42.23%**     |
| AUCTION end on expire           | 11317      | 7892       | **-30.26%**     |
| AUCTION end reached max bid     | 20497      | 12741      | **-37.84%**     |
| AUCTION start by owner          | 7762       | 4040       | **-47.95%**     |
| AUCTION cancel if no bids       | 6341       | 3111       | **-50.94%**     |
| AUCTION first bid               | 10394      | 5453       | **-47.54%**     |
| AUCTION next bid                | 12640      | 7302       | **-42.23%**     |
| TRANSFER item                   | 9508       | 6395       | **-32.74%**     |
| GET royalty params              | 4245       | 2890       | **-31.92%**     |
| code size: NftCollection        | 4649 / 17  | 3999 / 14  |                 |
| code size: NftItem              | 14785 / 37 | 12768 / 31 |                 |

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

#### 4. TVM-11 instructions

They allow accessing incoming message data without parsing `msg_cell` — but contribute only ~25% of the savings.
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
