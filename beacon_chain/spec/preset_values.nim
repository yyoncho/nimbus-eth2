type
  PresetValue* {.pure.} = enum
    BASE_REWARD_FACTOR
    BLS_WITHDRAWAL_PREFIX
    CHURN_LIMIT_QUOTIENT
    DEPOSIT_CHAIN_ID
    DEPOSIT_CONTRACT_ADDRESS
    DEPOSIT_NETWORK_ID
    DOMAIN_AGGREGATE_AND_PROOF
    DOMAIN_BEACON_ATTESTER
    DOMAIN_BEACON_PROPOSER
    DOMAIN_DEPOSIT
    DOMAIN_RANDAO
    DOMAIN_SELECTION_PROOF
    DOMAIN_VOLUNTARY_EXIT
    EFFECTIVE_BALANCE_INCREMENT
    EJECTION_BALANCE
    EPOCHS_PER_ETH1_VOTING_PERIOD
    EPOCHS_PER_HISTORICAL_VECTOR
    EPOCHS_PER_RANDOM_SUBNET_SUBSCRIPTION
    EPOCHS_PER_SLASHINGS_VECTOR
    ETH1_FOLLOW_DISTANCE
    GENESIS_FORK_VERSION
    GENESIS_DELAY
    HISTORICAL_ROOTS_LIMIT
    HYSTERESIS_DOWNWARD_MULTIPLIER
    HYSTERESIS_QUOTIENT
    HYSTERESIS_UPWARD_MULTIPLIER
    INACTIVITY_PENALTY_QUOTIENT
    MAX_ATTESTATIONS
    MAX_ATTESTER_SLASHINGS
    MAX_COMMITTEES_PER_SLOT
    MAX_DEPOSITS
    MAX_EFFECTIVE_BALANCE
    MAX_EPOCHS_PER_CROSSLINK
    MAX_PROPOSER_SLASHINGS
    MAX_SEED_LOOKAHEAD
    MAX_VALIDATORS_PER_COMMITTEE
    MAX_VOLUNTARY_EXITS
    MIN_ATTESTATION_INCLUSION_DELAY
    MIN_DEPOSIT_AMOUNT
    MIN_EPOCHS_TO_INACTIVITY_PENALTY
    MIN_GENESIS_ACTIVE_VALIDATOR_COUNT
    MIN_GENESIS_TIME
    MIN_PER_EPOCH_CHURN_LIMIT
    MIN_SEED_LOOKAHEAD
    MIN_SLASHING_PENALTY_QUOTIENT
    MIN_VALIDATOR_WITHDRAWABILITY_DELAY
    PROPOSER_REWARD_QUOTIENT
    RANDOM_SUBNETS_PER_VALIDATOR
    SAFE_SLOTS_TO_UPDATE_JUSTIFIED
    SECONDS_PER_ETH1_BLOCK
    SECONDS_PER_SLOT
    SHARD_COMMITTEE_PERIOD
    SHUFFLE_ROUND_COUNT
    SLOTS_PER_EPOCH
    SLOTS_PER_HISTORICAL_ROOT
    TARGET_AGGREGATORS_PER_COMMITTEE
    TARGET_COMMITTEE_SIZE
    VALIDATOR_REGISTRY_LIMIT
    WHISTLEBLOWER_REWARD_QUOTIENT

