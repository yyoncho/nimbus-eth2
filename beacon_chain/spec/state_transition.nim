# beacon_chain
# Copyright (c) 2018-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# State transition, as described in
# https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#beacon-chain-state-transition-function
#
# The entry point is `state_transition` which is at the bottom of the file!
#
# General notes about the code:
# * Weird styling - the sections taken from the spec use python styling while
#   the others use NEP-1 - helps grepping identifiers in spec
# * When updating the code, add TODO sections to mark where there are clear
#   improvements to be made - other than that, keep things similar to spec unless
#   motivated by security or performance considerations
#
# Performance notes:
# * The state transition is used in two contexts: to verify that incoming blocks
#   are correct and to replay existing blocks from database. Incoming blocks
#   are processed one-by-one while replay happens multiple blocks at a time.
# * Although signature verification is the slowest operation in the state
#   state transition, we skip it during replay - this is also when we repeatedly
#   call the state transition, making the non-signature part of the code
#   important from a performance point of view.
# * It's important to start with a prefilled cache - generating the shuffled
#   list of active validators is generally very slow.
# * Throughout, the code is affected by inefficient for loop codegen, meaning
#   that we have to iterate over indices and pick out the value manually:
#   https://github.com/nim-lang/Nim/issues/14421
# * Throughout, we're affected by inefficient `let` borrowing, meaning we
#   often have to take the address of a sequence item due to the above - look
#   for `let ... = unsafeAddr sequence[idx]`
# * Throughout, we're affected by the overloading rules that prefer a `var`
#   overload to a non-var overload - look for `asSeq()` - when the `var`
#   overload is used, the hash tree cache is cleared, which, aside from being
#   slow itself, causes additional processing to recalculate the merkle tree.

{.push raises: [Defect].}

import
  chronicles,
  stew/results,
  ../extras,
  ./datatypes/[phase0, altair, bellatrix],
  "."/[
    beaconstate, eth2_merkleization, forks, helpers, signatures,
    state_transition_block, state_transition_epoch, validator]

export results, extras, phase0, altair, bellatrix

# https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#beacon-chain-state-transition-function
proc verify_block_signature(
    state: ForkyBeaconState, signed_block: SomeForkySignedBeaconBlock):
    Result[void, cstring] =
  let
    proposer_index = signed_block.message.proposer_index
  if proposer_index >= state.validators.lenu64:
   return err("block: invalid proposer index")

  if not verify_block_signature(
      state.fork, state.genesis_validators_root, signed_block.message.slot,
      signed_block.root, state.validators[proposer_index].pubkey,
      signed_block.signature):
    return err("block: signature verification failed")

  ok()

# https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#beacon-chain-state-transition-function
func verifyStateRoot(
    state: ForkyBeaconState, blck: ForkyBeaconBlock | ForkySigVerifiedBeaconBlock):
    Result[void, cstring] =
  # This is inlined in state_transition(...) in spec.
  let state_root = hash_tree_root(state)
  if state_root != blck.state_root:
    err("block: state root verification failed")
  else:
    ok()

func verifyStateRoot(
    state: ForkyBeaconState, blck: ForkyTrustedBeaconBlock):
    Result[void, cstring] =
  # This is inlined in state_transition(...) in spec.
  ok()

type
  RollbackProc* = proc() {.gcsafe, noSideEffect, raises: [Defect].}
  RollbackHashedProc[T] =
    proc(state: var T) {.gcsafe, noSideEffect, raises: [Defect].}
  RollbackForkedHashedProc* = RollbackHashedProc[ForkedHashedBeaconState]

func noRollback*() =
  trace "Skipping rollback of broken state"

# Hashed-state transition functions
# ---------------------------------------------------------------

# https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#beacon-chain-state-transition-function
func process_slot*(
    state: var ForkyBeaconState, pre_state_root: Eth2Digest) =
  # `process_slot` is the first stage of per-slot processing - it is run for
  # every slot, including epoch slots - it does not however update the slot
  # number! `pre_state_root` refers to the state root of the incoming
  # state before any slot processing has been done.

  # Cache state root
  state.state_roots[state.slot mod SLOTS_PER_HISTORICAL_ROOT] = pre_state_root

  # Cache latest block header state root
  if state.latest_block_header.state_root == ZERO_HASH:
    state.latest_block_header.state_root = pre_state_root

  # Cache block root
  state.block_roots[state.slot mod SLOTS_PER_HISTORICAL_ROOT] =
    hash_tree_root(state.latest_block_header)

