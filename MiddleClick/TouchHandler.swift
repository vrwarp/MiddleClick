import AppKit

@MainActor class TouchHandler {
  static let shared = TouchHandler()
  private static let config = Config.shared
  private init() {
    Self.config.$tapToClick.onSet {
      self.tapToClick = $0
    }
    Self.config.$minimumFingers.onSet {
      Self.fingersQua = $0
    }
  }

  /// stored locally, since accessing the cache is more CPU-expensive than a local variable
  private var tapToClick = config.tapToClick

  private static var fingersQua = config.minimumFingers
  private static let allowMoreFingers = config.allowMoreFingers
  private static let maxDistanceDelta = config.maxDistanceDelta
  private static let maxTimeDelta = config.maxTimeDelta

  private var maybeMiddleClick = false
  private var touchStartTime: Date?
  private static var lastEmulatedMiddleClickTime: Date?
  private var middleClickPos1: SIMD2<Float> = .zero
  private var middleClickPos2: SIMD2<Float> = .zero

  /// Trackpad (and Magic Mouse) touches reach us through the public gesture event
  /// stream: every `gesture` event carries the current set of `NSTouch`es, which is
  /// enough to count fingers and track their movement — no private framework needed.
  private static let touchCallback: CGEventTapCallBack = {
    _, type, event, _ in
    // The tap is listen-only, so the returned event is ignored — pass it through untouched.
    let passthrough = Unmanaged.passUnretained(event)

    guard NSEvent.EventType(rawValue: UInt(type.rawValue)) == .gesture,
          let nsEvent = NSEvent(cgEvent: event)
    else { return passthrough }

    let touches = nsEvent.allTouches()
    // The gesture stream occasionally contains events without touch data. They say nothing about fingers, so skip them.
    guard !touches.isEmpty else { return passthrough }

    guard !AppUtils.isIgnoredAppBundle() else { return passthrough }

    let touchingFingers = touches.filter { $0.isTouching }
    let nFingers = touchingFingers.count

    let state = GlobalState.shared

    state.threeDown =
    allowMoreFingers ? nFingers >= fingersQua : nFingers == fingersQua

    let handler = TouchHandler.shared

    guard handler.tapToClick else { return passthrough }

    guard nFingers != 0 else {
      handler.handleTouchEnd()
      return passthrough
    }

    let isTouchStart = nFingers > 0 && handler.touchStartTime == nil
    if isTouchStart {
      handler.touchStartTime = Date()
      handler.maybeMiddleClick = true
      handler.middleClickPos1 = .zero
    } else if handler.maybeMiddleClick, let touchStartTime = handler.touchStartTime {
      // Timeout check for middle click
      let elapsedTime = -touchStartTime.timeIntervalSinceNow
      if elapsedTime > maxTimeDelta {
        handler.maybeMiddleClick = false
      }
    }

    guard !(nFingers < fingersQua) else { return passthrough }

    if !allowMoreFingers && nFingers > fingersQua {
      handler.resetMiddleClick()
    }

    let isCurrentFingersQuaAllowed = allowMoreFingers ? nFingers >= fingersQua : nFingers == fingersQua
    guard isCurrentFingersQuaAllowed else { return passthrough }

    handler.processTouches(touchingFingers)

    return passthrough
  }

  private func processTouches(_ touches: [NSTouch]) {
    if maybeMiddleClick {
      middleClickPos1 = .zero
    } else {
      middleClickPos2 = .zero
    }

//    TODO: Wait, what? Why is this iterating by fingersQua instead of all touching fingers, given that e.g. "allowMoreFingers" exists?
    for touch in touches.prefix(Self.fingersQua) {
      let pos = SIMD2(touch.normalizedPosition)
      if maybeMiddleClick {
        middleClickPos1 += pos
      } else {
        middleClickPos2 += pos
      }
    }

    if maybeMiddleClick {
      middleClickPos2 = middleClickPos1
      maybeMiddleClick = false
    }
  }

  private func resetMiddleClick() {
    maybeMiddleClick = false
    middleClickPos1 = .zero
  }

  private func handleTouchEnd() {
    guard let startTime = touchStartTime else { return }

    let elapsedTime = -startTime.timeIntervalSinceNow
    touchStartTime = nil

    guard middleClickPos1.isNonZero && elapsedTime <= Self.maxTimeDelta else { return }

    let delta = middleClickPos1.delta(to: middleClickPos2)
    if delta < Self.maxDistanceDelta && !shouldPreventEmulation() {
      Self.emulateMiddleClick()
    }
  }

  private static func emulateMiddleClick() {
    if let lastTime = lastEmulatedMiddleClickTime,
       -lastTime.timeIntervalSinceNow < maxTimeDelta * 0.3 {
      return
    }
    lastEmulatedMiddleClickTime = .init()

    // get the current pointer location
    let location = CGEvent(source: nil)?.location ?? .zero
    let buttonType: CGMouseButton = .center

    postMouseEvent(type: .otherMouseDown, button: buttonType, location: location)
    postMouseEvent(type: .otherMouseUp, button: buttonType, location: location)
  }

  private func shouldPreventEmulation() -> Bool {
    guard let naturalLastTime = GlobalState.shared.naturalMiddleClickLastTime else { return false }

    let elapsedTimeSinceNatural = -naturalLastTime.timeIntervalSinceNow
    return elapsedTimeSinceNatural <= Self.maxTimeDelta * 0.75 // fine-tuned multiplier
  }

  private static func postMouseEvent(
    type: CGEventType, button: CGMouseButton, location: CGPoint
  ) {
    CGEvent(
      mouseEventSource: nil, mouseType: type, mouseCursorPosition: location,
      mouseButton: button
    )?.post(tap: .cghidEventTap)
  }

  /// Listen-only, so the system never has a timeout reason to disable it —
  /// and if it disables it anyway, `CGEventController` re-arms it in place.
  private static let touchListener = CGEventController(
    options: .listenOnly,
    eventsOfInterest: CGEventMask(NSEvent.EventTypeMask.gesture.rawValue),
    callback: touchCallback
  )

  func start() {
    _ = Self.touchListener.start()
  }
  func stop() {
    Self.touchListener.stop()
  }
}

private extension NSTouch {
  /// Whether the finger is currently on the surface. A single gesture event may
  /// mix lifted (`ended`/`cancelled`) touches with ones still down.
  var isTouching: Bool { !phase.intersection(.touching).isEmpty }
}

extension SIMD2 where Scalar == Float {
  init(_ point: NSPoint) { self.init(Float(point.x), Float(point.y)) }
}
extension SIMD2 where Scalar: FloatingPoint {
  func delta(to other: SIMD2) -> Scalar {
    return abs(x - other.x) + abs(y - other.y)
  }

  var isNonZero: Bool { x != 0 || y != 0 }
}
