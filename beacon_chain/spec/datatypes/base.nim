# beacon_chain
# Copyright (c) 2018-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# This file contains data types that are part of the spec and thus subject to
# serialization and spec updates.
#
# The spec folder in general contains code that has been hoisted from the
# specification and that follows the spec as closely as possible, so as to make
# it easy to keep up-to-date.
#
# These datatypes are used as specifications for serialization - thus should not
# be altered outside of what the spec says. Likewise, they should not be made
# `ref` - this can be achieved by wrapping them in higher-level
# types / composition

# TODO Careful, not nil analysis is broken / incomplete and the semantics will
#      likely change in future versions of the language:
#      https://github.com/nim-lang/RFCs/issues/250
{.experimental: "notnil".}

{.push raises: [Defect].}

import
  std/[macros, hashes, strutils, tables, typetraits],
  stew/[assign2, byteutils, results],
  chronicles,
  json_serialization,
  chronos/timer,
  ssz_serialization/types as sszTypes,
  ../../version,
  ".."/[beacon_time, crypto, digest, presets]

export
  tables, results, json_serialization, timer, sszTypes, beacon_time, crypto,
  digest, presets

# Presently, we're reusing the data types from the serialization (uint64) in the
# objects we pass around to the beacon chain logic, thus keeping the two
# similar. This is convenient for keeping up with the specification, but
# will eventually need a more robust approach such that we don't run into
# over- and underflows.
# Some of the open questions are being tracked here:
# https://github.com/ethereum/consensus-specs/issues/224
#
# The present approach causes some problems due to how Nim treats unsigned
# integers - here's no high(uint64), arithmetic support is incomplete, there's
# no over/underflow checking available
#
# Eventually, we could also differentiate between user/tainted data and
# internal state that's gone through sanity checks already.

const SPEC_VERSION* = "1.1.10"
## Spec version we're aiming to be compatible with, right now

const
  # Not part of spec. Still useful, pending removing usage if appropriate.
  ZERO_HASH* = Eth2Digest()
  MAX_GRAFFITI_SIZE* = 32

  # https://github.com/ethereum/consensus-specs/blob/v1.1.9/specs/phase0/p2p-interface.md#configuration
  MAXIMUM_GOSSIP_CLOCK_DISPARITY* = 500.millis

  SLOTS_PER_ETH1_VOTING_PERIOD* =
    EPOCHS_PER_ETH1_VOTING_PERIOD * SLOTS_PER_EPOCH

  DEPOSIT_CONTRACT_TREE_DEPTH* = 32
  BASE_REWARDS_PER_EPOCH* = 4

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/validator.md#misc
  ATTESTATION_SUBNET_COUNT* = 64

template maxSize*(n: int) {.pragma.}

# Block validation flow
# We distinguish 4 cases depending
# if the signature and/or transition logic of a
# a block have been verified:
#
# |                            | Signature unchecked             | Signature verified          |
# |----------------------------|-------------------------------  |-----------------------------|
# | State transition unchecked | - UntrustedBeaconBlock          | - SigVerifiedBeaconBlock    |
# |                            | - UntrustedIndexedAttestation   | - TrustedIndexedAttestation |
# |                            | - UntrustedAttestation          | - TrustedAttestation        |
# |----------------------------|-------------------------------  |-----------------------------|
# | State transition verified  | - TransitionVerifiedBeaconBlock | - TrustedSignedBeaconBlock  |
# |                            | - UntrustedIndexedAttestation   | - TrustedIndexedAttestation |
# |                            | - UntrustedAttestation          | - TrustedAttestation        |
#
# At the moment we only introduce SigVerifiedBeaconBlock
# and keep the old naming where BeaconBlock == UntrustedbeaconBlock
# Also for Attestation, IndexedAttestation, AttesterSlashing, ProposerSlashing.
# We only distinguish between the base version and the Trusted version
# (i.e. Attestation and TrustedAttestation)
# The Trusted version, at the moment, implies that the cryptographic signature was checked.
# It DOES NOT imply that the state transition was verified.
# Currently the code MUST verify the state transition as soon as the signature is verified
#
# TODO We could implement the trust level as either static enums or generic tags
# and reduce duplication and improve maintenance and readability,
# however this caused problems respectively of:
# - ambiguous calls, in particular for chronicles, with static enums
# - broke the compiler in SSZ and nim-serialization

