import CoreGraphics
import Foundation
import CoreFoundation

class CGEventController: PointerableObject {
  private var eventTap: CFMachPort?
  private var runLoopSrc: CFRunLoopSource?
  private let options: CGEventTapOptions
  private let eventsOfInterest: CGEventMask
  private let callback: CGEventTapCallBack

  /// - Parameters:
  ///   - options: Use `.listenOnly` for taps that only observe the event stream.
  ///     A listen-only tap never delays event delivery, so the system has no
  ///     timeout reason to disable it. `.defaultTap` (active) is only for taps
  ///     that must modify events.
  ///   - eventsOfInterest: The mask of events to receive.
  ///   - callback: Called for every event of interest. `tapDisabledByTimeout` and
  ///     `tapDisabledByUserInput` are handled internally (see `rearmingCallback`)
  ///     and never reach this callback.
  init(
    options: CGEventTapOptions = .defaultTap,
    eventsOfInterest: CGEventMask,
    callback: @escaping CGEventTapCallBack
  ) {
    self.options = options
    self.eventsOfInterest = eventsOfInterest
    self.callback = callback
  }

  /// When macOS disables a tap, it says so by sending `tapDisabledByTimeout` or
  /// `tapDisabledByUserInput` into the tap's own callback. Handling it here re-arms
  /// the tap in place, at the moment it is killed — instead of recovering after the
  /// fact by restarting listeners on wake/display/device notifications.
  private static let rearmingCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
    let controller = CGEventController.from(pointer: userInfo)

    guard type != .tapDisabledByTimeout && type != .tapDisabledByUserInput else {
      controller.reenableTap(disabledBy: type)
      return nil
    }

    return controller.callback(proxy, type, event, userInfo)
  }

  private func reenableTap(disabledBy type: CGEventType) {
    guard let tap = eventTap else { return }

    log.error("Event tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input") - re-arming in place.")
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  func start() -> Bool {
    // If we already have a valid tap, don’t install another one
    if eventTap != nil && CFMachPortIsValid(eventTap) && runLoopSrc != nil {
      log.info("Event tap already registered.")
      return true
    }

    // Ensure any previous state is cleaned up before creating a new one
    stop()

    guard let tap = CGEvent.tapCreate(
      tap: .cghidEventTap,
      place: .headInsertEventTap,
      options: options,
      eventsOfInterest: eventsOfInterest,
      callback: Self.rearmingCallback,
      userInfo: rawPointer
    ) else {
      log.error("Failed to create event tap (check accessibility permission).")
      return false
    }

    guard let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      log.error("Failed to create RunLoop source for event tap.")
      CFMachPortInvalidate(tap) // Clean up the tap if source creation fails
      return false
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    self.eventTap = tap
    self.runLoopSrc = src

    log.info("Successfully registered event tap.")
    return true
  }

  func stop() {
    // Use guard to safely unwrap and validate the eventTap
    guard let tap = eventTap, CFMachPortIsValid(tap) else {
      // This block executes if eventTap is nil OR if eventTap exists but is invalid.
      // We can add specific logging if needed, but the main goal is cleanup.
      if eventTap != nil {
        // This means eventTap existed but was invalid
        log.info("Event tap was invalid, cleaning up.")
      } else {
        // This means eventTap was nil
        // log.info("No event tap found to unregister (was nil).") // Optional logging
      }

      // Ensure state is clean regardless of why the guard failed
      eventTap = nil
      runLoopSrc = nil // If the tap is gone/invalid, the source is useless
      return // Exit the function
    }

    // --- If guard passes, 'tap' is guaranteed non-nil and valid ---

    // Disable the tap first
    CGEvent.tapEnable(tap: tap, enable: false)

    // Remove the source from the run loop *if it exists*
    // (It should exist if 'tap' was valid, but check for safety)
    if let src = runLoopSrc {
      CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
      // CFRunLoopRemoveSource handles releasing the source
      self.runLoopSrc = nil // Clear our reference
    } else {
      log.info("RunLoop source was unexpectedly nil during unregister for a valid tap.")
    }

    // Invalidate the underlying Mach port
    CFMachPortInvalidate(tap)
    // CFMachPortInvalidate handles releasing the port
    self.eventTap = nil // Clear our reference

    log.info("Successfully unregistered event tap.")
  }

  deinit {
    log.info("CGEventController deinit: ensuring callback is unregistered.")
    stop()
  }
}

extension CGEventMask {
  static func from(_ types: CGEventType...) -> Self {
    var mask: UInt64 = 0

    for type in types {
      mask |= (1 << type.rawValue)
    }

    return Self(mask)
  }
}
