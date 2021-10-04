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
    default(Eth1Address), "http://127.0.0.1:8550")).get

  test "preparePayload, getPayload, executePayload, and consensusValidated":
    let
      payloadId = waitFor web3Provider.preparePayload(
        Eth2Digest.fromHex("0x3b8fb240d288781d4aac94d3fd16809ee413bc99294a085798a589dae51ddd4a"),
        5,  # Timestamp
        default(Eth2Digest).data,  # Random
        Eth1Address.fromHex("0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b"))  # Fee recipient
      payload =         waitFor web3Provider.getPayload(Quantity(payloadId.payloadId))
      payloadStatus =   waitFor web3Provider.executePayload(payload)
      validatedStatus = waitFor web3Provider.consensusValidated(payload.blockHash, BlockValidationStatus.valid)

      payloadId2 = waitFor web3Provider.preparePayload(
        Eth2Digest.fromHex("0xa217633b3c24112fe9b044b06b94a93d393a3ffd9e8765fecdb34063763d5135"),
        5,  # Timestamp
        default(Eth2Digest).data,  # Random
        Eth1Address.fromHex("0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b"))  # Fee recipient
      payload2 =         waitFor web3Provider.getPayload(Quantity(payloadId.payloadId))
      payloadStatus2 =   waitFor web3Provider.executePayload(payload)
      validatedStatus2 = waitFor web3Provider.consensusValidated(payload.blockHash, BlockValidationStatus.valid)

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