type
  # Domains
  # ---------------------------------------------------------------
  DomainType* = distinct array[4, byte]

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#custom-types
  Eth2Domain* = array[32, byte]

  # https://github.com/nim-lang/Nim/issues/574 and be consistent across
  # 32-bit and 64-bit word platforms.
  # The distinct types here should only be used when data has been de-tainted
  # following overflow checks - they cannot be used in SSZ objects as SSZ
  # instances are not invalid _per se_ when they hold an out-of-bounds index -
  # that is part of consensus.
  # VALIDATOR_REGISTRY_LIMIT is 1^40 in spec 1.0, but if the number of
  # validators ever grows near 1^32 that we support here, we'll have bigger
  # issues than the size of this type to take care of. Until then, we'll use
  # uint32 as it halves memory requirements for active validator sets,
  # improves consistency on 32-vs-64-bit platforms and works better with
  # Nim seq constraints.
  ValidatorIndex* = distinct uint32

  CommitteeIndex* = distinct uint8
    ## Index identifying a per-slot committee - depending on the active
    ## validator count, there may be up to `MAX_COMMITTEES_PER_SLOT` committees
    ## working in each slot.
    ##
    ## The `CommitteeIndex` type is constrained to values in the range
    ## `[0, MAX_COMMITTEES_PER_SLOT)` during initialization - to find out if
    ## a committee index is valid for a particular state, see
    ## `check_attestation_index`.
    ##
    ## `CommitteeIndex` is not used in `datatypes` to allow reading invalid data
    ## (validation happens on use instead, via `init`).

  SubnetId* = distinct uint8
    ## The subnet id maps which gossip subscription to use to publish an
    ## attestation - it is distinct from the CommitteeIndex in particular
    ##
    ## The `SubnetId` type is constrained to values in the range
    ## `[0, ATTESTATION_SUBNET_COUNT)` during initialization.

  Gwei* = uint64

  # BitVector[4] in the spec, ie 4 bits which end up encoded as a byte for
  # SSZ / hashing purposes
  JustificationBits* = distinct uint8

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#proposerslashing
  ProposerSlashing* = object
    signed_header_1*: SignedBeaconBlockHeader
    signed_header_2*: SignedBeaconBlockHeader

  TrustedProposerSlashing* = object
    # The Trusted version, at the moment, implies that the cryptographic signature was checked.
    # It DOES NOT imply that the state transition was verified.
    # Currently the code MUST verify the state transition as soon as the signature is verified
    signed_header_1*: TrustedSignedBeaconBlockHeader
    signed_header_2*: TrustedSignedBeaconBlockHeader

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#attesterslashing
  AttesterSlashing* = object
    attestation_1*: IndexedAttestation
    attestation_2*: IndexedAttestation

  TrustedAttesterSlashing* = object
    # The Trusted version, at the moment, implies that the cryptographic signature was checked.
    # It DOES NOT imply that the state transition was verified.
    # Currently the code MUST verify the state transition as soon as the signature is verified
    attestation_1*: TrustedIndexedAttestation
    attestation_2*: TrustedIndexedAttestation

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#indexedattestation
  IndexedAttestation* = object
    attesting_indices*: List[uint64, Limit MAX_VALIDATORS_PER_COMMITTEE]
    data*: AttestationData
    signature*: ValidatorSig

  TrustedIndexedAttestation* = object
    # The Trusted version, at the moment, implies that the cryptographic signature was checked.
    # It DOES NOT imply that the state transition was verified.
    # Currently the code MUST verify the state transition as soon as the signature is verified
    attesting_indices*: List[uint64, Limit MAX_VALIDATORS_PER_COMMITTEE]
    data*: AttestationData
    signature*: TrustedSig

  CommitteeValidatorsBits* = BitList[Limit MAX_VALIDATORS_PER_COMMITTEE]

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#attestation
  Attestation* = object
    aggregation_bits*: CommitteeValidatorsBits
    data*: AttestationData
    signature*: ValidatorSig

  TrustedAttestation* = object
    # The Trusted version, at the moment, implies that the cryptographic signature was checked.
    # It DOES NOT imply that the state transition was verified.
    # Currently the code MUST verify the state transition as soon as the signature is verified
    aggregation_bits*: CommitteeValidatorsBits
    data*: AttestationData
    signature*: TrustedSig

  ForkDigest* = distinct array[4, byte]

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#forkdata
  ForkData* = object
    current_version*: Version
    genesis_validators_root*: Eth2Digest

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#checkpoint
  Checkpoint* = object
    epoch*: Epoch
    root*: Eth2Digest

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#AttestationData
  AttestationData* = object
    slot*: Slot

    index*: uint64

    # LMD GHOST vote
    beacon_block_root*: Eth2Digest

    # FFG vote
    source*: Checkpoint
    target*: Checkpoint

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#deposit
  Deposit* = object
    proof*: array[DEPOSIT_CONTRACT_TREE_DEPTH + 1, Eth2Digest] ##\
    ## Merkle path to deposit root

    data*: DepositData

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#depositmessage
  DepositMessage* = object
    pubkey*: ValidatorPubKey
    withdrawal_credentials*: Eth2Digest
    amount*: Gwei

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#depositdata
  DepositData* = object
    pubkey*: ValidatorPubKey
    withdrawal_credentials*: Eth2Digest
    amount*: Gwei
    # Cannot use TrustedSig here as invalid signatures are possible and determine
    # if the deposit should be added or not during processing
    signature*: ValidatorSig  # Signing over DepositMessage

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#voluntaryexit
  VoluntaryExit* = object
    epoch*: Epoch ##\
    ## Earliest epoch when voluntary exit can be processed

    validator_index*: uint64

  SomeAttestation* = Attestation | TrustedAttestation
  SomeIndexedAttestation* = IndexedAttestation | TrustedIndexedAttestation
  SomeProposerSlashing* = ProposerSlashing | TrustedProposerSlashing
  SomeAttesterSlashing* = AttesterSlashing | TrustedAttesterSlashing
  SomeSignedBeaconBlockHeader* = SignedBeaconBlockHeader | TrustedSignedBeaconBlockHeader
  SomeSignedVoluntaryExit* = SignedVoluntaryExit | TrustedSignedVoluntaryExit

  # Legacy database type, see BeaconChainDB
  ImmutableValidatorData* = object
    pubkey*: ValidatorPubKey
    withdrawal_credentials*: Eth2Digest

  # Non-spec type that represents the immutable part of a validator - an
  # uncompressed key serialization is used to speed up loading from database
  ImmutableValidatorDataDb2* = object
    pubkey*: UncompressedPubKey
    withdrawal_credentials*: Eth2Digest

  ImmutableValidatorData2* = object
    pubkey*: CookedPubKey
    withdrawal_credentials*: Eth2Digest

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#validator
  Validator* = object
    pubkey*: ValidatorPubKey

    withdrawal_credentials*: Eth2Digest ##\
    ## Commitment to pubkey for withdrawals and transfers

    effective_balance*: uint64 ##\
    ## Balance at stake

    slashed*: bool

    # Status epochs
    activation_eligibility_epoch*: Epoch ##\
    ## When criteria for activation were met

    activation_epoch*: Epoch
    exit_epoch*: Epoch

    withdrawable_epoch*: Epoch ##\
    ## When validator can withdraw or transfer funds

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#pendingattestation
  PendingAttestation* = object
    aggregation_bits*: CommitteeValidatorsBits
    data*: AttestationData

    inclusion_delay*: uint64

    proposer_index*: uint64

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#historicalbatch
  HistoricalBatch* = object
    block_roots* : array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest]
    state_roots* : array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest]

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#fork
  Fork* = object
    previous_version*: Version
    current_version*: Version

    epoch*: Epoch ##\
    ## Epoch of latest fork

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#eth1data
  Eth1Data* = object
    deposit_root*: Eth2Digest
    deposit_count*: uint64
    block_hash*: Eth2Digest

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#signedvoluntaryexit
  SignedVoluntaryExit* = object
    message*: VoluntaryExit
    signature*: ValidatorSig

  TrustedSignedVoluntaryExit* = object
    message*: VoluntaryExit
    signature*: TrustedSig

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#beaconblockheader
  BeaconBlockHeader* = object
    slot*: Slot
    proposer_index*: uint64
    parent_root*: Eth2Digest
    state_root*: Eth2Digest
    body_root*: Eth2Digest

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#signingdata
  SigningData* = object
    object_root*: Eth2Digest
    domain*: Eth2Domain

  GraffitiBytes* = distinct array[MAX_GRAFFITI_SIZE, byte]

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#signedbeaconblockheader
  SignedBeaconBlockHeader* = object
    message*: BeaconBlockHeader
    signature*: ValidatorSig

  TrustedSignedBeaconBlockHeader* = object
    message*: BeaconBlockHeader
    signature*: TrustedSig

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/validator.md#aggregateandproof
  AggregateAndProof* = object
    aggregator_index*: uint64
    aggregate*: Attestation
    selection_proof*: ValidatorSig

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/validator.md#signedaggregateandproof
  SignedAggregateAndProof* = object
    message*: AggregateAndProof
    signature*: ValidatorSig

  SyncCommitteeCache* = object
    current_sync_committee*: array[SYNC_COMMITTEE_SIZE, ValidatorIndex]
    next_sync_committee*: array[SYNC_COMMITTEE_SIZE, ValidatorIndex]

  # This doesn't know about forks or branches in the DAG. It's for straight,
  # linear chunks of the chain.
  StateCache* = object
    shuffled_active_validator_indices*:
      Table[Epoch, seq[ValidatorIndex]]
    beacon_proposer_indices*: Table[Slot, Option[ValidatorIndex]]
    sync_committees*: Table[SyncCommitteePeriod, SyncCommitteeCache]

  # This matches the mutable state of the Solidity deposit contract
  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/solidity_deposit_contract/deposit_contract.sol
  DepositContractState* = object
    branch*: array[DEPOSIT_CONTRACT_TREE_DEPTH, Eth2Digest]
    deposit_count*: array[32, byte] # Uint256

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#validator
  ValidatorStatus* = object
    # This is a validator without the expensive, immutable, append-only parts
    # serialized. They're represented in memory to allow in-place SSZ reading
    # and writing compatibly with the full Validator object.

    pubkey* {.dontserialize.}: ValidatorPubKey

    withdrawal_credentials* {.dontserialize.}: Eth2Digest ##\
    ## Commitment to pubkey for withdrawals and transfers

    effective_balance*: uint64 ##\
    ## Balance at stake

    slashed*: bool

    # Status epochs
    activation_eligibility_epoch*: Epoch ##\
    ## When criteria for activation were met

    activation_epoch*: Epoch
    exit_epoch*: Epoch

    withdrawable_epoch*: Epoch ##\
    ## When validator can withdraw or transfer funds

  # https://github.com/ethereum/consensus-specs/blob/v1.1.9/specs/phase0/p2p-interface.md#eth2-field
  ENRForkID* = object
    fork_digest*: ForkDigest
    next_fork_version*: Version
    next_fork_epoch*: Epoch

  BeaconBlockExits* = object
    # Collection of exits that are suitable for block production
    proposer_slashings*: List[ProposerSlashing, Limit MAX_PROPOSER_SLASHINGS]
    attester_slashings*: List[AttesterSlashing, Limit MAX_ATTESTER_SLASHINGS]
    voluntary_exits*: List[SignedVoluntaryExit, Limit MAX_VOLUNTARY_EXITS]

  AttnetBits* = BitArray[ATTESTATION_SUBNET_COUNT]

