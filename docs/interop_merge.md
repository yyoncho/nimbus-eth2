Nimbus passes phase 0, Altair, and Merge consensus spec tests in minimal and mainnet presets.

# How to run Catalyst

- Clone Geth: `git clone --branch merge-interop-spec https://github.com/MariusVanDerWijden/go-ethereum.git ~/execution-clients/go-ethereum`
- Build Geth and Catalyst with `make geth`
- Run `scripts/run-catalyst.sh` to run Catalyst. It listens on port 8545.

# Verify Catalyst is working

- Clone Nimbus and check out the `amphora-merge-interop` branch
- Run `scripts/run-catalyst.sh`. This depends on the paths set up in the first section. If those are changed, adjust accordingly.
- While the Geth console is running, run `scripts/check_merge_test_vectors.sh`.

The results should be similar to
```
engine_preparePayload response: {"jsonrpc":"2.0","id":67,"result":"0x0"}
engine_getPayload response: {"jsonrpc":"2.0","id":67,"result":{"blockHash":"0x7a694c5e6e372e6f865b073c101c2fba01f899f16480eb13f7e333a3b7e015bc","parentHash":"0xa0513a503d5bd6e89a144c3268e5b7e9da9dbf63df125a360e3950a7d0d67131","coinbase":"0x0000000000000000000000000000000000000000","stateRoot":"0xca3149fa9e37db08d1cd49c9061db1002ef1cd58db2210f2115c8c989b2bdf45","receiptRoot":"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421","logsBloom":"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000","random":"0x0000000000000000000000000000000000000000000000000000000000000000","blockNumber":"0x1","gasLimit":"0x989680","gasUsed":"0x0","timestamp":"0x5","extraData":"0x","baseFeePerGas":"0x0","transactions":[]}}
Execution test vectors for Merge passed
```

- If issues present themselves here, or when Nimbus attempts to use the API, one can `debug.verbosity(4)` console command in Catalyst.

# Verify that Nimbus runs through the same examples

- Run `./env.sh nim c -r tests/test_merge_vectors.nim`
