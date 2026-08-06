import { readFile } from 'node:fs/promises'

const INSCRIPTION_ID_RE = /^[a-f0-9]{64}i\d+$/
const SLUG_RE = /^[a-z0-9_-]+$/
const X_HANDLE_RE = /^[A-Za-z0-9_]{1,15}$/
const X_URL_RE = /^(?:https?:\/\/)?(?:www\.)?(?:x\.com|twitter\.com)\/@?([A-Za-z0-9_]+)/i

const collectionsPath = new URL('../collections.json', import.meta.url).pathname
const collections = JSON.parse(await readFile(collectionsPath, 'utf8'))
const existingSlugs = new Set(collections.map(e => e.slug))

const body = await new Promise(resolve => {
  let data = ''
  process.stdin.on('data', chunk => { data += chunk })
  process.stdin.on('end', () => resolve(data))
})

const sections = {}
let currentKey = null
for (const line of body.split('\n')) {
  const match = line.match(/^### (.+)$/)
  if (match) {
    currentKey = match[1].trim()
    sections[currentKey] = ''
  } else if (currentKey) {
    sections[currentKey] += line + '\n'
  }
}

for (const key of Object.keys(sections)) {
  sections[key] = sections[key].trim()
}

const rawTitle = process.env.ISSUE_TITLE || sections['Collection Name'] || ''
const name = rawTitle.replace(/^add\s+(?:collection[:\s]*)?/i, '').trim()
const type = sections['Collection Type'] || ''
const rawIds = sections['Inscription ID(s)'] || ''
const slug = (sections['Slug'] || '').toLowerCase().trim()
const rawX = sections['X Handle(s)'] || ''

const errors = []

if (!name) errors.push('Collection Name is required')
if (!['gallery', 'parent'].includes(type)) errors.push(`Invalid type: "${type}" (must be gallery or parent)`)
if (!slug) {
  errors.push('Slug is required')
} else if (!SLUG_RE.test(slug)) {
  errors.push(`Invalid slug: "${slug}" (lowercase letters, numbers, hyphens, underscores only)`)
} else if (existingSlugs.has(slug)) {
  errors.push(`Slug "${slug}" already exists in collections.json`)
}

const ids = rawIds.split('\n').map(l => l.trim()).filter(Boolean)
if (ids.length === 0) {
  errors.push('At least one inscription ID is required')
} else {
  for (const id of ids) {
    if (!INSCRIPTION_ID_RE.test(id)) {
      errors.push(`Invalid inscription ID: "${id}"`)
    }
  }
}

if (type === 'gallery' && ids.length > 1) {
  errors.push(`Gallery type expects a single inscription ID, got ${ids.length}`)
}

const xHandles = []
if (rawX && rawX !== '_No response_') {
  const seenHandles = new Set()
  for (const part of rawX.split(/[\s,]+/).filter(Boolean)) {
    const urlMatch = part.match(X_URL_RE)
    const handle = urlMatch ? urlMatch[1] : part.replace(/^@/, '')

    if (!handle || seenHandles.has(handle.toLowerCase())) continue

    seenHandles.add(handle.toLowerCase())
    xHandles.push(handle)

    if (!X_HANDLE_RE.test(handle)) {
      errors.push(`Invalid X handle: "${handle}" (letters, numbers, underscores, max 15 characters)`)
    }
  }
}

let entry = null
if (errors.length === 0) {
  entry = { name: name.trim(), type, slug }
  if (type === 'gallery') {
    entry.id = ids[0]
  } else {
    entry.ids = ids
  }
  if (xHandles.length > 0) {
    entry.x = xHandles.length === 1 ? xHandles[0] : xHandles
  }
}

console.log(JSON.stringify({ entry, errors }))
