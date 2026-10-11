// The menu bar panel in the landing page's hero: what it lists and what it says about each machine,
// worked out the way App/MenuBar/MachineListing.swift does it. The build renders the first state into
// the page with this file and home.js renders every state after it, so the two can't drift apart.

export const appName = 'SwiftVM'

/** The machines the hero starts with: the two in the screenshot it is made after. */
export function initialMachines() {
    return [
        {
            id: 'macos-27',
            name: 'macOS 27',
            os: 'macos',
            family: 'macOS',
            state: 'running',
            address: '192.168.231.10',
            hardware: '4 CPU · 8 GB RAM',
            summary: 'macOS 27.0',
        },
        {
            id: 'ubuntu-26-04',
            name: 'Ubuntu 26.04',
            os: 'ubuntu',
            family: 'Linux',
            state: 'stopped',
            address: '192.168.231.11',
            hardware: '4 CPU · 4 GB RAM',
            summary: 'Ubuntu 26.04.1 LTS',
        },
    ]
}

/** The systems the filter offers, as `GuestFamily` lists them. */
export const families = ['macOS', 'Linux', 'Windows']

export const sortOrders = { created: 'Date Created', name: 'Name' }

const stateLabels = {
    stopped: 'Stopped',
    starting: 'Starting',
    running: 'Running',
    paused: 'Paused',
    suspending: 'Suspending',
    suspended: 'Suspended',
    restoring: 'Resuming',
    stopping: 'Shutting Down',
}

/** The machine holds a guest: running, paused, or on its way to or from that. */
export function isActive(state) {
    return state !== 'stopped' && state !== 'suspended'
}

/** On its way from one state to the next. */
export function isTransitioning(state) {
    return state === 'starting' || state === 'suspending' || state === 'restoring' || state === 'stopping'
}

/** The panel's second line: `2 of 5 running`. */
export function headline(machines) {
    const total = machines.length
    const running = machines.filter((machine) => isActive(machine.state)).length
    if (total === 0) return 'No virtual machines'
    if (running === 0) return total === 1 ? '1 virtual machine' : `${total} virtual machines`
    return `${running} of ${total} running`
}

/** The line under a machine's name: what it is busy with, where a running guest is reached, or what a stopped one is made of. */
export function statusLine(machine) {
    const label = stateLabels[machine.state]
    if (isTransitioning(machine.state)) return `${label}…`
    switch (machine.state) {
        case 'running':
            return machine.address
        case 'paused':
            return `${label} · ${machine.address}`
        case 'suspended':
            return `${label} · ${machine.hardware}`
        default:
            return `${machine.hardware} · ${machine.summary}`
    }
}

/** The machines of the panel's two groups, in the order and with the filter the "…" menu at the top sets. */
export function groups(machines, { sortOrder = 'created', filter = null } = {}) {
    const shown = machines.filter((machine) => !filter || machine.family === filter)
    if (sortOrder === 'name') {
        shown.sort((a, b) => a.name.localeCompare(b.name, 'en', { numeric: true, sensitivity: 'base' }))
    }
    return {
        running: shown.filter((machine) => isActive(machine.state)),
        notRunning: shown.filter((machine) => !isActive(machine.state)),
    }
}

/**
 * The actions in a machine's "…" menu, as App/MenuBar/MachineMenu.swift lists them. `null` is a
 * separator. An item without an action is one the page has nothing to show for.
 */
export function machineMenu(machine) {
    const item = (label, action = null, disabled = false) => ({ label, action, disabled })
    const { state } = machine
    const power = {
        stopped: [item('Start', 'start'), ...(machine.family === 'macOS' ? [item('Start in Recovery')] : [])],
        suspended: [item('Resume', 'start'), item('Discard Saved State', 'discard-state')],
        running: [
            item('Suspend', 'suspend'),
            item('Pause', 'pause'),
            item('Restart', 'restart'),
            item('Shut Down', 'shut-down'),
            item('Force Stop', 'force-stop'),
        ],
        paused: [item('Resume', 'resume'), item('Suspend', 'suspend'), item('Force Stop', 'force-stop')],
        stopping: [item('Force Stop', 'force-stop')],
    }
    const hasAddress = state === 'running' || state === 'paused'
    return [
        ...(power[state] ?? [item(`${stateLabels[state]}…`, null, true)]),
        null,
        item('Open Window'),
        item('Settings…'),
        item('Snapshots…'),
        item('Duplicate', null, state !== 'stopped'),
        null,
        item('Copy SSH Command'),
        item('Open in Terminal', null, state !== 'running'),
        item('Copy IP Address', null, !hasAddress),
        null,
        item('Show in Finder'),
        item('Delete…', 'delete', isActive(state)),
    ]
}

