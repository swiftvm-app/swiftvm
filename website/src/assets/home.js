// What makes the landing page's hero work: its panel behaves like the app's, with machines that start,
// suspend and shut down, and the sky follows the pointer. Without this script the hero is a still.

import { startAppearanceButtons } from './appearance.js'
import { makeCopyButton } from './copy.js'
import { appMenu, appName, headline, initialMachines, isActive, machineMenu, renderList, renderMenu } from './panel.js'

for (const button of document.querySelectorAll('[data-copy]')) {
    makeCopyButton(button, button.dataset.copy)
}
startAppearanceButtons()

const hero = document.querySelector('[data-hero]')
if (hero) {
    startPanel(hero)
    startSky(hero)
    startClock(hero.querySelector('[data-clock]'))
}

/** How long a machine is on its way from one state to the next. Far shorter than a real one takes. */
const duration = { starting: 1500, restoring: 1100, suspending: 1100, stopping: 1300 }

/** What "+" creates, the first that isn't there yet. */
const catalogue = [
    { name: 'Debian 13', os: 'debian', family: 'Linux', hardware: '4 CPU · 4 GB RAM', summary: 'Debian GNU/Linux 13 (trixie)' },
    { name: 'Ubuntu 24.04', os: 'ubuntu', family: 'Linux', hardware: '4 CPU · 4 GB RAM', summary: 'Ubuntu 24.04.4 LTS' },
    ...initialMachines(),
]

/** More machines than this don't fit the hero. */
const maximumMachines = 4

