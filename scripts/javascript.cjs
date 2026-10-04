const fs = require('node:fs')
const acorn = require('./vendor/acorn.cjs')
function parse(source) {
  return acorn.parse(source, { ecmaVersion: 'latest', sourceType: 'script', locations: true })
}

function visit(node, callback, parent = null, ancestors = []) {
  callback(node, parent, ancestors)
  for (const [key, value] of Object.entries(node)) {
    if (key === 'loc') continue
    if (Array.isArray(value)) {
      for (const item of value) if (item && typeof item.type === 'string') visit(item, callback, node, [...ancestors, node])
    } else if (value && typeof value.type === 'string') visit(value, callback, node, [...ancestors, node])
  }
}

const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
function decodeVLQ(text, position) {
  let value = 0, shift = 0, digit
  do {
    digit = alphabet.indexOf(text[position.value++])
    if (digit < 0 || shift > 30) throw new Error('无效的 source map。')
    value += (digit & 31) * 2 ** shift
    shift += 5
  } while (digit & 32)
  return (value & 1) ? -(value >> 1) : value >> 1
}

function sourceLookup(mapPath) {
  if (!fs.existsSync(mapPath)) throw new Error(`缺少 ${mapPath}，无法确认翻译范围。`)
  const map = JSON.parse(fs.readFileSync(mapPath, 'utf8'))
  const lines = []
  let source = 0, originalLine = 0, originalColumn = 0, name = 0
  for (const line of map.mappings.split(';')) {
    let column = 0
    const segments = []
    for (const segment of line.split(',')) {
      if (!segment) continue
      const p = { value: 0 }
      column += decodeVLQ(segment, p)
      if (p.value === segment.length) { segments.push({ column }); continue }
      source += decodeVLQ(segment, p)
      originalLine += decodeVLQ(segment, p)
      originalColumn += decodeVLQ(segment, p)
      if (p.value < segment.length) name += decodeVLQ(segment, p)
      segments.push({ column, source, originalLine, originalColumn })
    }
    lines.push(segments)
  }
  return loc => {
    const line = lines[loc.line - 1] || []
    let low = 0, high = line.length - 1, result
    while (low <= high) {
      const mid = (low + high) >> 1
      if (line[mid].column <= loc.column) { result = line[mid]; low = mid + 1 } else high = mid - 1
    }
    return result?.source === undefined ? null : {
      source: map.sources[result.source].replace(/^webpack:\/\/(?:\/)?\.\//, ''),
      line: result.originalLine + 1,
      column: result.originalColumn,
    }
  }
}

const displayKeys = new Set(['label', 'title', 'description', 'placeholder', 'aria-label', 'ariaLabel', 'tooltip', 'tooltipText', 'message', 'detail', 'buttonLabel', 'okButtonText', 'cancelButtonText', 'submitButtonText', 'secondaryText', 'subtitle', 'text', 'summary', 'emptyText', 'actionLabel', 'loadingMessage', 'progressDescription', 'hint', 'accessibilityLabel'])
function displayFragment(node, parent, ancestors) {
  const expression = node.type === 'TemplateElement' ? parent : node
  const call = node.type === 'TemplateElement' ? ancestors[ancestors.length - 2] : parent
  return call?.type === 'CallExpression' && call.callee.type === 'MemberExpression' &&
    !call.callee.computed && call.callee.property.name === 'createElement' &&
    call.arguments.indexOf(expression) >= 2
}
function eligible(node, parent, ancestors, origin) {
  if (!origin || !/^app\/src\//.test(origin.source)) return false
  const value = node.type === 'TemplateElement' ? node.value.cooked : node.value
  if (!['Literal', 'TemplateElement'].includes(node.type) || typeof value !== 'string') return false
  if (!value.trim() || (!/[A-Za-z]/.test(value) && !['(', ')', ' ('].includes(value))) return false
  // This locale is consumed only by the app's relative-time display formatter.
  if (origin.source === 'app/src/lib/format-relative.ts' && value === 'en-US' && parent?.type === 'CallExpression' && parent.arguments[0] === node) return true
  if (['Property', 'MethodDefinition', 'PropertyDefinition'].includes(parent?.type) && parent.key === node) return false
  if (parent?.type === 'ExpressionStatement' && parent.directive) return false
  if (parent?.type === 'MemberExpression' && parent.property === node) return false
  if (parent?.type === 'ImportDeclaration' || parent?.type === 'SwitchCase') return false
  if (parent?.type === 'BinaryExpression' && parent.operator !== '+') return false
  // Preserve TypeScript enum reverse mappings; they are identifiers, not labels.
  if (parent?.type === 'AssignmentExpression' && parent.left?.type === 'MemberExpression' && parent.left.computed && parent.left.property?.type === 'AssignmentExpression') return false
  const property = [parent, ...ancestors.slice().reverse()].find(n => n?.type === 'Property')
  if (property) {
    const key = property.key.name ?? property.key.value
    if (displayKeys.has(key)) return true
    if (['id', 'name', 'className', 'type', 'role', 'value', 'href', 'src', 'command', 'event', 'accelerator', 'key', 'action', 'data-testid'].includes(key)) return false
  }
  return /^app\/src\/ui\//.test(origin.source) || /^app\/src\/(?:lib\/menu|main-process\/menu)/.test(origin.source)
}

function candidates(source, mapPath) {
  const lookup = sourceLookup(mapPath)
  const list = []
  const ast = parse(source)
  visit(ast, (node, parent, ancestors) => {
    if (node.type !== 'TemplateElement' && (node.type !== 'Literal' || typeof node.value !== 'string')) return
    // JSX text is sometimes explicitly unmapped. Its enclosing JSX call still
    // identifies the original component; never infer scope from adjacent text.
    const origin = lookup(node.loc.start) || (parent?.loc ? lookup(parent.loc.start) : null)
    if (eligible(node, parent, ancestors, origin)) list.push({ node, value: node.type === 'TemplateElement' ? node.value.cooked : node.value, origin, parent, ancestors, displayFragment: displayFragment(node, parent, ancestors) })
  })
  return { ast, list }
}

module.exports = { parse, visit, candidates, sourceLookup, eligible, acornVersion: acorn.version }
