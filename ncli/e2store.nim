{.push raises: [Defect].}

import
  std/strformat,
  stew/[arrayops, endians2, io2, results],
  snappy, snappy/framing,
  ../beacon_chain/spec/forks,
  ../beacon_chain/spec/eth2_ssz_serialization

const
  E2Version* = [byte 0x65, 0x32]
  E2Index* = [byte 0x69, 0x32]

  SnappyBeaconBlock* = [byte 0x01, 0x00]
  SnappyBeaconState* = [byte 0x02, 0x00]

  TypeFieldLen = 2
  LengthFieldLen = 6
  HeaderFieldLen = TypeFieldLen + LengthFieldLen

type
  Type* = array[2, byte]

  Header* = object
    typ*: Type
    len*: int

  EraFile* = object
    handle: IoHandle
    start: Slot

  Index* = object
    startSlot*: Slot
    offsets*: seq[int64] # Absolute positions in file

proc toString(v: IoErrorCode): string =
  try: ioErrorMsg(v)
  except Exception as e: raiseAssert e.msg

func eraFileName*(cfg: RuntimeConfig, state: ForkyBeaconState, era: uint64): string =
  try:
    let
      historicalRoot =
        if era == 0: state.genesis_validators_root
        elif era > state.historical_roots.lenu64(): Eth2Digest()
        else: state.historical_roots.asSeq()[era - 1]

    &"{cfg.name()}-{era.int:05}-{1:05}-{shortLog(historicalRoot)}.era"
  except ValueError as exc:
    raiseAssert exc.msg

proc append(f: IoHandle, data: openArray[byte]): Result[void, string] =
  if (? writeFile(f, data).mapErr(toString)) != data.len.uint:
    return err("could not write data")
  ok()

proc appendHeader(f: IoHandle, typ: Type, dataLen: int): Result[int64, string] =
  let start = ? getFilePos(f).mapErr(toString)

  ? append(f, typ)
  ? append(f, toBytesLE(dataLen.uint64).toOpenArray(0, 5))

  ok(start)

proc appendRecord*(f: IoHandle, typ: Type, data: openArray[byte]): Result[int64, string] =
  let start = ? appendHeader(f, typ, data.len())
  ? append(f, data)
  ok(start)

proc toCompressedBytes(item: auto): seq[byte] =
  try:
    framingFormatCompress(SSZ.encode(item))
  except CatchableError as exc:
    raiseAssert exc.msg # shouldn't happen

proc appendRecord*(f: IoHandle, v: ForkyTrustedSignedBeaconBlock): Result[int64, string] =
  f.appendRecord(SnappyBeaconBlock, toCompressedBytes(v))

proc appendRecord*(f: IoHandle, v: ForkyBeaconState): Result[int64, string] =
  f.appendRecord(SnappyBeaconState, toCompressedBytes(v))

proc appendIndex*(f: IoHandle, startSlot: Slot, offsets: openArray[int64]): Result[int64, string] =
  let
    len = offsets.len() * sizeof(int64) + 16
    pos = ? f.appendHeader(E2Index, len)

  ? f.append(startSlot.uint64.toBytesLE())

  for v in offsets:
    ? f.append(cast[uint64](v - pos).toBytesLE())

  ? f.append(offsets.lenu64().toBytesLE())

  ok(pos)

proc appendRecord(f: IoHandle, index: Index): Result[int64, string] =
  f.appendIndex(index.startSlot, index.offsets)

proc checkBytesLeft(f: IoHandle, expected: int64): Result[void, string] =
  let size = ? getFileSize(f).mapErr(toString)
  if expected > size:
    return err("Record extends past end of file")

  let pos = ? getFilePos(f).mapErr(toString)
  if expected > size - pos:
    return err("Record extends past end of file")

  ok()

proc readFileExact(f: IoHandle, buf: var openArray[byte]): Result[void, string] =
  if (? f.readFile(buf).mapErr(toString)) != buf.len().uint:
    return err("missing data")
  ok()