func clear_epoch_from_cache(cache: var StateCache, epoch: Epoch) =
  cache.shuffled_active_validator_indices.del epoch

  for slot in epoch.slots():
    cache.beacon_proposer_indices.del slot

# https://github.com/ethereum/consensus-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#beacon-chain-state-transition-function
proc advance_slot(
    cfg: RuntimeConfig,
    state: var ForkyBeaconState, previous_slot_state_root: Eth2Digest,
    flags: UpdateFlags, cache: var StateCache, info: var ForkyEpochInfo) =
  # Do the per-slot and potentially the per-epoch processing, then bump the
  # slot number - we've now arrived at the slot state on top of which a block
  # optionally can be applied.
  process_slot(state, previous_slot_state_root)

  info.clear()

  let is_epoch_transition = (state.slot + 1).is_epoch
  if is_epoch_transition:
    # Note: Genesis epoch = 0, no need to test if before Genesis
    process_epoch(cfg, state, flags, cache, info)
    clear_epoch_from_cache(cache, (state.slot + 1).epoch)

  state.slot += 1

func noRollback*(state: var phase0.HashedBeaconState) =
  trace "Skipping rollback of broken phase 0 state"

func noRollback*(state: var altair.HashedBeaconState) =
  trace "Skipping rollback of broken Altair state"

func noRollback*(state: var bellatrix.HashedBeaconState) =
  trace "Skipping rollback of broken Bellatrix state"

func maybeUpgradeStateToAltair(
    cfg: RuntimeConfig, state: var ForkedHashedBeaconState) =
  # Both process_slots() and state_transition_block() call this, so only run it
  # once by checking for existing fork.
  if getStateField(state, slot).epoch == cfg.ALTAIR_FORK_EPOCH and
      state.kind == BeaconStateFork.Phase0:
    let newState = upgrade_to_altair(cfg, state.phase0Data.data)
    state = (ref ForkedHashedBeaconState)(
      kind: BeaconStateFork.Altair,
      altairData: altair.HashedBeaconState(
        root: hash_tree_root(newState[]), data: newState[]))[]

func maybeUpgradeStateToBellatrix(
    cfg: RuntimeConfig, state: var ForkedHashedBeaconState) =
  # Both process_slots() and state_transition_block() call this, so only run it
  # once by checking for existing fork.
  if getStateField(state, slot).epoch == cfg.BELLATRIX_FORK_EPOCH and
      state.kind == BeaconStateFork.Altair:
    let newState = upgrade_to_bellatrix(cfg, state.altairData.data)
    state = (ref ForkedHashedBeaconState)(
      kind: BeaconStateFork.Bellatrix,
      bellatrixData: bellatrix.HashedBeaconState(
        root: hash_tree_root(newState[]), data: newState[]))[]

func maybeUpgradeState*(
    cfg: RuntimeConfig, state: var ForkedHashedBeaconState) =
  cfg.maybeUpgradeStateToAltair(state)
  cfg.maybeUpgradeStateToBellatrix(state)

proc process_slots*(
    cfg: RuntimeConfig, state: var ForkedHashedBeaconState, slot: Slot,
    cache: var StateCache, info: var ForkedEpochInfo, flags: UpdateFlags):
    Result[void, cstring] =
  if not (getStateField(state, slot) < slot):
    if slotProcessed notin flags or getStateField(state, slot) != slot:
      return err("process_slots: cannot rewind state to past slot")

  # Update the state so its slot matches that of the block
  while getStateField(state, slot) < slot:
    withState(state):
      withEpochInfo(state.data, info):
        advance_slot(
          cfg, state.data, state.root, flags, cache, info)

      if skipLastStateRootCalculation notin flags or
          state.data.slot < slot:
        # Don't update state root for the slot of the block if going to process
        # block after
        state.root = hash_tree_root(state.data)

    maybeUpgradeState(cfg, state)

  ok()