type
  # Caches for computing justificiation, rewards and penalties - based on
  # implementation in Lighthouse:
  # https://github.com/sigp/lighthouse/blob/master/consensus/state_processing/src/per_epoch_processing/validator_statuses.rs
  RewardDelta* = object
    rewards*: Gwei
    penalties*: Gwei

  InclusionInfo* = object
    # The distance between the attestation slot and the slot that attestation
    # was included in block.
    delay*: uint64
    # The index of the proposer at the slot where the attestation was included.
    proposer_index*: uint64

  RewardFlags* {.pure.} = enum
    isSlashed
    canWithdrawInCurrentEpoch
    isActiveInPreviousEpoch
    isCurrentEpochAttester

    # the validator's beacon block root attestation for the first slot
    # of the _current_ epoch matches the block root known to the state.
    isCurrentEpochTargetAttester

    # Set if the validator's beacon block root attestation for the first slot of
    # the _previous_ epoch matches the block root known to the state.
    # Information used to reward the block producer of this validators
    # earliest-included attestation.
    isPreviousEpochTargetAttester
    # True if the validator's beacon block root attestation in the _previous_
    # epoch at the attestation's slot (`attestation_data.slot`) matches the
    # block root known to the state.
    isPreviousEpochHeadAttester

  RewardStatus* = object
    ## Data detailing the status of a single validator with respect to the
    ## reward processing

    # The validator's effective balance in the _current_ epoch.
    current_epoch_effective_balance*: uint64

    # True if the validator had an attestation included in the _previous_ epoch.
    is_previous_epoch_attester*: Option[InclusionInfo]

    # Total rewards and penalties for this validator
    delta*: RewardDelta

    flags*: set[RewardFlags]

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#get_total_balance
  TotalBalances* = object
    # The total effective balance of all active validators during the _current_
    # epoch.
    current_epoch_raw*: Gwei
    # The total effective balance of all active validators during the _previous_
    # epoch.
    previous_epoch_raw*: Gwei
    # The total effective balance of all validators who attested during the
    # _current_ epoch.
    current_epoch_attesters_raw*: Gwei
    # The total effective balance of all validators who attested during the
    # _current_ epoch and agreed with the state about the beacon block at the
    # first slot of the _current_ epoch.
    current_epoch_target_attesters_raw*: Gwei
    # The total effective balance of all validators who attested during the
    # _previous_ epoch.
    previous_epoch_attesters_raw*: Gwei
    # The total effective balance of all validators who attested during the
    # _previous_ epoch and agreed with the state about the beacon block at the
    # first slot of the _previous_ epoch.
    previous_epoch_target_attesters_raw*: Gwei
    # The total effective balance of all validators who attested during the
    # _previous_ epoch and agreed with the state about the beacon block at the
    # time of attestation.
    previous_epoch_head_attesters_raw*: Gwei

