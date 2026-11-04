import Foundation
import Testing
@testable import Installers

@Suite struct WindowsSetupTests {
    private let setup = WindowsSetup(
        computerName: "WIN-TEST", userName: "saeed", fullName: "Saeed & Co", password: "swiftvm", language: "de-DE",
        authorizedKeys: ["ssh-ed25519 AAAA test"]
    )

    @Test func answersEveryQuestionWindowsSetupWouldAsk() throws {
        let answers = setup.answerFile
        let document = try XMLDocument(xmlString: answers)
        let text = { (path: String) in try document.nodes(forXPath: path).map { $0.stringValue ?? "" } }
        // Arm's components, in the language of the installer.
        #expect(answers.contains("processorArchitecture=\"arm64\""))
        #expect(try text("//*[local-name()='UILanguage']").allSatisfy { $0 == "de-DE" })
        // Windows Pro, which Remote Desktop can reach, without a question about the edition.
        #expect(try text("//*[local-name()='ProductKey']/*[local-name()='Key']") == ["VK7JG-NPHTM-C97JM-9MPGT-3V66T"])
        // The checks that a virtual machine doesn't pass are skipped before they are made.
        for check in ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck", "BypassCPUCheck"] {
            #expect(answers.contains(check))
        }
        // The account, which logs in by itself and then finishes SwiftVM's setup.
        #expect(try text("//*[local-name()='LocalAccount']/*[local-name()='Name']") == ["saeed"])
        #expect(try text("//*[local-name()='LocalAccount']/*[local-name()='DisplayName']") == ["Saeed & Co"])
        #expect(try text("//*[local-name()='AutoLogon']/*[local-name()='Enabled']") == ["true"])
        #expect(try text("//*[local-name()='ComputerName']") == ["WIN-TEST"])
        #expect(try text("//*[local-name()='SynchronousCommand']/*[local-name()='CommandLine']").first?.contains("-Phase firstlogon") == true)
        // The password is never written out.
        #expect(!answers.contains(">swiftvm<"))
    }

    @Test func encodesThePasswordAsWindowsReadsIt() {
        // What Windows' own tools write for the password "swiftvm".
        let expected = Data("swiftvmPassword".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }).base64EncodedString()
        #expect(WindowsSetup.encodedPassword("swiftvm") == expected)
        #expect(WindowsSetup.encodedPassword("swiftvm") == "cwB3AGkAZgB0AHYAbQBQAGEAcwBzAHcAbwByAGQA")
    }

    @Test func takesOnlyNamesWindowsTakesForAccounts() {
        #expect(WindowsSetup.problem(withUserName: "saeed") == nil)
        #expect(WindowsSetup.problem(withUserName: "Saeed Vaziry") == nil)
        #expect(WindowsSetup.problem(withUserName: "") != nil)
        #expect(WindowsSetup.problem(withUserName: "a/b") != nil)
        #expect(WindowsSetup.problem(withUserName: "Administrator") != nil)
        #expect(WindowsSetup.problem(withUserName: String(repeating: "a", count: 21)) != nil)
        #expect(WindowsSetup.problem(withPassword: "") != nil)
    }

    @Test func makesAComputerNameOfAnyName() {
        #expect(WindowsSetup.computerName(from: "windows-11") == "WINDOWS-11")
        #expect(WindowsSetup.computerName(from: "my very long machine name") == "MY-VERY-LONG-MA")
        #expect(WindowsSetup.computerName(from: "1234") == "WINDOWS-1234")
        #expect(WindowsSetup.computerName(from: "ünïcode") == "N-CODE")
    }

    @Test func putsTheSetupNextToTheAnswerFileOnItsDisc() throws {
        let files = try WindowsGuestAgent.setupFiles()
        #expect(Set(files.keys) == ["setup.ps1", "install.ps1", "swiftvm-agent.cs"])
        // Windows' own tools read what is written for them with Windows' line breaks.
        let runner = String(decoding: try #require(files["setup.ps1"]), as: UTF8.self)
        #expect(runner.contains("\r\n"))
        #expect(!runner.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }
}

@Suite struct WindowsInstallerTests {
    @Test func readsTheLanguageTheDiscInstalls() {
        let list = "\r\n[Available UI Languages]\r\nen-us = 3\r\n\r\n[Fallback Languages]\r\nen-us = en-us\r\n"
        #expect(WindowsInstaller.language(inLanguageList: list) == "en-US")
        #expect(WindowsInstaller.language(inLanguageList: "[Available UI Languages]\nsr-latn-rs = 3\n") == "sr-Latn-RS")
        #expect(WindowsInstaller.language(inLanguageList: "[Fallback Languages]\nen-us = en-us\n") == nil)
    }
}

@Suite struct WindowsDownloadsTests {
    @Test func findsTheEditionOnMicrosoftsPage() {
        let page = #"<select id="product-edition"><option value="" selected>Select</option><option value="3816">Windows 11 (multi-edition ISO for Arm64)</option></select>"#
        #expect(WindowsDownloads.productEdition(inPage: page) == "3816")
        #expect(WindowsDownloads.productEdition(inPage: "<html></html>") == nil)
    }

    @Test func goesWhereThePagesFingerprintScriptWouldSendABrowser() throws {
        let script = #"window.dfp={url:"https://ov-df.microsoft.com/?session_id=abc&CustomerId=x&PageId=si&w=8DF2",sessionId:"abc"};src+="&rticks="+1791976566263;"#
        let address = try #require(WindowsDownloads.fingerprintAddress(inScript: script, now: Date(timeIntervalSince1970: 1)))
        #expect(address.absoluteString == "https://ov-df.microsoft.com/?session_id=abc&CustomerId=x&PageId=si&w=8DF2&mdt=1000&rticks=1791976566263")
    }

    @Test func picksTheLanguageOfTheMac() {
        let offered = ["Arabic", "English", "English (United Kingdom)", "German", "French Canadian", "French", "Portuguese", "Brazilian Portuguese"]
        #expect(WindowsDownloads.skuLanguage(for: ["de-DE"], available: offered) == "German")
        #expect(WindowsDownloads.skuLanguage(for: ["en-GB"], available: offered) == "English (United Kingdom)")
        #expect(WindowsDownloads.skuLanguage(for: ["en-US"], available: offered) == "English")
        #expect(WindowsDownloads.skuLanguage(for: ["fr-CA"], available: offered) == "French Canadian")
        #expect(WindowsDownloads.skuLanguage(for: ["pt-BR"], available: offered) == "Brazilian Portuguese")
        #expect(WindowsDownloads.skuLanguage(for: ["kl-GL"], available: offered) == "English")
    }
}