proc state_transition_block_aux(
    cfg: RuntimeConfig,
    state: var ForkyHashedBeaconState,
    signedBlock: SomeForkySignedBeaconBlock,
    cache: var StateCache, flags: UpdateFlags): Result[void, cstring] =
  # Block updates - these happen when there's a new block being suggested
  # by the block proposer. Every actor in the network will update its state
  # according to the contents of this block - but first they will validate
  # that the block is sane.
  if skipBLSValidation notin flags:
    ? verify_block_signature(state.data, signedBlock)

  trace "state_transition: processing block, signature passed",
    signature = shortLog(signedBlock.signature),
    blockRoot = shortLog(signedBlock.root)

  ? process_block(cfg, state.data, signedBlock.message, flags, cache)

  if skipStateRootValidation notin flags:
    ? verifyStateRoot(state.data, signedBlock.message)

  # only blocks currently being produced have an empty state root - we use a
  # separate function for those
  doAssert not signedBlock.message.state_root.isZero,
    "see makeBeaconBlock for block production"
  state.root = signedBlock.message.state_root

  ok()

func noRollback*(state: var ForkedHashedBeaconState) =
  trace "Skipping rollback of broken state"

proc state_transition_block*(
    cfg: RuntimeConfig,
    state: var ForkedHashedBeaconState,
    signedBlock: SomeForkySignedBeaconBlock,
    cache: var StateCache, flags: UpdateFlags,
    rollback: RollbackForkedHashedProc): Result[void, cstring] =
  ## `rollback` is called if the transition fails and the given state has been
  ## partially changed. If a temporary state was given to `state_transition`,
  ## it is safe to use `noRollback` and leave it broken, else the state
  ## object should be rolled back to a consistent state. If the transition fails
  ## before the state has been updated, `rollback` will not be called.
  doAssert not rollback.isNil, "use noRollback if it's ok to mess up state"

  let res = withState(state):
    when stateFork.toBeaconBlockFork() == type(signedBlock).toFork:
      state_transition_block_aux(cfg, state, signedBlock, cache, flags)
    else:
      err("State/block fork mismatch")

  if res.isErr():
    rollback(state)

  res

proc state_transition*(
    cfg: RuntimeConfig,
    state: var ForkedHashedBeaconState,
    signedBlock: SomeForkySignedBeaconBlock,
    cache: var StateCache, info: var ForkedEpochInfo, flags: UpdateFlags,
    rollback: RollbackForkedHashedProc): Result[void, cstring] =
  ## Apply a block to the state, advancing the slot counter as necessary. The
  ## given state must be of a lower slot, or, in case the `slotProcessed` flag
  ## is set, can be the slot state of the same slot as the block (where the
  ## slot state is the state without any block applied). To create a slot state,
  ## advance the state corresponding to the the parent block using
  ## `process_slots`.
  ##
  ## To run the state transition function in preparation for block production,
  ## use `makeBeaconBlock` instead.
  ##
  ## `rollback` is called if the transition fails and the given state has been
  ## partially changed. If a temporary state was given to `state_transition`,
  ## it is safe to use `noRollback` and leave it broken, else the state
  ## object should be rolled back to a consistent state. If the transition fails
  ## before the state has been updated, `rollback` will not be called.
  ? process_slots(
      cfg, state, signedBlock.message.slot, cache, info,
      flags + {skipLastStateRootCalculation})

  state_transition_block(
    cfg, state, signedBlock, cache, flags, rollback)

# https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/validator.md#preparing-for-a-beaconblock
template partialBeaconBlock(
    cfg: RuntimeConfig,
    state: var phase0.HashedBeaconState,
    proposer_index: ValidatorIndex,
    randao_reveal: ValidatorSig,
    eth1_data: Eth1Data,
    graffiti: GraffitiBytes,
    attestations: seq[Attestation],
    deposits: seq[Deposit],
    exits: BeaconBlockExits,
    sync_aggregate: SyncAggregate,
    execution_payload: ExecutionPayload): phase0.BeaconBlock =
  phase0.BeaconBlock(
    slot: state.data.slot,
    proposer_index: proposer_index.uint64,
    parent_root: state.latest_block_root(),
    body: phase0.BeaconBlockBody(
      randao_reveal: randao_reveal,
      eth1_data: eth1data,
      graffiti: graffiti,
      proposer_slashings: exits.proposer_slashings,
      attester_slashings: exits.attester_slashings,
      attestations: List[Attestation, Limit MAX_ATTESTATIONS](attestations),
      deposits: List[Deposit, Limit MAX_DEPOSITS](deposits),
      voluntary_exits: exits.voluntary_exits))