const
  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/phase0/beacon-chain.md#domain-types
  DOMAIN_BEACON_PROPOSER* = DomainType([byte 0x00, 0x00, 0x00, 0x00])
  DOMAIN_BEACON_ATTESTER* = DomainType([byte 0x01, 0x00, 0x00, 0x00])
  DOMAIN_RANDAO* = DomainType([byte 0x02, 0x00, 0x00, 0x00])
  DOMAIN_DEPOSIT* = DomainType([byte 0x03, 0x00, 0x00, 0x00])
  DOMAIN_VOLUNTARY_EXIT* = DomainType([byte 0x04, 0x00, 0x00, 0x00])
  DOMAIN_SELECTION_PROOF* = DomainType([byte 0x05, 0x00, 0x00, 0x00])
  DOMAIN_AGGREGATE_AND_PROOF* = DomainType([byte 0x06, 0x00, 0x00, 0x00])

  # https://github.com/ethereum/consensus-specs/blob/v1.1.10/specs/altair/beacon-chain.md#domain-types
  DOMAIN_SYNC_COMMITTEE* = DomainType([byte 0x07, 0x00, 0x00, 0x00])
  DOMAIN_SYNC_COMMITTEE_SELECTION_PROOF* = DomainType([byte 0x08, 0x00, 0x00, 0x00])
  DOMAIN_CONTRIBUTION_AND_PROOF* = DomainType([byte 0x09, 0x00, 0x00, 0x00])

