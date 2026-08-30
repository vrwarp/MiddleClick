import AppKit

@MainActor final class Controller {
  func start() {
    log.info("Starting listeners...")

    setupSessionHandling()

    accessibilityMonitor.addListener { becameTrusted in
      if becameTrusted {
        self.startEventTaps()
      } else {
        trayMenu.isStatusItemVisible = true
        self.stopEventTaps()
      }
    }

    checkForConflicts()
  }

  // Event taps don't need the old reactive restarts (on wake, display
  // reconfiguration, device hotplug): they aren't tied to a device, survive
  // sleep, and when macOS does disable one, it announces it right into the
  // tap's callback — where CGEventController re-arms it in place.

  func restartListeners() {
    log.info("Restarting now...")
    stopEventTaps()
    if isUserSessionActive {
      startEventTaps()
      log.info("Restart success.")
    } else {
//      This logic should never be reached — just a safeguard.
      log.info("Restart completed - listeners remain stopped due to inactive session")
    }
  }

  private func startEventTaps() {
    guard isUserSessionActive else {
      log.info("User session is inactive - not starting event taps")
      return
    }
    TouchHandler.shared.start()
    _ = Self.mouseEventHandler.start()
  }

  private func stopEventTaps() {
    TouchHandler.shared.stop()
    Self.mouseEventHandler.stop()
  }
}

// MARK: - Session Handling for Fast User Switching
//
// Always enabled: with MiddleClick running in more than one logged-in user's
// session (#127), only the on-console session should keep event taps installed —
// an off-console instance must not fight the active one over rewriting clicks.
// Stopping listeners while the session is off-console is safe on every
// macOS version, so no version gate.

fileprivate extension Controller {
  /// Session state tracking variables (using static storage for simplicity)
  private static var _userSessionActive = true

  /// Public accessor for session state (used by restartListeners and startEventTaps)
  var isUserSessionActive: Bool { Self._userSessionActive }

  /// Initialize session handling - call this from start()
  func setupSessionHandling() {
    Self._userSessionActive = true
    observeSessionNotifications()
  }

  private func observeSessionNotifications() {
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(receiveSessionResignActiveNote),
      name: NSWorkspace.sessionDidResignActiveNotification,
      object: nil
    )
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(receiveSessionBecomeActiveNote),
      name: NSWorkspace.sessionDidBecomeActiveNotification,
      object: nil
    )
  }

  @objc private func receiveSessionResignActiveNote(_ note: Notification) {
    log.info("User session resigned active, stopping listeners")
    Self._userSessionActive = false

    DispatchQueue.main.async {
      self.stopEventTaps()
    }
  }

  @objc private func receiveSessionBecomeActiveNote(_ note: Notification) {
    log.info("User session became active, restarting listeners")
    Self._userSessionActive = true

    DispatchQueue.main.async {
      self.restartListeners()
    }
  }
}
