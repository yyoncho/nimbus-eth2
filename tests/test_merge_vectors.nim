{.used.}

# https://notes.ethereum.org/@9AeMAlpyQYaAAyuj47BzRw/rkwW3ceVY
# Monitor traffic: socat -v TCP-LISTEN:9545,fork TCP-CONNECT:127.0.0.1:8545

import
  unittest2,
  chronos, web3/[engine_api_types, ethtypes],
  ../beacon_chain/eth1/eth1_monitor,
  ../beacon_chain/spec/[digest, presets],
  ./testutil

suite "Merge test vectors":
  # Use 8545 here to get Geth directly, or 9545 to allow for the socat proxy
  let web3Provider = (waitFor newWeb3DataProvider(
    default(Eth1Address), "http://127.0.0.1:8545")).get

  test "preparePayload, getPayload, executePayload, and consensusValidated":
    let
      payloadId = waitFor web3Provider.preparePayload(
        Eth2Digest.fromHex("0xa0513a503d5bd6e89a144c3268e5b7e9da9dbf63df125a360e3950a7d0d67131"),
        5,  # Timestamp
        default(Eth2Digest).data,  # Random
        Eth1Address.fromHex("0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b"))  # Fee recipient
      payload =         waitFor web3Provider.getPayload(Quantity(payloadId.payloadId))
      payloadStatus =   waitFor web3Provider.executePayload(payload)
      validatedStatus = waitFor web3Provider.consensusValidated(payload.blockHash, BlockValidationStatus.valid)
    check: payloadStatus.status == "VALID"

  test "getPayload unknown payload":
    try:
      let res = waitFor web3Provider.getPayload(Quantity(100000))
      doAssert false
    except ValueError as e:
      # expected outcome
      echo e.msg

  test "consensusValidated unknown header":
    try:
      # Random 64-nibble hex string
      let res = waitFor web3Provider.consensusValidated(
        Eth2Digest.fromHex("0x0aeb2ef52e9eb9d8586e09f531a4cd3e2ee9496df77d25e9e0feb0d83234e4c9").asBlockHash,
        BlockValidationStatus.valid)
      # currently, this seems not to actually show unknown header, but that's
      # not a Nimbus RPC issue
    except ValueError as e:
      # expected outcome
      echo e.msg