func getImmutableValidatorData*(validator: Validator): ImmutableValidatorData2 =
  let cookedKey = validator.pubkey.load() # Loading the pubkey is slow!
  doAssert cookedKey.isSome,
    "Cannot parse validator key: " & toHex(validator.pubkey)
  ImmutableValidatorData2(
    pubkey: cookedKey.get(),
    withdrawal_credentials: validator.withdrawal_credentials)

template makeLimitedU64*(T: untyped, limit: uint64) =
  # A "tigher" type is often used for T, but for the range check to be effective
  # it must make sense..

  static: doAssert limit <= distinctBase(T).high()
  # Many `uint64` values in the spec have a more limited range of valid values
  func init*(t: type T, value: uint64): Result[T, cstring] =
    if value < limit:
      ok(Result[T, cstring], T(value))
    else:
      err(Result[T, cstring], name(T) & " out of range")

  iterator items*(t: type T): T =
    for i in 0'u64..<limit:
      yield T(i)

  proc writeValue*(writer: var JsonWriter, value: T)
                  {.raises: [IOError, Defect].} =
    writeValue(writer, distinctBase value)

  proc readValue*(reader: var JsonReader, value: var T)
                {.raises: [IOError, SerializationError, Defect].} =
    let v = T.init(reader.readValue(uint64))
    if v.isSome():
      value = v.get()
    else:
      raiseUnexpectedValue(reader, $v.error())

  template `==`*(x, y: T): bool = distinctBase(x) == distinctBase(y)
  template `==`*(x: T, y: uint64): bool = distinctBase(x) == y
  template `==`*(x: uint64, y: T): bool = x == distinctBase(y)

  template `<`*(x, y: T): bool = distinctBase(x) < distinctBase(y)
  template `<`*(x: T, y: uint64): bool = distinctBase(x) < y
  template `<`*(x: uint64, y: T): bool = x < distinctBase(y)

  template hash*(x: T): Hash =
    hash distinctBase(x)

  template `$`*(x: T): string = $ distinctBase(x)

  template asInt*(x: T): int = int(distinctBase(x))
  template asUInt64*(x: T): uint64 = uint64(distinctBase(x))

  template toSszType(x: T): uint64 =
    {.error: "Limited types should not be used with SSZ (abi differences)".}

