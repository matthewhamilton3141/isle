// media-model.js
//
// The music half of the island's model, living in the renderer because the
// scrubber reads it at frame rate. A port of the media parts of
// NotchViewModel: the smoothed playback clock, the optimistic hold after a
// transport command, and the palette pulled from the cover (cached per cover).
//
// The scrubber runs off its own anchor rather than off whatever the bridge
// last reported. Spotify's SMTC timeline re-reports position irregularly and
// quantised; anchoring directly to it would yank the extrapolated position
// back into line on every report. Here a report only moves the anchor
// outright when it disagrees materially (a seek, a track change, a
// play/pause); ordinary sub-second disagreement is absorbed a fraction at a
// time, so the bar stays monotonic and the correction is invisible.

import { paletteFromImage } from '../shared/colors.js';

const DRIFT_CORRECTION = 0.18;
const SNAP_THRESHOLD = 1.5;
const COMMAND_GRACE_MS = 1500;

const EMPTY = Object.freeze({
  hasTrack: false, title: '', artist: '', album: '', duration: 0, reportedElapsed: 0,
  timestamp: 0, isPlaying: false, playbackRate: 0, isShuffled: false, repeatMode: 'off',
  canSeek: false, canShuffle: false, canRepeat: false, artwork: null, artKey: '',
});

export class MediaModel {
  constructor(onChange) {
    this.onChange = onChange;
    this.media = { ...EMPTY };
    this.artworkImage = null;      // decoded HTMLImageElement for the current cover
    this.artworkPalette = null;    // palette from it, or null without a cover
    this.loadingArtwork = null;

    this.anchorElapsed = 0;
    this.anchorDate = null;
    this.anchorRate = 0;

    this.pendingPlayState = null;
    this.pendingSeekTarget = null;
    this.pendingShuffle = null;
    this.pendingRepeat = null;
    this.pendingDeadline = 0;

    /** Position the user is dragging the scrubber to (0…1). Non-null only mid-drag. */
    this.scrubTarget = null;
  }

  // MARK: - Source

  /** A snapshot from the bridge (via main). */
  receive(snapshot) {
    const model = snapshot && snapshot.hasTrack ? { ...EMPTY, ...snapshot } : { ...EMPTY };
    this.holdOptimistic(model);
    this.apply(model);
  }

  holdOptimistic(model) {
    const now = Date.now();
    const expired = now >= this.pendingDeadline;
    if (this.pendingPlayState != null) {
      if (model.isPlaying === this.pendingPlayState || expired) this.pendingPlayState = null;
      else { model.isPlaying = this.pendingPlayState; model.playbackRate = model.isPlaying ? 1 : 0; }
    }
    if (this.pendingSeekTarget != null) {
      const elapsed = model.reportedElapsed + (model.playbackRate * (now - model.timestamp)) / 1000;
      if (Math.abs(elapsed - this.pendingSeekTarget) < 2 || expired) this.pendingSeekTarget = null;
      else { model.reportedElapsed = this.pendingSeekTarget; model.timestamp = now; }
    }
    if (this.pendingShuffle != null) {
      if (model.isShuffled === this.pendingShuffle || expired) this.pendingShuffle = null;
      else model.isShuffled = this.pendingShuffle;
    }
    if (this.pendingRepeat != null) {
      if (model.repeatMode === this.pendingRepeat || expired) this.pendingRepeat = null;
      else model.repeatMode = this.pendingRepeat;
    }
  }

  apply(model) {
    const now = Date.now();
    const previous = this.media;
    const reported = model.hasTrack
      ? Math.max(0, model.reportedElapsed + (model.playbackRate * (now - model.timestamp)) / 1000)
      : 0;
    const isNewTrack = model.title !== previous.title || model.album !== previous.album;
    const transportChanged = model.isPlaying !== previous.isPlaying || model.playbackRate !== this.anchorRate;

    // Same track, no cover yet: keep the one on screen.
    if (!model.artwork && !isNewTrack) model.artwork = previous.artwork;

    if (this.anchorDate == null || isNewTrack || transportChanged) {
      this.anchorElapsed = reported;
    } else {
      const predicted = this.projectedElapsed(now);
      const disagreement = reported - predicted;
      this.anchorElapsed = Math.abs(disagreement) > SNAP_THRESHOLD
        ? reported
        : predicted + disagreement * DRIFT_CORRECTION;
    }
    this.anchorDate = now;
    this.anchorRate = model.playbackRate;

    if (model.artwork !== previous.artwork) this.loadArtwork(model.artwork);

    this.media = model;
    this.onChange();
  }

