let vibrator = null
try { vibrator = require('@system.vibrator') } catch (error) {}
let lastPulse = -Infinity
let unavailable = false
function pulse(enabled) {
  if (!enabled || unavailable || !vibrator || typeof vibrator.vibrate !== 'function') return false
  const now = Date.now()
  if (now - lastPulse < 250) return false
  lastPulse = now
  try { vibrator.vibrate({ mode: 'short', fail: () => { unavailable = true } }); return true }
  catch (error) { unavailable = true; return false }
}
module.exports = { pulse }
