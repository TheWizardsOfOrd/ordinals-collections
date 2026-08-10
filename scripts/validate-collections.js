import { readFile } from 'node:fs/promises'

const VALID_TYPES = ['parent', 'gallery', 'multi_gallery']
const INSCRIPTION_ID_RE = /^[a-f0-9]{64}i\d+$/
const X_HANDLE_RE = /^[A-Za-z0-9_]{1,15}$/
const VALID_KEYS = new Set(['name', 'type', 'slug', 'id', 'ids', 'x'])
const NEEDS_INFO_KEYS = new Set(['name', 'type', 'slug', 'id', 'ids', 'issues', 'x'])

let errors = 0

function error(message) {
  console.error(`ERROR: ${message}`)
  errors++
}

function validateEntries(collections, { label, validKeys, requireIssues, forbiddenSlugs, inscriptionIds }) {
  // Check alpha sort
  for (let i = 1; i < collections.length; i++) {
    if (collections[i].name.localeCompare(collections[i - 1].name) < 0) {
      error(`[${label}] Not sorted: "${collections[i].name}" comes after "${collections[i - 1].name}"`)
    }
  }

  // Check for duplicate slugs and names
  const slugs = new Set()
  const names = new Set()
  for (const entry of collections) {
    if (slugs.has(entry.slug)) {
      error(`[${label}] Duplicate slug: "${entry.slug}"`)
    }
    slugs.add(entry.slug)

    if (names.has(entry.name)) {
      error(`[${label}] Duplicate name: "${entry.name}"`)
    }
    names.add(entry.name)

    if (forbiddenSlugs && forbiddenSlugs.has(entry.slug)) {
      error(`[${label}] Slug "${entry.slug}" conflicts with collections.json`)
    }

    const entryIds = entry.id ? [entry.id] : (entry.ids || [])
    const seenInEntry = new Set()
    for (const id of entryIds) {
      if (seenInEntry.has(id)) {
        error(`[${label}:${entry.slug}] inscription ID "${id}" listed more than once`)
      }
      seenInEntry.add(id)
    }

    const setKey = [...entryIds].sort().join('|')
    if (setKey && inscriptionIds.has(setKey)) {
      error(`[${label}] Duplicate inscription ID set in "${entry.slug}" and "${inscriptionIds.get(setKey)}"`)
    }
    inscriptionIds.set(setKey, entry.slug)
  }

  // Validate each entry
  for (const entry of collections) {
    const tag = entry.slug || entry.name || '(unknown)'

    const unexpected = Object.keys(entry).filter(k => !validKeys.has(k))
    if (unexpected.length > 0) {
      error(`[${label}:${tag}] unexpected keys: ${unexpected.join(', ')}`)
    }

    if (typeof entry.name !== 'string' || !entry.name.trim()) {
      error(`[${label}:${tag}] missing or empty name`)
    } else if (entry.name !== entry.name.trim()) {
      error(`[${label}:${tag}] name has leading/trailing whitespace: "${entry.name}"`)
    }

    if (!VALID_TYPES.includes(entry.type)) {
      error(`[${label}:${tag}] invalid type "${entry.type}", must be: ${VALID_TYPES.join(', ')}`)
    }

    if (typeof entry.slug !== 'string' || !entry.slug.trim()) {
      error(`[${label}:${tag}] missing or empty slug`)
    } else if (entry.slug !== entry.slug.toLowerCase()) {
      error(`[${label}:${tag}] slug must be lowercase: "${entry.slug}"`)
    } else if (!/^[a-z0-9_-]+$/.test(entry.slug)) {
      error(`[${label}:${tag}] slug contains invalid characters: "${entry.slug}"`)
    }

    if (entry.type === 'parent' || entry.type === 'multi_gallery') {
      if (!Array.isArray(entry.ids) || entry.ids.length === 0) {
        error(`[${label}:${tag}] ${entry.type} type must have non-empty ids array`)
      } else {
        for (const id of entry.ids) {
          if (!INSCRIPTION_ID_RE.test(id)) {
            error(`[${label}:${tag}] invalid inscription ID: "${id}"`)
          }
        }
      }
    }

    if (entry.type === 'gallery') {
      if (typeof entry.id !== 'string' || !INSCRIPTION_ID_RE.test(entry.id)) {
        error(`[${label}:${tag}] gallery type must have valid id string`)
      }
    }

    if (entry.x !== undefined) {
      const handles = Array.isArray(entry.x) ? entry.x : [entry.x]
      if (handles.length === 0) {
        error(`[${label}:${tag}] x must not be an empty array`)
      }

      const seenHandles = new Set()
      for (const handle of handles) {
        if (typeof handle !== 'string' || !X_HANDLE_RE.test(handle)) {
          error(`[${label}:${tag}] invalid X handle: "${handle}" (letters, numbers, underscores, max 15 chars, no @)`)
        } else if (seenHandles.has(handle.toLowerCase())) {
          error(`[${label}:${tag}] duplicate X handle: "${handle}"`)
        } else {
          seenHandles.add(handle.toLowerCase())
        }
      }
    }

    if (requireIssues) {
      if (!Array.isArray(entry.issues) || entry.issues.length === 0) {
        error(`[${label}:${tag}] must have non-empty issues array`)
      }
    }
  }
}

