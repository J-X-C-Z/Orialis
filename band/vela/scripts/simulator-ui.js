// UI evidence from Xiaomi's real emulator controller; no browser rendering.
const fs = require('node:fs')
const path = require('node:path')
const { createGrpcClient } = require('@aiot-toolkit/emulator/lib/vvd/grpc')
const client = createGrpcClient({ 'grpc.port': Number(process.env.ORIALIS_SIM_GRPC_PORT || 8554), 'grpc.token': process.env.ORIALIS_SIM_GRPC_TOKEN || '' })
function call(method, value) { return new Promise((resolve, reject) => client.client[method](value, client.authMate, (error, result) => error ? reject(error) : resolve(result))) }
function pause(ms) { return new Promise((resolve) => setTimeout(resolve, ms)) }
async function main() {
  const [command, ...args] = process.argv.slice(2)
  if (command === 'capture') {
    await pause(400)
    const result = await call('getScreenshot', { format: 'PNG' })
    const target = path.resolve(args[0]); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, result.image)
    console.log('Simulator screenshot saved:', target)
  } else if (command === 'tap') {
    const [x, y] = args.map(Number); await call('sendMouse', { x, y, buttons: 0 }); await pause(200); await call('sendMouse', { x, y, buttons: 1 }); await pause(150); await call('sendMouse', { x, y, buttons: 0 }); await pause(1200)
  } else if (command === 'swipe') {
    const [x, from, to] = args.map(Number)
    await call('sendMouse', { x, y: from, buttons: 1 })
    for (let i = 1; i <= 15; i += 1) { await pause(25); await call('sendMouse', { x, y: Math.round(from + (to - from) * i / 15), buttons: 1 }) }
    await call('sendMouse', { x, y: to, buttons: 0 }); await pause(1200)
  } else throw new Error('Usage: node scripts/simulator-ui.js capture <png> | tap <x> <y> | swipe <x> <fromY> <toY>')
}
main().then(() => client.close()).catch((error) => { console.error(error.message); client.close(); process.exitCode = 1 })
