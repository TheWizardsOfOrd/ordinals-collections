import { readFile } from 'node:fs/promises'

const BASE_COLLECTIONS_JSON = process.env.BASE_COLLECTIONS_JSON || '[]'
const SATFLOW_BASE = 'https://www.satflow.com/ordinals'
const ORDINALSWALLET_BASE = 'https://turbo.ordinalswallet.com/collection'

const baseCollections = JSON.parse(BASE_COLLECTIONS_JSON)
const baseSlugs = new Set(baseCollections.map(entry => entry.slug))

const raw = await readFile(new URL('../collections.json', import.meta.url), 'utf8')
const prCollections = JSON.parse(raw)

const newSlugs = prCollections
  .map(entry => entry.slug)
  .filter(slug => slug && !baseSlugs.has(slug))

if (newSlugs.length === 0) {
  console.log(JSON.stringify({ found: [] }))
  process.exit(0)
}

const legacyRaw = await readFile(new URL('../legacy/collections.json', import.meta.url), 'utf8')
const legacyCollections = JSON.parse(legacyRaw)
const legacySymbols = new Set(legacyCollections.map(entry => entry.symbol))

const found = []

for (const slug of newSlugs) {
  const legacyMatch = legacySymbols.has(slug)

  let satflowMatch = false
  const satflowUrl = `${SATFLOW_BASE}/${slug}`

  try {
    const response = await fetch(satflowUrl, { method: 'HEAD', redirect: 'follow' })
    satflowMatch = response.ok
  } catch {
    // network error — treat as no match
  }

  let ordinalswalletMatch = false
  const ordinalswalletUrl = `${ORDINALSWALLET_BASE}/${slug}`

  try {
    const response = await fetch(ordinalswalletUrl, { method: 'HEAD', redirect: 'follow' })
    ordinalswalletMatch = response.ok
  } catch {
    // network error — treat as no match
  }

  if (legacyMatch || satflowMatch || ordinalswalletMatch) {
    found.push({ slug, legacyMatch, satflowMatch, satflowUrl, ordinalswalletMatch, ordinalswalletUrl })
  }
}

const output = JSON.stringify({ found }, null, 2)
console.log(output)