proc makeBeaconBlock*(
    cfg: RuntimeConfig,
    state: var phase0.HashedBeaconState,
    proposer_index: ValidatorIndex,
    randao_reveal: ValidatorSig,
    eth1_data: Eth1Data,
    graffiti: GraffitiBytes,
    attestations: seq[Attestation],
    deposits: seq[Deposit],
    exits: BeaconBlockExits,
    sync_aggregate: SyncAggregate,
    execution_payload: ExecutionPayload,
    rollback: RollbackHashedProc[phase0.HashedBeaconState],
    cache: var StateCache): Result[phase0.BeaconBlock, cstring] =
  ## Create a block for the given state. The latest block applied to it will
  ## be used for the parent_root value, and the slot will be take from
  ## state.slot meaning process_slots must be called up to the slot for which
  ## the block is to be created.

  # To create a block, we'll first apply a partial block to the state, skipping
  # some validations.

  var blck = partialBeaconBlock(cfg, state, proposer_index,
                                randao_reveal, eth1_data, graffiti, attestations, deposits,
                                exits, sync_aggregate, executionPayload)

  let res = process_block(cfg, state.data, blck, {skipBlsValidation}, cache)

  if res.isErr:
    rollback(state)
    return err(res.error())

  state.root = hash_tree_root(state.data)
  blck.state_root = state.root

  ok(blck)

# https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/altair/validator.md#preparing-a-beaconblock
template partialBeaconBlock(
    cfg: RuntimeConfig,
    state: var altair.HashedBeaconState,
    proposer_index: ValidatorIndex,
    randao_reveal: ValidatorSig,
    eth1_data: Eth1Data,
    graffiti: GraffitiBytes,
    attestations: seq[Attestation],
    deposits: seq[Deposit],
    exits: BeaconBlockExits,
    sync_aggregate: SyncAggregate,
    execution_payload: ExecutionPayload): altair.BeaconBlock =
  altair.BeaconBlock(
    slot: state.data.slot,
    proposer_index: proposer_index.uint64,
    parent_root: state.latest_block_root(),
    body: altair.BeaconBlockBody(
      randao_reveal: randao_reveal,
      eth1_data: eth1data,
      graffiti: graffiti,
      proposer_slashings: exits.proposer_slashings,
      attester_slashings: exits.attester_slashings,
      attestations: List[Attestation, Limit MAX_ATTESTATIONS](attestations),
      deposits: List[Deposit, Limit MAX_DEPOSITS](deposits),
      voluntary_exits: exits.voluntary_exits,
      sync_aggregate: sync_aggregate))

proc makeBeaconBlock*(
    cfg: RuntimeConfig,
    state: var altair.HashedBeaconState,
    proposer_index: ValidatorIndex,
    randao_reveal: ValidatorSig,
    eth1_data: Eth1Data,
    graffiti: GraffitiBytes,
    attestations: seq[Attestation],
    deposits: seq[Deposit],
    exits: BeaconBlockExits,
    sync_aggregate: SyncAggregate,
    execution_payload: ExecutionPayload,
    rollback: RollbackHashedProc[altair.HashedBeaconState],
    cache: var StateCache): Result[altair.BeaconBlock, cstring] =
  ## Create a block for the given state. The latest block applied to it will
  ## be used for the parent_root value, and the slot will be take from
  ## state.slot meaning process_slots must be called up to the slot for which
  ## the block is to be created.

  # To create a block, we'll first apply a partial block to the state, skipping
  # some validations.

  var blck = partialBeaconBlock(cfg, state, proposer_index,
                                randao_reveal, eth1_data, graffiti, attestations, deposits,
                                exits, sync_aggregate, execution_payload)

  let res = process_block(cfg, state.data, blck, {skipBlsValidation}, cache)

  if res.isErr:
    rollback(state)
    return err(res.error())

  state.root = hash_tree_root(state.data)
  blck.state_root = state.root

  ok(blck)

