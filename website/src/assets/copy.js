// A button that copies a piece of text and says so for a moment.

/** Says what happened to whoever has the page read out, for whom a button's changed label goes unheard. */
function announce(text) {
    let status = document.querySelector('[data-status]')
    if (!status) {
        status = document.createElement('span')
        status.dataset.status = ''
        status.className = 'visually-hidden'
        status.setAttribute('role', 'status')
        document.body.append(status)
    }
    status.textContent = text
}

/**
 * @param button The button. It keeps its label, except for the moment after it was pressed.
 * @param text What to copy, or a function that works it out when the button is pressed.
 */
export function makeCopyButton(button, text) {
    const label = button.textContent
    let reset
    button.addEventListener('click', async () => {
        try {
            await navigator.clipboard.writeText(typeof text === 'function' ? text() : text)
        } catch {
            // Without permission to write to the clipboard, the button has nothing to say.
            return
        }
        button.textContent = 'Copied'
        button.classList.add('is-copied')
        announce('Copied')
        clearTimeout(reset)
        reset = setTimeout(() => {
            button.textContent = label
            button.classList.remove('is-copied')
            announce('')
        }, 1600)
    })
}
