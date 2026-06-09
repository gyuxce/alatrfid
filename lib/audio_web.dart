// Web implementation for POS beep sound using Web Audio API via dart:js.
// This file is loaded via conditional import only on web platforms.

import 'dart:js' as js;

void playWebBeepSound() {
  try {
    js.context.callMethod('eval', [
      """
      var ctx = new (window.AudioContext || window.webkitAudioContext)();
      var osc = ctx.createOscillator();
      var gain = ctx.createGain();
      osc.connect(gain);
      gain.connect(ctx.destination);
      osc.type = 'sine';
      osc.frequency.setValueAtTime(880, ctx.currentTime);
      gain.gain.setValueAtTime(0.08, ctx.currentTime);
      osc.start(ctx.currentTime);
      osc.stop(ctx.currentTime + 0.12);
      """
    ]);
  } catch (e) {
    // Silently fail if Web Audio API is not available
  }
}