function startPanel(hero) {
    const panel = hero.querySelector('[data-panel]')
    const list = panel.querySelector('[data-panel-list]')
    const headlineLabel = panel.querySelector('[data-panel-headline]')
    const toggle = hero.querySelector('[data-panel-toggle]')
    const newButton = panel.querySelector('.pn-header [data-action="new"]')
    const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)')

    const model = { machines: initialMachines(), creations: [], sortOrder: 'created', filter: null, askingToDelete: null }
    /** What each machine does next, by its id. */
    const timers = new Map()
    let nextAddress = 12
    let openMenu = null
    /** Something changed while a menu was open, and the list waits for the menu to close to show it. */
    let isStale = false

    const machine = (id) => model.machines.find((candidate) => candidate.id === id)

    // MARK: Drawing

    /** Draws the list again, and moves what was there before to its new place instead of jumping. */
    function render() {
        // A menu is part of the row it dropped from, and drawing the list again would take it away under
        // the pointer. Nothing waits long: every action that changes the list closes the menu first.
        if (openMenu) {
            isStale = true
            return
        }
        isStale = false
        const scale = Number(getComputedStyle(hero).getPropertyValue('--scale')) || 1
        const before = new Map([...list.querySelectorAll('[data-id]')].map((element) => [element.dataset.id, element.getBoundingClientRect()]))
        const heightBefore = list.getBoundingClientRect().height
        const focused = list.contains(document.activeElement) ? document.activeElement : null
        const focus = focused && { id: focused.closest('[data-id]')?.dataset.id, action: focused.dataset.action }

        list.innerHTML = renderList(model)
        headlineLabel.textContent = headline(model.machines)
        toggle.setAttribute('aria-label', `${appName}: ${headline(model.machines)}`)
        newButton.disabled = !nextToCreate()

        if (focus) {
            const row = list.querySelector(`[data-id="${focus.id}"]`)
            // Where it was, or as near to it as is left: in its row, in the list, at the head of the panel.
            const target = row?.querySelector(`[data-action="${focus.action}"]`) ?? row?.querySelector('button') ?? list.querySelector('button') ?? newButton
            target.focus()
        }
        if (reducedMotion.matches) return

        const timing = { duration: 320, easing: 'cubic-bezier(0.2, 0.8, 0.2, 1)' }
        for (const element of list.querySelectorAll('[data-id]')) {
            const from = before.get(element.dataset.id)
            if (!from) {
                element.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 240, easing: 'ease-out' })
                continue
            }
            const offset = (from.top - element.getBoundingClientRect().top) / scale
            if (Math.abs(offset) > 0.5) {
                element.animate([{ transform: `translateY(${offset}px)` }, { transform: 'none' }], timing)
            }
        }
        const heightAfter = list.getBoundingClientRect().height
        if (Math.abs(heightAfter - heightBefore) > 0.5) {
            list.classList.add('is-resizing')
            const resize = list.animate([{ height: `${heightBefore / scale}px` }, { height: `${heightAfter / scale}px` }], timing)
            resize.finished.then(() => list.classList.remove('is-resizing')).catch(() => {})
        }
    }

    // MARK: Machines

    /** Puts a machine into a state and, if that state is on the way to another, into that one in time. */
    function enter(id, state, then) {
        clearTimeout(timers.get(id))
        const target = machine(id)
        if (!target) return
        target.state = state
        if (model.askingToDelete === id && isActive(state)) model.askingToDelete = null
        render()
        if (then) timers.set(id, setTimeout(then, duration[state]))
    }

    const power = {
        start: (id) => enter(id, machine(id).state === 'suspended' ? 'restoring' : 'starting', () => enter(id, 'running')),
        suspend: (id) => enter(id, 'suspending', () => enter(id, 'suspended')),
        'shut-down': (id) => enter(id, 'stopping', () => enter(id, 'stopped')),
        restart: (id) => enter(id, 'stopping', () => power.start(id)),
        'force-stop': (id) => enter(id, 'stopped'),
        'discard-state': (id) => enter(id, 'stopped'),
        pause: (id) => enter(id, 'paused'),
        resume: (id) => enter(id, 'running'),
    }

    /** What "+" would create: the first of the catalogue that isn't there, while there is room for one more. */
    function nextToCreate() {
        const taken = new Set([...model.machines, ...model.creations].map((existing) => existing.name))
        return taken.size < maximumMachines ? catalogue.find((candidate) => !taken.has(candidate.name)) : undefined
    }

    /** Creates the next machine of the catalogue the way Quick Create does: a download, then a machine that starts. */
    function create() {
        const next = nextToCreate()
        if (!next) return

        const id = `created-${Date.now()}`
        const creation = { ...next, id, status: `Downloading ${next.name}…`, fraction: 0 }
        model.creations.push(creation)
        model.filter = null
        render()

        const started = performance.now()
        const download = 2400
        const tick = () => {
            const row = list.querySelector(`[data-id="${id}"]`)
            if (!model.creations.includes(creation)) return
            creation.fraction = Math.min((performance.now() - started) / download, 1)
            if (creation.fraction < 1) {
                const percent = Math.round(creation.fraction * 100)
                // Only the row's own progress, so that the pointer keeps what it is over.
                if (row) {
                    row.querySelector('[data-creation-status]').textContent = `${creation.status} ${percent}%`
                    row.querySelector('[data-creation-bar]').style.width = `${percent}%`
                    row.querySelector('[role="progressbar"]').setAttribute('aria-valuenow', percent)
                }
                timers.set(id, setTimeout(tick, 60))
                return
            }
            Object.assign(creation, { status: 'Preparing disk…', fraction: null })
            render()
            timers.set(
                id,
                setTimeout(() => {
                    model.creations.splice(model.creations.indexOf(creation), 1)
                    const { status, fraction, ...created } = creation
                    model.machines.push({ ...created, state: 'stopped', address: `192.168.231.${nextAddress++}` })
                    power.start(id)
                }, 700),
            )
        }
        tick()
    }

    // MARK: Menus

    function closeMenu({ restoreFocus = false } = {}) {
        if (!openMenu) return
        const { menu, button } = openMenu
        openMenu = null
        menu.remove()
        button.setAttribute('aria-expanded', 'false')
        if (restoreFocus) button.focus()
        if (isStale) render()
    }

    function showMenu(button, items, label, { byKeyboard }) {
        const wasOpenHere = openMenu?.button === button
        closeMenu()
        if (wasOpenHere) return

        button.insertAdjacentHTML('afterend', renderMenu(items, label))
        const menu = button.nextElementSibling
        // Upwards where there is no room below but some above the button, as a menu at the foot of the screen opens.
        const bounds = menu.getBoundingClientRect()
        if (bounds.bottom > innerHeight - 8 && button.getBoundingClientRect().top - bounds.height > 8) menu.classList.add('opens-up')
        button.setAttribute('aria-expanded', 'true')
        openMenu = { menu, button }
        if (byKeyboard) menu.querySelector('.pn-menu-item:not(:disabled)')?.focus()
    }

    function moveInMenu(key) {
        const items = [...openMenu.menu.querySelectorAll('.pn-menu-item:not(:disabled)')]
        // With the pointer having opened the menu, no item has the keyboard yet: up starts at the foot.
        const index = items.indexOf(document.activeElement)
        const next = { ArrowDown: index + 1, ArrowUp: index < 0 ? items.length - 1 : index - 1, Home: 0, End: items.length - 1 }[key]
        items[(next + items.length) % items.length]?.focus()
    }

    // MARK: Panel

    function setOpen(isOpen) {
        closeMenu()
        // Focus doesn't stay behind in a panel that is put away.
        if (!isOpen && panel.contains(document.activeElement)) toggle.focus()
        hero.dataset.panelState = isOpen ? 'open' : 'closed'
        toggle.setAttribute('aria-expanded', String(isOpen))
        panel.inert = !isOpen
    }

    const actions = {
        ...power,
        new: () => create(),
        close: () => setOpen(false),
        dismiss: () => {},
        // The app shows the machine's window, which the page doesn't have.
        open: () => {},
        sort: (id, value) => {
            model.sortOrder = value
            render()
        },
        filter: (id, value) => {
            model.filter = value || null
            render()
        },
        delete: (id) => {
            model.askingToDelete = id
            render()
            list.querySelector('[data-action="cancel-delete"]')?.focus()
        },
        'cancel-delete': () => {
            model.askingToDelete = null
            render()
        },
        'confirm-delete': (id) => {
            clearTimeout(timers.get(id))
            model.machines = model.machines.filter((candidate) => candidate.id !== id)
            model.askingToDelete = null
            render()
        },
        'cancel-creation': (id) => {
            clearTimeout(timers.get(id))
            model.creations = model.creations.filter((creation) => creation.id !== id)
            render()
        },
    }

    panel.addEventListener('click', (event) => {
        const button = event.target.closest('[data-action]')
        if (!button || button.disabled) return
        const { action, value } = button.dataset
        const id = button.closest('[data-id]')?.dataset.id
        // A click that the keyboard made has no place on the screen.
        const byKeyboard = event.detail === 0

        if (action === 'menu') return showMenu(button, machineMenu(machine(id)), button.getAttribute('aria-label'), { byKeyboard })
        if (action === 'app-menu') return showMenu(button, appMenu(model), button.getAttribute('aria-label'), { byKeyboard })

        const fromMenu = Boolean(button.closest('.pn-menu'))
        if (fromMenu) closeMenu({ restoreFocus: byKeyboard })
        actions[action]?.(id, value)
    })

    toggle.addEventListener('click', () => setOpen(hero.dataset.panelState !== 'open'))

    document.addEventListener('pointerdown', (event) => {
        if (openMenu && !openMenu.menu.contains(event.target) && !openMenu.button.contains(event.target)) closeMenu()
    })

    document.addEventListener('keydown', (event) => {
        if (openMenu && ['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
            event.preventDefault()
            moveInMenu(event.key)
        } else if (event.key === 'Escape' && openMenu) {
            closeMenu({ restoreFocus: true })
        } else if (event.key === 'Escape' && model.askingToDelete) {
            actions['cancel-delete']()
        } else if (event.key === 'Tab' && openMenu) {
            closeMenu()
        }
    })
}

/** The stars drift a little against the pointer, the near ones more than the far ones. */
function startSky(hero) {
    const sky = hero.querySelector('.sky')
    if (!matchMedia('(hover: hover) and (prefers-reduced-motion: no-preference)').matches) return

    let frame = null
    hero.addEventListener('pointermove', (event) => {
        if (frame) return
        frame = requestAnimationFrame(() => {
            frame = null
            const bounds = hero.getBoundingClientRect()
            sky.style.setProperty('--pointer-x', ((event.clientX - bounds.left) / bounds.width - 0.5).toFixed(3))
            sky.style.setProperty('--pointer-y', ((event.clientY - bounds.top) / bounds.height - 0.5).toFixed(3))
        })
    })
}

/** The menu bar's clock: the visitor's own time, written the way macOS writes it. */
function startClock(clock) {
    if (!clock) return
    const date = new Intl.DateTimeFormat('en-US', { weekday: 'short', month: 'short', day: 'numeric' })
    const time = new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit' })
    const show = () => {
        const now = new Date()
        clock.textContent = `${date.format(now).replace(',', '')} ${time.format(now)}`
        // Again when the minute is over.
        setTimeout(show, (60 - now.getSeconds()) * 1000 + 50)
    }
    show()
}