# https://github.com/ethereum/consensus-specs/blob/v1.1.3/specs/merge/validator.md#block-proposal
template partialBeaconBlock(
    cfg: RuntimeConfig,
    state: var bellatrix.HashedBeaconState,
    proposer_index: ValidatorIndex,
    randao_reveal: ValidatorSig,
    eth1_data: Eth1Data,
    graffiti: GraffitiBytes,
    attestations: seq[Attestation],
    deposits: seq[Deposit],
    exits: BeaconBlockExits,
    sync_aggregate: SyncAggregate,
    execution_payload: ExecutionPayload): bellatrix.BeaconBlock =
  bellatrix.BeaconBlock(
    slot: state.data.slot,
    proposer_index: proposer_index.uint64,
    parent_root: state.latest_block_root(),
    body: bellatrix.BeaconBlockBody(
      randao_reveal: randao_reveal,
      eth1_data: eth1data,
      graffiti: graffiti,
      proposer_slashings: exits.proposer_slashings,
      attester_slashings: exits.attester_slashings,
      attestations: List[Attestation, Limit MAX_ATTESTATIONS](attestations),
      deposits: List[Deposit, Limit MAX_DEPOSITS](deposits),
      voluntary_exits: exits.voluntary_exits,
      sync_aggregate: sync_aggregate,
      execution_payload: execution_payload))

proc makeBeaconBlock*(
    cfg: RuntimeConfig,
    state: var bellatrix.HashedBeaconState,
    proposer_index: ValidatorIndex,
    randao_reveal: ValidatorSig,
    eth1_data: Eth1Data,
    graffiti: GraffitiBytes,
    attestations: seq[Attestation],
    deposits: seq[Deposit],
    exits: BeaconBlockExits,
    sync_aggregate: SyncAggregate,
    execution_payload: ExecutionPayload,
    rollback: RollbackHashedProc[bellatrix.HashedBeaconState],
    cache: var StateCache): Result[bellatrix.BeaconBlock, cstring] =
  ## Create a block for the given state. The latest block applied to it will
  ## be used for the parent_root value, and the slot will be take from
  ## state.slot meaning process_slots must be called up to the slot for which
  ## the block is to be created.

  # To create a block, we'll first apply a partial block to the state, skipping
  # some validations.

  var blck = partialBeaconBlock(cfg, state, proposer_index,
                                randao_reveal, eth1_data, graffiti, attestations, deposits,
                                exits, sync_aggregate, execution_payload)

  let res = process_block(cfg, state.data, blck, {skipBlsValidation}, cache)

  if res.isErr:
    rollback(state)
    return err(res.error())

  state.root = hash_tree_root(state.data)
  blck.state_root = state.root

  ok(blck)

proc makeBeaconBlock*(
    cfg: RuntimeConfig,
    state: var ForkedHashedBeaconState,
    proposer_index: ValidatorIndex,
    randao_reveal: ValidatorSig,
    eth1_data: Eth1Data,
    graffiti: GraffitiBytes,
    attestations: seq[Attestation],
    deposits: seq[Deposit],
    exits: BeaconBlockExits,
    sync_aggregate: SyncAggregate,
    executionPayload: ExecutionPayload,
    rollback: RollbackForkedHashedProc,
    cache: var StateCache): Result[ForkedBeaconBlock, cstring] =
  ## Create a block for the given state. The latest block applied to it will
  ## be used for the parent_root value, and the slot will be take from
  ## state.slot meaning process_slots must be called up to the slot for which
  ## the block is to be created.

  template makeBeaconBlock(kind: untyped): Result[ForkedBeaconBlock, cstring] =
    # To create a block, we'll first apply a partial block to the state, skipping
    # some validations.

    var blck =
      ForkedBeaconBlock.init(
        partialBeaconBlock(cfg, state.`kind Data`, proposer_index,
                           randao_reveal, eth1_data, graffiti, attestations, deposits,
                           exits, sync_aggregate, executionPayload))

    let res = process_block(cfg, state.`kind Data`.data, blck.`kind Data`,
                            {skipBlsValidation}, cache)

    if res.isErr:
      rollback(state)
      return err(res.error())

    state.`kind Data`.root = hash_tree_root(state.`kind Data`.data)
    blck.`kind Data`.state_root = state.`kind Data`.root

    ok(blck)

  case state.kind
  of BeaconStateFork.Phase0:    makeBeaconBlock(phase0)
  of BeaconStateFork.Altair:    makeBeaconBlock(altair)
  of BeaconStateFork.Bellatrix: makeBeaconBlock(bellatrix)
