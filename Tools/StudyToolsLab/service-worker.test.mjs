import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import vm from 'node:vm'
import test from 'node:test'

const resourceRoot = new URL('../../Feather/Resources/StudyTools/', import.meta.url)
const source = (await fs.readFile(new URL('src/service-worker.js', resourceRoot), 'utf8'))
    .replace(/^import settings from .*$/m, 'const settings = []')

function event() {
    const listeners = new Set()
    return {
        listeners,
        addListener(listener) { listeners.add(listener) },
        removeListener(listener) { listeners.delete(listener) },
    }
}

function storageArea(initial = {}) {
    const values = { ...initial }
    return {
        values,
        async get(keys) {
            if (keys == null) return { ...values }
            return Object.fromEntries((Array.isArray(keys) ? keys : [keys])
                .filter(key => Object.hasOwn(values, key)).map(key => [key, values[key]]))
        },
        async set(entries) { Object.assign(values, entries) },
        async remove(keys) { for (const key of keys) delete values[key] },
    }
}

function createWorker() {
    let releaseAccess
    let accessOptions
    const access = new Promise(resolve => { releaseAccess = resolve })
    const timers = new Map()
    let nextTimer = 1
    const chrome = {
        storage: {
            sync: storageArea(),
            local: storageArea(),
            session: {
                ...storageArea(),
                async setAccessLevel(options) {
                    accessOptions = options
                    await access
                },
            },
        },
        webRequest: { onBeforeSendHeaders: event(), onCompleted: event() },
        runtime: { onMessage: event(), onMessageExternal: event() },
    }
    vm.runInNewContext(source, {
        chrome,
        console: { info() {}, warn() {}, error() {} },
        setTimeout(callback) {
            const identifier = nextTimer++
            timers.set(identifier, callback)
            return identifier
        },
        clearTimeout(identifier) { timers.delete(identifier) },
    })
    return { chrome, releaseAccess, timers, get accessOptions() { return accessOptions } }
}

test('registers before storage readiness and captures case-insensitive headers in session storage', async () => {
    const worker = createWorker()
    const { chrome } = worker
    assert.equal(chrome.webRequest.onBeforeSendHeaders.listeners.size, 1)
    assert.equal(worker.accessOptions.accessLevel, 'TRUSTED_AND_UNTRUSTED_CONTEXTS')
    const listener = [...chrome.webRequest.onBeforeSendHeaders.listeners][0]
    const pending = listener({
        url: 'https://school.magister.net/api/personen/12345/afspraken',
        requestHeaders: [{ name: 'authorization', value: 'Bearer TEST-ONLY-TOKEN' }],
    })
    assert.equal(chrome.storage.session.values.token, undefined)
    worker.releaseAccess()
    await pending
    assert.equal(chrome.storage.sync.values['user-id'], '12345')
    assert.equal(chrome.storage.session.values.token, 'Bearer TEST-ONLY-TOKEN')
    assert.equal(typeof chrome.storage.session.values['token-date'], 'number')
    assert.equal(chrome.storage.local.values.token, undefined)
    assert.equal(chrome.storage.sync.values.token, undefined)
    await listener({
        url: 'https://school.magister.net/api/personen/98765/afspraken',
        requestHeaders: [
            { name: 'x-request-source', value: 'study-tools' },
            { name: 'authorization', value: 'Bearer IGNORE-TEST-TOKEN' },
        ],
    })
    assert.equal(chrome.storage.sync.values['user-id'], '12345')
    assert.equal(chrome.storage.session.values.token, 'Bearer TEST-ONLY-TOKEN')
    await listener({ url: 'https://school.magister.net/api/overig' })
})

test('request completion answers only its tab and removes the listener and timer', () => {
    const { chrome, timers, releaseAccess } = createWorker()
    releaseAccess()
    const replies = []
    const receiveMessage = [...chrome.runtime.onMessage.listeners][0]
    const result = receiveMessage({ action: 'waitForRequestCompleted' },
        { url: 'https://school.magister.net/magister/', tab: { id: 7 } },
        response => replies.push(response))
    assert.equal(result, true)
    const completion = [...chrome.webRequest.onCompleted.listeners][0]
    completion({ tabId: 8, requestId: 'unrelated' })
    assert.equal(replies.length, 0)
    completion({ tabId: 7, requestId: 'expected' })
    assert.equal(replies.length, 1)
    assert.equal(replies[0].status, 'completed')
    assert.equal(replies[0].details.requestId, 'expected')
    assert.equal(chrome.webRequest.onCompleted.listeners.size, 0)
    assert.equal(timers.size, 0)
    completion({ tabId: 7, requestId: 'duplicate' })
    assert.equal(replies.length, 1)
})

test('request completion times out once and removes its listener', () => {
    const { chrome, timers, releaseAccess } = createWorker()
    releaseAccess()
    const replies = []
    const receiveMessage = [...chrome.runtime.onMessage.listeners][0]
    receiveMessage({ action: 'waitForRequestCompleted' },
        { url: 'https://school.magister.net/magister/', tab: { id: 7 } },
        response => replies.push(response))
    const timeout = [...timers.values()][0]
    timeout()
    timeout()
    assert.equal(replies.length, 1)
    assert.equal(replies[0].status, 'timeout')
    assert.equal(chrome.webRequest.onCompleted.listeners.size, 0)
    assert.equal(timers.size, 0)
})

test('every declared runtime file is bundled', async () => {
    const manifest = JSON.parse(await fs.readFile(new URL('manifest.json', resourceRoot), 'utf8'))
    const paths = new Set([
        manifest.background.service_worker,
        manifest.action.default_popup.split('?')[0],
        manifest.options_ui.page.split('?')[0],
        ...Object.values(manifest.icons),
        ...manifest.content_scripts.flatMap(script => [...(script.js || []), ...(script.css || [])]),
        ...manifest.web_accessible_resources.flatMap(resources => resources.resources),
    ])
    await Promise.all([...paths].map(path => fs.access(new URL(path, resourceRoot))))
})