proc readHeader(f: IoHandle): Result[Header, string] =
  var buf: array[10, byte]
  ? readFileExact(f, buf.toOpenArray(0, 7))

  var
    typ: Type
  discard typ.copyFrom(buf)

  # Cast safe because we had only 6 bytes of length data
  let
    len = cast[int64](uint64.fromBytesLE(buf.toOpenArray(2, 9)))

  # No point reading these..
  if len > int.high(): return err("header length exceeds int.high")

  # Must have at least that much data, or header is invalid
  ? f.checkBytesLeft(len)

  ok(Header(typ: typ, len: int(len)))

proc readRecord*(f: IoHandle, data: var seq[byte]): Result[Header, string] =
  let header = ? readHeader(f)
  if header.len > 0:
    ? f.checkBytesLeft(header.len)

    data.setLen(header.len)

    ? readFileExact(f, data)

  ok(header)

proc readIndexCount*(f: IoHandle): Result[int, string] =
  var bytes: array[8, byte]
  ? f.readFileExact(bytes)

  let count = uint64.fromBytesLE(bytes)
  if count > (int.high() div 8) - 3: return err("count: too large")

  let size = uint64(? f.getFileSize().mapErr(toString))
  # Need to have at least this much data in the file to read an index with
  # this count
  if count > (size div 8 + 3): return err("count: too large")

  ok(int(count)) # Sizes checked against int above

proc findIndexStartOffset*(f: IoHandle): Result[int64, string] =
  ? f.setFilePos(-8, SeekPosition.SeekCurrent).mapErr(toString)

  let
    count = ? f.readIndexCount() # Now we're back at the end of the index
    bytes = count.int64 * 8 + 24

  ok(-bytes)

proc readIndex*(f: IoHandle): Result[Index, string] =
  let
    startPos = ? f.getFilePos().mapErr(toString)
    fileSize = ? f.getFileSize().mapErr(toString)
    header = ? f.readHeader()

  if header.typ != E2Index: return err("not an index")
  if header.len < 16: return err("index entry too small")
  if header.len mod 8 != 0: return err("index length invalid")

  var buf: array[8, byte]
  ? f.readFileExact(buf)
  let
    slot = uint64.fromBytesLE(buf)
    count = header.len div 8 - 2

  var offsets = newSeqUninitialized[int64](count)
  for i in 0..<count:
    ? f.readFileExact(buf)

    let offset = uint64.fromBytesLE(buf)

    # Wrapping math is actually convenient here
    let absolute = cast[int64](cast[uint64](startPos) + offset)

    if absolute < 0 or absolute > fileSize: return err("Invalid offset")
    offsets[i] = absolute

  ? f.readFileExact(buf)
  if uint64(count) != uint64.fromBytesLE(buf): return err("invalid count")

  # technically not an error, but we'll throw this sanity check in here..
  if slot > int32.high().uint64: return err("fishy slot")

  ok(Index(startSlot: Slot(slot), offsets: offsets))

type
  EraGroup* = object
    eraStart: int64
    slotIndex*: Index

proc init*(T: type EraGroup, f: IoHandle, startSlot: Option[Slot]): Result[T, string] =
  let eraStart = ? f.appendHeader(E2Version, 0)

  ok(EraGroup(
    eraStart: eraStart,
    slotIndex: Index(
      startSlot: startSlot.get(Slot(0)),
      offsets: newSeq[int64](
        if startSlot.isSome(): SLOTS_PER_HISTORICAL_ROOT.int
        else: 0
  ))))

proc update*(g: var EraGroup, f: IoHandle, slot: Slot, sszBytes: openArray[byte]): Result[void, string] =
  doAssert slot >= g.slotIndex.startSlot
  g.slotIndex.offsets[int(slot - g.slotIndex.startSlot)] =
    try:
      ? f.appendRecord(SnappyBeaconBlock, framingFormatCompress(sszBytes))
    except CatchableError as e: raiseAssert e.msg # TODO fix snappy

  ok()

proc finish*(g: var EraGroup, f: IoHandle, state: ForkyBeaconState): Result[void, string] =
  let
    statePos = ? f.appendRecord(state)

  if state.slot > Slot(0):
    discard ? f.appendRecord(g.slotIndex)

  discard ? f.appendIndex(state.slot, [statePos])

  ok()
