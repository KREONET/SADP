import assert from 'node:assert/strict';
import test from 'node:test';
import { PcmEncoder } from '../static/pcm.mjs';

function encode(rate, input, split = input.length) {
  const packets = [];
  const encoder = new PcmEncoder(rate, (buffer) => packets.push(Buffer.from(buffer)));
  for (let offset = 0; offset < input.length; offset += split) encoder.push(input.subarray(offset, offset + split));
  encoder.flush();
  return packets;
}

for (const rate of [16000, 44100, 48000]) {
  test(`${rate} Hz produces one second of PCM16 in 20 ms packets`, () => {
    const packets = encode(rate, new Float32Array(rate).fill(0.5), 128);
    assert.equal(packets.length, 50);
    assert.equal(Buffer.concat(packets).length, 32000);
    assert.ok(packets.every((packet) => packet.length === 640));
    assert.equal(packets[0].readInt16LE(), 16384);
  });
  test(`${rate} Hz packet boundaries preserve waveform`, () => {
    const input = Float32Array.from({ length: rate }, (_, i) => Math.sin(i * 0.17));
    assert.deepEqual(Buffer.concat(encode(rate, input, 128)), Buffer.concat(encode(rate, input)));
  });
}

test('clipping and little endian encoding', () => {
  const packet = Buffer.concat(encode(16000, new Float32Array([-2, 0, 2])));
  assert.deepEqual([...packet], [0, 128, 0, 0, 255, 127]);
});

test('flush preserves the last partial packet without duplicates', () => {
  const packets = [];
  const encoder = new PcmEncoder(48000, (buffer) => packets.push(buffer));
  encoder.push(new Float32Array(1000));
  encoder.flush();
  encoder.flush();
  assert.deepEqual(packets.map((packet) => packet.byteLength), [640, 28]);
});
