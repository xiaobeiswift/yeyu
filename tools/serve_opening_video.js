// Local static server for opening cinematic mp4.
// Y3 GameAPI.play_ui_video expects an http(s) URL in practice (file:// often no-op).
//
// Usage (keep this running while debugging):
//   node tools/serve_opening_video.js
// Config:
//   video.url = 'http://127.0.0.1:18765/kaichang.mp4'

const http = require('http')
const fs = require('fs')
const path = require('path')

const root = path.resolve(__dirname, '../assets/video')
const port = Number(process.env.WZX_VIDEO_PORT || 18765)

const server = http.createServer((req, res) => {
  const ts = new Date().toISOString()
  console.log(`[WZX-video] ${ts} ${req.method} ${req.url} range=${req.headers.range || '-'}`)

  let u = decodeURIComponent((req.url || '/').split('?')[0])
  if (u === '/') u = '/kaichang.mp4'
  const f = path.normalize(path.join(root, u.replace(/^\/+/, '')))
  if (!f.startsWith(path.normalize(root)) || !fs.existsSync(f)) {
    res.writeHead(404)
    res.end('missing ' + f)
    return
  }
  const st = fs.statSync(f)
  const ext = path.extname(f).toLowerCase()
  const ctype =
    ext === '.png' ? 'image/png' :
    ext === '.jpg' || ext === '.jpeg' ? 'image/jpeg' :
    ext === '.webp' ? 'image/webp' :
    'video/mp4'
  const range = req.headers.range
  if (range) {
    const m = /bytes=(\d+)-(\d*)/.exec(range)
    const start = m ? Number(m[1]) : 0
    const end = m && m[2] ? Number(m[2]) : st.size - 1
    res.writeHead(206, {
      'Content-Type': ctype,
      'Content-Length': end - start + 1,
      'Content-Range': `bytes ${start}-${end}/${st.size}`,
      'Accept-Ranges': 'bytes',
      'Access-Control-Allow-Origin': '*',
    })
    fs.createReadStream(f, { start, end }).pipe(res)
    return
  }
  res.writeHead(200, {
    'Content-Type': ctype,
    'Content-Length': st.size,
    'Accept-Ranges': 'bytes',
    'Access-Control-Allow-Origin': '*',
  })
  fs.createReadStream(f).pipe(res)
})

server.listen(port, '127.0.0.1', () => {
  console.log(`[WZX] opening video http://127.0.0.1:${port}/kaichang.mp4`)
  console.log(`[WZX] freeze still http://127.0.0.1:${port}/kaichang_last.png`)
  console.log(`[WZX] root=${root}`)
})
