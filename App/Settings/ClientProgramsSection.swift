import SwiftUI
import VMControl

/// The programs that asked to use SwiftVM through `swiftvm serve`, and what was answered. Removing one
/// has it asked about again the next time it connects.
struct ClientProgramsSection: View {
    @State private var programs: [ServiceAnswer.ClientProgram] = []
    @State private var problem: String?

    var body: some View {
        Section {
            if programs.isEmpty {
                Text("No program has asked yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(programs) { program in
                LabeledContent {
                    Button("Remove") { change("clients-remove", program: program.path) }
                } label: {
                    Text("\(program.name): \(program.allowed ? "allowed" : "not allowed")")
                    Text(program.path)
                }
            }
        } header: {
            Text("Programs")
        } footer: {
            if let problem {
                Text(problem).foregroundStyle(.red)
            } else {
                Text("Other programs can use SwiftVM through its service, as the swiftvm tool does. The first time one does, SwiftVM asks you. A program that is removed is asked about again.")
            }
        }
        .task { change("clients") }
    }

    private func change(_ command: String, program: String? = nil) {
        Task {
            let result = await Task.detached { Result { try ServiceClient().send(command, program: program) } }.value
            switch result {
            case .success(let answer) where answer.ok:
                programs = answer.clients ?? []
                problem = nil
            case .success(let answer):
                problem = answer.error?.message ?? "The service said no."
            case .failure(let error):
                problem = "The service couldn't be reached: \(error.localizedDescription)"
            }
        }
    }
}
