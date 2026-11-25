// A tone generator: proves AudioWorklet runs (counts what it renders).
class Tone extends AudioWorkletProcessor {
  constructor() { super(); this.frames = 0; this.port.onmessage = () => this.port.postMessage(this.frames); }
  process(_, outputs) { const out = outputs[0][0]; for (let i = 0; i < out.length; i++) out[i] = Math.sin(this.frames++ / 20) * 0.1; return true; }
}
registerProcessor('tone', Tone);
