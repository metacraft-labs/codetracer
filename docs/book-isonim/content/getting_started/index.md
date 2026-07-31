---
title: Getting Started
order: 0
---
# Overview

Welcome to the CodeTracer's getting started section. This guide will help you understand how to record and replay programs in each of the supported programming languages.

## Core Concept: Record and Replay

Unlike traditional debuggers that attach to a running process, CodeTracer works by first **recording** your application's execution into a trace file. This trace captures everything that happens during the run.

Once a recording is made, you can **replay** it as many times as you need in the CodeTracer GUI. This allows you to inspect the application's state at any point in time, move forwards and backwards through the execution, and use powerful features like tracepoints without having to run your application again.

Think of it like recording a video of your program's execution that you can then analyze in detail.

## How to Use This Guide

This guide is structured to help you get started quickly and then dive deeper into the features that interest you.

### General-Purpose Languages

These languages are recorded directly via the `ct` CLI (`ct record`, `ct run`):

- [**Python**](./python.md): Steps for installing the recorder, creating a trace, and replaying it with your interpreter.
- [**Ruby**](./ruby.md): Examples and steps how to trace a Ruby program.
- [**JavaScript / TypeScript**](./javascript.md): Instrument and record JS/TS programs.
- [**WASM**](./wasm.md): Examples and steps how to trace a WASM program.

### Zero-Knowledge Languages

- [**Noir**](./noir.md): Examples and steps how to trace a Noir program.
- [**Circom**](./circom.md): Trace witness generation for Circom zero-knowledge circuits.
- [**Miden**](./miden.md): Trace programs on the Miden STARK-based VM.
- [**Leo (Aleo)**](./leo.md): Trace Leo smart contracts on the Aleo network.

### Smart Contract Languages

These languages use dedicated recorder binaries. Record with the language-specific recorder, then view with `ct replay --trace-folder <dir>`:

- [**Solidity (EVM)**](./solidity.md): Trace Solidity contracts via debug_traceTransaction.
- [**Stylus**](./stylus.md): Examples and steps how to trace a Stylus contract.
- [**Cairo (StarkNet)**](./cairo.md): Trace Cairo programs and StarkNet contracts.
- [**Aiken (Cardano)**](./aiken.md): Step through UPLC CEK machine execution.
- [**Cadence (Flow)**](./cadence.md): Trace Cadence contracts via interpreter instrumentation.
- [**Move (Sui / Aptos)**](./move.md): Trace Move VM execution on Sui and Aptos.
- [**Solana**](./solana.md): Trace Solana SBF programs with DWARF source mapping.
- [**Sway (FuelVM)**](./sway.md): Trace Sway contracts on FuelVM.
- [**PolkaVM (ink!)**](./polkavm.md): Trace PolkaVM programs and ink! contracts.
- [**Tolk (TON)**](./tolk.md): Trace Tolk/FunC contracts on the TON blockchain.
