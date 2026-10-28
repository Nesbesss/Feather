import settings from '../popup/dist/settings.js'

let userId,
    userToken,
    userTokenDate

const settingsToClear = [
    'auto-theme', 'theme-fixed', 'theme-day', 'theme-night', 'openedPopup', 'updates', 'beta', 'magister-shortcuts', 'magister-shortcuts-today', 'magister-sw-grid', 'magister-sw-sort', 'magister-sw-period', 'magister-sw-display', 'magister-ag-large', 'magister-subjects', 'magister-appbar-hidePicture', 'appbar-hide-actions', 'magister-appbar-zermelo', 'magister-appbar-zermelo-url', 'magister-css-border-radius', 'magister-css-dark-invert', 'magister-css-experimental', 'magister-css-hue', 'magister-css-luminance', 'magister-css-saturation', 'magister-css-theme', 'magister-op-oldgrey', 'magister-periods', 'periods', 'magister-shortcut-keys', 'magister-shortcut-keys-master', 'magister-shortcut-keys-today', 'magister-subjects', 'magister-sw-thisWeek', 'magister-vd-overhaul', 'magister-vd-enabled', 'magister-vd-subjects', 'magister-vd-grade', 'magister-vd-agendaHeight', 'magister-vd-deblue', 'magister-vd-gradewidget', 'magisterLogin-password', 'magisterLogin-method', 'magister-gamification-beta', 'gamification-enabled', 'magister-cf-calculator', 'magister-cf-statistics', 'magister-cf-backup', 'magister-cf-failred', 'notes-enabled', 'notes', 'st-notes', 'vd-enabled', 'vd-schedule-days', 'vd-schedule-extra-day', 'vd-schedule-zoom', 'vd-subjects-display', 'start-stats', 'teacher-names', 'version', 'disable-css', 'hotkeys-today', 'start-widgets', 'dark-image', 'light-image', 'subjects', 'hidden-studyguides', 'color', 'start-schedule-days', 'v', 'special', 'sw-cols', 'sw-current-week-behavior', 'sw-enabled', 'sw-list', 'sw-period', 'sw-resources-auto'
]

// Register event listeners synchronously so WebKit can wake this worker for them.
const credentialsReady = initialiseCredentials()
credentialsReady.catch(error => console.error('Unable to initialise Study Tools credentials.', error))
chrome.webRequest.onBeforeSendHeaders.addListener(captureCredentials,
    { urls: ['*://*.magister.net/*'] }, ['requestHeaders'])
setDefaults().catch(error => console.error('Unable to initialise Study Tools settings.', error))

async function initialiseCredentials() {
    // Allow any context to use chrome.storage.session
    await chrome.storage.session.setAccessLevel({ accessLevel: 'TRUSTED_AND_UNTRUSTED_CONTEXTS' })

    // Initialise the three variables
    userId = (await chrome.storage.sync.get('user-id'))?.['user-id'] || null
    userToken = (await chrome.storage.session.get('token'))?.['token'] || null
    userTokenDate = new Date((await chrome.storage.session.get('token-date'))?.['token-date'] || 0)
}

async function captureCredentials(e) {
    await credentialsReady
    // Return if the request was made by Study Tools itself
    const headers = e.requestHeaders || []
    if (headers.find(header => header.name.toLowerCase() === 'x-request-source')?.value === 'study-tools') return

    console.info('Request caught!')

    let userIdWas = userId
    let userTokenWas = userToken
    let userTokenDateWas = userTokenDate

    let urlUserId = e.url.split('/personen/')[1]?.split('/')[0]
    if (urlUserId?.length > 2 && !urlUserId.includes('undefined')) {
        userId = urlUserId || userIdWas
        await chrome.storage.sync.set({ 'user-id': userId })
        if (userIdWas !== userId) console.info(`User ID changed from ${userIdWas} to ${userId}.`)
    }

    let authObject = headers.find(header => header.name.toLowerCase() === 'authorization')
    if (authObject) {
        userToken = authObject.value
        userTokenDate = new Date()
        await chrome.storage.session.set({ 'token': userToken, 'token-date': userTokenDate.getTime() })
        if (userTokenWas !== userToken && new Date(userTokenDateWas).getTime() == 0) console.info(`User token gathered. Length: ${userToken.length}.`)
        else if (userTokenWas !== userToken) console.info(`User token changed since ${userTokenDate - userTokenDateWas} ms ago.`)
    }

}

async function setDefaults() {
    let syncedStorage = await chrome.storage.sync.get()
    let diff = {}

    // Check each setting to see if its value has been defined. If not, set it to the default value.
    settings.forEach(category => {
        category.settings.forEach(setting => {
            if (typeof syncedStorage[setting.id] === 'undefined') {
                if (setting.id === 'wallpaper' && syncedStorage['backdrop']?.length > 5) diff[setting.id] = 'custom,' + syncedStorage['backdrop']
                else diff[setting.id] = setting.default
            }
        })
    })

    if (Object.keys(diff).length > 0) {
        setTimeout(() => chrome.storage.sync.set(diff), 200)
        console.info("Set the following storage.sync keys to their default values:", diff)
    }

    if (settingsToClear.some(key => Object.keys(syncedStorage).includes(key))) {
        chrome.storage.sync.remove(settingsToClear)
        console.info("Redundant storage.sync keys removed to free up space.")
    }
}

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    switch (request.action) {
        case 'popstateDetected':
            console.info("Popstate detected, service worker revived.")
            return 0

        case 'waitForRequestCompleted':
            console.info(`Request completion notification requested by ${sender.url}.`)
            let completed = false
            const finish = response => {
                if (completed) return
                completed = true
                clearTimeout(timeout)
                chrome.webRequest.onCompleted.removeListener(onCompleted)
                sendResponse(response)
            }
            const onCompleted = details => {
                if (details.tabId !== sender.tab?.id) return
                finish({ status: 'completed', details })
            }
            const timeout = setTimeout(() => finish({ status: 'timeout' }), 5000)
            chrome.webRequest.onCompleted.addListener(onCompleted,
                { urls: ['*://*.magister.net/api/personen/*/aanmeldingen/*/cijfers/extracijferkolominfo/*'] })
            return true

        case 'uninstallSelf':
            chrome.management.uninstallSelf({ showConfirmDialog: false }, () => { window.location.reload() })
            break

        case 'openOptions':
            chrome.tabs.create({ url: `popup/dist/index.html?${request.data}` });
            break;

        default:
            return 0
    }
})

chrome.runtime.onMessageExternal.addListener(async (request, sender, sendResponse) => {
    switch (request.action) {
        case 'addPersonalTheme':
            const obj = request.obj
            const storedThemes = Object.values((await chrome.storage.local.get('storedThemes')).storedThemes)
            if (!storedThemes || storedThemes.length >= 9) return

            storedThemes.push(obj)

            //TODO: only if not exist

            await chrome.storage.local.set({ 'storedThemes': storedThemes })
            break

        default:
            return 0
    }
})
