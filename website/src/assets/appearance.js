// The appearance the page is shown in: the system's, unless the visitor chose the other one. The choice
// is kept, and the page's first lines put it back before anything is drawn (see lib/templates.mjs).

const root = document.documentElement
const system = matchMedia('(prefers-color-scheme: dark)')

export function isDark() {
    return (root.dataset.theme ?? (system.matches ? 'dark' : 'light')) === 'dark'
}

/** Calls `listener` whenever the page turns light or dark, whoever turned it. */
export function onAppearanceChange(listener) {
    system.addEventListener('change', listener)
    document.addEventListener('appearancechange', listener)
}

function choose(dark) {
    // Choosing what the system shows anyway is going back to following the system.
    const choice = dark === system.matches ? null : dark ? 'dark' : 'light'
    if (choice) root.dataset.theme = choice
    else delete root.dataset.theme
    try {
        if (choice) localStorage.setItem('appearance', choice)
        else localStorage.removeItem('appearance')
    } catch {
        // Without storage, the choice lasts as long as the page.
    }
    document.dispatchEvent(new Event('appearancechange'))
}

/** Makes the buttons that turn the page light or dark work, and shows them. */
export function startAppearanceButtons() {
    const buttons = [...document.querySelectorAll('[data-appearance]')]
    const describe = () => {
        const label = `Switch to the ${isDark() ? 'light' : 'dark'} appearance`
        for (const button of buttons) {
            button.setAttribute('aria-label', label)
            button.title = label
        }
    }
    for (const button of buttons) {
        button.hidden = false
        button.addEventListener('click', () => choose(!isDark()))
    }
    onAppearanceChange(describe)
    describe()
}
