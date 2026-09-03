// audio-levels.js
//
// The live waveform's source. Captures Windows' system loopback audio through
// Chromium's getDisplayMedia (the main process answers the request with the
// primary screen plus `audio: 'loopback'`; the video track is dropped at
// once), runs Web Audio's FFT over it, and reduces the spectrum to six
// log-spaced bands with the same shaping as SystemAudioLevels.swift: a slowly
// adapting reference level so quiet and loud tracks both fill the meter, a
// treble tilt, fast attack / slow release, and a silence gate that rests the
// bars as dots.
//
// The honest difference from the Mac app: this is system-wide loopback, not a
// tap on Spotify's process alone — Chromium has no process-scoped capture.
// The capture only runs while Spotify is playing, which keeps it mostly true.

const BAND_COUNT = 6;
const FFT_SIZE = 2048;
const TOP_FREQUENCY = 10_000;
const REFERENCE_START = -45;
const REFERENCE_FLOOR = -84;
const REFERENCE_ATTACK = 0.006;   // per 30Hz frame
const REFERENCE_RELEASE = 0.0025;
const RANGE_DB = 42;
const TILT_PER_BAND = 2;
const SILENCE_RMS = 1e-4;
const ATTACK = 0.55;
const RELEASE = 0.18;

export class AudioLevels {
  constructor() {
    this.levels = new Array(BAND_COUNT).fill(0);
    this.active = false;
    this.failureReason = null;
    this.stream = null;
    this.context = null;
    this.analyser = null;
    this.spectrum = null;
    this.timeDomain = null;
    this.bandRanges = [];
    this.reference = REFERENCE_START;
    this.timer = null;
    this.starting = null;
  }

  /** Whether real levels are available (capture running and something heard). */
  get isLive() { return this.active && this.stream != null; }

  async start() {
    if (this.active || this.starting) return;
    this.active = true;
    this.starting = this.open().finally(() => { this.starting = null; });
    await this.starting;
  }

  async open() {
    try {
      // Video is requested because Chromium requires it for a display
      // capture; the track is stopped immediately so nothing is recorded.
      const stream = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: true });
      if (!this.active) { stream.getTracks().forEach((t) => t.stop()); return; }
      stream.getVideoTracks().forEach((t) => t.stop());
      if (!stream.getAudioTracks().length) throw new Error('No loopback audio track');
      this.stream = stream;
      this.context = new AudioContext({ sampleRate: 48_000 });
      const source = this.context.createMediaStreamSource(stream);
      this.analyser = this.context.createAnalyser();
      this.analyser.fftSize = FFT_SIZE;
      this.analyser.smoothingTimeConstant = 0;
      source.connect(this.analyser);
      this.spectrum = new Float32Array(this.analyser.frequencyBinCount);
      this.timeDomain = new Float32Array(FFT_SIZE);
      this.bandRanges = AudioLevels.bandRanges(this.context.sampleRate);
      this.failureReason = null;
      this.timer = setInterval(() => this.tick(), 1000 / 30);
      console.info('[audio] loopback capture running');
    } catch (error) {
      this.failureReason = error && error.message ? error.message : String(error);
      this.active = false;
      console.warn('[audio] loopback capture unavailable:', this.failureReason);
    }
  }

  stop() {
    this.active = false;
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    if (this.stream) this.stream.getTracks().forEach((t) => t.stop());
    this.stream = null;
    if (this.context) this.context.close().catch(() => {});
    this.context = null;
    this.analyser = null;
    this.levels = new Array(BAND_COUNT).fill(0);
    this.reference = REFERENCE_START;
  }

  /** Log-spaced bin ranges from bin 1 (skip DC) up to TOP_FREQUENCY. */
  static bandRanges(sampleRate) {
    const half = FFT_SIZE / 2;
    const binWidth = sampleRate / FFT_SIZE;
    const minBin = 1;
    const maxBin = Math.min(half - 1, Math.max(minBin + 1, Math.floor(TOP_FREQUENCY / binWidth)));
    return Array.from({ length: BAND_COUNT }, (_, band) => {
      const low = Math.floor(minBin * (maxBin / minBin) ** (band / BAND_COUNT));
      const high = Math.max(low + 1, Math.floor(minBin * (maxBin / minBin) ** ((band + 1) / BAND_COUNT)));
      return [low, high];
    });
  }

  tick() {
    const { analyser } = this;
    if (!analyser) return;
    analyser.getFloatTimeDomainData(this.timeDomain);
    let sum = 0;
    for (let i = 0; i < this.timeDomain.length; i++) sum += this.timeDomain[i] * this.timeDomain[i];
    const rms = Math.sqrt(sum / this.timeDomain.length);

    // True silence: release to dots and freeze the reference, so the first
    // frame of the next track can't slam every bar to full.
    if (rms < SILENCE_RMS) {
      for (let i = 0; i < BAND_COUNT; i++) this.levels[i] += (0 - this.levels[i]) * RELEASE;
      return;
    }

    analyser.getFloatFrequencyData(this.spectrum);
    const bandDb = new Array(BAND_COUNT);
    let loudest = -Infinity;
    for (let band = 0; band < BAND_COUNT; band++) {
      const [low, high] = this.bandRanges[band];
      let acc = 0, count = 0;
      for (let bin = low; bin < high; bin++) {
        const db = this.spectrum[bin];
        if (Number.isFinite(db)) { acc += 10 ** (db / 10); count++; }
      }
      const power = count ? acc / count : 1e-12;
      // Treble tilt: music's energy sits in the bass, so lift the upper bands
      // a little per step to keep every bar honest about its own range.
      bandDb[band] = 10 * Math.log10(Math.max(power, 1e-12)) + band * TILT_PER_BAND;
      if (bandDb[band] > loudest) loudest = bandDb[band];
    }

    // The reference tracks the recent loudest band: slow attack, slower
    // release, never below the floor.
    const rate = loudest > this.reference ? REFERENCE_ATTACK * 8 : REFERENCE_RELEASE;
    this.reference += (loudest - this.reference) * rate;
    if (this.reference < REFERENCE_FLOOR) this.reference = REFERENCE_FLOOR;

    for (let band = 0; band < BAND_COUNT; band++) {
      const target = Math.min(1, Math.max(0, (bandDb[band] - this.reference + RANGE_DB) / RANGE_DB));
      const current = this.levels[band];
      this.levels[band] = current + (target - current) * (target > current ? ATTACK : RELEASE);
    }
  }
}
