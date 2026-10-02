export class PcmEncoder {
  constructor(inputRate, emit, packetSamples = 320) {
    if (inputRate < 16000) throw new Error('A sample rate of at least 16 kHz is required.');
    this.ratio = inputRate / 16000;
    this.emit = emit;
    this.packetSamples = packetSamples;
    this.weight = 0;
    this.sum = 0;
    this.samples = [];
  }

  push(input) {
    for (const value of input) {
      let remaining = 1;
      while (remaining > 1e-9) {
        const used = Math.min(remaining, this.ratio - this.weight);
        this.sum += value * used;
        this.weight += used;
        remaining -= used;
        if (this.weight >= this.ratio - 1e-9) {
          const sample = Math.max(-1, Math.min(1, this.sum / this.ratio));
          this.samples.push(Math.round(sample * (sample < 0 ? 32768 : 32767)));
          this.sum = this.weight = 0;
          if (this.samples.length === this.packetSamples) this.flushPacket();
        }
      }
    }
  }

  flushPacket() {
    if (!this.samples.length) return;
    const buffer = new ArrayBuffer(this.samples.length * 2);
    const view = new DataView(buffer);
    this.samples.forEach((value, index) => view.setInt16(index * 2, value, true));
    this.samples = [];
    this.emit(buffer);
  }

  flush() {
    // 리샘플러에 남은 1샘플 미만의 입력도 종료 시점에 반영한다.
    if (this.weight > 1e-9) {
      const sample = Math.max(-1, Math.min(1, this.sum / this.weight));
      this.samples.push(Math.round(sample * (sample < 0 ? 32768 : 32767)));
      this.sum = this.weight = 0;
    }
    this.flushPacket();
  }
}