  loadArtwork(dataUrl) {
    if (!dataUrl) {
      this.artworkImage = null;
      this.artworkPalette = null;
      this.loadingArtwork = null;
      return;
    }
    const image = new Image();
    this.loadingArtwork = image;
    image.onload = () => {
      if (this.loadingArtwork !== image) return;
      this.artworkImage = image;
      this.artworkPalette = paletteFromImage(image);
      this.onChange();
    };
    image.onerror = () => {
      if (this.loadingArtwork !== image) return;
      this.artworkImage = null;
      this.artworkPalette = null;
      this.onChange();
    };
    image.src = dataUrl;
  }

  // MARK: - Clock

  projectedElapsed(at = Date.now()) {
    if (this.anchorDate == null) return 0;
    const raw = this.anchorElapsed + ((at - this.anchorDate) / 1000) * this.anchorRate;
    if (this.media.duration <= 0) return Math.max(0, raw);
    return Math.min(Math.max(0, raw), this.media.duration);
  }

  /** Progress to render: the drag target while scrubbing, else the smoothed clock. */
  displayProgress(at = Date.now()) {
    if (this.scrubTarget != null) return this.scrubTarget;
    if (this.media.duration <= 0) return 0;
    return this.projectedElapsed(at) / this.media.duration;
  }

  // MARK: - Transport (optimistic)

  get canControlPlayback() { return this.media.hasTrack; }
  get canSeek() { return this.media.hasTrack && this.media.duration > 0 && this.media.canSeek; }

  togglePlayPause() {
    if (!this.canControlPlayback) return;
    window.isle.media.playPause();
    const now = Date.now();
    this.anchorElapsed = this.projectedElapsed(now);
    this.anchorDate = now;
    this.media = { ...this.media, isPlaying: !this.media.isPlaying };
    this.media.playbackRate = this.media.isPlaying ? 1 : 0;
    this.anchorRate = this.media.playbackRate;
    this.pendingPlayState = this.media.isPlaying;
    this.pendingDeadline = now + COMMAND_GRACE_MS;
    this.onChange();
  }

  nextTrack() { if (this.canControlPlayback) window.isle.media.next(); }
  previousTrack() { if (this.canControlPlayback) window.isle.media.previous(); }

  toggleShuffle() {
    if (!this.canControlPlayback) return;
    const want = !this.media.isShuffled;
    window.isle.media.setShuffle(want);
    this.media = { ...this.media, isShuffled: want };
    this.pendingShuffle = want;
    this.pendingDeadline = Date.now() + COMMAND_GRACE_MS;
    this.onChange();
  }

  /** off → all → one → off, matching what SMTC can express. */
  toggleRepeat() {
    if (!this.canControlPlayback) return;
    const want = this.media.repeatMode === 'off' ? 'all' : this.media.repeatMode === 'all' ? 'one' : 'off';
    window.isle.media.setRepeat(want);
    this.media = { ...this.media, repeatMode: want };
    this.pendingRepeat = want;
    this.pendingDeadline = Date.now() + COMMAND_GRACE_MS;
    this.onChange();
  }

  /** Commits a scrub on drag end, not continuously. */
  commitScrub() {
    const target = this.scrubTarget;
    this.scrubTarget = null;
    if (target == null || this.media.duration <= 0) { this.onChange(); return; }
    const seconds = target * this.media.duration;
    window.isle.media.seek(seconds);
    const now = Date.now();
    this.anchorElapsed = seconds;
    this.anchorDate = now;
    this.pendingSeekTarget = seconds;
    this.pendingDeadline = now + COMMAND_GRACE_MS;
    this.onChange();
  }
}