/** The "…" menu at the top of the panel: how the list is sorted and which systems it shows. */
export function appMenu({ sortOrder = 'created', filter = null } = {}) {
    const choice = (label, action, value, checked) => ({ label, action, value, checked })
    return [
        { heading: 'Sort By' },
        ...Object.entries(sortOrders).map(([value, label]) => choice(label, 'sort', value, sortOrder === value)),
        { heading: 'Show' },
        choice('All Systems', 'filter', '', filter === null),
        ...families.map((family) => choice(family, 'filter', family, filter === family)),
        null,
        { label: 'Check for Updates…', action: null },
        { label: `About ${appName}`, action: null },
    ]
}

// MARK: Markup

const escapes = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }

export function escapeHTML(text) {
    return String(text).replace(/[&<>"]/g, (character) => escapes[character])
}

/** One of the symbols the page defines once, in home.html. */
function symbol(name) {
    return `<svg class="pn-symbol" aria-hidden="true" focusable="false"><use href="#symbol-${name}"/></svg>`
}

function symbolButton(action, symbolName, help, label, attributes = '') {
    return `<button type="button" class="pn-button" data-action="${action}" title="${escapeHTML(help)}" aria-label="${escapeHTML(label)}"${attributes}>${symbol(symbolName)}</button>`
}

/** A machine's tile: in the system's colour while it holds a guest, without colour while it doesn't. */
function badge(os, isLit, isPulsing = false) {
    const glyph = os === 'macos' ? 'apple' : 'terminal'
    return `<span class="pn-badge pn-badge-${os}${isLit ? ' is-lit' : ''}${isPulsing ? ' is-pulsing' : ''}">${symbol(glyph)}</span>`
}

function progress(label) {
    return `<span class="pn-spinner" role="img" aria-label="${escapeHTML(label)}" title="${escapeHTML(label)}">${symbol('spinner')}</span>`
}

function primaryControl(machine) {
    const button = (action, symbolName, label) => symbolButton(action, symbolName, label, `${label} ${machine.name}`)
    switch (machine.state) {
        case 'stopped':
            return button('start', 'play', 'Start')
        case 'suspended':
            return button('start', 'play', 'Resume')
        case 'paused':
            return button('resume', 'play', 'Resume')
        case 'running':
            return button('suspend', 'pause', 'Suspend')
        default:
            return progress(stateLabels[machine.state])
    }
}

function machineRow(machine) {
    const active = isActive(machine.state)
    return `<div class="pn-row" data-id="${machine.id}" data-state="${machine.state}">
    ${badge(machine.os, active, isTransitioning(machine.state))}
    <span class="pn-text"><span class="pn-name">${escapeHTML(machine.name)}</span><span class="pn-status">${escapeHTML(statusLine(machine))}</span></span>
    <span class="pn-controls">${primaryControl(machine)}${
        active ? symbolButton('open', 'window', 'Open window', `Open the window of ${machine.name}`) : ''
    }${symbolButton('menu', 'ellipsis', 'More actions', `More actions for ${machine.name}`, ' aria-haspopup="menu" aria-expanded="false"')}</span>
</div>`
}

/** Asked in the row itself, as the app does. */
function deletionQuestion(machine) {
    return `<div class="pn-card" data-id="${machine.id}" role="group" aria-label="Delete ${escapeHTML(machine.name)}?">
    <span class="pn-card-title">Delete “${escapeHTML(machine.name)}”?</span>
    <span class="pn-card-text">The virtual machine and its disks are moved to the Trash.</span>
    <span class="pn-card-buttons"><button type="button" class="pn-push" data-action="cancel-delete">Cancel</button><button type="button" class="pn-push is-destructive" data-action="confirm-delete">Move to Trash</button></span>
</div>`
}

/** A machine that is still being created, with its progress. */
function creationRow(creation) {
    // Without a fraction the step takes as long as it takes, and the bar says so by not standing still.
    const isMeasured = creation.fraction != null
    const percent = isMeasured ? Math.round(creation.fraction * 100) : 100
    const status = isMeasured ? `${creation.status} ${percent}%` : creation.status
    return `<div class="pn-row is-creating" data-id="${creation.id}">
    ${badge(creation.os, false)}
    <span class="pn-text"><span class="pn-name">${escapeHTML(creation.name)}</span><span class="pn-status" data-creation-status>${escapeHTML(status)}</span><span class="pn-progress${isMeasured ? '' : ' is-indeterminate'}" role="progressbar" aria-label="${escapeHTML(creation.status)}"${isMeasured ? ` aria-valuemin="0" aria-valuemax="100" aria-valuenow="${percent}"` : ''}><span data-creation-bar style="width: ${percent}%"></span></span></span>
    <span class="pn-controls">${symbolButton('cancel-creation', 'xmark', 'Cancel', `Cancel creating ${creation.name}`)}</span>
</div>`
}

const emptyState = `<div class="pn-empty">
    <svg class="pn-empty-symbol" aria-hidden="true" focusable="false"><use href="#symbol-windows"/></svg>
    <span class="pn-empty-title">No Virtual Machines</span>
    <span class="pn-empty-text">Create a virtual machine to run macOS, Linux or Windows on this Mac.</span>
    <button type="button" class="pn-push is-prominent" data-action="new">New Virtual Machine…</button>
</div>`

const noMatch = `<div class="pn-empty is-compact">
    <span class="pn-empty-text">No virtual machine matches the filter.</span>
    <button type="button" class="pn-push" data-action="filter" data-value="">Show All Systems</button>
</div>`

/**
 * The panel's list: the running machines, then the ones that aren't and the ones being created.
 *
 * @param model `{ machines, creations, sortOrder, filter, askingToDelete }`, of which only `machines` is required.
 */
export function renderList(model) {
    const { machines, creations = [], askingToDelete = null } = model
    if (machines.length === 0 && creations.length === 0) return emptyState

    const { running, notRunning } = groups(machines, model)
    const row = (machine) => (machine.id === askingToDelete ? deletionQuestion(machine) : machineRow(machine))
    const section = (title) => `<div class="pn-section">${title}</div>`
    const parts = []
    if (running.length > 0) parts.push(section('Running'), ...running.map(row))
    if (notRunning.length > 0 || creations.length > 0) {
        parts.push(section('Not Running'), ...notRunning.map(row), ...creations.map(creationRow))
    }
    return parts.length > 0 ? parts.join('\n') : noMatch
}

/** A menu that drops down from one of the panel's "…" buttons. */
export function renderMenu(items, label) {
    const rows = items.map((item) => {
        if (item === null) return '<div class="pn-menu-separator" role="separator"></div>'
        if (item.heading) return `<div class="pn-menu-heading">${escapeHTML(item.heading)}</div>`
        const isChoice = item.checked !== undefined
        const attributes = [
            `role="${isChoice ? 'menuitemradio' : 'menuitem'}"`,
            isChoice ? `aria-checked="${item.checked}"` : '',
            item.action ? `data-action="${item.action}"` : 'data-action="dismiss"',
            item.value !== undefined ? `data-value="${escapeHTML(item.value)}"` : '',
            item.disabled ? 'disabled' : '',
        ]
        return `<button type="button" class="pn-menu-item" ${attributes.filter(Boolean).join(' ')}>${escapeHTML(item.label)}</button>`
    })
    return `<div class="pn-menu" role="menu" aria-label="${escapeHTML(label)}">${rows.join('')}</div>`
}