// Validate collections.json
const collectionsRaw = await readFile(new URL('../collections.json', import.meta.url), 'utf8')
let collections
try {
  collections = JSON.parse(collectionsRaw)
} catch (e) {
  error(`collections.json: Invalid JSON: ${e.message}`)
  process.exit(1)
}

if (!Array.isArray(collections)) {
  error('collections.json: Root must be an array')
  process.exit(1)
}

const allInscriptionIds = new Map()

validateEntries(collections, {
  label: 'collections.json',
  validKeys: VALID_KEYS,
  requireIssues: false,
  forbiddenSlugs: null,
  inscriptionIds: allInscriptionIds,
})

const collectionSlugs = new Set(collections.map(e => e.slug))

// Validate collections-needs-info.json
const needsInfoRaw = await readFile(new URL('../collections-needs-info.json', import.meta.url), 'utf8')
let needsInfo
try {
  needsInfo = JSON.parse(needsInfoRaw)
} catch (e) {
  error(`collections-needs-info.json: Invalid JSON: ${e.message}`)
  process.exit(1)
}

if (!Array.isArray(needsInfo)) {
  error('collections-needs-info.json: Root must be an array')
  process.exit(1)
}

if (needsInfo.length > 0) {
  validateEntries(needsInfo, {
    label: 'needs-info',
    validKeys: NEEDS_INFO_KEYS,
    requireIssues: true,
    forbiddenSlugs: collectionSlugs,
    inscriptionIds: allInscriptionIds,
  })
}

// Validate collections-disputed.json
const disputedRaw = await readFile(new URL('../collections-disputed.json', import.meta.url), 'utf8')
let disputed
try {
  disputed = JSON.parse(disputedRaw)
} catch (e) {
  error(`collections-disputed.json: Invalid JSON: ${e.message}`)
  process.exit(1)
}

if (!Array.isArray(disputed)) {
  error('collections-disputed.json: Root must be an array')
  process.exit(1)
}

if (disputed.length > 0) {
  validateEntries(disputed, {
    label: 'disputed',
    validKeys: VALID_KEYS,
    requireIssues: false,
    forbiddenSlugs: collectionSlugs,
    inscriptionIds: allInscriptionIds,
  })
}

if (errors > 0) {
  console.error(`\n${errors} error(s) found`)
  process.exit(1)
}

console.log(`OK — ${collections.length} entries validated, ${needsInfo.length} needs-info entries validated, ${disputed.length} disputed entries validated`)