makeLimitedU64(CommitteeIndex, MAX_COMMITTEES_PER_SLOT)
makeLimitedU64(SubnetId, ATTESTATION_SUBNET_COUNT)

func init*(T: type CommitteeIndex, index, committees_per_slot: uint64):
    Result[CommitteeIndex, cstring] =
  if index < min(committees_per_slot, MAX_COMMITTEES_PER_SLOT):
    ok(CommitteeIndex(index))
  else:
    err("Committee index out of range for epoch")

proc writeValue*(writer: var JsonWriter, value: ValidatorIndex)
                {.raises: [IOError, Defect].} =
  writeValue(writer, distinctBase value)

proc readValue*(reader: var JsonReader, value: var ValidatorIndex)
               {.raises: [IOError, SerializationError, Defect].} =
  value = ValidatorIndex reader.readValue(distinctBase ValidatorIndex)

template writeValue*(
    writer: var JsonWriter, value: Version | ForkDigest | DomainType) =
  writeValue(writer, to0xHex(distinctBase(value)))

proc readValue*(
    reader: var JsonReader, value: var (Version | ForkDigest | DomainType))
               {.raises: [IOError, SerializationError, Defect].} =
  let hex = reader.readValue(string)
  try:
    hexToByteArray(hex, distinctBase(value))
  except ValueError:
    raiseUnexpectedValue(reader, "Hex string of 4 bytes expected")

func `$`*(x: JustificationBits): string =
  "0x" & toHex(uint8(x))

proc readValue*(reader: var JsonReader, value: var JustificationBits)
    {.raises: [IOError, SerializationError, Defect].} =
  let hex = reader.readValue(string)
  try:
    value = JustificationBits(hexToByteArray(hex, 1)[0])
  except ValueError:
    raiseUnexpectedValue(reader, "Hex string of 1 byte expected")

proc writeValue*(writer: var JsonWriter, value: JustificationBits)
    {.raises: [IOError, Defect].} =
  writer.writeValue $value

# In general, ValidatorIndex is assumed to be convertible to/from an int. This
# should be valid for a long time, because
# https://github.com/ethereum/annotated-spec/blob/master/phase0/beacon-chain.md#configuration
# notes that "The maximum supported validator count is 2**22 (=4,194,304), or
# ~134 million ETH staking. Assuming 32 slots per epoch and 64 committees per
# slot, this gets us to a max 2048 validators in a committee."
#
# That's only active validators, so in principle, it can grow larger, but it
# should be orders of magnitude more validators than expected in the next in
# the next couple of years, than int32 indexing supports.
static: doAssert high(int) >= high(int32)

# `ValidatorIndex` seq handling.
template `[]=`*[T](a: var seq[T], b: ValidatorIndex, c: T) =
  a[b.int] = c

template `[]`*[T](a: seq[T], b: ValidatorIndex): auto = # Also var seq (!)
  a[b.int]

# `ValidatorIndex` Nim integration
template `==`*(x, y: ValidatorIndex) : bool =
  distinctBase(x) == distinctBase(y)

template `<`*(x, y: ValidatorIndex): bool =
  distinctBase(x) < distinctBase(y)

template hash*(x: ValidatorIndex): Hash =
  hash distinctBase(x)

template `$`*(x: ValidatorIndex): string =
  $ distinctBase(x)

template `==`*(x: uint64, y: ValidatorIndex): bool =
  x == uint64(y)

template `==`*(x: ValidatorIndex, y: uint64): bool =
  uint64(x) == y

template `==`*(x, y: JustificationBits): bool =
  distinctBase(x) == distinctBase(y)

