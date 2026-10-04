#!/usr/bin/env node
const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')
const { candidates, parse, visit, sourceLookup, acornVersion } = require('./javascript.cjs')

const projectRoot = path.resolve(__dirname, '..')
const hash = data => crypto.createHash('sha256').update(data).digest('hex')
const json = value => JSON.stringify(value, null, 2) + '\n'
const astJSON = ast => JSON.stringify(ast, (key, value) => ['start', 'end', 'loc', 'raw'].includes(key) ? undefined : value)
const files = ['main.js', 'renderer.js']

function versionParts(value) { return value.split('.').map(Number) }
function compareVersions(left, right) {
  const a = versionParts(left), b = versionParts(right)
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] - b[i]
  return 0
}

function resolveApp(input) {
  const root = path.resolve(input)
  for (const candidate of [root, path.join(root, 'resources', 'app')]) {
    if (fs.existsSync(path.join(candidate, 'package.json')) && fs.existsSync(path.join(candidate, 'renderer.js'))) return candidate
  }
  const versions = fs.readdirSync(root, { withFileTypes: true }).filter(x => x.isDirectory() && /^app-\d+\.\d+\.\d+$/.test(x.name)).sort((a,b) => compareVersions(b.name.slice(4), a.name.slice(4)))
  if (!versions.length) throw new Error('未找到 GitHub Desktop。请使用 --app 指定版本目录或 resources/app 目录。')
  return resolveApp(path.join(root, versions[0].name))
}

function loadDictionary(file) {
  const data = JSON.parse(fs.readFileSync(file, 'utf8'))
  if (data.locale !== 'zh-CN' || !Array.isArray(data.entries)) throw new Error('翻译词典格式无效。')
  const entries = new Map()
  for (const entry of data.entries) {
    if (typeof entry.text !== 'string' || !entry.text || typeof entry.translation !== 'string' || !Array.isArray(entry.sources) || !entry.sources.length || entry.sources.some(x => typeof x !== 'string' || !x.startsWith('app/src/'))) throw new Error(`翻译条目无效：${entry.text}`)
    if (entries.has(entry.text)) throw new Error(`翻译词典重复：${entry.text}`)
    entries.set(entry.text, entry)
  }
  return entries
}

function taggedTemplate(ancestors) {
  return ancestors.some((node, index) => node.type === 'TaggedTemplateExpression' && ancestors[index+1] === node.quasi)
}

