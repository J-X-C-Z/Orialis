/**
 * Unified vibration feedback for Xiaomi Vela JS apps.
 *
<<<<<<< HEAD
 * Navigation and ordinary taps are intentionally silent. Completion uses two
 * short pulses: this is lighter and crisper than the previous long pulse on
 * Vela hardware. Unsupported runtimes fail silently.
=======
 * The official vibrator API exposes short/long modes rather than intensity
 * levels, so the three semantic levels are mapped to the closest supported
 * mode. Unsupported runtimes fail silently.
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
 */
var vibrator = null

try {
  vibrator = require('@system.vibrator')
} catch (error) {
  vibrator = null
}

function vibrate(mode) {
  if (!vibrator || typeof vibrator.vibrate !== 'function') {
    return
  }

  try {
    vibrator.vibrate({ mode: mode })
  } catch (error) {
    // Vibration is optional feedback; never let it interrupt app behavior.
  }
}

export function light() {
<<<<<<< HEAD
  // Ordinary navigation/taps should not vibrate.
}

export function medium() {
  // Ordinary actions should not vibrate.
}

export function heavy() {
  // Exit/navigation actions should not vibrate.
}

export function complete() {
  vibrate('short')
  setTimeout(() => vibrate('short'), 105)
=======
  vibrate('short')
}

export function medium() {
  vibrate('short')
}

export function heavy() {
  vibrate('long')
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
}

export default {
  light,
  medium,
<<<<<<< HEAD
  heavy,
  complete
=======
  heavy
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
}