func `as`*(d: DepositData, T: type DepositMessage): T =
  T(pubkey: d.pubkey,
    withdrawal_credentials: d.withdrawal_credentials,
    amount: d.amount)

template newClone*[T: not ref](x: T): ref T =
  # TODO not nil in return type: https://github.com/nim-lang/Nim/issues/14146
  # TODO use only when x is a function call that returns a new instance!
  let res = new typeof(x) # TODO safe to do noinit here?
  res[] = x
  res

template assignClone*[T: not ref](x: T): ref T =
  # This is a bit of a mess: if x is an rvalue (temporary), RVO kicks in for
  # newClone - if it's not, `genericAssign` will be called which is ridiculously
  # slow - so `assignClone` should be used when RVO doesn't work. sigh.
  mixin assign
  let res = new typeof(x) # TODO safe to do noinit here?
  assign(res[], x)
  res

# TODO Careful, not nil analysis is broken / incomplete and the semantics will
#      likely change in future versions of the language:
#      https://github.com/nim-lang/RFCs/issues/250
template newClone*[T](x: ref T not nil): ref T =
  newClone(x[])

template lenu64*(x: untyped): untyped =
  uint64(len(x))

func `$`*(v: ForkDigest | Version | DomainType): string =
  toHex(distinctBase(v))

func toGaugeValue*(x: uint64 | Epoch | Slot): int64 =
  if x > uint64(int64.high):
    int64.high
  else:
    int64(x)

# TODO where's borrow support when you need it
func `==`*(a, b: ForkDigest | Version | DomainType): bool =
  array[4, byte](a) == array[4, byte](b)
func `<`*(a, b: ForkDigest | Version): bool =
  uint32.fromBytesBE(array[4, byte](a)) < uint32.fromBytesBE(array[4, byte](b))
func len*(v: ForkDigest | Version | DomainType): int = sizeof(v)
func low*(v: ForkDigest | Version): int = 0
func high*(v: ForkDigest | Version): int = len(v) - 1
func `[]`*(v: ForkDigest | Version | DomainType, idx: int): byte =
  array[4, byte](v)[idx]

template data*(v: ForkDigest | Version | DomainType): array[4, byte] =
  distinctBase(v)

func shortLog*(v: BeaconBlockHeader): auto =
  (
    slot: shortLog(v.slot),
    proposer_index: v.proposer_index,
    parent_root: shortLog(v.parent_root),
    state_root: shortLog(v.state_root)
  )

func shortLog*(v: SomeSignedBeaconBlockHeader): auto =
  (
    message: shortLog(v.message),
    signature: shortLog(v.signature)
  )

func shortLog*(v: DepositData): auto =
  (
    pubkey: shortLog(v.pubkey),
    withdrawal_credentials: shortLog(v.withdrawal_credentials),
    amount: v.amount,
    signature: shortLog(v.signature)
  )

func shortLog*(v: Checkpoint): auto =
  # epoch:root when logging epoch, root:slot when logging slot!
  $shortLog(v.epoch) & ":" & shortLog(v.root)

func shortLog*(v: AttestationData): auto =
  (
    slot: shortLog(v.slot),
    index: v.index,
    beacon_block_root: shortLog(v.beacon_block_root),
    source: shortLog(v.source),
    target: shortLog(v.target),
  )

func shortLog*(v: PendingAttestation): auto =
  (
    aggregation_bits: v.aggregation_bits,
    data: shortLog(v.data),
    inclusion_delay: v.inclusion_delay,
    proposer_index: v.proposer_index
  )

func shortLog*(v: SomeAttestation): auto =
  (
    aggregation_bits: v.aggregation_bits,
    data: shortLog(v.data),
    signature: shortLog(v.signature)
  )

func shortLog*(v: SomeIndexedAttestation): auto =
  (
    attestating_indices: v.attesting_indices,
    data: shortLog(v.data),
    signature: shortLog(v.signature)
  )

func shortLog*(v: SomeAttesterSlashing): auto =
  (
    attestation_1: shortLog(v.attestation_1),
    attestation_2: shortLog(v.attestation_2),
  )

func shortLog*(v: SomeProposerSlashing): auto =
  (
    signed_header_1: shortLog(v.signed_header_1),
    signed_header_2: shortLog(v.signed_header_2)
  )

func shortLog*(v: VoluntaryExit): auto =
  (
    epoch: shortLog(v.epoch),
    validator_index: v.validator_index
  )

