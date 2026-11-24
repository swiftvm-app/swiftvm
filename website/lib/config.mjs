// What the pages say about the site itself. Everything else comes from docs/.
export const site = {
    name: 'SwiftVM',
    url: 'https://swiftvm.app',
    tagline: 'macOS, Linux, and Windows virtual machines in your menu bar',
    description:
        'Native macOS app for running macOS, Linux, and Windows 11 for Arm virtual machines.',
    requirements: 'macOS 27 or newer, on Apple silicon',
    repository: 'https://github.com/swiftvm-app/swiftvm',
    branch: 'main',
    download: 'https://github.com/swiftvm-app/swiftvm/releases/latest',
    brew: 'brew install --cask swiftvm-app/tap/swiftvm',
    // svm, the command line that runs Linux machines without the app, on macOS and Linux.
    svmRepository: 'https://github.com/swiftvm-app/cli',
    svmInstall: 'curl -fsSL https://github.com/swiftvm-app/cli/releases/latest/download/install.sh | sh',
}
