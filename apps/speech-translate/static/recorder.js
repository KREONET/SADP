import { PcmEncoder } from './pcm.mjs';

class Recorder extends AudioWorkletProcessor {
  constructor() {
    super();
    this.running = true;
    this.encoder = new PcmEncoder(sampleRate, (buffer) => {
      this.port.postMessage({ type: 'pcm', buffer }, [buffer]);
    });
    this.port.onmessage = ({ data }) => {
      if (data.type === 'flush') {
        this.running = false;
        this.encoder.flush();
        this.port.postMessage({ type: 'flushed' });
      }
    };
  }

  process(inputs) {
    const input = inputs[0]?.[0];
    if (this.running && input) this.encoder.push(input);
    return true;
  }
}

registerProcessor('pcm-recorder', Recorder);