function pendingCandidate(value, origin, displayFragment) {
  if (!/^app\/src\/(?:ui|main-process\/menu)\//.test(origin.source)) return false
  if (/(?:dispatcher|stores|build-test-menu|\/test-|dds-converter|syntax-highlighting)/.test(origin.source)) return false
  if (displayFragment && value.length <= 1200 && /[A-Za-z]/.test(value) && !/https?:|[{};]/.test(value)) return true
  if (value.length < 4 || value.length > 1200 || /https?:|[{};]|^\[|^--|^[a-z]+-\w+|^(?:Failed|Unknown|Unexpected|Unsupported|Error loading|Tried to|Expecting|Invalid .*type)/.test(value)) return false
  return /[a-z][a-z] (?:[A-Za-z]|$)|^[A-Z][a-z]+(?: [A-Z][a-z]+)*[.!?…]?$/.test(value)
}

function patch(source, mapFile, dictionary, { translationAuthor, translationAuthorUrl } = {}) {
  const { ast, list } = candidates(source, mapFile)
  const edits = [], pending = new Map(), applied = new Map()
  for (const { node, value, origin, ancestors, displayFragment } of list) {
    const entry = dictionary.get(value)
    if (!entry || !entry.sources.includes(origin.source)) {
      if (pendingCandidate(value, origin, displayFragment)) {
        const key = `${origin.source}\0${value}`
        if (!pending.has(key)) pending.set(key, { text: value, source: origin.source, line: origin.line })
      }
      continue
    }
    // Tagged templates can interpret their raw strings as code, selectors, etc.
    if (node.type === 'TemplateElement' && taggedTemplate(ancestors)) continue
    const replacement = node.type === 'TemplateElement'
      ? entry.translation.replace(/\\/g, '\\\\').replace(/`/g, '\\`').replace(/\$\{/g, '\\${').replace(/\r/g, '\\r').replace(/\n/g, '\\n')
      : JSON.stringify(entry.translation)
    edits.push({ start: node.start, end: node.end, replacement })
    if (node.type === 'TemplateElement') node.value.cooked = entry.translation
    else node.value = entry.translation
    const key = `${value}\0${origin.source}`
    const previous = applied.get(key)
    if (previous) previous.occurrences++
    else applied.set(key, { text: value, translation: entry.translation, source: origin.source, occurrences: 1 })
  }
  const occurrences = edits.length
  const customizations = []
  if (translationAuthor) {
    const lookup = sourceLookup(mapFile)
    visit(ast, node => {
      if (node.type !== 'CallExpression' || node.callee.type !== 'MemberExpression' || node.callee.computed || node.callee.property.name !== 'createElement') return
      if (lookup(node.loc.start)?.source !== 'app/src/ui/about/about.tsx' || node.arguments[0]?.value !== 'div') return
      const props = node.arguments[1]
      if (props?.type !== 'ObjectExpression' || !props.properties.some(p => p.key.name === 'className' && p.value.value === 'terms-and-license-container')) return
      const links = []
      visit(node, child => {
        if (child.type !== 'CallExpression' || child.arguments[0]?.type !== 'Identifier') return
        const properties = child.arguments[1]?.properties
        if (properties?.some(p => p.key.name === 'uri' && p.value.value === 'https://gh.io/copilot-for-desktop-transparency')) links.push(child.arguments[0])
      })
      if (links.length !== 1) throw new Error('未找到关于页面的链接入口，无法添加汉化作者链接。已停止生成。')
      const createElement = source.slice(node.callee.start, node.callee.end)
      const linkButton = source.slice(links[0].start, links[0].end)
      const credit = `${createElement}("p",{className:"no-padding terms-and-license"},"汉化作者：",${createElement}(${linkButton},{uri:${JSON.stringify(translationAuthorUrl)}},${JSON.stringify(translationAuthor)}))`
      node.arguments.push(parse(credit).body[0].expression)
      edits.push({ start: node.end - 1, end: node.end - 1, replacement: ',' + credit })
      customizations.push({ type: 'about-credit', author: translationAuthor, url: translationAuthorUrl })
    })
    if (customizations.length !== 1) throw new Error('未找到唯一的关于页面，无法添加汉化作者。已停止生成。')
  }
  let result = source
  edits.sort((a,b) => b.start - a.start)
  for (let i = 0; i < edits.length; i++) {
    const edit = edits[i]
    if (i && edit.end > edits[i-1].start) throw new Error('检测到重叠的翻译范围。')
    result = result.slice(0, edit.start) + edit.replacement + result.slice(edit.end)
  }
  if (astJSON(ast) !== astJSON(parse(result))) throw new Error('翻译后的程序结构校验失败，已停止生成。')
  return { result, occurrences, applied: [...applied.values()], pending: [...pending.values()], customizations }
}

function generate({ app, output, dictionaryPath = path.join(projectRoot, 'locales', 'zh-CN.json') }) {
  const input = resolveApp(app)
  const metadata = JSON.parse(fs.readFileSync(path.join(input, 'package.json'), 'utf8'))
  if (metadata.name !== 'desktop' || metadata.productName !== 'GitHub Desktop' || !/^\d+\.\d+\.\d+$/.test(metadata.version)) throw new Error('输入目录不是支持的 GitHub Desktop 正式版。')
  const backup = path.join(input, '.zh-cn-backup', 'backup-manifest.json')
  if (fs.existsSync(backup)) {
    const saved = JSON.parse(fs.readFileSync(backup, 'utf8').replace(/^\uFEFF/, ''))
    if (saved.version !== metadata.version || files.some(file => hash(fs.readFileSync(path.join(input,file))) !== saved.files?.[file]?.originalSha256)) throw new Error('输入目录已安装过汉化。请先恢复原版，或使用官方原始安装包生成。')
  }
  const destination = path.join(path.resolve(output), `app-${metadata.version}`)
  if (destination === input || destination.startsWith(input + path.sep) || input.startsWith(destination + path.sep)) throw new Error('输出目录不能覆盖输入目录。')
  const dictionaryData = fs.readFileSync(dictionaryPath)
  const dictionary = loadDictionary(dictionaryPath)
  const { translationAuthor, translationAuthorUrl } = JSON.parse(dictionaryData)
  if (typeof translationAuthor !== 'string' || !translationAuthor.trim() || translationAuthor.length > 80 || /[\x00-\x1f]/.test(translationAuthor)) throw new Error('请在词典中填写有效的 translationAuthor 汉化作者名称。')
  try {
    if (typeof translationAuthorUrl !== 'string' || new URL(translationAuthorUrl).protocol !== 'https:') throw new Error()
  } catch { throw new Error('请在词典中填写有效的 translationAuthorUrl 汉化作者 HTTPS 主页链接。') }
  const report = { version: metadata.version, locale: 'zh-CN', translationAuthor, translationAuthorUrl, dictionaryEntries: dictionary.size, parserVersion: acornVersion, files: {}, applied: [], pendingCandidates: [], customizations: [] }
  const artifacts = new Map()
  for (const file of files) {
    const original = fs.readFileSync(path.join(input, file))
    const result = patch(original.toString('utf8'), path.join(input, file + '.map'), dictionary, { translationAuthor: file === 'renderer.js' ? translationAuthor : undefined, translationAuthorUrl })
    if (!result.occurrences) throw new Error(`${file} 未匹配到翻译。请检查版本和词典，已停止生成。`)
    report.files[file] = { originalSha256: hash(original), translatedSha256: hash(result.result), occurrences: result.occurrences }
    report.applied.push(...result.applied.map(x=>({file,...x})))
    report.pendingCandidates.push(...result.pending.map(x=>({file,...x})))
    report.customizations.push(...result.customizations.map(x=>({file,...x})))
    artifacts.set(path.join('resources', 'app', file), result.result)
    const license = file + '.LICENSE.txt'
    if (fs.existsSync(path.join(input, license))) artifacts.set(path.join('resources', 'app', license), fs.readFileSync(path.join(input, license)))
  }
  const manifest = { schemaVersion: 1, product: 'GitHub Desktop', version: metadata.version, locale: 'zh-CN', translationAuthor, translationAuthorUrl, dictionarySha256: hash(dictionaryData), files: report.files }
  artifacts.set('manifest.json', json(manifest))
  artifacts.set('translation-report.json', json(report))
  artifacts.set('pending-ui-strings.json', json(report.pendingCandidates))
  const occurrences = Object.values(report.files).reduce((n,x)=>n+x.occurrences,0)
  const unique = new Set(report.applied.map(x=>x.text)).size
  artifacts.set('README.txt', `GitHub Desktop ${metadata.version} 简体中文汉化包\r\n汉化作者：${translationAuthor}\r\n\r\n本包包含 ${unique} 条不同文案，共替换 ${occurrences} 处。\r\n仍有未翻译的文案；pending-ui-strings.json 是待审核候选清单。\r\n\r\n安装：正常退出 GitHub Desktop 后，双击 install.cmd。\r\n更新已安装的汉化：先双击本包 restore.cmd，再双击 install.cmd。\r\n恢复：正常退出 GitHub Desktop 后，双击 restore.cmd。\r\n只支持版本和原文件校验值均匹配的安装，不可混用其他版本。\r\n安装脚本会先备份，重复安装不会覆盖原版备份。\r\n`)
  for (const file of ['install.ps1', 'restore.ps1', 'package-common.ps1', 'install.cmd', 'restore.cmd']) artifacts.set(file, fs.readFileSync(path.join(projectRoot, 'scripts', file)))
  artifacts.set('LICENSE', fs.readFileSync(path.join(projectRoot, 'LICENSE')))
  // Generate and validate everything before creating any output file.
  for (const [relative, content] of artifacts) {
    const target = path.join(destination, relative)
    fs.mkdirSync(path.dirname(target), { recursive: true })
    fs.writeFileSync(target, content)
  }
  console.log(`已生成 ${destination}`)
  console.log(`匹配 ${unique} 条文案，替换 ${occurrences} 处；待审核候选 ${report.pendingCandidates.length} 条。`)
  return { destination, manifest, report }
}

function main() {
  if (Number(process.versions.node.split('.')[0]) < 22) throw new Error('需要 Node.js 22 或更高版本。')
  const options = {}
  const args = process.argv.slice(2)
  if (args.includes('--help')) { console.log('node scripts/generate.cjs [--app 安装目录] [--output 输出目录] [--dictionary 词典文件]'); return }
  for (let i=0;i<args.length;i+=2) {
    if (!['--app','--output','--dictionary'].includes(args[i]) || !args[i+1]) throw new Error('参数无效，请使用 --help 查看用法。')
    options[args[i].slice(2)] = args[i+1]
  }
  generate({ app: options.app || path.join(process.env.LOCALAPPDATA || '', 'GitHubDesktop'), output: options.output || path.join(projectRoot,'dist'), dictionaryPath: options.dictionary })
}
if (require.main === module) { try { main() } catch (error) { console.error(`生成失败：${error.message}`); process.exitCode = 1 } }
module.exports = { generate, patch, resolveApp, loadDictionary, compareVersions }