func shortLog*(v: SomeSignedVoluntaryExit): auto =
  (
    message: shortLog(v.message),
    signature: shortLog(v.signature)
  )

chronicles.formatIt AttestationData: it.shortLog
chronicles.formatIt Attestation: it.shortLog
chronicles.formatIt Checkpoint: it.shortLog

const
  # http://facweb.cs.depaul.edu/sjost/it212/documents/ascii-pr.htm
  PrintableAsciiChars = {' '..'~'}

func toPrettyString*(bytes: openArray[byte]): string =
  result = strip(string.fromBytes(bytes),
                 leading = false,
                 chars = Whitespace + {'\0'})

  # TODO: Perhaps handle UTF-8 at some point
  if not allCharsInSet(result, PrintableAsciiChars):
    result = "0x" & toHex(bytes)

func `$`*(value: GraffitiBytes): string = toPrettyString(distinctBase value)

func init*(T: type GraffitiBytes, input: string): GraffitiBytes
          {.raises: [ValueError, Defect].} =
  if input.len > 2 and input[0] == '0' and input[1] == 'x':
    if input.len > sizeof(GraffitiBytes) * 2 + 2:
      raise newException(ValueError, "The graffiti bytes should be less than 32")
    elif input.len mod 2 != 0:
      raise newException(ValueError, "The graffiti hex string should have an even length")

    hexToByteArray(input, distinctBase(result))
  else:
    if input.len > MAX_GRAFFITI_SIZE:
      raise newException(ValueError, "The graffiti value should be 32 characters or less")
    distinctBase(result)[0 ..< input.len] = toBytes(input)

func defaultGraffitiBytes*(): GraffitiBytes =
  const graffitiBytes =
    toBytes("Nimbus/" & fullVersionStr)
  static: doAssert graffitiBytes.len <= MAX_GRAFFITI_SIZE
  distinctBase(result)[0 ..< graffitiBytes.len] = graffitiBytes

proc writeValue*(w: var JsonWriter, value: GraffitiBytes)
                {.raises: [IOError, Defect].} =
  w.writeValue $value

template `==`*(lhs, rhs: GraffitiBytes): bool =
  distinctBase(lhs) == distinctBase(rhs)

proc readValue*(r: var JsonReader, T: type GraffitiBytes): T
               {.raises: [IOError, SerializationError, Defect].} =
  try:
    init(GraffitiBytes, r.readValue(string))
  except ValueError as err:
    r.raiseUnexpectedValue err.msg

func load*(
    validators: openArray[ImmutableValidatorData2],
    index: ValidatorIndex | uint64): Option[CookedPubKey] =
  if validators.lenu64() <= index.uint64:
    none(CookedPubKey)
  else:
    some(validators[index.int].pubkey)

template hash*(header: BeaconBlockHeader): Hash =
  hash(header.state_root)

static:
  # Sanity checks - these types should be trivial enough to copy with memcpy
  doAssert supportsCopyMem(Validator)
  doAssert supportsCopyMem(Eth2Digest)
  doAssert ATTESTATION_SUBNET_COUNT <= high(distinctBase SubnetId).int

func getSizeofSig(x: auto, n: int = 0): seq[(string, int, int)] =
  for name, value in x.fieldPairs:
    when value is tuple|object:
      result.add getSizeofSig(value, n + 1)
    # TrustedSig and ValidatorSig differ in that they have otherwise identical
    # fields where one is "blob" and the other is "data". They're structurally
    # isomorphic, regardless. Grandfather that exception in, but in general it
    # is still better to keep field names parallel.
    result.add((name.replace("blob", "data"), sizeof(value), n))

## At the GC-level, the GC is type-agnostic; it's all type-erased so
## casting between seq[Attestation] and seq[TrustedAttestation] will
## not disrupt GC operations.
##
## These SHOULD be used in function calls to avoid expensive temporary.
## see https://github.com/status-im/nimbus-eth2/pull/2250#discussion_r562010679
template isomorphicCast*[T, U](x: U): T =
  # Each of these pairs of types has ABI-compatible memory representations.
  static:
    doAssert sizeof(T) == sizeof(U)
    doAssert getSizeofSig(T()) == getSizeofSig(U())
  cast[ptr T](unsafeAddr x)[]

func clear*(cache: var StateCache) =
  cache.shuffled_active_validator_indices.clear
  cache.beacon_proposer_indices.clear
  cache.sync_committees.clear
