import Foundation

// An unsigned helper cannot tell Lilo from any other caller: it refuses to run.
guard let requirement = PowerHelperIdentity.requirement(forIdentifier: BuildIdentity.appIdentifier) else { exit(1) }

// Creating the service undoes whatever a run cut short left in its state file.
let service = PowerHelperService(
    backend: SystemPowerBackend(),
    stateURL: URL(fileURLWithPath: "/Library/Application Support/\(BuildIdentity.dataFolderName)/power-state.json")
)

// launchd stops the helper with SIGTERM at shutdown, restart or unregister: undo everything first.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    service.endAll()
    exit(0)
}
termination.resume()

let delegate = PowerHelperListener(service: service, onIdle: { exit(0) })
let listener = NSXPCListener(machServiceName: PowerHelperIdentity.machService)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = delegate
listener.resume()
delegate.armIdleExit()
dispatchMain()
