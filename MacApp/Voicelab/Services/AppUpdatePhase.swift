enum AppUpdatePhase: Equatable {
    case unconfigured, idle, checking, available, downloading, verifying, ready, installing, current, failed
}
